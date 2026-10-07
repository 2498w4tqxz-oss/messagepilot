import { z } from "zod";
import { createHash } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import { PilotError } from "./errors.js";
export const analyticsPolicy = z.object({
  accountId: z.string(),
  chatIds: z.array(z.string()).min(1),
  observerAgentIds: z.array(z.string()).default([]),
  readerAgentIds: z.array(z.string()).min(1),
  retainDays: z.number().int().min(1).max(365).default(30),
  storeText: z.boolean().default(false),
  contextMessages: z.number().int().min(0).max(1000).default(50),
  contextCharacters: z.number().int().min(0).max(200000).default(12000),
});
export const analyticsEvent = z
  .object({
    sourceId: z.string().min(1).max(200),
    chatId: z.string().min(1).max(500),
    kind: z.enum([
      "message.sent",
      "message.received",
      "message.delivered",
      "message.read",
      "message.edited",
      "message.unsent",
      "reaction.added",
      "reaction.removed",
      "media.sent",
      "media.received",
      "extension.action",
      "extension.opened",
      "extension.closed",
      "context.used",
      "command.accepted",
      "command.completed",
      "command.failed",
      "command.unknown",
    ]),
    occurredAt: z.number().int().nonnegative(),
    messageId: z.string().max(200).optional(),
    source: z.enum(["native", "extension", "agent", "fixture"]),
    reaction: z.string().max(80).optional(),
    media: z
      .enum([
        "image",
        "video",
        "audio",
        "gif",
        "sticker",
        "document",
        "archive",
        "other",
      ])
      .optional(),
    count: z.number().int().min(1).max(1000).default(1),
    action: z.string().max(100).optional(),
    characters: z.number().int().nonnegative().max(10000000).optional(),
    tokens: z.number().int().nonnegative().max(10000000).optional(),
    text: z.string().max(20000).optional(),
  })
  .strict();
