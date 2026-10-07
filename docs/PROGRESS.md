# Background task progress

MessagePilot reports work performed by a developer's agent or job runner. It does not run that work itself. A job has separate **task state** and **transport state**: `completed` means the producer reported completion; `transport.state=complete` means the native commands completed. Neither means a recipient read the result.

## Choose the presentation

| Mode          | Behavior                                                                                                                                                                 | Limit                                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `native_text` | Send one initial status, edit the same message with coalesced steps, then finalize it. Send optional files afterward.                                                    | Apple permits five edits within 15 minutes. Four intermediate edits are allowed at most; one is reserved for the final result.                  |
| `live_card`   | Persist steps and results. Open the extension's Progress tab, load the job ID, and tap Send progress card. The active view fetches the latest state every three seconds. | Sending is a user action. iOS controls extension lifetime and transcript snapshots; backend updates do not guarantee background bubble refresh. |

Native edit scheduling defaults to five seconds between intermediate edits, configurable from two seconds to five minutes. Updates arriving faster are coalesced. A queued intermediate edit can be cancelled and replaced before dispatch; an executing edit is never interrupted or blindly retried. Finalization bypasses the interval. After four intermediate edits, progress stays available in the API/card and the text bubble pauses until finalization.

A conservative 14-minute scheduling deadline leaves a minute for worker queueing. The native adapter still enforces actual eligibility at execution. By default, finalization outside the budget/window sends one new final message. Set `finalFallback: "none"` to prohibit that; the final task result remains stored and transport reports `paused`. Other failures, including a native edit rejected after queueing, stop with an explicit failure rather than automatically resending.

Do not use unlimited every-few-second native edits for long work: Apple does not offer that behavior. See Apple's [edit limits](https://support.apple.com/en-ie/105083), [message sessions](https://developer.apple.com/documentation/messages/mssession), and [direct-send requirements](<https://developer.apple.com/documentation/messages/msconversation/send(_:completionhandler:)-9krz>).

## HTTP and MCP

All paths are relative to `/v1/accounts/:accountId/` and require the usual Bearer credential.

| Request                          | Purpose                                                                      |
| -------------------------------- | ---------------------------------------------------------------------------- |
| `POST progress`                  | Create a job; returns 202 and a persistent job record.                       |
| `GET progress?chatId=EXACT_CHAT` | Read up to 100 latest jobs in one authorized chat.                           |
| `GET progress/:jobId`            | Read state, revision, history and transport receipts.                        |
| `POST progress/:jobId/updates`   | Update an owned job with revision control and content-sensitive idempotency. |

MCP tools: `bridge_progress_start`, `bridge_progress_update`, `bridge_progress_get`. Each accepts `accountId`; start/update use an `input` object matching HTTP, and update/get also take `jobId`.

Creation:

```json
{
  "chatId": "ENROLLED_EXACT_CHAT_ID",
  "idempotencyKey": "report-123-start",
  "title": "Preparing your report",
  "detail": "Collecting the source documents",
  "mode": "native_text",
  "intervalMs": 5000,
  "intermediateEdits": 4,
  "finalFallback": "new_message"
}
```

Step update:

```json
{
  "expectedRevision": 1,
  "idempotencyKey": "report-123-step-1",
  "state": "running",
  "detail": "Comparing the documents and checking totals",
  "fraction": 0.4
}
```

Final update, using the current revision:

```json
{
  "expectedRevision": 2,
  "idempotencyKey": "report-123-complete",
  "state": "completed",
  "detail": "Created the report and comparison sheet.",
  "fraction": 1,
  "attachments": [
    { "filePath": "/enrolled-worker-workspace/report.pdf", "label": "Report" },
    {
      "filePath": "/enrolled-worker-workspace/comparison.xlsx",
      "label": "Comparison"
    }
  ]
}
```

The example paths must be replaced with real existing files inside the **enrolled worker's** allowed workspace. Gateway storage paths are not worker paths. Attachments are sent sequentially as separate messages only after the final text succeeds. Apple does not let a text edit insert new attachment bubbles. `label` is manifest metadata, not an attachment caption. Up to ten outputs are accepted per job.

