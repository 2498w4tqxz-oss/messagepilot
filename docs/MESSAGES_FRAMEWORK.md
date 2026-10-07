# Messages framework and backend-free experiences

MessagePilot exposes the public Messages content families through `apple/Messages/ConversationPort.swift`: text, local attachments, `MSSticker`, and `MSMessage`. Each supports staging (`insert...`) or direct send (`send...`). The existing card extension uses live layouts with template fallback, explicit user-triggered direct sends, and selected-card session continuation. `PilotStickerBrowser` provides a reusable browser for bundled or prepared local stickers.

This is a developer integration layer, not a claim that the public Messages framework exposes every control in Apple's Messages app. Native editing/unsending, system text formatting/effects, polls, Send Later, Check In and other built-in extensions remain separate native/UI paths documented in the capability matrix.

## Direct sends for speed

Apple documents four direct APIs: `sendText`, `sendAttachment`, `send(MSSticker)` and `send(MSMessage)`. They require a visible extension, the `.messages` presentation context and recent user interaction. The framework rejects attempts while invisible, without recent interaction, or in `.media` presentation context. An open session alone is insufficient. [Apple direct-send documentation](<https://developer.apple.com/documentation/messages/msconversation/send(_:completionhandler:)-9krz>).

Preload/decode the content while displaying it. On the user's Send/Take turn tap, call `ConversationPort.submit(..., mode: .direct)` synchronously from that action. Avoid placing a slow network fetch between the tap and send. Apple remains the authority on whether the interaction is recent enough; MessagePilot does not fabricate touches or claim background-send entitlement.

```swift
// Inside the active MSMessagesAppViewController, in the button action:
ConversationPort(self).submit(.text("Task accepted"), mode: .direct) { error in
  // nil means the message started sending, not recipient delivery/read.
  // Surface errors. Never blindly retry an uncertain send.
}
```

Choose `.stage` when the user needs to review/edit in the input field. There is no automatic fallback that might duplicate a send. Local file URLs are required for attachment APIs. Sending an arbitrary stored file does not guarantee an inline native renderer for that type. Media/sticker constraints remain Apple's and are validated by the system.

## Rich layouts, stickers and interactive turns

- `MSMessageTemplateLayout`: image/media and captions for a compact rich message. Use meaningful alternate text/fallback presentation.
- `MSMessageLiveLayout`: extension-rendered interactive content in the transcript, plus required alternate template. Recipients without the extension see the alternate representation, not the full live interaction. Existing carousels use this path.
- `MSSession`: reuse the selected message's session for the next update to **that same experience**. Starting a different card creates a fresh session; the extension now checks card identity before continuation.
- `MSSticker` / `MSStickerBrowserViewController`: generated stickers and reusable packs, including user-driven peel/placement where Apple supports it. A direct sticker send and attaching a sticker to a previous bubble are different interactions.
- Lifecycle: `willBecomeActive`, `didBecomeActive`, selection, receipt and presentation callbacks are entry points. Extensions are not permanent background processes, and transcript instances can coexist with a composition instance.

A local send callback reports initiation only. Gateway receipts, Apple send initiation, native delivery and recipient read are distinct events. Native rich-message tests elsewhere in this repository do not automatically prove this new extension adapter on a physical phone.

## State carried in the message

Yes: small turn-based experiences can work without a backend. Encode application state into `MSMessage.url`, carry it in the selected message, decode on activation, validate the turn, then emit the next message using the same `MSSession`. Apple explicitly describes using the URL for application data. [MSMessage URL](https://developer.apple.com/documentation/messages/msmessage/url), [MSSession](https://developer.apple.com/documentation/messages/mssession).

`apple/Shared/PeerState.swift` implements a generic Codable envelope with:

- protocol version, experience UUID, revision, parent revision and turn UUID;
- zlib compression and URL-safe base64;
- a conservative **MessagePilot-defined** 8 KiB URL cap and 64 KiB decoded cap;
- scheme/host/version checks and expected experience/parent-revision validation;
- bounded decompression and rejection of malformed/oversized states.

```swift
let state = PeerStateEnvelope(
  experienceID: experienceID, revision: 3, parentRevision: 2,
  turnID: UUID(), state: ["task": "Review layout", "status": "approved"])
let url = try PeerStateCodec.encode(state)
let message = ConversationPort.message(
  layout: fallbackLayout, url: url, summary: "Layout approved",
  continuing: activeConversation?.selectedMessage)
// Submit only from an allowed user interaction in the active extension.
```

The limits are not documented Apple universal payload maxima. Compression is not encryption, authentication or a way to transfer huge files invisibly. Do not include secrets. Payload state is participant-controlled input: validate schema, roles, legal transitions and replay/duplicate turns. The codec validates an expected revision but does not implement authoritative conflict resolution, turn permissions or durable replay storage for your game. Concurrent/offline turns can conflict; select deterministic merge/reject behavior. Transport can delay, duplicate or reorder observations. It is not guaranteed instantaneous realtime synchronization.

Useful backend-free cases: turn-based games, compact checklists, polls owned by your extension, small collaborative choices and state snapshots. Prefer the backend library when you need durable shared history, large media, many participants, cross-chat access, globally authoritative state, external tool execution or independent identity authorization. A hybrid message can carry a small state snapshot plus an asset ID.

## What Apple identity does and does not supply

Messages uses the device's signed-in Apple Account and transport identity. The extension does not need its own login simply to participate in that active conversation. It receives scoped participant identifiers; those UUIDs are not an Apple ID email address, a universal user ID, a backend OAuth token or a device-independent proof of identity. [Participant identifier](https://developer.apple.com/documentation/messages/msconversation/localparticipantidentifier).

A developer backend still needs account binding and authorization. MessagePilot uses explicit enrolled identities, worker credentials, chat grants and optional passkeys. Google Workspace has separate OAuth. Do not treat arbitrary state fields such as `role: admin` as trusted because they arrived through iMessage. Do not equate native Messages sign-in with Sign in with Apple identity-token verification.

## Verification

The extension and primary app compile for iOS Simulator. `tests/swift/PeerStateChecks.swift` verifies codec roundtrip, different-experience rejection, stale revision rejection, size limits and malformed input. Compile/run with:

```sh
swiftc apple/Shared/PeerState.swift tests/swift/PeerStateChecks.swift -o work/peer-state-checks
work/peer-state-checks
```

This does not prove peer-to-peer delivery across two physical Apple identities. Physical installation of the changed app still requires valid Xcode account/signing profiles with the declared capabilities. No signing restrictions or SIP settings were bypassed.
