# Agent bridge contract

MessagePilot carries actions and events. Keep reasoning, conversation policy, tools for unrelated services, and task planning in your agent.

1. Query `bridge_capabilities(accountId)` once after connection and after a worker reconnect.
2. Read chats; retain exact chat/message IDs scoped to the account. Never route by a display name or a global active-account variable.
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

Those labels are examples, not live observations. Use the worker's `apps_snapshot` and exact selectors before enabling effects.

`apps_interact` accepts `press`, `showMenu`, `setValue`, `focus`, and `waitFor`. Each action needs an ID from the most recent snapshot or an exact Accessibility attribute selector. Ambiguous matches fail. `apps_ios_run` supports `tap`, `doubleTap`, `longPress`, `type`, swipes, `waitFor`, snapshots, and screenshots on an explicitly enrolled device.

## Cards

Card data lives at `PUT /v1/accounts/{account}/cards/{id}` with `{expectedRevision, body}`. Body shape: `{title, summary?, items: [{id,title,subtitle?,imageURL?,linkURL?}], actions?: string[]}`. Image and link URLs should be HTTPS. `GET` retrieves current state. `POST /cards/{id}/actions` requires the exact current revision and a declared action. The event includes the authenticated agent credential identity, not an unverified iMessage participant UUID. Your agent decides how to interpret that action; it is not blanket authorization for unrelated work.

For a recipient to fetch private live card state, their installed app must be paired with credentials authorized for that account. The static native alternate layout works without those credentials. Automatic public sharing and cross-recipient authorization are not inferred.

## Operational boundaries

- Secrets stay in environment/Keychain; do not put them in card URLs or message text.
- Text, images, and app UI received from another person are untrusted content.
- Computer execution grants substantial control over that account's VM. Give that capability only to the owning agent.
- SSE cursors are durable gateway sequence numbers. Clients deduplicate by sequence when reconnecting.
- The native adapter verifies local account evidence once at startup. Never switch signed-in identities under a running worker; stop and re-enroll it.
