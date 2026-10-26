import Foundation
import XCTest

@testable import MessagePilotKit

/// Replays Accessibility trees recorded from Messages on macOS 26.6.2 (the DOOR line's virtual
/// Mac, captured read-only with `apps.snapshot`, then sanitized). These prove the selectors match
/// the real UI structure; they do not press anything in a live app.
final class MessagesAXTests: XCTestCase {
  func fixture(_ name: String) throws -> AXFixtureNode {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try AXFixtureNode.load(url)
  }
  func window(_ app: AXFixtureNode) throws -> AXNode {
    try XCTUnwrap(app.childNodes().first { $0.identifier == "SceneWindow" })
  }

  func testComposerInBothObservedLayouts() throws {
    let full = try fixture("messages-26.6.2-full")
    let composer = try MessagesAX.composer(in: try window(full))
    XCTAssertEqual(composer.identifier, "messageBodyField")
    XCTAssertEqual(composer.role, "AXTextField", "macOS 26.6.2 exposes the composer as a text field")
    XCTAssertEqual(composer.label, "Message")

    let reduced = try fixture("messages-26.6.2-reduced")
    let fallback = try MessagesAX.composer(in: try window(reduced))
    XCTAssertEqual(fallback.role, "AXTextArea")
    XCTAssertNil(fallback.identifier, "Reduced layout: no identifier, found beside the add button")
  }

  func testOldEffectSelectorMatchesNothingOnMacOS26() throws {
    // Root cause of "Selector matched 0 elements" when sending Confetti on macOS 26: the old
    // full-worker effect flow looked for a text area described "iMessage" and an "Apps" button.
    for name in ["messages-26.6.2-full", "messages-26.6.2-reduced"] {
      let app = try fixture(name)
      XCTAssertTrue(app.descendants { $0.matches(["AXRole": "AXTextArea", "AXDescription": "iMessage"]) }.isEmpty)
      XCTAssertTrue(app.descendants { $0.matches(["AXDescription": "Apps"]) }.isEmpty)
      XCTAssertEqual(try MessagesAX.addButton(in: try window(app)).label, "add")
    }
  }

  func testEntryButtons() throws {
    let full = try window(try fixture("messages-26.6.2-full"))
    XCTAssertEqual(try MessagesAX.emojiPickerButton(in: full).label, "Emoji picker")
    XCTAssertEqual(try MessagesAX.recordAudioButton(in: full).label, "Record audio")
    let reduced = try window(try fixture("messages-26.6.2-reduced"))
    XCTAssertEqual(try MessagesAX.emojiPickerButton(in: reduced).label, "face.grinning")
  }

  func testBubblesExposeEveryReactionAndMessageAction() throws {
    let w = try window(try fixture("messages-26.6.2-full"))
    let transcript = try XCTUnwrap(MessagesAX.mainTranscript(in: w))
    XCTAssertNil(MessagesAX.overlayTranscript(in: w), "No overlay open in the recording")
    let containers = MessagesAX.messageContainers(in: transcript)
    XCTAssertEqual(containers.count, 16)
    let own = containers.filter(MessagesAX.isOwn)
    XCTAssertEqual(own.count, 11)
    let target = try XCTUnwrap(MessagesAX.actionTarget(containers[0]))
    XCTAssertEqual(target.identifier, "Sticker", "Actions live on the sticker drop target group")
    for classic in ReactionRequest.Classic.allCases {
      XCTAssertNotNil(target.customAction(classic.actionTitle), classic.actionTitle)
    }
    for action: MessagesAX.BubbleAction in [
      .addEmojiTapback, .tapbackDetails, .reply, .attachSticker, .forward, .copy, .delete,
    ] {
      XCTAssertNotNil(target.customAction(action.rawValue), action.rawValue)
    }
    // Recently used emoji Tapbacks are offered directly.
    XCTAssertNotNil(target.customAction("🔥") ?? target.customAction("😂"))
    XCTAssertTrue(target.customAction("Attach Sticker…")!.hasPrefix("Name:Attach Sticker…\n"))
  }

  func testBubbleLookupByTextAndDirection() throws {
    let w = try window(try fixture("messages-26.6.2-full"))
    let transcript = try XCTUnwrap(MessagesAX.mainTranscript(in: w))
    let mine = try MessagesAX.bubble(text: "Fixture message 1", own: true, in: transcript)
    XCTAssertNotNil(mine.customAction("Forward…"))
    XCTAssertThrowsError(try MessagesAX.bubble(text: "Fixture message 1", own: false, in: transcript))
    XCTAssertThrowsError(try MessagesAX.bubble(text: "not in transcript", own: true, in: transcript))
  }

