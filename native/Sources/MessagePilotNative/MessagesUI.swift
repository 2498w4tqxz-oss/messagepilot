import AppKit
import ApplicationServices
import Foundation
import IMessage
import MessagePilotKit
import PlatformSDK

/// Messages features that Beeper's adapter does not drive: effects, formatting, photo stacks,
/// stickers, forwarding, Send Later, the add menu (iMessage apps) and group management.
///
/// Every flow opens the exact thread through Beeper (deep link plus selection assertion), refuses
/// to overwrite a draft, presses Send at most once, and returns only after chat.db shows the
/// persisted result. Failures before Send clean up what the flow authored.
@MainActor final class MessagesUI {
  let api: PlatformAPI
  let database: () throws -> ChatDatabase
  let workspace: String

  init(api: PlatformAPI, database: @escaping () throws -> ChatDatabase, workspace: String) {
    self.api = api
    self.database = database
    self.workspace = workspace
  }

  // MARK: Session

  struct Session {
    let window: LiveAXNode
    let chatGUID: String
    let baseline: Int64
  }

  func open(_ chat: String) async throws -> Session {
    let db = try database()
    guard let guid = try db.resolveChatGUID(chat) else {
      throw BridgeFailure("Chat is not in the Messages database")
    }
    // Beeper opens the thread by deep link and asserts the selection before returning.
    _ = try await api.getThreadActivityStatus(threadID: chat)
    try MessagesApp.activate()
    let window = try MessagesApp.wait("Messages window", timeout: 3) { try MessagesApp.window() }
    return Session(window: window, chatGUID: guid, baseline: try db.maxRowID(chat: guid))
  }

  func live(_ node: AXNode) throws -> LiveAXNode {
    guard let live = node as? LiveAXNode else { throw BridgeFailure("Internal: non-live node") }
    return live
  }

  func emptyComposer(_ window: LiveAXNode) throws -> LiveAXNode {
    let composer = try live(try MessagesAX.composer(in: window))
    guard composer.text.isEmpty else {
      throw BridgeFailure("Composer has a draft; refusing to overwrite it")
    }
    return composer
  }

  func author(_ composer: LiveAXNode, _ text: String) throws {
    try? composer.perform("AXPress")
    try composer.set(kAXValueAttribute, text as CFString)
    try? composer.set(kAXFocusedAttribute, kCFBooleanTrue)
    MessagesApp.pump(0.12)
    guard composer.text == text else {
      try? composer.set(kAXValueAttribute, "" as CFString)
      throw BridgeFailure("Composer did not accept the authored text")
    }
  }

  /// Removes text this flow authored. Never touches a draft it did not write.
  func discard(_ composer: LiveAXNode, authored: String) {
    MessagesApp.dismissTransientUI()
    if composer.text == authored || composer.text.isEmpty {
      try? composer.set(kAXValueAttribute, "" as CFString)
    }
  }

  func pick(_ node: AXNode) throws {
    let item = try live(node)
    guard item.enabled else {
      throw BridgeFailure("\(item.title ?? item.label ?? "Command") is disabled here")
    }
    try item.perform(item.actionNames().contains("AXPick") ? "AXPick" : "AXPress")
  }

  func menuCommand(_ identifier: String) throws {
    try pick(try MessagesAX.menuBarCommand(identifier, in: try MessagesApp.root()))
  }

  /// AXMenu nodes outside the menu bar (popup menus such as the add button's).
  func openMenus() -> [LiveAXNode] {
    guard let root = try? MessagesApp.root() else { return [] }
    return root.childNodes().filter { $0.role != "AXMenuBar" }.flatMap {
      $0.descendants(maxDepth: 14) { $0.role == "AXMenu" }
    }.compactMap { $0 as? LiveAXNode }.filter { !MessagesAX.menuItems(in: $0).isEmpty }
  }

  func openAddMenu(_ window: LiveAXNode) throws -> LiveAXNode {
    MessagesApp.dismissTransientUI()
    try live(try MessagesAX.addButton(in: window)).perform("AXPress")
    return try MessagesApp.wait("add menu", timeout: 2.5) { self.openMenus().first }
  }

  func closeMenu(_ menu: LiveAXNode) {
    try? menu.perform("AXCancel")
    MessagesApp.pump(0.1)
    if !openMenus().isEmpty, MessagesApp.isFrontmost { try? MessagesApp.key(MessagesApp.escapeKey) }
  }

