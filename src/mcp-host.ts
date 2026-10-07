import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { z } from "zod";

const refs = z.record(z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/)).default({});
export const connectionSchema = z
  .object({
    id: z.string().regex(/^[a-zA-Z0-9_-]{1,80}$/),
    transport: z.enum(["stdio", "streamable-http", "sse"]),
    command: z.string().startsWith("/").optional(),
    arguments: z.array(z.string()).default([]),
    url: z.string().url().optional(),
    environmentRefs: refs,
    headerRefs: refs,
    registry: z
      .object({
        name: z.string(),
        version: z
          .string()
          .refine((v) => v !== "latest", "Pin a concrete registry version"),
      })
      .optional(),
  })
  .strict();
type Connection = z.infer<typeof connectionSchema>;
export class MCPHost {
  private clients = new Map<string, { client: Client; config: Connection }>();
  constructor(private env = process.env) {}
  private secrets(refs: Record<string, string>) {
    return Object.fromEntries(
      Object.entries(refs).map(([key, ref]) => {
        const value = this.env[ref];
        if (!value)
          throw new Error(`Missing worker environment variable ${ref}`);
        return [key, value];
      }),
    );
  }
  list() {
    return [...this.clients].map(([id, { config, client }]) => ({
      id,
      transport: config.transport,
      registry: config.registry,
      server: client.getServerVersion(),
      capabilities: client.getServerCapabilities(),
    }));
  }
  async connect(input: unknown) {
    const config = connectionSchema.parse(input);
    if (this.clients.has(config.id))
      throw new Error(
        "Connection already exists; disconnect before replacing it",
      );
    const client = new Client({
      name: "messagepilot-worker",
      version: "0.1.0",
    });
    let transport;
    if (config.transport === "stdio") {
      if (!config.command)
        throw new Error("Absolute executable path required for stdio");
      // Do not pass account/bridge credentials to child MCP servers by default.
      transport = new StdioClientTransport({
        command: config.command,
        args: config.arguments,
        env: {
          PATH: this.env.PATH ?? "/usr/bin:/bin",
          ...this.secrets(config.environmentRefs),
        },
        stderr: "pipe",
      });
      transport.stderr?.on("data", () => {}); // Drain logs without forwarding secrets or blocking the child.
    } else {
      if (!config.url) throw new Error("URL required");
      const url = new URL(config.url);
      if (
        url.username ||
        url.password ||
        (url.protocol !== "https:" &&
          !(
            url.protocol === "http:" &&
            ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
          ))
      )
        throw new Error(
          "Remote MCP servers require HTTPS; local HTTP is allowed",
        );
      const options = {
        requestInit: {
          headers: this.secrets(config.headerRefs),
          redirect: "error" as const,
        },
      };
      transport =
        config.transport === "sse"
          ? new SSEClientTransport(url, options)
          : new StreamableHTTPClientTransport(url, options);
    }
    try {
      await client.connect(transport, { timeout: 20000 });
      this.clients.set(config.id, { client, config });
      client.onclose = () => this.clients.delete(config.id);
      return this.list().find((c) => c.id === config.id);
    } catch (error) {
      await transport.close().catch(() => {});
      throw error;
    }
  }
  private client(id: string) {
    const c = this.clients.get(id);
    if (!c)
      throw new Error(
        "MCP connection not found; connect it inside this account worker",
      );
    return c.client;
  }
  async execute(operation: string, a: Record<string, any>) {
    if (operation === "mcp.connections") return this.list();
    if (operation === "mcp.connect") return this.connect(a);
    if (operation === "mcp.disconnect") {
      const c = this.client(a.id);
      await c.close();
      this.clients.delete(a.id);
      return { disconnected: true };
    }
    const c = this.client(a.id);
    switch (operation) {
      case "mcp.tools.list":
        return c.listTools({ cursor: a.cursor });
      case "mcp.tools.call":
        return c.callTool(
          { name: a.name, arguments: a.arguments ?? {} },
          undefined,
          { timeout: 60000 },
        );
      case "mcp.resources.list":
        return c.listResources({ cursor: a.cursor });
      case "mcp.resources.read":
        return c.readResource({ uri: a.uri });
      case "mcp.prompts.list":
        return c.listPrompts({ cursor: a.cursor });
      case "mcp.prompts.get":
        return c.getPrompt({ name: a.name, arguments: a.arguments ?? {} });
      default:
        throw new Error("Unknown MCP operation");
    }
  }
  close() {
    for (const { client } of this.clients.values())
      void client.close().catch(() => {});
    this.clients.clear();
  }
}
