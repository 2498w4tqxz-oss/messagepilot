import { PilotError } from "./errors.js";
import { z } from "zod";
import { analyticsPolicy } from "./analytics.js";
import { workspaceConfig } from "./google-workspace.js";
import { extensionHookSchema } from "./extension-hook-schema.js";

export const operations = [
  "device.auth.biometric",
  "device.auth.passkey",
  "device.surface.publish",
  "device.activity.list",
  "device.activity.start",
  "device.activity.update",
  "device.activity.end",
  "apple.activity.push",
  "mcp.registry.search",
  "mcp.registry.get",
  "mcp.connections",
  "mcp.connect",
  "mcp.disconnect",
  "mcp.tools.list",
  "mcp.tools.call",
  "mcp.resources.list",
  "mcp.resources.read",
  "mcp.prompts.list",
  "mcp.prompts.get",
  "imessage.catalog",
  "imessage.recipe",
  "imessage.run",
  "apple.tools.catalog",
  "apple.tools.run",
  "computer.input",
  "computer.apps",
  "identity",
  "chats.list",
  "messages.list",
  "messages.search",
  "messages.send",
  "messages.react",
  "messages.unreact",
  "messages.edit",
  "messages.unsend",
  "chats.create",
  "chats.read",
  "chats.unread",
  "chats.typing",
  "messages.effect",
  "messages.format",
  "messages.draft.discard",
  "messages.inspect",
  "messages.features",
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
  "apps.interact",
  "apps.snapshot",
  "computer.exec",
  "computer.screenshot",
  "files.read",
  "files.write",
  "apps.build",
  "apps.create",
  "apps.ios.run",
  "device.capture",
  "location.get",
] as const;
export type Operation = (typeof operations)[number];
export const readOperations = new Set<Operation>([
  "messages.inspect",
  "messages.features",
  "messages.get",
  "messages.reactions",
  "messages.scheduled.list",
  "apps.messages.installed",
  "device.activity.list",
  "mcp.registry.search",
  "mcp.registry.get",
  "mcp.connections",
  "mcp.tools.list",
  "mcp.resources.list",
  "mcp.resources.read",
  "mcp.prompts.list",
  "mcp.prompts.get",
  "imessage.catalog",
  "imessage.recipe",
  "apple.tools.catalog",
  "computer.apps",
  "computer.screenshot",
  "files.read",
  "identity",
  "chats.list",
  "messages.list",
  "messages.search",
  "apps.snapshot",
  "location.get",
]);
export const commandSchema = z
  .object({
    operation: z.enum(operations),
    args: z.record(z.unknown()).default({}),
    idempotencyKey: z.string().min(1).max(200),
  })
  .strict();
export type CommandInput = z.infer<typeof commandSchema>;
export type Capability = {
  operation: Operation;
  available: boolean;
  path: string;
  verification: "fixture" | "compiled" | "device-tested" | "unavailable";
  detail?: string;
};
export type CommandState =
  | "queued"
  | "executing"
  | "completed"
  | "failed"
  | "outcome_unknown"
  | "cancelled";
export type Command = CommandInput & {
  id: string;
  accountId: string;
  state: CommandState;
  createdAt: number;
  updatedAt: number;
  result?: unknown;
  error?: string;
  generation?: string;
};
export type Event = {
  sequence: number;
  accountId: string;
  sourceId: string;
  kind: string;
  data: unknown;
  createdAt: number;
};
export const workerFrame = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("hello"),
    accountId: z.string(),
    workerId: z.string(),
    allowedChatIds: z.array(z.string()).optional(),
    identity: z.string(),
    role: z.enum(["computer", "device"]).default("computer"),
    capabilities: z.array(
      z.object({
        operation: z.enum(operations),
        available: z.boolean(),
        path: z.string(),
        verification: z.enum([
          "fixture",
          "compiled",
          "device-tested",
          "unavailable",
        ]),
        detail: z.string().optional(),
      }),
    ),
  }),
  z.object({
    type: z.literal("result"),
    commandId: z.string(),
    generation: z.string(),
    ok: z.boolean(),
    result: z.unknown().optional(),
    error: z.string().optional(),
    uncertain: z.boolean().optional(),
  }),
  z.object({
    type: z.literal("event"),
    sourceId: z.string(),
    kind: z.string(),
    data: z.unknown(),
  }),
  z.object({ type: z.literal("heartbeat") }),
]);
export { PilotError } from "./errors.js";

