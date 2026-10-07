# Apple app and virtual computer tooling

## Create an independent iMessage app

```sh
node dist/src/cli.js app-create /path/in/agent/workspace/MyApp com.yourcompany.myapp
cd /path/in/agent/workspace/MyApp
xcodegen generate
```

The generator copies the host app, companion bridge, Messages extension and shared code, assigns independent bundle IDs/app groups/Keychain service names, and refuses existing destinations. Select your developer team in Xcode before installing on a physical device. The bridge operation `apps.create` runs the same generator in the account worker's configured toolkit.

## Interact with installed iMessage apps

MessagePilot includes a generic XCUITest runner because Messages app extensions are UI surfaces. It uses exact accessibility identifiers/labels observed on the enrolled device. Recipes fail on missing or ambiguous targets. Screenshot/tree attachments are retained in the `.xcresult` bundle.

Build the runner without launching it:

```sh
xcodebuild -project apple/MessagePilot.xcodeproj -scheme MessagePilotHarness \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath work/harness \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

For an actual agent-owned iPhone, build for its device destination with your development team and valid signing. Copy `examples/device-enrollment.json` into an untracked file containing its actual device ID and allowed app bundle IDs. Personal devices must not be enrolled.

Run a recipe only when the device is explicitly enrolled:

```sh
python3 scripts/run-ios.py \
  --xctestrun /agent/workspace/DerivedData/Build/Products/YourBuild.xctestrun \
  --recipe /agent/workspace/recipe.json \
  --device-id YOUR_DEDICATED_DEVICE_ID \
  --enrollment /agent/workspace/device-enrollment.json \
  --result /agent/workspace/results/unique-run.xcresult
```

`--prepare-only` validates enrollment and patches a temporary xctestrun without launching Xcode tests. The temporary file is placed beside the source so `__TESTROOT__` resolution remains correct. The `apps.ios.run` operation exposes this runner through the bridge. Batch multiple operations into a recipe to amortize test-runner startup.

The bridge can operate your own extension and other installed iMessage apps through their observed UI. It does not claim to install App Store apps without Apple's normal installation flow, or to forge another app's opaque message payload.

## Phone pairing and capture

Set the HTTPS gateway URL, account ID and expected identity in the host app. Supply separate agent and device tokens. The agent token authorizes private card reads/actions; the device token authenticates the phone worker. Tokens are stored in shared Keychain access groups, not in the message payload.

Connect the phone bridge while the app is foregrounded. A capture command presents a pending request; the user starts the camera/RoomPlan flow and finishes the scan. Results are sent as account events and buffered until acknowledged. The app disconnects on backgrounding; reconnect explicitly after returning. Apple's extension lifecycle does not keep this phone worker alive indefinitely.

## Virtual Mac

Build/sign the MessagePilotVM target with the Virtualization entitlement. Its Create action accepts a local IPSW and a new destination. It creates a fresh hardware identifier, auxiliary storage, sparse disk, NAT network, and a dedicated `Shared` directory. It never mounts your home directory. A file lock prevents two controllers opening the same VM at once.

Start the guest, complete Apple's setup and account sign-in, verify Messages activation manually, and enroll the guest worker. The VM does not inherit the host Apple Account. Each additional account needs a separately created guest or OS environment. Apple documents iCloud support for compatible new macOS 15+ guests; runtime iMessage activation is an account-specific acceptance check.
