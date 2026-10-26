import AppKit
import Foundation

/// Read-only view of Messages' chat.db for reconciliation and for data Beeper's mapper omits:
/// scheduled (Send Later) rows, emoji/sticker Tapback detail, attachment files and forward flags.
public final class ChatDatabase {
  public static var defaultPath: String { NSHomeDirectory() + "/Library/Messages/chat.db" }
  public let reader: SQLiteReader
  public let messageColumns: Set<String>
  public let attachmentColumns: Set<String>

  public init(path: String = ChatDatabase.defaultPath) throws {
    reader = try SQLiteReader(path: path)
    messageColumns = try reader.columns("message")
    attachmentColumns = (try? reader.columns("attachment")) ?? []
  }

  // MARK: Dates

  /// Messages stores nanoseconds (or seconds on very old rows) since 2001-01-01.
  public static func date(_ raw: Int64?) -> Date? {
    guard let raw, raw != 0 else { return nil }
    let seconds = raw > 10_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
    return Date(timeIntervalSinceReferenceDate: seconds)
  }
  public static func raw(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
  }

  // MARK: Accounts and chats

  public func accountLogins() throws -> [String] {
    try reader.rows("SELECT DISTINCT account_login FROM chat WHERE account_login IS NOT NULL")
      .compactMap { $0["account_login"]?.string }
  }

  public func chat(_ guid: String) throws -> [String: Any]? {
    guard
      let row = try reader.rows(
        "SELECT ROWID AS rowId, guid, chat_identifier, service_name, display_name, style, group_id FROM chat WHERE guid=?",
        [guid]
      ).first
    else { return nil }
    let participants = try reader.rows(
      "SELECT h.id AS handle, h.service FROM chat_handle_join chj JOIN handle h ON h.ROWID=chj.handle_id JOIN chat c ON c.ROWID=chj.chat_id WHERE c.guid=? ORDER BY h.ROWID",
      [guid]
    ).compactMap { $0["handle"]?.string }
    var out = row.mapValues(\.json)
    out["participants"] = participants
    // style 43 is a group conversation, 45 a one-to-one conversation.
    out["isGroup"] = row["style"]?.int == 43
    return out
  }

