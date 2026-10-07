# Rich messaging acceptance

MessagePilot was exercised against one explicitly authorized self-chat using the separate `messagepilot-scoped` executable. The test used macOS 27.2 (26B5086k), English Messages, Full Disk Access, Accessibility and Messages Automation. **SIP stayed enabled.** No account-wide watcher, inbox listing, unrelated conversation history or whole-desktop screenshot was used.

## Confirmed native results

| Feature                                                                   | Evidence                                                                                                                                                                         |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bold, italic, underline, strikethrough                                    | All four persisted native attributed-text keys; delivered outgoing messages and matching incoming self-chat copies                                                               |
| Big, Small, Shake, Nod, Explode, Ripple, Bloom, Jitter                    | All eight persisted native text-effect attributes; delivered outgoing messages and matching incoming self-chat copies                                                            |
| Slam, Loud, Gentle, Invisible Ink                                         | All four native expressive-send identifiers; delivered outgoing messages and matching incoming self-chat copies                                                                  |
| Echo, Spotlight, Balloons, Confetti, Love, Lasers, Fireworks, Celebration | All eight native screen-effect identifiers; delivered outgoing messages and matching incoming self-chat copies                                                                   |
| Edit                                                                      | Newly authored test message updated in native storage, positive edit timestamp and native Edited badge                                                                           |
| Unsend                                                                    | Newly authored test message retracted: native text cleared and retracted-part metadata recorded; this OS uses part metadata rather than a nonzero top-level retraction timestamp |
| Love, Like, Dislike, Laugh, Emphasize, Question Tapbacks                  | All six additions and all six removals confirmed through native reaction records                                                                                                 |
| Reply                                                                     | New threaded reply persisted with the intended parent message GUID                                                                                                               |
| PNG, animated GIF, MP4                                                    | Native error zero, sent and delivered flags, completed attachment transfers and received self-chat copies                                                                        |

[Machine-readable evidence](rich-verification.json) records the 24 formatting/effect cases without recipient addresses or native message IDs. Private test receipts remain ignored local files. A command returning successfully was not sufficient for these acceptance claims: native persisted attributes and delivery records were inspected in the permitted chat.

A final follow-up on the retained native path also verified Confetti delivery, PNG delivery, a reply with the intended parent, editing that reply, and its native retraction. The live gateway again rejected a foreign chat, unscoped search and computer execution.

Initial direct-path media attempts failed with Apple's error 34. The corrected path copies only an approved workspace asset into a private temporary staging directory, pumps the native run loop while waiting, and checks actual send state. The successful subsequent deliveries are the media evidence above; the failed attempts are not counted as passes.

The resumed check recovered the native menu and exposed two distinct problems: selection/focus could apply styles to the wrong range, and an extra Escape after selecting a menu command could cancel the compose session. Neither failed attempt counts as accepted. The adapter now reads back the selected UTF-16 range, uses native formatting shortcuts or AppKit menu selection, and verifies the persisted rich payload before returning success. Combined bold and italic over one selected range was delivered with matching incoming attributes.

The recovered sequence recorded 41 successful operations, including all 24 rich cases, a saved edit, a native retraction and six Tapback additions/removals. This was a sequence resumed after fixes, not an uninterrupted reliability or soak test.

A proposed reduction in Accessibility traversal was not retained after the follow-up effects path proved unreliable. The final effect action explicitly selects the native menu command. Scoped operations still exclude sidebar conversation rows and pinned previews. Recipient proof is limited to one command; a display name cannot enroll or authorize a conversation. The UI session must remain exclusive while native commands execute.

A later ordinary send exposed retained reply context. It is excluded from placement acceptance. Explicit navigation and native thread-root validation fixed the issue: a final four-case regression verified an ordinary combined-style send, an explicit reply, an ordinary formatted send after that reply and Confetti, including intended thread state, delivery and incoming self-copies. Those command samples took 10.4, 9.6, 8.4 and 9.3 seconds respectively.

The effects picker can intermittently fail to open. The adapter allows at most two preparation attempts, rechecking the exact recipient and unchanged authored draft before each. It submits Send only once, after confirming the effect preview. This bounded recovery passed the final Confetti check; it is not a soak-test guarantee. No failed send is automatically replayed.

## Scope and safeguards

Account and agent chat allowlists are enforced at the HTTP gateway, command receipt and event endpoints, worker enrollment, and native database queries. Foreign message IDs are rejected before opening UI. Restricted credentials cannot enumerate chats, issue unscoped searches, override UI selectors, use shell/file/computer tools, inspect general apps, connect MCP servers, or access cards/device/passkey endpoints. The unrestricted toolkit is also disabled inside a scoped worker. [Enrollment and boundaries](CHAT_SCOPES.md).

Editing and unsending require an own message within Apple's time window. Edits enforce the five-edit limit. Existing drafts are not silently overwritten. Ambiguous UI targets fail; an uncertain send must be reconciled before retrying. Full Disk Access is broader than this application-level policy; macOS itself does not grant per-chat database access.

## Speed and reproducibility

Observed individual effect commands took approximately 2.6–3.4 seconds from cold native process launch to a persisted outgoing message. This includes process startup and Accessibility work, and is not recipient animation latency. Production workers stay resident. No comparative BlueBubbles benchmark was performed.

The final retained-path follow-up measured approximately 9.9 seconds for Confetti, 13.9 seconds for PNG, 11.6 seconds for a reply after media, 5.4 seconds for edit and 4.0 seconds for unsend. These are individual warm command-to-native-result samples, not a latency distribution or recipient-rendering benchmark. Earlier 3.5–5.3 second text tests used an experimental traversal optimization that was subsequently rolled back; they are not claimed as final-path performance. Native UI execution remains the main performance limitation.

`npm run check` passes 39 local tests, including a compiled scoped Swift worker against a synthetic database. `npm run native:test` passes four additional Swift tests for exact style coverage, combined UTF-16 ranges, effect metadata and inherited reply threads. Both native executables compile. Linux CI skips that one macOS-native fixture test. For an explicitly enrolled self-chat, `scripts/rich-acceptance.ts` is an opt-in repeatable test harness; it sends 26 test messages and performs edit/unsend/Tapback operations. It is never run by CI. Inspect its saved receipts and recipient outcomes before calling a run accepted.

## Remaining limits

- Separate iPhone visual confirmation of animation playback and remote edit/unsend behavior is pending. Incoming self-chat payloads prove transport/persistence, not every recipient's rendering.
- Native text formatting supports Apple's four styles, not arbitrary font families.
- Arbitrary emoji/sticker Tapbacks, native stickers, link-preview appearance, Send Later, Polls, conversation backgrounds, GIPHY and other third-party app workflows have not passed this live test. Their existing device/extension adapters still need enrolled-device acceptance.
- Carousels, iMessage app generation, the optional primary app port, widgets, Dynamic Island, passkeys, biometrics, AR and other device tools retain their separately documented build/fixture status. These results do not promote them to live-tested features.
- Multi-account Apple identity provisioning, VM login/activation, reboot recovery, other OS languages and group-chat UI need separate acceptance. The scoped worker labels local enrollment; it does not independently verify the signed-in Apple sender identity.
- Restricted incoming-message events and history pagination are not implemented. Explicit scoped reads return at most 50 recent messages.

Apple references: [native formatting and effects](https://support.apple.com/en-au/guide/messages/icht7316c157/mac), [editing and unsending](https://support.apple.com/en-ae/guide/messages/ichtd68328c6/mac).
