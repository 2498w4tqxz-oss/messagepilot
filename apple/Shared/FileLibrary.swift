import Foundation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct PilotFile: Decodable, Identifiable {
  let id: String
  let chatId: String
  let name: String
  let bytes: Int
  let state: String
  let result: FileResult?
  struct FileResult: Decodable {
    let text: String
    let preview: String?
    let warnings: [String]
  }
}
struct PilotFileClient {
  let settings: BridgeSettings
  func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws
    -> URLRequest
  {
    var url = URLComponents(url: try settings.endpoint(path), resolvingAgainstBaseURL: false)!
    url.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: url.url!)
    guard let token = Secrets.get("agent-token") else {
      throw BridgeIssue("Pair an agent token with file permissions")
    }
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }
  func checked(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw BridgeIssue("File request failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
    }
  }
  func list(chat: String) async throws -> [PilotFile] {
    let (data, response) = try await URLSession.shared.data(
      for: request("files", query: [.init(name: "chatId", value: chat)]))
    try checked(response)
    return try JSONDecoder().decode([PilotFile].self, from: data)
  }
  func prepare(_ id: String) async throws {
    guard UUID(uuidString: id) != nil else { throw BridgeIssue("Invalid file ID") }
    let (_, response) = try await URLSession.shared.data(
      for: request("files/\(id)/prepare", method: "POST"))
    try checked(response)
  }
  func upload(_ url: URL, chat: String) async throws -> PilotFile {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let req = try request(
      "files", method: "POST",
      query: [
        .init(name: "chatId", value: chat), .init(name: "name", value: url.lastPathComponent),
      ])
    let (data, response) = try await URLSession.shared.upload(for: req, fromFile: url)
    try checked(response)
    return try JSONDecoder().decode(PilotFile.self, from: data)
  }
  func download(_ file: PilotFile, preview: Bool) async throws -> URL {
    guard UUID(uuidString: file.id) != nil else { throw BridgeIssue("Invalid file ID") }
    let (temporary, response) = try await URLSession.shared.download(
      for: request("files/\(file.id)/\(preview ? "preview" : "download")"))
    try checked(response)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "messagepilot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = preview ? (file.result?.preview ?? "preview.txt") : file.name
    guard name == (name as NSString).lastPathComponent, !name.isEmpty else {
      throw BridgeIssue("Invalid filename")
    }
    let output = directory.appendingPathComponent(name)
    try FileManager.default.moveItem(at: temporary, to: output)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete], ofItemAtPath: output.path)
    return output
  }
}
struct FileLibraryView: View {
  @State private var chat = ""
  @State private var files: [PilotFile] = []
  @State private var error = ""
  @State private var importing = false
  @State private var opened: OpenedFile?
  @State private var busy = false
  private let client = PilotFileClient(settings: .load())
  struct OpenedFile: Identifiable {
    let id = UUID()
    let url: URL
  }
  var body: some View {
    Form {
      Section("Conversation files") {
        TextField("Exact chat ID", text: $chat).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Load files") { run { files = try await client.list(chat: chat) } }.disabled(
          chat.isEmpty || busy)
        Button("Upload file") { importing = true }.disabled(chat.isEmpty || busy)
      }
      ForEach(files) { file in
        Section(file.name) {
          Text("\(file.bytes) bytes · \(file.state)").font(.caption)
          Button("Open original / Save a copy") {
            run { opened = .init(url: try await client.download(file, preview: false)) }
          }
          Button("Prepare readable preview") {
            run {
              try await client.prepare(file.id)
              files = try await client.list(chat: chat)
            }
          }
          if file.result?.preview != nil {
            Button("Open preview") {
              run { opened = .init(url: try await client.download(file, preview: true)) }
            }
          }
          if let text = file.result?.text, !text.isEmpty {
            Text(String(text.prefix(20000))).textSelection(.enabled)
          }
          ForEach(file.result?.warnings ?? [], id: \.self) { Text($0).font(.caption) }
        }
      }
      if busy { ProgressView() }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle("File library").fileImporter(
      isPresented: $importing, allowedContentTypes: [.item]
    ) { result in
      run {
        _ = try await client.upload(result.get(), chat: chat)
        files = try await client.list(chat: chat)
      }
    }.sheet(item: $opened, onDismiss: { opened = nil }) { file in
      NavigationStack {
        VStack {
          if QLPreviewController.canPreview(file.url as NSURL) {
            FileQuickLook(url: file.url)
          } else {
            Text("No system preview for this type. Save it or open it in a compatible app.")
              .padding()
          }
          ShareLink("Save or open in another app", item: file.url).padding()
        }.navigationTitle(file.url.lastPathComponent)
      }.onDisappear {
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
      }
    }
  }
  private func run(_ operation: @escaping () async throws -> Void) {
    busy = true
    error = ""
    Task {
      defer { busy = false }
      do { try await operation() } catch { self.error = error.localizedDescription }
    }
  }
}
struct FileQuickLook: UIViewControllerRepresentable {
  let url: URL
  func makeCoordinator() -> Coordinator { Coordinator(url) }
  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    return controller
  }
  func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(_ url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
      -> QLPreviewItem
    { url as NSURL }
  }
}
