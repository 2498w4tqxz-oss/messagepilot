import AppKit
import Foundation
import IMessage
import MessagePilotKit
import PlatformSDK

@MainActor final class Bridge {
  let api: PlatformAPI
  let config: NativeConfig
  let identity: IdentityResolver.Decision
  let ax = Desktop()
  lazy var ui = MessagesUI(api: api, database: { [unowned self] in try self.database() }, workspace: config.workspace)
  private var cachedDatabase: ChatDatabase?

  init(api: PlatformAPI, config: NativeConfig, identity: IdentityResolver.Decision) {
    self.api = api
    self.config = config
    self.identity = identity
  }

  func database() throws -> ChatDatabase {
    if let cachedDatabase { return cachedDatabase }
    let db = try ChatDatabase(path: config.chatDatabase ?? ChatDatabase.defaultPath)
    cachedDatabase = db
    return db
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
        "evidence": identity.source == .chatAccountLogin
          ? "matched-local-messages-account-at-startup"
          : "matched-\(identity.source?.rawValue ?? "unknown")-before-first-conversation",
        "identityCheck": identity.json,
      ]
    case "capabilities":
      return OperationCatalog.capabilities(config.flags)
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
    case "messages.get":
      return try await message(chat, try required(p, "messageId"))
    case "messages.reactions":
      let rows = try database().reactions(to: MessageID.guid(try required(p, "messageId")))
      return [
        "reactions": ReactionState.current(rows).map(\.json), "history": rows.map(\.json),
      ]
    case "chats.create":
      guard let recipients = p["recipients"] as? [String], !recipients.isEmpty else {
        throw BridgeFailure("recipients required")
      }
      return try await api.createThread(
        userIDs: recipients, title: p["title"] as? String, messageText: p["text"] as? String
      ).jsonValue
    case "messages.send":
      if let paths = p["filePaths"] as? [String] {
        guard p["text"] == nil, p["filePath"] == nil, p["replyTo"] == nil else {
          throw BridgeFailure("Photo collections cannot be combined with text, filePath or replyTo")
        }
        try requireUI()
        return try await ui.photos(try required(p, "chatId"), paths: paths)
      }
      let file = try (p["filePath"] as? String).map { try workspacePath($0) }
      return try await api.sendMessage(
        threadID: try required(p, "chatId"), text: p["text"] as? String, filePath: file,
        quotedMessageID: p["replyTo"] as? String
      ).jsonValue
    case "messages.react", "messages.unreact":
      let id = try required(p, "messageId")
      let request = try ReactionRequest.parse(try required(p, "reaction"))
      let add = method == "messages.react"
      if add {
        try await api.addReaction(threadID: chat, messageID: id, reactionKey: request.transportKey)
      } else {
        try await api.removeReaction(threadID: chat, messageID: id, reactionKey: request.transportKey)
      }
      return try await confirmReaction(MessageID.guid(id), request: request, present: add)
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
    case "chats.mute":
      try await api.updateThread(threadID: try required(p, "chatId"), muted: p["muted"] as? Bool ?? true)
    case "chats.delete":
      guard p["confirm"] as? Bool == true else {
        throw BridgeFailure("Deleting a conversation is irreversible; pass confirm: true")
      }
      try await api.deleteThread(threadID: try required(p, "chatId"))
    case "chats.notifyAnyway":
      try await api.notifyAnyway(threadID: try required(p, "chatId"))
    case "apps.snapshot":
      return try ax.snapshot(bundle: allowedBundle(p), maxDepth: min(p["depth"] as? Int ?? 8, 15))
    case "apps.interact":
      return try await ax.interact(
        bundle: allowedBundle(p), actions: p["actions"] as? [[String: Any]] ?? [])
    case "messages.format":
      guard config.enableExperimentalEffects else {
        throw BridgeFailure("Formatting requires calibrated native UI")
      }
      return try await ui.format(
        try required(p, "chatId"), text: try required(p, "text"),
        styles: p["styles"] as? [String] ?? [], range: p["range"] as? [String: Int])
    case "messages.effect":
      guard config.enableExperimentalEffects else {
        throw BridgeFailure("Effects adapter is disabled until calibrated on the dedicated worker")
      }
      return try await ui.effect(
        try required(p, "chatId"), text: try required(p, "text"),
        effect: try required(p, "effect"), kind: p["kind"] as? String ?? "bubble",
        range: p["range"] as? [String: Int])
    case "messages.sticker":
      try requireUI()
      return try await ui.sticker(
        try required(p, "chatId"), query: p["query"] as? String, index: p["index"] as? Int ?? 0)
    case "messages.sticker.attach":
      try requireUI()
      return try await ui.attachSticker(
        try required(p, "chatId"), messageID: try required(p, "messageId"),
        query: p["query"] as? String, index: p["index"] as? Int ?? 0)
    case "messages.forward":
      try requireUI()
      return try await ui.forward(
        try required(p, "chatId"), messageID: try required(p, "messageId"), to: try required(p, "to"))
    case "messages.schedule":
      try requireUI()
      return try await ui.schedule(
        try required(p, "chatId"), text: try required(p, "text"),
        sendAt: try SendLater.parse(try required(p, "sendAt")))
    case "messages.scheduled.list":
      let db = try database()
      let guid = chat.isEmpty ? nil : try db.resolveChatGUID(chat)
      if !chat.isEmpty, guid == nil { throw BridgeFailure("Chat not found") }
      return ["items": try db.scheduled(chat: guid)]
    case "messages.scheduled.cancel":
      try requireUI()
      return try await ui.cancelScheduled(try required(p, "chatId"), messageID: try required(p, "messageId"))
    case "attachments.download":
      return try await download(p)
    case "media.create":
      return try await MediaOps.create(p, workspace: config.workspace)
    case "apps.messages.installed":
      let result = try await runProcess(
        executable: "/usr/bin/pluginkit",
        arguments: ["-mA", "-vv", "-p", PluginKit.messagesExtensionPoint, "-P", "maccatalyst"],
        directory: config.workspace,
        timeout: 20)
      return ["extensions": PluginKit.messagesExtensions(result["stdout"] as? String ?? "")]
    case "apps.messages.list":
      try requireUI()
      return try await ui.appsList(try required(p, "chatId"))
    case "apps.messages.open":
      try requireUI()
      return try await ui.appsOpen(try required(p, "chatId"), app: try required(p, "app")).2
    case "apps.messages.prompt":
      try requireUI()
      return try await ui.appsPrompt(
        try required(p, "chatId"), app: try required(p, "app"), text: try required(p, "text"),
        submit: p["submit"] as? Bool ?? false)
    case "chats.details":
      try requireUI()
      return try await ui.detailsSummary(try required(p, "chatId"))
    case "chats.rename":
      try requireUI()
      return try await ui.rename(try required(p, "chatId"), name: try required(p, "name"))
    case "chats.participants.add":
      try requireUI()
      guard let addresses = p["addresses"] as? [String] else { throw BridgeFailure("addresses required") }
      return try await ui.participants(try required(p, "chatId"), add: addresses)
    case "chats.participants.remove":
      try requireUI()
      return try await ui.participants(try required(p, "chatId"), remove: try required(p, "address"))
    case "chats.leave":
      try requireUI()
      guard p["confirm"] as? Bool == true else {
        throw BridgeFailure("Leaving a group is irreversible for this account; pass confirm: true")
      }
      return try await ui.leave(try required(p, "chatId"))
    case "chats.pin":
      try requireUI()
      return try await ui.pin(try required(p, "chatId"), pinned: p["pinned"] as? Bool ?? true)
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
      try requireFiles()
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
      try requireFiles()
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

