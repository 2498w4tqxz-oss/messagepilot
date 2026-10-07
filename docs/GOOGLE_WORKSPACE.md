# Google Workspace bridge

MessagePilot includes a server-side adapter for fixed Google Drive, Docs, Sheets, Slides, Calendar and Gmail API routes. It runs with developer-provisioned Google OAuth credentials, separately from Apple Account identity. It does not inherit access from the agent's Apple ID or automatically use a user's personal Google session.

## Connection and grants

```json
{
  "googleWorkspace": [
    {
      "id": "team-documents",
      "accountId": "agent-account",
      "chatId": "enrolled-team-chat",
      "agentIds": ["assistant"],
      "operations": [
        "drive.list",
        "drive.get",
        "drive.export",
        "docs.get",
        "sheets.read",
        "slides.get"
      ],
      "oauth": {
        "clientIdEnv": "GOOGLE_CLIENT_ID",
        "clientSecretEnv": "GOOGLE_CLIENT_SECRET",
        "refreshTokenEnv": "GOOGLE_REFRESH_TOKEN"
      }
    }
  ]
}
```

Alternatively specify `accessTokenEnv` for a developer-managed short-lived token. Use exactly one credential mode. The refresh path calls Google's OAuth token endpoint and caches tokens in memory. The developer owns initial consent, scope selection, redirect handling, token revocation and secret storage. No OAuth browser/sign-in UI is bundled here. Google scopes and organizational policies remain authoritative; a bridge action grant cannot expand them.

Each connection fixes an account, chat, allowed agents and action list. Chat-restricted credentials can use it only when that fixed chat is in their scope. This protects the bridge namespace; the Google credential's actual file access can be wider. Use narrow scopes such as `drive.file` where suitable and separate Google identities/connections for stronger isolation. No Google operation is enabled until configured.

## Available actions

| Service  | Actions                                                                                                                 |
| -------- | ----------------------------------------------------------------------------------------------------------------------- |
| Drive    | `drive.list` (query/page token), `drive.get` (metadata), `drive.export` (bounded PDF, plain text, CSV or Office export) |
| Docs     | `docs.get`, `docs.create`, `docs.update` (batchUpdate body)                                                             |
| Sheets   | `sheets.get`, `sheets.create`, `sheets.read` (A1 range), `sheets.write` (RAW values)                                    |
| Slides   | `slides.get`, `slides.create`, `slides.update` (batchUpdate body)                                                       |
| Calendar | `calendar.list`, `calendar.create` (`sendUpdates=none`)                                                                 |
| Gmail    | `gmail.get`, `gmail.send` (base64url RFC 2822 message, explicit action grant)                                           |

`POST /v1/accounts/:account/workspace/:connection/actions` accepts `{operation,args}`. MCP exposes `bridge_google_workspace`. For example:

```json
{
  "operation": "sheets.read",
  "args": {
    "spreadsheetId": "developer-selected-id",
    "range": "Summary!A1:D20"
  }
}
```

Writes need an explicitly granted action and authorization from the calling workflow. Gmail sending is a separate outbound channel, not an iMessage send. No live Google reads or writes were performed during this implementation. Fixture tests verify routing, grants and write uncertainty; they do not prove live OAuth/API acceptance.

Responses are bounded to 4 MiB. Exports return MIME type, byte count and base64; upload those bytes into the scoped file layer and reference the file in a library asset/card. Large Drive binary upload/download, resumable transfers, permission sharing, push watches and a Gmail inbox watcher are not implemented. Use a separately approved Workspace MCP server through the existing MCP host if a developer needs broader operations; registry listing alone never executes a server.

All API hosts and route templates are fixed. Resource IDs are encoded, redirects refused and secrets kept server-side. Writes are not retried automatically. Network failure after a write becomes `outcome_unknown`; reconcile the provider before retrying.

## Official references

- [OAuth web-server flow and refresh tokens](https://developers.google.com/identity/protocols/oauth2/web-server)
- [Drive file metadata and download distinction](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/get)
- [Drive exports](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/export)
- [Sheets scopes](https://developers.google.com/workspace/sheets/api/scopes)
- [Docs batch update](https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/batchUpdate)