For live cards, upload outputs through the existing file API, then finalize with `fileIds: ["FILE_UUID"]`. Every file must belong to the same account and exact chat. The extension offers authenticated download, Quick Look and share for those files. Native-text jobs may also retain `fileIds`, but they do not automatically transfer gateway files to the worker or send them as attachments. A job of either mode can be opened as a progress card.

## Producer pattern

```ts
const job = await client.request(accountId, "progress", "POST", {
  chatId,
  idempotencyKey: `${runId}:start`,
  title: "Preparing report",
  detail: "Reading sources",
  mode: "native_text",
  intermediateEdits: 3,
});
let revision = job.revision;
async function report(key: string, state: string, detail: string, extra = {}) {
  const updated = await client.request(
    accountId,
    `progress/${job.id}/updates`,
    "POST",
    {
      expectedRevision: revision,
      idempotencyKey: `${runId}:${key}`,
      state,
      detail,
      ...extra,
    },
  );
  revision = updated.revision;
}
await report("analyze", "running", "Checking the totals", { fraction: 0.5 });
// Run your actual work. Report real milestones rather than invented activity.
await report("complete", "completed", "Created the report", {
  fraction: 1,
  attachments: [{ filePath: outputPathOnWorker, label: "Report" }],
});
// Inspect GET progress/:id to distinguish queued, completed and uncertain delivery.
```

Serialize producer updates. On a network timeout, retry the exact request with the same key and revision; do not generate a new key until the outcome is known. Identical retries return their original response. A key reused with different content or a stale revision returns 409. A fresh GET supplies current state. Task states are `running`, `waiting`, `completed`, `failed`, and `cancelled`; the last three are immutable. Start a new job for a new attempt.

Reporting `cancelled` describes the producer's task; it does **not** terminate a process, reverse completed actions, or unsend a message. The producer remains responsible for cancellation. `waiting` is useful for explicit approvals or missing input. No automatic timeout, cancellation button or job executor is implied.

## Permissions, persistence and recovery

- Account and exact-chat grants apply to create/read/update/list. Creation and updates require `messages.send`; native creation and each native edit also require `messages.edit`. Reads require `messages.list`. Only the creating enrolled agent can update a job. Card-only passkey sessions cannot access this endpoint.
- Publishing file IDs requires `files.read`; download requests independently check file access. Another chat's file cannot be attached to a job manifest.
- SQLite persists job revisions, idempotency receipts and native command IDs together. Restarting does not create another initial send. At most one command per job is outstanding. Gateway worker lanes continue to serialize native operations.
- Current owner permissions and chat scope are checked again before dispatch. Existing computer-control ownership is respected.
- An ambiguous native outcome or a send without a single message ID stops automatic sends/edits. Inspect the referenced command and native evidence before deciding how to recover. There is no automatic reconciliation or resume endpoint in this module.
- The job retains the latest 100 history entries and command receipts, with a maximum of 100 active native jobs per account. This is not a retention/TTL service; operators must manage database retention. An unchanged timestamp means no new producer report, not proof the task failed.
- The extension displays only what its paired credential can read. Recipients need the extension and their own granted gateway access. Message URLs contain IDs, not credentials. Apple participant UUIDs do not prove a native chat ID: sharing remains an explicit user action in the chosen conversation, with the intended chat shown before sending.

Transport states are `pending`, `watching`, `paused`, `complete`, `failed`, `outcome_unknown`, and `awaiting_user`. In live-card mode, `awaiting_user` describes user-managed presentation; the server does not observe that a card was actually shared or seen.

## Verification

As of October 7, 2026, `npm run check` passes all 69 tests (including ten progress tests), and the MessagePilot simulator app/extension build succeeds. Automated coverage exercises coalescing, reserved edits, final fallback, ordered attachments, idempotency, revision conflicts, terminal immutability, owner/chat restrictions, revocation, ambiguous outcomes, restart recovery, HTTP → worker fixture dispatch and actual MCP tool calls. The Apple extension compiles for the iOS simulator. This feature has **not** been sent through a live Messages account or visually accepted on a physical device; prior native edit acceptance is separate evidence.
