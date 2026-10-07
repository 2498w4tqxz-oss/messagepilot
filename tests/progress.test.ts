import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "../src/store.js";
import { ProgressService } from "../src/progress/service.js";
import {
  startProgress,
  updateProgress,
  type ProgressJob,
} from "../src/progress/schema.js";
import type { Config, Operation } from "../src/protocol.js";
import { Gateway } from "../src/gateway.js";
import { BridgeClient } from "../src/client.js";
import { Worker } from "../src/worker.js";
import { FixtureTransport } from "../src/native.js";
const config = (): Config => ({
  host: "127.0.0.1",
  port: 0,
  database: ":memory:",
  accounts: [
    {
      id: "a",
      identity: "fixture@example.test",
      workerTokenEnv: "W",
      allowedChatIds: ["self"],
    },
  ],
  agents: [
    { id: "owner", accounts: ["a"], tokenEnv: "A", chats: { a: ["self"] } },
  ],
});
function fixture(t: any, path = ":memory:") {
  const cfg = config(),
    actor = cfg.agents[0]!;
  let now = Date.now();
  const store = new Store(path);
  const service = new ProgressService(
    store,
    cfg,
    (a, _owner, input) => store.enqueue(a, input).id,
    () => {},
    () => now,
    false,
  );
  t.after(() => {
    service.close();
    store.close();
  });
  const get = (j: ProgressJob) => service.get("a", j.id, actor);
  const start = (extra = {}) =>
    service.start(
      "a",
      actor,
      startProgress.parse({
        chatId: "self",
        title: "Build report",
        detail: "Starting",
        idempotencyKey: "start",
        ...extra,
      }),
    );
  const update = (
    j: ProgressJob,
    detail: string,
    state = "running",
    extra = {},
  ) =>
    service.update(
      "a",
      j.id,
      actor,
      updateProgress.parse({
        expectedRevision: get(j).revision,
        idempotencyKey: detail,
        detail,
        state,
        ...extra,
      }),
    );
  const finish = (
    j: ProgressJob,
    result: unknown = { message: { id: "fixture-message" } },
    state: "completed" | "failed" | "outcome_unknown" = "completed",
  ) => {
    const id = get(j).transport.commandId!;
    assert.ok(id);
    store.transition("a", id, "queued", state, { result });
    service.tick();
  };
  return {
    cfg,
    actor,
    store,
    service,
    start,
    get,
    update,
    finish,
    advance: (ms: number) => {
      now += ms;
      service.tick();
    },
  };
}
test("coalesces fast updates, reserves fifth edit for final and sends outputs after it", (t) => {
  const f = fixture(t),
    j = f.start();
  f.service.tick();
  f.finish(j);
  f.update(j, "A");
  f.advance(1000);
  assert.equal(f.get(j).transport.commandId, undefined);
  f.update(j, "B");
  f.advance(4000);
  assert.equal(
    f.store.get("a", f.get(j).transport.commandId!)!.args.text,
    "Build report\nWorking\nB",
  );
  f.finish(j);
  for (let n = 0; n < 3; n++) {
    f.update(j, `Step ${n}`);
    f.advance(5000);
    f.finish(j);
  }
  assert.equal(f.get(j).transport.editAttempts, 4);
  f.update(j, "Another step");
  f.advance(5000);
  assert.equal(f.get(j).transport.state, "paused");
  f.update(j, "Report complete", "completed", {
    attachments: [{ label: "Report", filePath: "/worker/report.pdf" }],
  });
  f.service.tick();
  assert.equal(f.get(j).transport.action, "final_edit");
  assert.equal(f.get(j).transport.editAttempts, 5);
  f.finish(j);
  assert.equal(f.get(j).transport.action, "attachment");
  assert.equal(
    f.store.get("a", f.get(j).transport.commandId!)!.args.filePath,
    "/worker/report.pdf",
  );
  f.finish(j);
  assert.equal(f.get(j).transport.state, "complete");
  assert.equal(f.get(j).transport.receipts.length, 7);
});
test("expired window uses one final message; disabled fallback stops cleanly", (t) => {
  for (const fallback of ["new_message", "none"]) {
    const f = fixture(t),
      j = f.start({ finalFallback: fallback });
    f.service.tick();
    f.finish(j);
    f.advance(16 * 60000);
    f.update(j, "Done", "completed");
    f.service.tick();
    assert.equal(
      f.get(j).transport.action,
      fallback === "new_message" ? "final_send" : undefined,
    );
    if (fallback === "new_message") {
      f.finish(j);
      f.service.tick();
      assert.equal(f.get(j).transport.state, "complete");
    } else {
      assert.equal(f.get(j).transport.state, "paused");
      assert.equal(
        (f.store.db.prepare("SELECT active FROM progress_jobs").get() as any)
          .active,
        0,
      );
    }
  }
});
test("unknown outcome and absent native message ID stop without duplicate sends", (t) => {
  for (const outcome of ["unknown", "missing"]) {
    const f = fixture(t),
      j = f.start();
    f.service.tick();
    f.finish(j, {}, outcome === "unknown" ? "outcome_unknown" : "completed");
    assert.equal(f.get(j).transport.state, "outcome_unknown");
    f.update(j, "Done", "completed");
    f.advance(60000);
    assert.equal(
      (f.store.db.prepare("SELECT COUNT(*) AS n FROM commands").get() as any).n,
      1,
    );
  }
});
test("progress is owner-bound, chat-scoped, revision-checked and idempotent", (t) => {
  const f = fixture(t),
    j = f.start();
  assert.equal(f.start().id, j.id);
  assert.throws(() => f.start({ detail: "Changed" }), /key reused/);
  assert.throws(
    () => f.start({ chatId: "other", idempotencyKey: "other" }),
    /chat not granted/,
  );
  assert.throws(
    () => f.service.get("a", j.id, { ...f.actor, chats: { a: ["other"] } }),
    /chat not granted/,
  );
  assert.throws(
    () =>
      f.service.update(
        "a",
        j.id,
        { ...f.actor, id: "other" },
        updateProgress.parse({
          expectedRevision: 1,
          idempotencyKey: "x",
          detail: "x",
          state: "running",
        }),
      ),
    /creating agent/,
  );
  const input = updateProgress.parse({
    expectedRevision: 1,
    idempotencyKey: "update",
    detail: "Step",
    state: "waiting",
  });
  const updated = f.service.update("a", j.id, f.actor, input);
  assert.equal(updated.revision, 2);
  assert.deepEqual(f.service.update("a", j.id, f.actor, input), updated);
  assert.throws(
    () =>
      f.service.update("a", j.id, f.actor, {
        ...input,
        idempotencyKey: "stale",
      }),
    /Reload job/,
  );
  f.update(j, "Done", "completed");
  assert.throws(() => f.update(j, "Revive"), /immutable/);
});
test("live cards retain bounded progress and produce no native sends", (t) => {
  const f = fixture(t),
    j = f.start({ mode: "live_card" });
  for (let n = 0; n < 110; n++) f.update(j, `Step ${n}`);
  f.service.tick();
  assert.equal(f.get(j).history.length, 100);
  assert.equal(f.get(j).transport.state, "awaiting_user");
  assert.throws(
    () =>
      f.update(j, "Done", "completed", {
        attachments: [{ label: "x", filePath: "/x" }],
      }),
    /fileIds/,
  );
  assert.equal(
    (f.store.db.prepare("SELECT COUNT(*) AS n FROM commands").get() as any).n,
    0,
  );
});
test("revoked owner cannot dispatch a queued progress command", (t) => {
  const f = fixture(t),
    j = f.start();
  f.service.tick();
  const c = f.store.get("a", f.get(j).transport.commandId!)!;
  f.service.assertDispatch(c);
  f.cfg.agents = [];
  assert.throws(() => f.service.assertDispatch(c), /authorized/);
  f.service.tick();
  assert.equal(f.store.get("a", c.id)?.state, "cancelled");
  assert.equal(f.get(j).transport.state, "failed");
});
test("restart preserves pending command and does not enqueue another initial send", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "progress-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const cfg = config(),
    actor = cfg.agents[0]!;
  let store = new Store(join(dir, "db"));
  let service = new ProgressService(
    store,
    cfg,
    (a, _, i) => store.enqueue(a, i).id,
    () => {},
    Date.now,
    false,
  );
  const job = service.start(
    "a",
    actor,
    startProgress.parse({
      chatId: "self",
      title: "Test",
      detail: "Starting",
      idempotencyKey: "start",
    }),
  );
  service.tick();
  const command = service.get("a", job.id, actor).transport.commandId!;
  service.close();
  store.close();
  store = new Store(join(dir, "db"));
  service = new ProgressService(
    store,
    cfg,
    (a, _, i) => store.enqueue(a, i).id,
    () => {},
    Date.now,
    false,
  );
  try {
    service.tick();
    assert.equal(service.get("a", job.id, actor).transport.commandId, command);
    assert.equal(
      (store.db.prepare("SELECT COUNT(*) AS n FROM commands").get() as any).n,
      1,
    );
  } finally {
    service.close();
    store.close();
  }
});
test("HTTP progress runs through scoped gateway and fixture worker, not a native Messages account", async () => {
  const A = "a".repeat(40),
    W = "w".repeat(40),
    g = new Gateway(config(), { A, W });
  const port = await g.listen(),
    client = new BridgeClient(`http://127.0.0.1:${port}`, A);
  class ReceiptFixture extends FixtureTransport {
    async chatScope() {
      return ["self"];
    }
    async execute(op: Operation, args: Record<string, unknown>) {
      const result = await super.execute(op, args);
      return { ...result, message: { id: "fixture-message" } };
    }
  }
  const native = new ReceiptFixture("fixture@example.test");
  // Scoped worker must explicitly attest the exact same restricted chat set.
  const worker = new Worker(
    {
      url: `ws://127.0.0.1:${port}/worker`,
      token: W,
      accountId: "a",
      workerId: "fixture",
      identity: "fixture@example.test",
      spool: ":memory:",
    },
    native,
  );
  try {
    await worker.start();
    const j = await client.request("a", "progress", "POST", {
      chatId: "self",
      idempotencyKey: "http",
      title: "Report",
      detail: "Starting",
    });
    const wait = async (predicate: (j: ProgressJob) => boolean) => {
      for (let n = 0; n < 120; n++) {
        const current = await client.request("a", `progress/${j.id}`);
        if (predicate(current)) return current;
        await new Promise((r) => setTimeout(r, 25));
      }
      throw new Error("Timed out");
    };
    await wait((j) => !!j.transport.messageId);
    await client.request("a", `progress/${j.id}/updates`, "POST", {
      expectedRevision: 1,
      idempotencyKey: "done",
      state: "completed",
      detail: "Done",
      attachments: [{ filePath: "/fixture/output.pdf", label: "Report" }],
    });
    const done = await wait((j) => j.transport.state === "complete");
    assert.equal(done.transport.receipts.length, 3);
    assert.deepEqual(
      native.calls.map((c) => c.operation),
      ["messages.send", "messages.edit", "messages.send"],
    );
    await assert.rejects(client.request("a", "progress?chatId=other"), /403/);
    await assert.rejects(client.request("a", "progress"), /400/);
  } finally {
    await worker.close();
    await g.close();
  }
});

