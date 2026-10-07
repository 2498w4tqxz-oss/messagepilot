import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { BridgeClient } from "../client.js";
import { startProgress, updateProgress } from "./schema.js";
export function registerProgressTools(server: McpServer, client: BridgeClient) {
  const output = (value: unknown) => ({
    content: [{ type: "text" as const, text: JSON.stringify(value) }],
  });
  server.registerTool(
    "bridge_progress_start",
    {
      description:
        "Start a chat-scoped background-task status. Native text coalesces updates, allows at most four intermediate edits and reserves a final edit. Live cards require a user to share from the extension. Starting status does not execute the task.",
      inputSchema: { accountId: z.string(), input: startProgress },
    },
    async ({ accountId, input }) =>
      output(await client.request(accountId, "progress", "POST", input)),
  );
  server.registerTool(
    "bridge_progress_update",
    {
      description:
        "Report a step or terminal result with revision control and idempotency. Native output attachments are separate messages from worker-local paths; fileIds are authenticated card outputs. Cancelled describes task state; it does not stop the developer task. Inspect transport separately from task state.",
      inputSchema: {
        accountId: z.string(),
        jobId: z.string().uuid(),
        input: updateProgress,
      },
    },
    async ({ accountId, jobId, input }) =>
      output(
        await client.request(
          accountId,
          `progress/${jobId}/updates`,
          "POST",
          input,
        ),
      ),
  );
  server.registerTool(
    "bridge_progress_get",
    {
      description:
        "Read task state, revision, bounded history and native command receipts in an allowed chat.",
      inputSchema: { accountId: z.string(), jobId: z.string().uuid() },
    },
    async ({ accountId, jobId }) =>
      output(await client.request(accountId, `progress/${jobId}`)),
  );
}
