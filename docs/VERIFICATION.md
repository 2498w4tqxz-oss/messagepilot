# Verification record

Local verification used synthetic identities and temporary bridge databases. No live Apple account, Messages database, personal device, Find My data, or SIP setting was accessed. No virtual machine was installed or booted.

## Executed checks

| Check                           | Result                                | What it establishes                                                                                                                                                                                                                                                                     |
| ------------------------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm run check`                 | Passed: TypeScript build and 20 tests | Auth/account isolation, idempotency, restart/disconnect uncertainty, cancellation, event replay/deduplication, card revision control, device routing, concurrent development lane, app generation, enrolled-device recipe preparation, subprocess transport, and MCP discovery/dispatch |
| `npm run demo`                  | Passed                                | Real HTTP gateway to persistent WebSocket fixture worker and completed synthetic receipt                                                                                                                                                                                                |
| `npm run native:build`          | Release build passed                  | Swift adapter links the pinned native library                                                                                                                                                                                                                                           |
| iOS host and Messages extension | Simulator build passed                | Apple API/type/link compatibility; no simulator was launched                                                                                                                                                                                                                            |
| iOS UI harness                  | Simulator `build-for-testing` passed  | Test runner compiles with host and extension; no UI test was run                                                                                                                                                                                                                        |
| macOS virtual computer          | Build passed                          | Virtualization app compiles; no guest or Apple login was created                                                                                                                                                                                                                        |

Build environment: Apple silicon macOS, Node 26.5.0, Xcode 26.6, Swift 6.3.3. CI runs the TypeScript checks and synthetic demo on Node 24. The lockfiles pin the resolved dependencies.

## Synthetic speed measurement

`npm run benchmark` sends 250 sequential commands, discards 10 warmup samples, and measures HTTP request to dispatch at a persistent WebSocket fixture worker. The gateway persists commands to disk-backed SQLite WAL with full synchronization.

| Metric                |              Measured |
| --------------------- | --------------------: |
| Median dispatch       |              2.325 ms |
| p95 dispatch          |              3.566 ms |
| p99 dispatch          |              4.292 ms |
| Sequential throughput | 268.8 commands/second |

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

Enrollment, Apple Account activation, permission grants, real-device signing, and exact UI-selector calibration require the agent's own environment. Every live feature in [the capability table](CAPABILITIES.md) still needs device acceptance: verify the intended chat/message, native result and events, recipient rendering, and reconnect/reboot recovery with two isolated accounts. Capability reports distinguish `compiled`, `fixture`, and `device-tested`; compilation never promotes an operation to device-tested.

Effects, stickers, other iMessage apps, Find My UI, and device captures depend on the actual installed OS/apps/hardware. The code provides those execution paths and fails when a capability is disabled or unavailable. It does not certify unobserved Apple behavior. A stopped native process also requires history reconciliation for events missed while offline.