  // MARK: Messages data

  func message(_ chat: String, _ id: String) async throws -> [String: Any] {
    guard let message = try await api.getMessage(threadID: chat, messageID: id) else {
      throw BridgeFailure("Message not found")
    }
    var out: [String: Any] = ["message": message.jsonObject]
    let guid = MessageID.guid(id)
    if let db = try? database(), let row = try db.message(guid: guid) {
      var native: [String: Any] = [:]
      for key in [
        "is_forward", "schedule_type", "schedule_state", "balloon_bundle_id",
        "expressive_send_style_id", "is_audio_message", "thread_originator_guid", "mentions",
        "attributeRuns", "editCount", "retractedParts", "date_edited", "date_retracted",
      ] where row[key] != nil {
        native[key] = row[key]
      }
      out["native"] = native
      out["reactions"] = ReactionState.current(try db.reactions(to: guid)).map(\.json)
      out["attachments"] = try db.attachments(message: guid)
    }
    return out
  }

  func confirmReaction(_ guid: String, request: ReactionRequest, present: Bool) async throws -> [String: Any] {
    let db = try database()
    let deadline = Date().addingTimeInterval(5)
    repeat {
      let rows = try db.reactions(to: guid)
      if ReactionState.satisfies(rows, request: request, present: present) {
        return [
          "receipt": present ? "reaction-verified" : "reaction-removal-verified",
          "reaction": request.json, "reactions": ReactionState.current(rows).map(\.json),
        ]
      }
      try await Task.sleep(nanoseconds: 150_000_000)
    } while Date() < deadline
    return [
      "receipt": "adapter-completed", "reaction": request.json,
      "verification": "native-state-not-yet-observed",
    ]
  }

