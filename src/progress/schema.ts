import { z } from "zod";
export const startProgress = z
  .object({
    chatId: z.string().min(1).max(500),
    idempotencyKey: z.string().min(1).max(200),
    title: z.string().min(1).max(200),
    detail: z.string().min(1).max(2000),
    mode: z.enum(["native_text", "live_card"]).default("native_text"),
    intervalMs: z.number().int().min(2000).max(300000).default(5000),
    intermediateEdits: z.number().int().min(0).max(4).default(4),
    finalFallback: z.enum(["new_message", "none"]).default("new_message"),
  })
  .strict();
export const updateProgress = z
  .object({
    idempotencyKey: z.string().min(1).max(200),
    expectedRevision: z.number().int().positive(),
    state: z.enum(["running", "waiting", "completed", "failed", "cancelled"]),
    detail: z.string().min(1).max(8000),
    fraction: z.number().min(0).max(1).optional(),
    fileIds: z.array(z.string().uuid()).max(10).default([]),
    attachments: z
      .array(
        z
          .object({
            filePath: z.string().min(1).max(2000),
            label: z.string().min(1).max(200),
          })
          .strict(),
      )
      .max(10)
      .default([]),
  })
  .strict();
export type StartProgress = z.infer<typeof startProgress>;
export type UpdateProgress = z.infer<typeof updateProgress>;
export type ProgressJob = {
  id: string;
  accountId: string;
  owner: string;
  chatId: string;
  title: string;
  mode: StartProgress["mode"];
  state: UpdateProgress["state"];
  detail: string;
  fraction?: number;
  revision: number;
  createdAt: number;
  updatedAt: number;
  fileIds: string[];
  attachments: UpdateProgress["attachments"];
  policy: {
    intervalMs: number;
    intermediateEdits: number;
    finalFallback: StartProgress["finalFallback"];
  };
  history: { revision: number; state: string; detail: string; at: number }[];
  transport: {
    state:
      | "pending"
      | "watching"
      | "paused"
      | "complete"
      | "failed"
      | "outcome_unknown"
      | "awaiting_user";
    reason?: string;
    messageId?: string;
    sentAt?: number;
    lastAt: number;
    lastText?: string;
    editAttempts: number;
    commandId?: string;
    action?: "initial" | "edit" | "final_edit" | "final_send" | "attachment";
    submittedText?: string;
    submittedRevision?: number;
    completedRevision?: number;
    attachmentIndex: number;
    fallbackUsed: boolean;
    receipts: { commandId: string; action: string; state: string }[];
  };
};
export const terminal = (state: string) =>
  ["completed", "failed", "cancelled"].includes(state);
export function progressText(j: ProgressJob) {
  const label = {
    running: "Working",
    waiting: "Waiting",
    completed: "Completed",
    failed: "Failed",
    cancelled: "Cancelled",
  }[j.state];
  return `${j.title}\n${label}${j.fraction === undefined ? "" : ` · ${Math.round(j.fraction * 100)}%`}\n${j.detail}`;
}
