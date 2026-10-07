import test from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Gateway } from "../src/gateway.js";
import { Worker } from "../src/worker.js";
import { FixtureTransport } from "../src/native.js";

test("MCP discovers typed bridge tools and dispatches through an isolated fixture", async () => {
  const A = "agent-".padEnd(40, "x"),
    W = "worker-".padEnd(40, "x");
  const gateway = new Gateway(
    {
      host: "127.0.0.1",
      port: 0,
      database: ":memory:",
      accounts: [
        { id: "mcp", identity: "mcp@example.test", workerTokenEnv: "W" },
      ],
      agents: [{ id: "mcp", tokenEnv: "A", accounts: ["mcp"] }],
    },
    { A, W },
  );
  const port = await gateway.listen();
  const native = new FixtureTransport("mcp@example.test");
  const worker = new Worker(
    {
      url: `ws://127.0.0.1:${port}/worker`,
      token: W,
      accountId: "mcp",
      workerId: "mcp-fixture",
      identity: "mcp@example.test",
      spool: ":memory:",
    },
    native,
  );
  const client = new Client({ name: "messagepilot-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["--import", "tsx", "src/cli.ts", "mcp"],
    env: {
      MESSAGEPILOT_URL: `http://127.0.0.1:${port}`,
      MESSAGEPILOT_AGENT_TOKEN: A,
    },
  });
  try {
    await worker.start();
    await client.connect(transport);
    const list = await client.listTools();
    assert.ok(list.tools.find((t) => t.name === "apps_ios_run"));
    for (const name of [
      "bridge_registry_card",
      "bridge_computer_control",
      "mcp_connect",
      "mcp_tools_call",
      "imessage_run",
      "apple_tools_run",
      "device_activity_start",
      "apple_activity_push",
    ])
      assert.ok(
        list.tools.find((t) => t.name === name),
        `${name} must be discoverable`,
      );
    const send = list.tools.find((t) => t.name === "messages_send")!;
    assert.ok((send.inputSchema.properties as any).args.properties.chatId);
    const result = await client.callTool({
      name: "messages_send",
      arguments: {
        accountId: "mcp",
        args: { chatId: "fixture-only", text: "MCP test" },
        idempotencyKey: "mcp-send",
        waitMs: 1000,
      },
    });
    assert.equal(result.isError, undefined);
    const text = (result.content as any[])[0].text;
    assert.equal(JSON.parse(text).state, "completed");
    assert.equal(native.calls.length, 1);
  } finally {
    await client.close();
    worker.close();
    await gateway.close();
  }
});
