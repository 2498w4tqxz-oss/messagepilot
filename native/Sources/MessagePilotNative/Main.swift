import AppKit
import Foundation
import IMessage
import PlatformSDK

struct NativeConfig: Decodable {
  let allowedChatIds: [String]?
  let accountId: String
  let expectedIdentity: String
  let expectedOSUser: String
  let workspace: String
  let allowedBundles: [String]
  let enableComputer: Bool
  let enableExperimentalEffects: Bool
  let toolkitPath: String?
  let nodeExecutable: String?
}
struct BridgeFailure: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}
func required(_ p: [String: Any], _ key: String) throws -> String {
  guard let v = p[key] as? String, !v.isEmpty else { throw BridgeFailure("Missing \(key)") }
  return v
}
final class Output: @unchecked Sendable {
  static let shared = Output()
  private let lock = NSLock()
  func write(_ object: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    do {
      var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      data.append(10)
      try FileHandle.standardOutput.write(contentsOf: data)
    } catch { fputs("Unable to encode bridge frame\n", stderr) }
  }
}
@main struct Main {
  @MainActor static func main() async {
    do {
      let args = CommandLine.arguments
      // Compilation and --help never initialize IMessage, inspect an Apple account, or ask for permissions.
      guard args.contains("--live"), let i = args.firstIndex(of: "--config"),
        args.indices.contains(i + 1)
      else {
        print("messagepilot-native --live --config <dedicated-account.json>")
        return
      }
      let config = try JSONDecoder().decode(
        NativeConfig.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
      guard config.allowedChatIds == nil else {
        throw BridgeFailure(
          "Use messagepilot-scoped for chat-restricted accounts; full-account bootstrap refused")
      }
      guard NSUserName() == config.expectedOSUser else {
        throw BridgeFailure("OS user does not match the dedicated worker configuration")
      }
      let root = URL(fileURLWithPath: config.workspace).standardizedFileURL
      let marker = root.appendingPathComponent(".messagepilot-account")
      guard
        (try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(
          in: .whitespacesAndNewlines)) == config.accountId
      else { throw BridgeFailure("Dedicated worker enrollment marker missing") }
      _ = NSApplication.shared
      NSApp.setActivationPolicy(.accessory)
      IMessageHost.bootstrapWithOptions(
        dataDirPath: root.appendingPathComponent("native-logs").path, verbose: false,
        useSecondaryInstance: false)
      let api = try PlatformAPI(accountID: config.accountId)
      let current = try await api.getCurrentUser()
      guard
        [current.id, current.email, current.phoneNumber].compactMap({ $0 }).contains(where: {
          $0.lowercased() == config.expectedIdentity.lowercased()
        })
      else { throw BridgeFailure("Observed Messages account does not match expected identity") }
      api.subscribeToEvents { events in
        Output.shared.write(["type": "event", "data": events.map { $0.jsonObject() }])
      }
      try await api.startEventWatchingFromCurrentState()
      let bridge = Bridge(api: api, config: config)
      let lines = AsyncStream<String> { continuation in
        DispatchQueue.global().async {
          while let line = readLine(strippingNewline: true) { continuation.yield(line) }
          continuation.finish()
        }
      }
      for await line in lines {
        var id = "invalid"
        do {
          guard line.utf8.count <= 1_048_576, let data = line.data(using: .utf8),
            let r = try JSONSerialization.jsonObject(with: data) as? [String: Any]
          else { throw BridgeFailure("Invalid request") }
          id = try required(r, "id")
          let method = try required(r, "method")
          let requestID = id
          let params = r["params"] as? [String: Any] ?? [:]
          // The gateway serializes desktop actions and gives builds a separate lane.
          // Awaiting a compiler process must not stall reading the next Messages command.
          Task { @MainActor in
            do {
              let result = try await bridge.execute(method, params)
              Output.shared.write(["id": requestID, "result": result])
            } catch { Output.shared.write(["id": requestID, "error": String(describing: error)]) }
          }
        } catch { Output.shared.write(["id": id, "error": String(describing: error)]) }
      }
      try await api.dispose()
    } catch {
      fputs("MessagePilot startup failed: \(error)\n", stderr)
      exit(1)
    }
  }
}
@MainActor final class Bridge {
  let api: PlatformAPI
  let config: NativeConfig
  let ax = Desktop()
  init(api: PlatformAPI, config: NativeConfig) {
    self.api = api
    self.config = config
  }
  func execute(_ method: String, _ p: [String: Any]) async throws -> Any {
    let chat = p["chatId"] as? String ?? ""
    let pagination = (p["cursor"] as? String).map {
      PlatformSDK.PaginationArg(
        cursor: $0, direction: p["direction"] as? String == "after" ? .after : .before)
    }
    for key in ["messageId", "replyTo"] {
      if let id = p[key] as? String {
        guard let reference = try await api.resolveMessageReference(messageID: id),
          reference.threadID == chat
        else {
          throw BridgeFailure("Message reference does not belong to the requested chat")
        }
      }
    }
    switch method {
    case "identity":
      return [
        "identity": config.expectedIdentity, "accountId": config.accountId, "osUser": NSUserName(),
        "evidence": "matched-local-messages-account-at-startup",
      ]
    case "capabilities":
      let basic = [
        "identity", "chats.list", "messages.list", "messages.search", "messages.send",
        "messages.react", "messages.unreact", "messages.edit", "messages.unsend", "chats.create",
        "chats.read", "chats.unread", "chats.typing", "apps.snapshot", "apps.interact",
      ]
      return
        (basic + [
          "messages.effect", "messages.format", "computer.exec", "computer.input", "computer.apps",
          "computer.screenshot", "files.read", "files.write",
          "apps.build", "apps.create",
          "apps.ios.run",
        ]).map { name -> [String: Any] in
          let computer = [
            "computer.exec", "computer.input", "computer.apps", "computer.screenshot", "files.read",
            "files.write", "apps.build",
            "apps.create", "apps.ios.run",
          ].contains(name)
          let toolkit = ["apps.create", "apps.ios.run"].contains(name)
          let available =
            computer
            ? config.enableComputer && (!toolkit || config.toolkitPath != nil)
            : ["messages.effect", "messages.format"].contains(name)
              ? config.enableExperimentalEffects : true
          return [
            "operation": name, "available": available, "path": "sip-enabled-native",
            "verification": available ? "compiled" : "unavailable",
            "detail":
              "Live operation has not been verified by this build. UI capability depends on permissions, OS and locale.",
          ]
        }
    case "chats.list":
      return try await api.getThreads(
        folderName: p["folder"] as? String ?? "normal", pagination: pagination
      ).jsonObject
    case "messages.list":
      return try await api.getMessages(threadID: try required(p, "chatId"), pagination: pagination)
        .jsonObject
    case "messages.search":
      return try await api.searchMessages(
        typed: try required(p, "query"), threadID: p["chatId"] as? String,
        mediaOnly: p["mediaOnly"] as? Bool, sender: p["sender"] as? String, pagination: pagination,
        limit: min(p["limit"] as? Int ?? 50, 200)
      ).jsonObject
    case "chats.create":
      guard let recipients = p["recipients"] as? [String], !recipients.isEmpty else {
        throw BridgeFailure("recipients required")
      }
      return try await api.createThread(
        userIDs: recipients, title: p["title"] as? String, messageText: p["text"] as? String
      ).jsonValue
    case "messages.send":
      let file = try (p["filePath"] as? String).map { try workspacePath($0) }
      return try await api.sendMessage(
        threadID: try required(p, "chatId"), text: p["text"] as? String, filePath: file,
        quotedMessageID: p["replyTo"] as? String
      ).jsonValue
    case "messages.react":
      try await api.addReaction(
        threadID: chat, messageID: try required(p, "messageId"),
        reactionKey: try required(p, "reaction"))
    case "messages.unreact":
      try await api.removeReaction(
        threadID: chat, messageID: try required(p, "messageId"),
        reactionKey: try required(p, "reaction"))
    case "messages.edit":
      try await api.editMessage(
        threadID: chat, messageID: try required(p, "messageId"), content: try required(p, "text"))
    case "messages.unsend":
      try await api.deleteMessage(threadID: chat, messageID: try required(p, "messageId"))
    case "chats.read": try await api.sendReadReceipt(threadID: chat)
    case "chats.unread": try await api.markAsUnread(threadID: chat)
    case "chats.typing":
      try await api.sendActivityIndicator(
        type: p["active"] as? Bool == false ? "none" : "typing", threadID: chat)
    case "apps.snapshot":
      return try ax.snapshot(bundle: allowedBundle(p), maxDepth: min(p["depth"] as? Int ?? 8, 15))
    case "apps.interact":
      return try await ax.interact(
        bundle: allowedBundle(p), actions: p["actions"] as? [[String: Any]] ?? [])
    case "messages.format":
      guard config.enableExperimentalEffects else {
        throw BridgeFailure("Formatting requires calibrated native UI")
      }
      _ = try await api.getThreadActivityStatus(threadID: chat)
      return try await ax.sendFormatted(
        text: try required(p, "text"), styles: p["styles"] as? [String] ?? [],
        range: p["range"] as? [String: Int])
    case "messages.effect":
      guard config.enableExperimentalEffects else {
        throw BridgeFailure("Effects adapter is disabled until calibrated on the dedicated worker")
      }
      // Select without sending. Effects use the existing Messages UI; no injected framework.
      // This method opens and asserts the exact selected thread synchronously.
      // onThreadSelected installs an idle watcher and is insufficient here.
      _ = try await api.getThreadActivityStatus(threadID: chat)
      return try await ax.sendEffect(
        text: try required(p, "text"), effect: try required(p, "effect"),
        kind: p["kind"] as? String ?? "bubble",
        selectors: p["selectors"] as? [String: String] ?? [:])
    case "computer.apps":
      try requireComputer()
      return ax.applications()
    case "computer.input":
      try requireComputer()
      return try await ax.input(
        bundle: allowedBundle(p), actions: p["actions"] as? [[String: Any]] ?? [])
    case "computer.exec":
      try requireComputer()
      return try await runProcess(
        executable: try required(p, "executable"), arguments: p["arguments"] as? [String] ?? [],
        directory: try workspacePath(p["cwd"] as? String ?? config.workspace),
        timeout: min(p["timeoutSeconds"] as? Double ?? 60, 540))
    case "apps.build":
      try requireComputer()
      let project = try workspacePath(try required(p, "project"))
      let action = p["action"] as? String ?? "build"
      guard ["build", "build-for-testing"].contains(action) else {
        throw BridgeFailure("Unsupported build action")
      }
      var args = [
        "-project", project, "-scheme", try required(p, "scheme"), "-derivedDataPath",
        try workspacePath(p["derivedData"] as? String ?? "DerivedData"), "-destination",
        p["destination"] as? String ?? "generic/platform=iOS Simulator", action,
      ]
      if let team = p["team"] as? String { args.append("DEVELOPMENT_TEAM=\(team)") }
      if p["sign"] as? Bool != true { args.append("CODE_SIGNING_ALLOWED=NO") }
      return try await runProcess(
        executable: "/usr/bin/xcodebuild", arguments: args, directory: config.workspace,
        timeout: 540)
    case "apps.create":
      try requireComputer()
      guard let toolkit = config.toolkitPath else { throw BridgeFailure("toolkitPath is required") }
      return try await runProcess(
        executable: config.nodeExecutable ?? "/opt/homebrew/bin/node",
        arguments: [
          toolkit + "/dist/src/cli.js", "app-create",
          try workspacePath(try required(p, "directory")), try required(p, "bundleId"),
        ] + (p["primaryPort"] as? Bool == true ? ["--primary-port"] : [])
          + ((p["passkeyDomain"] as? String).map { ["--passkey-domain", $0] } ?? []),
        directory: config.workspace, timeout: 60)
    case "apps.ios.run":
      try requireComputer()
      guard let toolkit = config.toolkitPath, let recipe = p["recipe"] as? [String: Any] else {
        throw BridgeFailure("toolkitPath and recipe are required")
      }
      let recipeURL = URL(fileURLWithPath: try workspacePath(".recipe-\(UUID().uuidString).json"))
      try JSONSerialization.data(withJSONObject: recipe).write(to: recipeURL, options: .atomic)
      defer { try? FileManager.default.removeItem(at: recipeURL) }
      var args = [
        toolkit + "/scripts/run-ios.py", "--xctestrun",
        try workspacePath(try required(p, "xctestrun")), "--recipe", recipeURL.path, "--device-id",
        try required(p, "deviceId"), "--enrollment",
        try workspacePath(try required(p, "enrollment")), "--result",
        try workspacePath(try required(p, "resultPath")),
      ]
      if p["prepareOnly"] as? Bool == true { args.append("--prepare-only") }
      return try await runProcess(
        executable: "/usr/bin/python3", arguments: args, directory: config.workspace, timeout: 550)
    case "files.read":
      try requireComputer()
      let path = try workspacePath(try required(p, "path"))
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      let offset = UInt64(max(0, p["offset"] as? Int ?? 0))
      guard offset <= size else { throw BridgeFailure("Offset exceeds file size") }
      try handle.seek(toOffset: offset)
      let data =
        try handle.read(upToCount: min(max(1, p["length"] as? Int ?? 262144), 262144)) ?? Data()
      return [
        "path": path, "size": size, "offset": offset, "nextOffset": offset + UInt64(data.count),
        "eof": offset + UInt64(data.count) >= size, "dataBase64": data.base64EncodedString(),
      ]
    case "files.write":
      try requireComputer()
      let path = try workspacePath(try required(p, "path"))
      guard let data = Data(base64Encoded: try required(p, "dataBase64")), data.count <= 262144
      else { throw BridgeFailure("Invalid or oversized base64 chunk") }
      let offset = UInt64(max(0, p["offset"] as? Int ?? 0))
      let replace = p["replace"] as? Bool ?? false
      if replace && offset != 0 { throw BridgeFailure("replace requires offset zero") }
      let url = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(
          atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      if replace { try handle.truncate(atOffset: 0) }
      guard try handle.seekToEnd() == offset else {
        throw BridgeFailure("File size differs from expected append offset")
      }
      try handle.write(contentsOf: data)
      try handle.synchronize()
      return ["path": path, "size": offset + UInt64(data.count), "bytesWritten": data.count]
    case "computer.screenshot":
      try requireComputer()
      let path = try workspacePath(p["path"] as? String ?? "desktop.png")
      let result = try await runProcess(
        executable: "/usr/sbin/screencapture", arguments: ["-x", path], directory: config.workspace,
        timeout: 15)
      return ["path": path, "process": result]
    default: throw BridgeFailure("Unsupported operation: \(method)")
    }
    return ["receipt": "adapter-completed", "operation": method, "delivery": "not-asserted"]
  }
  func allowedBundle(_ p: [String: Any]) throws -> String {
    let bundle = p["bundleId"] as? String ?? "com.apple.MobileSMS"
    guard config.allowedBundles.contains(bundle) else {
      throw BridgeFailure("Application is not in this account's allowedBundles")
    }
    return bundle
  }
  func requireComputer() throws {
    guard config.enableComputer else {
      throw BridgeFailure("Computer tools are not enabled for this worker")
    }
  }
  func workspacePath(_ input: String) throws -> String {
    let root = URL(fileURLWithPath: config.workspace).resolvingSymlinksInPath().standardizedFileURL
    let target =
      (input.hasPrefix("/") ? URL(fileURLWithPath: input) : root.appendingPathComponent(input))
      .resolvingSymlinksInPath().standardizedFileURL
    guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
      throw BridgeFailure("Path must stay inside worker workspace")
    }
    return target.path
  }
}

func runProcess(executable: String, arguments: [String], directory: String, timeout: Double)
  async throws -> [String: Any]
{
  guard executable.hasPrefix("/") else {
    throw BridgeFailure("Executable must be an absolute path")
  }
  return try await Task.detached {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    // File-backed output avoids pipe deadlocks on large Xcode output.
    let base = URL(fileURLWithPath: directory).appendingPathComponent(
      ".messagepilot-process-\(UUID().uuidString)")
    let out = base.appendingPathExtension("out")
    let err = base.appendingPathExtension("err")
    FileManager.default.createFile(
      atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
    FileManager.default.createFile(
      atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
    defer {
      try? FileManager.default.removeItem(at: out)
      try? FileManager.default.removeItem(at: err)
    }
    let stdout = try FileHandle(forWritingTo: out)
    let stderr = try FileHandle(forWritingTo: err)
    defer {
      try? stdout.close()
      try? stderr.close()
    }
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.25)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw BridgeFailure("Process deadline exceeded; subprocess side effects may have occurred")
    }
    process.waitUntilExit()
    func tail(_ url: URL) throws -> String {
      let f = try FileHandle(forReadingFrom: url)
      defer { try? f.close() }
      let size = try f.seekToEnd()
      try f.seek(toOffset: size > 65536 ? size - 65536 : 0)
      return String(decoding: try f.readToEnd() ?? Data(), as: UTF8.self)
    }
    return [
      "exitCode": process.terminationStatus, "stdout": try tail(out), "stderr": try tail(err),
      "outputLimitBytes": 65536,
    ]
  }.value
}
