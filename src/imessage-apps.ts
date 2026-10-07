import { z } from "zod";
export const iosActionSchema = z
  .object({
    action: z.enum([
      "snapshot",
      "screenshot",
      "tap",
      "doubleTap",
      "twoFingerTap",
      "longPress",
      "type",
      "swipeLeft",
      "swipeRight",
      "swipeUp",
      "swipeDown",
      "waitFor",
      "wait",
      "adjustPicker",
      "setSlider",
      "pinch",
      "rotate",
      "drag",
      "tapCoordinate",
    ]),
    identifier: z.string().optional(),
    type: z
      .enum([
        "button",
        "textField",
        "textView",
        "cell",
        "staticText",
        "pickerWheel",
        "slider",
        "any",
      ])
      .optional(),
    text: z.string().optional(),
    value: z.number().optional(),
    seconds: z.number().min(0).max(10).optional(),
    timeoutSeconds: z.number().min(0).max(30).optional(),
    scale: z.number().positive().optional(),
    velocity: z.number().optional(),
    radians: z.number().optional(),
    x: z.number().min(0).max(1).optional(),
    y: z.number().min(0).max(1).optional(),
    toX: z.number().min(0).max(1).optional(),
    toY: z.number().min(0).max(1).optional(),
  })
  .strict();
