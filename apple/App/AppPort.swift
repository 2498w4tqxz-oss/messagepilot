import ActivityKit
import Foundation
import UIKit

@MainActor final class AppPort {
  var event: ((String, [String: Any]) -> Void)?
  private var watching = Set<String>()
  private var pushStartTask: Task<Void, Never>?
  private var activitiesTask: Task<Void, Never>?
  func watchPushStart() {
    for activity in Activity<BridgeActivityAttributes>.activities { watch(activity) }
    if activitiesTask == nil {
      activitiesTask = Task {
        for await activity in Activity<BridgeActivityAttributes>.activityUpdates { watch(activity) }
      }
    }
    guard pushStartTask == nil else { return }
    if #available(iOS 17.2, *) {
      pushStartTask = Task {
        for await token in Activity<BridgeActivityAttributes>.pushToStartTokenUpdates {
          event?(
            "device.activity.token",
            [
              "kind": "push-to-start", "token": token.map { String(format: "%02x", $0) }.joined(),
              "attributesType": "BridgeActivityAttributes",
              "bundleId": Bundle.main.bundleIdentifier ?? "",
            ])
        }
      }
    }
    for activity in Activity<BridgeActivityAttributes>.activities { watch(activity) }
  }
  private func watch(_ activity: Activity<BridgeActivityAttributes>) {
    guard !watching.contains(activity.id) else { return }
    watching.insert(activity.id)
    Task {
      for await token in activity.pushTokenUpdates {
        event?(
          "device.activity.token",
          [
            "kind": "update", "activityId": activity.id, "surfaceId": activity.attributes.surfaceId,
            "token": token.map { String(format: "%02x", $0) }.joined(),
            "bundleId": Bundle.main.bundleIdentifier ?? "",
          ])
      }
    }
  }
  func execute(_ operation: String, _ args: [String: Any]) async throws -> [String: Any] {
    let id = args["id"] as? String ?? "default"
    if operation == "device.surface.publish" {
      guard let title = args["title"] as? String else { throw BridgeIssue("title required") }
      let record = SurfaceRecord(
        id: id, cardId: args["cardId"] as? String,
        state: .init(
          title: title, detail: args["detail"] as? String ?? "",
          progress: min(max(args["progress"] as? Double ?? 0, 0), 1),
          updatedAt: Date().timeIntervalSince1970))
      try record.save()
      return [
        "surfaceId": id, "state": "published-to-app-group",
        "widgetRefresh": "requested-not-guaranteed",
      ]
    }
    if operation == "device.activity.list" {
      return [
        "enabled": ActivityAuthorizationInfo().areActivitiesEnabled,
        "activities": Activity<BridgeActivityAttributes>.activities.map {
          ["id": $0.id, "surfaceId": $0.attributes.surfaceId, "state": "\($0.activityState)"]
        },
      ]
    }
    guard let record = SurfaceRecord.load(), record.id == id else {
      throw BridgeIssue("Publish the matching surface first")
    }
    let content = ActivityContent(state: record.state, staleDate: Date().addingTimeInterval(900))
    if operation == "device.activity.start" {
      guard UIApplication.shared.applicationState == .active,
        ActivityAuthorizationInfo().areActivitiesEnabled
      else {
        throw BridgeIssue(
          "Foreground app and enabled Live Activities required; APNs push-to-start is a separate route"
        )
      }
      guard
        !Activity<BridgeActivityAttributes>.activities.contains(where: {
          $0.attributes.surfaceId == id
        })
      else { throw BridgeIssue("Activity already exists for this surface") }
      let activity = try Activity.request(
        attributes: BridgeActivityAttributes(
          accountId: BridgeSettings.load().accountId, surfaceId: id), content: content,
        pushType: .token)
      watch(activity)
      return ["activityId": activity.id, "state": "requested"]
    }
    guard
      let activity = Activity<BridgeActivityAttributes>.activities.first(where: {
        $0.attributes.surfaceId == id
      })
    else { throw BridgeIssue("No active activity for this surface") }
    if operation == "device.activity.end" {
      await activity.end(content, dismissalPolicy: .immediate)
    } else if operation == "device.activity.update" {
      await activity.update(content)
    } else {
      throw BridgeIssue("Unknown app-port operation")
    }
    return ["activityId": activity.id, "state": "submitted"]
  }
}
