import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Gateway } from "../src/gateway.js";
import { configSchema } from "../src/protocol.js";
import { hookSignature, verifyHookSignature } from "../src/extension-hooks.js";

const env = {
  WORKER: "w".repeat(40),
  AGENT: "a".repeat(40),
  OBSERVER: "o".repeat(40),
  OUTSIDER: "x".repeat(40),
  SECRET: "s".repeat(40),
};
async function setup(t: any, database = ":memory:", status = 200) {
  const received: { body: string; headers: http.IncomingHttpHeaders }[] = [];
  const receiver = http.createServer(async (req, res) => {
    let body = "";
    for await (const part of req) body += part;
    received.push({ body, headers: req.headers });
    res.writeHead(status);
    res.end();
  });
  await new Promise<void>((r) => receiver.listen(0, "127.0.0.1", r));
  const address = receiver.address() as { port: number };
  const config = configSchema.parse({
    host: "127.0.0.1",
    port: 0,
    database,
    accounts: [
      {
        id: "a",
        identity: "test@example.test",
        workerTokenEnv: "WORKER",
        allowedChatIds: ["self"],
      },
    ],
    agents: [
      {
        id: "caller",
        tokenEnv: "AGENT",
        accounts: ["a"],
        operations: [],
        chats: { a: ["self"] },
      },
      { id: "observer", tokenEnv: "OBSERVER", accounts: ["a"], operations: [] },
      { id: "outsider", tokenEnv: "OUTSIDER", accounts: ["a"] },
    ],
    extensionHooks: ["invites", "location", "checkin"].map((feature) => ({
      id: feature,
      feature,
      accountId: "a",
      chatId: "self",
      url: `http://127.0.0.1:${address.port}/hook`,
      allowLoopbackHttp: true,
      signingSecretEnv: "SECRET",
      requestAgentIds: ["caller"],
      observerAgentIds: ["observer"],
    })),
  });
  const gateway = new Gateway(config, env);
  const port = await gateway.listen();
  const call = async (
    hook: string,
    path: string,
    body?: unknown,
    token = env.AGENT,
    method = body === undefined ? "GET" : "POST",
  ) => {
    const response = await fetch(
      `http://127.0.0.1:${port}/v1/accounts/a/extension-hooks/${hook}/${path}`,
      {
        method,
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      },
    );
    return { status: response.status, value: await response.json() };
  };
  t.after(async () => {
    await gateway.close();
    await new Promise<void>((r) => receiver.close(() => r()));
  });
  return { gateway, config, received, call };
}
const observed = (state: string, sourceId = "observation-1") => ({
  state,
  sourceId,
  observedAt: Date.now(),
  evidence: { kind: "fixture", reference: "synthetic-fixture" },
});

test("extension requests bind chat, deduplicate and require exclusive claim before resolution", async (t) => {
  const { call, gateway, received } = await setup(t);
  const payload = {
    idempotencyKey: "k",
    action: "create",
    parameters: { title: "Synthetic invite" },
  };
  const a = await call("invites", "requests", payload);
  assert.equal(a.status, 202);
  assert.equal(a.value.state, "requested");
  assert.equal(
    (await call("invites", "requests", payload)).value.id,
    a.value.id,
  );
  assert.equal(
    (
      await call("invites", "requests", {
        ...payload,
        parameters: { title: "different" },
      })
    ).status,
    409,
  );
  assert.equal(
    (await call("invites", "requests", { ...payload, chatId: "foreign" }))
      .status,
    400,
  );
  const observation = {
    ...observed("created"),
    requestId: a.value.id,
    outcome: "completed",
  };
  assert.equal(
    (await call("invites", "observations", observation, env.OBSERVER)).status,
    403,
  );
  assert.equal(
    (await call("invites", `requests/${a.value.id}/claim`, {}, env.OBSERVER))
      .status,
    200,
  );
  assert.equal(
    (await call("invites", `requests/${a.value.id}/claim`, {}, env.OBSERVER))
      .status,
    409,
  );
  const result = await call(
    "invites",
    "observations",
    observation,
    env.OBSERVER,
  );
  assert.equal(result.status, 202);
  assert.equal(
    (await call("invites", "observations", observation, env.OBSERVER)).value.id,
    result.value.id,
  );
  assert.equal(
    (await call("invites", `requests/${a.value.id}`)).value.state,
    "completed",
  );
  await gateway.extensionHooks.flush();
  assert.equal(received.length, 2);
  for (const delivery of received) {
    assert.equal(
      delivery.headers["x-messagepilot-signature"],
      `v1=${hookSignature(env.SECRET, String(delivery.headers["x-messagepilot-timestamp"]), delivery.body)}`,
    );
    const event = JSON.parse(delivery.body);
    assert.equal(event.chatId, "self");
    assert.equal(event.source, "messagepilot.agent_mediated");
  }
});

