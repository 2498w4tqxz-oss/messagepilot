import Foundation
import XCTest

@testable import MessagePilotKit

final class ReactionTests: XCTestCase {
  func testClassicTapbacksAndAliases() throws {
    XCTAssertEqual(try ReactionRequest.parse("love"), .classic(.love))
    XCTAssertEqual(try ReactionRequest.parse("Heart"), .classic(.love))
    XCTAssertEqual(try ReactionRequest.parse("thumbs_up"), .classic(.like))
    XCTAssertEqual(try ReactionRequest.parse("haha"), .classic(.laugh))
    XCTAssertEqual(try ReactionRequest.parse("!!"), .classic(.emphasize))
    XCTAssertEqual(try ReactionRequest.parse("?"), .classic(.question))
    XCTAssertEqual(ReactionRequest.classic(.love).transportKey, "heart")
    XCTAssertEqual(ReactionRequest.classic(.question).associatedType, 2005)
    XCTAssertEqual(ReactionRequest.Classic.love.actionTitle, "Heart")
    XCTAssertEqual(ReactionRequest.Classic.laugh.pickerIdentifier, "ha")
  }

  func testAnySingleEmojiIsATapback() throws {
    for emoji in ["🔥", "❤️", "❤", "👍🏽", "🏳️‍🌈", "👨‍👩‍👧", "‼️", "🇺🇸", "1️⃣"] {
      XCTAssertEqual(try ReactionRequest.parse(emoji), .emoji(emoji), emoji)
      XCTAssertEqual(try ReactionRequest.parse(emoji).associatedType, 2006)
    }
    // The classic heart Tapback and the ❤️ emoji Tapback are different reactions on macOS 15+.
    XCTAssertNotEqual(try ReactionRequest.parse("❤️"), try ReactionRequest.parse("heart"))
  }

  func testNonEmojiAndMultipleEmojiAreRejected() {
    for bad in ["a", "1", "#", "🔥🔥", "heartt", "", "ok 👍"] {
      XCTAssertThrowsError(try ReactionRequest.parse(bad), bad)
    }
  }

  func row(_ id: Int64, _ type: Int, emoji: String? = nil, me: Bool = true, sender: String? = nil)
    -> ReactionRow
  {
    ReactionRow(
      rowID: id, guid: "R\(id)", type: type, emoji: emoji, fromMe: me, sender: sender, date: nil)
  }

  func testKindsFromAssociatedTypes() {
    XCTAssertEqual(row(1, 2000).kind, .classic)
    XCTAssertEqual(row(1, 2000).classic, .love)
    XCTAssertEqual(row(1, 2006, emoji: "🔥").kind, .emoji)
    XCTAssertEqual(row(1, 2007).kind, .sticker)
    XCTAssertEqual(row(1, 1000).kind, .sticker, "Sticker peeled onto a bubble")
    XCTAssertTrue(row(1, 3006, emoji: "🔥").isRemoval)
    XCTAssertNil(row(1, 0).kind)
    XCTAssertNil(row(1, 4000).kind, "Poll votes are not reactions")
  }

  func testOneTapbackSlotPerSenderAndRemoval() {
    let rows = [
      row(1, 2000),  // I loved it
      row(2, 2006, emoji: "🔥"),  // then switched to an emoji: replaces the heart
      row(3, 2001, me: false, sender: "+15550100100"),
      row(4, 2007),  // sticker is additive
      row(5, 3001, me: false, sender: "+15550100100"),  // they removed their like
    ]
    let current = ReactionState.current(rows)
    XCTAssertEqual(current.map(\.rowID), [2, 4])
    XCTAssertTrue(ReactionState.satisfies(rows, request: .emoji("🔥"), present: true))
    XCTAssertTrue(ReactionState.satisfies(rows, request: .classic(.love), present: false))
    let removed = rows + [row(6, 3006, emoji: "🔥")]
    XCTAssertTrue(ReactionState.satisfies(removed, request: .emoji("🔥"), present: false))
    XCTAssertEqual(ReactionState.current(removed).map(\.rowID), [4])
  }

  func testRemovalOfADifferentEmojiDoesNotClearTheSlot() {
    let rows = [row(1, 2006, emoji: "🔥"), row(2, 3006, emoji: "🎉")]
    XCTAssertTrue(ReactionState.satisfies(rows, request: .emoji("🔥"), present: true))
  }
}
