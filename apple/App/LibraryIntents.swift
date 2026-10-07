import AppIntents
import Foundation

struct ReadMessagePilotFile: AppIntent {
  static var title: LocalizedStringResource = "Read MessagePilot File"
  static var description = IntentDescription(
    "Read prepared file text using your paired account and chat permissions. Does not send a message."
  )
  static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "File ID") var fileID: String
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard UUID(uuidString: fileID) != nil else { throw BridgeIssue("Invalid file ID") }
    let client = PilotFileClient(settings: .load())
    let (data, response) = try await URLSession.shared.data(
      for: client.request("files/\(fileID)/read"))
    try client.checked(response)
    let file = try JSONDecoder().decode(PilotFile.self, from: data)
    guard let result = file.result else { throw BridgeIssue("Prepare the file preview first") }
    return .result(value: String(result.text.prefix(20000)))
  }
}
struct StoreMessagePilotFile: AppIntent {
  static var title: LocalizedStringResource = "Store MessagePilot File"
  static var description = IntentDescription(
    "Store a file in your paired account, bound to an explicitly permitted chat.")
  static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "Chat ID") var chatID: String
  @Parameter(title: "File") var file: IntentFile
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = (file.filename as NSString).lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else { throw BridgeIssue("Invalid filename") }
    let url = directory.appendingPathComponent(name)
    // Shortcuts materializes IntentFile. Use the app's streaming picker for large originals.
    guard file.data.count <= 16 * 1024 * 1024 else {
      throw BridgeIssue("Use the file library for files larger than 16 MiB")
    }
    try file.data.write(to: url, options: .completeFileProtection)
    let stored = try await PilotFileClient(settings: .load()).upload(url, chat: chatID)
    return .result(value: stored.id)
  }
}
struct PrepareMessagePilotFile: AppIntent {
  static var title: LocalizedStringResource = "Prepare MessagePilot File Preview"
  static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "File ID") var fileID: String
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await PilotFileClient(settings: .load()).prepare(fileID)
    return .result(dialog: "Preview requested. Read the file after conversion finishes.")
  }
}
struct MessagePilotShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ReadMessagePilotFile(), phrases: ["Read a file with \(.applicationName)"],
      shortTitle: "Read File", systemImageName: "doc.text")
    AppShortcut(
      intent: StoreMessagePilotFile(), phrases: ["Store a file with \(.applicationName)"],
      shortTitle: "Store File", systemImageName: "tray.and.arrow.down")
    AppShortcut(
      intent: PrepareMessagePilotFile(), phrases: ["Prepare a preview with \(.applicationName)"],
      shortTitle: "Prepare Preview", systemImageName: "doc.richtext")
  }
}
