# MessagePilot

**A fast, account-isolated bridge between agents and Apple's messaging environment.**

MessagePilot connects an external agent to its own Apple Account, Messages session, iMessage apps, development tools, and virtual Mac. It does not choose a model, reason about conversations, or run an agent's business workflows. No BlueBubbles server, helper, credentials, or protocol is required.

## Components

| Component             | Purpose                                                                        |
| --------------------- | ------------------------------------------------------------------------------ |
| HTTP + MCP gateway    | Typed operations, account authorization, command receipts, replayable events   |
| Persistent Mac worker | One warm native process per account; SIP-enabled Messages automation           |
| iMessage extension    | Native interactive cards, carousels, previews, and generated text stickers     |
| iPhone companion      | Explicit pairing; foreground location, AR pose capture, RoomPlan scan requests |
| Xcode UI harness      | Operate Messages and installed iMessage apps on an enrolled agent-only device  |
| Virtual Mac app       | Create, install, open, and run separate Apple-silicon macOS virtual machines   |

The bridge also includes an Official MCP Registry client, resident MCP connections inside each account worker, exclusive virtual-computer control, and Apple developer-tool adapters. Generated iMessage apps can opt into a primary app port for widgets, Live Activities/Dynamic Island, App Intents, and device capabilities; it is disabled by default in the generator.

The native Messages adapter uses the MIT-licensed `beeper/platform-imessage` library pinned to a specific commit. MessagePilot owns the bridge, account routing, protocol, persistence, development tools, app extension, device bridge, and virtual computer. This is a new build, not a fork of the user's prior application. See [third-party notices](THIRD_PARTY.md).

## Verification boundary

**Rich messaging has now been exercised in one explicitly authorized self-chat with SIP enabled.** All four text styles, eight text animations, four bubble effects and eight screen effects produced matching outgoing and incoming self-chat payloads with delivered status. Editing, unsending, six standard Tapbacks and their removal, replies, PNG, GIF and video were also exercised. See the [live verification record](docs/RICH_MESSAGING_VERIFICATION.md) for the exact evidence and limits.

The gateway passes 39 local tests, including a compiled Swift worker against an isolated fixture database. Apple app/VM targets remain compile-verified; separate iPhone visual confirmation and broader app/device acceptance remain outstanding. For personal-account testing, [chat-restricted enrollment](docs/CHAT_SCOPES.md) uses a separate worker that queries only explicitly permitted conversations and exposes no general computer tools.

`compiled` is not `device-tested`. Effects use exact Accessibility selectors and need calibration for the worker's macOS version and language. Phone UI automation requires an enrolled physical device, Developer Mode, and a properly signed test runner. Compiling the runner does not prove an installed app's UI selectors. Native read state does not assert that a remote recipient received a read receipt. See [capability and verification details](docs/CAPABILITIES.md).

## Requirements

- Gateway/MCP: Node.js 24 or newer. Remote connections need HTTPS/WSS termination.
- Native worker: dedicated macOS user session or dedicated virtual Mac; Xcode/Swift matching the pinned package. This checkout was built with Xcode 26.6 / Swift 6.3.3.
- Apple app builds: Xcode and XcodeGen. Real-device installation requires your own developer team and signing.
- Virtual Mac: Apple silicon, macOS 15+, a compatible IPSW, sufficient RAM/disk, and the Virtualization entitlement. An 80 GiB sparse guest disk is created per VM.

## Safe local verification

```sh
npm ci
npm run check
npx tsx scripts/fixture-demo.ts
npm run benchmark
npm run native:build
npm run apple:generate
xcodebuild -project apple/MessagePilot.xcodeproj -scheme MessagePilot \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/MessagePilot.xcodeproj -scheme MessagePilotVM \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath work/vm \
  CODE_SIGNING_ALLOWED=NO build
```

None of those commands start the live native bridge. Do not run upstream library CLIs during verification; their onboarding may open Messages or request account access.

## Connect an account

