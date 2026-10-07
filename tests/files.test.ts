import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Gateway } from "../src/gateway.js";
import { configSchema } from "../src/protocol.js";
import { fileFormat } from "../src/file-formats.js";
async function setup(t: any, conversion?: any) {
  const dir = mkdtempSync(join(tmpdir(), "messagepilot-files-"));
  const gateway = new Gateway(
    configSchema.parse({
      database: ":memory:",
      host: "127.0.0.1",
      port: 0,
      files: {
        directory: dir,
        maxFileBytes: 4096,
        maxAccountBytes: 8192,
        conversion,
      },
      accounts: [
        {
          id: "a",
          identity: "a@example.test",
          workerTokenEnv: "W",
          allowedChatIds: ["self", "second"],
        },
        { id: "b", identity: "b@example.test", workerTokenEnv: "B" },
      ],
      agents: [
        { id: "a", tokenEnv: "A", accounts: ["a"], chats: { a: ["self"] } },
        { id: "b", tokenEnv: "C", accounts: ["b"] },
        { id: "no", tokenEnv: "N", accounts: ["a"], operations: [] },
      ],
    }),
    {
      W: "w".repeat(40),
      A: "a".repeat(40),
      B: "b".repeat(40),
      C: "c".repeat(40),
      N: "n".repeat(40),
    },
  );
  const port = await gateway.listen();
  const base = `http://127.0.0.1:${port}/v1/accounts`;
  const call = (
    path: string,
    init: RequestInit = {},
    token = "a",
    account = "a",
  ) =>
    fetch(`${base}/${account}/files${path}`, {
      ...init,
      headers: { authorization: `Bearer ${token.repeat(40)}`, ...init.headers },
    });
  const upload = (name: string, data: string, chatId = "self") =>
    call(`?${new URLSearchParams({ name, chatId })}`, {
      method: "POST",
      body: data,
    });
  t.after(async () => {
    await gateway.close();
    rmSync(dir, { force: true, recursive: true });
  });
  return { gateway, call, upload, dir };
}
test("all requested formats have read/display routes; unknown types remain opaque", () => {
  for (const ext of "pdf docx doc xlsx xls pptx ppt txt csv rtf pages jpg jpeg png gif webp heic svg tiff tif bmp mp4 mov avi mkv webm wmv mp3 wav m4a aac flac zip rar 7z tar gz html htm json xml".split(
    " ",
  ))
    assert.notEqual(fileFormat(`sample.${ext}`).category, "binary", ext);
  assert.equal(fileFormat("unknown.mystery").category, "binary");
});
test("binary uploads preserve bytes, metadata, ranges and exact chat isolation", async (t) => {
  const { call, upload } = await setup(t);
  const response = await upload("example.unknown", "abcdef");
  assert.equal(response.status, 201);
  const file = (await response.json()) as any;
  assert.equal(file.bytes, 6);
  assert.equal(file.sha256.length, 64);
  assert.equal(await (await call(`/${file.id}/download`)).text(), "abcdef");
  const range = await call(`/${file.id}/download`, {
    headers: { range: "bytes=1-3" },
  });
  assert.equal(range.status, 206);
  assert.equal(await range.text(), "bcd");
  assert.equal(
    (await call(`/${file.id}/download`, { headers: { range: "bytes=99-" } }))
      .status,
    416,
  );
  assert.equal(
    (await call(`/${file.id}/download`, { method: "HEAD" })).headers.get(
      "content-length",
    ),
    "6",
  );
  assert.equal((await upload("bad.txt", "x", "second")).status, 403);
  assert.equal((await call("?chatId=second")).status, 403);
  assert.equal((await call("?chatId=self", {}, "n")).status, 403);
  assert.equal((await call(`/${file.id}`, {}, "c", "b")).status, 404);
  assert.equal(
    (await call(`/${file.id}/prepare`, { method: "POST" })).status,
    409,
  );
  assert.equal((await call(`/${file.id}`, { method: "DELETE" })).status, 200);
  assert.equal((await call(`/${file.id}`)).status, 404);
});
test("upload validation rejects traversal, checksum mismatch and quota overflow", async (t) => {
  const { call, upload } = await setup(t);
  assert.equal((await upload("../oops.txt", "x")).status, 400);
  assert.equal((await upload("large.bin", "a".repeat(4097))).status, 413);
  assert.equal(
    (
      await call("?chatId=self&name=x.bin", {
        method: "POST",
        body: "abc",
        headers: { "x-content-sha256": "bad" },
      })
    ).status,
    400,
  );
  assert.equal((await upload("1.bin", "x".repeat(4096))).status, 201);
  assert.equal((await upload("2.bin", "x".repeat(4096))).status, 201);
  assert.equal((await upload("3.bin", "x")).status, 413);
});
test(
  "sandboxed HTML preview is escaped text and external file references are not followed",
  { skip: process.platform !== "darwin" },
  async (t) => {
    const { upload, call } = await setup(t, {
      python: "/usr/bin/python3",
      tools: {},
    });
    const source = '<script>alert(1)</script><img src="file:///etc/passwd">';
    const f = (await (await upload("test.html", source)).json()) as any;
    assert.equal(
      (await call(`/${f.id}/prepare`, { method: "POST" })).status,
      202,
    );
    let r: any;
    for (let i = 0; i < 100; i++) {
      r = await (await call(`/${f.id}`)).json();
      if (r.state !== "preparing") break;
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.equal(r.state, "ready", JSON.stringify(r));
    assert.equal(r.result.text, source);
    const preview = await call(`/${f.id}/preview`);
    assert.equal(preview.headers.get("content-type"), "text/plain");
    assert.equal(preview.headers.get("x-content-type-options"), "nosniff");
    assert.equal(await preview.text(), source);
  },
);
test(
  "conversion sandbox denies unrelated file reads, external writes and network",
  { skip: process.platform !== "darwin" },
  async (t) => {
    const { writeFile, chmod, readFile } = await import("node:fs/promises");
    const root = mkdtempSync(join(tmpdir(), "messagepilot-probe-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const marker = join(root, "private-marker"),
      probe = join(root, "probe.py"),
      outside = join(root, "escaped");
    await writeFile(marker, "private");
    await writeFile(
      probe,
      `#!/usr/bin/python3\nimport socket\nblocked=0\ntry:open(${JSON.stringify(marker)}).read()\nexcept PermissionError:blocked+=1\ntry:open(${JSON.stringify(outside)},'w').write('bad')\nexcept PermissionError:blocked+=1\ntry:socket.create_connection(('127.0.0.1',9),0.2)\nexcept PermissionError:blocked+=1\nprint('blocked='+str(blocked))\n`,
    );
    await chmod(probe, 0o700);
    const { upload, call } = await setup(t, {
      python: "/usr/bin/python3",
      tools: { textutil: probe },
    });
    const f = (await (await upload("probe.doc", "synthetic")).json()) as any;
    await call(`/${f.id}/prepare`, { method: "POST" });
    let r: any;
    for (let i = 0; i < 100; i++) {
      r = await (await call(`/${f.id}`)).json();
      if (r.state !== "preparing") break;
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.equal(r.result.text.trim(), "blocked=3", JSON.stringify(r));
  },
);
