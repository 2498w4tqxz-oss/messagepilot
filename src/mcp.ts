import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { containerPlan, containerPlanInput } from "./container-plan.js";
import { analyticsEvent } from "./analytics.js";
import { workspaceInput } from "./google-workspace.js";
import { assetInput } from "./library.js";
import { BridgeClient } from "./client.js";
import { operations, readOperations } from "./protocol.js";
import { toolSchemas } from "./tool-schemas.js";
import { registryCard } from "./registry.js";
import {
  hookRequestSchema,
  hookObservationSchema,
} from "./extension-hook-schema.js";
export async function startMCP(url: string, token: string) {
  const client = new BridgeClient(url, token),
    server = new McpServer({ name: "messagepilot", version: "0.1.0" });
  const output = (value: unknown) => ({
    content: [{ type: "text" as const, text: JSON.stringify(value) }],
  });
  server.registerTool(
    "bridge_container_plan",
    {
      description:
        "Produce a pinned-image Apple container launch plan for a Linux agent connected to a Mac Messages worker. Does not install, pull, launch, provision Apple accounts or grant Mac desktop access.",
      inputSchema: containerPlanInput.shape,
    },
    async (input) => output(containerPlan(input)),
  );
  server.registerTool(
    "bridge_analytics_observe",
    {
      description:
        "Record an explicit observation in an opt-in account/chat analytics policy. Require real source evidence; never infer read receipts from send success. Collector source is reported, not Apple-verified.",
      inputSchema: { accountId: z.string(), event: analyticsEvent },
    },
    async ({ accountId, event }) =>
      output(
        await client.request(
          accountId,
          "analytics/observations",
          "POST",
          event,
        ),
      ),
  );
  server.registerTool(
    "bridge_analytics",
    {
      description:
        "Read opt-in event counts, reactions, media, action usage and matched read/delivery latency; or retrieve character/message-bounded context when text collection is enabled.",
      inputSchema: {
        accountId: z.string(),
        chatId: z.string(),
        view: z.enum(["report", "context", "events"]),
        since: z.number().int().optional(),
        until: z.number().int().optional(),
      },
    },
    async ({ accountId, chatId, view, since, until }) =>
      output(
        await client.request(
          accountId,
          `analytics/${view}?${new URLSearchParams({ chatId, ...(since !== undefined ? { since: String(since) } : {}), ...(until !== undefined ? { until: String(until) } : {}) })}`,
        ),
      ),
  );
  server.registerTool(
    "bridge_google_workspace",
    {
      description:
        "Call a configured Google Workspace connection through fixed official Google API routes. Connection grants bind account, chat, agent and actions. OAuth is developer-provisioned. Writes are never automatically retried. Gmail send requires an explicit grant and caller authorization.",
      inputSchema: {
        accountId: z.string(),
        connectionId: z.string(),
        input: workspaceInput,
      },
    },
    async ({ accountId, connectionId, input }) =>
      output(
        await client.request(
          accountId,
          `workspace/${encodeURIComponent(connectionId)}/actions`,
          "POST",
          input,
        ),
      ),
  );
  server.registerTool(
    "bridge_library_save",
    {
      description:
        "Create or revise a reusable asset in a chat-bound backend library. Immutable versions, expectedRevision concurrency check and content-sensitive idempotency. Large content belongs in files.",
      inputSchema: {
        accountId: z.string(),
        assetId: z.string().uuid().optional(),
        asset: assetInput,
      },
    },
    async ({ accountId, assetId, asset }) =>
      output(
        await client.request(
          accountId,
          `library${assetId ? `/${assetId}` : ""}`,
          "POST",
          asset,
        ),
      ),
  );
  server.registerTool(
    "bridge_library_read",
    {
      description:
        "List current chat assets or read an immutable revision. Backend can be local SQLite or a configured developer-hosted database adapter.",
      inputSchema: {
        accountId: z.string(),
        chatId: z.string(),
        assetId: z.string().uuid().optional(),
        revision: z.number().int().positive().optional(),
      },
    },
    async ({ accountId, chatId, assetId, revision }) =>
      output(
        await client.request(
          accountId,
          `library${assetId ? `/${assetId}` : ""}?${new URLSearchParams({ chatId, ...(revision ? { revision: String(revision) } : {}) })}`,
        ),
      ),
  );
  server.registerTool(
    "bridge_file_upload",
    {
      description:
        "Upload up to 512 KiB decoded bytes, bound to an exact permitted chat. Use binary HTTP upload for larger files. Never supplies a server-local path.",
      inputSchema: {
        accountId: z.string(),
        chatId: z.string(),
        name: z.string(),
        base64: z
          .string()
          .max(699052)
          .regex(
            /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/,
          ),
      },
    },
    async ({ accountId, chatId, name, base64 }) => {
      const data = Buffer.from(base64, "base64");
      if (data.length > 524288)
        throw new Error("Use HTTP upload for files larger than 512 KiB");
      return output(await client.upload(accountId, chatId, name, data));
    },
  );
  server.registerTool(
    "bridge_file",
    {
      description:
        "List chat-bound files, inspect/extract bounded text and metadata, request a cached preview, or obtain authenticated download/preview routes. Prepare is asynchronous. Unknown types retain original bytes. No native delivery is implied.",
      inputSchema: {
        accountId: z.string(),
        action: z.enum([
          "list",
          "info",
          "read",
          "prepare",
          "formats",
          "download",
        ]),
        chatId: z.string().optional(),
        fileId: z.string().uuid().optional(),
      },
    },
    async ({ accountId, action, chatId, fileId }) => {
      if (action === "formats")
        return output(await client.request(accountId, "files/formats"));
      if (action === "list") {
        if (!chatId) throw new Error("chatId required");
        return output(
          await client.request(
            accountId,
            `files?${new URLSearchParams({ chatId })}`,
          ),
        );
      }
      if (!fileId) throw new Error("fileId required");
      const result = await client.request(
        accountId,
        `files/${fileId}${["read", "prepare"].includes(action) ? `/${action}` : ""}`,
        action === "prepare" ? "POST" : "GET",
      );
      return output(
        action === "download"
          ? {
              file: result,
              downloadPath: `/v1/accounts/${encodeURIComponent(accountId)}/files/${fileId}/download`,
              previewPath: `/v1/accounts/${encodeURIComponent(accountId)}/files/${fileId}/preview`,
              authentication:
                "Bearer token with files.read and file chat access required",
            }
          : result,
      );
    },
  );
  for (const [name, schema, route] of [
    ["request", hookRequestSchema, "requests"],
    ["observe", hookObservationSchema, "observations"],
  ] as const) {
    server.registerTool(
      `bridge_extension_${name}`,
      {
        description:
          name === "request"
            ? "Queue an Invites, Location or Check In workflow for an enrolled agent. Does not execute Apple UI; requested is not completed. Hook fixes the account, chat and callback destination."
            : "Report a verified native extension observation. The gateway labels this agent-reported, not an Apple-signed event. Never infer Check In arrival or safety state.",
        inputSchema: {
          accountId: z.string(),
          hookId: z.string(),
          payload: schema,
        },
      },
      async ({ accountId, hookId, payload }) =>
        output(
          await client.request(
            accountId,
            `extension-hooks/${encodeURIComponent(hookId)}/${route}`,
            "POST",
            payload,
          ),
        ),
    );
  }
  server.registerTool(
    "bridge_extension_status",
    {
      description:
        "List extension requests, inspect one request, or inspect durable callback deliveries. A delivered webhook does not prove Apple UI success.",
      inputSchema: {
        accountId: z.string(),
        hookId: z.string(),
        resource: z.enum(["requests", "deliveries"]),
        requestId: z.string().uuid().optional(),
      },
    },
    async ({ accountId, hookId, resource, requestId }) =>
      output(
        await client.request(
          accountId,
          `extension-hooks/${encodeURIComponent(hookId)}/${resource}${resource === "requests" && requestId ? `/${requestId}` : ""}`,
        ),
      ),
  );
  server.registerTool(
    "bridge_extension_claim",
    {
      description:
        "Claim an extension request before operating the enrolled device. A second claim fails. Reconcile uncertain actions after restart; do not blindly repeat them.",
      inputSchema: {
        accountId: z.string(),
        hookId: z.string(),
        requestId: z.string().uuid(),
      },
    },
    async ({ accountId, hookId, requestId }) =>
      output(
        await client.request(
          accountId,
          `extension-hooks/${encodeURIComponent(hookId)}/requests/${requestId}/claim`,
          "POST",
          {},
        ),
      ),
  );
  server.registerTool(
    "bridge_computer_control",
    {
      description:
        "Claim, renew, inspect or release exclusive agent control of the account's dedicated virtual computer. Renew before expiry. Raw keyboard/pointer input requires a lease. Does not transfer control of the host's personal desktop.",
      inputSchema: {
        accountId: z.string(),
        action: z.enum(["claim", "renew", "status", "release"]),
        leaseId: z.string().optional(),
        ttlSeconds: z.number().int().min(15).max(900).default(120),
      },
    },
    async ({ accountId, action, leaseId, ttlSeconds }) =>
      output(
        await client.request(
          accountId,
          "control",
          action === "status"
            ? "GET"
            : action === "release"
              ? "DELETE"
              : "POST",
          action === "status" ? undefined : { leaseId, ttlSeconds },
        ),
      ),
  );
  server.registerTool(
    "bridge_registry_card",
    {
      description:
        "Search the Official MCP Registry through the enrolled worker and publish a browsable iMessage card. Card selection produces a scoped event for the external agent; no automatic installation or tool execution. Send the card using the installed MessagePilot extension.",
      inputSchema: {
        accountId: z.string(),
        search: z.string().default(""),
        cardId: z.string(),
        expectedRevision: z.number().int().min(0),
        idempotencyKey: z.string(),
      },
    },
    async ({ accountId, search, cardId, expectedRevision, idempotencyKey }) => {
      const queued = await client.command(
        accountId,
        "mcp.registry.search",
        { search, limit: 20 },
        idempotencyKey,
      );
      const receipt = await client.wait(accountId, queued.id, 25000);
      if (receipt.state !== "completed") return output(receipt);
      return output(
        await client.request(
          accountId,
          `cards/${encodeURIComponent(cardId)}`,
          "PUT",
          { expectedRevision, body: registryCard(receipt.result) },
        ),
      );
    },
  );
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
