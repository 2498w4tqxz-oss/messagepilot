import { z } from "zod";

export const operations = [
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
export class PilotError extends Error {
  constructor(
    public code: string,
    message: string,
    public status = 400,
  ) {
    super(message);
  }
}

export const configSchema = z.object({
  host: z.string().default("127.0.0.1"),
  port: z.number().int().min(0).max(65535).default(4380),
  database: z.string(),
  accounts: z
    .array(
      z.object({
        id: z.string().regex(/^[a-zA-Z0-9_-]+$/),
        identity: z.string().min(1),
        workerTokenEnv: z.string(),
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
    ].includes(operation)
  )
    str("chatId");
  if (
    [
      "messages.react",
      "messages.unreact",
      "messages.edit",
      "messages.unsend",
    ].includes(operation)
  )
    str("messageId");
  if (operation === "messages.send" && !args.text && !args.filePath)
    throw new PilotError("invalid_arguments", "text or filePath required");
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
