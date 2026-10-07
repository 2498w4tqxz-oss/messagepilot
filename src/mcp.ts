import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { BridgeClient } from "./client.js";
import { operations, readOperations } from "./protocol.js";
import { toolSchemas } from "./tool-schemas.js";
export async function startMCP(url: string, token: string) {
  const client = new BridgeClient(url, token),
    server = new McpServer({ name: "messagepilot", version: "0.1.0" });
  const output = (value: unknown) => ({
    content: [{ type: "text" as const, text: JSON.stringify(value) }],
  });
  server.registerTool(
    "bridge_capabilities",
    {
      description:
        "List this Apple account’s current transport capabilities and verification level.",
      inputSchema: { accountId: z.string() },
    },
    async ({ accountId }) =>
      output(await client.request(accountId, "capabilities")),
  );
  for (const operation of operations) {
    server.registerTool(
      operation.replaceAll(".", "_"),
      {
        description: `Execute ${operation} on an isolated Apple account. ${readOperations.has(operation) ? "Read operation." : "May change Apple account or computer state."} Returns a durable command receipt. Check bridge_command_status if queued/executing. Media paths refer to the worker computer.`,
        inputSchema: {
          accountId: z.string(),
          args: toolSchemas[operation],
          idempotencyKey: z.string().min(1),
          waitMs: z.number().int().min(0).max(60000).default(0),
        },
        annotations: {
          readOnlyHint: readOperations.has(operation),
          destructiveHint: ["messages.unsend", "computer.exec"].includes(
            operation,
          ),
          idempotentHint: true,
          openWorldHint: true,
        },
      },
      async ({ accountId, args, idempotencyKey, waitMs }) => {
        try {
          const command = await client.command(
            accountId,
            operation,
            args,
            idempotencyKey,
          );
          return output(
            waitMs ? await client.wait(accountId, command.id, waitMs) : command,
          );
        } catch (e) {
          return { ...output({ error: String(e) }), isError: true };
        }
      },
    );
  }
  server.registerTool(
    "bridge_command_status",
    {
      description:
        "Read a command receipt. completed means the adapter returned; inspect its receipt for Apple delivery evidence.",
      inputSchema: { accountId: z.string(), commandId: z.string() },
    },
    async ({ accountId, commandId }) =>
      output(
        await client.request(
          accountId,
          `commands/${encodeURIComponent(commandId)}`,
        ),
      ),
  );
  server.registerTool(
    "bridge_events",
    {
      description:
        "Read replayable account-scoped transport events after a numeric cursor.",
      inputSchema: {
        accountId: z.string(),
        after: z.number().int().min(0).default(0),
      },
    },
    async ({ accountId, after }) =>
      output(await client.request(accountId, `events?after=${after}`)),
  );
  server.registerTool(
    "bridge_card_put",
    {
      description:
        "Publish versioned data for the MessagePilot iMessage carousel/card extension. Does not itself send an iMessage.",
      inputSchema: {
        accountId: z.string(),
        cardId: z.string(),
        expectedRevision: z.number().int().min(0),
        body: z.record(z.unknown()),
      },
    },
    async ({ accountId, cardId, expectedRevision, body }) =>
      output(
        await client.request(
          accountId,
          `cards/${encodeURIComponent(cardId)}`,
          "PUT",
          { expectedRevision, body },
        ),
      ),
  );
  await server.connect(new StdioServerTransport());
  return server;
}
