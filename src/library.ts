import { z } from "zod";
import { randomUUID, createHash } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import { PilotError } from "./errors.js";
export const assetInput = z
  .object({
    chatId: z.string().min(1).max(500),
    idempotencyKey: z.string().min(1).max(200),
    expectedRevision: z.number().int().nonnegative().default(0),
    title: z.string().min(1).max(300),
    kind: z.string().min(1).max(80),
    tags: z.array(z.string().min(1).max(80)).max(30).default([]),
    content: z.unknown(),
    fileIds: z.array(z.string().uuid()).max(100).default([]),
    provenance: z
      .object({
        agent: z.string().max(200).optional(),
        model: z.string().max(200).optional(),
        source: z.string().max(1000).optional(),
        parentAssetId: z.string().uuid().optional(),
      })
      .strict()
      .optional(),
  })
  .strict();
export type AssetInput = z.infer<typeof assetInput>;
export type LibraryScope = { accountId: string; chatId: string };
export type AssetVersion = {
  id: string;
  revision: number;
  createdAt: number;
  actor: string;
  value: AssetInput;
};
/** Implement this contract with your own database. Every method receives an authenticated scope. */
export interface LibraryProvider {
  list(scope: LibraryScope): Promise<AssetVersion[]>;
  get(
    scope: LibraryScope,
    id: string,
    revision?: number,
  ): Promise<AssetVersion | undefined>;
  save(
    scope: LibraryScope,
    id: string | undefined,
    value: AssetInput,
    actor: string,
  ): Promise<AssetVersion>;
}
export class SQLiteLibrary implements LibraryProvider {
  constructor(private db: DatabaseSync) {
    db.exec(
      `CREATE TABLE IF NOT EXISTS library_versions(account TEXT NOT NULL,chat TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,created INTEGER NOT NULL,actor TEXT NOT NULL,value TEXT NOT NULL,idem TEXT NOT NULL,hash TEXT NOT NULL,PRIMARY KEY(account,chat,id,revision),UNIQUE(account,chat,idem));`,
    );
  }
  private row(r: any): AssetVersion | undefined {
    return r
      ? {
          id: r.id,
          revision: r.revision,
          createdAt: r.created,
          actor: r.actor,
          value: JSON.parse(r.value),
        }
      : undefined;
  }
  async list(s: LibraryScope) {
    return this.db
      .prepare(
        "SELECT v.* FROM library_versions v WHERE account=? AND chat=? AND revision=(SELECT MAX(revision) FROM library_versions x WHERE x.account=v.account AND x.chat=v.chat AND x.id=v.id) ORDER BY created DESC LIMIT 200",
      )
      .all(s.accountId, s.chatId)
      .map((r) => this.row(r)!);
  }
  async get(s: LibraryScope, id: string, revision?: number) {
    return this.row(
      revision === undefined
        ? this.db
            .prepare(
              "SELECT * FROM library_versions WHERE account=? AND chat=? AND id=? ORDER BY revision DESC LIMIT 1",
            )
            .get(s.accountId, s.chatId, id)
        : this.db
            .prepare(
              "SELECT * FROM library_versions WHERE account=? AND chat=? AND id=? AND revision=?",
            )
            .get(s.accountId, s.chatId, id, revision),
    );
  }
  async save(
    s: LibraryScope,
    id: string | undefined,
    value: AssetInput,
    actor: string,
  ) {
    if (value.chatId !== s.chatId)
      throw new PilotError("chat_forbidden", "Asset chat mismatch", 403);
    const serialized = JSON.stringify(value);
    if (Buffer.byteLength(serialized) > 512 * 1024)
      throw new PilotError(
        "too_large",
        "Asset metadata/content limit is 512 KiB; store larger content as files",
        413,
      );
    const canonical = (v: any): any =>
      Array.isArray(v)
        ? v.map(canonical)
        : v && typeof v === "object"
          ? Object.fromEntries(
              Object.keys(v)
                .sort()
                .map((k) => [k, canonical(v[k])]),
            )
          : v;
    const hash = createHash("sha256")
      .update(JSON.stringify(canonical({ id: id ?? null, value, actor })))
      .digest("hex");
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const previous = this.db
        .prepare(
          "SELECT * FROM library_versions WHERE account=? AND chat=? AND idem=?",
        )
        .get(s.accountId, s.chatId, value.idempotencyKey) as any;
      if (previous) {
        if (previous.hash !== hash)
          throw new PilotError(
            "idempotency_conflict",
            "Key used for different content",
            409,
          );
        this.db.exec("COMMIT");
        return this.row(previous)!;
      }
      const current = id
        ? (
            this.db
              .prepare(
                "SELECT MAX(revision) AS n FROM library_versions WHERE account=? AND chat=? AND id=?",
              )
              .get(s.accountId, s.chatId, id) as { n: number | null }
          ).n
        : null;
      if (
        (id && !current) ||
        (!id && value.expectedRevision !== 0) ||
        (current ?? 0) !== value.expectedRevision
      )
        throw new PilotError(
          "revision_conflict",
          "Asset missing or revision changed",
          409,
        );
      const result = {
        id: id ?? randomUUID(),
        revision: (current ?? 0) + 1,
        createdAt: Date.now(),
        actor,
        value,
      };
      this.db
        .prepare("INSERT INTO library_versions VALUES(?,?,?,?,?,?,?,?,?)")
        .run(
          s.accountId,
          s.chatId,
          result.id,
          result.revision,
          result.createdAt,
          actor,
          serialized,
          value.idempotencyKey,
          hash,
        );
      this.db.exec("COMMIT");
      return result;
    } catch (e) {
      this.db.exec("ROLLBACK");
      throw e;
    }
  }
}
/** Developer-hosted adapter: implement this small HTTP contract over any local/cloud database. */
export class HTTPLibrary implements LibraryProvider {
  constructor(
    private url: string,
    private token: string,
    private fetcher: typeof fetch = fetch,
  ) {
    const u = new URL(url);
    if (
      u.protocol !== "https:" ||
      u.username ||
      u.password ||
      u.search ||
      u.hash
    )
      throw new Error("Library provider requires a credential-free HTTPS URL");
    if (!token || token.length < 32)
      throw new Error("Library provider token missing/too short");
  }
  private async call(action: string, scope: LibraryScope, data: unknown) {
    const r = await this.fetcher(this.url, {
      method: "POST",
      redirect: "error",
      headers: {
        authorization: `Bearer ${this.token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ version: 1, action, scope, data }),
      signal: AbortSignal.timeout(15000),
    });
    if (!r.ok)
      throw new PilotError(
        r.status === 409 ? "revision_conflict" : "provider_error",
        "Library provider failed",
        r.status === 409 ? 409 : 502,
      );
    const chunks: Uint8Array[] = [];
    let n = 0;
    for await (const chunk of r.body! as any) {
      n += chunk.length;
      if (n > 2 * 1024 * 1024)
        throw new PilotError(
          "provider_error",
          "Library response exceeds limit",
          502,
        );
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString());
  }
  async list(scope: LibraryScope) {
    return this.call("list", scope, {});
  }
  async get(scope: LibraryScope, id: string, revision?: number) {
    return (await this.call("get", scope, { id, revision })) ?? undefined;
  }
  async save(
    scope: LibraryScope,
    id: string | undefined,
    value: AssetInput,
    actor: string,
  ) {
    return this.call("save", scope, { id, value, actor });
  }
}
