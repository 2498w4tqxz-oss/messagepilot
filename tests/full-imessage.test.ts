import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { Gateway } from "../src/gateway.js";
import { Worker } from "../src/worker.js";
import { FixtureTransport } from "../src/native.js";
import { BridgeClient } from "../src/client.js";
import {
  operations,
  readOperations,
  validateArgs,
  type Config,
  type Operation,
} from "../src/protocol.js";
import { toolSchemas } from "../src/tool-schemas.js";
import { chatOperations } from "../src/chat-scope.js";

const binary = resolve("native/.build/release/messagepilot-native");
const onMac = process.platform === "darwin" && existsSync(binary);
const inMinutes = (m: number) => new Date(Date.now() + m * 60_000).toISOString();

test("new iMessage operations are registered with schemas and argument rules", () => {
  for (const op of [
    "messages.get",
    "messages.reactions",
    "messages.sticker",
    "messages.sticker.attach",
    "messages.forward",
    "messages.schedule",
    "messages.scheduled.list",
    "messages.scheduled.cancel",
    "attachments.download",
    "media.create",
    "apps.messages.installed",
    "apps.messages.list",
    "apps.messages.open",
    "apps.messages.prompt",
    "chats.mute",
    "chats.pin",
    "chats.delete",
    "chats.notifyAnyway",
    "chats.details",
    "chats.rename",
    "chats.participants.add",
    "chats.participants.remove",
    "chats.leave",
  ] as const) {
    assert.ok(operations.includes(op), op);
    assert.ok(toolSchemas[op], op);
  }
  assert.ok(readOperations.has("messages.reactions"));
  assert.ok(!readOperations.has("messages.schedule"));
  // Destructive or cross-chat operations never inherit chat-scoped authority.
  for (const op of [
    "chats.delete",
    "chats.leave",
    "messages.forward",
    "apps.messages.prompt",
  ] as const)
    assert.ok(!chatOperations.has(op), op);
});

test("Send Later, forwarding and irreversible chat changes validate before dispatch", () => {
  const chat = { chatId: "any;-;+15550100100" };
  assert.doesNotThrow(() =>
    validateArgs("messages.schedule", { ...chat, text: "hi", sendAt: inMinutes(30) }),
  );
  for (const sendAt of [
    inMinutes(0.5),
    inMinutes(15 * 24 * 60),
    "2030-01-01T09:00:00",
    "tomorrow",
  ])
    assert.throws(
      () => validateArgs("messages.schedule", { ...chat, text: "hi", sendAt }),
      /Send Later|time zone/,
      sendAt,
    );
  assert.throws(
    () => validateArgs("messages.forward", { ...chat, messageId: "M" }),
    /to is required/,
  );
  assert.throws(() => validateArgs("chats.delete", chat), /confirm/);
  assert.doesNotThrow(() => validateArgs("chats.leave", { ...chat, confirm: true }));
  assert.throws(
    () => validateArgs("attachments.download", chat),
    /messageId is required/,
  );
  const media = toolSchemas["media.create"];
  assert.ok(media.safeParse({ kind: "card", title: "Open house" }).success);
  assert.ok(!media.safeParse({ kind: "card" }).success);
  assert.ok(!media.safeParse({ kind: "sticker" }).success);
  assert.ok(media.safeParse({ kind: "slideshow", sources: ["a.png"] }).success);
  assert.ok(
    toolSchemas["apps.interact"].safeParse({
      actions: [{ action: "pick", selector: { AXIdentifier: "send_later…" } }],
    }).success,
  );
});

test("gateway carries the new operations end to end through a worker", async (t) => {
  const tokens = {
    WORKER: "worker-" + "x".repeat(32),
    AGENT: "agent-" + "x".repeat(32),
  };
  const config: Config = {
    host: "127.0.0.1",
    port: 0,
    database: ":memory:",
    accounts: [{ id: "line", identity: "line@example.test", workerTokenEnv: "WORKER" }],
    agents: [{ id: "agent", tokenEnv: "AGENT", accounts: ["line"] }],
  };
  const g = new Gateway(config, tokens);
  const port = await g.listen();
  const native = new FixtureTransport("line@example.test");
  const worker = new Worker(
    {
      url: `ws://127.0.0.1:${port}/worker`,
      token: tokens.WORKER,
      accountId: "line",
      workerId: "w",
      identity: "line@example.test",
      spool: ":memory:",
    },
    native,
  );
  await worker.start();
  t.after(async () => {
    worker.close();
    await g.close();
  });
  const client = new BridgeClient(`http://127.0.0.1:${port}`, tokens.AGENT);
  const start = Date.now();
  while (!(await client.request("line", "capabilities")).online) {
    if (Date.now() - start > 3000) throw new Error("worker offline");
    await new Promise((r) => setTimeout(r, 10));
  }
  const chatId = "any;-;+15550100100";
  const cases: [Operation, Record<string, unknown>][] = [
    ["messages.react", { chatId, messageId: "M1", reaction: "🔥" }],
    ["messages.sticker.attach", { chatId, messageId: "M1", query: "heart" }],
    ["messages.schedule", { chatId, text: "Reminder", sendAt: inMinutes(90) }],
    ["messages.send", { chatId, filePaths: ["a.png", "b.png", "c.png"] }],
    ["attachments.download", { chatId, messageId: "M1", convert: "png" }],
    ["media.create", { kind: "sticker", text: "🎉" }],
    ["chats.rename", { chatId, name: "Open House Team" }],
  ];
  for (const [operation, args] of cases) {
    const command = await client.command("line", operation, args);
    const done = await client.wait("line", command.id);
    assert.equal(done.state, "completed", operation);
  }
  assert.deepEqual(
    native.calls.map((c) => c.operation),
    cases.map(([op]) => op),
  );
  // Zod defaults reach the worker (index 0 for sticker selection).
  assert.equal(native.calls[1]!.args.index, 0);
});

