import XCTest

/// Simulator acceptance for the vault bubble: line side sends an interactive bubble from the
/// extension; person side taps it, pastes a value, and the bubble updates to Connected.
/// Needs VAULT_LINK (a pending request URL from the reference server, passed to xcodebuild as
/// TEST_RUNNER_VAULT_LINK) and VAULT_SECRET (a dummy value, TEST_RUNNER_VAULT_SECRET).
final class VaultFlowTests: XCTestCase {
  let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
  let extensionID = "dev.messagepilot.vault.messages"

  func snap(_ name: String, tree: Bool = false) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
    if tree {
      let t = XCTAttachment(string: messages.debugDescription)
      t.name = name + "-tree"
      t.lifetime = .keepAlways
      add(t)
    }
  }

  func openConversation() {
    // A popover left open by an earlier run would swallow the first tap.
    let dismiss = messages.otherElements["PopoverDismissRegion"]
    if dismiss.exists { dismiss.tap() }
    if !messages.textFields["messageBodyField"].waitForExistence(timeout: 2) {
      messages.cells.element(boundBy: 0).tap()
      XCTAssertTrue(messages.textFields["messageBodyField"].waitForExistence(timeout: 5))
    }
  }

  func testBubbleFlow() throws {
    let env = ProcessInfo.processInfo.environment
    let link = try XCTUnwrap(env["VAULT_LINK"], "VAULT_LINK missing")
    let secret = try XCTUnwrap(env["VAULT_SECRET"], "VAULT_SECRET missing")
    continueAfterFailure = false
    messages.activate()
    openConversation()
    snap("01-conversation")

    // Line side: open the iMessage app from the add menu, the way MessagePilot does on the Mac.
    messages.buttons["add"].tap()
    XCTAssertTrue(messages.cells.element(boundBy: 0).waitForExistence(timeout: 5))
    let app = messages.cells.matching(NSPredicate(format: "identifier ENDSWITH %@", ":" + extensionID)).firstMatch
    let menu = messages.collectionViews.containing(NSPredicate(format: "label == 'Photos'")).firstMatch
    for _ in 0..<8 where !(app.exists && app.isHittable) {
      let more = messages.cells["More"]
      if more.exists && more.isHittable && !app.exists {
        more.tap()
        continue
      }
      menu.swipeUp(velocity: .slow)
    }
    snap("02-add-menu", tree: true)
    XCTAssertTrue(app.isHittable, "Line Vault is listed in the add menu")
    app.tap()

    let field = messages.textFields["vault.requestLink"]
    XCTAssertTrue(field.waitForExistence(timeout: 8))
    field.tap()
    field.typeText(link)
    snap("03-line-compose")
    messages.buttons["vault.sendRequest"].tap()
    // Messages stages an extension's message in the composer; the sender confirms with Send.
    // MessagePilot presses the same sendButton on the Mac.
    let send = messages.buttons["sendButton"]
    XCTAssertTrue(send.waitForExistence(timeout: 8))
    snap("04-staged")
    send.tap()

    // The interactive bubble lands in the transcript.
    let transcript = messages.collectionViews["TranscriptCollectionView"]
    let bubble = transcript.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS[c] %@", "Connect Lofty API key")).firstMatch
    XCTAssertTrue(bubble.waitForExistence(timeout: 10))
    sleep(1)
    snap("05-bubble-sent", tree: true)

    // Person side: tap the bubble, paste into the secure field, connect.
    bubble.tap()
    let secure = messages.secureTextFields["vault.secret"]
    XCTAssertTrue(secure.waitForExistence(timeout: 10))
    snap("06-person-opens-bubble")
    secure.tap()
    secure.typeText(secret)
    messages.buttons["vault.connect"].tap()
    // The secret is already with the backend at this point. The extension then stages the
    // same-session update; on iOS 26 the person confirms it with Send.
    XCTAssertTrue(send.waitForExistence(timeout: 10))
    snap("07-update-staged")
    send.tap()

    let connected = transcript.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS[c] %@", "Lofty API key connected")).firstMatch
    XCTAssertTrue(connected.waitForExistence(timeout: 15))
    sleep(1)
    snap("08-bubble-connected", tree: true)
  }
}
