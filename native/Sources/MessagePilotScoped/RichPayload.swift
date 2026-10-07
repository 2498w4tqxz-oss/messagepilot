import Foundation

// Persisted payload evidence, independent of UI action completion.
enum RichPayload {
  static func matchesThread(_ message: [String: Any], expected: String?) -> Bool {
    (message["thread_originator_guid"] as? String) == expected
  }
  static let styleKeys = [
    "bold": "__kIMTextBoldAttributeName", "italic": "__kIMTextItalicAttributeName",
    "underline": "__kIMTextUnderlineAttributeName",
    "strikethrough": "__kIMTextStrikethroughAttributeName",
  ]
  static let textEffects = [
    "Big": "5", "Small": "11", "Shake": "9", "Nod": "8", "Explode": "12", "Ripple": "4",
    "Bloom": "6", "Jitter": "10",
  ]
  static let expressive = [
    "Slam": "com.apple.MobileSMS.expressivesend.impact",
    "Loud": "com.apple.MobileSMS.expressivesend.loud",
    "Gentle": "com.apple.MobileSMS.expressivesend.gentle",
    "Invisible Ink": "com.apple.MobileSMS.expressivesend.invisibleink",
    "Echo": "com.apple.messages.effect.CKEchoEffect",
    "Spotlight": "com.apple.messages.effect.CKSpotlightEffect",
    "Balloons": "com.apple.messages.effect.CKHappyBirthdayEffect",
    "Confetti": "com.apple.messages.effect.CKConfettiEffect",
    "Love": "com.apple.messages.effect.CKHeartEffect",
    "Lasers": "com.apple.messages.effect.CKLasersEffect",
    "Fireworks": "com.apple.messages.effect.CKFireworksEffect",
    "Celebration": "com.apple.messages.effect.CKSparklesEffect",
  ]
  static func covers(_ runs: [[String: Any]], range: NSRange, key: String, value: String) -> Bool {
    guard range.location >= 0, range.length > 0 else { return false }
    var cursor = range.location
    let end = NSMaxRange(range)
    for run in runs.sorted(by: { ($0["start"] as? Int ?? -1) < ($1["start"] as? Int ?? -1) }) {
      guard let start = run["start"] as? Int, let length = run["length"] as? Int,
        length > 0, start <= cursor,
        (run["attributes"] as? [String: String])?[key] == value
      else { continue }
      cursor = max(cursor, start + length)
      if cursor >= end { return true }
    }
    return false
  }
  static func matches(
    _ message: [String: Any], request: [String: Any], formatting: Bool, effect: Bool
  ) -> Bool {
    guard let text = request["text"] as? String, message["text"] as? String == text else {
      return false
    }
    let requested = request["range"] as? [String: Int] ?? [:]
    let range = NSRange(
      location: requested["start"] ?? 0, length: requested["length"] ?? (text as NSString).length)
    let runs = message["attributeRuns"] as? [[String: Any]] ?? []
    func exactCoverage(key: String, value: String) -> Bool {
      covers(runs, range: range, key: key, value: value)
        && !runs.contains { run in
          guard (run["attributes"] as? [String: String])?[key] == value,
            let start = run["start"] as? Int, let length = run["length"] as? Int
          else { return false }
          return start < range.location || start + length > NSMaxRange(range)
        }
    }
    if formatting {
      guard let styles = request["styles"] as? [String], !styles.isEmpty else { return false }
      return styles.allSatisfy { style in
        guard let key = styleKeys[style] else { return false }
        return exactCoverage(key: key, value: "1")
      }
    }
    if effect {
      guard let name = request["effect"] as? String else { return false }
      if request["kind"] as? String == "text" {
        guard let value = textEffects[name] else { return false }
        return exactCoverage(key: "__kIMTextEffectAttributeName", value: value)
      }
      guard let expected = expressive[name] else { return false }
      return message["expressive_send_style_id"] as? String == expected
    }
    return true
  }
}
