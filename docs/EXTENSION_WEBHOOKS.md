# Invites, Location and Check In webhooks

MessagePilot exposes a durable webhook workflow around these Apple Messages extensions. It is **agent-mediated**: an authenticated request enters the queue, an enrolled agent claims it, operates the correct device/chat, verifies the native result and submits an observation. MessagePilot signs and delivers the resulting callback. This implementation does not register a webhook with Apple, autonomously drive these three extensions, or continuously monitor them without a running observer agent.

Research on 2026-10-07 found no documented public Apple Invites, Messages Location or Messages Check In webhook API. Apple's documented interfaces are the app/web UI: [Invites creation](https://support.apple.com/guide/apple-invites/create-an-event-dev1d1c7cb6b/ios), [Invites notifications](https://support.apple.com/guide/apple-invites/change-notification-settings-devd1a3c152e/ios), [Messages location sharing](https://support.apple.com/en-euro/guide/iphone/iph69b192bc2/ios), and [Check In privacy and requirements](https://www.apple.com/legal/privacy/data/en/check-in/). App Store Connect webhooks and MDM check-in endpoints are different products.

## Configuration and scope

Add `extensionHooks` to the gateway configuration. Hooks are administrator-configured; API callers cannot choose a recipient or callback URL. Use dedicated caller and observer agent credentials, enrolled in the same account and allowed chat. Ordinary messaging operation grants do not grant hook access. Hook grants also do not grant messaging, shell or device access: provision those independently for the actual observer/executor.

```json
{
  "extensionHooks": [
    {
      "id": "my-invites",
      "accountId": "agent-account",
      "chatId": "EXACT_ENROLLED_CHAT_ID",
      "feature": "invites",
      "url": "https://your-service.example/hooks/messagepilot",
      "signingSecretEnv": "MESSAGEPILOT_INVITES_SIGNING_SECRET",
      "requestAgentIds": ["workflow-caller"],
      "observerAgentIds": ["phone-agent"],
      "includeCoordinates": false,
      "allowLoopbackHttp": false
    }
  ]
}
```

Repeat with `feature: "location"` and `feature: "checkin"` as needed. Each signing secret must contain at least 32 characters; generate a random secret, keep it in the environment, and share it only with the callback receiver. Callback URLs require HTTPS; tests may explicitly enable HTTP to literal `127.0.0.1` or `[::1]`. Redirects are never followed. Treat configured callback destinations as trusted data recipients. Inbound HTTP should be protected with TLS when accessed off-host.

The gateway intersects account and agent chat permissions before exposing a hook. Empty chat grants deny access. Request/observer roles are distinct, and passkey card-only sessions cannot use these endpoints. Stored request bodies and pending callbacks are bound to the configured account, chat, feature, destination and coordinate setting; changing that binding hides old requests and disables old pending callbacks rather than forwarding them to a new destination.

Coordinates are rejected by default. Only an explicitly opted-in `location` hook accepts structured coordinates. Keep free-text summaries minimal: do not insert coordinates, personal addresses, raw screenshots, guest lists or unrelated phone content into them. The gateway cannot validate a factual UI claim or redact every possible secret from text supplied by a trusted observer.

## Incoming requests

Use the dedicated caller's Bearer token:

```http
POST /v1/accounts/agent-account/extension-hooks/my-invites/requests
Authorization: Bearer <caller-token>
Content-Type: application/json

{
  "idempotencyKey": "invite-creation-001",
  "action": "create",
  "parameters": {"title": "Private test event"}
}
```

HTTP 202 returns a durable request with `state: "requested"`. It does **not** mean an event was created, a location was shared or a Check In was started. Repeating the same key/content returns the same request; changed content returns 409. Request submission emits `extension.action.requested` to the configured callback.

| Extension | Actions and required parameters                                                                                                                                                      |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Invites   | `create`: title, optional description/ISO startsAt; `share`: Apple Invites HTTPS URL; `inspect`: none                                                                                |
| Location  | `send_pin`: none; `start_sharing`: duration (`one_hour`, `end_of_day`, `indefinitely`); `stop_sharing`: none; `inspect`: none                                                        |
| Check In  | `start_timer`: minutes and dataLevel (`limited`, `full`); `start_destination`: destination, travelMode (`driving`, `walking`, `transit`), dataLevel; `cancel`: none; `inspect`: none |

These are workflow contracts for an enrolled agent, not claims that every action is available on every device or recipient. A creation request does not authorize invitations to extra guests. Location and Check In data-sharing choices must match the supplied intent.

## Claim, operate, observe

With an observer token, claim a request once:

```http
POST /v1/accounts/agent-account/extension-hooks/my-invites/requests/<request-id>/claim
```

A second claim returns 409. Read `/requests` for the latest 100 requests or `/requests/<request-id>` for one receipt. The agent must inspect the bound chat, execute using its separately authorized phone/device tools and verify the actual result. Then report:

