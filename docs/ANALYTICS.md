# Optional analytics and context budgets

Analytics is disabled unless a gateway policy explicitly enrolls an account and chat. MessagePilot does not silently turn a personal inbox into a telemetry source. Collection and reporting permissions are separate; both intersect existing account/chat authorization.

```json
{
  "analytics": [
    {
      "accountId": "agent-account",
      "chatIds": ["enrolled-chat-id"],
      "observerAgentIds": ["collector"],
      "readerAgentIds": ["developer"],
      "retainDays": 30,
      "storeText": false,
      "contextMessages": 50,
      "contextCharacters": 12000
    }
  ]
}
```

## What is recorded

Each observation carries a stable source ID, chat ID, event kind, occurrence timestamp, gateway observation timestamp, collector-reported source (`native`, `extension`, `agent`, `fixture`) and optional message ID, reaction, media type, action, item count, character/token count or text. Source labels are not Apple-signed evidence. Duplicate source IDs with the same sanitized content are ignored; conflicting reuse is rejected.

Supported kinds: message sent/received/delivered/read/edited/unsent; reaction added/removed; media sent/received; extension opened/closed/action; context used; command accepted/completed/failed/unknown. Media categories include image, video, audio, GIF, sticker, document, archive and other. Reaction labels accept native Tapback types or custom emoji strings. Developers can name their own extension actions and attach counts.

The gateway automatically emits **command** observations for configured chats when accepting a command or recording its terminal result. They measure bridge workflow, not native message delivery. Native read receipts, actual attachment types/counts and extension interactions require an enrolled collector to submit observations. No continuous Apple receipt watcher or automatic complete extension telemetry is claimed. The Messages framework does not expose every built-in app's analytics.

## API and reports

Prefix `/v1/accounts/:account/analytics`:

- `POST /observations`: submit one observation; MCP `bridge_analytics_observe`.
- `GET /report?chatId=...&since=<milliseconds>&until=<milliseconds>`: totals by event, reaction add/remove, media/direction, action, source, message rate/hour, matched delivery/read latency (mean/p50/p95/sample count) and unmatched sent count.
- `GET /events?chatId=...&since=...&until=...`: latest 200 permitted observations, including occurrence and gateway observation timestamps.
- `GET /context?chatId=...`: bounded stored message context when text collection is enabled.
- MCP `bridge_analytics` selects `report`, `events` or `context`.

```json
{
  "sourceId": "receipt-event-42",
  "chatId": "enrolled-chat-id",
  "kind": "message.read",
  "occurredAt": 1791400000000,
  "messageId": "native-stable-message-id",
  "source": "native"
}
```

Use the actual timestamp and explicit receipt evidence. Send acceptance is not delivery; delivery is not a read; opening the extension is not reading every message. Read latency requires matching sent/read observations for the same message within the requested interval. Missing receipts yield `null`/unmatched counts, not zero latency. Multiple observers must coordinate stable IDs to avoid double-counting the same native event. Device clock skew and polling delay affect measurements.

Reaction totals are observed adds/removes, not the current reaction inventory per message. Usage rate is observed messages divided by the requested interval, not proof of user engagement. Media counts rely on the collector's item counts. Reports over 50,000 observations ask the caller to narrow the range. Reports sum explicitly reported context characters/tokens and state how many token observations exist; missing token reports are not a measured zero. Raw observations are preserved for developer analysis; there is no built-in billing or model-specific tokenizer.

## Context and privacy

Text storage defaults off and text is stripped before persistence. When enabled, context retrieval enforces both configured message count and character total. It returns the latest observed version per message, applies observed edits and excludes observed unsends; missing edit/delete observations cannot be inferred. It does not retrieve the whole Apple database. This is an application context-builder budget, not a universal LLM token limit or an override of a model provider's context window.

Retention cleanup runs during ingestion/reporting and on gateway heartbeat for configured policies. Removing a policy stops collection/access; retained rows are not automatically erased by removing configuration. Disabling text collection prevents new text storage and context access, but does not erase previously stored text immediately. Manage deletion/retention in the controlled backend as appropriate. SQLite backups may retain prior data; coordinate backup retention separately.

Only exact enrolled chats are accessible. Reports/context are authenticated and not public links. Do not place message text, coordinates, OAuth credentials or raw phone trees in analytics source IDs or action names. Fixture tests cover chat isolation, idempotency, unknown reads, matched latency, reaction labels, media counts and context limits. Live production analytics remains dependent on developer enrollment and genuine collectors.