test(
  "compiled native worker advertises only operations the gateway knows",
  { skip: !onMac },
  (t) => {
    const root = mkdtempSync(join(tmpdir(), "mp-describe-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const config = join(root, "native.json");
    writeFileSync(
      config,
      JSON.stringify({
        accountId: "line",
        expectedIdentity: "line@example.test",
        expectedOSUser: userInfo().username,
        workspace: root,
        allowedBundles: ["com.apple.MobileSMS"],
        enableComputer: false,
        enableExperimentalEffects: true,
      }),
    );
    const out = spawnSync(binary, ["--describe", "--config", config], {
      encoding: "utf8",
    });
    assert.equal(out.status, 0, out.stderr);
    const caps = JSON.parse(out.stdout) as {
      operation: string;
      available: boolean;
      verification: string;
    }[];
    for (const c of caps)
      assert.ok(
        (operations as readonly string[]).includes(c.operation),
        `${c.operation} must be a gateway operation or the worker hello is rejected`,
      );
    const byName = Object.fromEntries(caps.map((c) => [c.operation, c]));
    assert.equal(byName["messages.schedule"]!.available, true);
    assert.equal(byName["computer.exec"]!.available, false);
    assert.equal(byName["files.write"]!.available, false);
  },
);

/** XML-plist property values: the reader also accepts them besides keyed archives. */
const plist = (inner: string) =>
  Buffer.from(
    `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">${inner}</plist>`,
  );

function accountsStore(path: string, username: string) {
  const db = new DatabaseSync(path);
  db.exec(`CREATE TABLE ZACCOUNTTYPE(Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER VARCHAR);
    CREATE TABLE ZACCOUNT(Z_PK INTEGER PRIMARY KEY, ZACTIVE INTEGER, ZACCOUNTTYPE INTEGER, ZUSERNAME VARCHAR);
    CREATE TABLE ZACCOUNTPROPERTY(Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZKEY VARCHAR, ZVALUE BLOB);
    INSERT INTO ZACCOUNTTYPE VALUES(1,'com.apple.account.IdentityServices');`);
  db.prepare("INSERT INTO ZACCOUNT VALUES(1,1,1,?)").run(username);
  db.prepare("INSERT INTO ZACCOUNTPROPERTY(ZOWNER,ZKEY,ZVALUE) VALUES(1,'handles',?)").run(
    plist(
      `<array><dict><key>uri</key><string>mailto:${username}</string></dict><dict><key>uri</key><string>tel:+15550100100</string></dict></array>`,
    ),
  );
  db.close();
}

function chatStore(path: string, logins: string[]) {
  const db = new DatabaseSync(path);
  db.exec(
    "CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, guid TEXT, account_login TEXT); CREATE TABLE message(ROWID INTEGER PRIMARY KEY, guid TEXT);",
  );
  for (const login of logins)
    db.prepare("INSERT INTO chat(guid, account_login) VALUES(?, ?)").run(
      "iMessage;-;+15550109999",
      login,
    );
  db.close();
}

test(
  "brand-new account with no chats passes the identity check through its iMessage registration",
  { skip: !onMac },
  (t) => {
    const root = mkdtempSync(join(tmpdir(), "mp-identity-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const accounts = join(root, "Accounts4.sqlite");
    accountsStore(accounts, "line@example.test");
    const run = (logins: string[], expected = "Line@Example.test") => {
      const chat = join(root, `chat-${logins.length}-${Math.random()}.db`);
      chatStore(chat, logins);
      const config = join(root, `native-${Math.random()}.json`);
      writeFileSync(
        config,
        JSON.stringify({
          accountId: "line",
          expectedIdentity: expected,
          expectedOSUser: userInfo().username,
          workspace: root,
          allowedBundles: [],
          enableComputer: false,
          enableExperimentalEffects: false,
          chatDatabase: chat,
          accountsDatabase: accounts,
        }),
      );
      const out = spawnSync(binary, ["--resolve-identity", "--config", config], {
        encoding: "utf8",
      });
      return { status: out.status, decision: JSON.parse(out.stdout) };
    };
    const fresh = run([]);
    assert.equal(fresh.status, 0);
    assert.equal(fresh.decision.source, "ids-account");
    assert.equal(fresh.decision.observed["chat.account_login"], 0);
    assert.equal(run([], "+1 (555) 010-0100").decision.source, "ids-account");
    const established = run(["E:line@example.test"]);
    assert.equal(established.decision.source, "chat.account_login");
    const other = run(["E:someone-else@example.test"]);
    assert.equal(other.status, 3);
    assert.match(other.decision.reason, /different account/);
    assert.equal(run([], "stranger@example.test").status, 3);
  },
);
