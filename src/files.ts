import { createHash, randomUUID } from "node:crypto";
import {
  createReadStream,
  mkdirSync,
  realpathSync,
  chmodSync,
  existsSync,
} from "node:fs";
import {
  mkdir,
  mkdtemp,
  open,
  rm,
  copyFile,
  writeFile,
  readFile,
  stat,
} from "node:fs/promises";
import { resolve, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { pipeline } from "node:stream/promises";
import type { DatabaseSync } from "node:sqlite";
import type { IncomingMessage, ServerResponse } from "node:http";
import { PilotError, type Config } from "./protocol.js";
import { fileFormat } from "./file-formats.js";
export type FileRecord = {
  id: string;
  account: string;
  chat: string;
  name: string;
  bytes: number;
  sha256: string;
  state: string;
  created: number;
  result: string | null;
};
export class Files {
  readonly directory: string;
  private converting = new Map<string, Promise<void>>();
  private busy = false;
  constructor(
    private db: DatabaseSync,
    private config: NonNullable<Config["files"]>,
  ) {
    mkdirSync(config.directory, { recursive: true, mode: 0o700 });
    this.directory = realpathSync(config.directory);
    chmodSync(this.directory, 0o700);
    db.exec(
      `CREATE TABLE IF NOT EXISTS bridge_files(id TEXT PRIMARY KEY, account TEXT NOT NULL, chat TEXT NOT NULL, name TEXT NOT NULL, bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, state TEXT NOT NULL, created INTEGER NOT NULL, result TEXT); CREATE INDEX IF NOT EXISTS bridge_files_scope ON bridge_files(account,chat);`,
    );
    // A single gateway owns this database. Interrupted uploads do not expose partial bytes.
    const stale = db
      .prepare("SELECT id FROM bridge_files WHERE state='uploading'")
      .all() as { id: string }[];
    for (const row of stale)
      void rm(join(this.directory, row.id), { recursive: true, force: true });
    db.exec(
      "DELETE FROM bridge_files WHERE state='uploading'; UPDATE bridge_files SET state='stored' WHERE state='preparing'",
    );
  }
  private scope(chat: string, scope: string[] | undefined) {
    if (!chat || chat.length > 500)
      throw new PilotError("invalid_chat", "Exact chatId required");
    if (scope !== undefined && !scope.includes(chat))
      throw new PilotError(
        "chat_forbidden",
        "Chat is outside the credential scope",
        403,
      );
  }
  get(account: string, id: string, scope: string[] | undefined) {
    const r = this.db
      .prepare("SELECT * FROM bridge_files WHERE account=? AND id=?")
      .get(account, id) as FileRecord | undefined;
    if (!r || r.state === "uploading")
      throw new PilotError("not_found", "File not found", 404);
    this.scope(r.chat, scope);
    return r;
  }
  manifest(r: FileRecord) {
    return {
      id: r.id,
      chatId: r.chat,
      name: r.name,
      bytes: r.bytes,
      sha256: r.sha256,
      state: r.state,
      createdAt: r.created,
      format: fileFormat(r.name),
      result: r.result ? JSON.parse(r.result) : null,
    };
  }
  list(account: string, chat: string, scope: string[] | undefined) {
    this.scope(chat, scope);
    return (
      this.db
        .prepare(
          "SELECT * FROM bridge_files WHERE account=? AND chat=? AND state!='uploading' ORDER BY created DESC LIMIT 200",
        )
        .all(account, chat) as FileRecord[]
    ).map((r) => this.manifest(r));
  }
  async upload(
    account: string,
    chat: string,
    name: string,
    scope: string[] | undefined,
    req: IncomingMessage,
  ) {
    this.scope(chat, scope);
    if (
      !name ||
      name.length > 240 ||
      /[\x00-\x1f\x7f/\\]/.test(name) ||
      name === "." ||
      name === ".."
    )
      throw new PilotError(
        "invalid_name",
        "Use a filename without paths or control characters",
      );
    const length = req.headers["content-length"];
    if (typeof length !== "string" || !/^\d+$/.test(length))
      throw new PilotError("length_required", "Content-Length required", 411);
    const bytes = Number(length);
    if (!Number.isSafeInteger(bytes) || bytes > this.config.maxFileBytes)
      throw new PilotError(
        "too_large",
        "File exceeds configured size limit",
        413,
      );
    const used = (
      this.db
        .prepare(
          "SELECT COALESCE(SUM(bytes),0) AS n FROM bridge_files WHERE account=?",
        )
        .get(account) as { n: number }
    ).n;
    if (used + bytes > this.config.maxAccountBytes)
      throw new PilotError("quota", "Account storage quota exceeded", 413);
    const id = randomUUID(),
      dir = join(this.directory, id);
    this.db
      .prepare("INSERT INTO bridge_files VALUES(?,?,?,?,?,?,?,?,NULL)")
      .run(id, account, chat, name, bytes, "", "uploading", Date.now());
    try {
      await mkdir(dir, { mode: 0o700 });
      const fd = await open(join(dir, "original"), "wx", 0o600);
      const hash = createHash("sha256");
      let size = 0;
      try {
        for await (const chunk of req) {
          size += chunk.length;
          if (size > bytes)
            throw new PilotError(
              "too_large",
              "Body exceeds declared length",
              413,
            );
          hash.update(chunk);
          await fd.writeFile(chunk);
        }
        if (size !== bytes)
          throw new PilotError("invalid_length", "Incomplete upload");
      } finally {
        await fd.close();
      }
      const sha256 = hash.digest("hex");
      if (
        req.headers["x-content-sha256"] &&
        req.headers["x-content-sha256"] !== sha256
      )
        throw new PilotError("checksum", "SHA-256 mismatch");
      this.db
        .prepare("UPDATE bridge_files SET sha256=?, state='stored' WHERE id=?")
        .run(sha256, id);
      return this.manifest(this.get(account, id, scope));
    } catch (e) {
      this.db.prepare("DELETE FROM bridge_files WHERE id=?").run(id);
      await rm(dir, { recursive: true, force: true });
      throw e;
    }
  }
  async remove(r: FileRecord) {
    if (this.converting.has(r.id))
      throw new PilotError("busy", "File is being prepared", 409);
    await rm(join(this.directory, r.id), { recursive: true, force: true });
    this.db.prepare("DELETE FROM bridge_files WHERE id=?").run(r.id);
  }
  prepare(r: FileRecord) {
    if (r.result || this.converting.has(r.id)) return;
    if (!this.config.conversion)
      throw new PilotError(
        "disabled",
        "Configure sandboxed conversion; original download remains available",
        409,
      );
    if (this.busy)
      throw new PilotError(
        "busy",
        "Another conversion is running; retry later",
        409,
      );
    if (process.platform !== "darwin")
      throw new PilotError(
        "unsupported",
        "This converter requires the macOS sandbox",
        409,
      );
    this.busy = true;
    this.db
      .prepare("UPDATE bridge_files SET state='preparing' WHERE id=?")
      .run(r.id);
    const task = this.convert(r)
      .catch(() => {
        this.db
          .prepare(
            "UPDATE bridge_files SET state='unavailable', result=? WHERE id=?",
          )
          .run(
            JSON.stringify({
              status: "unavailable",
              text: "",
              metadata: {},
              preview: null,
              warnings: [
                "Conversion failed or exceeded limits; original retained",
              ],
            }),
            r.id,
          );
      })
      .finally(() => {
        this.busy = false;
        this.converting.delete(r.id);
      });
    this.converting.set(r.id, task);
  }
  private async convert(r: FileRecord) {
    const job = join(this.directory, r.id, "preview");
    await mkdir(job, { recursive: true, mode: 0o700 });
    const ext = fileFormat(r.name).extension;
    const safeExt = /^[a-z0-9]{1,12}$/.test(ext) ? ext : "bin";
    await copyFile(
      join(this.directory, r.id, "original"),
      join(job, `input.${safeExt}`),
    );
    await copyFile(
      fileURLToPath(new URL("../scripts/file-converter.py", import.meta.url)),
      join(job, "convert.py"),
    );
    await writeFile(
      join(job, "tools.json"),
      JSON.stringify(this.config.conversion!.tools),
    );
    // LibreOffice's IPC socket needs a short path, distinct from every other job.
    const socketDirectory = await mkdtemp("/private/tmp/mp-");
    try {
      // Deny IP networking and personal data; permit local Unix IPC for Office only.
      const q = (s: string) => JSON.stringify(s);
      const roots = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/Library",
        "/opt",
        "/private/var/db",
        "/private/etc",
        "/private/preboot",
        "/dev",
        "/Applications/Xcode.app",
        "/Applications/LibreOffice.app",
        job,
        socketDirectory,
      ];
      const toolPaths = [
        this.config.conversion!.python,
        ...Object.values(this.config.conversion!.tools),
      ]
        .filter(existsSync)
        .map((p) => realpathSync(p));
      const profile = `(version 1)(allow default)(deny network*)${this.config.conversion!.tools.soffice ? "(allow network* (local unix-socket) (remote unix-socket))" : ""}(deny file-read-data (require-all (require-not (literal "/")) ${toolPaths.map((p) => `(require-not (literal ${q(p)}))`).join(" ")} ${roots.map((p) => `(require-not (subpath ${q(p)}))`).join(" ")}))(deny file-write* (require-all (require-not (subpath ${q(job)})) (require-not (subpath ${q(socketDirectory)})) (require-not (literal "/dev/null"))))`;

      await writeFile(join(job, "sandbox.sb"), profile);
      await new Promise<void>((ok, no) => {
        const child = spawn(
          "/usr/bin/sandbox-exec",
          [
            "-f",
            join(job, "sandbox.sb"),
            this.config.conversion!.python,
            join(job, "convert.py"),
            job,
            safeExt,
          ],
          {
            cwd: job,
            detached: true,
            stdio: "ignore",
            env: {
              PATH: "/usr/bin:/bin:/opt/homebrew/bin",
              HOME: job,
              TMPDIR: job,
              OSL_SOCKET_PATH: socketDirectory,
              LANG: "en_US.UTF-8",
              PYTHONDONTWRITEBYTECODE: "1",
            },
          },
        );
        const kill = () => {
          if (child.pid)
            try {
              process.kill(-child.pid, "SIGKILL");
            } catch {}
        };
        const timer = setTimeout(() => {
          kill();
          no(new Error("timeout"));
        }, 95000);
        child.on("error", (e) => {
          clearTimeout(timer);
          kill();
          no(e);
        });
        child.on("exit", (code) => {
          clearTimeout(timer);
          kill();
          code === 0 ? ok() : no(new Error("converter failed"));
        });
      });
      const output = join(job, "result.json");
      if ((await stat(output)).size > 2 * 1024 * 1024)
        throw new Error("oversized result");
      const result = JSON.parse(await readFile(output, "utf8"));
      if (
        result.preview &&
        (basename(result.preview) !== result.preview ||
          !/\.(pdf|png|jpg|txt|mp4|m4a)$/.test(result.preview))
      )
        throw new Error("invalid preview");
      this.db
        .prepare("UPDATE bridge_files SET state=?,result=? WHERE id=?")
        .run(result.status, JSON.stringify(result), r.id);
      // Keep only the selected derivative. Drop copied original, profiles and scratch output.
      const { readdir } = await import("node:fs/promises");
      for (const name of await readdir(job))
        if (name !== result.preview)
          await rm(join(job, name), { recursive: true, force: true });
    } finally {
      await rm(socketDirectory, { recursive: true, force: true });
    }
  }
  async stream(
    r: FileRecord,
    preview: boolean,
    req: IncomingMessage,
    res: ServerResponse,
  ) {
    const result = r.result ? JSON.parse(r.result) : null;
    if (preview && !result?.preview)
      throw new PilotError(
        "not_ready",
        "No preview available; prepare or download original",
        409,
      );
    const name = preview ? result.preview : r.name,
      path = preview
        ? join(this.directory, r.id, "preview", result.preview)
        : join(this.directory, r.id, "original");
    const size = (await stat(path)).size;
    let start = 0,
      end = size - 1,
      status = 200;
    const range = req.headers.range;
    if (range) {
      const m = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (!m || (!m[1] && !m[2]) || size === 0) {
        res.writeHead(416, { "content-range": `bytes */${size}` });
        res.end();
        return;
      }
      if (!m[1]) {
        start = Math.max(0, size - Number(m[2]));
      } else {
        start = Number(m[1]);
        if (m[2]) end = Math.min(end, Number(m[2]));
      }
      if (
        !Number.isSafeInteger(start) ||
        !Number.isSafeInteger(end) ||
        start > end ||
        start >= size
      ) {
        res.writeHead(416, { "content-range": `bytes */${size}` });
        res.end();
        return;
      }
      status = 206;
    }
    const mime = preview ? fileFormat(name).mime : "application/octet-stream";
    res.writeHead(status, {
      "content-type": mime,
      "content-length": Math.max(0, end - start + 1),
      "content-disposition": `${preview ? "inline" : "attachment"}; filename*=UTF-8''${encodeURIComponent(name).replace(/'/g, "%27")}`,
      "x-content-type-options": "nosniff",
      "content-security-policy": "sandbox; default-src 'none'",
      "cache-control": "no-store",
      "accept-ranges": "bytes",
      ...(status === 206
        ? { "content-range": `bytes ${start}-${end}/${size}` }
        : {}),
    });
    if (req.method === "HEAD" || size === 0) {
      res.end();
      return;
    }
    await pipeline(createReadStream(path, { start, end }), res);
  }
  async close() {
    await Promise.all(this.converting.values());
  }
}
