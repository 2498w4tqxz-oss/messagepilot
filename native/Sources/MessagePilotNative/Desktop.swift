import AppKit
import ApplicationServices
import Foundation

/// Explicit, account-local Accessibility operations. Selectors match exact observed attributes.
/// No coordinate guesses, global keyboard scripting, injected dylibs, or SIP changes.
@MainActor final class Desktop {
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
