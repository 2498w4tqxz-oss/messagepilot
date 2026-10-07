# Reusable backend library

The library stores AI-created artifacts independently of a single message: drafts, prompts, generated text, layouts, game states, app specifications, reusable templates, tool results and references to original files. It is available through HTTP and MCP. A library entry is not automatically sent, published or executed.

## Implemented model

Each immutable version records asset ID, revision, created timestamp, authenticated actor, exact account/chat scope, title, kind, tags, JSON content, local file IDs and optional provenance (agent, model, source and parent asset ID). Caller-supplied provenance is descriptive, not trusted authentication. Each version has a content-sensitive idempotency key. `expectedRevision` prevents two agents from silently overwriting each other; successful updates preserve old versions.

Default storage is SQLite in the gateway database. Large bytes belong in the file layer, not JSON (512 KiB per asset version). References must point to files in the same authorized account and chat. No automatic deletion, public sharing, embedding, model training or cross-chat search occurs.

## API

Prefix: `/v1/accounts/:account/library`. Existing Bearer token and intersected chat policy apply. Reading requires `files.read`; saving requires `files.write`.

- `POST /library`: create; `expectedRevision: 0`.
- `POST /library/:id`: update; use the current revision.
- `GET /library?chatId=...`: latest versions, up to 200 assets.
- `GET /library/:id?chatId=...&revision=2`: exact historical version; omit revision for latest.

```json
{
  "chatId": "enrolled-chat-id",
  "idempotencyKey": "draft-123-create",
  "expectedRevision": 0,
  "title": "Reusable inspection checklist",
  "kind": "checklist",
  "tags": ["operations", "template"],
  "content": { "items": ["Confirm appointment", "Capture photos"] },
  "fileIds": [],
  "provenance": {
    "agent": "operations",
    "source": "generated from approved requirements"
  }
}
```

MCP: `bridge_library_save` and `bridge_library_read`. Keep idempotency keys stable when retrying the same write, and use a new key for a different version.

## Bring your own backend

`LibraryProvider` in `src/library.ts` defines `list(scope)`, `get(scope,id,revision?)`, and `save(scope,id?,value,actor)`. It separates application policy from storage. The bundled HTTP adapter allows developers to implement this contract over Postgres, Convex, Firestore, DynamoDB, a local database service or another backend without coupling MessagePilot to one vendor.

```json
{
  "library": {
    "provider": "http",
    "url": "https://your-backend.example/messagepilot-library",
    "tokenEnv": "LIBRARY_PROVIDER_TOKEN"
  }
}
```

The adapter POSTs `{version:1, action:"list|get|save", scope:{accountId,chatId}, data:{...}}` to that fixed HTTPS endpoint with its server-side Bearer secret. Redirects are refused. A `get` returns an asset version or JSON `null`; `list` returns an array; `save` returns the committed asset version. Use `409` for revision/idempotency conflicts. Remote implementations must atomically enforce scoped keys, immutable revisions, actor/content-sensitive idempotency and CAS. The remote provider is a trusted data processor: the gateway authorizes the request before dispatch, but cannot enforce a remote database's internal isolation. Provision one narrowly granted provider token and validate the supplied scope there too.

This is a real generic adapter, not a claim that native SDK adapters for every database are bundled. Moving existing assets between providers is a developer migration; changing configuration does not copy data.

## Blob storage and cloud placement

Current built-in file bytes are on the gateway filesystem. That filesystem can live on a developer-controlled local Mac, dedicated server or managed attached volume. Remote library JSON can contain application-defined object references for S3/GCS/R2/Drive/etc.; those references are not automatically fetched, exposed publicly or treated as executable URLs by MessagePilot.

For a fully remote blob implementation, preserve the file API's streaming bytes, immutable hash, exact account/chat authorization, quotas, ranges and authenticated downloads. Keep blob ownership and metadata transactions consistent using pending/committed records and orphan cleanup. Avoid placing expiring signed URLs inside long-lived iMessage payloads; store a stable library asset ID and authorize at retrieval. Dedicated S3/GCS/R2 streaming adapters, migration, reference-counted garbage collection and full-text/vector search remain extension points, not implemented features.
