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
      extensionHooks: [
        {
          id: "invites",
          accountId: "mcp",
          chatId: "fixture-only",
          feature: "invites",
          url: "http://127.0.0.1:1/callback",
          signingSecretEnv: "S",
          requestAgentIds: ["mcp"],
          observerAgentIds: ["mcp"],
          includeCoordinates: false,
          allowLoopbackHttp: true,
        },
      ],
    },
    { A, W, S: "s".repeat(40) },
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
      "bridge_file_upload",
      "bridge_file",
      "bridge_library_save",
      "bridge_library_read",
      "bridge_google_workspace",
      "bridge_analytics",
      "bridge_analytics_observe",
      "bridge_container_plan",
      "bridge_progress_start",
      "bridge_progress_update",
      "bridge_progress_get",
      "bridge_extension_request",
      "bridge_extension_observe",
      "bridge_extension_status",
      "bridge_extension_claim",
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
    const progressResult = await client.callTool({
      name: "bridge_progress_start",
      arguments: {
        accountId: "mcp",
        input: {
          chatId: "fixture-only",
          title: "Task",
          detail: "Starting",
          mode: "live_card",
          idempotencyKey: "progress-mcp",
        },
      },
    });
    assert.equal(progressResult.isError, undefined);
    const progress = JSON.parse((progressResult.content as any[])[0].text);
    const progressUpdate = await client.callTool({
      name: "bridge_progress_update",
      arguments: {
        accountId: "mcp",
        jobId: progress.id,
        input: {
          expectedRevision: 1,
          idempotencyKey: "progress-done",
          state: "completed",
          detail: "Done",
        },
      },
    });
    assert.equal(progressUpdate.isError, undefined);
    const progressRead = await client.callTool({
      name: "bridge_progress_get",
      arguments: { accountId: "mcp", jobId: progress.id },
    });
    assert.equal(
      JSON.parse((progressRead.content as any[])[0].text).state,
      "completed",
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
    const hookResult = await client.callTool({
      name: "bridge_extension_request",
      arguments: {
        accountId: "mcp",
        hookId: "invites",
        payload: { idempotencyKey: "mcp-hook", action: "inspect" },
      },
    });
    assert.equal(hookResult.isError, undefined);
    const request = JSON.parse((hookResult.content as any[])[0].text);
    assert.equal(request.state, "requested");
    const claim = await client.callTool({
      name: "bridge_extension_claim",
      arguments: { accountId: "mcp", hookId: "invites", requestId: request.id },
    });
    assert.equal(
      JSON.parse((claim.content as any[])[0].text).state,
      "executing",
    );
    const report = await client.callTool({
      name: "bridge_extension_observe",
      arguments: {
        accountId: "mcp",
        hookId: "invites",
        payload: {
          sourceId: "mcp-observation",
          observedAt: Date.now(),
          state: "unavailable",
          requestId: request.id,
          outcome: "blocked",
          evidence: { kind: "fixture", reference: "no-phone-fixture" },
        },
      },
    });
    assert.equal(report.isError, undefined);
    const status = await client.callTool({
      name: "bridge_extension_status",
      arguments: {
        accountId: "mcp",
        hookId: "invites",
        resource: "requests",
        requestId: request.id,
      },
    });
    assert.equal(
      JSON.parse((status.content as any[])[0].text).state,
      "blocked",
    );
    assert.equal(
      native.calls.length,
      1,
      "Hook queue must not pretend to execute native transport",
    );
  } finally {
    await client.close();
    worker.close();
    await gateway.close();
  }
});
