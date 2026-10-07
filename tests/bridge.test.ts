import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";
import { Gateway } from "../src/gateway.js";
import { Store } from "../src/store.js";
import { Worker } from "../src/worker.js";
import { FixtureTransport } from "../src/native.js";
import { BridgeClient } from "../src/client.js";
import { Auth } from "../src/auth.js";
import type { Config } from "../src/protocol.js";
const tokens = {
  WORKER_A: "worker-a-" + "x".repeat(32),
  WORKER_B: "worker-b-" + "x".repeat(32),
  AGENT_A: "agent-a-" + "x".repeat(32),
  AGENT_ALL: "all-" + "x".repeat(32),
  DEVICE_A: "device-a-" + "x".repeat(32),
};
const config = (database = ":memory:"): Config => ({
  host: "127.0.0.1",
  port: 0,
  database,
  accounts: [
    {
      id: "a",
      identity: "a@example.test",
      workerTokenEnv: "WORKER_A",
      deviceTokenEnv: "DEVICE_A",
    },
    { id: "b", identity: "b@example.test", workerTokenEnv: "WORKER_B" },
  ],
  agents: [
    { id: "agent-a", tokenEnv: "AGENT_A", accounts: ["a"] },
    { id: "all", tokenEnv: "AGENT_ALL", accounts: ["a", "b"] },
  ],
});
async function until<T>(
  fn: () => Promise<T> | T,
  accept: (v: T) => boolean,
  timeout = 3000,
): Promise<T> {
  const start = Date.now();
  while (true) {
    const v = await fn();
    if (accept(v)) return v;
    if (Date.now() - start > timeout) throw new Error("Timed out");
    await new Promise((r) => setTimeout(r, 5));
  }
}
async function setup(t: any, delay = 0) {
  const g = new Gateway(config(), tokens);
  const port = await g.listen();
  const url = `http://127.0.0.1:${port}`;
  const a = new FixtureTransport("a@example.test", delay),
    b = new FixtureTransport("b@example.test");
  const workers = [
    new Worker(
      {
        url: `ws://127.0.0.1:${port}/worker`,
        token: tokens.WORKER_A,
        accountId: "a",
        workerId: "wa",
        identity: "a@example.test",
        spool: ":memory:",
      },
      a,
    ),
    new Worker(
      {
        url: `ws://127.0.0.1:${port}/worker`,
        token: tokens.WORKER_B,
        accountId: "b",
        workerId: "wb",
        identity: "b@example.test",
        spool: ":memory:",
      },
      b,
    ),
  ];
  await Promise.all(workers.map((w) => w.start()));
  const client = new BridgeClient(url, tokens.AGENT_ALL);
  await until(
    () => client.request("a", "capabilities"),
    (r) => r.online,
  );
  await until(
    () => client.request("b", "capabilities"),
    (r) => r.online,
  );
  t.after(async () => {
    workers.forEach((w) => w.close());
    await g.close();
  });
  return { g, port, url, a, b, workers, client };
}

