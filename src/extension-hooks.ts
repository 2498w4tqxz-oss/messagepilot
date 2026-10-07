import {
  createHash,
  createHmac,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import type { Principal } from "./auth.js";
import { chatScope } from "./chat-scope.js";
import { PilotError, type Config } from "./protocol.js";
import {
  extensionActions,
  extensionStates,
  hookRequestSchema,
  hookObservationSchema,
  type ExtensionHookConfig,
} from "./extension-hook-schema.js";

const canonical = (v: unknown) =>
  JSON.stringify(v, (_, x) =>
    x && typeof x === "object" && !Array.isArray(x)
      ? Object.fromEntries(
          Object.entries(x).sort(([a], [b]) => a.localeCompare(b)),
        )
      : x,
  );
const hash = (v: unknown) =>
  createHash("sha256").update(canonical(v)).digest("hex");
export const hookSignature = (
  secret: string,
  timestamp: string,
  body: string,
) => createHmac("sha256", secret).update(`${timestamp}.${body}`).digest("hex");

/** Verify raw bytes before parsing, then deduplicate the event ID durably at the receiver. */
export function verifyHookSignature(
  secret: string,
  timestamp: string,
  body: string,
  signature: string,
  now = Date.now(),
): boolean {
  if (
    !/^\d{10,}$/.test(timestamp) ||
    !/^v1=[a-f0-9]{64}$/.test(signature) ||
    Math.abs(now / 1000 - Number(timestamp)) > 300
  )
    return false;
  return timingSafeEqual(
    Buffer.from(signature.slice(3), "hex"),
    Buffer.from(hookSignature(secret, timestamp, body), "hex"),
  );
}

/** Durable agent-mediated extension workflows. This is not an Apple event API. */
export class ExtensionHooks {
  private hooks = new Map<string, ExtensionHookConfig>();
  private secrets = new Map<string, string>();
  private timer: NodeJS.Timeout;
  private active?: Promise<void>;
  private stopped = false;
  constructor(
    private db: DatabaseSync,
    private config: Config,
    env: NodeJS.ProcessEnv,
  ) {
    for (const hook of config.extensionHooks ?? []) {
      const account = config.accounts.find((a) => a.id === hook.accountId);
      if (!account || this.hooks.has(hook.id))
        throw new Error("Invalid or duplicate extension hook binding");
      if (
        account.allowedChatIds &&
        !account.allowedChatIds.includes(hook.chatId)
      )
        throw new Error("Extension hook exceeds account chat scope");
      for (const id of [...hook.requestAgentIds, ...hook.observerAgentIds]) {
        const agent = config.agents.find(
          (a) => a.id === id && a.accounts.includes(hook.accountId),
        );
        if (
          !agent ||
          chatScope(config, agent, hook.accountId)?.includes(hook.chatId) ===
            false
        )
          throw new Error("Extension hook exceeds agent account/chat scope");
      }
      const url = new URL(hook.url);
      if (
        url.username ||
        url.password ||
        url.hash ||
        (url.protocol !== "https:" &&
          !(
            hook.allowLoopbackHttp &&
            url.protocol === "http:" &&
            ["127.0.0.1", "[::1]"].includes(url.hostname)
          ))
      )
        throw new Error(
          "Webhook requires HTTPS (explicit literal loopback HTTP allowed for tests)",
        );
      const secret = env[hook.signingSecretEnv];
      if (!secret || secret.length < 32)
        throw new Error(
          "Webhook signing secret must have at least 32 characters",
        );
      this.hooks.set(hook.id, hook);
      this.secrets.set(hook.id, secret);
    }
    db.exec(`CREATE TABLE IF NOT EXISTS extension_requests(id TEXT PRIMARY KEY,hook TEXT NOT NULL,binding TEXT NOT NULL,key TEXT NOT NULL,fingerprint TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,actor TEXT,created INTEGER NOT NULL,updated INTEGER NOT NULL,result TEXT,UNIQUE(hook,key));
      CREATE TABLE IF NOT EXISTS extension_deliveries(id TEXT PRIMARY KEY,hook TEXT NOT NULL,binding TEXT NOT NULL,source TEXT NOT NULL,fingerprint TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next INTEGER NOT NULL,status INTEGER,UNIQUE(hook,source));
      CREATE INDEX IF NOT EXISTS extension_delivery_due ON extension_deliveries(state,next);`);
    db.prepare(
      "UPDATE extension_requests SET state='outcome_unknown',updated=? WHERE state='executing'",
    ).run(Date.now());
    this.timer = setInterval(() => {
      void this.flush().catch(() => {});
    }, 1000);
    this.timer.unref();
  }
  authorize(
    account: string,
    id: string,
    agent: Principal,
    mode: "request" | "observe" | "read",
  ) {
    const hook = this.hooks.get(id);
    if (!hook || hook.accountId !== account)
      throw new PilotError("not_found", "Extension hook not found", 404);
    const ids =
      mode === "request"
        ? hook.requestAgentIds
        : mode === "observe"
          ? hook.observerAgentIds
          : [...hook.requestAgentIds, ...hook.observerAgentIds];
    if (!ids.includes(agent.id) || agent.cardOnly)
      throw new PilotError("forbidden", "Extension hook grant required", 403);
    if (chatScope(this.config, agent, account)?.includes(hook.chatId) === false)
      throw new PilotError("chat_forbidden", "Hook chat is outside scope", 403);
    return hook;
  }
  private binding(hook: ExtensionHookConfig) {
    return hash({
      account: hook.accountId,
      chat: hook.chatId,
      feature: hook.feature,
      url: hook.url,
      includeCoordinates: hook.includeCoordinates,
    });
  }
  private parse<T>(
    schema: { safeParse(v: unknown): { success: boolean; data?: T } },
    input: unknown,
  ): T {
    const result = schema.safeParse(input);
    if (!result.success)
      throw new PilotError(
        "invalid_arguments",
        "Invalid extension hook payload",
      );
    return result.data!;
  }
  private transaction<T>(fn: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const value = fn();
      this.db.exec("COMMIT");
      return value;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }
  private event(
    hook: ExtensionHookConfig,
    source: string,
    kind: string,
    data: unknown,
  ) {
    const fingerprint = hash({ binding: this.binding(hook), kind, data });
    const old = this.db
      .prepare("SELECT * FROM extension_deliveries WHERE hook=? AND source=?")
      .get(hook.id, source);
    if (old) {
      if (old.fingerprint !== fingerprint)
        throw new PilotError(
          "idempotency_conflict",
          "Observation key has different content",
          409,
        );
      return JSON.parse(String(old.body));
    }
    const event = {
      id: randomUUID(),
      accountId: hook.accountId,
      chatId: hook.chatId,
      feature: hook.feature,
      kind,
      source: "messagepilot.agent_mediated",
      createdAt: Date.now(),
      data,
    };
    this.db
      .prepare(
        "INSERT INTO extension_deliveries(id,hook,binding,source,fingerprint,body,state,next) VALUES(?,?,?,?,?,?,'pending',?)",
      )
      .run(
        event.id,
        hook.id,
        this.binding(hook),
        source,
        fingerprint,
        JSON.stringify(event),
        Date.now(),
      );
    return event;
  }
  request(hook: ExtensionHookConfig, input: unknown) {
    const parsed = this.parse(hookRequestSchema, input);
    const schema = (
      extensionActions[hook.feature] as Record<
        string,
        { safeParse(v: unknown): any }
      >
    )[parsed.action];
    if (
      !schema ||
      !Object.hasOwn(extensionActions[hook.feature], parsed.action)
    )
      throw new PilotError(
        "invalid_action",
        "Action is not supported for this extension",
      );
    const body = {
      action: parsed.action,
      parameters: this.parse(schema, parsed.parameters),
    };
    const fingerprint = hash({ binding: this.binding(hook), body });
    return this.transaction(() => {
      const old = this.db
        .prepare("SELECT * FROM extension_requests WHERE hook=? AND key=?")
        .get(hook.id, parsed.idempotencyKey);
      if (old) {
        if (old.fingerprint !== fingerprint)
          throw new PilotError(
            "idempotency_conflict",
            "Request key has different content",
            409,
          );
        return this.decode(old);
      }
      const id = randomUUID(),
        now = Date.now();
      this.db
        .prepare(
          "INSERT INTO extension_requests(id,hook,binding,key,fingerprint,body,state,created,updated) VALUES(?,?,?,?,?,?,'requested',?,?)",
        )
        .run(
          id,
          hook.id,
          this.binding(hook),
          parsed.idempotencyKey,
          fingerprint,
          JSON.stringify(body),
          now,
          now,
        );
      this.event(hook, `request:${id}`, "extension.action.requested", {
        requestId: id,
        ...body,
        state: "requested",
        execution: "requires_enrolled_agent",
      });
      return this.get(hook, id);
    });
  }
  private decode(row: Record<string, unknown>) {
    return {
      id: row.id,
      ...JSON.parse(String(row.body)),
      state: row.state,
      actor: row.actor,
      createdAt: row.created,
      updatedAt: row.updated,
      result: row.result ? JSON.parse(String(row.result)) : undefined,
    };
  }
  get(hook: ExtensionHookConfig, id: string) {
    const row = this.db
      .prepare(
        "SELECT * FROM extension_requests WHERE hook=? AND binding=? AND id=?",
      )
      .get(hook.id, this.binding(hook), id);
    if (!row)
      throw new PilotError("not_found", "Extension request not found", 404);
    return this.decode(row);
  }
  list(hook: ExtensionHookConfig) {
    return this.db
      .prepare(
        "SELECT * FROM extension_requests WHERE hook=? AND binding=? ORDER BY created DESC LIMIT 100",
      )
      .all(hook.id, this.binding(hook))
      .map((r) => this.decode(r));
  }
  claim(hook: ExtensionHookConfig, id: string, actor: string) {
    const result = this.db
      .prepare(
        "UPDATE extension_requests SET state='executing',actor=?,updated=? WHERE hook=? AND binding=? AND id=? AND state='requested'",
      )
      .run(actor, Date.now(), hook.id, this.binding(hook), id);
    if (!result.changes)
      throw new PilotError(
        "not_claimable",
        "Request already claimed or terminal; reconcile rather than retry Apple actions",
        409,
      );
    return this.get(hook, id);
  }
  observe(hook: ExtensionHookConfig, input: unknown, actor: string) {
    const observation = this.parse(hookObservationSchema, input);
    if (
      !(extensionStates[hook.feature] as readonly string[]).includes(
        observation.state,
      )
    )
      throw new PilotError(
        "invalid_state",
        "State is not supported for this extension",
      );
    if (observation.observedAt > Date.now() + 60000)
      throw new PilotError(
        "invalid_time",
        "Observation timestamp is in the future",
      );
    if (
      observation.location &&
      (hook.feature !== "location" || !hook.includeCoordinates)
    )
      throw new PilotError(
        "coordinates_forbidden",
        "Coordinates require an explicit location-hook opt-in",
        403,
      );
    if (!!observation.requestId !== !!observation.outcome)
      throw new PilotError(
        "invalid_arguments",
        "Request ID and outcome must be supplied together",
      );
    if (
      observation.state === "unavailable" &&
      observation.outcome === "completed"
    )
      throw new PilotError(
        "invalid_outcome",
        "Unavailable Apple UI cannot complete an action",
      );
    return this.transaction(() => {
      if (observation.requestId) {
        const request = this.get(hook, observation.requestId);
        if (request.actor !== actor)
          throw new PilotError(
            "not_owner",
            "Only the claiming observer may resolve this request",
            403,
          );
        if (
          !["executing", "outcome_unknown"].includes(request.state) &&
          hash(request.result) !== hash(observation)
        )
          throw new PilotError(
            "terminal_request",
            "Request already resolved",
            409,
          );
      }
      const event = this.event(
        hook,
        `observation:${observation.sourceId}`,
        `extension.${hook.feature}.${observation.state}`,
        {
          ...observation,
          actor,
          verification:
            observation.evidence.kind === "fixture"
              ? "fixture"
              : "agent_reported",
        },
      );
      if (observation.requestId)
        this.db
          .prepare(
            "UPDATE extension_requests SET state=?,result=?,updated=? WHERE hook=? AND id=?",
          )
          .run(
            observation.outcome!,
            JSON.stringify(observation),
            Date.now(),
            hook.id,
            observation.requestId,
          );
      return event;
    });
  }
  deliveries(hook: ExtensionHookConfig) {
    return this.db
      .prepare(
        "SELECT id,state,attempts,status FROM extension_deliveries WHERE hook=? AND binding=? ORDER BY rowid DESC LIMIT 100",
      )
      .all(hook.id, this.binding(hook));
  }
  flush(): Promise<void> {
    if (this.stopped) return Promise.resolve();
    if (this.active) return this.active;
    this.active = this.deliver().finally(() => {
      this.active = undefined;
    });
    return this.active;
  }
  private async deliver() {
    const rows = this.db
      .prepare(
        "SELECT * FROM extension_deliveries WHERE state='pending' AND next<=? ORDER BY rowid LIMIT 20",
      )
      .all(Date.now());
    await Promise.all(
      rows.map(async (row) => {
        const hook = this.hooks.get(String(row.hook));
        if (!hook || this.binding(hook) !== row.binding) {
          this.db
            .prepare(
              "UPDATE extension_deliveries SET state='disabled' WHERE id=?",
            )
            .run(row.id!);
          return;
        }
        const timestamp = String(Math.floor(Date.now() / 1000)),
          body = String(row.body),
          attempts = Number(row.attempts) + 1;
        if (attempts > 8) {
          this.db
            .prepare(
              "UPDATE extension_deliveries SET state='failed' WHERE id=?",
            )
            .run(row.id!);
          return;
        }
        // Count dispatch before I/O so a crash cannot reset the retry budget.
        this.db
          .prepare(
            "UPDATE extension_deliveries SET attempts=?,next=? WHERE id=?",
          )
          .run(
            attempts,
            Date.now() + Math.min(300000, 1000 * 2 ** attempts),
            row.id!,
          );
        let status: number | null = null;
        try {
          const response = await fetch(hook.url, {
            method: "POST",
            redirect: "manual",
            signal: AbortSignal.timeout(5000),
            headers: {
              "content-type": "application/json",
              "x-messagepilot-id": String(row.id),
              "x-messagepilot-timestamp": timestamp,
              "x-messagepilot-signature": `v1=${hookSignature(this.secrets.get(hook.id)!, timestamp, body)}`,
            },
            body,
          });
          status = response.status;
          await response.body?.cancel();
        } catch {
          /* Retain stable event ID/body; remote delivery may have occurred. */
        }
        const state =
          status !== null && status >= 200 && status < 300
            ? "delivered"
            : attempts >= 8
              ? "failed"
              : "pending";
        this.db
          .prepare(
            "UPDATE extension_deliveries SET state=?,attempts=?,status=?,next=? WHERE id=?",
          )
          .run(
            state,
            attempts,
            status,
            Date.now() + Math.min(300000, 1000 * 2 ** attempts),
            row.id!,
          );
      }),
    );
  }
  async close() {
    this.stopped = true;
    clearInterval(this.timer);
    await this.active;
  }
}
