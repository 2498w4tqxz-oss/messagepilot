import ActivityKit
import SwiftUI
import WidgetKit

struct SurfaceEntry: TimelineEntry {
  var date: Date
  var surface: SurfaceRecord?
}
struct SurfaceProvider: TimelineProvider {
  func placeholder(in context: Context) -> SurfaceEntry { SurfaceEntry(date: Date(), surface: nil) }
  func getSnapshot(in context: Context, completion: @escaping (SurfaceEntry) -> Void) {
    completion(SurfaceEntry(date: Date(), surface: SurfaceRecord.load()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<SurfaceEntry>) -> Void) {
    completion(
      Timeline(
        entries: [SurfaceEntry(date: Date(), surface: SurfaceRecord.load())],
        policy: .after(Date().addingTimeInterval(900))))
  }
}
struct MessagePilotWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "MessagePilotSurface", provider: SurfaceProvider()) { entry in
      VStack(alignment: .leading) {
        Text(entry.surface?.state.title ?? "MessagePilot").font(.headline)
        Text(entry.surface?.state.detail ?? "Your agent's shared surface").font(.caption)
        if let state = entry.surface?.state { ProgressView(value: state.progress) }
        Button(intent: RefreshMessagePilotSurface()) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }.containerBackground(.fill.tertiary, for: .widget)
    }.configurationDisplayName("MessagePilot").description("Shared agent and iMessage app state.")
      .supportedFamilies([.systemSmall, .systemMedium])
  }
}
struct MessagePilotLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: BridgeActivityAttributes.self) { context in
      VStack(alignment: .leading) {
        Text(context.state.title).font(.headline)
        Text(context.state.detail).font(.caption)
        ProgressView(value: context.state.progress)
      }.padding().activityBackgroundTint(.black.opacity(0.85)).activitySystemActionForegroundColor(
        .white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { Image(systemName: "message.fill") }
        DynamicIslandExpandedRegion(.trailing) { Text("\(Int(context.state.progress * 100))%") }
        DynamicIslandExpandedRegion(.bottom) {
          VStack {
            Text(context.state.title).font(.headline)
            Text(context.state.detail).font(.caption)
            ProgressView(value: context.state.progress)
          }
        }
      } compactLeading: {
        Image(systemName: "message.fill")
      } compactTrailing: {
        Text("\(Int(context.state.progress * 100))%")
      } minimal: {
        Image(systemName: "message.fill")
      }
    }
  }
}
@main struct MessagePilotWidgets: WidgetBundle {
  var body: some Widget {
    MessagePilotWidget()
    MessagePilotLiveActivity()
  }
}