test("tokens are unique, long, and bound to account + role", () => {
  const auth = new Auth(config(), tokens);
  assert.equal(auth.worker(`Bearer ${tokens.DEVICE_A}`).role, "device");
  assert.throws(() => auth.agent(`Bearer ${tokens.AGENT_A}`, "b"));
  assert.throws(
    () => new Auth(config(), { ...tokens, WORKER_B: tokens.WORKER_A }),
  );
  assert.throws(() => auth.worker(`Bearer ${tokens.AGENT_A}`));
  const duplicate = config();
  duplicate.agents[1]!.id = duplicate.agents[0]!.id;
  assert.throws(() => new Auth(duplicate, tokens), /Agent IDs/);
});
test("virtual computer control leases fence competing agents and reject stale renewals", async (t) => {
  const { client, url } = await setup(t);
  const other = new BridgeClient(url, tokens.AGENT_A);
  await assert.rejects(
    client.command("a", "computer.input", {
      bundleId: "fixture",
      actions: [{ action: "activate" }],
    }),
    /control_required/,
  );
  const lease = await client.request("a", "control", "POST", {
    ttlSeconds: 120,
  });
  await assert.rejects(
    other.command("a", "messages.send", { chatId: "fixture", text: "blocked" }),
    /control_required/,
  );
  await assert.rejects(
    other.request("a", "control", "POST", { ttlSeconds: 120 }),
    /control_held/,
  );
  await assert.rejects(
    client.request("a", "control", "POST", {
      leaseId: "stale",
      ttlSeconds: 120,
    }),
    /control_held/,
  );
  const input = await client.command("a", "computer.input", {
    bundleId: "fixture",
    actions: [{ action: "activate" }],
  });
  assert.equal((await client.wait("a", input.id)).state, "completed");
  await client.request("a", "control", "POST", {
    leaseId: lease.leaseId,
    ttlSeconds: 150,
  });
  await client.request("a", "control", "DELETE", { leaseId: lease.leaseId });
  assert.equal((await client.request("a", "control")).control, null);
  const newLease = await other.request("a", "control", "POST", {
    ttlSeconds: 120,
  });
  assert.notEqual(newLease.leaseId, lease.leaseId);
});
test("control cannot be acquired over queued work and expired leases cannot be released", () => {
  const s = new Store(":memory:");
  try {
    const command = s.enqueue("a", {
      operation: "messages.send",
      args: { chatId: "c", text: "pending" },
      idempotencyKey: "pending",
    });
    assert.throws(() => s.claimControl("a", "agent", 120), /outstanding/);
    s.transition("a", command.id, "queued", "cancelled");
    const lease = s.claimControl("a", "agent", 120);
    s.db.prepare("UPDATE control SET expires=0").run();
    assert.equal(s.control("a"), null);
    assert.throws(
      () => s.releaseControl("a", "agent", lease.leaseId),
      /absent/,
    );
  } finally {
    s.close();
  }
});
test("background ActivityKit token events bind to device credentials and deduplicate without a socket", async (t) => {
  const { url, client } = await setup(t);
  const send = (token: string, kind = "device.activity.token") =>
    fetch(`${url}/v1/device-events`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        sourceId: "fixture-token-event",
        accountId: "b",
        kind,
        data: { token: "fixture-not-a-real-token" },
      }),
    });
  assert.equal((await send(tokens.AGENT_ALL)).status, 401);
  assert.equal((await send(tokens.WORKER_A)).status, 403);
  assert.equal((await send(tokens.DEVICE_A, "messages.changed")).status, 400);
  const first = await (await send(tokens.DEVICE_A)).json();
  const duplicate = await (await send(tokens.DEVICE_A)).json();
  assert.equal(first.accountId, "a");
  assert.equal(first.sequence, duplicate.sequence);
  assert.equal((await client.request("b", "events")).length, 0);
});
test("idempotency is content-sensitive, canonical, and account-scoped", () => {
  const s = new Store(":memory:");
  const input = {
    operation: "messages.send" as const,
    args: { text: "hi", chatId: "chat" },
    idempotencyKey: "one",
  };
  const a = s.enqueue("a", input);
  assert.equal(
    s.enqueue("a", { ...input, args: { chatId: "chat", text: "hi" } }).id,
    a.id,
  );
  assert.notEqual(s.enqueue("b", input).id, a.id);
  assert.throws(() => s.enqueue("a", { ...input, args: { text: "changed" } }));
  s.close();
});
test("restart fences executing commands and preserves queued commands", () => {
  const dir = mkdtempSync(join(tmpdir(), "mp-"));
  const path = join(dir, "db");
  let s = new Store(path);
  const a = s.enqueue("a", {
    operation: "messages.send",
    args: { text: "a" },
    idempotencyKey: "a",
  });
  s.transition("a", a.id, "queued", "executing", { generation: "g" });
  const b = s.enqueue("a", {
    operation: "messages.send",
    args: { text: "b" },
    idempotencyKey: "b",
  });
  s.close();
  s = new Store(path);
  assert.equal(s.get("a", a.id)?.state, "outcome_unknown");
  assert.equal(s.next("a")?.id, b.id);
  s.close();
  rmSync(dir, { recursive: true });
});
test("event replay deduplicates per account and does not cross account boundaries", () => {
  const s = new Store(":memory:");
  const one = s.event("a", "same", "message", { text: "a" });
  assert.equal(
    s.event("a", "same", "message", { text: "duplicate" }).sequence,
    one.sequence,
  );
  s.event("b", "same", "message", { text: "b" });
  assert.equal(s.events("a").length, 1);
  assert.equal(s.events("a", one.sequence).length, 0);
  assert.equal((s.events("b")[0]!.data as any).text, "b");
  s.close();
});
test("card revision updates reject stale writes", () => {
  const s = new Store(":memory:");
  s.putCard("a", "card", { title: "a" }, 0);
  assert.throws(() => s.putCard("a", "card", { title: "stale" }, 0));
  assert.equal(s.putCard("a", "card", { title: "new" }, 1).revision, 2);
  assert.equal(s.card("b", "card"), undefined);
  s.close();
});
test("worker binding rejects a wrong native Apple identity before connecting", async () => {
  const w = new Worker(
    {
      url: "ws://127.0.0.1:1/worker",
      token: tokens.WORKER_A,
      accountId: "a",
      workerId: "w",
      identity: "a@example.test",
      spool: ":memory:",
    },
    new FixtureTransport("other@example.test"),
  );
  await assert.rejects(w.start(), /identity/);
  w.close();
});
test("HTTP bridge dispatches one duplicate send only and routes accounts independently", async (t) => {
  const { client, a, b } = await setup(t);
  const input = { chatId: "same-chat", text: "Hello" };
  const first = await client.command("a", "messages.send", input, "send");
  const duplicate = await client.command("a", "messages.send", input, "send");
  assert.equal(first.id, duplicate.id);
  assert.equal((await client.wait("a", first.id)).state, "completed");
  const second = await client.command(
    "b",
    "messages.send",
    { ...input, text: "Other account" },
    "send",
  );
  await client.wait("b", second.id);
  assert.equal(a.calls.length, 1);
  assert.equal(b.calls.length, 1);
  assert.equal(b.calls[0]!.args.text, "Other account");
});
test("scoped agent cannot query or mutate another account", async (t) => {
  const { url } = await setup(t);
  const restricted = new BridgeClient(url, tokens.AGENT_A);
  await assert.rejects(restricted.request("b", "capabilities"), /403/);
  await assert.rejects(
    restricted.command(
      "b",
      "messages.send",
      { chatId: "x", text: "no" },
      "key",
    ),
    /403/,
  );
});
test("invalid message arguments never reach native transport", async (t) => {
  const { client, a } = await setup(t);
  await assert.rejects(
    client.command("a", "messages.send", { text: "missing chat" }, "invalid"),
    /400/,
  );
  assert.equal(a.calls.length, 0);
});
test("disconnect during an action becomes unknown and is never replayed", async (t) => {
  const { client, workers, g } = await setup(t, 300);
  const cmd = await client.command(
    "a",
    "messages.send",
    { chatId: "chat", text: "uncertain" },
    "uncertain",
  );
  await until(
    () => g.store.get("a", cmd.id),
    (c) => c?.state === "executing",
  );
  workers[0]!.close();
  await until(
    () => g.store.get("a", cmd.id),
    (c) => c?.state === "outcome_unknown",
  );
  assert.equal(
    (
      await client.command(
        "a",
        "messages.send",
        { chatId: "chat", text: "uncertain" },
        "uncertain",
      )
    ).state,
    "outcome_unknown",
  );
});
test("queued action can be cancelled without touching the worker", async (t) => {
  const { client, g } = await setup(t, 150);
  const first = await client.command(
    "a",
    "messages.send",
    { chatId: "chat", text: "first" },
    "first",
  );
  await until(
    () => g.store.get("a", first.id),
    (c) => c?.state === "executing",
  );
  const second = await client.command(
    "a",
    "messages.send",
    { chatId: "chat", text: "cancel" },
    "second",
  );
  const cancelled = await client.request(
    "a",
    `commands/${second.id}`,
    "DELETE",
  );
  assert.equal(cancelled.state, "cancelled");
  await client.wait("a", first.id);
});
test("native event spool is acknowledged only after account-scoped persistence", async (t) => {
  const { a, g } = await setup(t);
  a.emit({ messageId: "event-1", text: "hello" });
  await until(
    () => g.store.events("a"),
    (rows) => rows.some((e) => e.kind === "messages.changed"),
  );
  assert.equal(g.store.events("b").length, 0);
});
test("two workers cannot own the same desktop identity concurrently", async (t) => {
  const { port } = await setup(t);
  const ws = new WebSocket(`ws://127.0.0.1:${port}/worker`, {
    headers: { authorization: `Bearer ${tokens.WORKER_A}` },
  });
  const closed = new Promise<number>((r) => ws.on("close", r));
  ws.on("open", () =>
    ws.send(
      JSON.stringify({
        type: "hello",
        accountId: "a",
        identity: "a@example.test",
        workerId: "duplicate",
        capabilities: [],
      }),
    ),
  );
  assert.equal(await closed, 1008);
});
test("card actions are revision-checked and emit authenticated actor events", async (t) => {
  const { client, g } = await setup(t);
  await client.request("a", "cards/c", "PUT", {
    expectedRevision: 0,
    body: { title: "Pick", items: [], actions: ["Choose"] },
  });
  await assert.rejects(
    client.request("a", "cards/c/actions", "POST", {
      revision: 0,
      action: "Choose",
      idempotencyKey: "old",
    }),
    /409/,
  );
  await assert.rejects(
    client.request("a", "cards/c/actions", "POST", {
      revision: 1,
      action: "Delete",
      idempotencyKey: "bad",
    }),
    /400/,
  );
  await client.request("a", "cards/c/actions", "POST", {
    revision: 1,
    action: "Choose",
    idempotencyKey: "ok",
  });
  assert.ok(
    g.store
      .events("a")
      .some((e) => e.kind === "card.action" && (e.data as any).actor === "all"),
  );
});
test("device commands use a separately authenticated phone lane", async (t) => {
  const { port, client, a } = await setup(t);
  const ws = new WebSocket(`ws://127.0.0.1:${port}/worker`, {
    headers: { authorization: `Bearer ${tokens.DEVICE_A}` },
  });
  t.after(() => ws.terminate());
  ws.on("open", () =>
    ws.send(
      JSON.stringify({
        type: "hello",
        role: "device",
        accountId: "a",
        identity: "a@example.test",
        workerId: "phone",
        capabilities: [
          {
            operation: "location.get",
            available: true,
            path: "fixture",
            verification: "fixture",
          },
        ],
      }),
    ),
  );
  ws.on("message", (raw) => {
    const f = JSON.parse(raw.toString());
    if (f.type === "command")
      ws.send(
        JSON.stringify({
          type: "result",
          generation: f.generation,
          commandId: f.command.id,
          ok: true,
          result: { fixture: true, source: "phone" },
        }),
      );
  });
  await until(
    () => client.request("a", "capabilities"),
    (r) => r.workerIds.length === 2,
  );
  const c = await client.command("a", "location.get", {}, randomUUID());
  assert.equal((await client.wait("a", c.id)).state, "completed");
  assert.equal(a.calls.length, 0);
});
test("a long app build does not block the account messaging lane", async (t) => {
  const { client, g, a } = await setup(t, 180);
  const build = await client.command(
    "a",
    "apps.build",
    { project: "demo.xcodeproj", scheme: "Demo" },
    "build",
  );
  await until(
    () => g.store.get("a", build.id),
    (c) => c?.state === "executing",
  );
  const send = await client.command(
    "a",
    "messages.send",
    { chatId: "chat", text: "fast" },
    "during-build",
  );
  await until(
    () => g.store.get("a", send.id),
    (c) => c?.state === "executing",
  );
  assert.equal(g.store.get("a", build.id)?.state, "executing");
  await until(
    () => a.calls.length,
    (count) => count === 2,
  );
  await client.wait("a", send.id);
  await client.wait("a", build.id);
});