export const selectorSchema = z.object({
  identifier: z.string().min(1),
  type: z
    .enum([
      "button",
      "textField",
      "textView",
      "cell",
      "staticText",
      "pickerWheel",
      "slider",
      "any",
    ])
    .optional(),
});
const entries = [
  [
    "backgrounds",
    "Conversation Backgrounds",
    "Select native dynamic/photo/generated backgrounds or remove them; changes can affect conversation participants",
  ],
  ["photos", "Photos", "Select and send images/video"],
  ["camera", "Camera", "Capture media"],
  [
    "stickers",
    "Stickers / Memoji / Genmoji",
    "Send and place installed stickers; creation depends on device support",
  ],
  ["audio", "Audio", "Record, review and send voice messages"],
  ["images", "#images", "Search and send GIFs where available"],
  [
    "location",
    "Location",
    "Share/request location through the observed Messages UI",
  ],
  ["checkin", "Check In", "Configure and send a supported Check In"],
  [
    "sendlater",
    "Send Later",
    "Create, change, send now or delete a native scheduled message",
  ],
  ["polls", "Polls", "Create a native poll, add choices and vote"],
  [
    "digitaltouch",
    "Digital Touch",
    "Gestures and drawings using calibrated UI and coordinate actions",
  ],
  [
    "imageplayground",
    "Image Playground",
    "Create and send images where device/language permits",
  ],
  [
    "applecash",
    "Apple Cash",
    "Visible app controls; Apple authentication/payment confirmation remains required",
  ],
  [
    "appstore",
    "iMessage App Store",
    "Browse and manage extensions with Apple's installation flow",
  ],
  [
    "giphy",
    "GIPHY",
    "Search/select/send GIFs and stickers through installed extension",
  ],
  [
    "gamepigeon",
    "GamePigeon",
    "Open games and operate observed controls/gestures",
  ],
  [
    "tenor",
    "GIF Keyboard by Tenor",
    "Search and share through installed keyboard/extension",
  ],
  [
    "custom",
    "Any installed iMessage extension",
    "Observe and operate arbitrary compatible extension UI",
  ],
] as const;
export function appCatalog() {
  return {
    apps: entries.map(([id, title, purpose]) => ({
      id,
      title,
      purpose,
      path: "enrolled-ios-ui",
      verification: "requires-device-calibration",
    })),
    workflows: [
      "app.open",
      "custom",
      "sendlater.create",
      "sendlater.update",
      "sendlater.sendNow",
      "sendlater.delete",
      "polls.create",
      "polls.vote",
      "polls.addOption",
      "polls.details",
      "backgrounds.set",
      "backgrounds.fromMessage",
      "backgrounds.remove",
      "giphy.search",
      "giphy.send",
    ],
    note: "Catalog entries describe control paths, not universal tested compatibility. App availability, locale, authentication and Apple UI restrictions still apply. Game gestures can use observed screenshot coordinates. Never substitute a MessagePilot card for an Apple-native poll.",
  };
}
export const workflowSchema = z.object({
  workflow: z.enum([
    "app.open",
    "custom",
    "sendlater.create",
    "sendlater.update",
    "sendlater.sendNow",
    "sendlater.delete",
    "polls.create",
    "polls.vote",
    "polls.addOption",
    "polls.details",
    "backgrounds.set",
    "backgrounds.fromMessage",
    "backgrounds.remove",
    "giphy.search",
    "giphy.send",
  ]),
  selectors: z.record(selectorSchema).default({}),
  values: z
    .object({
      text: z.string().optional(),
      query: z.string().optional(),
      options: z.array(z.string().min(1)).min(2).max(12).optional(),
      option: z.string().optional(),
    })
    .default({}),
  dateActions: z.array(iosActionSchema).max(20).optional(),
  actions: z.array(iosActionSchema).max(80).optional(),
});
export function compileWorkflow(input: unknown) {
  const a = workflowSchema.parse(input);
  const steps: Record<string, unknown>[] = [];
  const action = (key: string, kind = "tap", text?: string) => {
    const selector = a.selectors[key];
    if (!selector) throw new Error(`Missing observed selector: ${key}`);
    steps.push({
      action: kind,
      ...selector,
      ...(text === undefined ? {} : { text }),
    });
  };
  const text = (value: string | undefined, field: string) => {
    if (!value) throw new Error(`${field} required`);
    return value;
  };
  const open = (app: string) => {
    action("conversation");
    action("add");
    action(app);
  };
  const date = () => {
    if (!a.dateActions?.length)
      throw new Error(
        "Calibrated dateActions are required; date-picker layout is OS/locale dependent",
      );
    steps.push(...a.dateActions);
  };
  switch (a.workflow) {
    case "app.open":
      open("app");
      break;
    case "backgrounds.set":
      action("conversation");
      action("conversationInfo");
      action("backgrounds");
      action("backgroundType");
      if (a.actions) steps.push(...a.actions);
      action("done");
      break;
    case "backgrounds.fromMessage":
      action("conversation");
      action("photoMessage", "longPress");
      action("setAsBackground");
      if (a.actions) steps.push(...a.actions);
      action("done");
      break;
    case "backgrounds.remove":
      action("conversation");
      action("conversationInfo");
      action("backgrounds");
      action("none");
      break;
    case "custom":
      if (!a.actions?.length) throw new Error("actions required");
      steps.push(...a.actions);
      break;
    case "sendlater.create":
      open("sendLater");
      date();
      action("composer", "type", text(a.values.text, "text"));
      action("send");
      break;
    case "sendlater.update":
      action("conversation");
      action("scheduledEdit");
      action("editTime");
      date();
      break;
    case "sendlater.sendNow":
      action("conversation");
      action("scheduledEdit");
      action("sendNow");
      break;
    case "sendlater.delete":
      action("conversation");
      action("scheduledMessage", "longPress");
      action("delete");
      if (a.selectors.confirmDelete) action("confirmDelete");
      break;
    case "polls.create":
      open("polls");
      if (!a.values.options) throw new Error("options required");
      a.values.options.forEach((choice, i) =>
        action(`option${i + 1}`, "type", choice),
      );
      action("send");
      break;
    case "polls.vote":
      action("conversation");
      action("poll", "waitFor");
      action("choice");
      break;
    case "polls.addOption":
      action("conversation");
      action("poll", "waitFor");
      action("addOption");
      action("newOption", "type", text(a.values.option, "option"));
      action("send");
      break;
    case "polls.details":
      action("conversation");
      action("poll", "longPress");
      action("pollDetails");
      break;
    case "giphy.search":
      open("giphy");
      action("search", "type", text(a.values.query, "query"));
      break;
    case "giphy.send":
      open("giphy");
      action("search", "type", text(a.values.query, "query"));
      action("result", "waitFor");
      action("result");
      action("send");
      break;
  }
  steps.push({ action: "snapshot" }, { action: "screenshot" });
  return {
    recipe: { bundleId: "com.apple.MobileSMS", launch: false, actions: steps },
    workflow: a.workflow,
    verification: "requires-device-calibration",
    delivery: "not-asserted",
  };
}
