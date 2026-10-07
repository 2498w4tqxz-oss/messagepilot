import AppKit
import ApplicationServices
import Foundation
import SQLite3

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}
struct Config: Decodable {
  let accountId: String
  let expectedIdentity: String
  let expectedOSUser: String
  let allowedChatIds: [String]
  let database: String?
  let enableUI: Bool?
  let workspace: String?
}
func pause(_ seconds: TimeInterval) {
  Thread.sleep(forTimeInterval: seconds)
}
func required(_ p: [String: Any], _ key: String) throws -> String {
  guard let v = p[key] as? String, !v.isEmpty else { throw Failure("Missing \(key)") }
  return v
}
final class ScopedDatabase {
  let config: Config
  var db: OpaquePointer?
  init(_ c: Config) throws {
    config = c
    guard !c.allowedChatIds.isEmpty else {
      throw Failure("Explicit nonempty allowedChatIds required")
    }
    let path = c.database ?? NSHomeDirectory() + "/Library/Messages/chat.db"
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    else {
      throw Failure("Cannot open Messages database read-only; Full Disk Access may be required")
    }
    sqlite3_busy_timeout(db, 2000)
  }
  deinit { sqlite3_close(db) }
  func query(_ sql: String, _ args: [String] = []) throws -> [[String: Any]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw Failure("Scoped database query unavailable on this schema")
    }
    defer { sqlite3_finalize(stmt) }
    for (i, v) in args.enumerated() {
      sqlite3_bind_text(
        stmt, Int32(i + 1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    var rows = [[String: Any]]()
    var status = sqlite3_step(stmt)
    while status == SQLITE_ROW {
      var row = [String: Any]()
      for i in 0..<sqlite3_column_count(stmt) {
        let key = String(cString: sqlite3_column_name(stmt, i))
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: row[key] = sqlite3_column_int64(stmt, i)
        case SQLITE_FLOAT: row[key] = sqlite3_column_double(stmt, i)
        case SQLITE_TEXT: row[key] = String(cString: sqlite3_column_text(stmt, i))
        case SQLITE_BLOB:
          if let bytes = sqlite3_column_blob(stmt, i) {
            row[key] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
              .base64EncodedString()
          }
        default: row[key] = NSNull()
        }
      }
      rows.append(row)
      status = sqlite3_step(stmt)
    }
    guard status == SQLITE_DONE else { throw Failure("Scoped database read failed") }
    return rows
  }
  func chat(_ id: String) throws -> [String: Any] {
    guard config.allowedChatIds.contains(id) else { throw Failure("chat_forbidden") }
    guard
      let row = try query("SELECT guid,chat_identifier,service_name FROM chat WHERE guid=?", [id])
        .first
    else { throw Failure("Permitted chat not found") }
    guard row["service_name"] as? String == "iMessage" else {
      throw Failure("Rich operations require iMessage")
    }
    return row
  }
  let join =
    " FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE c.guid=?"
  func messages(_ chat: String, query: String? = nil, id: String? = nil) throws -> [[String: Any]] {
    _ = try self.chat(chat)
    var args = [chat]
    var filter = ""
    if let id {
      filter += " AND m.guid=?"
      args.append(id)
    }
    if let query {
      filter += " AND m.text LIKE ?"
      args.append("%" + query + "%")
    }
    let columns =
      "SELECT m.ROWID AS rowId,m.guid AS id,m.text,m.is_from_me,m.date,m.date_delivered,m.date_read,m.date_edited,m.date_retracted,m.error AS nativeError,m.is_sent,m.is_delivered,m.associated_message_guid,m.associated_message_type,m.expressive_send_style_id,m.attributedBody,m.message_summary_info,m.thread_originator_guid,m.cache_has_attachments"
    return try self.query(columns + join + filter + " ORDER BY m.ROWID DESC LIMIT 50", args).map {
      row in
      var r = row
      if let b = row["attributedBody"] as? String, let data = Data(base64Encoded: b),
        let str = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString
      {
        r["text"] = str.string
        var runs = [[String: Any]]()
        str.enumerateAttributes(in: NSRange(location: 0, length: str.length)) {
          attributes, range, _ in
          runs.append([
            "start": range.location, "length": range.length,
            "attributes": attributes.mapValues { String(describing: $0) },
          ])
        }
        r["attributeRuns"] = runs
      }
      if let b = row["message_summary_info"] as? String, let data = Data(base64Encoded: b),
        let summary = (try? PropertyListSerialization.propertyList(from: data, format: nil))
          as? [String: Any]
      {
        r["retractedParts"] = summary["rp"] as? [Int] ?? []
        r["editCount"] =
          (summary["ec"] as? [String: [Any]])?.values.map { max(0, $0.count - 1) }.max() ?? 0
      }
      r.removeValue(forKey: "attributedBody")
      r.removeValue(forKey: "message_summary_info")
      return r
    }
  }
  func reactions(_ chat: String, _ id: String) throws -> [[String: Any]] {
    _ = try self.chat(chat)
    return try query(
      "SELECT m.guid AS id,m.associated_message_type AS type,m.is_from_me,m.associated_message_emoji AS emoji"
        + join + " AND m.associated_message_guid IN (?,?) ORDER BY m.ROWID DESC LIMIT 30",
      [chat, id, "p:0/" + id])
  }
  func message(_ chat: String, _ id: String, own: Bool = false, maxAge: Double? = nil) throws
    -> [String: Any]
  {
    guard let row = try messages(chat, id: id).first else {
      throw Failure("Message is not in permitted chat")
    }
    if own && (row["is_from_me"] as? Int64 != 1) {
      throw Failure("Only own messages can be edited or unsent")
    }
    if let maxAge, let raw = row["date"] as? Int64 {
      let date = Double(raw) / 1_000_000_000 + 978_307_200
      guard Date().timeIntervalSince1970 - date < maxAge else {
        throw Failure("Apple operation time window expired")
      }
    }
    return row
  }
}
@MainActor final class ScopedUI {
  let db: ScopedDatabase
  init(_ db: ScopedDatabase) { self.db = db }
  func attr(_ e: AXUIElement, _ key: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success else { return nil }
    return v
  }
  func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }
  // Never traverse conversation rows. Search structural attributes first; no whole-app snapshots.
  func nodes(_ e: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 16 else { return [] }
    let id = attr(e, "AXIdentifier") as? String ?? ""
    if ["ConversationList", "CKConversationListCollectionView"].contains(id)
      || children(e).contains(where: {
        ["ConversationList", "CKConversationListCollectionView"].contains(
          attr($0, "AXIdentifier") as? String ?? "")
      })
    {
      return []
    }
    if attr(e, "AXRole") as? String == "AXMenuBar" {
      return children(e).filter { attr($0, "AXTitle") as? String == "Format" }.flatMap {
        nodes($0, depth: depth + 1)
      }
    }
    return [e] + children(e).prefix(150).flatMap { nodes($0, depth: depth + 1) }
  }
  func app() throws -> AXUIElement {
    guard db.config.enableUI == true, AXIsProcessTrusted() else {
      throw Failure("Scoped UI requires explicit enableUI and Accessibility permission")
    }
    guard
      let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.MobileSMS"
      ).first
    else { throw Failure("Messages is not running") }
    return AXUIElementCreateApplication(app.processIdentifier)
  }
  func window() throws -> AXUIElement {
    let root = try app()
    let windows = (attr(root, "AXWindows") as? [AXUIElement] ?? []).filter {
      attr($0, "AXIdentifier") as? String == "SceneWindow"
    }
    guard windows.count == 1 else { throw Failure("Expected one Messages SceneWindow") }
    return windows[0]
  }
  func exact(_ root: AXUIElement, _ key: String, _ value: String) throws -> AXUIElement {
    let found = nodes(root).filter {
      attr($0, key) as? String == value
        && !(key == "AXTitle" && value != "Format"
          && attr($0, "AXRole") as? String == "AXMenuBarItem")
    }
    guard found.count == 1 else {
      let observed =
        value.hasPrefix("Effect:")
        ? nodes(root).compactMap { attr($0, "AXDescription") as? String }.filter {
          $0.hasPrefix("Effect:")
        } : []
      throw Failure(
        "Expected one \(key)=\(value); found \(found.count); picker labels: \(observed)")
    }
    return found[0]
  }
  func waitInApp(_ key: String, _ value: String) throws -> AXUIElement {
    for _ in 0..<70 {
      if let root = try? app(), let result = try? exact(root, key, value) { return result }
      pause(0.025)
    }
    return try exact(try app(), key, value)
  }
  func waitInWindow(_ key: String, _ value: String) throws -> AXUIElement {
    for _ in 0..<50 {
      if let w = try? window(), let result = try? exact(w, key, value) { return result }
      pause(0.03)
    }
    return try exact(try window(), key, value)
  }
  func action(_ node: AXUIElement, _ name: String) throws {
    guard AXUIElementPerformAction(node, name as CFString) == .success else {
      throw Failure("Native action failed: \(name)")
    }
  }
  func set(_ node: AXUIElement, _ key: String, _ value: CFTypeRef) throws {
    guard AXUIElementSetAttributeValue(node, key as CFString, value) == .success else {
      throw Failure("Native attribute failed: \(key)")
    }
  }
  func open(_ chat: String, message: String? = nil) throws {
    let root = try app()  // Enforce enableUI before opening any conversation.
    if let format = try? exact(root, "AXTitle", "Format"),
      attr(format, "AXSelected") as? Bool == true
    {
      try action(format, "AXCancel")
      pause(0.1)
      guard attr(format, "AXSelected") as? Bool != true else {
        throw Failure(
          "Native Format menu is still tracking input; close that menu before continuing")
      }
    }
    let row = try db.chat(chat)
    var u = URLComponents()
    u.scheme = "imessage"
    u.path = "open"
    if let message {
      _ = try db.message(chat, message)
      u.queryItems = [URLQueryItem(name: "message-guid", value: message)]
    } else {
      u.queryItems = [
        URLQueryItem(
          name: chat.contains(";+;") ? "groupid" : "address",
          value: row["chat_identifier"] as? String)
      ]
    }
    guard let url = u.url, NSWorkspace.shared.open(url) else {
      throw Failure("Unable to open permitted conversation")
    }
    pause(0.45)
    if let w = try? boundWindow(chat),
      (try? exact(w, "AXIdentifier", "TapbackPickerCollectionView")) != nil
    {
      try key(53)
      pause(0.15)
    }
  }
  func digits(_ s: String) -> String { s.filter { $0.isNumber } }
  func boundWindow(_ chat: String) throws -> AXUIElement {
    let row = try db.chat(chat)
    let recipient = row["chat_identifier"] as? String ?? ""
    guard chat.contains(";-;") else {
      throw Failure("Restricted UI currently requires a direct conversation")
    }
    let w = try window()
    // Compose recipient chips are authoritative addresses. Never accept a contact display name.
    let popups = nodes(w).filter { attr($0, "AXRole") as? String == "AXPopUpButton" }
    for p in popups where popups.count == 1 {
      let d = attr(p, "AXDescription") as? String ?? ""
      let fields = d.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
      if fields.contains(recipient) { return w }
    }
    if !popups.isEmpty {
      throw Failure("Recipient chips do not match exactly one permitted address")
    }
    // Established direct chats may expose the exact phone/email in their window title.
    let title = attr(w, "AXTitle") as? String ?? ""
    let phoneCharacters = CharacterSet.decimalDigits.union(.whitespaces).union(
      CharacterSet(charactersIn: "+()-"))
    let phoneTitle = title.unicodeScalars.allSatisfy { phoneCharacters.contains($0) }
    if title == recipient
      || (recipient.hasPrefix("+") && phoneTitle && digits(title) == digits(recipient))
    {
      return w
    }
    throw Failure(
      "Cannot verify exact recipient in Messages UI; refusing transcript read or mutation")
  }
  func snapshot(_ chat: String, view: String = "transcript", messageID: String? = nil) throws
    -> [String: Any]
  {
    if let messageID { _ = try db.message(chat, messageID) }
    try open(chat, message: messageID)
    let w = try boundWindow(chat)
    func walk(_ e: AXUIElement, _ depth: Int) -> [String: Any] {
      var r = [String: Any]()
      for k in ["AXRole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue"] {
        if let v = attr(e, k), v is String || v is NSNumber { r[k] = v }
      }
      var names: CFArray?
      AXUIElementCopyActionNames(e, &names)
      r["actions"] = names as? [String] ?? []
      if depth < 7 { r["children"] = children(e).prefix(100).map { walk($0, depth + 1) } }
      return r
    }
    var roots = nodes(w).filter {
      ["TranscriptCollectionView", "MessageEntryView"].contains(
        attr($0, "AXIdentifier") as? String ?? "")
    }
    if view == "apps" || view == "effects" {
      try action(
        try exact(try exact(w, "AXIdentifier", "MessageEntryView"), "AXDescription", "add"),
        "AXPress")
      pause(0.2)
      if view == "effects" {
        try action(try waitInApp("AXTitle", "Message Effects"), "AXPress")
        pause(0.25)
      }
      roots = nodes(w).filter { attr($0, "AXRole") as? String == "AXMenu" }
    }
    if view == "message-menu" {
      guard let id = messageID else { throw Failure("messageId required") }
      let row = try db.message(chat, id)
      let target = try target(w, row)
      try action(target, "AXShowMenu")
      pause(0.2)
      roots = nodes(w).filter { attr($0, "AXRole") as? String == "AXMenu" }
    }
    if view == "format" {
      let f = try exact(try app(), "AXTitle", "Format")
      // The menu exposes its command tree without starting a tracking session.
      roots = [f]
    }
    return [
      "chatId": chat, "scope": "permitted-transcript-and-composer-only",
      "trees": roots.map { walk($0, 0) },
    ]
  }
  func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
    guard CGPreflightPostEventAccess() else {
      throw Failure(
        "Native keyboard event posting is not authorized for this execution environment")
    }
    guard
      let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.MobileSMS"
      ).first,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier
    else { throw Failure("Messages lost focus") }
    for down in [true, false] {
      guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
        throw Failure("Key unavailable")
      }
      e.flags = flags
      e.post(tap: .cghidEventTap)
      if down { pause(0.04) }
    }
    pause(0.08)
  }
  func media(_ chat: String, _ path: String) throws -> [String: Any] {
    guard db.config.enableUI == true, let workspace = db.config.workspace else {
      throw Failure("Scoped media requires an explicitly enrolled workspace")
    }
    let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
    let file =
      (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
      .resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path)
    else { throw Failure("Media must be a file inside enrolled workspace") }
    let row = try db.chat(chat)
    guard chat.contains(";-;") else {
      throw Failure("Scoped attachment sending requires direct chat")
    }
    let recipient = row["chat_identifier"] as? String ?? ""
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
      "messagepilot-media-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let staged = staging.appendingPathComponent(file.lastPathComponent)
    try FileManager.default.copyItem(at: file, to: staged)
    let previous = (try db.messages(chat)).compactMap { $0["rowId"] as? Int64 }.max() ?? 0
    func quote(_ s: String) -> String {
      "\""
        + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "\"", with: "\\\"") + "\""
    }
    let source =
      "tell application \"Messages\"\nset svc to first service whose service type is iMessage\nset recipient to buddy "
      + quote(recipient) + " of svc\nsend POSIX file " + quote(staged.path)
      + " to recipient\nend tell"
    guard let script = NSAppleScript(source: source) else {
      throw Failure("Attachment AppleScript failed to compile")
    }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    guard error == nil else {
      throw Failure("Messages attachment automation failed; check Automation permission")
    }
    for _ in 0..<250 {
      if let sent = try db.messages(chat).first(where: {
        ($0["rowId"] as? Int64 ?? 0) > previous && $0["is_from_me"] as? Int64 == 1
          && $0["cache_has_attachments"] as? Int64 == 1
      }) {
        if let error = sent["nativeError"] as? Int64, error != 0 {
          throw Failure("Native attachment failed with Apple error \(error)")
        }
        if sent["is_sent"] as? Int64 == 1 {
          return [
            "receipt": "native-attachment-sent", "message": sent, "delivery": "inspect-timestamps",
          ]
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    throw Failure("Attachment submitted but not observed in permitted chat; outcome unknown")
  }
  func send(_ chat: String, _ p: [String: Any], format: Bool = false, effect: Bool = false) throws
    -> [String: Any]
  {
    let reply = p["replyTo"] as? String
    if let reply { _ = try db.message(chat, reply) }
    try open(chat, message: reply)
    let w = try boundWindow(chat)
    if let reply {
      let initial = try waitInWindow("AXIdentifier", "messageBodyField")
      guard (attr(initial, "AXValue") as? String ?? "").isEmpty else {
        throw Failure("Composer contains a draft")
      }
      let row = try db.message(chat, reply)
      let node = try target(w, row)
      var names: CFArray?
      AXUIElementCopyActionNames(node, &names)
      guard let name = (names as? [String] ?? []).first(where: { $0.hasPrefix("Name:Reply") })
      else { throw Failure("Native reply action unavailable") }
      try action(node, name)
      pause(0.25)
    }
    let composer = try waitInWindow("AXIdentifier", "messageBodyField")
    let existing = attr(composer, "AXValue") as? String ?? ""
    guard existing.isEmpty else { throw Failure("Composer contains a draft; refusing overwrite") }
    let text = try required(p, "text")
    let previous = (try db.messages(chat)).compactMap { $0["rowId"] as? Int64 }.max() ?? 0
    try set(composer, "AXValue", text as CFString)
    try set(composer, "AXFocused", kCFBooleanTrue)
    if format || (effect && p["kind"] as? String == "text") {
      let range = p["range"] as? [String: Int] ?? [:]
      var r = CFRange(
        location: range["start"] ?? 0, length: range["length"] ?? (text as NSString).length)
      guard r.location >= 0, r.length > 0, r.location + r.length <= (text as NSString).length,
        let v = AXValueCreate(.cfRange, &r)
      else { throw Failure("Invalid text range") }
      try set(composer, "AXSelectedTextRange", v)
      let items =
        format
        ? Array(Set(p["styles"] as? [String] ?? [])).sorted().map {
          [
            "bold": "Bold", "italic": "Italic", "underline": "Underline",
            "strikethrough": "Strikethrough",
          ][$0] ?? ""
        } : [try required(p, "effect")]
      for item in items {
        _ = try boundWindow(chat)
        try action(try exact(try app(), "AXTitle", item), "AXPress")
        pause(0.18)
        try action(try exact(try app(), "AXTitle", "Format"), "AXCancel")
        pause(0.05)
      }
    } else if effect {
      let buttons = nodes(w).filter {
        attr($0, "AXRole") as? String == "AXButton"
          && ["Apps", "add"].contains(attr($0, "AXDescription") as? String ?? "")
      }
      guard buttons.count == 1 else { throw Failure("Apps button needs calibration") }
      try action(buttons[0], "AXPress")
      pause(0.15)
      try action(try waitInApp("AXTitle", "Message Effects"), "AXPress")
      pause(0.2)
      try action(
        try waitInWindow("AXDescription", "Effect: " + (try required(p, "effect"))), "AXPress")
      pause(0.15)
    }
    if effect && p["kind"] as? String != "text" {
      let preview = try exact(try window(), "AXIdentifier", "CKBalloonTextView")
      guard attr(preview, "AXValue") as? String == text else {
        throw Failure("Effect preview differs from authored text")
      }
      let send = try exact(try window(), "AXIdentifier", "sendButton")
      guard
        (attr(send, "AXDescription") as? String ?? "").lowercased() == "send with "
          + (try required(p, "effect")).lowercased() + " effect"
      else { throw Failure("Effect send button does not confirm selected effect") }
      try action(send, "AXPress")
    } else {
      _ = try boundWindow(chat)
      try set(composer, "AXFocused", kCFBooleanTrue)
      var insertion = CFRange(location: (text as NSString).length, length: 0)
      if let position = AXValueCreate(.cfRange, &insertion) {
        try set(composer, "AXSelectedTextRange", position)
      }
      pause(0.15)
      guard attr(composer, "AXFocused") as? Bool == true else {
        throw Failure("Composer did not regain focus after formatting")
      }
      try key(36)
    }
    for _ in 0..<30 {
      if let sent = try db.messages(chat).first(where: {
        ($0["rowId"] as? Int64 ?? 0) > previous && $0["is_from_me"] as? Int64 == 1
          && $0["text"] as? String == text
      }) {
        return [
          "receipt": "native-message-observed", "message": sent, "delivery": "inspect-timestamps",
        ]
      }
      pause(0.1)
    }
    throw Failure("Send submitted but native message not observed; outcome unknown")
  }
  func target(_ w: AXUIElement, _ row: [String: Any]) throws -> AXUIElement {
    let transcript = try waitInWindow("AXIdentifier", "TranscriptCollectionView")
    let text = row["text"] as? String ?? ""
    guard !text.isEmpty else { throw Failure("Scoped mutation requires identifiable text") }
    let own = row["is_from_me"] as? Int64 == 1
    let matches = nodes(transcript).filter { e in
      guard attr(e, "AXValue") as? String == text, let p = attr(e, "AXParent") else { return false }
      let desc = attr((p as! AXUIElement), "AXDescription") as? String ?? ""
      return desc.hasPrefix("Your iMessage,") == own
    }
    guard matches.count == 1 else { throw Failure("Message target is ambiguous or not visible") }
    return matches[0]
  }
  func mutate(_ method: String, _ chat: String, _ p: [String: Any]) throws -> [String: Any] {
    let id = try required(p, "messageId")
    let row = try db.message(
      chat, id, own: ["messages.edit", "messages.unsend"].contains(method),
      maxAge: method == "messages.unsend" ? 120 : method == "messages.edit" ? 900 : nil)
    if method == "messages.edit", (row["editCount"] as? Int ?? 0) >= 5 {
      throw Failure("Apple edit count limit reached")
    }
    let codes = [
      "love": 2000, "heart": 2000, "like": 2001, "dislike": 2002, "laugh": 2003, "emphasize": 2004,
      "question": 2005,
    ]
    let desired = codes[p["reaction"] as? String ?? ""]
    if let desired, ["messages.react", "messages.unreact"].contains(method) {
      let current =
        try db.reactions(chat, id).first(where: { $0["is_from_me"] as? Int64 == 1 })?["type"]
        as? Int64
      if (method == "messages.react" && current == Int64(desired))
        || (method == "messages.unreact" && current != Int64(desired))
      {
        return ["receipt": "already-in-requested-state", "reactions": try db.reactions(chat, id)]
      }
    }
    try open(chat, message: id)
    let w = try boundWindow(chat)
    let text = row["text"] as? String ?? ""
    guard !text.isEmpty else {
      throw Failure("Scoped mutation currently requires an identifiable text message")
    }
    var node = try target(w, row)
    for _ in 0..<5 {
      var names: CFArray?
      AXUIElementCopyActionNames(node, &names)
      if (names as? [String] ?? []).contains("AXShowMenu") { break }
      guard let p = attr(node, "AXParent") else { break }
      node = (p as! AXUIElement)
    }
    let label =
      method == "messages.edit"
      ? "Edit" : method == "messages.unsend" ? "Undo Send" : "Tapback Details…"
    var names: CFArray?
    AXUIElementCopyActionNames(node, &names)
    if let direct = (names as? [String] ?? []).first(where: { $0.hasPrefix("Name:" + label + "\n") }
    ) {
      try action(node, direct)
    } else {
      try action(node, "AXShowMenu")
      pause(0.15)
      try action(try exact(try app(), "AXTitle", label), "AXPress")
    }
    pause(0.2)
    if method == "messages.edit" {
      let fields = nodes(w).filter { e in
        var editable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(e, "AXValue" as CFString, &editable)
        return editable.boolValue
          && ["AXTextField", "AXTextArea"].contains(attr(e, "AXRole") as? String ?? "")
          && attr(e, "AXIdentifier") as? String != "messageBodyField"
          && attr(e, "AXValue") as? String == text
      }
      guard fields.count == 1 else { throw Failure("Edit field requires calibration") }
      try set(fields[0], "AXValue", try required(p, "text") as CFString)
      try set(fields[0], "AXFocused", kCFBooleanTrue)
      pause(0.25)
      try action(try exact(w, "AXDescription", "Send edit"), "AXPress")
    } else if method == "messages.react" || method == "messages.unreact" {
      let r = try required(p, "reaction")
      let identifier =
        [
          "love": "heart", "heart": "heart", "like": "thumbsUp", "dislike": "thumbsDown",
          "laugh": "ha", "emphasize": "exclamation", "question": "questionMark",
        ][r] ?? r
      let picker = try waitInWindow("AXIdentifier", "TapbackPickerCollectionView")
      pause(0.6)
      try action(try exact(picker, "AXIdentifier", identifier), "AXPress")
      if let desired {
        let expected = method == "messages.unreact" ? desired + 1000 : desired
        var confirmed = false
        for _ in 0..<40 {
          let rows = try db.reactions(chat, id)
          if rows.first(where: { $0["is_from_me"] as? Int64 == 1 })?["type"] as? Int64
            == Int64(expected)
          {
            confirmed = true
            break
          }
          pause(0.075)
        }
        guard confirmed else {
          throw Failure("Tapback action submitted but expected native reaction state not observed")
        }
      }
    }
    pause(0.3)
    return [
      "receipt": "ui-action-submitted", "message": try db.message(chat, id),
      "reactions": try db.reactions(chat, id), "delivery": "inspect-native-state",
    ]
  }
}
@main struct Main {
  @MainActor static func main() {
    do {
      let args = CommandLine.arguments
      guard args.contains("--live"), let i = args.firstIndex(of: "--config"),
        args.indices.contains(i + 1)
      else {
        print("messagepilot-scoped --live --config <scoped-account.json>")
        return
      }
      let c = try JSONDecoder().decode(
        Config.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
      guard NSUserName() == c.expectedOSUser else { throw Failure("OS user mismatch") }
      let db = try ScopedDatabase(c)
      let ui = ScopedUI(db)
      while let line = readLine() {
        var id = "invalid"
        do {
          guard line.utf8.count < 1_048_576, let data = line.data(using: .utf8),
            let r = try JSONSerialization.jsonObject(with: data) as? [String: Any]
          else { throw Failure("Invalid request") }
          id = try required(r, "id")
          let method = try required(r, "method")
          let p = r["params"] as? [String: Any] ?? [:]
          if p["cursor"] != nil {
            throw Failure("Scoped native pagination is not implemented; use explicit scoped search")
          }
          let result: Any
          if method == "identity" {
            result =
              [
                "identity": c.expectedIdentity, "allowedChatIds": c.allowedChatIds,
                "evidence":
                  "explicit-chat-enrollment-and-os-user; Apple sender identity not independently verified",
              ] as [String: Any]
          } else if method == "capabilities" {
            result = [
              "messages.list", "messages.search", "chats.read", "messages.send", "messages.effect",
              "messages.format", "messages.inspect", "messages.draft.discard", "messages.edit",
              "messages.unsend", "messages.react", "messages.unreact",
            ].map {
              [
                "operation": $0,
                "available": c.enableUI == true
                  || ["messages.list", "messages.search"].contains($0),
                "path": "chat-restricted-native", "verification": "compiled",
              ] as [String: Any]
            }
          } else {
            let chat = try required(p, "chatId")
            _ = try db.chat(chat)
            if p["selectors"] != nil {
              throw Failure("Restricted commands cannot override selectors")
            }
            if let reply = p["replyTo"] as? String { _ = try db.message(chat, reply) }
            switch method {
            case "chats.read":
              try ui.open(chat)
              _ = try ui.boundWindow(chat)
              pause(0.25)
              result = [
                "receipt": "permitted-chat-opened", "delivery": "read-receipts-depend-on-settings",
              ]
            case "messages.list": result = ["items": try db.messages(chat)]
            case "messages.search":
              result = ["items": try db.messages(chat, query: try required(p, "query"))]
            case "messages.inspect":
              result = try ui.snapshot(
                chat, view: p["view"] as? String ?? "transcript",
                messageID: p["messageId"] as? String)
            case "messages.draft.discard":
              try ui.open(chat)
              let candidate = try ui.window()
              if let preview = try? ui.exact(candidate, "AXIdentifier", "CKBalloonTextView"),
                ui.attr(preview, "AXValue") as? String == (try required(p, "expectedText")),
                let close = try? ui.exact(candidate, "AXIdentifier", "closeButton"),
                ui.attr(close, "AXDescription") as? String == "Cancel effect"
              {
                try ui.action(close, "AXPress")
                pause(0.6)
              }
              _ = try ui.boundWindow(chat)
              let composer = try ui.waitInWindow("AXIdentifier", "messageBodyField")
              guard ui.attr(composer, "AXValue") as? String == (try required(p, "expectedText"))
              else { throw Failure("Draft differs from expected authored text") }
              try ui.set(composer, "AXValue", "" as CFString)
              result = ["discarded": true]
            case "messages.send", "messages.effect", "messages.format":
              if let path = p["filePath"] as? String {
                guard method == "messages.send", p["text"] == nil else {
                  throw Failure("Send scoped media and text as separate commands")
                }
                result = try ui.media(chat, path)
              } else {
                result = try ui.send(
                  chat, p, format: method == "messages.format", effect: method == "messages.effect")
              }
            case "messages.edit", "messages.unsend", "messages.react", "messages.unreact":
              result = try ui.mutate(method, chat, p)
            default: throw Failure("Operation unavailable in chat-restricted worker")
            }
          }
          write(["id": id, "result": result])
        } catch { write(["id": id, "error": String(describing: error)]) }
      }
    } catch {
      fputs("Scoped worker: \(error)\n", stderr)
      exit(1)
    }
  }
  static func write(_ o: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys) {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data([10]))
    }
  }
}
