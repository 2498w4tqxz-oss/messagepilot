import XCTest

/// Build-only in CI. Run this test solely on a dedicated agent device, never a personal one.
final class MessagePilotHarness: XCTestCase {
  func testRecipe() throws {
    continueAfterFailure = false
    guard let encoded = ProcessInfo.processInfo.environment["MESSAGEPILOT_RECIPE_BASE64"],
      let data = Data(base64Encoded: encoded),
      let recipe = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let bundle = recipe["bundleId"] as? String,
      let actions = recipe["actions"] as? [[String: Any]], !actions.isEmpty, actions.count <= 100
    else { throw HarnessError.invalidRecipe }
    let app = XCUIApplication(bundleIdentifier: bundle)
    if recipe["launch"] as? Bool == true { app.launch() } else { app.activate() }
    for action in actions {
      guard let kind = action["action"] as? String else { throw HarnessError.invalidRecipe }
      if kind == "snapshot" {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "MessagePilot accessibility tree"
        attachment.lifetime = .keepAlways
        add(attachment)
        continue
      }
      if kind == "screenshot" {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "MessagePilot desktop"
        attachment.lifetime = .keepAlways
        add(attachment)
        continue
      }
      if kind == "tapCoordinate" || kind == "drag" {
        func coordinate(_ x: String, _ y: String) throws -> XCUICoordinate {
          guard let px = action[x] as? Double, let py = action[y] as? Double,
            (0...1).contains(px), (0...1).contains(py)
          else { throw HarnessError.invalidRecipe }
          return app.coordinate(withNormalizedOffset: CGVector(dx: px, dy: py))
        }
        let start = try coordinate("x", "y")
        if kind == "tapCoordinate" {
          start.tap()
        } else {
          start.press(
            forDuration: min(action["seconds"] as? Double ?? 0.1, 3),
            thenDragTo: try coordinate("toX", "toY"))
        }
        continue
      }
      let query: XCUIElementQuery
      switch action["type"] as? String {
      case "button": query = app.buttons
      case "textField": query = app.textFields
      case "textView": query = app.textViews
      case "cell": query = app.cells
      case "staticText": query = app.staticTexts
      case "pickerWheel": query = app.pickerWheels
      case "slider": query = app.sliders
      default: query = app.descendants(matching: .any)
      }
      guard let identifier = action["identifier"] as? String, !identifier.isEmpty else {
        throw HarnessError.invalidRecipe
      }
      let matches = query.matching(identifier: identifier)
      let element = matches.firstMatch
      guard element.waitForExistence(timeout: min(action["timeoutSeconds"] as? Double ?? 5, 30))
      else { throw HarnessError.notFound(identifier) }
      guard matches.count == 1 else { throw HarnessError.ambiguous(identifier) }
      switch kind {
      case "waitFor": break
      case "adjustPicker":
        guard let text = action["text"] as? String else { throw HarnessError.invalidRecipe }
        element.adjust(toPickerWheelValue: text)
      case "setSlider":
        guard let value = action["value"] as? Double, (0...1).contains(value) else {
          throw HarnessError.invalidRecipe
        }
        element.adjust(toNormalizedSliderPosition: CGFloat(value))
      case "pinch":
        guard let scale = action["scale"] as? Double, let velocity = action["velocity"] as? Double
        else { throw HarnessError.invalidRecipe }
        element.pinch(withScale: CGFloat(scale), velocity: CGFloat(velocity))
      case "rotate":
        guard let radians = action["radians"] as? Double,
          let velocity = action["velocity"] as? Double
        else { throw HarnessError.invalidRecipe }
        element.rotate(CGFloat(radians), withVelocity: CGFloat(velocity))
      case "tap": element.tap()
      case "doubleTap": element.doubleTap()
      case "twoFingerTap": element.twoFingerTap()
      case "longPress": element.press(forDuration: min(action["seconds"] as? Double ?? 1, 3))
      case "type":
        guard let text = action["text"] as? String else { throw HarnessError.invalidRecipe }
        element.tap()
        element.typeText(text)
      case "swipeLeft": element.swipeLeft()
      case "swipeRight": element.swipeRight()
      case "swipeUp": element.swipeUp()
      case "swipeDown": element.swipeDown()
      default: throw HarnessError.invalidRecipe
      }
    }
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = "Final accessibility tree"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  enum HarnessError: Error {
    case invalidRecipe
    case notFound(String)
    case ambiguous(String)
  }
}