1. Create a dedicated virtual Mac with the `MessagePilotVM` app, or use a dedicated Mac/user session. Sign in to Messages with the **agent's** Apple Account. Apple authentication and 2FA remain in Apple's UI.
2. Install MessagePilot and build the native binary inside that environment. Grant its required Accessibility, Automation, and Messages-data permissions there. Leave SIP enabled.
3. Copy `examples/gateway.json` and `examples/worker.live.json` into untracked local configuration. Give every account worker, device, and agent a different random token of at least 32 characters. Store tokens in environment variables or the account's Keychain; never in Git.
4. Copy `examples/native.json`, set the dedicated OS username, identity, and workspace. Create the workspace and a `.messagepilot-account` file whose sole content is the configured account ID. This is an explicit enrollment step, not an automatic setup side effect.
5. Start the gateway with `npm run gateway -- config.local.json`. Start the worker **inside the dedicated environment** with `npm run worker -- worker.local.json --live`.
6. Verify the reported account and capabilities from an authorized agent. The native adapter compares the expected identity with the local Messages account data at startup; this is not a substitute for confirming Apple's active Send & Receive settings. Do not switch the Apple Account underneath a running worker.

One Apple identity belongs to one isolated OS environment. Running multiple worker processes in a single logged-in desktop does not create separate Apple identities. Each account may also have one separately authenticated phone companion.

The gateway binds to loopback by default. Put it behind your own TLS reverse proxy for remote use, preserve WebSocket upgrades and SSE streaming, and do not log authorization headers. WSS is required for non-loopback worker connections. Keep account workers warm and geographically close to the gateway.

## Agent interface

Run the MCP bridge using the client-specific token and gateway address:

```sh
MESSAGEPILOT_URL=https://your-bridge.example.com \
  node dist/src/cli.js mcp
```

Set `MESSAGEPILOT_AGENT_TOKEN` securely in that process's environment. The MCP server exposes typed tools such as `messages_send`, `messages_react`, `chats_read`, `apps_snapshot`, `apps_interact`, `apps_create`, `apps_build`, `apps_ios_run`, `computer_exec`, and `device_capture`. Tool names and schemas are available through MCP discovery. [Agent contract](docs/AGENT_INTERFACE.md).

Direct HTTP example, with an existing authorized `$MESSAGEPILOT_AGENT_TOKEN`:

```sh
curl https://your-bridge.example.com/v1/accounts/agent-one/commands \
  -H "Authorization: Bearer $MESSAGEPILOT_AGENT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"operation":"messages.send","args":{"chatId":"EXACT_CHAT_ID","text":"Hello"},"idempotencyKey":"unique-send-001"}'
```

Use `GET /v1/accounts/{account}/commands/{id}` for the receipt. Use `GET /v1/accounts/{account}/events?after=0&stream=1` for an SSE stream with replay cursors. Account credentials never travel inside message content.

## Rich messages and developer tools

