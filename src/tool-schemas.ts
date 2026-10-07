import { z } from "zod";
import type { Operation } from "./protocol.js";
const chat = {
  chatId: z
    .string()
    .min(1)
    .describe(
      "Exact chat ID returned by chats_list; never infer from a display name.",
    ),
};
const message = {
  ...chat,
  messageId: z
    .string()
    .min(1)
    .describe("Exact message identifier returned by messages_list."),
};
const cursor = {
  cursor: z.string().optional(),
  direction: z.enum(["before", "after"]).optional(),
};
const axSelector = z
  .record(z.string())
  .describe(
    "Exact Accessibility attributes observed in apps_snapshot, e.g. AXIdentifier, AXRole, AXTitle, AXDescription.",
  );
export const toolSchemas: Record<
  Operation,
  z.ZodType<Record<string, unknown>>
> = {
  "files.read": z.object({
    path: z.string(),
    offset: z.number().int().min(0).optional(),
    length: z.number().int().min(1).max(262144).optional(),
  }),
  "files.write": z.object({
    path: z.string(),
    dataBase64: z.string().max(349528),
    offset: z.number().int().min(0).default(0),
    replace: z.boolean().default(false),
  }),
  identity: z.object({}),
  "chats.list": z.object({ folder: z.string().optional(), ...cursor }),
  "messages.list": z.object({ ...chat, ...cursor }),
  "messages.search": z.object({
    query: z.string(),
    chatId: z.string().optional(),
    mediaOnly: z.boolean().optional(),
    sender: z.string().optional(),
    limit: z.number().int().min(1).max(200).optional(),
    ...cursor,
  }),
  "messages.send": z.object({
    ...chat,
    text: z.string().optional(),
    filePath: z
      .string()
      .optional()
      .describe(
        "Image, GIF, video, audio, or file inside the account worker workspace.",
      ),
    replyTo: z.string().optional(),
  }),
  "messages.react": z.object({
    ...message,
    reaction: z
      .string()
      .describe(
        "Supported reaction name or emoji. Transport availability varies by OS.",
      ),
  }),
  "messages.unreact": z.object({ ...message, reaction: z.string() }),
  "messages.edit": z.object({ ...message, text: z.string().min(1) }),
  "messages.unsend": z.object(message),
  "chats.create": z.object({
    recipients: z.array(z.string().min(1)).min(1),
    title: z.string().optional(),
    text: z.string().optional(),
  }),
  "chats.read": z.object(chat),
  "chats.unread": z.object(chat),
  "chats.typing": z.object({ ...chat, active: z.boolean() }),
  "messages.effect": z.object({
    ...chat,
    text: z.string(),
    effect: z
      .string()
      .describe("Exact visible effect label, such as Jitter or Invisible Ink."),
    kind: z.enum(["text", "bubble", "screen"]),
    selectors: z
      .record(z.string())
      .optional()
      .describe(
        "Calibrated composer/apps/effects/format/send labels for this OS and locale.",
      ),
  }),
  "apps.snapshot": z.object({
    bundleId: z.string().optional(),
    depth: z.number().int().min(1).max(15).optional(),
  }),
  "apps.interact": z.object({
    bundleId: z.string().optional(),
    actions: z
      .array(
        z.object({
          action: z.enum(["press", "showMenu", "setValue", "focus", "waitFor"]),
          id: z.string().optional(),
          selector: axSelector.optional(),
          value: z.string().optional(),
          timeoutSeconds: z.number().min(0).max(10).optional(),
        }),
      )
      .min(1)
      .max(40),
  }),
  "computer.exec": z.object({
    executable: z.string().startsWith("/"),
    arguments: z.array(z.string()).optional(),
    cwd: z.string().optional(),
    timeoutSeconds: z.number().min(1).max(540).optional(),
  }),
  "computer.screenshot": z.object({ path: z.string().optional() }),
  "apps.build": z.object({
    project: z.string(),
    scheme: z.string(),
    destination: z.string().optional(),
    derivedData: z.string().optional(),
    sign: z.boolean().optional(),
    action: z.enum(["build", "build-for-testing"]).optional(),
    team: z.string().optional(),
  }),
  "apps.create": z.object({
    directory: z.string(),
    bundleId: z
      .string()
      .regex(/^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*){2,}$/),
  }),
  "apps.ios.run": z.object({
    xctestrun: z.string(),
    enrollment: z.string(),
    deviceId: z.string(),
    resultPath: z.string(),
    recipe: z.object({
      bundleId: z.string(),
      launch: z.boolean().optional(),
      actions: z.array(z.record(z.unknown())).min(1).max(100),
    }),
    prepareOnly: z.boolean().optional(),
  }),
  "device.capture": z.object({ kind: z.enum(["room", "ar"]) }),
  "location.get": z.object({}),
};
