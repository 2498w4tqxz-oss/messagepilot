import ActivityKit
import AppIntents
import Foundation
import WidgetKit

struct BridgeActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
    var detail: String
    var progress: Double
    var updatedAt: Double
  }
  var accountId: String
  var surfaceId: String
}
struct SurfaceRecord: Codable {
  var id: String
  var cardId: String?
  var state: BridgeActivityAttributes.ContentState
  static func load() -> SurfaceRecord? {
    guard let data = BridgeSettings.defaults.data(forKey: "surface.current") else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
  func save() throws {
    BridgeSettings.defaults.set(try JSONEncoder().encode(self), forKey: "surface.current")
    WidgetCenter.shared.reloadAllTimelines()
  }
}
struct RefreshMessagePilotSurface: AppIntent {
  static var title: LocalizedStringResource = "Refresh MessagePilot Surface"
  static var description = IntentDescription(
    "Refresh the shared card on widgets without opening the primary app.")
  static var openAppWhenRun = false
  func perform() async throws -> some IntentResult {
    guard var surface = SurfaceRecord.load(), let cardID = surface.cardId else {
      throw BridgeIssue("Publish a surface with a card ID first")
    }
    let card = try await CardClient(settings: BridgeSettings.load()).load(cardID)
    surface.state.title = card.body.title
    surface.state.detail = card.body.summary ?? ""
    surface.state.updatedAt = Date().timeIntervalSince1970
    try surface.save()
    return .result()
  }
}
struct MessagePilotCardAction: AppIntent {
  static var title: LocalizedStringResource = "MessagePilot Card Action"
  static var description = IntentDescription("Send a declared card action to the paired bridge.")
  static var openAppWhenRun = false
  @Parameter(title: "Card ID") var cardID: String
  @Parameter(title: "Action") var action: String
  func perform() async throws -> some IntentResult {
    let client = CardClient(settings: BridgeSettings.load())
    let card = try await client.load(cardID)
    guard card.body.actions?.contains(action) == true else {
      throw BridgeIssue("Action is not declared by the current card")
    }
    try await client.action(card: cardID, revision: card.revision, name: action)
    return .result()
  }
}
