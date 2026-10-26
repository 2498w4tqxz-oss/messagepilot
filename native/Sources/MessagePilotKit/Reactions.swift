import Foundation

/// Every Tapback form iMessage supports on macOS 15+: the six classic Tapbacks, any single emoji,
/// and stickers attached to a bubble. Classic and emoji Tapbacks share one slot per sender; a new
/// one replaces the previous. Stickers are additive.
public enum ReactionRequest: Equatable {
  case classic(Classic)
  case emoji(String)

  public enum Classic: String, CaseIterable {
    case love, like, dislike, laugh, emphasize, question

    /// Key understood by Beeper's `addReaction`/`removeReaction`.
    public var transportKey: String { self == .love ? "heart" : rawValue }
    /// chat.db associated_message_type for an addition; removals add 1000.
    public var associatedType: Int {
      2000 + Classic.allCases.firstIndex(of: self)!
    }
    /// Custom Accessibility action title on a macOS 26 message bubble (English).
    public var actionTitle: String {
      switch self {
      case .love: "Heart"
      case .like: "Thumbs up"
      case .dislike: "Thumbs down"
      case .laugh: "Ha ha!"
      case .emphasize: "Exclamation mark"
      case .question: "Question mark"
      }
    }
    /// TapbackPickerCollectionView child identifier on macOS 15+.
    public var pickerIdentifier: String {
      switch self {
      case .love: "heart"
      case .like: "thumbsUp"
      case .dislike: "thumbsDown"
      case .laugh: "ha"
      case .emphasize: "exclamation"
      case .question: "questionMark"
      }
    }
  }

  static let aliases: [String: Classic] = [
    "love": .love, "heart": .love, "like": .like, "thumbsup": .like, "thumbs_up": .like,
    "thumbs-up": .like, "dislike": .dislike, "thumbsdown": .dislike, "thumbs_down": .dislike,
    "thumbs-down": .dislike, "laugh": .laugh, "haha": .laugh, "ha": .laugh,
    "emphasize": .emphasize, "emphasis": .emphasize, "exclamation": .emphasize, "!!": .emphasize,
    "question": .question, "questionmark": .question, "?": .question,
  ]

  public static func parse(_ raw: String) throws -> ReactionRequest {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let classic = aliases[trimmed.lowercased()] { return .classic(classic) }
    guard trimmed.count == 1, let character = trimmed.first, isEmoji(character) else {
      throw KitError(
        "Reaction must be love, like, dislike, laugh, emphasize, question, or exactly one emoji")
    }
    return .emoji(trimmed)
  }

  public static func isEmoji(_ c: Character) -> Bool {
    let scalars = c.unicodeScalars
    guard let first = scalars.first else { return false }
    if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
    // Text-default emoji such as ❤ or ‼ count when they carry VS16 or form a sequence.
    return first.properties.isEmoji && (scalars.count > 1 || first.value > 0x238C)
      && !(first.properties.numericType != nil && scalars.count == 1)
  }

  public var transportKey: String {
    switch self {
    case .classic(let c): c.transportKey
    case .emoji(let e): e
    }
  }
  public var associatedType: Int {
    switch self {
    case .classic(let c): c.associatedType
    case .emoji: 2006
    }
  }
  public var json: [String: Any] {
    switch self {
    case .classic(let c): ["kind": "classic", "name": c.rawValue, "associatedType": associatedType]
    case .emoji(let e): ["kind": "emoji", "emoji": e, "associatedType": associatedType]
    }
  }
}

/// A reaction row from chat.db (`message` rows whose associated_message_guid targets a message).
public struct ReactionRow: Equatable {
  public let rowID: Int64
  public let guid: String
  public let type: Int
  public let emoji: String?
  public let fromMe: Bool
  public let sender: String?
  public let date: Date?
  public init(
    rowID: Int64, guid: String, type: Int, emoji: String?, fromMe: Bool, sender: String?,
    date: Date?
  ) {
    self.rowID = rowID
    self.guid = guid
    self.type = type
    self.emoji = emoji
    self.fromMe = fromMe
    self.sender = sender
    self.date = date
  }

  public enum Kind: String { case classic, emoji, sticker }
  /// 1000 is a sticker peeled onto a bubble (iOS 10 style); 2007 is a sticker Tapback (iOS 18+).
  public var kind: Kind? {
    if type == 1000 { return .sticker }
    guard (2000...2007).contains(type) || (3000...3007).contains(type) else { return nil }
    switch type % 1000 {
    case 6: return .emoji
    case 7: return .sticker
    default: return .classic
    }
  }
  public var isRemoval: Bool { (3000...3007).contains(type) }
  public var classic: ReactionRequest.Classic? {
    guard kind == .classic else { return nil }
    return ReactionRequest.Classic.allCases[type % 1000]
  }
  /// Identity of the Tapback for add/remove pairing.
  public var key: String {
    switch kind {
    case .classic: classic!.rawValue
    case .emoji: "emoji:" + (emoji ?? "")
    case .sticker: "sticker:\(guid)"
    case nil: "unknown:\(type)"
    }
  }
}

public enum ReactionState {
  /// Current reactions after applying additions, replacements and removals in row order.
  public static func current(_ rows: [ReactionRow]) -> [ReactionRow] {
    var tapbacks: [String: ReactionRow] = [:]  // one classic/emoji slot per sender
    var stickers: [ReactionRow] = []
    for row in rows.sorted(by: { $0.rowID < $1.rowID }) {
      guard let kind = row.kind else { continue }
      let sender = row.fromMe ? "me" : (row.sender ?? "")
      if kind == .sticker {
        if row.isRemoval {
          stickers.removeAll { ($0.fromMe ? "me" : ($0.sender ?? "")) == sender }
        } else {
          stickers.append(row)
        }
        continue
      }
      if row.isRemoval {
        if let existing = tapbacks[sender], existing.key == removalKey(row) {
          tapbacks[sender] = nil
        }
      } else {
        tapbacks[sender] = row
      }
    }
    return (Array(tapbacks.values) + stickers).sorted { $0.rowID < $1.rowID }
  }

  static func removalKey(_ row: ReactionRow) -> String {
    switch row.kind {
    case .emoji: "emoji:" + (row.emoji ?? "")
    case .classic: row.classic!.rawValue
    default: row.key
    }
  }

  /// True when `mine` reflects the requested reaction (or its absence).
  public static func satisfies(
    _ rows: [ReactionRow], request: ReactionRequest, present: Bool
  ) -> Bool {
    let mine = current(rows).filter { $0.fromMe && $0.kind != .sticker }
    let has = mine.contains { row in
      switch request {
      case .classic(let c): row.classic == c
      case .emoji(let e): row.kind == .emoji && row.emoji == e
      }
    }
    return has == present
  }
}

extension ReactionRow {
  public var json: [String: Any] {
    var out: [String: Any] = [
      "id": guid, "type": type, "kind": kind?.rawValue ?? "unknown", "fromMe": fromMe,
      "removal": isRemoval,
    ]
    if let emoji { out["emoji"] = emoji }
    if let classic { out["name"] = classic.rawValue }
    if let sender { out["sender"] = sender }
    if let date { out["date"] = ISO8601DateFormatter().string(from: date) }
    return out
  }
}