export const configSchema = z.object({
  analytics: z.array(analyticsPolicy).optional(),
  googleWorkspace: z.array(workspaceConfig).optional(),
  library: z
    .object({
      provider: z.literal("http"),
      url: z.string().url(),
      tokenEnv: z.string().min(1),
    })
    .optional(),
  files: z
    .object({
      directory: z.string().min(1),
      maxFileBytes: z
        .number()
        .int()
        .positive()
        .default(512 * 1024 * 1024),
      maxAccountBytes: z
        .number()
        .int()
        .positive()
        .default(5 * 1024 * 1024 * 1024),
      conversion: z
        .object({
          python: z.string().startsWith("/"),
          tools: z.record(z.string().startsWith("/")),
        })
        .optional(),
    })
    .optional(),
  extensionHooks: z.array(extensionHookSchema).optional(),
  passkeys: z
    .object({
      rpId: z.string().min(1),
      origin: z.string().url(),
      appIds: z.array(z.string().regex(/^[A-Z0-9]+\.[A-Za-z0-9.-]+$/)).min(1),
    })
    .optional(),
  host: z.string().default("127.0.0.1"),
  port: z.number().int().min(0).max(65535).default(4380),
  database: z.string(),
  accounts: z
    .array(
      z.object({
        id: z.string().regex(/^[a-zA-Z0-9_-]+$/),
        identity: z.string().min(1),
        workerTokenEnv: z.string(),
        allowedChatIds: z.array(z.string().min(1)).optional(),
        deviceTokenEnv: z.string().optional(),
      }),
    )
    .min(1),
  agents: z
    .array(
      z.object({
        id: z.string(),
        tokenEnv: z.string(),
        accounts: z.array(z.string()),
        operations: z.array(z.enum(operations)).optional(),
        chats: z.record(z.array(z.string().min(1))).optional(),
      }),
    )
    .min(1),
});
export type Config = z.infer<typeof configSchema>;

export function validateArgs(
  operation: Operation,
  args: Record<string, unknown>,
) {
  const str = (key: string) => {
    if (typeof args[key] !== "string" || !(args[key] as string).length)
      throw new PilotError("invalid_arguments", `${key} is required`);
  };
  if (
    [
      "messages.list",
      "messages.send",
      "messages.react",
      "messages.unreact",
      "messages.edit",
      "messages.unsend",
      "chats.read",
      "chats.unread",
      "chats.typing",
      "messages.effect",
      "messages.get",
      "messages.reactions",
      "messages.sticker",
      "messages.sticker.attach",
      "messages.forward",
      "messages.schedule",
      "messages.scheduled.cancel",
      "attachments.download",
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
    ].includes(operation)
  )
    str("chatId");
  if (
    [
      "messages.react",
      "messages.unreact",
      "messages.edit",
      "messages.unsend",
      "messages.get",
      "messages.reactions",
      "messages.sticker.attach",
      "messages.forward",
      "messages.scheduled.cancel",
      "attachments.download",
    ].includes(operation)
  )
    str("messageId");
  if (operation === "messages.schedule") {
    str("text");
    str("sendAt");
    const when = Date.parse(String(args.sendAt));
    if (!/(Z|[+-]\d\d:?\d\d)$/.test(String(args.sendAt)) || Number.isNaN(when))
      throw new PilotError(
        "invalid_arguments",
        "sendAt must be an ISO 8601 date-time with a time zone",
      );
    const lead = when - Date.now();
    if (lead < 60_000 || lead > 14 * 24 * 3600_000)
      throw new PilotError(
        "invalid_arguments",
        "Send Later accepts times from one minute to 14 days ahead",
      );
  }
  if (operation === "messages.forward") str("to");
  if (["apps.messages.open", "apps.messages.prompt"].includes(operation))
    str("app");
  if (operation === "apps.messages.prompt") str("text");
  if (operation === "chats.rename") str("name");
  if (operation === "chats.participants.remove") str("address");
  if (
    ["chats.delete", "chats.leave"].includes(operation) &&
    args.confirm !== true
  )
    throw new PilotError(
      "invalid_arguments",
      "This is irreversible for the account; pass confirm: true",
    );
  if (
    operation === "messages.send" &&
    !args.text &&
    !args.filePath &&
    !args.filePaths
  )
    throw new PilotError(
      "invalid_arguments",
      "text, filePath or filePaths required",
    );
  if (
    operation === "messages.send" &&
    args.filePaths &&
    (args.text !== undefined ||
      args.filePath !== undefined ||
      args.replyTo !== undefined)
  )
    throw new PilotError(
      "invalid_arguments",
      "Photo collections cannot be combined with text, filePath or replyTo",
    );
  if (["messages.react", "messages.unreact"].includes(operation))
    str("reaction");
  if (operation === "messages.edit") str("text");
  if (operation === "messages.search") str("query");
  if (operation === "messages.effect") {
    str("text");
    str("effect");
  }
  if (operation === "computer.exec") {
    str("executable");
    if (
      args.arguments !== undefined &&
      !z.array(z.string()).safeParse(args.arguments).success
    )
      throw new PilotError("invalid_arguments", "arguments must be strings");
  }
  if (
    operation === "chats.create" &&
    !z.array(z.string().min(1)).min(1).safeParse(args.recipients).success
  )
    throw new PilotError("invalid_arguments", "recipients required");
}
