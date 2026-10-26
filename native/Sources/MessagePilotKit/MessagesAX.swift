import Foundation

/// Messages.app Accessibility map for macOS 26 (English), recorded from the DOOR line's virtual Mac
/// running macOS 26.6.2 with `apps.snapshot`. Fixtures under Tests/MessagePilotKitTests/Fixtures
/// replay those trees (sanitized) so every finder here is tested against the real structure.
///
/// Two layouts were observed. The full layout exposes identifiers (MessageEntryView,
/// messageBodyField as an AXTextField described "Message"). A reduced layout, seen right after
/// Messages restarts, drops most identifiers and uses SF Symbol names ("face.grinning"). Finders
/// accept both and fail closed when a match is ambiguous.
public enum MessagesAX {
  public static let bundleID = "com.apple.MobileSMS"
  /// Never traversed: reading them would expose other conversations.
  public static let privateRegions: Set<String> = ["ConversationList", "CKConversationListCollectionView"]

  public static let composerIdentifier = "messageBodyField"
  public static let entryViewIdentifier = "MessageEntryView"
  public static let transcriptIdentifier = "TranscriptCollectionView"

  /// Custom actions on a message bubble in macOS 26.6.2.
  public enum BubbleAction: String, CaseIterable {
    case addEmojiTapback = "Add Emoji as Tapback"
    case tapbackDetails = "Tapback Details…"
    case reply = "Reply…"
    case attachSticker = "Attach Sticker…"
    case forward = "Forward…"
    case copy = "Copy"
    case delete = "Delete…"
    case showTimes = "Show Times"
    case edit = "Edit"
    case undoSend = "Undo Send"
  }

  // MARK: Composer

  public static func entryView(in window: AXNode) -> AXNode? {
    if let entry = window.descendants(skipIdentifiers: privateRegions, where: {
      $0.identifier == entryViewIdentifier
    }).first {
      return entry
    }
    // Reduced layout: the group that directly contains the "add" button.
    return window.descendants(skipIdentifiers: privateRegions) { node in
      node.childNodes().contains { $0.role == "AXButton" && $0.label == "add" }
    }.first
  }

  public static func composer(in window: AXNode) throws -> AXNode {
    let identified = window.descendants(skipIdentifiers: privateRegions) {
      $0.identifier == composerIdentifier
    }
    if identified.count == 1 { return identified[0] }
    guard identified.isEmpty, let entry = entryView(in: window) else {
      throw AXLookup.Ambiguity(what: "Message composer", count: identified.count, observed: [])
    }
    let fields = entry.childNodes().filter { ["AXTextField", "AXTextArea"].contains($0.role ?? "") }
    guard fields.count == 1 else {
      throw AXLookup.Ambiguity(
        what: "Message composer", count: fields.count,
        observed: entry.childNodes().map { $0.role ?? "?" })
    }
    return fields[0]
  }

  public static func entryButton(_ labels: [String], in window: AXNode) throws -> AXNode {
    guard let entry = entryView(in: window) else {
      throw AXLookup.Ambiguity(what: "Message entry view", count: 0, observed: [])
    }
    let found = entry.childNodes().filter { $0.role == "AXButton" && labels.contains($0.label ?? "") }
    guard found.count == 1 else {
      throw AXLookup.Ambiguity(
        what: "Entry button \(labels.first ?? "")", count: found.count,
        observed: entry.childNodes().compactMap(\.label))
    }
    return found[0]
  }
  public static func addButton(in window: AXNode) throws -> AXNode {
    try entryButton(["add"], in: window)
  }
  public static func emojiPickerButton(in window: AXNode) throws -> AXNode {
    try entryButton(["Emoji picker", "face.grinning"], in: window)
  }
  public static func recordAudioButton(in window: AXNode) throws -> AXNode {
    try entryButton(["Record audio", "waveform"], in: window)
  }

  // MARK: Transcript and bubbles

  public static func transcripts(in window: AXNode) -> [AXNode] {
    window.descendants(skipIdentifiers: privateRegions) { $0.identifier == transcriptIdentifier }
  }

  /// The overlay/reply transcript opened by `imessage://open?message-guid=…&overlay=1`.
  public static func overlayTranscript(in window: AXNode) -> AXNode? {
    let all = transcripts(in: window)
    guard all.count > 1 else { return nil }
    return all.first { $0.label != "Messages" }
  }

  public static func mainTranscript(in window: AXNode) -> AXNode? {
    let all = transcripts(in: window)
    return all.first { $0.label == "Messages" } ?? (all.count == 1 ? all[0] : nil)
  }

  static let messageActionTitles: Set<String> = Set(
    BubbleAction.allCases.map(\.rawValue) + ReactionRequest.Classic.allCases.map(\.actionTitle))

  public static func hasMessageActions(_ node: AXNode) -> Bool {
    node.shortActionNames.contains { name in
      name.hasPrefix("Name:") && messageActionTitles.contains(String(name.dropFirst(5)))
    }
  }

  /// The element that carries a bubble's custom actions (the "Sticker" group in macOS 26).
  public static func actionTarget(_ container: AXNode) -> AXNode? {
    if hasMessageActions(container) { return container }
    return container.childNodes().first(where: hasMessageActions)
  }

  /// Transcript rows that are messages (they carry a description and Tapback/Reply actions).
  public static func messageContainers(in transcript: AXNode) -> [AXNode] {
    transcript.childNodes().filter { node in
      !(node.label ?? "").isEmpty && actionTarget(node) != nil
    }
  }

  public static func isOwn(_ container: AXNode) -> Bool {
    let label = container.label ?? actionTarget(container)?.label ?? ""
    return label.hasPrefix("Your ")
  }

