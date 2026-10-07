# Built-in and third-party iMessage surfaces

`imessage_catalog` returns the current built-in catalog and available recipe names. `imessage_recipe` compiles a typed workflow into a native Messages UI recipe without executing it. `imessage_run` compiles and executes the recipe through the enrolled device harness, using the same signing, device enrollment and result-bundle requirements as `apps_ios_run`.

These are native UI control paths. No dedicated device has been tested in this checkout, and the catalog does not mean every feature in every installed app is automatically supported. Apple authentication, purchases, hardware requirements, locale, accessibility exposure, and third-party UI changes still matter. Generic recipes can be extended for an installed app without changing the transport.

## Named native workflows

| Workflow            | Required observed selectors                                            | Values                           |
| ------------------- | ---------------------------------------------------------------------- | -------------------------------- |
| `app.open`          | `conversation`, `add`, `app`                                           | None                             |
| `sendlater.create`  | `conversation`, `add`, `sendLater`, `composer`, `send`                 | `text`; calibrated `dateActions` |
| `sendlater.update`  | `conversation`, `scheduledEdit`, `editTime`                            | Calibrated `dateActions`         |
| `sendlater.sendNow` | `conversation`, `scheduledEdit`, `sendNow`                             | None                             |
| `sendlater.delete`  | `conversation`, `scheduledMessage`, `delete`; optional `confirmDelete` | None                             |
| `polls.create`      | `conversation`, `add`, `polls`, `option1`…`optionN`, `send`            | `options` (2–12)                 |
| `polls.vote`        | `conversation`, `poll`, `choice`                                       | None                             |
| `polls.addOption`   | `conversation`, `poll`, `addOption`, `newOption`, `send`               | `option`                         |
| `giphy.search`      | `conversation`, `add`, `giphy`, `search`                               | `query`                          |
| `giphy.send`        | Above plus `result`, `send`                                            | `query`                          |

`polls.details` uses `conversation`, `poll` (long press) and `pollDetails` to inspect native votes. `scheduledEdit` is the Edit control beside the scheduled date. Include any picker-dismissal/commit action in `dateActions`. Include `confirmDelete` only when the observed UI presents that confirmation.

Each selector is `{ "identifier": "EXACT_OBSERVED_IDENTIFIER_OR_LABEL", "type": "button" }`. The identifier must match exactly one element. Snapshot the device before calibrating the selector table. Templates assume the conversation is reachable from the current Messages screen; use a custom navigation recipe to get to that state. A missing selector fails instead of guessing. If a release uses a different sequence (for example a different scheduled-message context menu), use a `custom` workflow with the observed actions.

Date pickers differ by OS and locale, so `dateActions` contains explicit observed picker/button actions rather than guessing date-wheel order. These flows use **Apple's Send Later**, not a timer maintained by the bridge. Apple's scheduling eligibility and limits apply. Poll recipes use **Apple's Polls app**, not a MessagePilot card that resembles a poll. [Apple Send Later](https://support.apple.com/guide/iphone/schedule-text-messages-to-send-later-iph5ae9a7be6/ios), [Apple Polls](https://support.apple.com/en-ae/guide/iphone/iphde1787df4/ios).

`polls.create` expects the desired choice fields to exist. If adding additional choice rows requires buttons, use a custom recipe. Check the final screenshot and recipient transcript before asserting a native feature succeeded. The runner writes screenshot and accessibility-tree attachments into the result bundle; `apple_tools_run` with `xcresulttool` can export them.

## Other built-in apps and extensions

Conversation backgrounds have named `backgrounds.set`, `backgrounds.fromMessage`, and `backgrounds.remove` recipes. Set uses observed `conversation`, `conversationInfo`, `backgrounds`, `backgroundType` and `done` selectors, with optional `actions` for photo selection, swatches, cropping or Image Playground. From-message uses `conversation`, `photoMessage` (long press), `setAsBackground`, optional edit actions and `done`. Remove uses `conversation`, `conversationInfo`, `backgrounds`, `none`. These operate native Messages backgrounds, not the extension's view background. Apple documents that conversation participants can see and change the shared background; removal also affects the conversation. [Apple backgrounds guide](https://support.apple.com/en-ke/guide/iphone/iph605fa06e4/ios).

Photos, Camera, Audio, Stickers/Memoji/Genmoji, #images, Location, Check In, Digital Touch, Image Playground, Apple Cash and the iMessage App Store use `app.open` plus observed `custom` actions. The harness supports snapshots, screenshots, exact-element taps/double taps/two-finger taps/long presses, text, swipes, date-picker wheels, sliders, pinches, rotations and normalized-coordinate taps/drags. Coordinates must come from a current screenshot. Secure UI and system confirmations may require a person. See [Apple's iMessage app guide](https://support.apple.com/en-ie/guide/iphone/iphf9c9c01d3/ios).

GIPHY, its sticker extension, Tenor's GIF Keyboard, GamePigeon and other installed iMessage extensions use the same harness. GIPHY has named search/send recipes; arbitrary sticker placement and game actions use calibrated drags and custom recipes. Install apps through Apple's normal flow before using them. No popularity ranking or exhaustive third-party test coverage is claimed. [GIPHY's native Messages guide](https://support.giphy.com/hc/en-us/articles/360033083931-How-to-Send-GIFs-Stickers-and-GIPHY-Text-in-iMessage), [Tenor's App Store listing](https://apps.apple.com/us/app/gif-keyboard/id917932200), [GamePigeon](https://www.gamepigeonapp.com/).

## Apple developer tools

`apple_tools_catalog` lists executable adapters and Apple framework documentation. `apple_tools_run` accepts `tool`, literal `arguments`, a workspace `cwd`, and a timeout. Arguments are passed directly, not interpreted by a shell. Tool availability comes from the selected Xcode installation; inspect `--help` in the dedicated worker before issuing version-specific commands.

Included command adapters: `xcodebuild`, `swift`, `swiftc`, `simctl`, `devicectl`, `xcresulttool`, `xctrace`, `metal`, `metallib`, `realitytool`, `actool`, `ibtool`, `plutil`, `sips`, and `codesign`. These cover compilation, installation, launch, simulation, test-result extraction, profiling, asset processing and signing. Other tools remain reachable through `computer_exec`. Explicitly target agent-owned simulator/device IDs; never use an ambiguous `booted` or default personal device.

Framework references cover Messages, ARKit, RealityKit, RoomPlan, App Intents, Image Playground, PhotosUI/AVFoundation, Core Location/MapKit, Vision/Core ML, Metal and game graphics. They are development APIs for the generated apps; listing a framework does not automatically grant its entitlements or expose every API as an RPC. Agents can author source, build, sign and drive those apps using the bridge. [Apple command-line tools](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference).
