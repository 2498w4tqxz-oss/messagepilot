import { WebSocket } from "ws";
import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { randomUUID } from "node:crypto";
import type { NativeTransport } from "./native.js";
import type { Command } from "./protocol.js";
export class Worker {
  private socket?: WebSocket;
  private stopped = false;
  private retry?: NodeJS.Timeout;
  private heartbeat?: NodeJS.Timeout;
  private spool: DatabaseSync;
  private busy = new Set<string>();
  private welcomed = false;
  private nativeReady = false;
  private allowedChatIds?: string[];
  constructor(
    private options: {
      url: string;
      token: string;
      accountId: string;
      workerId: string;
      identity: string;
      spool: string;
    },
    private native: NativeTransport,
  ) {
    if (options.spool !== ":memory:")
      mkdirSync(dirname(options.spool), { recursive: true, mode: 0o700 });
    this.spool = new DatabaseSync(options.spool);
    this.spool.exec(
      "PRAGMA journal_mode=WAL;PRAGMA synchronous=FULL;CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,data TEXT NOT NULL);",
    );
    native.onEvent((data) => {
      if (this.stopped || this.allowedChatIds !== undefined) return;
      const sourceId = randomUUID();
      this.spool
        .prepare("INSERT INTO events VALUES(?,?)")
        .run(sourceId, JSON.stringify(data));
      if (this.welcomed)
        this.send({ type: "event", sourceId, kind: "messages.changed", data });
    });
    native.onExit?.(() => {
      this.nativeReady = false;
      this.socket?.terminate();
    });
  }
  async start() {
    const identity = await this.native.identity();
    if (identity.toLowerCase() !== this.options.identity.toLowerCase())
      throw new Error(
        "Native Apple identity does not match the enrolled account",
      );
    this.allowedChatIds = await this.native.chatScope?.();
    this.nativeReady = true;
    this.connect();
  }
  private connect() {
    if (this.stopped || !this.nativeReady) return;
    this.welcomed = false;
    const ws = new WebSocket(this.options.url, {
      headers: { Authorization: `Bearer ${this.options.token}` },
      perMessageDeflate: false,
    });
    this.socket = ws;
    ws.on("open", () => {
      void this.native
        .capabilities()
        .then((capabilities) => {
          if (ws.readyState === WebSocket.OPEN)
            ws.send(
              JSON.stringify({
                type: "hello",
                accountId: this.options.accountId,
                workerId: this.options.workerId,
                identity: this.options.identity,
                capabilities,
                allowedChatIds: this.allowedChatIds,
              }),
            );
        })
        .catch(() => ws.close());
    });
    ws.on("error", () => {});
    ws.on("message", (raw) => {
      if (this.stopped) return;
      try {
        const frame = JSON.parse(raw.toString());
        if (frame.type === "welcome") {
          this.welcomed = true;
          if (this.allowedChatIds !== undefined)
            this.spool.exec("DELETE FROM events");
          for (const event of this.spool
            .prepare("SELECT * FROM events ORDER BY rowid")
            .all())
            this.send({
              type: "event",
              sourceId: event.id,
              kind: "messages.changed",
              data: JSON.parse(event.data as string),
            });
          this.heartbeat = setInterval(
            () => this.send({ type: "heartbeat" }),
            15000,
          );
        }
        if (frame.type === "ack")
          this.spool
            .prepare("DELETE FROM events WHERE id=?")
            .run(frame.sourceId);
        if (frame.type === "command") {
          if (this.busy.has(frame.command.id)) {
            ws.close(1008, "Duplicate active command");
            return;
          }
          void this.execute(ws, frame.generation, frame.command);
        }
      } catch {
        ws.close(1008, "Invalid frame");
      }
    });
    ws.on("close", () => {
      clearInterval(this.heartbeat);
      this.welcomed = false;
      if (!this.stopped) {
        if (this.busy.size) {
          this.native.close();
          this.nativeReady = false;
          process.stderr.write(
            "Worker fenced after disconnect during execution; restart required.\n",
          );
        } else
          this.retry = setTimeout(
            () => this.connect(),
            1000 + Math.random() * 1000,
          );
      }
    });
  }
  private async execute(ws: WebSocket, generation: string, command: Command) {
    this.busy.add(command.id);
    try {
      const result = await this.native.execute(command.operation, command.args);
      if (ws.readyState === WebSocket.OPEN)
        ws.send(
          JSON.stringify({
            type: "result",
            commandId: command.id,
            generation,
            ok: true,
            result,
          }),
        );
    } catch (error) {
      if (ws.readyState === WebSocket.OPEN)
        ws.send(
          JSON.stringify({
            type: "result",
            commandId: command.id,
            generation,
            ok: false,
            error: String(error),
            uncertain: true,
          }),
        );
    } finally {
      this.busy.delete(command.id);
    }
  }
  private send(value: unknown) {
    if (this.socket?.readyState === WebSocket.OPEN)
      this.socket.send(JSON.stringify(value));
  }
  close() {
    if (this.stopped) return;
    this.stopped = true;
    clearTimeout(this.retry);
    clearInterval(this.heartbeat);
    this.socket?.terminate();
    this.native.close();
    this.spool.close();
  }
}
