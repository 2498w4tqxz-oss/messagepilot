import Foundation
import SwiftUI

struct TaskProgressRecord: Decodable {
  let id: String
  let accountId: String
  let chatId: String
  let title: String
  let detail: String
  let state: String
  let fraction: Double?
  let updatedAt: Double
  let fileIds: [String]
  var terminal: Bool { ["completed", "failed", "cancelled"].contains(state) }
}

// Polling lasts only as long as this view's task. iOS owns extension suspension
// and transcript snapshots; a backend update does not imply a refreshed bubble.
struct TaskProgressView: View {
  let initialID: String
  let selectedAccount: String?
  let transcript: Bool
  let onSend: (TaskProgressRecord) -> Void
  @State private var id = ""
  @State private var job: TaskProgressRecord?
  @State private var error = ""
  @State private var opened: FileLibraryView.OpenedFile?
  @State private var refreshKey = UUID()
  @State private var busy = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if !transcript {
          TextField("Progress job ID", text: $id)
            .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("Load progress") { job = nil; refreshKey = UUID() }
            .disabled(UUID(uuidString: id) == nil)
        }
        if let job {
          Text(job.title).font(.headline)
          Text(job.state.capitalized).font(.caption)
          if !job.terminal {
            if let fraction = job.fraction { ProgressView(value: fraction) }
            else { ProgressView() }
          }
          Text(job.detail)
          Text("Updated \(Date(timeIntervalSince1970: job.updatedAt / 1000), style: .relative) ago")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(Array(job.fileIds.enumerated()), id: \.element) { index, file in
            Button("Open output \(index + 1)") { Task { await open(file) } }.disabled(busy)
          }
          if !transcript {
            Text("Intended chat: \(job.chatId)").font(.caption)
            Button("Send progress card in this conversation") { onSend(job) }
              .buttonStyle(.borderedProminent)
          }
        }
        if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
      }.padding()
    }
    .task(id: refreshKey) {
      if id.isEmpty { id = initialID }
      guard UUID(uuidString: id) != nil else { return }
      let requestedID = id
      while !Task.isCancelled {
        do {
          let settings = BridgeSettings.load()
          guard selectedAccount == nil || selectedAccount == settings.accountId else {
            throw BridgeIssue("This progress card belongs to another account")
          }
          let client = PilotFileClient(settings: settings)
          let (data, response) = try await URLSession.shared.data(for: client.request("progress/\(requestedID)"))
          try client.checked(response)
          let record = try JSONDecoder().decode(TaskProgressRecord.self, from: data)
          try Task.checkCancellation()
          job = record
          error = ""
          if record.terminal { return }
          try await Task.sleep(for: .seconds(3))
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription; return }
      }
    }
    .sheet(item: $opened) { item in
      NavigationStack {
        FileQuickLook(url: item.url)
          .toolbar { ShareLink(item: item.url) }
      }.onDisappear { try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
    }
  }
  private func open(_ id: String) async {
    busy = true
    defer { busy = false }
    do {
      guard UUID(uuidString: id) != nil else { throw BridgeIssue("Invalid file ID") }
      let client = PilotFileClient(settings: .load())
      let (data, response) = try await URLSession.shared.data(for: client.request("files/\(id)"))
      try client.checked(response)
      let file = try JSONDecoder().decode(PilotFile.self, from: data)
      opened = .init(url: try await client.download(file, preview: false))
    } catch { self.error = error.localizedDescription }
  }
}
