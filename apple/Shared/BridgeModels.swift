import Foundation
import Security

struct BridgeSettings: Codable {
  var url = "https://bridge.example.com"
  var accountId = ""
  var identity = ""
  static let defaults = UserDefaults(suiteName: "group.dev.messagepilot")!
  static func load() -> Self {
    guard let data = defaults.data(forKey: "bridge.settings"),
      let settings = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return settings
  }
  func save() { Self.defaults.set(try? JSONEncoder().encode(self), forKey: "bridge.settings") }
  func endpoint(_ suffix: String) throws -> URL {
    guard var parts = URLComponents(string: url), parts.scheme == "https", parts.host != nil,
      parts.user == nil, parts.password == nil, parts.query == nil
    else { throw BridgeIssue("Use a HTTPS bridge URL") }
    parts.path =
      "/v1/accounts/\(accountId.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? "")/\(suffix)"
    guard let result = parts.url else { throw BridgeIssue("Invalid bridge URL") }
    return result
  }
}
struct BridgeIssue: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
enum Secrets {
  static func remove(_ key: String) {
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.messagepilot", kSecAttrAccount as String: key,
      ] as CFDictionary)
  }
  static func cardToken() -> String? {
    let expiry = BridgeSettings.defaults.double(forKey: "card-session-expiry")
    if expiry > Date().timeIntervalSince1970 * 1000, let token = get("card-session") {
      return token
    }
    return get("agent-token")
  }
  static func put(_ key: String, _ value: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.messagepilot",
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(query as CFDictionary)
    var record = query
    record[kSecValueData as String] = Data(value.utf8)
    record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(record as CFDictionary, nil)
    guard status == errSecSuccess else { throw BridgeIssue("Keychain error \(status)") }
  }
  static func get(_ key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.messagepilot",
      kSecAttrAccount as String: key, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
struct CardItem: Codable, Identifiable {
  var id: String
  var title: String
  var subtitle: String?
  var imageURL: String?
  var linkURL: String?
  var action: String?
}
struct CardBody: Codable {
  var title: String
  var summary: String?
  var items: [CardItem]
  var actions: [String]?
}
struct CardRecord: Codable {
  var id: String
  var revision: Int
  var body: CardBody
}
struct CardClient {
  let settings: BridgeSettings
  func load(_ id: String) async throws -> CardRecord {
    guard let token = Secrets.cardToken() else {
      throw BridgeIssue("Pair the MessagePilot host app first")
    }
    let component = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    var request = URLRequest(url: try settings.endpoint("cards/\(component)"))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw BridgeIssue("Card unavailable or account access denied")
    }
    return try JSONDecoder().decode(CardRecord.self, from: data)
  }
  func action(card: String, revision: Int, name: String) async throws {
    guard let token = Secrets.cardToken() else { throw BridgeIssue("Pair or sign in first") }
    var request = URLRequest(
      url: try settings.endpoint(
        "cards/\(card.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? "")/actions"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "revision": revision, "action": name, "idempotencyKey": UUID().uuidString,
    ])
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
      throw BridgeIssue("Action was not accepted; reload the card")
    }
  }
}
