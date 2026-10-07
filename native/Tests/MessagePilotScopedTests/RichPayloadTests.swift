import Foundation
import XCTest

@testable import MessagePilotScoped

final class RichPayloadTests: XCTestCase {
  func testOrdinarySendMustNotInheritReplyThread() {
    XCTAssertFalse(
      RichPayload.matchesThread(["thread_originator_guid": "previous-parent"], expected: nil))
    XCTAssertTrue(RichPayload.matchesThread(["thread_originator_guid": NSNull()], expected: nil))
    XCTAssertTrue(
      RichPayload.matchesThread(["thread_originator_guid": "parent"], expected: "parent"))
    XCTAssertFalse(
      RichPayload.matchesThread(["thread_originator_guid": "other-parent"], expected: "parent"))
  }
  func testCoverageRejectsHolesAndMissingStyles() {
    let key = RichPayload.styleKeys["bold"]!
    let runs: [[String: Any]] = [
      ["start": 0, "length": 2, "attributes": [key: "1"]],
      ["start": 3, "length": 2, "attributes": [key: "1"]],
    ]
    XCTAssertFalse(
      RichPayload.covers(runs, range: NSRange(location: 0, length: 5), key: key, value: "1"))
    XCTAssertTrue(
      RichPayload.covers(runs, range: NSRange(location: 3, length: 2), key: key, value: "1"))
    XCTAssertFalse(
      RichPayload.covers(
        runs, range: NSRange(location: 3, length: 2), key: RichPayload.styleKeys["italic"]!,
        value: "1"))
  }
  func testCombinedStylesUseUTF16Range() {
    let text = "👋 hello"
    let request: [String: Any] = [
      "text": text, "styles": ["bold", "italic"], "range": ["start": 3, "length": 5],
    ]
    let attrs = [RichPayload.styleKeys["bold"]!: "1", RichPayload.styleKeys["italic"]!: "1"]
    let message: [String: Any] = [
      "text": text, "attributeRuns": [["start": 3, "length": 5, "attributes": attrs]],
    ]
    XCTAssertTrue(RichPayload.matches(message, request: request, formatting: true, effect: false))
    let extra: [String: Any] = [
      "text": text, "attributeRuns": [["start": 0, "length": 8, "attributes": attrs]],
    ]
    XCTAssertFalse(RichPayload.matches(extra, request: request, formatting: true, effect: false))
    XCTAssertFalse(
      RichPayload.matches(
        message, request: ["text": text, "styles": ["bold"]], formatting: true, effect: false))
  }
  func testEffectsNeedMatchingNativeMetadata() {
    let request: [String: Any] = ["text": "test", "kind": "screen", "effect": "Confetti"]
    XCTAssertFalse(
      RichPayload.matches(["text": "test"], request: request, formatting: false, effect: true))
    XCTAssertTrue(
      RichPayload.matches(
        ["text": "test", "expressive_send_style_id": RichPayload.expressive["Confetti"]!],
        request: request, formatting: false, effect: true))
    XCTAssertFalse(
      RichPayload.matches(
        ["text": "test", "expressive_send_style_id": RichPayload.expressive["Love"]!],
        request: request, formatting: false, effect: true))
  }
}
