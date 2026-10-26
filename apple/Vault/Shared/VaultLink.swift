import Foundation

/// The bubble's URL: `https://<backend>/v1/vault/r/<id>?label=<label>&state=pending#t=<token>`.
/// The one-time token rides in the fragment; after the secret is accepted the bubble is updated
/// to a URL with `state=connected` and no token. The secret itself is never part of any URL.
struct VaultLink: Equatable {
  enum State: String { case pending, connected }

  let base: URL
  let id: String
  let label: String
  let state: State
  let token: String?

  static let loopback: Set<String> = ["localhost", "127.0.0.1", "::1"]

  /// Parses a bubble URL. Only hosts in `allowedHosts` are accepted (the line operator's
  /// backend), so a look-alike bubble from someone else cannot collect a secret.
  static func parse(_ url: URL, allowedHosts: Set<String>) -> VaultLink? {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = c.host?.lowercased(), allowedHosts.contains(host),
      c.scheme == "https" || (c.scheme == "http" && loopback.contains(host))
    else { return nil }
    let parts = c.path.split(separator: "/").map(String.init)
    guard parts.count == 4, parts[0] == "v1", parts[1] == "vault", parts[2] == "r",
      parts[3].count == 16, parts[3].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    let query = Dictionary(
      (c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    guard let label = query["label"], !label.isEmpty, label.count <= 80,
      let state = State(rawValue: query["state"] ?? "")
    else { return nil }
    let token = c.fragment.flatMap { fragment -> String? in
      URLComponents(string: "x:?" + fragment)?.queryItems?.first(where: { $0.name == "t" })?.value
    }
    if state == .pending, (token ?? "").count < 32 { return nil }
    var root = URLComponents()
    root.scheme = c.scheme
    root.host = c.host
    root.port = c.port
    guard let base = root.url else { return nil }
    return VaultLink(
      base: base, id: parts[3], label: label, state: state, token: state == .pending ? token : nil)
  }

  var bubbleURL: URL {
    var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    c.path = "/v1/vault/r/\(id)"
    c.queryItems = [URLQueryItem(name: "label", value: label), URLQueryItem(name: "state", value: state.rawValue)]
    if state == .pending, let token { c.fragment = "t=\(token)" }
    return c.url!
  }

  var submitURL: URL { base.appendingPathComponent("v1/vault/submit") }

  func connected() -> VaultLink {
    VaultLink(base: base, id: id, label: label, state: .connected, token: nil)
  }

  /// JSON body for the backend. `device` is Messages' per-device participant UUID, which the
  /// backend records so a used link cannot be replayed from another device.
  func submission(value: String, device: String) throws -> Data {
    guard let token, state == .pending else { throw VaultError.notPending }
    return try JSONSerialization.data(withJSONObject: [
      "id": id, "token": token, "value": value, "device": device,
    ])
  }

  static func allowedHosts(_ bundle: Bundle) -> Set<String> {
    Set(
      (bundle.object(forInfoDictionaryKey: "VaultAllowedHosts") as? String ?? "")
        .split(separator: " ").map { $0.lowercased() })
  }
}

enum VaultError: Error, LocalizedError {
  case notPending, rejected(String), transport
  var errorDescription: String? {
    switch self {
    case .notPending: "This request was already completed."
    case .rejected(let reason): reason
    case .transport: "Couldn't reach the service. Check your connection and try again."
    }
  }
}
