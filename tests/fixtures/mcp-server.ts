import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
const server = new McpServer({ name: "fixture-only", version: "1.0.0" });
server.registerTool(
  "echo",
  { inputSchema: { text: z.string() } },
  async ({ text }) => ({ content: [{ type: "text", text }] }),
);
server.registerTool("environment", {}, async () => ({
  content: [
    {
      type: "text",
      text: JSON.stringify({
        secret: process.env.BRIDGE_SECRET ?? null,
        fixture: process.env.FIXTURE_VALUE ?? null,
      }),
    },
  ],
}));
server.registerResource("fixture", "fixture://hello", {}, async (uri) => ({
  contents: [{ uri: uri.href, text: "fixture resource" }],
}));
server.registerPrompt(
  "fixture",
  { argsSchema: { text: z.string() } },
  async ({ text }) => ({
    messages: [{ role: "user", content: { type: "text", text } }],
  }),
);
await server.connect(new StdioServerTransport());
