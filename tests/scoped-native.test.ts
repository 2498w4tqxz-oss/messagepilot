import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
const binary = resolve("native/.build/release/messagepilot-scoped");
test(
  "compiled scoped native worker queries only enrolled chat and rejects foreign message IDs before UI",
  { skip: process.platform !== "darwin" || !existsSync(binary) },
  (t) => {
    const root = mkdtempSync(join(tmpdir(), "messagepilot-native-scope-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const database = join(root, "fixture.sqlite"),
      config = join(root, "config.json");
    const db = new DatabaseSync(database);
    db.exec(`CREATE TABLE chat(ROWID INTEGER PRIMARY KEY,guid TEXT,chat_identifier TEXT,service_name TEXT);
 CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
 CREATE TABLE message(ROWID INTEGER PRIMARY KEY,guid TEXT,text TEXT,is_from_me INTEGER,date INTEGER,date_delivered INTEGER,date_read INTEGER,date_edited INTEGER,date_retracted INTEGER,error INTEGER,is_sent INTEGER,is_delivered INTEGER,associated_message_guid TEXT,associated_message_type INTEGER,associated_message_emoji TEXT,expressive_send_style_id TEXT,attributedBody BLOB,message_summary_info BLOB,thread_originator_guid TEXT,cache_has_attachments INTEGER);
 INSERT INTO chat VALUES(1,'allowed','+15555550100','iMessage'),(2,'secret','+15555550200','iMessage');
 INSERT INTO message(ROWID,guid,text,is_from_me,date) VALUES(1,'own','allowed fixture',1,0),(2,'foreign','SECRET MUST NEVER LEAVE',1,0),(3,'incoming','received fixture',0,0);
 INSERT INTO chat_message_join VALUES(1,1),(2,2),(1,3);`);
    db.close();
    writeFileSync(
      config,
      JSON.stringify({
        accountId: "fixture",
        expectedIdentity: "fixture",
        expectedOSUser: userInfo().username,
        allowedChatIds: ["allowed"],
        database,
        enableUI: false,
      }),
    );
    const requests = [
      { id: "read", method: "messages.list", params: { chatId: "allowed" } },
      { id: "other", method: "messages.list", params: { chatId: "secret" } },
      {
        id: "search",
        method: "messages.search",
        params: { chatId: "allowed", query: "SECRET" },
      },
      {
        id: "unscoped",
        method: "messages.search",
        params: { query: "SECRET" },
      },
      {
        id: "cross-message",
        method: "messages.edit",
        params: {
          chatId: "allowed",
          messageId: "foreign",
          text: "replacement",
        },
      },
      {
        id: "cross-reply",
        method: "messages.send",
        params: { chatId: "allowed", replyTo: "foreign", text: "reply" },
      },
      {
        id: "expired",
        method: "messages.unsend",
        params: { chatId: "allowed", messageId: "own" },
      },
      {
        id: "not-own",
        method: "messages.edit",
        params: {
          chatId: "allowed",
          messageId: "incoming",
          text: "replacement",
        },
      },
      {
        id: "ui-disabled",
        method: "messages.send",
        params: { chatId: "allowed", text: "must not open Messages" },
      },
      {
        id: "escape",
        method: "computer.exec",
        params: { chatId: "allowed", executable: "/bin/echo" },
      },
    ];
    const run = spawnSync(binary, ["--live", "--config", config], {
      input: requests.map((r) => JSON.stringify(r)).join("\n") + "\n",
      encoding: "utf8",
      timeout: 10000,
    });
    assert.equal(run.status, 0, run.stderr);
    assert.ok(!run.stdout.includes("SECRET MUST NEVER LEAVE"));
    const r = Object.fromEntries(
      run.stdout
        .trim()
        .split("\n")
        .map((line) => {
          const v = JSON.parse(line);
          return [v.id, v];
        }),
    );
    assert.equal(r.read.result.items.length, 2);
    assert.deepEqual(r.search.result.items, []);
    assert.match(r.other.error, /chat_forbidden/);
    assert.match(r.unscoped.error, /chatId/);
    assert.match(r["cross-message"].error, /not in permitted chat/);
    assert.match(r["cross-reply"].error, /not in permitted chat/);
    assert.match(r.expired.error, /time window/);
    assert.match(r["not-own"].error, /Only own/);
    assert.match(r.escape.error, /unavailable/);
    assert.match(r["ui-disabled"].error, /enableUI/);
    // Verify no writable connection or schema changes were introduced by the native process.
    const check = new DatabaseSync(database, { readOnly: true });
    assert.equal(
      check.prepare("SELECT text FROM message WHERE guid='foreign'").get()!
        .text,
      "SECRET MUST NEVER LEAVE",
    );
    check.close();
  },
);