  public static func balloonText(_ container: AXNode) -> String? {
    container.first(maxDepth: 4) { $0.identifier == "CKBalloonTextView" }?.value
  }

  /// One bubble by exact text and direction. Repeated text is refused rather than guessed.
  public static func bubble(text: String, own: Bool, in transcript: AXNode) throws -> AXNode {
    let found = messageContainers(in: transcript).filter {
      isOwn($0) == own && balloonText($0) == text
    }
    guard found.count == 1 else {
      throw AXLookup.Ambiguity(what: "Message bubble", count: found.count, observed: [])
    }
    return actionTarget(found[0])!
  }

  /// The single bubble shown by an overlay deep link.
  public static func overlayBubble(in window: AXNode) throws -> AXNode {
    guard let overlay = overlayTranscript(in: window) else {
      throw AXLookup.Ambiguity(what: "Overlay transcript", count: 0, observed: [])
    }
    let containers = messageContainers(in: overlay)
    guard let first = containers.first, let target = actionTarget(first) else {
      throw AXLookup.Ambiguity(what: "Overlay bubble", count: 0, observed: [])
    }
    return target
  }

  // MARK: Menus

  public struct MenuItem: Equatable {
    public let identifier: String?
    public let title: String
    public let enabled: Bool
    public var json: [String: Any] {
      ["identifier": identifier ?? NSNull(), "title": title, "enabled": enabled]
    }
  }

  public static func menuItems(in menu: AXNode) -> [MenuItem] {
    menu.descendants(maxDepth: 3) { $0.role == "AXMenuItem" }.compactMap { node in
      guard let title = node.title, !title.isEmpty else { return nil }
      return MenuItem(identifier: node.identifier, title: title, enabled: node.enabled)
    }
  }

  public static func menuItem(
    _ name: String, identifiers: [String] = [], in menu: AXNode
  ) throws -> AXNode {
    let wanted = name.lowercased()
    let found = menu.descendants(maxDepth: 4) { node in
      node.role == "AXMenuItem"
        && (identifiers.contains(node.identifier ?? "\u{0}")
          || node.identifier?.lowercased() == wanted || node.title?.lowercased() == wanted)
    }
    guard found.count == 1 else {
      throw AXLookup.Ambiguity(
        what: "Menu item \(name)", count: found.count, observed: menuItems(in: menu).map(\.title))
    }
    return found[0]
  }

  public static func menuBarItem(identifier: String, title: String, in app: AXNode) -> AXNode? {
    app.first(maxDepth: 3) {
      $0.role == "AXMenuBarItem" && ($0.identifier == identifier || $0.title == title)
    }
  }

  /// Format menu commands keep stable identifiers on macOS 26: bold … strikethrough and the
  /// eight text effects (big, small, shake, nod, explode, ripple, bloom, jitter).
  public static func formatCommand(_ name: String, in app: AXNode) throws -> AXNode {
    guard let format = menuBarItem(identifier: "com.messages.formatmenu", title: "Format", in: app)
    else { throw AXLookup.Ambiguity(what: "Format menu", count: 0, observed: []) }
    return try menuItem(name, identifiers: [name.lowercased()], in: format)
  }

  /// Any menu-bar command by stable identifier, e.g. Edit › Send Later… is `send_later…` and
  /// View › Send Later (a list filter) is `send_later`; both exist on macOS 26.6.2.
  public static func menuBarCommand(_ identifier: String, in app: AXNode) throws -> AXNode {
    guard let bar = app.childNodes().first(where: { $0.role == "AXMenuBar" }) else {
      throw AXLookup.Ambiguity(what: "Menu bar", count: 0, observed: [])
    }
    let found = bar.descendants(maxDepth: 5) {
      $0.role == "AXMenuItem" && $0.identifier == identifier
    }
    guard found.count == 1 else {
      throw AXLookup.Ambiguity(what: "Menu command \(identifier)", count: found.count, observed: [])
    }
    return found[0]
  }

  /// The selected row of the conversation list, the only row a chat-level action may read.
  public static func selectedConversationRow(in window: AXNode) -> AXNode? {
    guard
      let list = window.first(where: { $0.identifier == "ConversationList" })
    else { return nil }
    let rows = list.descendants(maxDepth: 3) { node in
      (node.attribute("AXSelected") as? Bool) == true
        && node.shortActionNames.contains { $0.hasPrefix("Name:Pin ") || $0.hasPrefix("Name:Unpin ") }
    }
    return rows.count == 1 ? rows[0] : nil
  }

  public static func pinAction(_ row: AXNode, pinned: Bool) -> String? {
    let prefix = pinned ? "Name:Pin " : "Name:Unpin "
    return row.actionNames().first { $0.hasPrefix(prefix) }
  }

  public static func conversationCommand(_ identifier: String, in app: AXNode) throws -> AXNode {
    guard
      let menu = menuBarItem(
        identifier: "com.messages.conversationsmenu", title: "Conversation", in: app)
    else { throw AXLookup.Ambiguity(what: "Conversation menu", count: 0, observed: []) }
    return try menuItem(identifier, identifiers: [identifier], in: menu)
  }

  // MARK: Effects

  public static func effectButton(_ effect: String, in root: AXNode) throws -> AXNode {
    try AXLookup.unique(
      "Effect \(effect)", in: root,
      observe: { ($0.label ?? "").hasPrefix("Effect:") ? $0.label : nil },
      where: { $0.label == "Effect: " + effect })
  }

  public static func sendButton(in root: AXNode) -> AXNode? {
    root.first { $0.identifier == "sendButton" }
  }
}
