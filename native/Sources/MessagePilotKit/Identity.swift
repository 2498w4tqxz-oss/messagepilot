import Foundation

/// Decides whether the Messages session belongs to the enrolled Apple identity.
///
/// Beeper's `CurrentUser.fetch` reads `chat.account_login`, which is empty until the account has
/// at least one conversation; it then reports the placeholder "default". A brand-new line therefore
/// failed startup. Messages history stays the primary evidence. Only when there is no history at
/// all do we consult the signed-in iMessage registration (Identity Services account) and, last,
/// Messages' own scripting account list.
public enum IdentityResolver {
  public enum Source: String, Codable {
    case chatAccountLogin = "chat.account_login"
    case identityServices = "ids-account"
    case messagesAccounts = "messages-scripting-account"
  }

  public struct Decision: Equatable {
    public let matched: Bool
    public let source: Source?
    public let reason: String
    /// Count of candidate values seen per source; never the values themselves (they are PII).
    public let observed: [String: Int]
    public var json: [String: Any] {
      [
        "matched": matched, "source": source?.rawValue ?? NSNull(), "reason": reason,
        "observed": observed,
      ]
    }
  }

  public static func decide(
    expected: String, chatLogins: [String], identityServices: [IDSAccount],
    messagesAccounts: [String]?
  ) -> Decision {
    let logins = chatLogins.filter(isIdentityLike)
    let active = identityServices.filter(\.active)
    let observed: [String: Int] = [
      Source.chatAccountLogin.rawValue: logins.count,
      Source.identityServices.rawValue: active.reduce(0) { $0 + $1.identities.count },
      Source.messagesAccounts.rawValue: messagesAccounts?.count ?? -1,
    ]
    guard isIdentityLike(expected) else {
      return Decision(
        matched: false, source: nil, reason: "Expected identity is not an email or phone number",
        observed: observed)
    }
    if logins.contains(where: { same($0, expected) }) {
      return Decision(
        matched: true, source: .chatAccountLogin, reason: "Messages history uses the identity",
        observed: observed)
    }
    if !logins.isEmpty {
      // History exists for another identity. Do not let a registration record override it.
      return Decision(
        matched: false, source: nil,
        reason: "Messages history belongs to a different account", observed: observed)
    }
    if active.contains(where: { $0.identities.contains(where: { same($0, expected) }) }) {
      return Decision(
        matched: true, source: .identityServices,
        reason: "No conversations yet; the active iMessage registration lists the identity",
        observed: observed)
    }
    if let accounts = messagesAccounts, accounts.contains(where: { same($0, expected) }) {
      return Decision(
        matched: true, source: .messagesAccounts,
        reason: "No conversations yet; Messages lists the identity as an iMessage account",
        observed: observed)
    }
    return Decision(
      matched: false, source: nil,
      reason: logins.isEmpty && active.isEmpty && (messagesAccounts ?? []).isEmpty
        ? "No conversations yet and no signed-in iMessage registration was readable"
        : "No source lists the expected identity",
      observed: observed)
  }

  /// Strips Messages/IDS prefixes and URI schemes, lowercases emails, keeps + and digits for phones.
  public static func normalize(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["mailto:", "tel:", "E:", "e:", "P:", "p:"] where s.hasPrefix(prefix) {
      s.removeFirst(prefix.count)
      break
    }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.contains("@") { return s.lowercased() }
    let plus = s.hasPrefix("+") ? "+" : ""
    return plus + s.filter(\.isNumber)
  }

  public static func isIdentityLike(_ raw: String) -> Bool {
    // DSIDs (urn:ds:…, D:…) identify the Apple Account internally; they are never handles.
    let lowered = raw.lowercased()
    guard !lowered.hasPrefix("urn:"), !lowered.hasPrefix("d:") else { return false }
    let n = normalize(raw)
    if n.contains("@") {
      let parts = n.split(separator: "@")
      return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }
    return n.filter(\.isNumber).count >= 7
  }

  public static func same(_ a: String, _ b: String) -> Bool {
    guard isIdentityLike(a), isIdentityLike(b) else { return false }
    let x = normalize(a)
    let y = normalize(b)
    if x.contains("@") || y.contains("@") { return x == y }
    let dx = x.filter(\.isNumber)
    let dy = y.filter(\.isNumber)
    if dx == dy { return true }
    // North American numbers are often stored without the country code on one side.
    if dx.count == 11, dx.hasPrefix("1"), dx.dropFirst() == Substring(dy), !y.hasPrefix("+") {
      return true
    }
    if dy.count == 11, dy.hasPrefix("1"), dy.dropFirst() == Substring(dx), !x.hasPrefix("+") {
      return true
    }
    return false
  }
}

/// An Identity Services (iMessage/FaceTime registration) account from the Accounts store.
public struct IDSAccount: Equatable {
  public let active: Bool
  /// Apple ID, email-address, vetted aliases and registered handle URIs (mailto:/tel:).
  public let identities: [String]
  public init(active: Bool, identities: [String]) {
    self.active = active
    self.identities = identities
  }
}

public enum IDSAccountReader {
  public static var defaultPath: String { NSHomeDirectory() + "/Library/Accounts/Accounts4.sqlite" }
  static let accountType = "com.apple.account.IdentityServices"
  static let keys = ["handles", "apple-id", "email-address", "account-info"]

  public static func accounts(databasePath: String = defaultPath) throws -> [IDSAccount] {
    let db = try SQLiteReader(path: databasePath)
    let accountColumns = try db.columns("ZACCOUNT")
    let activeColumn = accountColumns.contains("ZACTIVE") ? "a.ZACTIVE" : "1"
    let rows = try db.rows(
      "SELECT a.Z_PK AS pk, a.ZUSERNAME AS username, \(activeColumn) AS active FROM ZACCOUNT a JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE=t.Z_PK WHERE t.ZIDENTIFIER=?",
      [accountType])
    return try rows.map { row in
      var values: [String] = []
      if let user = row["username"]?.string { values.append(user) }
      if let pk = row["pk"]?.int {
        let props = try db.rows(
          "SELECT ZKEY AS key, ZVALUE AS value FROM ZACCOUNTPROPERTY WHERE ZOWNER=? AND ZKEY IN (?,?,?,?)",
          [pk] + keys)
        for prop in props {
          guard let data = prop["value"]?.data else { continue }
          values += strings(in: decode(data))
        }
      }
      var seen = Set<String>()
      let identities = values.filter(IdentityResolver.isIdentityLike).filter {
        seen.insert(IdentityResolver.normalize($0)).inserted
      }
      return IDSAccount(active: (row["active"]?.int ?? 0) == 1, identities: identities)
    }
  }

  static func decode(_ data: Data) -> Any? {
    let classes: [AnyClass] = [
      NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSSet.self, NSDate.self,
      NSData.self,
    ]
    if let object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) {
      return object
    }
    return try? PropertyListSerialization.propertyList(from: data, format: nil)
  }

  static func strings(in object: Any?) -> [String] {
    switch object {
    case let s as String: return [s]
    case let a as [Any]: return a.flatMap { strings(in: $0) }
    case let set as NSSet: return set.allObjects.flatMap { strings(in: $0) }
    case let d as [String: Any]:
      // Handles are {uri, status, is-user-visible}; account-info carries AppleID and VettedAliases.
      return d.filter { !["SelfHandle", "AuthID", "status"].contains($0.key) }.values.flatMap {
        strings(in: $0)
      }
    default: return []
    }
  }
}
