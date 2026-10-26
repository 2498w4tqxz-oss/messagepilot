import Foundation

/// Minimal Accessibility element surface. The live worker wraps AXUIElement; tests replay trees
/// recorded from a real macOS 26 Messages session (`apps.snapshot` output).
public protocol AXNode: AnyObject {
  func attribute(_ name: String) -> Any?
  func childNodes() -> [AXNode]
  func actionNames() -> [String]
}

extension AXNode {
  public func string(_ name: String) -> String? { attribute(name) as? String }
  public var role: String? { string("AXRole") }
  public var identifier: String? { string("AXIdentifier") }
  public var title: String? { string("AXTitle") }
  public var label: String? { string("AXDescription") }
  public var value: String? { string("AXValue") }
  public var enabled: Bool { (attribute("AXEnabled") as? Bool) ?? true }

  /// Action names without the "\nTarget:…\nSelector:…" suffix AppKit appends to custom actions.
  public var shortActionNames: [String] {
    actionNames().map { String($0.split(separator: "\n", maxSplits: 1).first ?? "") }
  }

  /// The full action name for a custom action titled `title` (e.g. "Attach Sticker…").
  public func customAction(_ title: String) -> String? {
    actionNames().first { $0 == "Name:" + title || $0.hasPrefix("Name:" + title + "\n") }
  }

  /// Exact-attribute match, the same rule `apps.interact` selectors use.
  public func matches(_ selector: [String: String]) -> Bool {
    !selector.isEmpty && selector.allSatisfy { string($0.key) == $0.value }
  }

  /// Depth-first search; never descends into the conversation list so other chats stay unread.
  public func descendants(
    maxDepth: Int = 18, skipIdentifiers: Set<String> = [], where predicate: (AXNode) -> Bool
  ) -> [AXNode] {
    var out: [AXNode] = []
    func walk(_ node: AXNode, _ depth: Int) {
      guard depth <= maxDepth, out.count < 400 else { return }
      if predicate(node) { out.append(node) }
      if let id = node.identifier, skipIdentifiers.contains(id) { return }
      for child in node.childNodes().prefix(300) { walk(child, depth + 1) }
    }
    walk(self, 0)
    return out
  }

  public func first(maxDepth: Int = 18, where predicate: (AXNode) -> Bool) -> AXNode? {
    descendants(maxDepth: maxDepth, where: predicate).first
  }

  public func summary() -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, name) in [
      ("role", "AXRole"), ("identifier", "AXIdentifier"), ("title", "AXTitle"),
      ("description", "AXDescription"),
    ] {
      if let v = string(name) { out[key] = v }
    }
    return out
  }
}

public enum AXLookup {
  public struct Ambiguity: Error, CustomStringConvertible {
    public let what: String
    public let count: Int
    public let observed: [String]
    public var description: String {
      "\(what): expected exactly one element, found \(count)"
        + (observed.isEmpty ? "" : "; observed: \(observed.prefix(30).joined(separator: " | "))")
    }
  }

  public static func unique(
    _ what: String, in root: AXNode, skip: Set<String> = MessagesAX.privateRegions,
    observe: ((AXNode) -> String?)? = nil, where predicate: (AXNode) -> Bool
  ) throws -> AXNode {
    let found = root.descendants(skipIdentifiers: skip, where: predicate)
    guard found.count == 1 else {
      let observed =
        observe.map { f in root.descendants(skipIdentifiers: skip, where: { _ in true }).compactMap(f) }
        ?? []
      throw Ambiguity(what: what, count: found.count, observed: observed)
    }
    return found[0]
  }
}

/// A recorded tree node (the JSON shape `apps.snapshot` returns).
public final class AXFixtureNode: AXNode {
  public let attributes: [String: Any]
  public let children: [AXFixtureNode]
  public let actions: [String]
  public weak var parent: AXFixtureNode?
  public private(set) var performed: [String] = []

  public init(json: [String: Any]) {
    var attrs = json
    attrs.removeValue(forKey: "children")
    attrs.removeValue(forKey: "actions")
    attributes = attrs
    actions = json["actions"] as? [String] ?? []
    children = (json["children"] as? [[String: Any]] ?? []).map(AXFixtureNode.init(json:))
    for child in children { child.parent = self }
  }

  public static func load(_ url: URL) throws -> AXFixtureNode {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let dict = object as? [String: Any] else { throw KitError("Fixture is not an object") }
    let tree = (dict["result"] as? [String: Any])?["tree"] as? [String: Any] ?? dict["tree"]
      as? [String: Any] ?? dict
    return AXFixtureNode(json: tree)
  }

  public func attribute(_ name: String) -> Any? { attributes[name] }
  public func childNodes() -> [AXNode] { children }
  public func actionNames() -> [String] { actions }
  public func perform(_ action: String) { performed.append(action) }
}
