import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { resolve } from "node:path";
import { Registry, registryCard } from "../src/registry.js";
import { MCPHost } from "../src/mcp-host.js";
import { FixtureTransport } from "../src/native.js";
import { ToolkitTransport } from "../src/toolkit.js";
import { compileWorkflow, appCatalog } from "../src/imessage-apps.js";
import { activityPayload, providerToken } from "../src/activity-push.js";
import { appleToolCommand } from "../src/apple-tools.js";
import http from "node:http";
import { randomUUID } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";

test("registry requests stay on the official API, encode names/cursors and render selection cards without executing metadata", async () => {
  const urls: string[] = [];
  const sample = {
    servers: [
      {
        server: {
          name: "org.test/echo",
          version: "1.0.0",
          description: "untrusted metadata",
          title: "Echo",
        },
      },
    ],
    metadata: { nextCursor: "next" },
  };
  const registry = new Registry((async (url: any) => {
    urls.push(String(url));
    return new Response(JSON.stringify(sample));
  }) as typeof fetch);
  const data = await registry.search("hello world", "a/b", 10);
  assert.equal(new URL(urls[0]!).host, "registry.modelcontextprotocol.io");
  assert.equal(new URL(urls[0]!).searchParams.get("cursor"), "a/b");
  await registry.get("org.test/echo", "1.0.0");
  assert.ok(urls[1]!.includes("org.test%2Fecho/versions/1.0.0"));
  const card = registryCard(data);
  assert.equal(card.items[0].action, card.actions[0]);
  assert.equal(card.items[0].subtitle, "1.0.0 · untrusted metadata");
});
test("worker MCP client uses actual stdio protocol for tools/resources/prompts and isolates inherited secrets", async () => {
  const host = new MCPHost({
    PATH: process.env.PATH,
    BRIDGE_SECRET: "must-not-inherit",
    FIXTURE_SOURCE: "explicit",
  });
  try {
    await host.connect({
      id: "fixture",
      transport: "stdio",
      command: process.execPath,
      arguments: ["--import", "tsx", resolve("tests/fixtures/mcp-server.ts")],
      environmentRefs: { FIXTURE_VALUE: "FIXTURE_SOURCE" },
    });
    const tools = (await host.execute("mcp.tools.list", {
      id: "fixture",
    })) as any;
    assert.ok(tools.tools.find((t: any) => t.name === "echo"));
    const result = (await host.execute("mcp.tools.call", {
      id: "fixture",
      name: "echo",
      arguments: { text: "through MCP" },
    })) as any;
    assert.equal(result.content[0].text, "through MCP");
    const env = (await host.execute("mcp.tools.call", {
      id: "fixture",
      name: "environment",
    })) as any;
    assert.deepEqual(JSON.parse(env.content[0].text), {
      secret: null,
      fixture: "explicit",
    });
    assert.equal(
      (
        (await host.execute("mcp.resources.read", {
          id: "fixture",
          uri: "fixture://hello",
        })) as any
      ).contents[0].text,
      "fixture resource",
    );
    assert.equal(
      (
        (await host.execute("mcp.prompts.get", {
          id: "fixture",
          name: "fixture",
          arguments: { text: "prompt" },
        })) as any
      ).messages[0].content.text,
      "prompt",
    );
    await assert.rejects(
      host.execute("mcp.tools.list", { id: "other-account" }),
      /not found/,
    );
    await host.execute("mcp.disconnect", { id: "fixture" });
    assert.equal(host.list().length, 0);
  } finally {
    host.close();
  }
});
test("MCP remote transport rejects cleartext nonlocal servers and unresolved secrets", async () => {
  const host = new MCPHost({});
  await assert.rejects(
    host.connect({
      id: "bad",
      transport: "streamable-http",
      url: "http://example.com/mcp",
    }),
    /HTTPS/,
  );
  await assert.rejects(
    host.connect({
      id: "bad",
      transport: "streamable-http",
      url: "https://example.com/mcp",
      headerRefs: { Authorization: "MISSING" },
    }),
    /Missing/,
  );
  await assert.rejects(
    host.connect({
      id: "bad",
      transport: "stdio",
      command: "/usr/bin/false",
      registry: { name: "example/test", version: "latest" },
    }),
    /Pin/,
  );
});
test("worker MCP client speaks Streamable HTTP with explicitly configured authorization", async () => {
  const server = new McpServer({ name: "http-fixture", version: "1.0.0" });
  server.registerTool("fixture", {}, async () => ({
    content: [{ type: "text", text: "remote fixture" }],
  }));
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: randomUUID,
  });
  await server.connect(transport);
  const headers: string[] = [];
  const listener = http.createServer(async (req, res) => {
    headers.push(req.headers.authorization ?? "");
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk);
    const data = Buffer.concat(chunks).toString();
    await transport.handleRequest(
      req,
      res,
      data ? JSON.parse(data) : undefined,
    );
  });
  await new Promise<void>((resolve) =>
    listener.listen(0, "127.0.0.1", resolve),
  );
  const address = listener.address() as import("node:net").AddressInfo;
  const host = new MCPHost({ FIXTURE_AUTH: "Bearer fixture-only" });
  try {
    await host.connect({
      id: "http",
      transport: "streamable-http",
      url: `http://127.0.0.1:${address.port}/mcp`,
      headerRefs: { Authorization: "FIXTURE_AUTH" },
    });
    const result = (await host.execute("mcp.tools.call", {
      id: "http",
      name: "fixture",
    })) as any;
    assert.equal(result.content[0].text, "remote fixture");
    assert.ok(
      headers.length >= 2 && headers.every((h) => h === "Bearer fixture-only"),
    );
    await host.execute("mcp.disconnect", { id: "http" });
  } finally {
    host.close();
    await server.close();
    listener.closeAllConnections();
    await new Promise<void>((resolve) => listener.close(() => resolve()));
  }
});
test("iMessage recipes require observed selectors and preserve native poll and scheduling semantics", () => {
  assert.throws(
    () => compileWorkflow({ workflow: "giphy.send", values: { query: "cat" } }),
    /selector/,
  );
  const selectors = Object.fromEntries(
    ["conversation", "add", "polls", "option1", "option2", "send"].map((k) => [
      k,
      { identifier: `observed-${k}` },
    ]),
  );
  const poll = compileWorkflow({
    workflow: "polls.create",
    selectors,
    values: { options: ["A", "B"] },
  });
  assert.equal(poll.recipe.bundleId, "com.apple.MobileSMS");
  assert.deepEqual(
    poll.recipe.actions.filter((s) => s.action === "type").map((s) => s.text),
    ["A", "B"],
  );
  assert.equal(poll.delivery, "not-asserted");
  assert.throws(
    () =>
      compileWorkflow({
        workflow: "sendlater.create",
        selectors: {
          conversation: { identifier: "c" },
          add: { identifier: "a" },
          sendLater: { identifier: "s" },
        },
        values: { text: "later" },
      }),
    /dateActions/,
  );
  assert.ok(appCatalog().apps.find((a) => a.id === "giphy"));
});
test("toolkit keeps Apple tools on its native worker and validates registry pins before connecting", async () => {
  const native = new FixtureTransport("fixture@example.test");
  const registry = new Registry(
    (async () =>
      new Response(
        JSON.stringify({
          server: {
            version: "1.0.0",
            remotes: [
              { type: "streamable-http", url: "https://example.test/mcp" },
            ],
          },
        }),
      )) as typeof fetch,
  );
  const transport = new ToolkitTransport(native, true, registry);
  try {
    await transport.execute("apple.tools.run", {
      tool: "simctl",
      arguments: ["help"],
    });
    assert.deepEqual(native.calls[0]?.args.arguments, ["simctl", "help"]);
    await assert.rejects(
      transport.execute("mcp.connect", {
        id: "bad",
        transport: "streamable-http",
        url: "https://other.test/mcp",
        registry: { name: "example/test", version: "1.0.0" },
      }),
      /does not match/,
    );
    await assert.rejects(
      new ToolkitTransport(native, false).execute("mcp.connections", {}),
      /Enable/,
    );
    assert.throws(() => appleToolCommand("unknown", []), /Unknown/);
  } finally {
    transport.close();
  }
});
test("ActivityKit payload and provider signature are validated without contacting APNs", () => {
  assert.throws(
    () => activityPayload({ event: "start", contentState: {} }),
    /requires/,
  );
  const payload = JSON.parse(
    activityPayload(
      { event: "update", contentState: { title: "Progress", progress: 0.5 } },
      123,
    ),
  );
  assert.equal(payload.aps.timestamp, 123);
  assert.equal(payload.aps["content-state"].progress, 0.5);
  assert.throws(
    () =>
      activityPayload({
        event: "update",
        contentState: { text: "a".repeat(5000) },
      }),
    /4096/,
  );
  const keys = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const jwt = providerToken(
    keys.privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    "KEY",
    "TEAM",
    123,
  );
  const [header, body, signature] = jwt.split(".");
  assert.equal(
    JSON.parse(Buffer.from(body!, "base64url").toString()).iss,
    "TEAM",
  );
  assert.ok(
    verify(
      "sha256",
      Buffer.from(`${header}.${body}`),
      { key: keys.publicKey, dsaEncoding: "ieee-p1363" },
      Buffer.from(signature!, "base64url"),
    ),
  );
});
