import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { SQLiteLibrary, HTTPLibrary, assetInput } from "../src/library.js";
import {
  Analytics,
  analyticsPolicy,
  analyticsEvent,
} from "../src/analytics.js";
import {
  GoogleWorkspace,
  workspaceConfig,
  workspaceInput,
  workspaceRoute,
} from "../src/google-workspace.js";
test("library versions are chat scoped, idempotent, immutable and concurrency checked", async () => {
  const db = new DatabaseSync(":memory:"),
    library = new SQLiteLibrary(db),
    scope = { accountId: "a", chatId: "self" };
  try {
    const input = assetInput.parse({
      chatId: "self",
      idempotencyKey: "one",
      title: "Reusable draft",
      kind: "text",
      content: "one",
    });
    const first = await library.save(scope, undefined, input, "agent");
    assert.deepEqual(
      await library.save(scope, undefined, input, "agent"),
      first,
    );
    await assert.rejects(
      library.save(scope, undefined, { ...input, content: "changed" }, "agent"),
    );
    const second = await library.save(
      scope,
      first.id,
      { ...input, idempotencyKey: "two", expectedRevision: 1, content: "two" },
      "agent",
    );
    assert.equal(second.revision, 2);
    assert.equal((await library.get(scope, first.id, 1))?.value.content, "one");
    assert.equal((await library.list(scope)).length, 1);
    await assert.rejects(
      library.save(
        scope,
        first.id,
        { ...input, idempotencyKey: "three", expectedRevision: 1 },
        "agent",
      ),
    );
    assert.equal(
      await library.get({ accountId: "b", chatId: "self" }, first.id),
      undefined,
    );
    assert.equal(
      await library.get({ accountId: "a", chatId: "other" }, first.id),
      undefined,
    );
  } finally {
    db.close();
  }
});
test("custom backend HTTP contract carries authenticated namespace and prevents redirects", async () => {
  let request: any;
  const provider = new HTTPLibrary(
    "https://storage.example.test/library",
    "s".repeat(40),
    async (url, init) => {
      request = { url, init };
      return new Response("[]");
    },
  );
  await provider.list({ accountId: "a", chatId: "self" });
  assert.equal(request.init.redirect, "error");
  assert.deepEqual(JSON.parse(request.init.body).scope, {
    accountId: "a",
    chatId: "self",
  });
  assert.throws(
    () => new HTTPLibrary("http://storage.example.test", "x".repeat(40)),
  );
});
test("opt-in analytics preserves source, deduplicates, bounds context and never fabricates reads", () => {
  const db = new DatabaseSync(":memory:");
  try {
    const p = analyticsPolicy.parse({
      accountId: "a",
      chatIds: ["self"],
      observerAgentIds: ["observer"],
      readerAgentIds: ["reader"],
      storeText: true,
      contextMessages: 2,
      contextCharacters: 10,
    });
    const a = new Analytics(db, [p]);
    const now = Date.now();
    assert.throws(() => a.policy("a", "other", "reader", "read", undefined));
    assert.throws(() => a.policy("a", "self", "reader", "observe", undefined));
    const put = (id: string, kind: string, time: number, extra = {}) =>
      a.observe(
        p,
        analyticsEvent.parse({
          sourceId: id,
          chatId: "self",
          kind,
          occurredAt: time,
          source: "fixture",
          ...extra,
        }),
      );
    put("sent", "message.sent", now - 10000, { messageId: "m", text: "hello" });
    assert.equal(
      put("sent", "message.sent", now - 10000, {
        messageId: "m",
        text: "hello",
      }).duplicate,
      true,
    );
    let r = a.report(p, "self", now - 20000, now);
    assert.equal(r.readLatency.meanMs, null);
    assert.equal(r.readLatency.unmatchedSent, 1);
    put("read", "message.read", now - 5000, { messageId: "m" });
    put("reaction", "reaction.added", now - 4000, { reaction: "__proto__" });
    put("media", "media.sent", now - 3000, { media: "image", count: 3 });
    put("received", "message.received", now - 2000, {
      messageId: "r",
      text: "world",
    });
    r = a.report(p, "self", now - 20000, now);
    assert.equal(r.readLatency.meanMs, 5000);
    assert.equal(r.reactions.__proto__!.added, 1);
    assert.equal(r.media["media.sent:image"], 3);
    assert.equal(a.context(p, "self").characters, 10);
    put("unsent", "message.unsent", now - 1000, { messageId: "m" });
    assert.equal(a.context(p, "self").messages.length, 1);
    const noText = { ...p, storeText: false };
    put("future", "extension.action", now, { action: "tap" });
    a.observe(
      noText,
      analyticsEvent.parse({
        sourceId: "private",
        chatId: "self",
        kind: "message.received",
        occurredAt: now,
        source: "fixture",
        messageId: "hidden",
        text: "secret",
      }),
    );
    assert.ok(
      !String(
        (
          db
            .prepare(
              "SELECT value FROM analytics_events WHERE source_id='private'",
            )
            .get() as any
        ).value,
      ).includes("secret"),
    );
  } finally {
    db.close();
  }
});
test("Google connection enforces account/chat/action grants and routes only fixed Google APIs", async () => {
  const c = workspaceConfig.parse({
    id: "drive",
    accountId: "a",
    chatId: "self",
    agentIds: ["agent"],
    operations: ["drive.get"],
    accessTokenEnv: "G",
  });
  let called: any;
  const api = new GoogleWorkspace([c], { G: "token" }, async (url, init) => {
    called = { url, init };
    return Response.json({ id: "file" });
  });
  assert.throws(() => api.authorize("a", "drive", "agent", ["other"]));
  assert.throws(() => api.authorize("b", "drive", "agent", undefined));
  const authorized = api.authorize("a", "drive", "agent", ["self"]);
  assert.deepEqual(
    await api.execute(
      authorized,
      workspaceInput.parse({
        operation: "drive.get",
        args: { fileId: "https://evil.example/x" },
      }),
    ),
    { id: "file" },
  );
  assert.ok(
    called.url.startsWith(
      "https://www.googleapis.com/drive/v3/files/https%3A%2F%2F",
    ),
  );
  assert.equal(called.init.redirect, "error");
  await assert.rejects(
    api.execute(
      c,
      workspaceInput.parse({ operation: "gmail.send", args: { raw: "abc" } }),
    ),
  );
  assert.equal(
    workspaceRoute("sheets.write", {
      spreadsheetId: "s",
      range: "A1:B2",
      body: { values: [[1, 2]] },
    }).method,
    "PUT",
  );
});
test("Google writes report uncertainty and are never retried", async () => {
  const c = workspaceConfig.parse({
    id: "docs",
    accountId: "a",
    chatId: "self",
    agentIds: ["agent"],
    operations: ["docs.create"],
    accessTokenEnv: "G",
  });
  let calls = 0;
  const api = new GoogleWorkspace([c], { G: "token" }, async () => {
    calls++;
    throw new Error("network");
  });
  await assert.rejects(
    api.execute(c, {
      operation: "docs.create",
      args: { body: { title: "test" } },
    }),
    /outcome unknown/,
  );
  assert.equal(calls, 1);
});
test("container planning pins images and never places credentials or host mounts in plans", async () => {
  const { containerPlan } = await import("../src/container-plan.js");
  const p = containerPlan({
    name: "agent",
    image: `example.test/agent@sha256:${"a".repeat(64)}`,
    gatewayURL: "https://bridge.example.test",
    accountId: "a",
  });
  assert.equal(p.status, "plan_only");
  assert.deepEqual(p.mounts, []);
  assert.ok(p.arguments.includes("--cpus"));
  assert.throws(() =>
    containerPlan({
      name: "agent",
      image: "image:latest",
      gatewayURL: "https://bridge.example.test",
      accountId: "a",
    }),
  );
});
test("gateway library and analytics routes enforce intersected scope and command counts", async () => {
  const { Gateway } = await import("../src/gateway.js");
  const { configSchema } = await import("../src/protocol.js");
  const gateway = new Gateway(
    configSchema.parse({
      host: "127.0.0.1",
      port: 0,
      database: ":memory:",
      accounts: [
        {
          id: "a",
          identity: "a@test",
          workerTokenEnv: "W",
          allowedChatIds: ["self"],
        },
      ],
      agents: [
        { id: "a", tokenEnv: "A", accounts: ["a"], chats: { a: ["self"] } },
      ],
      analytics: [
        {
          accountId: "a",
          chatIds: ["self"],
          readerAgentIds: ["a"],
          observerAgentIds: ["a"],
        },
      ],
    }),
    { W: "w".repeat(40), A: "a".repeat(40) },
  );
  const port = await gateway.listen();
  const call = (path: string, body?: unknown) =>
    fetch(`http://127.0.0.1:${port}/v1/accounts/a/${path}`, {
      method: body ? "POST" : "GET",
      headers: {
        authorization: `Bearer ${"a".repeat(40)}`,
        "content-type": "application/json",
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  try {
    const asset = {
      chatId: "self",
      idempotencyKey: "create",
      title: "test",
      kind: "text",
      content: "hello",
    };
    const created = await call("library", asset);
    assert.equal(created.status, 200);
    const a: any = await created.json();
    assert.equal((await call(`library/${a.id}?chatId=other`)).status, 403);
    assert.equal((await call(`library/${a.id}?chatId=self`)).status, 200);
    const event = {
      sourceId: "one",
      chatId: "self",
      kind: "message.sent",
      messageId: "m",
      occurredAt: Date.now(),
      source: "fixture",
    };
    assert.equal((await call("analytics/observations", event)).status, 200);
    assert.equal((await call("analytics/report?chatId=other")).status, 403);
    const command = {
      operation: "messages.send",
      args: { chatId: "self", text: "fixture" },
      idempotencyKey: "cmd",
    };
    assert.equal((await call("commands", command)).status, 202);
    assert.equal((await call("commands", command)).status, 202);
    const report: any = await (
      await call("analytics/report?chatId=self")
    ).json();
    assert.equal(report.counts["command.accepted"], 1);
    assert.equal(report.counts["message.sent"], 1);
    assert.equal(report.readLatency.meanMs, null);
  } finally {
    await gateway.close();
  }
});
