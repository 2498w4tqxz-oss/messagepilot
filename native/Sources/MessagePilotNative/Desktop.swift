import AppKit
import ApplicationServices
import Foundation

/// Explicit, account-local Accessibility operations. Selectors match exact observed attributes.
/// Coordinates must come from the dedicated computer's current screenshot.
@MainActor final class Desktop {
  func applications() -> [[String: Any]] {
    NSWorkspace.shared.runningApplications.compactMap { app in
      guard let bundle = app.bundleIdentifier else { return nil }
      return [
        "bundleId": bundle, "name": app.localizedName ?? bundle, "pid": app.processIdentifier,
        "active": app.isActive,
      ]
    }
  }
  func input(bundle: String, actions: [[String: Any]]) async throws -> [String: Any] {
    _ = try root(bundle)
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
      !actions.isEmpty, actions.count <= 100
    else { throw BridgeFailure("Running app and 1–100 actions required") }
    func point(_ a: [String: Any], _ x: String = "x", _ y: String = "y") throws -> CGPoint {
      guard let px = a[x] as? Double, let py = a[y] as? Double, px.isFinite, py.isFinite else {
        throw BridgeFailure("Observed screen coordinates required")
      }
      let p = CGPoint(x: px, y: py)
      var displays = [CGDirectDisplayID](repeating: 0, count: 16)
      var count: UInt32 = 0
      CGGetActiveDisplayList(16, &displays, &count)
      guard displays.prefix(Int(count)).contains(where: { CGDisplayBounds($0).contains(p) }) else {
        throw BridgeFailure("Point is outside the worker displays")
      }
      return p
    }
    func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, _ clicks: Int64 = 1)
      throws
    {
      guard
        let e = CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
      else { throw BridgeFailure("Cannot create pointer event") }
      e.setIntegerValueField(.mouseEventClickState, value: clicks)
      e.post(tap: .cghidEventTap)
    }
    for a in actions {
      let kind = try required(a, "action")
      if kind == "activate" {
        guard app.activate(options: [.activateIgnoringOtherApps]) else {
          throw BridgeFailure("Cannot activate target app")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        continue
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
      else { throw BridgeFailure("Target app lost focus; refusing global input") }
      switch kind {
      case "move": try mouse(.mouseMoved, point(a), .left)
      case "click":
        let p = try point(a)
        let right = a["button"] as? String == "right"
        for click in 1...min(max(a["clicks"] as? Int ?? 1, 1), 2) {
          try mouse(
            right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left, Int64(click))
          try mouse(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left, Int64(click))
        }
      case "drag":
        let start = try point(a)
        let end = try point(a, "toX", "toY")
        try mouse(.leftMouseDown, start, .left)
        defer { try? mouse(.leftMouseUp, end, .left) }
        for step in 1...12 {
          guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
          else { throw BridgeFailure("Target app lost focus") }
          let t = Double(step) / 12
          try mouse(
            .leftMouseDragged,
            CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), .left)
          try await Task.sleep(nanoseconds: 15_000_000)
        }
      case "scroll":
        guard
          let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32(a["deltaY"] as? Int ?? 0), wheel2: Int32(a["deltaX"] as? Int ?? 0),
            wheel3: 0)
        else { throw BridgeFailure("Cannot create scroll event") }
        event.post(tap: .cghidEventTap)
      case "key", "text":
        guard kind != "key" || a["keyCode"] as? Int != nil else {
          throw BridgeFailure("keyCode required")
        }
        let code = a["keyCode"] as? Int ?? 0
        guard (0...127).contains(code),
          let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)
        else { throw BridgeFailure("Invalid key code") }
        if kind == "text" {
          let text = try required(a, "text")
          guard text.utf16.count <= 10000 else { throw BridgeFailure("Text input is too long") }
          for slice in stride(from: 0, to: Array(text.utf16).count, by: 20) {
            let chunk = Array(Array(text.utf16).dropFirst(slice).prefix(20))
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
          }
        } else {
          var flags: CGEventFlags = []
          for modifier in a["modifiers"] as? [String] ?? [] {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default: throw BridgeFailure("Unknown modifier")
            }
          }
          down.flags = flags
          up.flags = flags
          down.post(tap: .cghidEventTap)
          up.post(tap: .cghidEventTap)
        }
      default: throw BridgeFailure("Unsupported computer input")
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    return [
      "receipt": "input-posted", "actions": actions.count, "bundleId": bundle,
      "verification": "inspect-next-screenshot",
    ]
  }
  private var nodes: [String: AXUIElement] = [:]
  private var snapshotBundle: String?
  private func attribute(_ e: AXUIElement, _ key: String) -> Any? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success else { return nil }
    return value
  }
  private func root(_ bundle: String) throws -> AXUIElement {
    guard AXIsProcessTrusted() else {
      throw BridgeFailure("Accessibility permission is required in the dedicated worker session")
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    else { throw BridgeFailure("Application is not running: \(bundle)") }
    return AXUIElementCreateApplication(app.processIdentifier)
  }
  func snapshot(bundle: String, maxDepth: Int) throws -> [String: Any] {
    nodes.removeAll()
    snapshotBundle = bundle
    var count = 0
    func walk(_ e: AXUIElement, _ depth: Int) -> [String: Any] {
      count += 1
      let id = "n\(count)"
      nodes[id] = e
      var row: [String: Any] = ["id": id]
      for key in [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute,
        kAXValueAttribute, kAXEnabledAttribute,
      ] {
        if let value = attribute(e, key), value is String || value is NSNumber { row[key] = value }
      }
      var actions: CFArray?
      if AXUIElementCopyActionNames(e, &actions) == .success {
        row["actions"] = actions as? [String] ?? []
      }
      if depth < maxDepth, count < 2000 {
        row["children"] = (attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(200)
          .map { walk($0, depth + 1) }
      }
      return row
    }
    return [
      "bundleId": bundle, "tree": walk(try root(bundle), 0),
      "scope": "IDs valid until next snapshot",
    ]
  }
  private func match(_ e: AXUIElement, selector: [String: String], depth: Int = 0) -> [AXUIElement]
  {
    guard depth < 18 else { return [] }
    var result: [AXUIElement] = []
    if !selector.isEmpty, selector.allSatisfy({ (attribute(e, $0.key) as? String) == $0.value }) {
      result.append(e)
    }
    for c in (attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(250) {
      result += match(c, selector: selector, depth: depth + 1)
      if result.count > 20 { break }
    }
    return result
  }
  private func find(bundle: String, action: [String: Any]) throws -> AXUIElement {
    if let id = action["id"] as? String, snapshotBundle == bundle, let node = nodes[id] {
      return node
    }
    guard let selector = action["selector"] as? [String: String], !selector.isEmpty else {
      throw BridgeFailure("An observed node id or exact AX selector is required")
    }
    let found = match(try root(bundle), selector: selector)
    guard found.count == 1 else {
      throw BridgeFailure("Selector matched \(found.count) elements; refusing ambiguous UI action")
    }
    return found[0]
  }
  func interact(bundle: String, actions: [[String: Any]]) async throws -> [String: Any] {
    guard !actions.isEmpty, actions.count <= 40 else {
      throw BridgeFailure("Between 1 and 40 actions required")
    }
    for action in actions {
      let kind = try required(action, "action")
      if kind == "waitFor" {
        let deadline = Date().addingTimeInterval(min(action["timeoutSeconds"] as? Double ?? 3, 10))
        var found = false
        repeat {
          if (try? find(bundle: bundle, action: action)) != nil {
            found = true
            break
          }
          try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        if !found { throw BridgeFailure("Timed out waiting for exact AX element") }
        continue
      }
      let node = try find(bundle: bundle, action: action)
      let status: AXError
      switch kind {
      case "press": status = AXUIElementPerformAction(node, kAXPressAction as CFString)
      case "showMenu": status = AXUIElementPerformAction(node, kAXShowMenuAction as CFString)
      case "setValue":
        status = AXUIElementSetAttributeValue(
          node, kAXValueAttribute as CFString, try required(action, "value") as CFString)
      case "focus":
        status = AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      default: throw BridgeFailure("Unsupported AX action: \(kind)")
      }
      guard status == .success else {
        throw BridgeFailure("AX operation failed: \(status.rawValue)")
      }
    }
    return ["receipt": "ui-actions-completed", "count": actions.count, "delivery": "not-asserted"]
  }
  func sendFormatted(text: String, styles: [String], range: [String: Int]?) async throws -> [String:
    Any]
  {
    let bundle = "com.apple.MobileSMS"
    let composer = try find(
      bundle: bundle, action: ["selector": [kAXIdentifierAttribute: "messageBodyField"]])
    guard (attribute(composer, kAXValueAttribute) as? String ?? "").isEmpty else {
      throw BridgeFailure("Composer has a draft")
    }
    let labels = [
      "bold": "Bold", "italic": "Italic", "underline": "Underline",
      "strikethrough": "Strikethrough",
    ]
    guard !styles.isEmpty, styles.allSatisfy({ labels[$0] != nil }) else {
      throw BridgeFailure("Unsupported native text style")
    }
    var selected = CFRange(
      location: range?["start"] ?? 0, length: range?["length"] ?? (text as NSString).length)
    guard selected.location >= 0, selected.length > 0,
      selected.location + selected.length <= (text as NSString).length
    else { throw BridgeFailure("Invalid formatting range") }
    guard
      AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, text as CFString)
        == .success,
      let value = AXValueCreate(.cfRange, &selected),
      AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, value)
        == .success
    else { throw BridgeFailure("Cannot author/select text") }
    for style in styles {
      _ = try await interact(
        bundle: bundle,
        actions: [
          [
            "action": "press",
            "selector": [kAXRoleAttribute: kAXMenuItemRole, kAXTitleAttribute: labels[style]!],
          ]
        ])
      let menu = try find(
        bundle: bundle,
        action: ["selector": [kAXRoleAttribute: kAXMenuBarItemRole, kAXTitleAttribute: "Format"]])
      guard AXUIElementPerformAction(menu, "AXCancel" as CFString) == .success else {
        throw BridgeFailure("Format menu did not release input")
      }
    }
    _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    return try await input(
      bundle: bundle, actions: [["action": "activate"], ["action": "key", "keyCode": 36]])
  }
  func sendEffect(text: String, effect: String, kind: String, selectors: [String: String])
    async throws -> [String: Any]
  {
    let bundle = "com.apple.MobileSMS"
    let composer: [String: String] = [
      kAXRoleAttribute: kAXTextAreaRole,
      kAXDescriptionAttribute: selectors["composer"] ?? "iMessage",
    ]
    let node = try find(bundle: bundle, action: ["selector": composer])
    let existing = attribute(node, kAXValueAttribute) as? String ?? ""
    guard existing.isEmpty else {
      throw BridgeFailure("Composer has a draft; refusing to overwrite it")
    }
    _ = try await interact(
      bundle: bundle,
      actions: [
        ["action": "setValue", "selector": composer, "value": text],
        ["action": "focus", "selector": composer],
      ])
    if kind == "text" {
      // Select the entire freshly authored string, then use the native Format menu.
      var range = CFRange(location: 0, length: (text as NSString).length)
      guard let value = AXValueCreate(.cfRange, &range),
        AXUIElementSetAttributeValue(node, kAXSelectedTextRangeAttribute as CFString, value)
          == .success
      else { throw BridgeFailure("Cannot select text for animation") }
      _ = try await interact(
        bundle: bundle,
        actions: [
          [
            "action": "press",
            "selector": [
              kAXRoleAttribute: kAXMenuBarItemRole,
              kAXTitleAttribute: selectors["format"] ?? "Format",
            ],
          ]
        ])
    } else {
      _ = try await interact(
        bundle: bundle,
        actions: [
          ["action": "press", "selector": [kAXDescriptionAttribute: selectors["apps"] ?? "Apps"]],
          [
            "action": "waitFor",
            "selector": [kAXTitleAttribute: selectors["effects"] ?? "Message Effects"],
          ],
          [
            "action": "press",
            "selector": [kAXTitleAttribute: selectors["effects"] ?? "Message Effects"],
          ],
        ])
    }
    _ = try await interact(
      bundle: bundle,
      actions: [
        ["action": "waitFor", "selector": [kAXTitleAttribute: effect]],
        ["action": "press", "selector": [kAXTitleAttribute: effect]],
      ])
    // Press an exact Send button rather than posting Return to a potentially different app.
    return try await interact(
      bundle: bundle,
      actions: [
        [
          "action": "press",
          "selector": [
            kAXRoleAttribute: kAXButtonRole, kAXDescriptionAttribute: selectors["send"] ?? "Send",
          ],
        ]
      ])
  }
}