  func testMenuBarCommandsUsedBySendLaterFormatAndDetails() throws {
    let app = try fixture("messages-26.6.2-full")
    let sendLater = try MessagesAX.menuBarCommand("send_later…", in: app)
    XCTAssertEqual(sendLater.title, "Send Later…", "Edit › Send Later… schedules the composed message")
    XCTAssertEqual(try MessagesAX.menuBarCommand("send_later", in: app).title, "Send Later", "View filter is distinct")
    XCTAssertEqual(try MessagesAX.menuBarCommand("show_details", in: app).title, "Show Details")
    XCTAssertEqual(try MessagesAX.menuBarCommand("orderFrontCharacterPalette:", in: app).title, "Emoji & Symbols")
    XCTAssertEqual(try MessagesAX.menuBarCommand("tapback_last_message…", in: app).title, "Tapback Last Message…")
    for style in ["bold", "italic", "underline", "strikethrough"] {
      XCTAssertEqual(try MessagesAX.formatCommand(style, in: app).identifier, style)
    }
    for effect in ["Big", "Small", "Shake", "Nod", "Explode", "Ripple", "Bloom", "Jitter"] {
      XCTAssertEqual(try MessagesAX.formatCommand(effect, in: app).title, effect)
    }
    XCTAssertEqual(try MessagesAX.conversationCommand("delete_conversation…", in: app).title, "Delete Conversation…")
    XCTAssertThrowsError(try MessagesAX.menuBarCommand("no_such_command", in: app))
  }

  func testConversationRowPinActionOnlyOnSelectedRow() throws {
    let w = try window(try fixture("messages-26.6.2-full"))
    XCTAssertNil(MessagesAX.selectedConversationRow(in: w), "Recording has no AXSelected attribute")
    let synthetic = AXFixtureNode(json: [
      "AXRole": "AXWindow",
      "children": [
        [
          "AXIdentifier": "ConversationList",
          "children": [
            [
              "AXRole": "AXStaticText", "AXSelected": false,
              "actions": ["Name:Unpin Someone Else\nTarget:0x0\nSelector:(null)"],
            ],
            [
              "AXRole": "AXStaticText", "AXSelected": true,
              "actions": [
                "AXPress", "Name:Pin +1 (555) 010-0100\nTarget:0x0\nSelector:(null)",
                "Name:Mark as Unread",
              ],
            ],
          ],
        ]
      ],
    ])
    let selected = try XCTUnwrap(MessagesAX.selectedConversationRow(in: synthetic))
    XCTAssertNotNil(MessagesAX.pinAction(selected, pinned: true))
    XCTAssertNil(MessagesAX.pinAction(selected, pinned: false))
  }

  func testPrivateRegionsAreNotTraversedForComposerSearch() throws {
    let w = try window(try fixture("messages-26.6.2-full"))
    let visible = w.descendants(skipIdentifiers: MessagesAX.privateRegions) { _ in true }
    XCTAssertFalse(visible.contains { ($0.label ?? "").contains("Fixture message preview") })
  }

  func testMenuItemsAndEffectButtonLookups() throws {
    let menu = AXFixtureNode(json: [
      "AXRole": "AXMenu",
      "children": [
        ["AXRole": "AXMenuItem", "AXTitle": "Photos", "AXIdentifier": "photos"],
        ["AXRole": "AXMenuItem", "AXTitle": "Message Effects", "AXIdentifier": "message_effects"],
        ["AXRole": "AXMenuItem", "AXTitle": "Send Later", "AXIdentifier": "send_later"],
      ],
    ])
    XCTAssertEqual(MessagesAX.menuItems(in: menu).map(\.title), ["Photos", "Message Effects", "Send Later"])
    XCTAssertEqual(try MessagesAX.menuItem("Message Effects", identifiers: ["message_effects"], in: menu).identifier, "message_effects")
    XCTAssertEqual(try MessagesAX.menuItem("photos", in: menu).title, "Photos")
    let picker = AXFixtureNode(json: [
      "AXRole": "AXGroup",
      "children": [
        ["AXRole": "AXButton", "AXDescription": "Effect: Confetti"],
        ["AXRole": "AXButton", "AXDescription": "Effect: Lasers"],
      ],
    ])
    XCTAssertEqual(try MessagesAX.effectButton("Confetti", in: picker).label, "Effect: Confetti")
    XCTAssertThrowsError(try MessagesAX.effectButton("Spotlight", in: picker)) { error in
      XCTAssertTrue(String(describing: error).contains("Effect: Lasers"), "Failure lists observed labels")
    }
  }
}
