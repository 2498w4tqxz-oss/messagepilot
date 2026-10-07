import http, { type IncomingMessage, type ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";
import { Auth } from "./auth.js";
import { Store } from "./store.js";
import {
  commandSchema,
  workerFrame,
  validateArgs,
  PilotError,
  type Config,
  type Capability,
} from "./protocol.js";
import { toolSchemas } from "./tool-schemas.js";
import { Passkeys } from "./passkeys.js";
type Session = {
  socket: WebSocket;
  generation: string;
  account: string;
  workerId: string;
  capabilities: Capability[];
  inflight: Map<string, { commandId: string; timer: NodeJS.Timeout }>;
  lastSeen: number;
};
async function body(req: IncomingMessage) {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 1024 * 1024)
      throw new PilotError(
        "too_large",
        "Use worker-local media paths; JSON limit is 1 MiB",
        413,
      );
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString());
  } catch {
    throw new PilotError("invalid_json", "Expected JSON body");
  }
}
function reply(res: ServerResponse, status: number, value: unknown) {
  res.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  res.end(JSON.stringify(value));
}
export class Gateway {
  readonly store: Store;
  readonly auth: Auth;
  readonly server: http.Server;
  readonly wss: WebSocketServer;
  readonly passkeys?: Passkeys;
  private sessions = new Map<string, Session>();
  private streams = new Map<string, Set<ServerResponse>>();
  private heartbeat: NodeJS.Timeout;
  private closing = false;
  constructor(
    readonly config: Config,
    env = process.env,
  ) {
    this.auth = new Auth(config, env, (token) =>
      this.passkeys?.principal(token),
    );
    this.store = new Store(config.database);
    this.passkeys = config.passkeys
      ? new Passkeys(this.store.db, config.passkeys)
      : undefined;
    this.server = http.createServer((req, res) => {
      void this.route(req, res).catch((error) => {
        if (!res.headersSent)
          reply(res, error instanceof PilotError ? error.status : 500, {
            error: error instanceof PilotError ? error.code : "internal_error",
            message:
              error instanceof PilotError
                ? error.message
                : "Internal gateway error",
          });
        else res.end();
      });
    });
    this.wss = new WebSocketServer({
      noServer: true,
      maxPayload: 8 * 1024 * 1024,
      perMessageDeflate: false,
    });
    this.server.on("upgrade", (req, socket, head) => {
      try {
        if (req.url !== "/worker") throw new Error("Invalid path");
        const account = this.auth.worker(req.headers.authorization);
        this.wss.handleUpgrade(req, socket, head, (ws) =>
          this.attach(ws, account.account, account.role),
        );
      } catch {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
      }
    });
    this.heartbeat = setInterval(() => {
      for (const s of this.sessions.values()) {
        if (Date.now() - s.lastSeen > 45000) s.socket.terminate();
        else s.socket.ping();
      }
    }, 15000);
    this.heartbeat.unref();
  }
  async listen() {
    await new Promise<void>((resolve) =>
      this.server.listen(this.config.port, this.config.host, resolve),
    );
    const address = this.server.address();
    return typeof address === "object" && address ? address.port : 0;
  }
  private emit(account: string, source: string, kind: string, data: unknown) {
    const event = this.store.event(account, source, kind, data);
    for (const res of this.streams.get(account) ?? []) {
      if (
        !res.write(
          `id: ${event.sequence}\nevent: ${kind}\ndata: ${JSON.stringify(event)}\n\n`,
        )
      )
        res.destroy();
    }
    return event;
  }
  private attach(
    socket: WebSocket,
    account: Config["accounts"][number],
    role: "computer" | "device",
  ) {
    const key = `${account.id}:${role}`;
    let session: Session | undefined;
    const helloTimer = setTimeout(
      () => socket.close(1008, "Handshake timeout"),
      5000,
    );
    socket.on("pong", () => {
      if (session) session.lastSeen = Date.now();
    });
    socket.on("error", () => {});
    socket.on("message", (raw) => {
      if (this.closing) return;
      try {
        const frame = workerFrame.parse(JSON.parse(raw.toString()));
        if (frame.type === "hello") {
          if (
            session ||
            frame.role !== role ||
            frame.accountId !== account.id ||
            frame.identity.toLowerCase() !== account.identity.toLowerCase()
          )
            throw new Error("Identity mismatch");
          if (this.sessions.has(key))
            throw new Error(
              "Account already has an active worker for this role",
            );
          const capabilities = frame.capabilities.filter(
            (c) =>
              (c.operation.startsWith("device.") ||
                c.operation === "location.get") ===
              (role === "device"),
          );
          clearTimeout(helloTimer);
          session = {
            socket,
            account: account.id,
            workerId: frame.workerId,
            generation: randomUUID(),
            capabilities,
            inflight: new Map(),
            lastSeen: Date.now(),
          };
          this.sessions.set(key, session);
          socket.send(
            JSON.stringify({ type: "welcome", generation: session.generation }),
          );
          this.dispatch(account.id);
          return;
        }
        if (!session || this.sessions.get(key) !== session)
          throw new Error("Worker not enrolled");
        session.lastSeen = Date.now();
        if (frame.type === "event") {
          const allowed =
            role === "device"
              ? [
                  "device.capture.completed",
                  "device.capture.cancelled",
                  "device.activity.token",
                ]
              : ["messages.changed", "bridge.resync_required"];
          if (!allowed.includes(frame.kind))
            throw new Error("Event kind not allowed for this worker role");
          const event = this.emit(
            account.id,
            `worker:${role}:${frame.sourceId}`,
            frame.kind,
            frame.data,
          );
          socket.send(
            JSON.stringify({
              type: "ack",
              sourceId: frame.sourceId,
              sequence: event.sequence,
            }),
          );
        }
        if (frame.type === "result") {
          const active = [...session.inflight.entries()].find(
            ([, value]) => value.commandId === frame.commandId,
          );
          if (frame.generation !== session.generation || !active)
            throw new Error("Stale command result");
          const state = frame.ok
            ? "completed"
            : frame.uncertain
              ? "outcome_unknown"
              : "failed";
          if (
            this.store.transition(
              account.id,
              frame.commandId,
              "executing",
              state,
              { result: frame.result, error: frame.error },
            )
          )
            this.emit(
              account.id,
              `command:${frame.commandId}:${state}`,
              "command.updated",
              this.store.get(account.id, frame.commandId),
            );
          clearTimeout(active[1].timer);
          session.inflight.delete(active[0]);
          this.dispatch(account.id);
        }
      } catch {
        socket.close(1008, "Invalid worker frame or binding");
      }
    });
    socket.on("close", () => {
      clearTimeout(helloTimer);
      if (session && this.sessions.get(key) === session) {
        this.store.interrupt(account.id, session.generation);
        this.sessions.delete(key);
        for (const active of session.inflight.values()) {
          clearTimeout(active.timer);
          this.emit(
            account.id,
            `command:${active.commandId}:unknown`,
            "command.updated",
            this.store.get(account.id, active.commandId),
          );
        }
      }
    });
  }
  private dispatch(account: string) {
    if (this.closing) return;
    this.dispatchRole(account, "computer", "messages");
    this.dispatchRole(account, "computer", "development");
    this.dispatchRole(account, "computer", "integrations");
    this.dispatchRole(account, "device", "messages");
  }
  private dispatchRole(
    account: string,
    role: "computer" | "device",
    lane: "messages" | "development" | "integrations",
  ) {
    const s = this.sessions.get(`${account}:${role}`);
    if (!s || s.inflight.has(lane) || s.socket.readyState !== WebSocket.OPEN)
      return;
    const command = this.store.next(account, role === "device", lane);
    if (!command) return;
    if (
      !s.capabilities.some(
        (c) => c.operation === command.operation && c.available,
      )
    ) {
      this.store.transition(account, command.id, "queued", "failed", {
        error: `Capability unavailable: ${command.operation}`,
      });
      this.emit(
        account,
        `command:${command.id}:failed`,
        "command.updated",
        this.store.get(account, command.id),
      );
      queueMicrotask(() => this.dispatch(account));
      return;
    }
    if (
      !this.store.transition(account, command.id, "queued", "executing", {
        generation: s.generation,
      })
    )
      return;
    // Timeout fences the entire worker. Never run another desktop action over an uncertain one.
    const deadline = [
      "apps.build",
      "apps.ios.run",
      "computer.exec",
      "apple.tools.run",
      "imessage.run",
    ].includes(command.operation)
      ? 600000
      : 90000;
    s.inflight.set(lane, {
      commandId: command.id,
      timer: setTimeout(() => s.socket.terminate(), deadline),
    });
    s.socket.send(
      JSON.stringify({ type: "command", generation: s.generation, command }),
    );
  }
  private async route(req: IncomingMessage, res: ServerResponse) {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (
      url.pathname === "/.well-known/apple-app-site-association" &&
      req.method === "GET" &&
      this.passkeys
    ) {
      reply(res, 200, {
        webcredentials: { apps: this.passkeys.config.appIds },
      });
      return;
    }
    if (url.pathname.startsWith("/v1/passkeys/") && req.method === "POST") {
      if (!this.passkeys)
        throw new PilotError(
          "disabled",
          "Optional passkey authentication is not configured",
          404,
        );
      const input = await body(req);
      if (
        typeof input.accountId !== "string" ||
        !this.config.accounts.some((a) => a.id === input.accountId)
      )
        throw new PilotError("not_found", "Account not found", 404);
      if (url.pathname === "/v1/passkeys/signin-options") {
        reply(
          res,
          200,
          await this.passkeys.authenticationOptions(input.accountId),
        );
        return;
      }
      if (url.pathname === "/v1/passkeys/signin-verify") {
        try {
          reply(
            res,
            200,
            await this.passkeys.authenticate(
              input.accountId,
              input.challengeId,
              input.response,
            ),
          );
        } catch (error) {
          if (error instanceof PilotError) throw error;
          throw new PilotError(
            "invalid_passkey",
            "Passkey verification failed",
            401,
          );
        }
        return;
      }
      throw new PilotError("not_found", "Unknown passkey endpoint", 404);
    }
    if (url.pathname === "/health") {
      reply(res, 200, { service: "messagepilot", status: "up" });
      return;
    }
    if (url.pathname === "/v1/device-events" && req.method === "POST") {
      const binding = this.auth.worker(req.headers.authorization);
      if (binding.role !== "device")
        throw new PilotError(
          "forbidden",
          "A device credential is required",
          403,
        );
      const event = await body(req);
      if (
        event.kind !== "device.activity.token" ||
        typeof event.sourceId !== "string" ||
        !event.sourceId ||
        event.sourceId.length > 200 ||
        !event.data ||
        typeof event.data !== "object"
      )
        throw new PilotError(
          "invalid_event",
          "Only ActivityKit token events are accepted here",
        );
      reply(
        res,
        200,
        this.emit(
          binding.account.id,
          `worker:device:${event.sourceId}`,
          event.kind,
          event.data,
        ),
      );
      return;
    }
    const segments = url.pathname.split("/").filter(Boolean);
    if (segments[0] !== "v1" || segments[1] !== "accounts" || !segments[2])
      throw new PilotError("not_found", "Unknown endpoint", 404);
    const account = decodeURIComponent(segments[2]);
    const agent = this.auth.agent(req.headers.authorization, account);
    const resource = segments[3],
      id = segments[4];
    if (
      agent.cardOnly &&
      resource !== "cards" &&
      !(resource === "passkeys" && id === "logout")
    )
      throw new PilotError(
        "forbidden",
        "Passkey sessions grant private card access only",
        403,
      );
    if (resource === "passkeys") {
      if (!this.passkeys)
        throw new PilotError("disabled", "Passkeys are not configured", 404);
      if (id === "logout" && req.method === "POST") {
        this.passkeys.logout(req.headers.authorization!.slice(7));
        reply(res, 200, { signedOut: true });
        return;
      }
      this.auth.agent(req.headers.authorization, account, "computer.input");
      if (id === "register-options" && req.method === "POST") {
        reply(res, 200, await this.passkeys.registrationOptions(account));
        return;
      }
      if (id === "register-verify" && req.method === "POST") {
        const input = await body(req);
        try {
          reply(
            res,
            200,
            await this.passkeys.register(
              account,
              input.challengeId,
              input.response,
            ),
          );
        } catch (error) {
          if (error instanceof PilotError) throw error;
          throw new PilotError(
            "invalid_passkey",
            "Passkey registration failed",
            401,
          );
        }
        return;
      }
      if (!id && req.method === "GET") {
        reply(res, 200, this.passkeys.credentials(account));
        return;
      }
      if (id && req.method === "DELETE") {
        reply(res, 200, this.passkeys.revoke(account, decodeURIComponent(id)));
        return;
      }
    }
    if (resource === "control") {
      if (req.method === "GET") {
        reply(res, 200, { control: this.store.control(account) });
        return;
      }
      this.auth.agent(req.headers.authorization, account, "computer.input");
      const input = await body(req);
      if (req.method === "POST") {
        const ttl = input.ttlSeconds ?? 120;
        if (!Number.isInteger(ttl) || ttl < 15 || ttl > 900)
          throw new PilotError("invalid_ttl", "ttlSeconds must be 15–900");
        const lease = this.store.claimControl(
          account,
          agent.id,
          ttl,
          input.leaseId,
        );
        this.emit(account, randomUUID(), "computer.control", {
          state: "claimed",
          ...lease,
        });
        reply(res, 200, lease);
        return;
      }
      if (req.method === "DELETE") {
        this.store.releaseControl(account, agent.id, input.leaseId);
        this.emit(account, randomUUID(), "computer.control", {
          state: "released",
          owner: agent.id,
        });
        reply(res, 200, { released: true });
        return;
      }
    }
    if (req.method === "GET" && resource === "capabilities") {
      const sessions = [
        this.sessions.get(`${account}:computer`),
        this.sessions.get(`${account}:device`),
      ].filter((s): s is Session => !!s);
      reply(res, 200, {
        accountId: account,
        online: sessions.length > 0,
        workerIds: sessions.map((s) => s.workerId),
        capabilities: sessions
          .flatMap((s) => s.capabilities)
          .filter(
            (c) => !agent.operations || agent.operations.includes(c.operation),
          ),
      });
      return;
    }
    if (req.method === "POST" && resource === "commands" && !id) {
      const parsed = commandSchema.safeParse(await body(req));
      if (!parsed.success)
        throw new PilotError("invalid_command", parsed.error.message);
      this.auth.agent(
        req.headers.authorization,
        account,
        parsed.data.operation,
      );
      validateArgs(parsed.data.operation, parsed.data.args);
      const args = toolSchemas[parsed.data.operation].safeParse(
        parsed.data.args,
      );
      if (!args.success)
        throw new PilotError("invalid_arguments", args.error.message);
      this.store.assertControl(
        account,
        agent.id,
        parsed.data.operation === "computer.input",
      );
      parsed.data.args = args.data;
      const command = this.store.enqueue(account, parsed.data);
      reply(res, 202, command);
      this.dispatch(account);
      return;
    }
    if (req.method === "GET" && resource === "commands" && id) {
      const command = this.store.get(account, id);
      if (!command) throw new PilotError("not_found", "Command not found", 404);
      this.auth.agent(req.headers.authorization, account, command.operation);
      reply(res, 200, command);
      return;
    }
    if (req.method === "DELETE" && resource === "commands" && id) {
      const command = this.store.get(account, id);
      if (!command) throw new PilotError("not_found", "Command not found", 404);
      this.auth.agent(req.headers.authorization, account, command.operation);
      if (!this.store.transition(account, id, "queued", "cancelled"))
        throw new PilotError(
          "already_dispatched",
          "Only queued commands can be cancelled; dispatched Apple actions cannot be recalled",
          409,
        );
      reply(res, 200, this.store.get(account, id));
      return;
    }
    // Events/cards carry conversation data: restricted tokens need message-read access.
    if (resource === "events" || resource === "cards")
      this.auth.agent(req.headers.authorization, account, "messages.list");
    if (req.method === "GET" && resource === "events") {
      const after = Number(
        url.searchParams.get("after") ?? req.headers["last-event-id"] ?? 0,
      );
      if (!Number.isSafeInteger(after) || after < 0)
        throw new PilotError("invalid_cursor", "Expected nonnegative integer");
      if (url.searchParams.get("stream") !== "1") {
        reply(res, 200, this.store.events(account, after));
        return;
      }
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
        "x-accel-buffering": "no",
      });
      let cursor = after;
      while (true) {
        const page = this.store.events(account, cursor, 1000);
        for (const event of page)
          res.write(
            `id: ${event.sequence}\nevent: ${event.kind}\ndata: ${JSON.stringify(event)}\n\n`,
          );
        if (page.length < 1000) break;
        cursor = page.at(-1)!.sequence;
      }
      const set = this.streams.get(account) ?? new Set<ServerResponse>();
      this.streams.set(account, set);
      set.add(res);
      const ping = setInterval(() => res.write(": keepalive\n\n"), 15000);
      res.on("close", () => {
        clearInterval(ping);
        set.delete(res);
      });
      return;
    }
    if (resource === "cards" && id && req.method === "GET") {
      const card = this.store.card(account, id);
      if (!card) throw new PilotError("not_found", "Card not found", 404);
      reply(res, 200, card);
      return;
    }
    if (
      resource === "cards" &&
      id &&
      segments[5] === "actions" &&
      req.method === "POST"
    ) {
      this.auth.agent(req.headers.authorization, account, "messages.send");
      const input = await body(req);
      const card = this.store.card(account, id);
      if (!card || card.revision !== input.revision)
        throw new PilotError(
          "revision_conflict",
          "Reload the current card before acting",
          409,
        );
      if (
        typeof input.action !== "string" ||
        !card.body?.actions?.includes(input.action) ||
        typeof input.idempotencyKey !== "string" ||
        input.idempotencyKey.length > 200
      )
        throw new PilotError(
          "invalid_action",
          "Action must be declared by the current card",
        );
      const event = this.emit(
        account,
        `card-action:${id}:${input.idempotencyKey}`,
        "card.action",
        {
          cardId: id,
          revision: card.revision,
          action: input.action,
          actor: agent.id,
        },
      );
      reply(res, 202, event);
      return;
    }
    if (resource === "cards" && id && req.method === "PUT") {
      this.auth.agent(req.headers.authorization, account, "messages.send");
      const input = await body(req);
      if (
        !Number.isSafeInteger(input.expectedRevision) ||
        input.expectedRevision < 0
      )
        throw new PilotError("invalid_revision", "expectedRevision required");
      const card = this.store.putCard(
        account,
        id,
        input.body,
        input.expectedRevision,
      );
      this.emit(account, `card:${id}:${card.revision}`, "card.updated", card);
      reply(res, 200, card);
      return;
    }
    throw new PilotError("not_found", "Unknown endpoint", 404);
  }
  async close() {
    if (this.closing) return;
    this.closing = true;
    clearInterval(this.heartbeat);
    for (const s of this.sessions.values()) {
      for (const active of s.inflight.values()) clearTimeout(active.timer);
      this.store.interrupt(s.account, s.generation);
    }
    this.sessions.clear();
    for (const socket of this.wss.clients) socket.terminate();
    for (const set of this.streams.values()) for (const res of set) res.end();
    await Promise.all([
      new Promise<void>((resolve) => this.server.close(() => resolve())),
      new Promise<void>((resolve) => this.wss.close(() => resolve())),
    ]);
    this.store.close();
  }
}
