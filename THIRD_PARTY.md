# Third-party components

MessagePilot has no BlueBubbles dependency.

The Swift worker links **Beeper platform-imessage** (MIT) at commit `fdc5640bfcf936c3d8208bc15411944b7ed9819c`: https://github.com/beeper/platform-imessage/tree/fdc5640bfcf936c3d8208bc15411944b7ed9819c . Its source and license are fetched by Swift Package Manager; preserve its MIT notices when distributing binaries. Transitive Swift dependencies and versions are recorded in `native/Package.resolved`.

The Node bridge uses `@modelcontextprotocol/sdk`, `@simplewebauthn/server`, `ws`, and `zod`; exact versions and dependencies are recorded in `package-lock.json`. Their licenses remain in their installed packages. No third-party Apple Account credentials or proprietary app code are included.

Research references:

- Apple Messages API and send constraints: https://developer.apple.com/documentation/messages/msconversation
- Apple interactive layouts: https://developer.apple.com/documentation/messages/msmessagelivelayout
- Apple macOS formatting/effects UI: https://support.apple.com/guide/messages/icht7316c157/mac
- Apple VM iCloud eligibility: https://developer.apple.com/documentation/virtualization/using-icloud-with-macos-virtual-machines
- Apple RoomPlan: https://developer.apple.com/augmented-reality/roomplan/
- BlueBubbles architectural comparison only: https://docs.bluebubbles.app/server

Apple documents iCloud eligibility for newly created compatible macOS VMs. That does not establish successful iMessage activation for a particular account or guest. That must be confirmed in the dedicated environment.
