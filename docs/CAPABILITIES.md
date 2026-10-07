# Capability paths

All live Apple operations remain **not device-tested in this build**. Tests use synthetic identities and compile-only Apple targets.

| Feature                                    | Implemented path                                                     | What still needs dedicated-device verification                                                |
| ------------------------------------------ | -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Text, GIF, image, video, file              | Persistent native send with workspace attachment                     | Sending, native GUID, delivered event                                                         |
| Link preview                               | Normal Messages link send and received message representation        | Recipient rendering and preview timing                                                        |
| Reply                                      | Native quoted message ID                                             | Correct parent in recipient transcript                                                        |
| Reaction/removal                           | Native SIP-enabled Accessibility adapter                             | Target message and OS-supported reaction                                                      |
| Edit/unsend                                | Native Messages UI                                                   | Eligibility window and remote behavior                                                        |
| Read/unread                                | Native chat state                                                    | Local state; remote read receipts depend on settings                                          |
| Typing                                     | Native UI operation                                                  | Peer visibility, groups and timeout                                                           |
| Text/bubble/screen effects                 | Exact-selector AX driver, disabled until calibrated                  | Every label and final recipient effect                                                        |
| Carousel/live card                         | Own `MSMessageLiveLayout` extension                                  | Device signing, installation, sends, active-view refresh                                      |
| Text sticker                               | Own `MSSticker` generation/send UI                                   | Actual sticker presentation                                                                   |
| Arbitrary stickers and other iMessage apps | Enrolled XCUITest recipes                                            | App-specific selectors and actions                                                            |
| Create an iMessage app                     | Independent source/bundle/app-group generator                        | Developer team and provisioning                                                               |
| Build/test app tooling                     | Xcode build and enrolled test runner                                 | Real-device runner signing                                                                    |
| AR                                         | Foreground AR camera-pose capture                                    | Device support and physical tracking                                                          |
| Room scan                                  | Foreground RoomPlan with explicit Finish button                      | LiDAR device, scan quality, result event                                                      |
| Phone location                             | Foreground Core Location                                             | Permissions, freshness, accuracy                                                              |
| Find My                                    | Allowlisted app snapshot and UI actions                              | Observed visible data; no general account-query API                                           |
| Virtual computer                           | Native Virtualization app                                            | IPSW install, Apple login, Messages activation, worker enrollment                             |
| Virtual-computer takeover                  | Agent control leases plus keyboard, pointer, screenshot and AX tools | Guest enrollment, permissions, target focus and observed coordinates                          |
| Official MCP Registry                      | Search/version API, iMessage registry cards                          | Card rendering on enrolled device; public API read verified                                   |
| Connected MCP servers                      | Persistent stdio, Streamable HTTP and legacy SSE clients             | Stdio/HTTP fixtures tested; each real server needs credentials and acceptance                 |
| Native Send Later, Polls, GIPHY            | Named recipes with observed selector tables                          | OS-specific sequence, native scheduled state/poll/GIF and recipient outcome                   |
| Other built-in/installed iMessage apps     | Generic enrolled UI actions, gestures and snapshots                  | App installation, accessibility and hardware/authentication restrictions                      |
| Optional primary app port                  | Opt-in generated host capabilities and shared state                  | Entitlements, pairing and installation                                                        |
| Widgets / Dynamic Island / Live Activities | WidgetKit, ActivityKit, App Intents and HTTP/2 APNs adapter          | Real device presentation, tokens and push delivery                                            |
| Conversation backgrounds                   | Native UI recipes for selection, photo messages and removal          | Shared participant outcome and OS-specific selectors                                          |
| Optional passkeys / biometrics             | AuthenticationServices, LocalAuthentication and WebAuthn verifier    | Signed associated-domain entitlement, real-device prompts; cryptographic server fixtures pass |

## SIP

No code changes SIP, AMFI, library validation, or Messages injection settings. The default adapter uses the system's normal permission model. Some third-party library internals include system interfaces; the intended execution path does not inject a dylib into Messages or require SIP to be disabled. Source support and successful compilation do not prove every operation works on every macOS release.

Apple's published Mac UI supports text effects and bubble/screen effects. MessagePilot drives those controls directly using Accessibility. It refuses ambiguous selectors or overwriting an existing draft. A failed effect sequence may leave its own draft staged; the agent must inspect and reconcile it rather than automatically falling back to a plain send.

## Performance design

A resident Swift process avoids per-message process startup. Persistent WebSockets avoid polling for command dispatch. SQLite WAL with full synchronization preserves command intent before dispatch. Messages are serialized per account because they share a desktop. Development builds use a separate lane. Different accounts and phone workers can execute concurrently.

The database event source still has upstream polling/backstop behavior. A disconnected or suspended iPhone cannot be treated as an always-on worker. UI tests have launch overhead; batch their action sequences. No microsecond iMessage-delivery claims are made.
