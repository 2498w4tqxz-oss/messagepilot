import Foundation

public enum MessageID {
  /// Beeper message IDs are `GUID` or `GUID_<part>`; chat.db and deep links use the bare GUID.
  public static func guid(_ id: String) -> String {
    id.firstIndex(of: "_").map { String(id[..<$0]) } ?? id
  }
  public static func part(_ id: String) -> Int? {
    id.firstIndex(of: "_").flatMap { Int(id[id.index(after: $0)...]) }
  }
  public static func isValidGUID(_ guid: String) -> Bool {
    !guid.isEmpty && guid.count <= 80
      && guid.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ":") }
  }
  /// `imessage://open?message-guid=…` (overlay shows the single message in a focused view).
  public static func deepLink(guid: String, overlay: Bool) throws -> URL {
    guard isValidGUID(guid) else { throw KitError("Invalid message GUID") }
    var c = URLComponents()
    c.scheme = "imessage"
    c.path = "open"
    c.queryItems = [URLQueryItem(name: "message-guid", value: guid)]
    if overlay { c.queryItems?.append(URLQueryItem(name: "overlay", value: "1")) }
    guard let url = c.url else { throw KitError("Invalid deep link") }
    return url
  }
}

public enum SendLater {
  /// Messages offers Send Later up to 14 days ahead.
  public static let maximumLead: TimeInterval = 14 * 24 * 3600
  public static let minimumLead: TimeInterval = 60

  public static func parse(_ raw: String, now: Date = Date()) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: raw) ?? fractional.date(from: raw) else {
      throw KitError("sendAt must be an ISO 8601 date-time with a time zone, e.g. 2026-11-01T09:30:00-04:00")
    }
    guard date.timeIntervalSince(now) >= minimumLead else {
      throw KitError("sendAt must be at least one minute in the future")
    }
    guard date.timeIntervalSince(now) <= maximumLead else {
      throw KitError("Messages schedules at most 14 days ahead")
    }
    return date
  }

  /// Rounds to the minute, which is the picker's granularity.
  public static func minute(_ date: Date) -> Date {
    Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
  }

  /// True when a persisted schedule matches the requested one within the picker's precision.
  public static func matches(persisted: Date, requested: Date) -> Bool {
    abs(persisted.timeIntervalSince(minute(requested))) < 90
  }
}

public enum WorkspacePath {
  /// Resolves `input` (absolute or relative) and refuses anything outside `root` after symlinks.
  public static func resolve(_ input: String, root: String) throws -> String {
    let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
    let target =
      (input.hasPrefix("/") ? URL(fileURLWithPath: input) : base.appendingPathComponent(input))
      .resolvingSymlinksInPath().standardizedFileURL
    guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
      throw KitError("Path must stay inside worker workspace")
    }
    return target.path
  }

  /// A fresh, collision-free file name inside `root`.
  public static func fresh(_ root: String, stem: String, ext: String) throws -> String {
    let safeStem = stem.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(40)
    let name = "\(safeStem.isEmpty ? "media" : String(safeStem))-\(UUID().uuidString.prefix(8)).\(ext)"
    return try resolve("media/" + name, root: root)
  }
}