  func download(_ p: [String: Any]) async throws -> [String: Any] {
    let id = try required(p, "messageId")
    let guid = MessageID.guid(id)
    let db = try database()
    var attachments = try db.attachments(message: guid)
    guard !attachments.isEmpty else { throw BridgeFailure("Message has no attachments") }
    let index: Int
    if let wanted = p["attachmentId"] as? String {
      guard let i = attachments.firstIndex(where: { $0["guid"] as? String == wanted }) else {
        throw BridgeFailure("Attachment not on this message")
      }
      index = i
    } else {
      index = p["index"] as? Int ?? 0
      guard attachments.indices.contains(index) else { throw BridgeFailure("Attachment index out of range") }
    }
    if attachments[index]["exists"] as? Bool != true {
      // Messages downloads iCloud-offloaded or not-yet-fetched attachments when the cell loads.
      try await api.loadAttachment(messageID: id)
      let deadline = Date().addingTimeInterval(45)
      while Date() < deadline {
        attachments = try db.attachments(message: guid)
        if attachments[index]["exists"] as? Bool == true { break }
        try await Task.sleep(nanoseconds: 300_000_000)
      }
    }
    let record = attachments[index]
    guard record["exists"] as? Bool == true, let source = record["path"] as? String else {
      throw BridgeFailure("Attachment is not available locally yet")
    }
    let name = (record["transfer_name"] as? String ?? URL(fileURLWithPath: source).lastPathComponent)
      .replacingOccurrences(of: "/", with: "_")
    var target = URL(fileURLWithPath: try workspacePath(
      p["path"] as? String ?? "attachments/\(guid.prefix(8))-\(name)"))
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: target)
    if let format = p["convert"] as? String {
      guard ["png", "jpeg"].contains(format) else { throw BridgeFailure("convert must be png or jpeg") }
      target = target.deletingPathExtension().appendingPathExtension(format == "png" ? "png" : "jpg")
      try MediaFactory.write(
        try MediaFactory.loadImage(URL(fileURLWithPath: source)), to: target,
        type: format == "png" ? .png : .jpeg)
    } else {
      try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
    }
    let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
    var out: [String: Any] = [
      "path": target.path, "size": size, "mimeType": record["mime_type"] ?? NSNull(),
      "isSticker": record["isSticker"] ?? false, "attachmentId": record["guid"] ?? NSNull(),
      "uti": record["uti"] ?? NSNull(),
    ]
    if p["includeData"] as? Bool == true {
      guard size <= 262144 else { throw BridgeFailure("includeData is limited to 256 KiB; use files.read") }
      out["dataBase64"] = try Data(contentsOf: target).base64EncodedString()
    }
    return out
  }

  // MARK: Policy

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
  func requireFiles() throws {
    guard config.enableComputer || config.enableFiles == true else {
      throw BridgeFailure("File transfer is not enabled for this worker (enableFiles)")
    }
  }
  func requireUI() throws {
    guard config.uiAutomation else {
      throw BridgeFailure("Messages UI automation is disabled for this worker (enableUIAutomation)")
    }
  }
  func workspacePath(_ input: String) throws -> String {
    do { return try WorkspacePath.resolve(input, root: config.workspace) } catch {
      throw BridgeFailure("Path must stay inside worker workspace")
    }
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
    while process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning {
      process.terminate()
      usleep(250_000)
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