export class Analytics {
  constructor(
    private db: DatabaseSync,
    private policies: z.infer<typeof analyticsPolicy>[],
  ) {
    if (new Set(policies.map((p) => p.accountId)).size !== policies.length)
      throw new Error("One analytics policy per account");
    db.exec(
      `CREATE TABLE IF NOT EXISTS analytics_events(account TEXT NOT NULL,chat TEXT NOT NULL,source_id TEXT NOT NULL,kind TEXT NOT NULL,occurred INTEGER NOT NULL,observed INTEGER NOT NULL,value TEXT NOT NULL,hash TEXT NOT NULL,PRIMARY KEY(account,chat,source_id)); CREATE INDEX IF NOT EXISTS analytics_time ON analytics_events(account,chat,occurred);`,
    );
  }
  policy(
    account: string,
    chat: string,
    agent: string,
    mode: "read" | "observe",
    scope: string[] | undefined,
  ) {
    const p = this.policies.find(
      (p) => p.accountId === account && p.chatIds.includes(chat),
    );
    if (
      !p ||
      (scope !== undefined && !scope.includes(chat)) ||
      !(mode === "read" ? p.readerAgentIds : p.observerAgentIds).includes(agent)
    )
      throw new PilotError(
        "forbidden",
        "Analytics is disabled or not granted for this chat",
        403,
      );
    return p;
  }
  sweep() {
    for (const p of this.policies) this.purge(p);
  }
  private purge(p: z.infer<typeof analyticsPolicy>) {
    this.db
      .prepare("DELETE FROM analytics_events WHERE account=? AND occurred<?")
      .run(p.accountId, Date.now() - p.retainDays * 86400000);
  }
  observe(
    p: z.infer<typeof analyticsPolicy>,
    event: z.infer<typeof analyticsEvent>,
  ) {
    if (!p.chatIds.includes(event.chatId))
      throw new PilotError("chat_forbidden", "Analytics chat mismatch", 403);
    if (
      event.occurredAt > Date.now() + 60000 ||
      event.occurredAt < Date.now() - p.retainDays * 86400000
    )
      throw new PilotError(
        "invalid_timestamp",
        "Event outside retention window or in future",
      );
    if (event.kind.startsWith("reaction.") && !event.reaction)
      throw new PilotError("invalid_event", "Reaction type required");
    if (event.kind.startsWith("media.") && !event.media)
      throw new PilotError("invalid_event", "Media type required");
    if (event.kind.startsWith("message.") && !event.messageId)
      throw new PilotError(
        "invalid_event",
        "Stable messageId required for message events",
      );
    this.purge(p);
    const sanitized = {
      ...event,
      ...(!p.storeText ? { text: undefined } : {}),
    };
    const value = JSON.stringify(sanitized),
      hash = createHash("sha256").update(value).digest("hex");
    const old = this.db
      .prepare(
        "SELECT hash FROM analytics_events WHERE account=? AND chat=? AND source_id=?",
      )
      .get(p.accountId, event.chatId, event.sourceId) as
      { hash: string } | undefined;
    if (old && old.hash !== hash)
      throw new PilotError(
        "idempotency_conflict",
        "Observation ID has different data",
        409,
      );
    if (!old)
      this.db
        .prepare("INSERT INTO analytics_events VALUES(?,?,?,?,?,?,?,?)")
        .run(
          p.accountId,
          event.chatId,
          event.sourceId,
          event.kind,
          event.occurredAt,
          Date.now(),
          value,
          hash,
        );
    return {
      recorded: true,
      duplicate: !!old,
      textStored: p.storeText && event.text !== undefined,
    };
  }
  /** Passive command telemetry has gateway timestamps; it is never called a native message/read receipt. */
  command(
    account: string,
    chat: string | undefined,
    id: string,
    state: string,
    operation: string,
  ) {
    if (!chat) return;
    const p = this.policies.find(
      (p) => p.accountId === account && p.chatIds.includes(chat),
    );
    if (!p) return;
    const kind =
      state === "accepted"
        ? "command.accepted"
        : state === "completed"
          ? "command.completed"
          : state === "outcome_unknown"
            ? "command.unknown"
            : "command.failed";
    if (
      this.db
        .prepare(
          "SELECT 1 FROM analytics_events WHERE account=? AND chat=? AND source_id=?",
        )
        .get(account, chat, `command:${id}:${state}`)
    )
      return;
    this.observe(p, {
      sourceId: `command:${id}:${state}`,
      chatId: chat,
      kind,
      occurredAt: Date.now(),
      source: "agent",
      count: 1,
      action: operation,
    });
  }
  private rows(
    p: z.infer<typeof analyticsPolicy>,
    chat: string,
    since: number,
    until: number,
  ) {
    this.purge(p);
    return (
      this.db
        .prepare(
          "SELECT value,observed FROM analytics_events WHERE account=? AND chat=? AND occurred>=? AND occurred<=? ORDER BY occurred,source_id LIMIT 50001",
        )
        .all(p.accountId, chat, since, until) as {
        value: string;
        observed: number;
      }[]
    ).map((r) => ({ ...JSON.parse(r.value), observedAt: r.observed }));
  }
  events(
    p: z.infer<typeof analyticsPolicy>,
    chat: string,
    since: number,
    until: number,
  ) {
    this.purge(p);
    return (
      this.db
        .prepare(
          "SELECT value,observed FROM analytics_events WHERE account=? AND chat=? AND occurred>=? AND occurred<=? ORDER BY occurred DESC LIMIT 200",
        )
        .all(p.accountId, chat, since, until) as {
        value: string;
        observed: number;
      }[]
    ).map((r) => {
      const event = JSON.parse(r.value);
      if (!p.storeText) delete event.text;
      return { ...event, observedAt: r.observed };
    });
  }
  report(
    p: z.infer<typeof analyticsPolicy>,
    chat: string,
    since: number,
    until: number,
  ) {
    const rows = this.rows(p, chat, since, until);
    if (rows.length > 50000)
      throw new PilotError("too_large", "Narrow analytics time range", 413);
    const counts: Record<string, number> = Object.create(null),
      reactions: Record<string, { added: number; removed: number }> =
        Object.create(null),
      media: Record<string, number> = Object.create(null),
      actions: Record<string, number> = Object.create(null),
      sources: Record<string, number> = Object.create(null);
    const sent = new Map<string, number>(),
      read = new Map<string, number>(),
      delivered = new Map<string, number>();
    for (const e of rows) {
      counts[e.kind] = (counts[e.kind] ?? 0) + e.count;
      sources[e.source] = (sources[e.source] ?? 0) + 1;
      if (e.kind.startsWith("reaction.")) {
        const r = reactions[e.reaction] ?? { added: 0, removed: 0 };
        r[e.kind === "reaction.added" ? "added" : "removed"] += e.count;
        Object.defineProperty(reactions, e.reaction, {
          value: r,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
      if (e.media)
        Object.defineProperty(media, `${e.kind}:${e.media}`, {
          value: (media[`${e.kind}:${e.media}`] ?? 0) + e.count,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      if (e.action)
        Object.defineProperty(actions, e.action, {
          value:
            (Object.hasOwn(actions, e.action) ? actions[e.action] : 0) +
            e.count,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      const map =
        e.kind === "message.sent"
          ? sent
          : e.kind === "message.read"
            ? read
            : e.kind === "message.delivered"
              ? delivered
              : undefined;
      if (map && e.messageId)
        map.set(
          e.messageId,
          Math.min(map.get(e.messageId) ?? Infinity, e.occurredAt),
        );
    }
    const latency = (target: Map<string, number>) => {
      const values = [...sent]
        .flatMap(([id, t]) =>
          target.has(id) && target.get(id)! >= t ? [target.get(id)! - t] : [],
        )
        .sort((a, b) => a - b);
      return {
        samples: values.length,
        meanMs: values.length
          ? values.reduce((a, b) => a + b, 0) / values.length
          : null,
        p50Ms: values.length
          ? values[Math.ceil(values.length * 0.5) - 1]
          : null,
        p95Ms: values.length
          ? values[Math.ceil(values.length * 0.95) - 1]
          : null,
        unmatchedSent: sent.size - values.length,
      };
    };
    return {
      chatId: chat,
      since,
      until,
      observationCount: rows.length,
      counts,
      reactions,
      media,
      actions,
      sources,
      readLatency: latency(read),
      deliveryLatency: latency(delivered),
      messagesPerHour:
        ((counts["message.sent"] ?? 0) + (counts["message.received"] ?? 0)) /
        Math.max((until - since) / 3600000, 1 / 3600),
      contextUsage: {
        observations: rows.filter((e) => e.kind === "context.used").length,
        reportedCharacters: rows
          .filter((e) => e.kind === "context.used")
          .reduce((n, e) => n + (e.characters ?? 0), 0),
        reportedTokens: rows
          .filter((e) => e.kind === "context.used")
          .reduce((n, e) => n + (e.tokens ?? 0), 0),
        tokenObservations: rows.filter(
          (e) => e.kind === "context.used" && e.tokens !== undefined,
        ).length,
      },
      contextPolicy: {
        messages: p.contextMessages,
        characters: p.contextCharacters,
        textStored: p.storeText,
      },
      limitations: [
        "Counts describe observed events, not complete inbox history.",
        "Reaction adds/removes are event totals, not current per-message inventory.",
        "Read latency requires matching explicit receipt and sent timestamps inside this query window.",
        "Sources are collector-reported; agent and fixture observations are not Apple attestations.",
      ],
    };
  }
  context(p: z.infer<typeof analyticsPolicy>, chat: string) {
    this.purge(p);
    if (!p.storeText || !p.contextMessages || !p.contextCharacters)
      return {
        messages: [],
        characters: 0,
        policy: {
          maxMessages: p.contextMessages,
          maxCharacters: p.contextCharacters,
        },
        textCollectionEnabled: p.storeText,
      };
    const rows = this.db
      .prepare(
        "SELECT value FROM analytics_events WHERE account=? AND chat=? AND kind IN ('message.sent','message.received','message.edited','message.unsent') ORDER BY occurred DESC LIMIT 2000",
      )
      .all(p.accountId, chat) as { value: string }[];
    const messages: any[] = [];
    let characters = 0;
    const seen = new Set<string>();
    for (const row of rows) {
      const e = JSON.parse(row.value);
      if (seen.has(e.messageId)) continue;
      seen.add(e.messageId);
      if (e.kind === "message.unsent" || !e.text) continue;
      if (
        messages.length >= p.contextMessages ||
        characters + e.text.length > p.contextCharacters
      )
        break;
      messages.push({
        messageId: e.messageId,
        direction: e.kind,
        occurredAt: e.occurredAt,
        text: e.text,
        source: e.source,
      });
      characters += e.text.length;
    }
    return {
      messages: messages.reverse(),
      characters,
      policy: {
        maxMessages: p.contextMessages,
        maxCharacters: p.contextCharacters,
      },
      textCollectionEnabled: true,
    };
  }
}
