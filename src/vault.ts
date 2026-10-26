import http, { type IncomingMessage, type ServerResponse } from "node:http";
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import { DatabaseSync } from "node:sqlite";

/**
 * Secure-input vault: a line asks a person for a secret (for example a CRM API key) through
 * an interactive iMessage bubble. The person's Messages extension posts the value here over
 * HTTPS with a one-time token from the bubble. The value is encrypted at rest and is never
 * returned to agents, never written to logs and never placed in the transcript. Agents see
 * only request status ("pending", "connected", "expired").
 *
 * The bubble URL is `${base}/v1/vault/r/<id>?label=…&state=pending#t=<token>`. The token rides in
 * the fragment: browsers never send it to a server, and only the extension (or the fallback
 * page's script) reads it.
 */
export type VaultRequest = {
  id: string;
  line: string;
  recipient: string;
  label: string;
  state: "pending" | "connected" | "expired";
  createdAt: number;
  expiresAt: number;
  connectedAt?: number;
  device?: string;
};

const b64url = (b: Buffer) => b.toString("base64url");
const hash = (s: string) => createHash("sha256").update(s).digest();

export class VaultService {
  private db: DatabaseSync;
  private key: Buffer;
  constructor(
    path: string,
    key: Buffer,
    private publicBase: string,
    private now = () => Date.now(),
  ) {
    if (key.length !== 32) throw new Error("Vault key must be 32 bytes");
    const base = new URL(publicBase);
    const loopback = ["127.0.0.1", "localhost", "[::1]"].includes(
      base.hostname,
    );
    if (base.protocol !== "https:" && !loopback)
      throw new Error("Vault base URL must be https (loopback excepted)");
    this.key = key;
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL;
      CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY, line TEXT NOT NULL, recipient TEXT NOT NULL,
        label TEXT NOT NULL, token_hash BLOB NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL, connected_at INTEGER, device TEXT, failures INTEGER NOT NULL DEFAULT 0,
        secret BLOB);`);
  }

  /** Mints a single-use request for one person. Returns the bubble URL (token in fragment). */
  create(input: {
    line: string;
    recipient: string;
    label: string;
    ttlSeconds?: number;
  }) {
    const label = input.label.trim();
    if (!label || label.length > 80)
      throw new Error("label must be 1–80 characters");
    const ttl = Math.min(Math.max(input.ttlSeconds ?? 900, 60), 24 * 3600);
    const id = b64url(randomBytes(12));
    const token = b64url(randomBytes(32));
    const created = this.now();
    this.db
      .prepare(
        "INSERT INTO requests(id,line,recipient,label,token_hash,state,created_at,expires_at) VALUES(?,?,?,?,?,'pending',?,?)",
      )
      .run(
        id,
        input.line,
        input.recipient,
        label,
        hash(token),
        created,
        created + ttl * 1000,
      );
    const url = new URL(`/v1/vault/r/${id}`, this.publicBase);
    // Percent-encoding (not "+") so Foundation's URLComponents decodes spaces in the extension.
    url.search = `?label=${encodeURIComponent(label)}&state=pending`;
    url.hash = `t=${token}`;
    return { id, url: url.toString(), expiresAt: created + ttl * 1000 };
  }

  status(id: string): VaultRequest | undefined {
    const r = this.db.prepare("SELECT * FROM requests WHERE id=?").get(id) as
      Record<string, any> | undefined;
    if (!r) return undefined;
    const expired = r.state === "pending" && r.expires_at <= this.now();
    return {
      id: r.id,
      line: r.line,
      recipient: r.recipient,
      label: r.label,
      state: expired ? "expired" : r.state,
      createdAt: r.created_at,
      expiresAt: r.expires_at,
      connectedAt: r.connected_at ?? undefined,
      device: r.device ?? undefined,
    };
  }

  /** Accepts the secret once. Errors never reveal whether the id or the token was wrong. */
  submit(input: { id: string; token: string; value: string; device?: string }) {
    const generic = new Error("Request is invalid, used or expired");
    if (
      typeof input.value !== "string" ||
      !input.value.length ||
      input.value.length > 8192
    )
      throw new Error("value must be 1–8192 characters");
    const r = this.db
      .prepare("SELECT * FROM requests WHERE id=?")
      .get(input.id) as Record<string, any> | undefined;
    if (
      !r ||
      r.state !== "pending" ||
      r.expires_at <= this.now() ||
      r.failures >= 5
    )
      throw generic;
    const ok =
      typeof input.token === "string" &&
      timingSafeEqual(
        hash(input.token),
        Buffer.from(r.token_hash as Uint8Array),
      );
    if (!ok) {
      this.db
        .prepare("UPDATE requests SET failures=failures+1 WHERE id=?")
        .run(input.id);
      throw generic;
    }
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", this.key, iv);
    cipher.setAAD(Buffer.from(input.id));
    const sealed = Buffer.concat([
      iv,
      cipher.update(input.value, "utf8"),
      cipher.final(),
      cipher.getAuthTag(),
    ]);
    const changed = this.db
      .prepare(
        "UPDATE requests SET state='connected', connected_at=?, device=?, secret=?, token_hash=X'' WHERE id=? AND state='pending'",
      )
      .run(this.now(), input.device?.slice(0, 64) ?? null, sealed, input.id);
    if (changed.changes !== 1) throw generic;
    return { state: "connected" as const, label: r.label as string };
  }

  /**
   * Server-side consumers (the integration that calls the CRM) read the value here. This is
   * deliberately not an HTTP route and not an agent operation.
   */
  reveal(id: string): string {
    const r = this.db
      .prepare("SELECT secret FROM requests WHERE id=? AND state='connected'")
      .get(id) as { secret: Uint8Array } | undefined;
    if (!r) throw new Error("No connected secret");
    const data = Buffer.from(r.secret);
    const decipher = createDecipheriv(
      "aes-256-gcm",
      this.key,
      data.subarray(0, 12),
    );
    decipher.setAAD(Buffer.from(id));
    decipher.setAuthTag(data.subarray(data.length - 16));
    return Buffer.concat([
      decipher.update(data.subarray(12, data.length - 16)),
      decipher.final(),
    ]).toString("utf8");
  }

  close() {
    this.db.close();
  }
}

const fallbackPage = (
  label: string,
) => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer">
<title>Secure connection</title><style>body{font:16px -apple-system,system-ui,sans-serif;margin:0;padding:24px;max-width:480px}
input,button{font:inherit;width:100%;box-sizing:border-box;padding:12px;margin-top:12px;border-radius:10px;border:1px solid #bbb}
button{background:#0a84ff;color:#fff;border:0}</style></head><body><h1>Connect ${label.replace(/[<>&"]/g, "")}</h1>
<p>Paste the value below. It goes straight to the service and never appears in the conversation.</p>
<form id="f"><input id="v" type="password" autocomplete="off" required aria-label="Secret value">
<button>Connect</button></form><p id="s" role="status"></p><script>
const t=new URLSearchParams(location.hash.slice(1)).get("t");history.replaceState(null,"",location.pathname+location.search);
const id=location.pathname.split("/").pop();
document.getElementById("f").onsubmit=async e=>{e.preventDefault();const v=document.getElementById("v");
const r=await fetch("/v1/vault/submit",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({id,token:t,value:v.value})});
v.value="";document.getElementById("s").textContent=r.ok?"Connected.":"This link is invalid, used or expired.";};
</script></body></html>`;

/** HTTP surface: submit (extension or fallback page), fallback page, and admin create/status. */
export function vaultHandler(vault: VaultService, adminToken: string) {
  if (adminToken.length < 32)
    throw new Error("Admin token must be at least 32 characters");
  const admin = hash(adminToken);
  const json = (res: ServerResponse, status: number, body: unknown) => {
    res.writeHead(status, {
      "content-type": "application/json",
      "cache-control": "no-store",
    });
    res.end(JSON.stringify(body));
  };
  const read = async (req: IncomingMessage) => {
    let size = 0;
    const chunks: Buffer[] = [];
    for await (const chunk of req) {
      size += (chunk as Buffer).length;
      if (size > 16384) throw new Error("Body too large");
      chunks.push(chunk as Buffer);
    }
    return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  };
  const isAdmin = (req: IncomingMessage) => {
    const given = (req.headers.authorization ?? "").replace(/^Bearer /, "");
    return timingSafeEqual(hash(given), admin);
  };
  return async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", "http://vault");
    try {
      if (req.method === "POST" && url.pathname === "/v1/vault/submit") {
        const body = await read(req);
        return json(res, 200, vault.submit(body));
      }
      const page = url.pathname.match(/^\/v1\/vault\/r\/([A-Za-z0-9_-]{16})$/);
      if (req.method === "GET" && page) {
        const status = vault.status(page[1]!);
        res.writeHead(status ? 200 : 404, {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "no-store",
          "content-security-policy":
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'none'",
        });
        return res.end(
          status?.state === "pending"
            ? fallbackPage(status.label)
            : "Not available",
        );
      }
      if (!isAdmin(req)) return json(res, 401, { error: "unauthorized" });
      if (req.method === "POST" && url.pathname === "/v1/vault/requests")
        return json(res, 201, vault.create(await read(req)));
      const one = url.pathname.match(
        /^\/v1\/vault\/requests\/([A-Za-z0-9_-]{16})$/,
      );
      if (req.method === "GET" && one) {
        const status = vault.status(one[1]!);
        return status
          ? json(res, 200, status)
          : json(res, 404, { error: "not_found" });
      }
      return json(res, 404, { error: "not_found" });
    } catch (error) {
      // Never echo request bodies; they may contain the secret.
      return json(res, 400, {
        error: String((error as Error).message ?? error).slice(0, 120),
      });
    }
  };
}

export function startVaultServer(
  vault: VaultService,
  adminToken: string,
  host = "127.0.0.1",
  port = 4390,
) {
  const handler = vaultHandler(vault, adminToken);
  const server = http.createServer((req, res) => void handler(req, res));
  return new Promise<http.Server>((resolve) =>
    server.listen(port, host, () => resolve(server)),
  );
}