  /// Candidate chat GUIDs for the public thread ID Beeper exposes (`any;-;+1555…` on macOS 26).
  public static func chatGUIDCandidates(_ threadID: String) -> [String] {
    let parts = threadID.split(separator: ";", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { return [threadID] }
    return [threadID] + ["iMessage", "SMS", "RCS", "any"].filter { $0 != parts[0] }.map {
      "\($0);\(parts[1]);\(parts[2])"
    }
  }

  public func resolveChatGUID(_ threadID: String) throws -> String? {
    for candidate in Self.chatGUIDCandidates(threadID)
    where try reader.rows("SELECT 1 FROM chat WHERE guid=?", [candidate]).first != nil {
      return candidate
    }
    return nil
  }

  // MARK: Messages

  var messageSelect: String {
    let optional = [
      "date_edited", "date_retracted", "thread_originator_guid", "associated_message_emoji",
      "schedule_type", "schedule_state", "is_forward", "balloon_bundle_id",
      "expressive_send_style_id", "is_audio_message", "cache_has_attachments", "error",
      "attributedBody", "message_summary_info", "item_type", "group_title", "group_action_type",
      "other_handle",
    ].filter(messageColumns.contains).map { "m.\($0)" }
    return
      (["m.ROWID AS rowId", "m.guid", "m.text", "m.is_from_me", "m.date", "m.date_delivered",
        "m.date_read", "m.is_sent", "m.is_delivered", "m.associated_message_guid",
        "m.associated_message_type", "h.id AS sender"] + optional).joined(separator: ",")
  }

  public func message(guid: String) throws -> [String: Any]? {
    try reader.rows(
      "SELECT \(messageSelect) FROM message m LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE m.guid=?",
      [guid]
    ).first.map(Self.decode)
  }

  public func chatGUID(forMessage guid: String) throws -> String? {
    try reader.rows(
      "SELECT c.guid FROM chat c JOIN chat_message_join j ON j.chat_id=c.ROWID JOIN message m ON m.ROWID=j.message_id WHERE m.guid=?",
      [guid]
    ).first?["guid"]?.string
  }

  public func maxRowID(chat: String) throws -> Int64 {
    try reader.rows(
      "SELECT MAX(m.ROWID) AS top FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE c.guid=?",
      [chat]
    ).first?["top"]?.int ?? 0
  }

  /// Rows in a chat after `rowID`, newest first. Includes scheduled rows.
  public func messages(chat: String, after rowID: Int64, limit: Int = 50) throws -> [[String: Any]]
  {
    try reader.rows(
      "SELECT \(messageSelect) FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE c.guid=? AND m.ROWID>? ORDER BY m.ROWID DESC LIMIT ?",
      [chat, rowID, limit]
    ).map(Self.decode)
  }

  /// Send Later rows. `schedule_type` 2 marks a scheduled send; `schedule_state` tracks it.
  public func scheduled(chat: String?) throws -> [[String: Any]] {
    guard messageColumns.contains("schedule_type") else { return [] }
    var sql =
      "SELECT \(messageSelect), c.guid AS chatGuid FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE COALESCE(m.schedule_type,0)<>0"
    var args: [Any?] = []
    if let chat {
      sql += " AND c.guid=?"
      args.append(chat)
    }
    return try reader.rows(sql + " ORDER BY m.date ASC LIMIT 200", args).map { row in
      var out = Self.decode(row)
      out["chatGuid"] = row["chatGuid"]?.string
      out["scheduledFor"] = (out["date"] as? String)
      out["state"] = Self.scheduleState(row["schedule_state"]?.int)
      return out
    }
  }

  public static func scheduleState(_ raw: Int64?) -> String {
    switch raw {
    case 1: return "pending"
    case 2: return "sending"
    case 3: return "sent"
    case 4: return "failed"
    case 5: return "cancelled"
    default: return "unknown-\(raw ?? -1)"
    }
  }

  // MARK: Reactions

  public func reactions(to guid: String) throws -> [ReactionRow] {
    guard guid.allSatisfy({ $0.isHexDigit || $0 == "-" || $0.isLetter }) else {
      throw KitError("Invalid message GUID")
    }
    let emoji = messageColumns.contains("associated_message_emoji") ? "m.associated_message_emoji" : "NULL"
    return try reader.rows(
      "SELECT m.ROWID AS rowId, m.guid, m.associated_message_type AS type, \(emoji) AS emoji, m.is_from_me, m.date, h.id AS sender FROM message m LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE m.associated_message_guid=? OR m.associated_message_guid LIKE ? ORDER BY m.ROWID",
      [guid, "%/" + guid]
    ).map {
      ReactionRow(
        rowID: $0["rowId"]?.int ?? 0, guid: $0["guid"]?.string ?? "",
        type: Int($0["type"]?.int ?? 0), emoji: $0["emoji"]?.string,
        fromMe: $0["is_from_me"]?.int == 1, sender: $0["sender"]?.string,
        date: Self.date($0["date"]?.int))
    }
  }

  // MARK: Attachments

  public func attachments(message guid: String) throws -> [[String: Any]] {
    let optional = ["is_sticker", "hide_attachment", "uti", "transfer_state", "total_bytes"]
      .filter(attachmentColumns.contains).map { "a.\($0)" }
    let columns =
      (["a.ROWID AS rowId", "a.guid", "a.filename", "a.mime_type", "a.transfer_name"] + optional)
      .joined(separator: ",")
    return try reader.rows(
      "SELECT \(columns) FROM attachment a JOIN message_attachment_join maj ON maj.attachment_id=a.ROWID JOIN message m ON m.ROWID=maj.message_id WHERE m.guid=? ORDER BY a.ROWID",
      [guid]
    ).map { row in
      var out = row.mapValues(\.json)
      if let name = row["filename"]?.string {
        let path = (name as NSString).expandingTildeInPath
        out["path"] = path
        out["exists"] = FileManager.default.fileExists(atPath: path)
      }
      out["isSticker"] = row["is_sticker"]?.int == 1
      // IMFileTransferState: 5 is finished. Other values mean the file is not local yet.
      out["downloaded"] = row["transfer_state"]?.int == 5 || (out["exists"] as? Bool == true)
      return out
    }
  }

  // MARK: Decoding

  public static func decode(_ row: [String: SQLiteReader.Value]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in row where !["attributedBody", "message_summary_info"].contains(key) {
      out[key] = value.json
    }
    for key in ["date", "date_delivered", "date_read", "date_edited", "date_retracted"] {
      if let d = date(row[key]?.int) {
        out[key] = ISO8601DateFormatter().string(from: d)
      } else {
        out[key] = NSNull()
      }
    }
    if let body = row["attributedBody"]?.data, let decoded = AttributedBody.decode(body) {
      out["text"] = decoded.text
      out["attributeRuns"] = decoded.runs
      let mentions = decoded.runs.compactMap { run -> [String: Any]? in
        guard let attrs = run["attributes"] as? [String: String],
          let handle = attrs["__kIMMentionConfirmedMention"]
        else { return nil }
        return ["start": run["start"] ?? 0, "length": run["length"] ?? 0, "handle": handle]
      }
      if !mentions.isEmpty { out["mentions"] = mentions }
    }
    if let summary = row["message_summary_info"]?.data,
      let plist = (try? PropertyListSerialization.propertyList(from: summary, format: nil))
        as? [String: Any]
    {
      out["retractedParts"] = plist["rp"] as? [Int] ?? []
      out["editCount"] =
        (plist["ec"] as? [String: [Any]])?.values.map { max(0, $0.count - 1) }.max() ?? 0
    }
    return out
  }
}

/// Decodes the typedstream `attributedBody` column into text and attribute runs.
public enum AttributedBody {
  public static func decode(_ data: Data) -> (text: String, runs: [[String: Any]])? {
    guard let string = unarchive(data) else { return nil }
    var runs: [[String: Any]] = []
    string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attrs, range, _ in
      runs.append([
        "start": range.location, "length": range.length,
        "attributes": Dictionary(
          uniqueKeysWithValues: attrs.map { ($0.key.rawValue, String(describing: $0.value)) }),
      ])
    }
    return (string.string, runs)
  }

  static func unarchive(_ data: Data) -> NSAttributedString? {
    // Messages writes NSArchiver typedstreams. NSUnarchiver is the only reader for that format.
    if let value = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString { return value }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
  }

  /// Encodes an attributed string the way Messages does; used by tests to build fixtures.
  public static func encode(_ string: NSAttributedString) -> Data {
    NSArchiver.archivedData(withRootObject: string)
  }
}
