# Capability paths

All live Apple operations remain **not device-tested in this build**. Tests use synthetic identities and compile-only Apple targets.

| Feature                                    | Implemented path                                              | What still needs dedicated-device verification                    |
| ------------------------------------------ | ------------------------------------------------------------- | ----------------------------------------------------------------- |
| Text, GIF, image, video, file              | Persistent native send with workspace attachment              | Sending, native GUID, delivered event                             |
| Link preview                               | Normal Messages link send and received message representation | Recipient rendering and preview timing                            |
| Reply                                      | Native quoted message ID                                      | Correct parent in recipient transcript                            |
| Reaction/removal                           | Native SIP-enabled Accessibility adapter                      | Target message and OS-supported reaction                          |
| Edit/unsend                                | Native Messages UI                                            | Eligibility window and remote behavior                            |
| Read/unread                                | Native chat state                                             | Local state; remote read receipts depend on settings              |
| Typing                                     | Native UI operation                                           | Peer visibility, groups and timeout                               |
| Text/bubble/screen effects                 | Exact-selector AX driver, disabled until calibrated           | Every label and final recipient effect                            |
| Carousel/live card                         | Own `MSMessageLiveLayout` extension                           | Device signing, installation, sends, active-view refresh          |
| Text sticker                               | Own `MSSticker` generation/send UI                            | Actual sticker presentation                                       |
| Arbitrary stickers and other iMessage apps | Enrolled XCUITest recipes                                     | App-specific selectors and actions                                |
| Create an iMessage app                     | Independent source/bundle/app-group generator                 | Developer team and provisioning                                   |
| Build/test app tooling                     | Xcode build and enrolled test runner                          | Real-device runner signing                                        |
| AR                                         | Foreground AR camera-pose capture                             | Device support and physical tracking                              |
| Room scan                                  | Foreground RoomPlan with explicit Finish button               | LiDAR device, scan quality, result event                          |
| Phone location                             | Foreground Core Location                                      | Permissions, freshness, accuracy                                  |
| Find My                                    | Allowlisted app snapshot and UI actions                       | Observed visible data; no general account-query API               |
| Virtual computer                           | Native Virtualization app                                     | IPSW install, Apple login, Messages activation, worker enrollment |

## SIP

No code changes SIP, AMFI, library validation, or Messages injection settings. The default adapter uses the system's normal permission model. Some third-party library internals include system interfaces; the intended execution path does not inject a dylib into Messages or require SIP to be disabled. Source support and successful compilation do not prove every operation works on every macOS release.

Apple's published Mac UI supports text effects and bubble/screen effects. MessagePilot drives those controls directly using Accessibility. It refuses ambiguous selectors or overwriting an existing draft. A failed effect sequence may leave its own draft staged; the agent must inspect and reconcile it rather than automatically falling back to a plain send.

## Performance design

A resident Swift process avoids per-message process startup. Persistent WebSockets avoid polling for command dispatch. SQLite WAL with full synchronization preserves command intent before dispatch. Messages are serialized per account because they share a desktop. Development builds use a separate lane. Different accounts and phone workers can execute concurrently.

The database event source still has upstream polling/backstop behavior. A disconnected or suspended iPhone cannot be treated as an always-on worker. UI tests have launch overhead; batch their action sequences. No microsecond iMessage-delivery claims are made.
