import test from "node:test";
import assert from "node:assert/strict";
import { Gateway } from "../src/gateway.js";
import { configSchema, type CommandInput } from "../src/protocol.js";
import { chatScope, assertChatScope, visibleEvent } from "../src/chat-scope.js";
import { toolSchemas } from "../src/tool-schemas.js";
import {
  textEffects,
  bubbleEffects,
  screenEffects,
} from "../src/rich-messages.js";
const env = { W: "w".repeat(40), A: "a".repeat(40), B: "b".repeat(40) };
const config = () =>
  configSchema.parse({
    port: 0,
    database: ":memory:",
    accounts: [{ id: "a", identity: "fixture", workerTokenEnv: "W" }],
    agents: [
      {
        id: "limited",
        tokenEnv: "A",
        accounts: ["a"],
        chats: { a: ["allowed"] },
      },
      { id: "owner", tokenEnv: "B", accounts: ["a"] },
    ],
  });
const cmd = (chatId: string): CommandInput => ({
  operation: "messages.send",
  args: { chatId, text: "fixture" },
  idempotencyKey: chatId,
});
test("chat policies intersect; missing account in grant means no chats", () => {
  const c = config();
  c.accounts[0]!.allowedChatIds = ["allowed", "second"];
  assert.deepEqual(chatScope(c, c.agents[0]!, "a"), ["allowed"]);
  assert.deepEqual(
    chatScope(c, { id: "x", accounts: ["a"], chats: {} }, "a"),
    [],
  );
  assert.throws(() => assertChatScope([], cmd("allowed")), /permitted chat/);
  assert.throws(
    () =>
      assertChatScope(["allowed"], {
        ...cmd("allowed"),
        args: { chatId: "allowed", selectors: { send: "other" } },
      }),
    /override/,
  );
});
test("scoped credentials cannot read or cancel other-chat receipts, events, cards or escape via tools", async (t) => {
  const g = new Gateway(config(), env);
  const port = await g.listen();
  t.after(() => g.close());
  const call = async (
    path: string,
    token = env.A,
    method = "GET",
    body?: unknown,
  ) =>
    fetch(`http://127.0.0.1:${port}/v1/accounts/a/${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  const foreign = g.store.enqueue("a", cmd("secret"));
  const own = g.store.enqueue("a", cmd("allowed"));
  for (const method of ["GET", "DELETE"])
    assert.equal(
      (await call(`commands/${foreign.id}`, env.A, method)).status,
      403,
    );
  assert.equal((await call(`commands/${own.id}`)).status, 200);
  for (const path of ["cards/private", "control", "passkeys/register-options"])
    assert.equal((await call(path)).status, 403);
  for (const input of [
    cmd("secret"),
    {
      operation: "messages.search",
      args: { query: "x" },
      idempotencyKey: "search",
    },
    {
      operation: "computer.exec",
      args: { executable: "/bin/echo" },
      idempotencyKey: "exec",
    },
    { operation: "apps.snapshot", args: {}, idempotencyKey: "ax" },
    {
      operation: "mcp.tools.call",
      args: { id: "x", name: "x" },
      idempotencyKey: "mcp",
    },
  ])
    assert.equal((await call("commands", env.A, "POST", input)).status, 403);
  g.store.event("a", "secret", "command.updated", foreign);
  g.store.event("a", "own", "command.updated", own);
  g.store.event("a", "native", "messages.changed", {
    chatId: "secret",
    text: "NEVER EXPOSE",
  });
  const events = await (await call("events")).json();
  assert.equal(events.length, 1);
  assert.equal(events[0].data.id, own.id);
  assert.equal(
    (
      await call("commands", env.A, "POST", {
        ...cmd("allowed"),
        idempotencyKey: "allowed-new",
      })
    ).status,
    202,
  );
  const c = config();
  c.accounts[0]!.allowedChatIds = ["allowed"];
  assert.deepEqual(chatScope(c, c.agents[1]!, "a"), ["allowed"]);
});
test("SSE replay and live events omit unrelated receipts and native batches", async (t) => {
  const g = new Gateway(config(), env);
  const port = await g.listen();
  t.after(() => g.close());
  const hidden = g.store.enqueue("a", cmd("hidden"));
  const own = g.store.enqueue("a", cmd("allowed"));
  g.store.event("a", "hidden", "command.updated", hidden);
  g.store.event("a", "own", "command.updated", own);
  const abort = new AbortController();
  const response = await fetch(
    `http://127.0.0.1:${port}/v1/accounts/a/events?stream=1`,
    { headers: { Authorization: `Bearer ${env.A}` }, signal: abort.signal },
  );
  const reader = response.body!.getReader();
  const replay = new TextDecoder().decode((await reader.read()).value);
  assert.match(replay, new RegExp(own.id));
  assert.ok(!replay.includes(hidden.id));
  (g as any).emit("a", "hidden-live", "command.updated", hidden);
  (g as any).emit("a", "own-live", "command.updated", own);
  const live = new TextDecoder().decode((await reader.read()).value);
  assert.match(live, new RegExp(own.id));
  assert.ok(!live.includes(hidden.id));
  abort.abort();
});
test("all native effect families validate and invalid combinations fail before dispatch", () => {
  for (const [kind, effects] of [
    ["text", textEffects],
    ["bubble", bubbleEffects],
    ["screen", screenEffects],
  ] as const)
    for (const effect of effects)
      assert.ok(
        toolSchemas["messages.effect"].safeParse({
          chatId: "allowed",
          text: "fixture",
          kind,
          effect,
        }).success,
      );
  assert.ok(
    !toolSchemas["messages.effect"].safeParse({
      chatId: "allowed",
      text: "fixture",
      kind: "text",
      effect: "Confetti",
    }).success,
  );
  assert.ok(
    !toolSchemas["messages.format"].safeParse({
      chatId: "allowed",
      text: "x",
      styles: ["Comic Sans"],
    }).success,
  );
  assert.ok(
    !toolSchemas["messages.format"].safeParse({
      chatId: "allowed",
      text: "x",
      styles: ["bold"],
      range: { start: 1, length: 1 },
    }).success,
  );
  assert.ok(
    toolSchemas["messages.format"].safeParse({
      chatId: "allowed",
      text: "Hello",
      styles: ["bold", "italic"],
    }).success,
  );
});

test("restricted account refuses unscoped worker enrollment, including empty allowlists", async (t) => {
  const { WebSocket } = await import("ws");
  for (const allowedChatIds of [[], ["allowed"]]) {
    const c = config();
    c.accounts[0]!.allowedChatIds = allowedChatIds;
    const g = new Gateway(c, env);
    const port = await g.listen();
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/worker`, {
        headers: { Authorization: `Bearer ${env.W}` },
      });
      const closed = new Promise<number>((resolve, reject) => {
        ws.on("close", resolve);
        ws.on("error", reject);
      });
      ws.on("open", () =>
        ws.send(
          JSON.stringify({
            type: "hello",
            accountId: "a",
            workerId: "broad",
            identity: "fixture",
            capabilities: [],
          }),
        ),
      );
      assert.equal(await closed, 1008);
    } finally {
      await g.close();
    }
  }
});
