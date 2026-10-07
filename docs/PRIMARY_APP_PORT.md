# Optional primary app port

The primary app port is **opt-in**. A developer can keep MessagePilot centered entirely on Messages, or use the containing app as a capability host for Apple features that cannot live entirely inside an iMessage extension.

```sh
# Minimal containing app + Messages extension. No widget or device bridge.
node dist/src/cli.js app-create /agent/workspace/ChatApp com.example.chat

# Add the primary app port and its additional extension targets.
node dist/src/cli.js app-create /agent/workspace/FullApp com.example.full --primary-port
```

The equivalent `apps_create` argument is `primaryPort: true`; it defaults to `false`. Both modes generate independent bundle IDs, App Groups and Keychain service names. The repository's complete MessagePilot app includes the port to provide the reference implementation; generated apps choose which mode to include.

| Minimal mode                              | Optional primary app port                       |
| ----------------------------------------- | ----------------------------------------------- |
| Small setup/pairing screen                | Device bridge and setup screen                  |
| Messages extension and shared card client | Everything in minimal mode                      |
| App Group and scoped card credential      | WidgetKit Home Screen widget                    |
| No camera/location/push features          | ActivityKit Lock Screen/Dynamic Island views    |
| No widget target                          | App Intents for card actions and widget refresh |
|                                           | Foreground location, AR and RoomPlan capture    |
|                                           | APNs ActivityKit token registration             |

The containing app need not be the main product interface. Install and pair it, then use Messages, widgets, Live Activities or Shortcuts as appropriate. Apple still requires installation, permissions and lifecycle eligibility. The optional port is not an always-running background daemon.

## Shared surfaces

`device_surface_publish` writes a named surface (`id`, `title`, `detail`, `progress`, optional `cardId`) into the shared App Group while the paired device worker is active. WidgetKit receives a reload request; Apple controls when it renders. `RefreshMessagePilotSurface` is an App Intent that fetches the linked card through the shared credential without opening the app. `MessagePilotCardAction` emits a declared, revision-checked card action for the external agent. Developers can extend these intents and data models for their own product.

The widget and Messages extension read the same account configuration and protected Keychain access group. Credentials are not embedded in messages, shared card URLs, or the widget view. [Apple App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups), [App Intents](https://developer.apple.com/documentation/appintents/appintent).

## Live Activities and Dynamic Island

Publish a surface, then call `device_activity_start` with its ID while the primary app is foregrounded and Live Activities are enabled. `device_activity_list`, `device_activity_update` and `device_activity_end` provide local lifecycle operations through the paired foreground worker. The Widget extension supplies Lock Screen, expanded, compact and minimal Dynamic Island layouts. Device support and system policy determine presentation. [ActivityKit](https://developer.apple.com/documentation/activitykit).

ActivityKit issues activity update tokens and, on supported releases, push-to-start tokens. The app publishes these as account-scoped `device.activity.token` events using a device-authenticated HTTP endpoint during ActivityKit's limited background runtime. Failed token delivery remains buffered for foreground reconnect. `apple_activity_push` sends signed HTTP/2 ActivityKit pushes directly from the worker for `start`, `update` or `end`; it does not depend on the companion WebSocket remaining connected. Initial enrollment and token acquisition still require the installed app. Push-to-start requires `attributesType`, `attributes` and an `alert`. On iOS 18+, set `requestUpdateToken: true` when requesting a fresh update token. Keep the latest token from account events. [Apple's ActivityKit push protocol](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

Configure these secrets **only in the dedicated worker environment**:

```text
MESSAGEPILOT_APNS_KEY_PATH=/private/path/AuthKey.p8
MESSAGEPILOT_APNS_KEY_ID=YOUR_KEY_ID
MESSAGEPILOT_APNS_TEAM_ID=YOUR_TEAM_ID
MESSAGEPILOT_APNS_BUNDLE_ID=com.example.full.app
MESSAGEPILOT_APNS_ENVIRONMENT=sandbox
```

Use `production` for a production entitlement/token. The generated development app requests the `aps-environment: development` entitlement; configure signing and distribution entitlements for the intended release. The bridge never creates or exports a signing key. APNs `accepted: true` establishes provider acceptance, not device rendering. The code does not bypass Apple's Live Activity limits or refresh budgets.

The provided ActivityKit content state is `{ "title": "...", "detail": "...", "progress": 0.5, "updatedAt": 1790000000 }`. Its attributes type is `BridgeActivityAttributes`, with `{ "accountId": "agent-one", "surfaceId": "task-1" }`. Obtain exact tokens from the enrolled app's events. ActivityKit pushes update the Live Activity; they do not automatically refresh the separate Home Screen widget's cached App Group data. Use the widget refresh intent/card fetch for that surface.

All Apple targets are compile-verified only. APNs payload construction and signing are tested locally with ephemeral test keys; no push has been sent and no developer account/device has been enrolled during this build.

## Optional authentication

The primary app port also includes native passkey/biometric adapters. Passkey sign-in remains disabled until the developer configures a relying party and Associated Domains. See [authentication setup](AUTHENTICATION.md). Minimal generated apps contain none of this native authentication UI.
