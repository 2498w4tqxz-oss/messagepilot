import { DatabaseSync } from "node:sqlite";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import {
  PilotError,
  type Command,
  type CommandInput,
  type CommandState,
  type Event,
} from "./protocol.js";
const canonical = (v: unknown): string =>
  JSON.stringify(v, (_, value) =>
    value && typeof value === "object" && !Array.isArray(value)
      ? Object.fromEntries(
          Object.entries(value).sort(([a], [b]) => a.localeCompare(b)),
        )
      : value,
  );
export class Store {
  db: DatabaseSync;
  constructor(path: string) {
    if (path !== ":memory:")
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    this.db
      .exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS commands(id TEXT PRIMARY KEY,account TEXT NOT NULL,key TEXT NOT NULL,fingerprint TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,created INTEGER NOT NULL,updated INTEGER NOT NULL,generation TEXT,result TEXT,error TEXT,UNIQUE(account,key));
      CREATE INDEX IF NOT EXISTS commands_queue ON commands(account,state,created);
      CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,account TEXT NOT NULL,source TEXT NOT NULL,kind TEXT NOT NULL,data TEXT NOT NULL,created INTEGER NOT NULL,UNIQUE(account,source));
      CREATE INDEX IF NOT EXISTS events_account ON events(account,sequence);
      CREATE TABLE IF NOT EXISTS cards(account TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,body TEXT NOT NULL,PRIMARY KEY(account,id));`);
    // A process crash cannot establish whether a submitted Apple action happened.
    this.db
      .prepare(
        "UPDATE commands SET state='outcome_unknown',error='Gateway restarted during execution',updated=? WHERE state='executing'",
      )
      .run(Date.now());
  }
  enqueue(account: string, input: CommandInput): Command {
    const fingerprint = createHash("sha256")
      .update(canonical({ operation: input.operation, args: input.args }))
      .digest("hex");
    const old = this.db
      .prepare("SELECT * FROM commands WHERE account=? AND key=?")
      .get(account, input.idempotencyKey);
    if (old) {
      if (old.fingerprint !== fingerprint)
        throw new PilotError(
          "idempotency_conflict",
          "Key already used with different content",
          409,
        );
      return this.decode(old);
    }
    const id = randomUUID(),
      now = Date.now();
    this.db
      .prepare(
        "INSERT INTO commands(id,account,key,fingerprint,body,state,created,updated) VALUES(?,?,?,?,?,?,?,?)",
      )
      .run(
        id,
        account,
        input.idempotencyKey,
        fingerprint,
        JSON.stringify(input),
        "queued",
        now,
        now,
      );
    return this.get(account, id)!;
  }
  private decode(row: Record<string, unknown>): Command {
    return {
      ...JSON.parse(row.body as string),
      id: row.id,
      accountId: row.account,
      state: row.state,
      createdAt: row.created,
      updatedAt: row.updated,
      generation: row.generation ?? undefined,
      result: row.result ? JSON.parse(row.result as string) : undefined,
      error: row.error ?? undefined,
    };
  }
  get(account: string, id: string) {
    const row = this.db
      .prepare("SELECT * FROM commands WHERE account=? AND id=?")
      .get(account, id);
    return row ? this.decode(row) : undefined;
  }
  next(
    account: string,
    device = false,
    lane: "messages" | "development" = "messages",
  ) {
    const op = "json_extract(body,'$.operation')";
    const filter = device
      ? `${op} IN ('device.capture','location.get')`
      : `${op} NOT IN ('device.capture','location.get') AND ${op} ${lane === "development" ? "IN" : "NOT IN"} ('apps.build','apps.create','apps.ios.run')`;
    const row = this.db
      .prepare(
        `SELECT * FROM commands WHERE account=? AND state='queued' AND ${filter} ORDER BY created,rowid LIMIT 1`,
      )
      .get(account);
    return row ? this.decode(row) : undefined;
  }
  transition(
    account: string,
    id: string,
    from: CommandState,
    to: CommandState,
    extra: { generation?: string; result?: unknown; error?: string } = {},
  ) {
    return (
      Number(
        this.db
          .prepare(
            "UPDATE commands SET state=?,updated=?,generation=COALESCE(?,generation),result=?,error=? WHERE account=? AND id=? AND state=?",
          )
          .run(
            to,
            Date.now(),
            extra.generation ?? null,
            extra.result === undefined ? null : JSON.stringify(extra.result),
            extra.error ?? null,
            account,
            id,
            from,
          ).changes,
      ) === 1
    );
  }
  interrupt(account: string, generation: string) {
    this.db
      .prepare(
        "UPDATE commands SET state='outcome_unknown',error='Worker disconnected during execution',updated=? WHERE account=? AND generation=? AND state='executing'",
      )
      .run(Date.now(), account, generation);
  }
  event(account: string, sourceId: string, kind: string, data: unknown): Event {
    this.db
      .prepare(
        "INSERT OR IGNORE INTO events(account,source,kind,data,created) VALUES(?,?,?,?,?)",
      )
      .run(account, sourceId, kind, JSON.stringify(data), Date.now());
    return this.eventRow(
      this.db
        .prepare("SELECT * FROM events WHERE account=? AND source=?")
        .get(account, sourceId)!,
    );
  }
  private eventRow(r: Record<string, unknown>): Event {
    return {
      sequence: r.sequence as number,
      accountId: r.account as string,
      sourceId: r.source as string,
      kind: r.kind as string,
      data: JSON.parse(r.data as string),
      createdAt: r.created as number,
    };
  }
  events(account: string, after = 0, limit = 200) {
    return this.db
      .prepare(
        "SELECT * FROM events WHERE account=? AND sequence>? ORDER BY sequence LIMIT ?",
      )
      .all(account, after, Math.min(1000, limit))
      .map((r) => this.eventRow(r));
  }
  putCard(
    account: string,
    id: string,
    body: unknown,
    expectedRevision: number,
  ) {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const old = this.card(account, id);
      if ((old?.revision ?? 0) !== expectedRevision)
        throw new PilotError(
          "revision_conflict",
          "Card changed; fetch latest revision",
          409,
        );
      const revision = expectedRevision + 1;
      this.db
        .prepare(
          "INSERT INTO cards VALUES(?,?,?,?) ON CONFLICT(account,id) DO UPDATE SET revision=excluded.revision,body=excluded.body",
        )
        .run(account, id, revision, JSON.stringify(body));
      this.db.exec("COMMIT");
      return { id, revision, body };
    } catch (e) {
      this.db.exec("ROLLBACK");
      throw e;
    }
  }
  card(account: string, id: string) {
    const r = this.db
      .prepare("SELECT * FROM cards WHERE account=? AND id=?")
      .get(account, id);
    return r
      ? {
          id: r.id as string,
          revision: r.revision as number,
          body: JSON.parse(r.body as string),
        }
      : undefined;
  }
  close() {
    this.db.close();
  }
}