  /// Polls chat.db for a new row in the chat that satisfies `match`.
  func reconcile(
    _ session: Session, timeout: TimeInterval = 10, _ match: ([String: Any]) -> Bool
  ) throws -> [String: Any]? {
    let db = try database()
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let row = try db.messages(chat: session.chatGUID, after: session.baseline).first(where: {
        ($0["is_from_me"] as? Int64) == 1 && match($0)
      }) {
        return row
      }
      MessagesApp.pump(0.1)
    } while Date() < deadline
    return nil
  }

  // MARK: Effects and formatting

  func effect(_ chat: String, text: String, effect: String, kind: String, range: [String: Int]?)
    async throws -> [String: Any]
  {
    let session = try await open(chat)
    let composer = try emptyComposer(session.window)
    try author(composer, text)
    do {
      if kind == "text" {
        try applyFormat(composer, text: text, range: range, commands: [effect.lowercased()])
        try submit(composer, text: text)
      } else {
        let menu = try openAddMenu(session.window)
        do {
          try pick(try MessagesAX.menuItem("Message Effects", identifiers: ["message_effects"], in: menu))
        } catch {
          closeMenu(menu)
          throw error
        }
        let button = try MessagesApp.wait("effect picker", timeout: 3) {
          try MessagesAX.effectButton(effect, in: try MessagesApp.window())
        }
        try live(button).perform("AXPress")
        MessagesApp.pump(0.2)
        let window = try MessagesApp.window()
        let previews = window.descendants { $0.identifier == "CKBalloonTextView" && $0.value == text }
        guard !previews.isEmpty else { throw BridgeFailure("Effect preview does not show the authored text") }
        guard let send = MessagesAX.sendButton(in: window),
          (send.label ?? "").lowercased() == "send with \(effect.lowercased()) effect"
        else { throw BridgeFailure("Send button does not confirm the \(effect) effect") }
        try live(send).perform("AXPress")
      }
    } catch {
      if let close = try? MessagesApp.window().first(where: { $0.identifier == "closeButton" }) {
        try? live(close).perform("AXPress")
      }
      discard(composer, authored: text)
      throw error
    }
    let request: [String: Any] = [
      "text": text, "effect": effect, "kind": kind, "range": range as Any,
    ]
    guard
      let row = try reconcile(session, { row in
        row["text"] as? String == text
          && RichPayload.matches(row, request: request, formatting: false, effect: true)
      })
    else { throw BridgeFailure("Effect submitted but the persisted effect was not observed; outcome unknown, do not retry") }
    return ["receipt": "native-effect-verified", "message": row, "delivery": "inspect-timestamps"]
  }

  func format(_ chat: String, text: String, styles: [String], range: [String: Int]?) async throws
    -> [String: Any]
  {
    let allowed = ["bold", "italic", "underline", "strikethrough"]
    guard !styles.isEmpty, styles.allSatisfy(allowed.contains) else {
      throw BridgeFailure("Styles must be bold, italic, underline or strikethrough")
    }
    let session = try await open(chat)
    let composer = try emptyComposer(session.window)
    try author(composer, text)
    do {
      try applyFormat(composer, text: text, range: range, commands: Array(Set(styles)).sorted())
      try submit(composer, text: text)
    } catch {
      discard(composer, authored: text)
      throw error
    }
    let request: [String: Any] = ["text": text, "styles": styles, "range": range as Any]
    guard
      let row = try reconcile(session, { row in
        row["text"] as? String == text
          && RichPayload.matches(row, request: request, formatting: true, effect: false)
      })
    else { throw BridgeFailure("Formatted send not observed with the requested styles; outcome unknown") }
    return ["receipt": "native-format-verified", "message": row, "delivery": "inspect-timestamps"]
  }

  func applyFormat(_ composer: LiveAXNode, text: String, range: [String: Int]?, commands: [String])
    throws
  {
    let length = (text as NSString).length
    let selection = NSRange(location: range?["start"] ?? 0, length: range?["length"] ?? length)
    guard selection.location >= 0, selection.length > 0, NSMaxRange(selection) <= length else {
      throw BridgeFailure("Invalid text range")
    }
    let shortcuts: [String: CGKeyCode] = ["bold": 11, "italic": 34, "underline": 32]
    for command in commands {
      try? composer.perform("AXPress")
      try composer.setSelection(selection)
      MessagesApp.pump(0.08)
      guard composer.selection == selection else {
        throw BridgeFailure("Composer selection differs from the requested range")
      }
      if let code = shortcuts[command], MessagesApp.isFrontmost {
        try MessagesApp.key(code, flags: .maskCommand)
      } else {
        try pick(try MessagesAX.formatCommand(command, in: try MessagesApp.root()))
      }
      MessagesApp.pump(0.12)
      if let format = MessagesAX.menuBarItem(
        identifier: "com.messages.formatmenu", title: "Format", in: try MessagesApp.root()),
        format.attribute("AXSelected") as? Bool == true
      {
        try? live(format).perform("AXCancel")
      }
    }
  }

  func submit(_ composer: LiveAXNode, text: String) throws {
    try? composer.set(kAXFocusedAttribute, kCFBooleanTrue)
    try composer.setSelection(NSRange(location: (text as NSString).length, length: 0))
    MessagesApp.pump(0.1)
    try MessagesApp.activate()
    try MessagesApp.key(MessagesApp.returnKey)
  }

  // MARK: Photo stacks (carousels of photos in one message)

  func photos(_ chat: String, paths: [String]) async throws -> [String: Any] {
    guard (2...20).contains(paths.count) else { throw BridgeFailure("2–20 photos required") }
    let sources = try paths.map { path -> URL in
      let file = URL(fileURLWithPath: try WorkspacePath.resolve(path, root: workspace))
      guard ["png", "jpg", "jpeg", "heic", "gif"].contains(file.pathExtension.lowercased()),
        NSImage(contentsOf: file) != nil
      else { throw BridgeFailure("Each photo must be a PNG, JPEG, HEIC or GIF inside the workspace") }
      return file
    }
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
      "messagepilot-photos-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let files = try sources.enumerated().map { index, source -> URL in
      let target = staging.appendingPathComponent("\(index)-" + source.lastPathComponent)
      try FileManager.default.copyItem(at: source, to: target)
      return target
    }
    let session = try await open(chat)
    let composer = try emptyComposer(session.window)
    let board = NSPasteboard.general
    board.clearContents()
    guard board.writeObjects(files as [NSURL]) else { throw BridgeFailure("Cannot stage photos") }
    let version = board.changeCount
    defer { if board.changeCount == version { board.clearContents() } }
    try? composer.perform("AXPress")
    try? composer.set(kAXFocusedAttribute, kCFBooleanTrue)
    try MessagesApp.activate()
    try MessagesApp.key(9, flags: .maskCommand)
    let staged = try MessagesApp.wait("staged photos", timeout: 4) { () -> String? in
      let value = composer.text
      return value.filter { $0 == "\u{fffc}" }.count == paths.count ? value : nil
    }
    guard staged.allSatisfy({ $0 == "\u{fffc}" || $0.isWhitespace }) else {
      discard(composer, authored: staged)
      throw BridgeFailure("Composer holds more than the requested photos; not sent")
    }
    try MessagesApp.key(MessagesApp.returnKey)
    let db = try database()
    guard
      let row = try reconcile(session, timeout: 30, { row in
        (row["cache_has_attachments"] as? Int64) == 1
          && ((try? db.attachments(message: row["guid"] as? String ?? "").count) ?? 0) == paths.count
      })
    else { throw BridgeFailure("Photo stack submitted but not reconciled; outcome unknown, do not retry") }
    return [
      "receipt": "native-photo-stack-sent", "message": row,
      "attachments": try db.attachments(message: row["guid"] as? String ?? ""),
      "delivery": "inspect-timestamps",
    ]
  }

  // MARK: Stickers

  /// Finds the Emoji & Stickers picker: an attached popover, or on macOS 26 a detached popover
  /// window owned by Messages.
  func stickerPicker() -> LiveAXNode? {
    guard let root = try? MessagesApp.root() else { return nil }
    let windows = (root.attribute(kAXWindowsAttribute) as? [AXUIElement] ?? []).map(LiveAXNode.init)
    for window in windows {
      if let popover = window.first(maxDepth: 10, where: { $0.role == "AXPopover" }) as? LiveAXNode,
        popover.first(maxDepth: 8, where: { ($0.attribute("AXSubrole") as? String) == "AXSearchField" }) != nil
      {
        return popover
      }
      if window.identifier != "SceneWindow",
        window.first(maxDepth: 8, where: { ($0.attribute("AXSubrole") as? String) == "AXSearchField" }) != nil
      {
        return window
      }
    }
    return nil
  }

  static let pickerChrome: Set<String> = [
    "Search", "Frequently Used", "Smileys & People", "Animals & Nature", "Food & Drink",
    "Activity", "Travel & Places", "Objects", "Symbols", "Flags", "Emoji", "Stickers", "Memoji",
    "Recents", "Close",
  ]

  func pickerLabels(_ picker: AXNode) -> [String] {
    picker.descendants(maxDepth: 12) { !($0.label ?? $0.title ?? "").isEmpty }.compactMap {
      $0.label ?? $0.title
    }
  }

  /// Switches the picker to its Stickers section and returns pressable sticker items.
  func stickerItems(_ picker: LiveAXNode) throws -> [LiveAXNode] {
    if let tab = picker.first(maxDepth: 12, where: { node in
      ["Stickers", "Sticker"].contains(node.label ?? node.title ?? "")
        && node.actionNames().contains("AXPress")
    }) as? LiveAXNode {
      try? tab.perform("AXPress")
      MessagesApp.pump(0.4)
    }
    return picker.descendants(maxDepth: 14) { node in
      let label = node.label ?? ""
      return !label.isEmpty && !Self.pickerChrome.contains(label)
        && node.actionNames().contains("AXPress")
        && ["AXButton", "AXCell", "AXImage", "AXGroup"].contains(node.role ?? "")
        && (label.lowercased().contains("sticker") || node.identifier?.lowercased().contains("sticker") == true
          || node.role == "AXImage")
    }.compactMap { $0 as? LiveAXNode }
  }

  func chooseSticker(_ picker: LiveAXNode, query: String?, index: Int) throws -> String {
    let items = try stickerItems(picker)
    let candidates =
      query.map { q in items.filter { ($0.label ?? "").lowercased().contains(q.lowercased()) } }
      ?? items
    guard candidates.indices.contains(index) else {
      throw BridgeFailure(
        "No sticker matched (\(candidates.count) candidates). Picker labels: \(pickerLabels(picker).prefix(40).joined(separator: " | "))"
      )
    }
    let chosen = candidates[index]
    try chosen.perform("AXPress")
    return chosen.label ?? ""
  }

  func sticker(_ chat: String, query: String?, index: Int) async throws -> [String: Any] {
    let session = try await open(chat)
    let composer = try emptyComposer(session.window)
    do {
      try live(try MessagesAX.emojiPickerButton(in: session.window)).perform("AXPress")
    } catch {
      try menuCommand("orderFrontCharacterPalette:")
    }
    let picker = try MessagesApp.wait("Emoji & Stickers picker", timeout: 3) { self.stickerPicker() }
    let chosen: String
    do {
      chosen = try chooseSticker(picker, query: query, index: index)
    } catch {
      MessagesApp.dismissTransientUI()
      throw error
    }
    MessagesApp.pump(0.4)
    MessagesApp.dismissTransientUI()
    // A chosen sticker lands in the composer as one attachment; send only that.
    let staged = composer.text
    guard staged.filter({ $0 == "\u{fffc}" }).count == 1,
      staged.allSatisfy({ $0 == "\u{fffc}" || $0.isWhitespace })
    else {
      discard(composer, authored: staged)
      throw BridgeFailure("Sticker did not stage in the composer; nothing sent")
    }
    try MessagesApp.activate()
    try MessagesApp.key(MessagesApp.returnKey)
    let db = try database()
    guard
      let row = try reconcile(session, timeout: 20, { row in
        let atts = (try? db.attachments(message: row["guid"] as? String ?? "")) ?? []
        return atts.count == 1 && (atts[0]["isSticker"] as? Bool == true)
      })
    else { throw BridgeFailure("Sticker submitted but no sticker attachment observed; outcome unknown") }
    return ["receipt": "native-sticker-sent", "sticker": chosen, "message": row]
  }

  /// Opens one message in the overlay view and returns its bubble action target.
  func overlay(_ chat: String, messageID: String) async throws -> (Session, LiveAXNode) {
    let guid = MessageID.guid(messageID)
    let session = try await open(chat)
    guard NSWorkspace.shared.open(try MessageID.deepLink(guid: guid, overlay: true)) else {
      throw BridgeFailure("Messages refused the message deep link")
    }
    let target = try MessagesApp.wait("message bubble", timeout: 3) {
      try MessagesAX.overlayBubble(in: try MessagesApp.window())
    }
    return (session, try live(target))
  }

  func closeOverlay() {
    if let window = try? MessagesApp.window(), let overlay = MessagesAX.overlayTranscript(in: window) {
      try? live(overlay).perform("AXCancel")
    }
  }

  func attachSticker(_ chat: String, messageID: String, query: String?, index: Int) async throws
    -> [String: Any]
  {
    let guid = MessageID.guid(messageID)
    let before = try database().reactions(to: guid).map(\.rowID).max() ?? 0
    let (_, bubble) = try await overlay(chat, messageID: messageID)
    defer { closeOverlay() }
    guard let action = bubble.customAction(MessagesAX.BubbleAction.attachSticker.rawValue) else {
      throw BridgeFailure("Attach Sticker… is not offered for this message")
    }
    try bubble.perform(action)
    let picker = try MessagesApp.wait("sticker picker", timeout: 3) { self.stickerPicker() }
    let chosen: String
    do {
      chosen = try chooseSticker(picker, query: query, index: index)
    } catch {
      MessagesApp.dismissTransientUI()
      throw error
    }
    let db = try database()
    let deadline = Date().addingTimeInterval(15)
    repeat {
      let rows = try db.reactions(to: guid)
      if let placed = rows.first(where: { $0.rowID > before && $0.fromMe && $0.kind == .sticker }) {
        MessagesApp.dismissTransientUI()
        return [
          "receipt": "native-sticker-attached", "sticker": chosen, "reaction": placed.json,
          "reactions": ReactionState.current(rows).map(\.json),
        ]
      }
      MessagesApp.pump(0.15)
    } while Date() < deadline
    MessagesApp.dismissTransientUI()
    throw BridgeFailure("Sticker chosen but no sticker Tapback was persisted; outcome unknown")
  }

  // MARK: Forward

  func forward(_ chat: String, messageID: String, to recipient: String) async throws -> [String: Any]
  {
    guard IdentityResolver.isIdentityLike(recipient) else {
      throw BridgeFailure("Forward recipient must be a phone number (+country code) or email")
    }
    let (_, bubble) = try await overlay(chat, messageID: messageID)
    guard let action = bubble.customAction(MessagesAX.BubbleAction.forward.rawValue) else {
      closeOverlay()
      throw BridgeFailure("Forward… is not offered for this message")
    }
    try bubble.perform(action)
    let to = try MessagesApp.wait("forward recipient field", timeout: 3) {
      try MessagesApp.window().first(where: { $0.identifier == "To:" }) as? LiveAXNode
    }
    guard to.text.isEmpty else { throw BridgeFailure("Recipient field is not empty") }
    try to.set(kAXValueAttribute, recipient as CFString)
    try? to.set(kAXFocusedAttribute, kCFBooleanTrue)
    try MessagesApp.activate()
    try MessagesApp.key(MessagesApp.returnKey)
    MessagesApp.pump(1.5)  // IDS resolves the address before the composer accepts Return
    let composer = try live(try MessagesAX.composer(in: try MessagesApp.window()))
    guard !composer.text.isEmpty else {
      MessagesApp.dismissTransientUI()
      throw BridgeFailure("Forwarded content did not stage in the composer; nothing sent")
    }
    let started = Date()
    try? composer.set(kAXFocusedAttribute, kCFBooleanTrue)
    try MessagesApp.key(MessagesApp.returnKey)
    let db = try database()
    let deadline = Date().addingTimeInterval(20)
    repeat {
      for guid in ChatDatabase.chatGUIDCandidates("any;-;" + recipient) {
        if let row = try db.messages(chat: guid, after: 0, limit: 5).first(where: {
          ($0["is_from_me"] as? Int64) == 1
            && (ISO8601DateFormatter().date(from: $0["date"] as? String ?? "") ?? .distantPast)
              > started.addingTimeInterval(-5)
        }) {
          return ["receipt": "native-forward-sent", "chatId": guid, "message": row]
        }
      }
      MessagesApp.pump(0.2)
    } while Date() < deadline
    throw BridgeFailure("Forward submitted but no message to the recipient was observed; outcome unknown")
  }

  // MARK: Send Later

  func schedule(_ chat: String, text: String, sendAt: Date) async throws -> [String: Any] {
    let session = try await open(chat)
    let composer = try emptyComposer(session.window)
    try author(composer, text)
    do {
      try menuCommand("send_later…")
      let control = try MessagesApp.wait("Send Later time control", timeout: 3) { () -> LiveAXNode? in
        let root = try MessagesApp.root()
        return root.descendants(maxDepth: 16) { $0.role == "AXDateTimeArea" }.first as? LiveAXNode
      }
      try control.set(kAXValueAttribute, SendLater.minute(sendAt) as CFDate)
      MessagesApp.pump(0.3)
      guard let shown = control.attribute(kAXValueAttribute) as? Date,
        SendLater.matches(persisted: shown, requested: sendAt)
      else { throw BridgeFailure("Send Later picker did not accept the requested time") }
      try submit(composer, text: text)
    } catch {
      discard(composer, authored: text)
      throw BridgeFailure("Send Later not scheduled: \(error)")
    }
    let db = try database()
    let deadline = Date().addingTimeInterval(10)
    repeat {
      if let row = try db.scheduled(chat: session.chatGUID).first(where: {
        $0["text"] as? String == text && ($0["rowId"] as? Int64 ?? 0) > session.baseline
      }) {
        let persisted = ISO8601DateFormatter().date(from: row["scheduledFor"] as? String ?? "")
        guard let persisted, SendLater.matches(persisted: persisted, requested: sendAt) else {
          throw BridgeFailure("Scheduled message persisted at a different time: \(row["scheduledFor"] ?? "")")
        }
        return ["receipt": "native-send-later-scheduled", "message": row]
      }
      MessagesApp.pump(0.15)
    } while Date() < deadline
    throw BridgeFailure("Send Later submitted but no scheduled row observed; outcome unknown")
  }

  func cancelScheduled(_ chat: String, messageID: String) async throws -> [String: Any] {
    let guid = MessageID.guid(messageID)
    let db = try database()
    guard let row = try db.scheduled(chat: nil).first(where: { $0["guid"] as? String == guid }),
      (row["is_from_me"] as? Int64) == 1
    else { throw BridgeFailure("Message is not one of this account's scheduled messages") }
    let text = row["text"] as? String ?? ""
    let session = try await open(chat)
    guard let transcript = MessagesAX.mainTranscript(in: session.window) else {
      throw BridgeFailure("Transcript not found")
    }
    let bubble = try live(try MessagesAX.bubble(text: text, own: true, in: transcript))
    let names = bubble.shortActionNames
    guard
      let action = bubble.actionNames().first(where: { name in
        ["Name:Delete…", "Name:Delete", "Name:Cancel Send", "Name:Delete Message"].contains(
          String(name.split(separator: "\n").first ?? ""))
      })
    else {
      throw BridgeFailure("No delete action on the scheduled bubble; observed: \(names.joined(separator: ", "))")
    }
    try bubble.perform(action)
    // Messages confirms deletes in a sheet with a Delete button.
    if let confirm = try? MessagesApp.wait("delete confirmation", timeout: 2, { () -> LiveAXNode? in
      try MessagesApp.window().first(maxDepth: 12) {
        $0.role == "AXButton" && ["Delete", "Delete Message"].contains($0.title ?? $0.label ?? "")
      } as? LiveAXNode
    }) {
      try confirm.perform("AXPress")
    }
    let deadline = Date().addingTimeInterval(8)
    repeat {
      let still = try db.scheduled(chat: session.chatGUID).first { $0["guid"] as? String == guid }
      if still == nil || (still?["state"] as? String) == "cancelled" {
        return ["receipt": "native-send-later-cancelled", "messageId": guid]
      }
      MessagesApp.pump(0.15)
    } while Date() < deadline
    throw BridgeFailure("Delete chosen but the scheduled row remains; outcome unknown")
  }

  // MARK: iMessage apps (the add menu)

  func appsList(_ chat: String) async throws -> [String: Any] {
    let session = try await open(chat)
    let menu = try openAddMenu(session.window)
    let items = MessagesAX.menuItems(in: menu)
    closeMenu(menu)
    return ["items": items.map(\.json), "source": "Messages add menu"]
  }

  func presentedUI(_ window: LiveAXNode) -> AXNode? {
    window.first(maxDepth: 10) { ["AXPopover", "AXSheet"].contains($0.role ?? "") }
      ?? (try? MessagesApp.root()).flatMap { root in
        (root.attribute(kAXWindowsAttribute) as? [AXUIElement] ?? []).map(LiveAXNode.init)
          .first { $0.identifier != "SceneWindow" }
      }
  }

  func describe(_ node: AXNode, depth: Int = 6) -> [String: Any] {
    var out = node.summary()
    if let value = node.value, !value.isEmpty { out["value"] = String(value.prefix(200)) }
    let actions = node.shortActionNames.filter { $0 != "AXScrollToVisible" }
    if !actions.isEmpty { out["actions"] = actions }
    if depth > 0 {
      let kids = node.childNodes().prefix(60).map { describe($0, depth: depth - 1) }
      if !kids.isEmpty { out["children"] = Array(kids) }
    }
    return out
  }

  func appsOpen(_ chat: String, app: String) async throws -> (Session, AXNode?, [String: Any]) {
    let session = try await open(chat)
    let menu = try openAddMenu(session.window)
    do {
      try pick(try MessagesAX.menuItem(app, identifiers: [app], in: menu))
    } catch {
      closeMenu(menu)
      throw error
    }
    MessagesApp.pump(0.8)
    let window = try MessagesApp.window()
    let presented = presentedUI(window)
    return (
      session, presented,
      [
        "receipt": "messages-app-opened", "app": app,
        "presented": presented.map { describe($0) } ?? NSNull(),
        "entry": MessagesAX.entryView(in: window).map { describe($0, depth: 3) } ?? NSNull(),
      ]
    )
  }

  func appsPrompt(_ chat: String, app: String, text: String, submit: Bool) async throws
    -> [String: Any]
  {
    let (_, presented, opened) = try await appsOpen(chat, app: app)
    let window = try MessagesApp.window()
    let scope = presented ?? window
    let fields = scope.descendants(skipIdentifiers: MessagesAX.privateRegions) { node in
      ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(node.role ?? "")
        && node.identifier != MessagesAX.composerIdentifier && node.label != "Search"
          || (node.attribute("AXSubrole") as? String) == "AXSearchField"
          && node.identifier != MessagesAX.composerIdentifier
    }.compactMap { $0 as? LiveAXNode }
    guard fields.count == 1 else {
      MessagesApp.dismissTransientUI()
      throw BridgeFailure(
        "Expected one prompt field in \(app), found \(fields.count); opened UI: \(opened["presented"] ?? "none")")
    }
    let field = fields[0]
    try? field.perform("AXPress")
    try? field.set(kAXFocusedAttribute, kCFBooleanTrue)
    do { try field.set(kAXValueAttribute, text as CFString) } catch { try MessagesApp.type(text) }
    if submit {
      try MessagesApp.activate()
      try MessagesApp.key(MessagesApp.returnKey)
    }
    MessagesApp.pump(1.2)
    return [
      "receipt": "messages-app-prompted", "app": app, "submitted": submit,
      "presented": presentedUI(try MessagesApp.window()).map { describe($0) } ?? NSNull(),
    ]
  }

  // MARK: Conversation management

  func details(_ chat: String) async throws -> (Session, AXNode) {
    let session = try await open(chat)
    try menuCommand("show_details")
    let ui = try MessagesApp.wait("conversation details", timeout: 3) {
      self.presentedUI(try MessagesApp.window())
    }
    return (session, ui)
  }

  func detailsSummary(_ chat: String) async throws -> [String: Any] {
    let (_, ui) = try await details(chat)
    defer { MessagesApp.dismissTransientUI() }
    return ["receipt": "details-opened", "details": describe(ui, depth: 8)]
  }

  func requireGroup(_ chat: String) throws -> [String: Any] {
    let db = try database()
    guard let guid = try db.resolveChatGUID(chat), let info = try db.chat(guid) else {
      throw BridgeFailure("Chat not found")
    }
    guard info["isGroup"] as? Bool == true else {
      throw BridgeFailure("This operation needs a group conversation")
    }
    return info
  }

  func detailsControl(_ ui: AXNode, labels: [String], roles: [String] = ["AXButton"]) throws
    -> LiveAXNode
  {
    let found = ui.descendants(maxDepth: 14) { node in
      roles.contains(node.role ?? "")
        && labels.contains(where: { l in
          (node.label ?? node.title ?? "").localizedCaseInsensitiveContains(l)
        })
    }.compactMap { $0 as? LiveAXNode }
    guard found.count == 1 else {
      throw BridgeFailure(
        "Expected one control matching \(labels), found \(found.count); details labels: \(ui.descendants(maxDepth: 14, where: { !($0.label ?? $0.title ?? "").isEmpty }).compactMap { $0.label ?? $0.title }.prefix(40).joined(separator: " | "))"
      )
    }
    return found[0]
  }

  func rename(_ chat: String, name: String) async throws -> [String: Any] {
    let info = try requireGroup(chat)
    let (_, ui) = try await details(chat)
    defer { MessagesApp.dismissTransientUI() }
    let current = info["display_name"] as? String ?? ""
    let fields = ui.descendants(maxDepth: 14) { node in
      ["AXTextField", "AXTextArea"].contains(node.role ?? "")
        && ((node.value ?? "") == current && !current.isEmpty
          || (node.attribute("AXPlaceholderValue") as? String ?? node.label ?? "")
            .localizedCaseInsensitiveContains("name"))
    }.compactMap { $0 as? LiveAXNode }
    guard fields.count == 1 else {
      throw BridgeFailure("Group name field not found uniquely (\(fields.count))")
    }
    try fields[0].set(kAXValueAttribute, name as CFString)
    try? fields[0].set(kAXFocusedAttribute, kCFBooleanTrue)
    try MessagesApp.activate()
    try MessagesApp.key(MessagesApp.returnKey)
    let db = try database()
    let guid = info["guid"] as? String ?? chat
    let deadline = Date().addingTimeInterval(8)
    repeat {
      if (try db.chat(guid))?["display_name"] as? String == name {
        return ["receipt": "group-renamed", "name": name]
      }
      MessagesApp.pump(0.15)
    } while Date() < deadline
    throw BridgeFailure("Rename submitted but the group name did not change; outcome unknown")
  }

  func participants(_ chat: String, add addresses: [String]) async throws -> [String: Any] {
    let info = try requireGroup(chat)
    guard !addresses.isEmpty, addresses.allSatisfy(IdentityResolver.isIdentityLike) else {
      throw BridgeFailure("addresses must be phone numbers or emails")
    }
    let (_, ui) = try await details(chat)
    defer { MessagesApp.dismissTransientUI() }
    try detailsControl(ui, labels: ["Add Member", "Add Members", "Add Contact"]).perform("AXPress")
    let field = try MessagesApp.wait("member field", timeout: 3) { () -> LiveAXNode? in
      try MessagesApp.root().descendants(maxDepth: 16) { node in
        ["AXTextField", "AXTextArea"].contains(node.role ?? "")
          && (node.identifier == "To:" || (node.label ?? "").localizedCaseInsensitiveContains("add"))
          && node.identifier != MessagesAX.composerIdentifier
      }.first as? LiveAXNode
    }
    for address in addresses {
      try field.set(kAXValueAttribute, address as CFString)
      try? field.set(kAXFocusedAttribute, kCFBooleanTrue)
      try MessagesApp.activate()
      try MessagesApp.key(MessagesApp.returnKey)
      MessagesApp.pump(1.0)
    }
    if let done = try? detailsControl(try presentedUI(try MessagesApp.window()) ?? ui, labels: ["Add", "Done"]) {
      try? done.perform("AXPress")
    }
    let guid = info["guid"] as? String ?? chat
    let db = try database()
    let deadline = Date().addingTimeInterval(15)
    repeat {
      let members = (try db.chat(guid))?["participants"] as? [String] ?? []
      if addresses.allSatisfy({ a in members.contains { IdentityResolver.same($0, a) } }) {
        return ["receipt": "members-added", "participants": members]
      }
      MessagesApp.pump(0.2)
    } while Date() < deadline
    throw BridgeFailure("Add submitted but the members were not observed; outcome unknown")
  }

  func participants(_ chat: String, remove address: String) async throws -> [String: Any] {
    let info = try requireGroup(chat)
    let (_, ui) = try await details(chat)
    defer { MessagesApp.dismissTransientUI() }
    let rows = ui.descendants(maxDepth: 14) { node in
      node.shortActionNames.contains { $0.hasPrefix("Name:Remove") }
        && ((node.label ?? "").contains(address) || (node.title ?? "").contains(address))
    }.compactMap { $0 as? LiveAXNode }
    guard rows.count == 1, let action = rows[0].actionNames().first(where: { $0.hasPrefix("Name:Remove") })
    else { throw BridgeFailure("Member row with a Remove action not found uniquely (\(rows.count))") }
    try rows[0].perform(action)
    let guid = info["guid"] as? String ?? chat
    let db = try database()
    let deadline = Date().addingTimeInterval(15)
    repeat {
      let members = (try db.chat(guid))?["participants"] as? [String] ?? []
      if !members.contains(where: { IdentityResolver.same($0, address) }) {
        return ["receipt": "member-removed", "participants": members]
      }
      MessagesApp.pump(0.2)
    } while Date() < deadline
    throw BridgeFailure("Remove chosen but the member is still listed; outcome unknown")
  }

  func leave(_ chat: String) async throws -> [String: Any] {
    _ = try requireGroup(chat)
    let (_, ui) = try await details(chat)
    defer { MessagesApp.dismissTransientUI() }
    try detailsControl(ui, labels: ["Leave this Conversation", "Leave Conversation"]).perform("AXPress")
    if let confirm = try? MessagesApp.wait("leave confirmation", timeout: 2, { () -> LiveAXNode? in
      try MessagesApp.root().descendants(maxDepth: 14) {
        $0.role == "AXButton" && ["Leave", "Leave Conversation"].contains($0.title ?? $0.label ?? "")
      }.first as? LiveAXNode
    }) {
      try confirm.perform("AXPress")
    }
    return ["receipt": "leave-requested", "delivery": "inspect-chat-membership"]
  }

  func pin(_ chat: String, pinned: Bool) async throws -> [String: Any] {
    let session = try await open(chat)
    guard let row = MessagesAX.selectedConversationRow(in: session.window) else {
      throw BridgeFailure("Selected conversation row not found")
    }
    guard let action = MessagesAX.pinAction(row, pinned: pinned) else {
      return ["receipt": "already-in-requested-state", "pinned": pinned]
    }
    try live(row).perform(action)
    MessagesApp.pump(0.4)
    return ["receipt": pinned ? "conversation-pinned" : "conversation-unpinned"]
  }
}
