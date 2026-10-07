import { z } from "zod";
export const textEffects = [
  "Big",
  "Small",
  "Shake",
  "Nod",
  "Explode",
  "Ripple",
  "Bloom",
  "Jitter",
] as const;
export const bubbleEffects = [
  "Slam",
  "Loud",
  "Gentle",
  "Invisible Ink",
] as const;
export const screenEffects = [
  "Echo",
  "Spotlight",
  "Balloons",
  "Confetti",
  "Love",
  "Lasers",
  "Fireworks",
  "Celebration",
] as const;
export const textStyles = [
  "bold",
  "italic",
  "underline",
  "strikethrough",
] as const;
export const formattingSchema = z
  .object({
    chatId: z.string().min(1),
    text: z.string().min(1).max(10000),
    styles: z.array(z.enum(textStyles)).min(1).max(4),
    range: z
      .object({
        start: z.number().int().min(0),
        length: z.number().int().min(1),
      })
      .optional()
      .describe(
        "Optional UTF-16 range; omitted means the entire message. Native text styles, not arbitrary typefaces.",
      ),
  })
  .superRefine((v, c) => {
    if (new Set(v.styles).size !== v.styles.length)
      c.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Styles must be unique",
      });
    if (v.range && v.range.start + v.range.length > v.text.length)
      c.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Formatting range exceeds text",
      });
  });
export const richFeatures = {
  formatting: textStyles,
  textEffects,
  bubbleEffects,
  screenEffects,
  tapbacks: [
    "love",
    "like",
    "dislike",
    "laugh",
    "emphasize",
    "question",
    "custom-emoji",
  ],
  operations: [
    "reply",
    "edit",
    "unsend",
    "read",
    "unread",
    "typing",
    "media",
    "link-preview",
  ],
  extensionOrDevice: [
    "stickers",
    "carousels",
    "polls",
    "send-later",
    "backgrounds",
    "audio",
    "GIPHY",
  ],
  constraints: {
    edit: "Own iMessage; up to five edits within 15 minutes; recipient version matters",
    unsend: "Own iMessage within two minutes; recipient version matters",
    font: "Native bold, italic, underline, strikethrough. Arbitrary fonts require a rendered card/image and are not native text styling.",
    effects:
      "Availability and labels depend on OS; selector calibration and recipient rendering must be verified",
  },
  verification: "catalog-only; query worker capabilities and live receipts",
};
