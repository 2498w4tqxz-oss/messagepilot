import { z } from "zod";

export const extensionHookSchema = z
  .object({
    id: z.string().regex(/^[a-zA-Z0-9_-]{1,80}$/),
    accountId: z.string().min(1),
    chatId: z.string().min(1),
    feature: z.enum(["invites", "location", "checkin"]),
    url: z.string().url(),
    signingSecretEnv: z.string().min(1),
    requestAgentIds: z.array(z.string()).default([]),
    observerAgentIds: z.array(z.string()).min(1),
    includeCoordinates: z.boolean().default(false),
    allowLoopbackHttp: z.boolean().default(false),
  })
  .strict();
export type ExtensionHookConfig = z.infer<typeof extensionHookSchema>;

const empty = z.object({}).strict();
export const extensionActions = {
  invites: {
    create: z
      .object({
        title: z.string().min(1).max(200),
        description: z.string().max(2000).optional(),
        startsAt: z.string().datetime({ offset: true }).optional(),
      })
      .strict(),
    share: z
      .object({
        url: z
          .string()
          .url()
          .refine((v) => {
            const u = new URL(v);
            return (
              u.protocol === "https:" &&
              ["icloud.com", "www.icloud.com"].includes(u.hostname) &&
              u.pathname.startsWith("/invites/") &&
              !u.username &&
              !u.password
            );
          }, "Expected an Apple Invites share URL"),
      })
      .strict(),
    inspect: empty,
  },
  location: {
    send_pin: empty,
    start_sharing: z
      .object({ duration: z.enum(["one_hour", "end_of_day", "indefinitely"]) })
      .strict(),
    stop_sharing: empty,
    inspect: empty,
  },
  checkin: {
    start_timer: z
      .object({
        minutes: z.number().int().min(1).max(1440),
        dataLevel: z.enum(["limited", "full"]),
      })
      .strict(),
    start_destination: z
      .object({
        destination: z.string().min(1).max(500),
        travelMode: z.enum(["driving", "walking", "transit"]),
        dataLevel: z.enum(["limited", "full"]),
      })
      .strict(),
    cancel: empty,
    inspect: empty,
  },
};
export const extensionStates = {
  invites: [
    "created",
    "shared",
    "updated",
    "rsvp_changed",
    "cancelled",
    "unavailable",
  ] as const,
  location: [
    "pin_sent",
    "sharing_started",
    "location_updated",
    "sharing_stopped",
    "unavailable",
  ] as const,
  checkin: [
    "started",
    "updated",
    "arrived",
    "timer_completed",
    "delayed",
    "cancelled",
    "unavailable",
  ] as const,
};
export const hookRequestSchema = z
  .object({
    idempotencyKey: z.string().min(1).max(200),
    action: z.string(),
    parameters: z.record(z.unknown()).default({}),
  })
  .strict();
export const hookObservationSchema = z
  .object({
    sourceId: z.string().min(1).max(200),
    observedAt: z.number().int().positive(),
    state: z.string(),
    evidence: z
      .object({
        kind: z.enum(["ui", "native", "fixture"]),
        reference: z.string().min(1).max(200),
      })
      .strict(),
    requestId: z.string().uuid().optional(),
    outcome: z.enum(["completed", "blocked", "failed"]).optional(),
    location: z
      .object({
        latitude: z.number().min(-90).max(90),
        longitude: z.number().min(-180).max(180),
        accuracyMeters: z.number().nonnegative().optional(),
      })
      .strict()
      .optional(),
    summary: z.string().max(500).optional(),
  })
  .strict();