```json
{
  "sourceId": "device-observation-001",
  "observedAt": 1791398400000,
  "state": "created",
  "requestId": "UUID_FROM_REQUEST",
  "outcome": "completed",
  "evidence": { "kind": "ui", "reference": "private-evidence-id" },
  "summary": "Synthetic event persisted in the native app"
}
```

Submit this to `POST /v1/accounts/<account>/extension-hooks/<hook>/observations`. Only the claiming observer may resolve the request. Outcomes are `completed`, `blocked` or `failed`. `unavailable` cannot complete an action. Following gateway restart, claimed requests become `outcome_unknown`; they must be reconciled against native state, not automatically replayed. There is no automatic claim lease expiry or reassignment.

For independently observed changes, omit both requestId and outcome. Each sourceId must uniquely identify that observation; repeated identical observations deduplicate, and reuse with different content returns 409. The observer is responsible for detecting changes, selecting stable source IDs, ordering observations and preventing duplicate semantic reports. The gateway is not an RSVP scraper, GPS watcher or Check In monitor.

| Extension | Accepted observed states                                                                  |
| --------- | ----------------------------------------------------------------------------------------- |
| Invites   | `created`, `shared`, `updated`, `rsvp_changed`, `cancelled`, `unavailable`                |
| Location  | `pin_sent`, `sharing_started`, `location_updated`, `sharing_stopped`, `unavailable`       |
| Check In  | `started`, `updated`, `arrived`, `timer_completed`, `delayed`, `cancelled`, `unavailable` |

Callback kind is `extension.<feature>.<state>`. Evidence kind `ui` or `native` is labeled `agent_reported`; `fixture` stays `fixture`. No payload is labeled Apple-verified. Never infer Check In arrival, completion or a person's safety from elapsed time, a callback acknowledgement, a lack of updates or a simulator. A delayed/offline observer cannot replace Apple's native safety notifications.

## Signed callbacks and delivery

Callbacks include a stable event `id`, bound account/chat, feature, kind, creation timestamp, `source: "messagepilot.agent_mediated"` and observation/request data. They use:

- `X-MessagePilot-Id`: stable event ID.
- `X-MessagePilot-Timestamp`: Unix seconds at delivery attempt.
- `X-MessagePilot-Signature`: `v1=` followed by HMAC-SHA256 of `<timestamp>.<raw body>` using the configured secret.

Use exported `verifyHookSignature(secret, timestamp, rawBody, signature)` before parsing; it uses constant-time comparison and a five-minute timestamp tolerance. Persist receiver-side event IDs to prevent replay/duplicate processing, then return a 2xx after durable acceptance. Signature validation alone is not deduplication.

SQLite persists the outbox atomically with the request/observation. Delivery is at least once, with stable IDs/bodies, five-second attempt timeouts, exponential retries and eight total attempts. A one-second dispatcher services the queue; ready callbacks may be delivered concurrently and are not ordered. A lost acknowledgement can cause a duplicate delivery. This is a webhook timing policy, not an Apple action latency claim. `GET .../deliveries` returns the latest 100 delivery states (`pending`, `delivered`, `failed`, `disabled`), attempts and HTTP status. Failed callbacks stay recorded; there is no automatic dead-letter replay endpoint.

## MCP tools

- `bridge_extension_request`: queue a workflow with the same typed request contract.
- `bridge_extension_claim`: exclusively claim before operating Apple UI.
- `bridge_extension_observe`: report native evidence and optional terminal outcome.
- `bridge_extension_status`: inspect request receipts and callback delivery.

The agent supplies the configured hook ID; the same HTTP authorization and scope enforcement apply. These tools use MessagePilot's MCP server and do not install an observer from the Official Registry.

## Controlled physical-phone acceptance — 2026-10-07

| Workflow | Native result                                                                                                                                                                 | Bridge callback result                                                              |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Invites  | Created a synthetic invitation and shared only to the approved self-chat. Sent and received rich invitation cards observed. Synthetic event remains available for inspection. | Request, created and shared callbacks verified with the receiver's HMAC check.      |
| Location | Sent a static pin only to the approved self-chat; both outgoing and incoming cards observed. No continuous location sharing enabled.                                          | Pin-sent callback verified; coordinate/address fields omitted.                      |
| Check In | Native UI explicitly said this recipient cannot receive Check In. Draft removed; no Check In started.                                                                         | Unavailable observation completed the request as blocked; signed callback verified. |

[Sanitized callback evidence](evidence/extension-webhooks.json) contains event types, signature verification and local callback delay only. Seven callbacks were received and verified. The native middle step was performed by an agent through the authorized phone-control workflow, not by a new unattended Apple SDK. No RSVP watcher, ongoing GPS update stream, Check In completion or production public callback endpoint was proven. The phone's raw evidence remains private and is excluded from the repository.

Run one gateway dispatcher per database. There are no distributed callback leases for multiple gateway processes.
