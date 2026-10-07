import { randomUUID, createHash } from "node:crypto";
import type { Store } from "../store.js";
import type { Command, CommandInput, Config, Operation } from "../protocol.js";
import type { Principal } from "../auth.js";
import { PilotError } from "../errors.js";
import { chatScope } from "../chat-scope.js";
import {
  terminal,
  progressText,
  type ProgressJob,
  type StartProgress,
  type UpdateProgress,
} from "./schema.js";
const fingerprint = (v: unknown) =>
  createHash("sha256")
    .update(
      JSON.stringify(v, (_, x) =>
        x && typeof x === "object" && !Array.isArray(x)
          ? Object.fromEntries(
              Object.entries(x).sort(([a], [b]) => a.localeCompare(b)),
            )
          : x,
      ),
    )
    .digest("hex");
type Submit = (account: string, owner: string, input: CommandInput) => string;
export class ProgressService {
  private timer?: NodeJS.Timeout;
  constructor(
    private store: Store,
    private config: Config,
    private submit: Submit,
    private validateFiles: (
      account: string,
      chat: string,
      files: string[],
      actor: Principal,
    ) => void,
    private now = Date.now,
    automatic = true,
  ) {
    store.db.exec(
      "CREATE TABLE IF NOT EXISTS progress_jobs(id TEXT PRIMARY KEY,account TEXT NOT NULL,chat TEXT NOT NULL,owner TEXT NOT NULL,active INTEGER NOT NULL,body TEXT NOT NULL); CREATE INDEX IF NOT EXISTS progress_scope ON progress_jobs(account,chat); CREATE TABLE IF NOT EXISTS progress_keys(account TEXT NOT NULL,owner TEXT NOT NULL,key TEXT NOT NULL,hash TEXT NOT NULL,response TEXT NOT NULL,PRIMARY KEY(account,owner,key));",
    );
    if (automatic) {
      this.timer = setInterval(() => this.tick(), 250);
      this.timer.unref();
    }
  }
  close() {
    if (this.timer) clearInterval(this.timer);
  }
  authorize(account: string, chat: string, actor: Principal, write = false) {
    if (
      actor.cardOnly ||
      !actor.accounts.includes(account) ||
      !this.config.accounts.some((a) => a.id === account)
    )
      throw new PilotError("forbidden", "Progress account not granted", 403);
    const scope = chatScope(this.config, actor, account);
    if (scope !== undefined && !scope.includes(chat))
      throw new PilotError("chat_forbidden", "Progress chat not granted", 403);
    const op = write ? "messages.send" : "messages.list";
    if (actor.operations && !actor.operations.includes(op))
      throw new PilotError("forbidden", `Progress requires ${op}`, 403);
  }
  private write(j: ProgressJob) {
    j.transport.receipts = j.transport.receipts.slice(-100);
    this.store.db
      .prepare(
        "INSERT INTO progress_jobs VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET active=excluded.active,body=excluded.body",
      )
      .run(
        j.id,
        j.accountId,
        j.chatId,
        j.owner,
        Number(
          ![
            "complete",
            "failed",
            "outcome_unknown",
            "awaiting_user",
            "paused",
          ].includes(j.transport.state),
        ),
        JSON.stringify(j),
      );
  }
  get(account: string, id: string, actor: Principal, write = false) {
    const row = this.store.db
      .prepare("SELECT body FROM progress_jobs WHERE account=? AND id=?")
      .get(account, id) as { body: string } | undefined;
    if (!row) throw new PilotError("not_found", "Progress job not found", 404);
    const j = JSON.parse(row.body) as ProgressJob;
    this.authorize(account, j.chatId, actor, write);
    if (write && j.owner !== actor.id)
      throw new PilotError(
        "forbidden",
        "Only the creating agent can update this job",
        403,
      );
    return j;
  }
  list(account: string, chat: string, actor: Principal) {
    this.authorize(account, chat, actor);
    return (
      this.store.db
        .prepare(
          "SELECT body FROM progress_jobs WHERE account=? AND chat=? ORDER BY rowid DESC LIMIT 100",
        )
        .all(account, chat) as { body: string }[]
    ).map((r) => JSON.parse(r.body));
  }
  private mutate(
    account: string,
    owner: string,
    key: string,
    input: unknown,
    action: () => ProgressJob,
  ) {
    const hash = fingerprint(input);
    this.store.db.exec("BEGIN IMMEDIATE");
    try {
      const old = this.store.db
        .prepare(
          "SELECT hash,response FROM progress_keys WHERE account=? AND owner=? AND key=?",
        )
        .get(account, owner, key) as
        { hash: string; response: string } | undefined;
      if (old) {
        if (old.hash !== hash)
          throw new PilotError(
            "idempotency_conflict",
            "Progress key reused for different input",
            409,
          );
        this.store.db.exec("COMMIT");
        return JSON.parse(old.response) as ProgressJob;
      }
      const j = action();
      this.write(j);
      this.store.db
        .prepare("INSERT INTO progress_keys VALUES(?,?,?,?,?)")
        .run(account, owner, key, hash, JSON.stringify(j));
      this.store.db.exec("COMMIT");
      return JSON.parse(JSON.stringify(j)) as ProgressJob;
    } catch (e) {
      this.store.db.exec("ROLLBACK");
      throw e;
    }
  }
  start(account: string, actor: Principal, input: StartProgress) {
    this.authorize(account, input.chatId, actor, true);
    if (
      input.mode === "native_text" &&
      actor.operations &&
      !actor.operations.includes("messages.edit")
    )
      throw new PilotError(
        "forbidden",
        "Native progress requires messages.edit",
        403,
      );
    return this.mutate(
      account,
      actor.id,
      input.idempotencyKey,
      { start: input },
      () => {
        const active = this.store.db
          .prepare(
            "SELECT COUNT(*) AS n FROM progress_jobs WHERE account=? AND active=1",
          )
          .get(account) as { n: number };
        if (active.n >= 100)
          throw new PilotError(
            "too_many_jobs",
            "At most 100 active progress jobs per account",
            429,
          );
        const at = this.now();
        return {
          id: randomUUID(),
          accountId: account,
          owner: actor.id,
          chatId: input.chatId,
          title: input.title,
          mode: input.mode,
          state: "running",
          detail: input.detail,
          revision: 1,
          createdAt: at,
          updatedAt: at,
          fileIds: [],
          attachments: [],
          policy: {
            intervalMs: input.intervalMs,
            intermediateEdits: input.intermediateEdits,
            finalFallback: input.finalFallback,
          },
          history: [
            { revision: 1, state: "running", detail: input.detail, at },
          ],
          transport: {
            state: input.mode === "live_card" ? "awaiting_user" : "pending",
            lastAt: 0,
            editAttempts: 0,
            attachmentIndex: 0,
            fallbackUsed: false,
            receipts: [],
          },
        };
      },
    );
  }
  update(account: string, id: string, actor: Principal, input: UpdateProgress) {
    const current = this.get(account, id, actor, true);
    return this.mutate(
      account,
      actor.id,
      input.idempotencyKey,
      { id, update: input },
      () => {
        if (current.revision !== input.expectedRevision)
          throw new PilotError(
            "revision_conflict",
            "Reload job before updating",
            409,
          );
        if (terminal(current.state))
          throw new PilotError(
            "terminal_job",
            "Terminal jobs are immutable; start a new attempt",
            409,
          );
        if (
          !terminal(input.state) &&
          (input.fileIds.length || input.attachments.length)
        )
          throw new PilotError(
            "invalid_outputs",
            "Outputs are published only with a terminal result",
          );
        if (input.state !== "completed" && input.attachments.length)
          throw new PilotError(
            "invalid_outputs",
            "Native attachments require completed work",
          );
        this.validateFiles(account, current.chatId, input.fileIds, actor);
        if (current.mode === "live_card" && input.attachments.length)
          throw new PilotError(
            "invalid_outputs",
            "Use fileIds for live cards; native attachments require native_text mode",
          );
        // A queued intermediate edit has not reached the worker. Supersede it
        // atomically so a slow/offline worker eventually receives the newest step.
        const transport = current.transport;
        if (terminal(input.state) && transport.state === "paused") {
          transport.state = "watching";
          delete transport.reason;
        }
        if (
          transport.action === "edit" &&
          transport.commandId &&
          this.store.transition(
            account,
            transport.commandId,
            "queued",
            "cancelled",
            { error: "Superseded by newer progress" },
          )
        ) {
          transport.receipts.push({
            commandId: transport.commandId,
            action: "edit",
            state: "cancelled",
          });
          transport.editAttempts = Math.max(0, transport.editAttempts - 1);
          delete transport.commandId;
          delete transport.action;
          delete transport.submittedText;
          delete transport.submittedRevision;
        }
        const at = this.now();
        const j = {
          ...current,
          state: input.state,
          detail: input.detail,
          fraction: input.fraction,
          revision: current.revision + 1,
          updatedAt: at,
          fileIds: input.fileIds,
          attachments: input.attachments,
        };
        j.history = [
          ...current.history,
          { revision: j.revision, state: j.state, detail: j.detail, at },
        ].slice(-100);
        return j;
      },
    );
  }
  tick() {
    const rows = this.store.db
      .prepare("SELECT body FROM progress_jobs WHERE active=1 ORDER BY rowid")
      .all() as { body: string }[];
    for (const row of rows) {
      const j = JSON.parse(row.body) as ProgressJob;
      this.store.db.exec("BEGIN IMMEDIATE");
      try {
        this.advance(j);
        // Idle ticks do not rewrite history/receipts into SQLite.
        if (JSON.stringify(j) !== row.body) this.write(j);
        this.store.db.exec("COMMIT");
      } catch (e) {
        this.store.db.exec("ROLLBACK");
        const original = JSON.parse(row.body) as ProgressJob;
        if (original.transport.commandId)
          this.store.transition(
            original.accountId,
            original.transport.commandId,
            "queued",
            "cancelled",
            { error: "Progress authorization or submission failed" },
          );
        original.transport.state = "failed";
        original.transport.reason =
          e instanceof PilotError
            ? e.message
            : "Progress dispatcher failed; inspect command receipts";
        this.write(original);
      }
    }
  }
  assertDispatch(c: Command) {
    if (!c.idempotencyKey.startsWith("progress:")) return;
    const id = c.idempotencyKey.split(":")[1];
    const row = this.store.db
      .prepare("SELECT body FROM progress_jobs WHERE account=? AND id=?")
      .get(c.accountId, id ?? "") as { body: string } | undefined;
    if (!row)
      throw new PilotError("forbidden", "Progress job no longer exists", 403);
    const j = JSON.parse(row.body) as ProgressJob;
    const actor = this.config.agents.find((a) => a.id === j.owner);
    if (!actor || j.transport.commandId !== c.id)
      throw new PilotError(
        "forbidden",
        "Progress command no longer authorized",
        403,
      );
    this.authorize(j.accountId, j.chatId, actor, true);
    if (actor.operations && !actor.operations.includes(c.operation))
      throw new PilotError("forbidden", "Progress operation revoked", 403);
    this.store.assertControl(c.accountId, actor.id);
  }
  private advance(j: ProgressJob) {
    const t = j.transport,
      now = this.now();
    const actor = this.config.agents.find((a) => a.id === j.owner);
    if (!actor) throw new PilotError("forbidden", "Creating agent removed");
    this.authorize(j.accountId, j.chatId, actor, true);
    if (t.commandId) {
      const c = this.store.get(j.accountId, t.commandId);
      if (!c)
        throw new PilotError("missing_command", "Progress command missing");
      if (["queued", "executing"].includes(c.state)) return;
      t.receipts.push({ commandId: c.id, action: t.action!, state: c.state });
      if (c.state === "outcome_unknown") {
        t.state = "outcome_unknown";
        t.reason =
          "Native action outcome unknown; reconcile before any further sends";
        return;
      }
      if (c.state !== "completed") {
        t.state = "failed";
        t.reason = c.error ?? "Native action failed; no blind retry";
        return;
      }
      if (t.action === "initial") {
        const r = c.result as any;
        const id =
          r?.message?.id ??
          r?.id ??
          (Array.isArray(r) && r.length === 1 ? r[0]?.id : undefined);
        if (typeof id !== "string" || !id) {
          t.state = "outcome_unknown";
          t.reason =
            "Send completed without a single verifiable message ID; no automatic edits or resend";
          return;
        }
        t.messageId = id;
        t.sentAt = c.createdAt;
        t.state = "watching";
      }
      if (t.action === "final_edit" || t.action === "final_send") {
        t.completedRevision = t.submittedRevision;
      }
      if (t.action === "attachment") t.attachmentIndex++;
      t.lastText = t.action === "attachment" ? t.lastText : t.submittedText;
      t.lastAt = now;
      delete t.commandId;
      delete t.action;
      delete t.submittedText;
      delete t.submittedRevision;
    }
    if (t.completedRevision) {
      if (t.attachmentIndex < j.attachments.length) {
        const attachment = j.attachments[t.attachmentIndex]!;
        this.queue(
          j,
          "attachment",
          "messages.send",
          { chatId: j.chatId, filePath: attachment.filePath },
          `attachment:${t.attachmentIndex}`,
        );
        return;
      }
      t.state = "complete";
      delete t.reason;
      return;
    }
    if (!t.messageId) {
      this.queue(
        j,
        "initial",
        "messages.send",
        { chatId: j.chatId, text: progressText(j) },
        "initial",
      );
      return;
    }
    const final = terminal(j.state),
      text = progressText(j);
    if (final && text === t.lastText) {
      t.completedRevision = j.revision;
      return;
    }
    // A one-minute margin accounts for worker queueing. The native adapter still enforces Apple's deadline.
    const editable =
      now - (t.sentAt ?? 0) < 14 * 60 * 1000 && t.editAttempts < 5;
    if (final) {
      if (editable) {
        this.queue(
          j,
          "final_edit",
          "messages.edit",
          { chatId: j.chatId, messageId: t.messageId, text },
          `final:${j.revision}`,
        );
        t.editAttempts++;
        return;
      }
      if (j.policy.finalFallback === "new_message" && !t.fallbackUsed) {
        this.queue(
          j,
          "final_send",
          "messages.send",
          { chatId: j.chatId, text },
          `final:${j.revision}`,
        );
        t.fallbackUsed = true;
        return;
      }
      t.state = "paused";
      t.reason =
        "Native edit budget/window exhausted; final message fallback disabled";
      return;
    }
    if (!editable || t.editAttempts >= j.policy.intermediateEdits) {
      t.state = "paused";
      t.reason =
        "Intermediate edit budget/window exhausted; final edit reserved when still eligible";
      return;
    }
    if (text === t.lastText || now - t.lastAt < j.policy.intervalMs) return;
    this.queue(
      j,
      "edit",
      "messages.edit",
      { chatId: j.chatId, messageId: t.messageId, text },
      `revision:${j.revision}`,
    );
    t.editAttempts++;
    t.state = "watching";
    delete t.reason;
  }
  private queue(
    j: ProgressJob,
    action: NonNullable<ProgressJob["transport"]["action"]>,
    operation: Operation,
    args: Record<string, unknown>,
    key: string,
  ) {
    const id = this.submit(j.accountId, j.owner, {
      operation,
      args,
      idempotencyKey: `progress:${j.id}:${key}`,
    });
    delete j.transport.reason;
    j.transport.state = "watching";
    j.transport.commandId = id;
    j.transport.action = action;
    j.transport.submittedRevision = j.revision;
    j.transport.submittedText =
      typeof args.text === "string" ? args.text : undefined;
  }
}
