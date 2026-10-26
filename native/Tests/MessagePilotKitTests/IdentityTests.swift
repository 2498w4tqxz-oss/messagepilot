import Foundation
import SQLite3
import XCTest

@testable import MessagePilotKit

final class IdentityTests: XCTestCase {
  func testNormalizationAcrossMessagesAndIDSForms() {
    XCTAssertEqual(IdentityResolver.normalize("E:Hello@Example.com"), "hello@example.com")
    XCTAssertEqual(IdentityResolver.normalize("mailto:hello@example.com"), "hello@example.com")
    XCTAssertEqual(IdentityResolver.normalize("tel:+1 (555) 010-0100"), "+15550100100")
    XCTAssertEqual(IdentityResolver.normalize("P:+15550100100"), "+15550100100")
    XCTAssertTrue(IdentityResolver.same("HELLO@example.com", "E:hello@example.com"))
    XCTAssertTrue(IdentityResolver.same("+1 (555) 010-0100", "tel:+15550100100"))
    XCTAssertTrue(IdentityResolver.same("+15550100100", "5550100100"))
    XCTAssertFalse(IdentityResolver.same("+15550100100", "+5550100100"))
    XCTAssertFalse(IdentityResolver.same("hello@example.com", "hello@example.org"))
  }

  func testPlaceholdersAndDeviceHandlesAreNotIdentities() {
    // Beeper's no-history placeholder and IDS's DSID self handle must never match anything.
    for value in ["default", "urn:ds:1234567890", "D:1234567890", "", "E:"] {
      XCTAssertFalse(IdentityResolver.isIdentityLike(value), value)
    }
  }

  let expected = "line@example.com"
  let registered = IDSAccount(active: true, identities: ["line@example.com", "tel:+15550100100"])

  func testHistoryMatchIsPrimary() {
    let d = IdentityResolver.decide(
      expected: expected, chatLogins: ["E:line@example.com"], identityServices: [],
      messagesAccounts: nil)
    XCTAssertTrue(d.matched)
    XCTAssertEqual(d.source, .chatAccountLogin)
  }

  func testBrandNewAccountMatchesThroughIdentityServices() {
    // The bug: no chats, so Beeper sees "default". The registration proves the identity.
    let d = IdentityResolver.decide(
      expected: expected, chatLogins: [], identityServices: [registered], messagesAccounts: nil)
    XCTAssertTrue(d.matched)
    XCTAssertEqual(d.source, .identityServices)
    XCTAssertEqual(d.observed["ids-account"], 2)
  }

  func testPhoneIdentityMatchesRegisteredHandle() {
    let d = IdentityResolver.decide(
      expected: "+1 555 010 0100", chatLogins: [], identityServices: [registered],
      messagesAccounts: nil)
    XCTAssertTrue(d.matched)
  }

  func testOtherAccountsHistoryBlocksFallbacks() {
    let d = IdentityResolver.decide(
      expected: expected, chatLogins: ["E:someone-else@example.com"],
      identityServices: [registered], messagesAccounts: [expected])
    XCTAssertFalse(d.matched)
    XCTAssertEqual(d.reason, "Messages history belongs to a different account")
  }

  func testInactiveRegistrationIsIgnoredAndScriptingIsLastResort() {
    let inactive = IDSAccount(active: false, identities: [expected])
    XCTAssertFalse(
      IdentityResolver.decide(
        expected: expected, chatLogins: [], identityServices: [inactive], messagesAccounts: nil
      ).matched)
    let d = IdentityResolver.decide(
      expected: expected, chatLogins: [], identityServices: [inactive],
      messagesAccounts: ["Line@Example.com"])
    XCTAssertTrue(d.matched)
    XCTAssertEqual(d.source, .messagesAccounts)
  }

  func testNothingReadableFailsClosed() {
    let d = IdentityResolver.decide(
      expected: expected, chatLogins: [], identityServices: [], messagesAccounts: [])
    XCTAssertFalse(d.matched)
    XCTAssertEqual(d.reason, "No conversations yet and no signed-in iMessage registration was readable")
  }

  /// Builds an Accounts store with the same tables, account type and archived property shapes as
  /// a real macOS Accounts4.sqlite (keys and value types recorded from a live system).
  func makeAccountsStore(active: Int = 1) throws -> String {
    let path = NSTemporaryDirectory() + "accounts-\(UUID().uuidString).sqlite"
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
    exec(
      "CREATE TABLE ZACCOUNTTYPE(Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER VARCHAR);"
        + "CREATE TABLE ZACCOUNT(Z_PK INTEGER PRIMARY KEY, ZACTIVE INTEGER, ZACCOUNTTYPE INTEGER, ZUSERNAME VARCHAR);"
        + "CREATE TABLE ZACCOUNTPROPERTY(Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZKEY VARCHAR, ZVALUE BLOB);"
        + "INSERT INTO ZACCOUNTTYPE VALUES(1,'com.apple.account.IdentityServices'),(2,'com.apple.account.Google');"
        + "INSERT INTO ZACCOUNT VALUES(10,\(active),1,'Line@Example.com'),(11,1,2,'other@gmail.example');")
    let props: [(String, Any)] = [
      (
        "handles",
        [
          ["uri": "mailto:line@example.com", "status": 5051, "is-user-visible": true],
          ["uri": "tel:+15550100100", "status": 5051, "is-user-visible": true],
        ]
      ),
      ("apple-id", "line@example.com"),
      (
        "account-info",
        [
          "AppleID": "line@example.com", "SelfHandle": "urn:ds:12345678901",
          "AuthID": "D:12345678901", "VettedAliases": ["line@example.com", "alias@example.com"],
        ] as [String: Any]
      ),
      ("profile-id", "D:12345678901"),
    ]
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "INSERT INTO ZACCOUNTPROPERTY(ZOWNER,ZKEY,ZVALUE) VALUES(10,?,?)", -1, &stmt, nil)
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (key, value) in props {
      let data = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false)
      sqlite3_reset(stmt)
      sqlite3_bind_text(stmt, 1, key, -1, transient)
      _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), transient) }
      XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }
    return path
  }

  func testIdentityServicesReaderDecodesArchivedHandles() throws {
    let path = try makeAccountsStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let accounts = try IDSAccountReader.accounts(databasePath: path)
    XCTAssertEqual(accounts.count, 1, "Only the IdentityServices account is read")
    XCTAssertTrue(accounts[0].active)
    let normalized = Set(accounts[0].identities.map(IdentityResolver.normalize))
    XCTAssertEqual(
      normalized, ["line@example.com", "+15550100100", "alias@example.com"],
      "Apple ID, vetted aliases and registered handles; never the DSID")
  }

  func testReaderReportsInactiveAccounts() throws {
    let path = try makeAccountsStore(active: 0)
    defer { try? FileManager.default.removeItem(atPath: path) }
    XCTAssertEqual(try IDSAccountReader.accounts(databasePath: path).first?.active, false)
  }

  func testMissingStoreThrowsInsteadOfMatching() {
    XCTAssertThrowsError(try IDSAccountReader.accounts(databasePath: "/nonexistent/Accounts4.sqlite"))
  }
}
