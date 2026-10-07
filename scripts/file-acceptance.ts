import { Gateway } from "../src/gateway.js";
import { configSchema } from "../src/protocol.js";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
const gateway = new Gateway(
  configSchema.parse({
    database: ":memory:",
    host: "127.0.0.1",
    port: 0,
    files: {
      directory: resolve("work/file-fixtures/storage"),
      conversion: {
        python: "/opt/homebrew/bin/python3",
        tools: {
          image: resolve("native/.build/messagepilot-image"),
          textutil: "/usr/bin/textutil",
          soffice: "/opt/homebrew/bin/soffice",
          pdftotext: "/opt/homebrew/bin/pdftotext",
          ffmpeg: "/opt/homebrew/bin/ffmpeg",
          ffprobe: "/opt/homebrew/bin/ffprobe",
          sips: "/usr/bin/sips",
          magick: "/opt/homebrew/bin/magick",
          tar: "/usr/bin/tar",
        },
      },
    },
    accounts: [
      {
        id: "fixture",
        identity: "fixture@example.test",
        workerTokenEnv: "W",
        allowedChatIds: ["fixture"],
      },
    ],
    agents: [
      {
        id: "fixture",
        tokenEnv: "A",
        accounts: ["fixture"],
        chats: { fixture: ["fixture"] },
      },
    ],
  }),
  { W: "w".repeat(40), A: "a".repeat(40) },
);
const port = await gateway.listen(),
  base = `http://127.0.0.1:${port}/v1/accounts/fixture/files`,
  headers = { authorization: `Bearer ${"a".repeat(40)}` };
const results = [];
try {
  for (const name of (await readdir("work/file-fixtures"))
    .filter((n) => n.startsWith("sample."))
    .sort()) {
    const original = await readFile(`work/file-fixtures/${name}`);
    const uploaded = await fetch(
      `${base}?${new URLSearchParams({ name, chatId: "fixture" })}`,
      { method: "POST", headers, body: original },
    );
    if (!uploaded.ok) throw new Error(await uploaded.text());
    const f: any = await uploaded.json();
    const downloaded = Buffer.from(
      await (
        await fetch(`${base}/${f.id}/download`, { headers })
      ).arrayBuffer(),
    );
    await fetch(`${base}/${f.id}/prepare`, { method: "POST", headers });
    let r: any;
    for (let i = 0; i < 500; i++) {
      r = await (await fetch(`${base}/${f.id}`, { headers })).json();
      if (r.state !== "preparing") break;
      await new Promise((r) => setTimeout(r, 250));
    }
    let previewHTTP: number | null = null,
      previewBytes = 0,
      signatureValid = false;
    if (r.result?.preview) {
      const response = await fetch(`${base}/${f.id}/preview`, { headers });
      previewHTTP = response.status;
      const data = Buffer.from(await response.arrayBuffer());
      previewBytes = data.length;
      const extension = r.result.preview.split(".").pop();
      signatureValid =
        extension === "pdf"
          ? data.subarray(0, 5).toString() === "%PDF-"
          : extension === "png"
            ? data
                .subarray(0, 8)
                .equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
            : ["mp4", "m4a"].includes(extension)
              ? data.subarray(4, 8).toString() === "ftyp"
              : extension === "txt"
                ? data.length > 0
                : data.length > 0;
      const { mkdir } = await import("node:fs/promises");
      await mkdir("work/file-fixtures/previews", { recursive: true });
      await writeFile(`work/file-fixtures/previews/${name}.${extension}`, data);
    }
    const result = {
      extension: name.split(".").pop(),
      originalExact: downloaded.equals(original),
      previewHTTP,
      previewBytes,
      signatureValid,
      status: r.state,
      preview: r.result?.preview ?? null,
      textCharacters: r.result?.text?.length ?? 0,
      metadataKeys: Object.keys(r.result?.metadata ?? {}),
      warnings: r.result?.warnings ?? [],
    };
    results.push(result);
    console.log(JSON.stringify(result));
  }
  await writeFile(
    "docs/FILE_ACCEPTANCE.json",
    JSON.stringify(
      {
        date: "2026-10-07",
        environment:
          "macOS sandboxed conversion; synthetic fixtures; not recipient delivery",
        results,
      },
      null,
      2,
    ) + "\n",
  );
} finally {
  await gateway.close();
}
