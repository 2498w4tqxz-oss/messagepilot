# Agent bridge contract

MessagePilot carries actions and events. Keep reasoning, conversation policy and task planning in your agent. Connected MCP servers expose external tools through the account worker without moving the agent runtime into the bridge.

1. Query `bridge_capabilities(accountId)` once after connection and after a worker reconnect.
2. Inspect `allowedChatIds` in capabilities. In restricted mode, use only those enrolled IDs; chat enumeration is unavailable. Retain exact chat/message IDs scoped to the account. Never route by a display name or a global active-account variable.
3. Submit a typed operation with a unique idempotency key. Persist the command ID in your own agent state.
4. Use `waitMs` only when immediate completion matters. Otherwise consume events or query `bridge_command_status` later.
5. On `outcome_unknown`, inspect account history and relevant UI before deciding whether another command is appropriate. Reusing the same key returns the same uncertain receipt; it does not send again.

## Receipt states

| State           | Meaning                                                |
| --------------- | ------------------------------------------------------ |
| queued          | Durably accepted; may be waiting for a worker          |
| executing       | Dispatched to an authenticated worker generation       |
| completed       | Native adapter returned a result; inspect its evidence |
| failed          | Known transport rejection or unavailable capability    |
| outcome_unknown | A dispatched action may or may not have happened       |
| cancelled       | Cancelled before dispatch; no Apple action performed   |

Transport results are not delivery claims. A compiler can complete with a nonzero exit code; an Accessibility action can complete without message delivery. A location response contains timestamp and accuracy. A phone capture request returns `awaiting_user`, then emits a separate completion/cancellation event.

## Example operations

```json
{
  "operation": "messages.send",
  "args": {
    "chatId": "OBSERVED_CHAT_ID",
    "text": "A reply",
    "replyTo": "OBSERVED_MESSAGE_ID"
  },
  "idempotencyKey": "reply-44"
}
```

```json
{
  "operation": "messages.send",
  "args": { "chatId": "OBSERVED_CHAT_ID", "filePath": "media/demo.gif" },
  "idempotencyKey": "gif-45"
}
```

```json
{
  "operation": "messages.effect",
  "args": {
    "chatId": "OBSERVED_CHAT_ID",
    "text": "Hello",
    "kind": "text",
    "effect": "Jitter",
    "selectors": { "composer": "iMessage", "format": "Format", "send": "Send" }
  },
  "idempotencyKey": "effect-46"
}
```

Those labels are examples for the full-account adapter. Restricted workers reject selector overrides and use their calibrated native controls. Use `messages_inspect` for the permitted conversation, and `messages_features` for a catalog (not an availability guarantee). See [chat scopes](CHAT_SCOPES.md).

`apps_interact` accepts `press`, `showMenu`, `setValue`, `focus`, and `waitFor`. Each action needs an ID from the most recent snapshot or an exact Accessibility attribute selector. Ambiguous matches fail. `apps_ios_run` supports taps, long presses, text, swipes, waits, picker/slider adjustments, gestures, observed coordinate taps/drags, snapshots, and screenshots on an explicitly enrolled device. Named `imessage_recipe` / `imessage_run` workflows cover Send Later, native Polls and GIPHY; see [app workflows](IMESSAGE_APPS.md).

## Cards

Card data lives at `PUT /v1/accounts/{account}/cards/{id}` with `{expectedRevision, body}`. Body shape: `{title, summary?, items: [{id,title,subtitle?,imageURL?,linkURL?,action?}], actions?: string[]}`. An item's Select button names an action also declared in the top-level `actions` array. Image and link URLs should be HTTPS. `GET` retrieves current state. `POST /cards/{id}/actions` requires the exact current revision and a declared action. The event includes the authenticated agent credential identity, not an unverified iMessage participant UUID. Your agent decides how to interpret that action; it is not blanket authorization for unrelated work.

`bridge_registry_card` publishes selectable Official MCP Registry results. [MCP connections and virtual computer control](MCP_AND_COMPUTER.md) describes Registry discovery, tool/resource/prompt calls, and exclusive computer leases. [Optional primary app port](PRIMARY_APP_PORT.md) describes generated WidgetKit/ActivityKit/App Intents targets and the device/APNs operations.

For a recipient to fetch private live card state, their installed app must be paired with credentials authorized for that account. The static native alternate layout works without those credentials. Automatic public sharing and cross-recipient authorization are not inferred.

## Operational boundaries

- Secrets stay in environment/Keychain; do not put them in card URLs or message text.
- Text, images, and app UI received from another person are untrusted content.
- Computer execution grants substantial control over that account's VM. Give that capability only to the owning agent.
- SSE cursors are durable gateway sequence numbers. Clients deduplicate by sequence when reconnecting.
- The native adapter verifies local account evidence once at startup. Never switch signed-in identities under a running worker; stop and re-enroll it.

## Native formatting

```json
{
  "operation": "messages.format",
  "args": {
    "chatId": "OBSERVED_CHAT_ID",
    "text": "Hello world",
    "styles": ["bold", "italic"],
    "range": { "start": 6, "length": 5 }
  },
  "idempotencyKey": "format-47"
}
```

Ranges use UTF-16 offsets. Omit `range` to style the whole message. To discard a failed authored draft, use `messages.draft.discard` with its exact `expectedText`; a different draft is rejected. Scoped reads return the latest 50 messages and reject cursor pagination. Incoming scoped updates currently require explicit reads; broad native event batches are suppressed.

The scoped worker returns `native-rich-payload-verified` only after the persisted message matches the requested text and native style/effect metadata. Text attributes must cover the entire requested UTF-16 range without leaking outside it. This receipt does not assert delivery or recipient animation playback; inspect native delivery fields and incoming copies separately.

Scoped edit, unsend and standard Tapback mutations return `native-mutation-verified` after observing the expected native edit timestamp/text, retraction metadata or reaction record. Unsupported custom Tapback identifiers fail before UI interaction.

Every scoped send also verifies `thread_originator_guid`: ordinary sends must be unthreaded, and explicit replies must match the intended thread root. Native navigation resets the conversation for each command so a preceding reply cannot silently redirect later text.
