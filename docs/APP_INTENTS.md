# App Intents

App Intents expose MessagePilot-owned actions to Shortcuts, Siri and supported system experiences. They do not grant privileged access to arbitrary Apple or third-party apps. Availability and system presentation depend on OS, device, permissions and deployment configuration. [Apple AppIntent documentation](https://developer.apple.com/documentation/appintents/appintent).

## Implemented intents

| Intent                            | Target            | Behavior                                                                                                                                          |
| --------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Read MessagePilot File            | Primary app       | Authenticated bounded text from a prepared file ID; requires system authentication and gateway file/chat grants.                                  |
| Store MessagePilot File           | Primary app       | Accepts Shortcuts IntentFile and exact chat ID, uploads through file API, returns file ID. 16 MiB intent cap; app picker supports larger uploads. |
| Prepare MessagePilot File Preview | Primary app       | Requests asynchronous conversion; response is request acceptance, not completed preview.                                                          |
| Refresh MessagePilot Surface      | Shared app/widget | Refreshes the configured card-backed surface and reloads widgets.                                                                                 |
| MessagePilot Card Action          | Shared app/widget | Reads current card revision, validates the declared action and posts to the paired bridge.                                                        |

`MessagePilotShortcuts` advertises the three file intents with app-specific phrases. Credentials come from the paired Keychain, never from a spoken parameter. The file intents live in the optional primary app because it can participate in system automation independently of an open Messages extension. Existing surface/card intents remain reusable from widgets and other supported app surfaces.

A shortcut does not acquire an `MSConversation` or satisfy the extension's recent-touch requirement. It can prepare files/state/cards; the user then opens the extension and invokes the direct-send action. Background agent messaging continues through the separately enrolled Mac bridge. Do not label a prepared asset “sent.”

## Extending the port

Add small, typed intents for your own declared operations (for example, save a library asset, perform an authorized card action, prepare a game turn). Keep server authorization, revision checks and idempotency in the bridge. Use AppEntity/AppEnum types when your product has stable entities or finite choices; avoid accepting arbitrary shell commands or untrusted backend URLs as intent parameters. A primary port remains optional for developers who only need an iMessage extension.

The iOS Simulator build confirms these intents compile and produces App Intents metadata. Live Siri discovery, phrase invocation, system authentication and Shortcuts execution on the user's physical phone have not been tested for these additions. They require a properly signed installation and paired HTTPS gateway.
