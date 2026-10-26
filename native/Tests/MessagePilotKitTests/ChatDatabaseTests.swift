import AppKit
import Foundation
import SQLite3
import XCTest

@testable import MessagePilotKit

/// A chat.db with the macOS 26 columns MessagePilot reads, filled with synthetic rows.
final class ChatDatabaseTests: XCTestCase {
  var path = ""
  var attachmentDir = ""
  let chatGUID = "iMessage;-;+15550100100"
  let groupGUID = "iMessage;+;chat123456"

  override func setUpWithError() throws {
    path = NSTemporaryDirectory() + "chat-\(UUID().uuidString).db"
    attachmentDir = NSTemporaryDirectory() + "att-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: attachmentDir, withIntermediateDirectories: true)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: attachmentDir + "/sticker.heic"))
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
    exec(
      """
      CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT, style INTEGER, group_id TEXT, account_login TEXT);
      CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
      CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
      CREATE TABLE message(ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, handle_id INTEGER, is_from_me INTEGER, date INTEGER, date_delivered INTEGER, date_read INTEGER, is_sent INTEGER, is_delivered INTEGER, associated_message_guid TEXT, associated_message_type INTEGER, associated_message_emoji TEXT, date_edited INTEGER, date_retracted INTEGER, thread_originator_guid TEXT, schedule_type INTEGER DEFAULT 0, schedule_state INTEGER DEFAULT 0, is_forward INTEGER DEFAULT 0, balloon_bundle_id TEXT, expressive_send_style_id TEXT, is_audio_message INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0, error INTEGER DEFAULT 0, attributedBody BLOB, message_summary_info BLOB, item_type INTEGER DEFAULT 0, group_title TEXT, group_action_type INTEGER DEFAULT 0, other_handle INTEGER DEFAULT 0);
      CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT, is_sticker INTEGER, hide_attachment INTEGER, uti TEXT, transfer_state INTEGER, total_bytes INTEGER);
      CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
      INSERT INTO chat VALUES(1,'\(chatGUID)','+15550100100','iMessage',NULL,45,NULL,'E:line@example.com');
      INSERT INTO chat VALUES(2,'\(groupGUID)','chat123456','iMessage','Fixture Group',43,'G1','E:line@example.com');
      INSERT INTO handle VALUES(1,'+15550100100','iMessage'),(2,'friend@example.com','iMessage');
      INSERT INTO chat_handle_join VALUES(1,1),(2,1),(2,2);
      """)
    let now = ChatDatabase.raw(Date())
    let later = ChatDatabase.raw(Date().addingTimeInterval(3600))
    let rows: [(Int, String, String?, Int, Int, Int64, String?, Int, String?, Int, Int)] = [
      // rowid, guid, text, handle, fromMe, date, assocGUID, assocType, emoji, scheduleType, isForward
      (1, "M1", "hello there", 1, 0, now, nil, 0, nil, 0, 0),
      (2, "R1", nil, 0, 1, now, "p:0/M1", 2000, nil, 0, 0),
      (3, "R2", nil, 0, 1, now, "p:0/M1", 2006, "🔥", 0, 0),
      (4, "R3", nil, 1, 0, now, "p:0/M1", 2007, nil, 0, 0),
      (5, "S1", "see you tomorrow", 0, 1, later, nil, 0, nil, 2, 0),
      (6, "F1", "hello there", 0, 1, now, nil, 0, nil, 0, 1),
      (7, "A1", "\u{fffc}", 1, 0, now, nil, 0, nil, 0, 0),
    ]
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(
      db,
      "INSERT INTO message(ROWID,guid,text,handle_id,is_from_me,date,associated_message_guid,associated_message_type,associated_message_emoji,schedule_type,schedule_state,is_forward,attributedBody,cache_has_attachments) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      -1, &stmt, nil)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for r in rows {
      sqlite3_reset(stmt)
      sqlite3_bind_int(stmt, 1, Int32(r.0))
      sqlite3_bind_text(stmt, 2, r.1, -1, transient)
      if let t = r.2 { sqlite3_bind_text(stmt, 3, t, -1, transient) } else { sqlite3_bind_null(stmt, 3) }
      sqlite3_bind_int(stmt, 4, Int32(r.3))
      sqlite3_bind_int(stmt, 5, Int32(r.4))
      sqlite3_bind_int64(stmt, 6, r.5)
      if let a = r.6 { sqlite3_bind_text(stmt, 7, a, -1, transient) } else { sqlite3_bind_null(stmt, 7) }
      sqlite3_bind_int(stmt, 8, Int32(r.7))
      if let e = r.8 { sqlite3_bind_text(stmt, 9, e, -1, transient) } else { sqlite3_bind_null(stmt, 9) }
      sqlite3_bind_int(stmt, 10, Int32(r.9))
      sqlite3_bind_int(stmt, 11, r.9 == 2 ? 1 : 0)
      sqlite3_bind_int(stmt, 12, Int32(r.10))
      if r.1 == "M1" {
        // attributedBody with a confirmed mention over "there", as Messages persists it.
        let body = NSMutableAttributedString(string: "hello there")
        body.addAttribute(
          NSAttributedString.Key("__kIMMentionConfirmedMention"), value: "+15550100100",
          range: NSRange(location: 6, length: 5))
        let data = AttributedBody.encode(body)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 13, $0.baseAddress, Int32(data.count), transient) }
      } else {
        sqlite3_bind_null(stmt, 13)
      }
      sqlite3_bind_int(stmt, 14, r.1 == "A1" ? 1 : 0)
      XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }
    sqlite3_finalize(stmt)
    exec(
      """
      INSERT INTO chat_message_join VALUES(1,1),(1,2),(1,3),(1,4),(1,5),(1,7),(2,6);
      INSERT INTO attachment VALUES(1,'AT1','\(attachmentDir)/sticker.heic','image/heic','sticker.heic',1,0,'public.heic',5,4);
      INSERT INTO attachment VALUES(2,'AT2','~/Library/Messages/Attachments/xx/never-downloaded.jpg','image/jpeg','photo.jpg',0,0,'public.jpeg',0,1234);
      INSERT INTO message_attachment_join VALUES(7,1),(7,2);
      """)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: attachmentDir)
  }

  func testAccountLoginsAndChatResolution() throws {
    let db = try ChatDatabase(path: path)
    XCTAssertEqual(try db.accountLogins(), ["E:line@example.com"])
    // Beeper exposes "any;-;…" thread IDs on macOS 26; chat.db may store a service prefix.
    XCTAssertEqual(try db.resolveChatGUID("any;-;+15550100100"), chatGUID)
    XCTAssertNil(try db.resolveChatGUID("any;-;+15550109999"))
    let group = try XCTUnwrap(try db.chat(groupGUID))
    XCTAssertEqual(group["isGroup"] as? Bool, true)
    XCTAssertEqual(group["participants"] as? [String], ["+15550100100", "friend@example.com"])
    XCTAssertEqual(try db.chat(chatGUID)?["isGroup"] as? Bool, false)
  }

  func testMessageDecodesMentionsFromAttributedBody() throws {
    let db = try ChatDatabase(path: path)
    let m = try XCTUnwrap(try db.message(guid: "M1"))
    XCTAssertEqual(m["text"] as? String, "hello there")
    let mentions = try XCTUnwrap(m["mentions"] as? [[String: Any]])
    XCTAssertEqual(mentions.count, 1)
    XCTAssertEqual(mentions[0]["handle"] as? String, "+15550100100")
    XCTAssertEqual(mentions[0]["start"] as? Int, 6)
    XCTAssertEqual(try db.message(guid: "F1")?["is_forward"] as? Int64, 1)
  }

  func testReactionsIncludeEmojiAndStickerTapbacks() throws {
    let db = try ChatDatabase(path: path)
    let rows = try db.reactions(to: "M1")
    XCTAssertEqual(rows.map(\.type), [2000, 2006, 2007])
    XCTAssertEqual(rows[1].emoji, "🔥")
    XCTAssertEqual(rows[2].sender, "+15550100100")
    let current = ReactionState.current(rows)
    XCTAssertEqual(current.map(\.guid), ["R2", "R3"], "My emoji replaced my heart; their sticker stays")
    XCTAssertThrowsError(try db.reactions(to: "M1' OR 1=1 --"))
  }

  func testScheduledMessagesAreListedSeparately() throws {
    let db = try ChatDatabase(path: path)
    let scheduled = try db.scheduled(chat: chatGUID)
    XCTAssertEqual(scheduled.map { $0["guid"] as? String }, ["S1"])
    XCTAssertEqual(scheduled[0]["state"] as? String, "pending")
    let when = ISO8601DateFormatter().date(from: scheduled[0]["scheduledFor"] as? String ?? "")
    XCTAssertNotNil(when)
    XCTAssertGreaterThan(when!.timeIntervalSinceNow, 3000)
    XCTAssertEqual(try db.scheduled(chat: groupGUID).count, 0)
  }

  func testAttachmentsResolvePathsAndStickerFlag() throws {
    let db = try ChatDatabase(path: path)
    let atts = try db.attachments(message: "A1")
    XCTAssertEqual(atts.count, 2)
    XCTAssertEqual(atts[0]["isSticker"] as? Bool, true)
    XCTAssertEqual(atts[0]["exists"] as? Bool, true)
    XCTAssertEqual(atts[0]["downloaded"] as? Bool, true)
    XCTAssertEqual(atts[1]["exists"] as? Bool, false)
    XCTAssertEqual(atts[1]["downloaded"] as? Bool, false)
    XCTAssertTrue((atts[1]["path"] as? String ?? "").hasPrefix(NSHomeDirectory()), "~ expanded")
  }

  func testIncrementalReadsForReconciliation() throws {
    let db = try ChatDatabase(path: path)
    XCTAssertEqual(try db.maxRowID(chat: chatGUID), 7)
    XCTAssertEqual(try db.messages(chat: chatGUID, after: 4).map { $0["guid"] as? String }, ["A1", "S1"])
    XCTAssertEqual(try db.chatGUID(forMessage: "F1"), groupGUID)
  }

  func testAppleEpochConversion() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertEqual(ChatDatabase.date(ChatDatabase.raw(date))!.timeIntervalSince1970, 1_800_000_000, accuracy: 0.001)
    XCTAssertEqual(ChatDatabase.date(600_000_000)!.timeIntervalSinceReferenceDate, 600_000_000)
    XCTAssertNil(ChatDatabase.date(0))
  }
}