- Images, GIFs, videos, and files: `messages.send` with a `filePath` inside the worker workspace. Transfer assets and retrieve screenshots with `files.write` / `files.read` in base64 chunks up to 256 KiB. The agent can also prepare assets using its virtual computer. Text containing links uses normal Messages preview behavior; Apple controls final rendering.
- Replies: `messages.send` with `replyTo` set to an observed message ID.
- Native bold, italic, underline and strikethrough: `messages.format`, optionally over a UTF-16 range. Custom font families are not native Messages text styles.
- Text, bubble, and screen effects: `messages.effect`, explicitly enabled after UI selector calibration on the dedicated worker. No injection is performed.
- Cards/carousels: write versioned card data with `bridge_card_put` or `PUT /cards/{id}`; load and send it from the MessagePilot Messages extension. Installed recipients get the interactive layout; other clients get the alternate native message layout. Card URLs carry IDs, not credentials. There is no public web fallback page.
- Stickers: the included extension creates text stickers. Arbitrary sticker UI and third-party iMessage apps can be operated through the enrolled iOS harness; do not mislabel an image attachment as a native sticker.
- Create an app: `apps.create` produces an independent host app + Messages extension with distinct bundle IDs and app groups. Edit its source using the account's computer tools, then `apps.build`.
- Other iMessage apps: observe their actual UI, build a bounded action recipe, and run `apps.ios.run` against a dedicated device. The bridge does not guess private payload formats or claim that sending arbitrary JSON launches another extension. [Device harness guide](docs/APPLE_DEVELOPMENT.md).
- Find My: inspect/operate the allowed Find My app using `apps.snapshot` / `apps.interact` or the device harness. This is user-visible UI automation, not a universal Find My location-query API. Core Location in the phone companion reports only that phone's own location.
- Official MCP Registry: search/inspect server metadata, connect pinned remote servers or explicit local executables, and use tools/resources/prompts through the dedicated worker. `bridge_registry_card` displays selectable Registry results in iMessage. [Registry and control guide](docs/MCP_AND_COMPUTER.md).
- Virtual-computer takeover: claim an exclusive agent lease, inspect apps/screens, send keyboard/pointer input, and release it. The worker operates inside the guest, with account-scoped credentials and foreground-target checks.
- Native Send Later, Polls and GIPHY: named UI recipe compilers plus a generic installed-app harness. Photos, Camera, Audio, Stickers, Digital Touch, Check In, Location, Image Playground and other extensions use observed UI recipes. Availability and selectors require dedicated-device calibration. [iMessage app coverage](docs/IMESSAGE_APPS.md).
- Apple developer tools: typed adapters for Xcode builds, Swift, Simulator, devicectl, result extraction, Instruments, Metal, asset tools and signing, plus framework references for creating richer apps.
- Optional primary app port: pass `primaryPort: true` to `apps.create`, or `--primary-port` to the generator. Includes shared state, WidgetKit, ActivityKit/Dynamic Island, App Intents and an APNs Live Activity route. [Primary app port guide](docs/PRIMARY_APP_PORT.md).
- Optional authentication: native passkey and biometric prompts, an opt-in WebAuthn verifier with single-use challenges and short-lived private-card sessions, and generated Associated Domains configuration. [Authentication guide](docs/AUTHENTICATION.md).
- Native conversation backgrounds: select dynamic/photo backgrounds, use a photo message as a background, or remove the background through calibrated Messages UI recipes. These can affect other conversation participants; inspect the native result.

## Speed and execution

The native Messages process and worker WebSocket stay resident. Messages UI actions are serialized per account. App creation/build/testing has a separate development lane, so a long compiler job does not queue ahead of a message. Phone capture has a separate device connection. Different accounts execute concurrently.

The benchmark reports **loopback request-to-fixture-worker latency with a durable SQLite WAL**, excluding Apple's network, UI automation, LLM inference, and phone test-runner startup. See [local verification](docs/VERIFICATION.md) for recorded results. Xcode UI testing is a development/control path and is considerably heavier than the persistent Mac messaging path; batch UI actions into one recipe.

## Durability and semantics

- Idempotency keys are scoped to an account and fingerprint the operation and arguments.
- A successful API enqueue means `queued`, not sent. Native results and account events provide the next level of evidence.
- An uncertain submitted operation is never blindly retried. On crash/disconnect, it becomes `outcome_unknown`; reconcile against Messages before deciding what to do.
- In full-account mode, native events observed while the worker is connected to the native process are spooled and replayed until gateway acknowledgement. A fully stopped native process cannot capture events. After restart, use chat/history reads to reconcile the missed interval.
- `completed` means the adapter returned successfully; inspect its result. UI action completion, compiler exit codes, message submission, delivery, and recipient read state are distinct.
- Source message text is data. The bridge does not translate an incoming message into a privileged tool command.
- Arbitrary computer execution is intentionally powerful and opt-in. A workspace path check is not an OS sandbox. The dedicated VM is the isolation boundary.

## Repository layout

```text
src/          HTTP/MCP protocol, authorization, SQLite receipts, worker transport
native/       Long-lived Swift adapter and exact-selector Accessibility driver
apple/        iOS host, Messages extension, UI harness, virtual Mac app
scripts/      Fixture demo, benchmark, enrolled-device test runner
examples/     Credential-free account configurations and payloads
tests/        Isolation, recovery, routing, developer-tool and protocol tests
```
