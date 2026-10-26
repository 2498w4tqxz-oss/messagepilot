import AppKit
import ApplicationServices
import Foundation
import MessagePilotKit

/// AXUIElement-backed node for the shared Kit finders.
final class LiveAXNode: AXNode {
  let element: AXUIElement
  init(_ element: AXUIElement) { self.element = element }

  func attribute(_ name: String) -> Any? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }
  func childNodes() -> [AXNode] {
    (attribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map(LiveAXNode.init)
  }
  func actionNames() -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
  }
  var parentNode: LiveAXNode? {
    guard let p = attribute(kAXParentAttribute) else { return nil }
    return LiveAXNode(p as! AXUIElement)
  }

  func perform(_ action: String) throws {
    // AppKit menu items can acknowledge AXPress without running the command; AXPick runs it.
    let resolved =
      action == "AXPress" && role == "AXMenuItem" && actionNames().contains("AXPick")
      ? "AXPick" : action
    let status = AXUIElementPerformAction(element, resolved as CFString)
    guard status == .success else {
      throw BridgeFailure("Accessibility action \(resolved) failed (\(status.rawValue))")
    }
  }
  func set(_ name: String, _ value: CFTypeRef) throws {
    let status = AXUIElementSetAttributeValue(element, name as CFString, value)
    guard status == .success else {
      throw BridgeFailure("Accessibility attribute \(name) not settable (\(status.rawValue))")
    }
  }
  func setSelection(_ range: NSRange) throws {
    var cf = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &cf) else { throw BridgeFailure("Bad range") }
    try set(kAXSelectedTextRangeAttribute, value)
  }
  var selection: NSRange? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw)
        == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    var cf = CFRange()
    guard AXValueGetValue(raw as! AXValue, .cfRange, &cf) else { return nil }
    return NSRange(location: cf.location, length: cf.length)
  }
  /// Composer text. Messages exposes an attributed value on recent macOS versions.
  var text: String {
    if let s = attribute(kAXValueAttribute) as? String { return s }
    if let a = attribute(kAXValueAttribute) as? NSAttributedString { return a.string }
    return ""
  }
}

/// Live access to the Messages process, its main window and input.
@MainActor enum MessagesApp {
  static func running() throws -> NSRunningApplication {
    guard AXIsProcessTrusted() else {
      throw BridgeFailure("Accessibility permission is required in the dedicated worker session")
    }
    guard
      let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: MessagesAX.bundleID
      ).first
    else { throw BridgeFailure("Messages is not running") }
    return app
  }
  static func root() throws -> LiveAXNode {
    LiveAXNode(AXUIElementCreateApplication(try running().processIdentifier))
  }
  static func window() throws -> LiveAXNode {
    let windows = (try root().attribute(kAXWindowsAttribute) as? [AXUIElement] ?? []).map(
      LiveAXNode.init)
    let scenes = windows.filter { $0.identifier == "SceneWindow" }
    if scenes.count == 1 { return scenes[0] }
    if scenes.isEmpty, windows.count == 1 { return windows[0] }
    throw BridgeFailure("Expected one Messages window, found \(scenes.count) scene windows")
  }

  static func activate() throws {
    let app = try running()
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
      app.activate(options: [])
      pump(0.25)
    }
  }
  static var isFrontmost: Bool {
    guard let app = try? running() else { return false }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
  }

  /// Keeps Accessibility and workspace notifications flowing while waiting.
  static func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  static func wait<T>(
    _ what: String, timeout: TimeInterval = 3, interval: TimeInterval = 0.05,
    _ probe: () throws -> T?
  ) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: Error?
    repeat {
      do { if let value = try probe() { return value } } catch { lastError = error }
      pump(interval)
    } while Date() < deadline
    if let lastError { throw BridgeFailure("Timed out waiting for \(what): \(lastError)") }
    throw BridgeFailure("Timed out waiting for \(what)")
  }

  /// Posts a key to Messages only while it is frontmost.
  static func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
    guard isFrontmost else {
      throw BridgeFailure(
        "Messages lost focus (foreground: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")); refusing global input"
      )
    }
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
        throw BridgeFailure("Key event unavailable")
      }
      event.flags = flags
      event.post(tap: .cghidEventTap)
      if down { pump(0.03) }
    }
    pump(0.08)
  }
  static let returnKey: CGKeyCode = 36
  static let escapeKey: CGKeyCode = 53

  /// Types text through key events (for fields that ignore AXValue assignment).
  static func type(_ text: String) throws {
    guard isFrontmost else { throw BridgeFailure("Messages lost focus; refusing typing") }
    let units = Array(text.utf16)
    for start in stride(from: 0, to: units.count, by: 16) {
      let chunk = Array(units[start..<min(start + 16, units.count)])
      for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
          throw BridgeFailure("Key event unavailable")
        }
        event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        event.post(tap: .cghidEventTap)
      }
      pump(0.02)
    }
  }

  /// Closes open menus and popovers left by an aborted flow. Never sends anything.
  static func dismissTransientUI() {
    guard let root = try? root() else { return }
    // Menu-bar menus are always present in the tree; only popup menus elsewhere are open.
    for child in root.childNodes() where child.role != "AXMenuBar" {
      for menu in child.descendants(maxDepth: 14, where: { $0.role == "AXMenu" }) {
        try? (menu as? LiveAXNode)?.perform("AXCancel")
      }
    }
    if isFrontmost, (try? window()).flatMap({ w in
      w.first(maxDepth: 6) { $0.role == "AXPopover" || $0.role == "AXSheet" }
    }) != nil {
      try? key(escapeKey)
    }
  }
}