test("new revisions replace only queued edits and preserve edit budget", (t) => {
  const f = fixture(t),
    j = f.start();
  f.service.tick();
  f.finish(j);
  f.update(j, "First");
  f.advance(5000);
  const old = f.get(j).transport.commandId!;
  f.update(j, "Newest");
  assert.equal(f.store.get("a", old)?.state, "cancelled");
  assert.equal(f.get(j).transport.editAttempts, 0);
  f.service.tick();
  const next = f.get(j).transport.commandId!;
  assert.notEqual(next, old);
  assert.match(String(f.store.get("a", next)?.args.text), /Newest/);
  f.store.transition("a", next, "queued", "executing");
  f.update(j, "Final", "completed");
  f.service.tick();
  assert.equal(f.get(j).transport.commandId, next);
  f.store.transition("a", next, "executing", "completed", { result: {} });
  f.service.tick();
  assert.equal(f.get(j).transport.action, "final_edit");
});

test("progress output IDs require file permission and the same exact chat", async () => {
  const dir = mkdtempSync(join(tmpdir(), "progress-files-"));
  const cfg = config();
  cfg.accounts[0]!.allowedChatIds = ["self", "second"];
  cfg.agents[0]!.chats = { a: ["self", "second"] };
  cfg.files = { directory: dir, maxFileBytes: 4096, maxAccountBytes: 8192 };
  cfg.agents.push({
    id: "limited",
    accounts: ["a"],
    tokenEnv: "L",
    operations: ["messages.send", "messages.list"],
  });
  const A = "a".repeat(40),
    W = "w".repeat(40),
    L = "l".repeat(40);
  const g = new Gateway(cfg, { A, W, L });
  const port = await g.listen();
  const client = new BridgeClient(`http://127.0.0.1:${port}`, A),
    limited = new BridgeClient(`http://127.0.0.1:${port}`, L);
  try {
    const file = await client.upload(
      "a",
      "self",
      "output.txt",
      Buffer.from("result"),
    );
    const wrong = await client.upload(
      "a",
      "second",
      "other.txt",
      Buffer.from("other"),
    );
    const j = await client.request("a", "progress", "POST", {
      chatId: "self",
      title: "Files",
      detail: "Starting",
      mode: "live_card",
      idempotencyKey: "start",
    });
    const update = {
      expectedRevision: 1,
      idempotencyKey: "done",
      state: "completed",
      detail: "Done",
    };
    await assert.rejects(
      client.request("a", `progress/${j.id}/updates`, "POST", {
        ...update,
        fileIds: [wrong.id],
      }),
      /another chat/,
    );
    const final = await client.request(
      "a",
      `progress/${j.id}/updates`,
      "POST",
      { ...update, fileIds: [file.id] },
    );
    assert.deepEqual(final.fileIds, [file.id]);
    await assert.rejects(
      limited.request("a", "progress", "POST", {
        chatId: "self",
        title: "Native",
        detail: "Starting",
        idempotencyKey: "native",
      }),
      /messages.edit/,
    );
    const limitedJob = await limited.request("a", "progress", "POST", {
      chatId: "self",
      title: "Card",
      detail: "Starting",
      mode: "live_card",
      idempotencyKey: "limited",
    });
    await assert.rejects(
      limited.request("a", `progress/${limitedJob.id}/updates`, "POST", {
        ...update,
        fileIds: [file.id],
      }),
      /files.read/,
    );
  } finally {
    await g.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
