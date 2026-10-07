# Verification record

Initial build verification used synthetic identities and temporary bridge databases. Subsequent authorized testing used the separate scoped worker and exactly one self-chat, with SIP enabled. See [rich messaging acceptance](RICH_MESSAGING_VERIFICATION.md) and [expanded acceptance](EXPANDED_ACCEPTANCE.md). No other conversations or Find My data were read. No virtual machine was installed or booted.

## Executed checks

| Check                           | Result                                | What it establishes                                                                                                                                                                                                                                                                     |
| ------------------------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm run check`                 | Passed: TypeScript build and 40 tests | Auth/account isolation, idempotency, restart/disconnect uncertainty, cancellation, event replay/deduplication, card revision control, device routing, concurrent development lane, app generation, enrolled-device recipe preparation, subprocess transport, and MCP discovery/dispatch |
| `npm run demo`                  | Passed                                | Real HTTP gateway to persistent WebSocket fixture worker and completed synthetic receipt                                                                                                                                                                                                |
| `npm run native:build`          | Release build passed                  | Swift adapter links the pinned native library                                                                                                                                                                                                                                           |
| iOS host and Messages extension | Simulator build passed                | Build plus installed simulator host/extension; see expanded acceptance                                                                                                                                                                                                                  |
| iOS UI harness                  | Simulator `build-for-testing` passed  | Enrolled simulator UI tests executed; feature-level results in expanded acceptance                                                                                                                                                                                                      |
| macOS virtual computer          | Build passed                          | Virtualization app compiles; no guest or Apple login was created                                                                                                                                                                                                                        |

Build environment: Apple silicon macOS, Node 26.5.0, Xcode 26.6, Swift 6.3.3. CI runs the TypeScript checks and synthetic demo on Node 24. The lockfiles pin the resolved dependencies.

## Expanded bridge checks

The test suite also exercises exclusive virtual-computer leases, device-authenticated background token ingestion/deduplication, Official Registry URL construction and card conversion, actual MCP stdio and Streamable HTTP connections, explicit environment-secret forwarding, native UI recipe validation, optional primary-port generation, and APNs payload/signature construction with ephemeral keys. The public Official Registry was read successfully. Expanded acceptance contacted the real Context7 Streamable HTTP service, discovered its tools and completed a public `resolve-library-id` query. Legacy SSE uses the SDK transport but was not exercised against a live server.

The iOS host, Messages extension, WidgetKit/ActivityKit extension, App Intents and UI harness pass a simulator build-for-testing. Separately generated minimal and primary-port applications also compiled with distinct bundle IDs. Expanded acceptance launched an isolated, unsigned-in simulator and exercised the installed host, Messages extension and device bridge. No APNs notification was sent, and no developer identity or private key was read.

Passkey tests construct ephemeral ES256 authenticators and verify registration and assertion signatures through the real gateway/verifier. They reject wrong origins, relying-party hashes, missing user verification, expired/replayed challenges and cross-account access, and verify credential revocation and card-only sessions. A simulator biometric command returned the expected not-enrolled error; real Apple passkey and biometric success remain unverified.

## Chat-restricted acceptance

Seven additional tests cover account/agent chat intersections, empty grants, exact recipient enrollment, cross-chat reads and mutations, filtered SSE history/live delivery, restricted endpoints, worker scope matching, rich schemas, and a compiled scoped worker against a synthetic Messages database. All 40 pass locally. Linux CI skips the one compiled macOS-native fixture test. Both native executable products build successfully. The native live test is explicitly opt-in and never part of CI.

`npm run native:test` additionally passes four pure Swift payload tests covering incomplete style ranges, combined UTF-16 formatting, missing/wrong effect identifiers and unintended reply-thread inheritance. These tests do not open Messages.

## Synthetic speed measurement

`npm run benchmark` sends 250 sequential commands, discards 10 warmup samples, and measures HTTP request to dispatch at a persistent WebSocket fixture worker. The gateway persists commands to disk-backed SQLite WAL with full synchronization.

| Metric                |              Measured |
| --------------------- | --------------------: |
| Median dispatch       |              2.547 ms |
| p95 dispatch          |              3.945 ms |
| p99 dispatch          |              7.608 ms |
| Sequential throughput | 249.3 commands/second |

These 240 local samples measure bridge overhead. They exclude Apple UI execution, Apple network delivery, recipient rendering, model latency, device test-runner startup, TLS, and remote network transit. They are not end-to-end iMessage latency or capacity guarantees. Run the included benchmark on the intended gateway hardware.

## Apple build commands

After `npm run apple:generate`:

```sh
xcodebuild -project apple/MessagePilot.xcodeproj -scheme MessagePilot \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/MessagePilot.xcodeproj -scheme MessagePilotHarness \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/harness CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project apple/MessagePilot.xcodeproj -scheme MessagePilotVM \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath work/vm \
  CODE_SIGNING_ALLOWED=NO build
```

## Remaining acceptance work on dedicated accounts

Enrollment, Apple Account activation, permission grants, real-device signing, and exact UI-selector calibration require the agent's own environment. Features outside the tested subset in [the capability table](CAPABILITIES.md) still need device acceptance: verify the intended chat/message, native result and events, recipient rendering, and reconnect/reboot recovery with two isolated accounts. Capability reports distinguish `compiled`, `fixture`, and `device-tested`; compilation never promotes an operation to device-tested.

Effects, stickers, other iMessage apps, Find My UI, and device captures depend on the actual installed OS/apps/hardware. The code provides those execution paths and fails when a capability is disabled or unavailable. It does not certify unobserved Apple behavior. A stopped native process also requires history reconciliation for events missed while offline.