test("hook authorization separates caller, observer, accounts, chats and coordinate consent", async (t) => {
  const { call, config } = await setup(t);
  assert.equal(
    (await call("location", "requests", undefined, env.OUTSIDER)).status,
    403,
  );
  assert.equal(
    (
      await call(
        "location",
        "requests",
        { idempotencyKey: "x", action: "send_pin" },
        env.OBSERVER,
      )
    ).status,
    403,
  );
  assert.equal(
    (await call("location", "observations", observed("pin_sent"))).status,
    403,
  );
  assert.equal(
    (
      await call(
        "location",
        "observations",
        { ...observed("pin_sent"), location: { latitude: 1, longitude: 2 } },
        env.OBSERVER,
      )
    ).status,
    403,
  );
  assert.equal(
    (
      await call(
        "checkin",
        "observations",
        observed("rsvp_changed"),
        env.OBSERVER,
      )
    ).status,
    400,
  );
  assert.equal(
    (
      await call("checkin", "requests", {
        idempotencyKey: "x",
        action: "start_timer",
        parameters: { minutes: 5 },
      })
    ).status,
    400,
  );
  assert.equal(
    (
      await call("checkin", "requests", {
        idempotencyKey: "x",
        action: "__proto__",
      })
    ).status,
    400,
  );
  assert.equal(
    (
      await call("invites", "requests", {
        idempotencyKey: "x",
        action: "share",
        parameters: { url: "https://icloud.com.evil.test/invites/test" },
      })
    ).status,
    400,
  );
  config.agents[0]!.chats = { a: [] };
  assert.equal((await call("location", "requests")).status, 403);
});

test("all three extension observations emit correctly typed callbacks without Apple success inflation", async (t) => {
  const { call, gateway, received } = await setup(t);
  for (const [feature, state] of [
    ["invites", "rsvp_changed"],
    ["location", "pin_sent"],
    ["checkin", "unavailable"],
  ]) {
    const result = await call(
      feature!,
      "observations",
      observed(state!),
      env.OBSERVER,
    );
    assert.equal(result.status, 202);
    assert.equal(result.value.data.verification, "fixture");
  }
  await gateway.extensionHooks.flush();
  assert.deepEqual(received.map((x) => JSON.parse(x.body).kind).sort(), [
    "extension.checkin.unavailable",
    "extension.invites.rsvp_changed",
    "extension.location.pin_sent",
  ]);
});

test("durable callback retries keep event ID and stop after eight failed attempts", async (t) => {
  const { call, gateway, received } = await setup(t, ":memory:", 503);
  await call("location", "observations", observed("pin_sent"), env.OBSERVER);
  for (let i = 0; i < 8; i++) {
    gateway.store.db.exec("UPDATE extension_deliveries SET next=0");
    await gateway.extensionHooks.flush();
  }
  assert.equal(received.length, 8);
  assert.equal(new Set(received.map((x) => x.body)).size, 1);
  const status = (await call("location", "deliveries")).value[0];
  assert.equal(status.state, "failed");
  assert.equal(status.attempts, 8);
  await gateway.extensionHooks.flush();
  assert.equal(received.length, 8);
});

test("restart preserves pending deliveries and marks claimed Apple actions uncertain", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "messagepilot-hooks-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const { call, gateway, config, received } = await setup(
    t,
    join(dir, "hooks.db"),
  );
  const request = await call("checkin", "requests", {
    idempotencyKey: "timer",
    action: "start_timer",
    parameters: { minutes: 5, dataLevel: "limited" },
  });
  await call("checkin", `requests/${request.value.id}/claim`, {}, env.OBSERVER);
  await gateway.close();
  const restarted = new Gateway(config, env);
  t.after(() => restarted.close());
  await restarted.listen();
  const hook = restarted.extensionHooks.authorize(
    "a",
    "checkin",
    config.agents[1]!,
    "observe",
  );
  assert.equal(
    restarted.extensionHooks.get(hook, request.value.id).state,
    "outcome_unknown",
  );
  assert.throws(
    () => restarted.extensionHooks.claim(hook, request.value.id, "observer"),
    /already claimed/,
  );
  await restarted.extensionHooks.flush();
  assert.equal(received.length, 1);
});

test("rebound hook cannot disclose old request bodies or send old callbacks to a new destination", async (t) => {
  const { gateway, call, config } = await setup(t);
  const request = await call("invites", "requests", {
    idempotencyKey: "old",
    action: "create",
    parameters: { title: "private" },
  });
  const hook = config.extensionHooks![0]!;
  hook.url += "/new-destination";
  assert.deepEqual(gateway.extensionHooks.list(hook), []);
  assert.throws(
    () => gateway.extensionHooks.get(hook, request.value.id),
    /not found/,
  );
  await gateway.extensionHooks.flush();
  assert.equal(
    gateway.store.db.prepare("SELECT state FROM extension_deliveries").get()!
      .state,
    "disabled",
  );
});

test("callback verifier rejects tampering, stale timestamps and malformed signatures", () => {
  const timestamp = String(Math.floor(Date.now() / 1000)),
    raw = '{"id":"synthetic"}';
  const signature = "v1=" + hookSignature(env.SECRET, timestamp, raw);
  assert.equal(
    verifyHookSignature(env.SECRET, timestamp, raw, signature),
    true,
  );
  assert.equal(
    verifyHookSignature(env.SECRET, timestamp, raw + " ", signature),
    false,
  );
  assert.equal(
    verifyHookSignature(
      env.SECRET,
      timestamp,
      raw,
      signature,
      Date.now() + 301000,
    ),
    false,
  );
  assert.equal(
    verifyHookSignature(env.SECRET, timestamp, raw, "v1=bad"),
    false,
  );
});
