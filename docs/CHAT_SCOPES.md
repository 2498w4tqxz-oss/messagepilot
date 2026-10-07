# Chat-restricted access

MessagePilot supports an account-wide chat ceiling (`accounts[].allowedChatIds`) and per-agent grants (`agents[].chats[accountId]`). When both exist, authority is their intersection. An empty list grants no chats; a missing account entry in an agent's `chats` map grants no chats for that account. Omitting both retains the dedicated-account mode.

For a personal account where the bridge itself must not collect other conversations, use **both the account ceiling and the separate `messagepilot-scoped` worker**. The full-account worker refuses a native configuration containing `allowedChatIds`, before initializing its upstream library. The gateway verifies the worker's declared chat ceiling matches account enrollment. Restarted queues are rechecked against the current account ceiling before dispatch.

The scoped binary has no Beeper library dependency, account watcher, inbox enumeration, global search, Contacts lookup, or computer execution tool. It opens `chat.db` read-only. Every message query joins through the exact enrolled chat GUID; message IDs, replies, edits, reactions and unsends must belong to that chat. Own-message and Apple time-window checks precede mutation. UI automation verifies the direct conversation's exact phone/email, excludes the sidebar and pinned previews from traversal, and refuses ambiguous message targets. Contact names alone are not sufficient identity proof. The currently calibrated UI is English on macOS 27.2; other layouts/locales can fail closed. Restricted UI operations currently support direct conversations. Scoped database reads can use an explicitly enrolled group GUID.

## Enroll

1. As the local administrator, resolve only the intended recipient: `npx tsx src/cli.ts scope-resolve +15555550100`. The command queries one exact address and requires one matching direct iMessage conversation. It does not list or read the inbox.
2. Copy `examples/gateway.scoped.json`, `examples/worker.scoped.json`, and `examples/native.scoped.json` into ignored `*.local.json` configuration. Put the observed chat ID in all relevant allowlists. Set the actual OS username, two unique random tokens in environment variables, and the approved media directory.
3. Build `swift build --package-path native -c release --product messagepilot-scoped`.
4. Grant Full Disk Access and Accessibility to the execution environment. Media automation also needs Messages Automation permission. Set `enableUI: true` only for the enrolled session.
5. Start the gateway and worker using the normal CLI with the scoped configuration and `--live`. Keep `enableToolkit: false`.

The restricted identity string labels explicit local chat enrollment. It is **not independently verified evidence of the signed-in Apple sender identity**. The normal dedicated-account worker has separate Apple identity verification. Sender selection and Apple Account activation still need enrollment checks.

## API enforcement

- Every messaging command needs an exact permitted `chatId`. Chat listing, chat creation, unscoped search, selector overrides, general app snapshots, screenshots, shell/file tools, developer tools, MCP connections, and computer takeover are denied to a chat-restricted credential.
- A scoped credential cannot read or cancel another chat's command receipt, even with its command ID.
- REST event history and SSE replay/live delivery filter command events by chat. Unstructured account-wide native event batches, cards, device events and passkey-management endpoints are unavailable under a chat ceiling. Use scoped `messages.list`/`messages.search` for updates; the restricted worker does not currently push incoming-message events.
- `messages.inspect` returns the permitted transcript/composer or an explicitly opened native picker/menu. It never returns a whole-desktop screenshot.
- `messages.format` supports native styles and UTF-16 ranges. `messages.effect` validates effect families and supports a text-effect range. `messages.draft.discard` requires the exact authored draft text, so recovery cannot silently overwrite a different draft. No failed rich send automatically becomes a plain send.
- Media paths must resolve inside the configured media workspace, including symlinks. Media and a text caption use separate commands in restricted mode.
- Read endpoints currently return the latest 50 messages; cursor pagination is not yet supported by the restricted native worker. Do not treat a partial page as complete history.

These are application/credential boundaries. macOS Full Disk Access itself is not per-chat, and the worker OS user is not sandboxed from its own files. An administrator who can change configuration or execute arbitrary local code can change the enrollment. A chat-restricted credential cannot grant itself that authority. Accepted commands are durable; cancel queued commands before revoking a grant when appropriate.

A macOS UI action depends on a stable session. Concurrent manual edits or switching conversations may cause an operation to fail. Inspect the scoped receipt and native state before retrying an uncertain mutation.
