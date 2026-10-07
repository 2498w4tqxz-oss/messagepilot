import { z } from "zod";
import {
  formattingSchema,
  textEffects,
  bubbleEffects,
  screenEffects,
} from "./rich-messages.js";
import type { Operation } from "./protocol.js";
import { connectionSchema } from "./mcp-host.js";
import { workflowSchema, iosActionSchema } from "./imessage-apps.js";
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
  "device.auth.biometric": z.object({
    reason: z.string().min(1).max(300),
    allowPasscode: z.boolean().default(false),
  }),
  "device.auth.passkey": z
    .object({
      registration: z.boolean().default(false),
      options: z.record(z.unknown()),
    })
    .describe(
      "Present Apple passkey UI in the active primary app. Return the signed WebAuthn response for relying-party verification; client output alone is not a login.",
    ),
  "device.surface.publish": z.object({
    id: z.string().default("default"),
    title: z.string().max(200),
    detail: z.string().max(1000).default(""),
    progress: z.number().min(0).max(1).default(0),
    cardId: z.string().optional(),
  }),
  "device.activity.list": z.object({}),
  "device.activity.start": z.object({ id: z.string().default("default") }),
  "device.activity.update": z.object({ id: z.string().default("default") }),
  "device.activity.end": z.object({ id: z.string().default("default") }),
  "apple.activity.push": z.object({
    requestUpdateToken: z
      .boolean()
      .default(false)
      .describe(
        "For push-to-start on iOS 18+, request a fresh update token with input-push-token: 1.",
      ),
    pushToken: z.string().regex(/^[a-fA-F0-9]{32,512}$/),
    event: z.enum(["start", "update", "end"]),
    contentState: z.record(z.unknown()),
    attributesType: z.string().optional(),
    attributes: z.record(z.unknown()).optional(),
    alert: z.object({ title: z.string(), body: z.string() }).optional(),
    staleDate: z.number().int().optional(),
    dismissalDate: z.number().int().optional(),
  }),
  "mcp.registry.search": z.object({
    search: z.string().default(""),
    cursor: z.string().optional(),
    limit: z.number().int().min(1).max(100).default(20),
  }),
  "mcp.registry.get": z.object({
    name: z.string().min(1),
    version: z.string().default("latest"),
  }),
  "mcp.connections": z.object({}),
  "mcp.connect": connectionSchema,
  "mcp.disconnect": z.object({ id: z.string() }),
  "mcp.tools.list": z.object({ id: z.string(), cursor: z.string().optional() }),
  "mcp.tools.call": z.object({
    id: z.string(),
    name: z.string(),
    arguments: z.record(z.unknown()).default({}),
  }),
  "mcp.resources.list": z.object({
    id: z.string(),
    cursor: z.string().optional(),
  }),
  "mcp.resources.read": z.object({ id: z.string(), uri: z.string() }),
  "mcp.prompts.list": z.object({
    id: z.string(),
    cursor: z.string().optional(),
  }),
  "mcp.prompts.get": z.object({
    id: z.string(),
    name: z.string(),
    arguments: z.record(z.string()).default({}),
  }),
  "imessage.catalog": z.object({}),
  "imessage.recipe": workflowSchema,
  "imessage.run": z.object({
    workflow: workflowSchema,
    xctestrun: z.string(),
    enrollment: z.string(),
    deviceId: z.string(),
    resultPath: z.string(),
    prepareOnly: z.boolean().optional(),
  }),
  "apple.tools.catalog": z.object({}),
  "apple.tools.run": z.object({
    tool: z.string(),
    arguments: z.array(z.string()).default([]),
    cwd: z.string().optional(),
    timeoutSeconds: z.number().min(1).max(540).default(120),
  }),
  "computer.apps": z.object({}),
  "computer.input": z.object({
    bundleId: z.string().min(1),
    actions: z
      .array(
        z
          .object({
            action: z.enum([
              "activate",
              "click",
              "move",
              "drag",
              "scroll",
              "key",
              "text",
            ]),
            x: z.number().optional(),
            y: z.number().optional(),
            toX: z.number().optional(),
            toY: z.number().optional(),
            button: z.enum(["left", "right"]).optional(),
            clicks: z.number().int().min(1).max(2).optional(),
            deltaX: z.number().int().min(-10000).max(10000).optional(),
            deltaY: z.number().int().min(-10000).max(10000).optional(),
            keyCode: z.number().int().min(0).max(127).optional(),
            modifiers: z
              .array(z.enum(["command", "shift", "option", "control"]))
              .optional(),
            text: z.string().max(10000).optional(),
          })
          .strict(),
      )
      .min(1)
      .max(100),
  }),
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
  "messages.features": z.object({}),
  "messages.inspect": z.object({
    ...chat,
    messageId: z.string().optional(),
    view: z
      .enum(["transcript", "apps", "format", "effects", "message-menu"])
      .optional(),
  }),
  "messages.draft.discard": z.object({
    ...chat,
    expectedText: z.string().min(1),
  }),
  "messages.format": formattingSchema,
  "messages.effect": z
    .object({
      ...chat,
      text: z.string().min(1).max(10000),
      effect: z
        .string()
        .describe(
          "Exact visible effect label, such as Jitter or Invisible Ink.",
        ),
      kind: z.enum(["text", "bubble", "screen"]),
      range: z
        .object({
          start: z.number().int().min(0),
          length: z.number().int().min(1),
        })
        .optional(),
      selectors: z
        .record(z.string())
        .optional()
        .describe(
          "Calibrated composer/apps/effects/format/send labels for this OS and locale.",
        ),
    })
    .superRefine((v, ctx) => {
      if (
        v.range &&
        (v.kind !== "text" || v.range.start + v.range.length > v.text.length)
      )
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: "Range requires a valid text-effect substring",
        });
      const names: readonly string[] =
        v.kind === "text"
          ? textEffects
          : v.kind === "bubble"
            ? bubbleEffects
            : screenEffects;
      if (!names.includes(v.effect))
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: "Effect does not belong to the requested effect kind",
        });
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
    passkeyDomain: z
      .string()
      .optional()
      .describe(
        "Optional webcredentials domain; requires primaryPort and matching RP configuration/AASA.",
      ),
    primaryPort: z
      .boolean()
      .default(false)
      .describe(
        "Opt in to the primary app port, widgets, Live Activities, App Intents and device capabilities. Default creates a minimal containing app and Messages extension.",
      ),
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
      actions: z.array(iosActionSchema).min(1).max(100),
    }),
    prepareOnly: z.boolean().optional(),
  }),
  "device.capture": z.object({ kind: z.enum(["room", "ar"]) }),
  "location.get": z.object({}),
};
