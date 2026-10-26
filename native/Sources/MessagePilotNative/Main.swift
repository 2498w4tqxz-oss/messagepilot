import AppKit
import Foundation
import IMessage
import MessagePilotKit
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
  /// Stickers, Send Later, forwarding, photo stacks, the add menu and group management.
  /// Defaults to `enableExperimentalEffects`, which already implies calibrated UI automation.
  let enableUIAutomation: Bool?
  /// files.read / files.write inside the workspace without the rest of the computer tools.
  let enableFiles: Bool?
  /// Test overrides; production uses ~/Library/Messages/chat.db and ~/Library/Accounts.
  let chatDatabase: String?
  let accountsDatabase: String?

  var uiAutomation: Bool { enableUIAutomation ?? enableExperimentalEffects }
  var flags: OperationCatalog.Flags {
    OperationCatalog.Flags(
      enableComputer: enableComputer, enableEffects: enableExperimentalEffects,
      enableUI: uiAutomation, enableFiles: enableFiles ?? false, hasToolkit: toolkitPath != nil)
  }
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

/// Identity evidence for startup and the `identity` operation.
enum IdentityCheck {
  /// Lists the iMessage accounts Messages reports through scripting. Requires the Automation
  /// permission Lines already grants; used only when there is no conversation history yet.
  @MainActor static func messagesAccounts() -> [String]? {
    let source = """
      tell application "Messages"
        set out to {}
        repeat with a in (every account whose service type is iMessage)
          try
            set end of out to (description of a as text)
          end try
        end repeat
        return out
      end tell
      """
    var error: NSDictionary?
    guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil
    else { return nil }
    guard result.numberOfItems > 0 else { return [] }
    return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
  }

  @MainActor static func resolve(
    config: NativeConfig, beeperLogins: [String], allowScripting: Bool
  ) -> IdentityResolver.Decision {
    let chatLogins: [String]
    if let db = try? ChatDatabase(path: config.chatDatabase ?? ChatDatabase.defaultPath),
      let logins = try? db.accountLogins()
    {
      chatLogins = logins
    } else {
      chatLogins = beeperLogins
    }
    let ids = (try? IDSAccountReader.accounts(
      databasePath: config.accountsDatabase ?? IDSAccountReader.defaultPath)) ?? []
    let first = IdentityResolver.decide(
      expected: config.expectedIdentity, chatLogins: chatLogins, identityServices: ids,
      messagesAccounts: nil)
    let noHistory = !chatLogins.contains(where: IdentityResolver.isIdentityLike)
    guard !first.matched, noHistory, allowScripting else { return first }
    return IdentityResolver.decide(
      expected: config.expectedIdentity, chatLogins: chatLogins, identityServices: ids,
      messagesAccounts: messagesAccounts())
  }
}

func printJSON(_ object: Any) {
  if let data = try? JSONSerialization.data(
    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
  }
}

@main struct Main {
  @MainActor static func main() async {
    do {
      let args = CommandLine.arguments
      guard let i = args.firstIndex(of: "--config"), args.indices.contains(i + 1) else {
        print(
          "messagepilot-native --live --config <dedicated-account.json>\n"
            + "  --describe          print this worker's capability catalog and exit\n"
            + "  --resolve-identity  check the Apple identity from local databases and exit")
        return
      }
      let config = try JSONDecoder().decode(
        NativeConfig.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
      // Neither probe initializes IMessage, opens Messages or asks for permissions.
      if args.contains("--describe") {
        printJSON(OperationCatalog.capabilities(config.flags))
        return
      }
      if args.contains("--resolve-identity") {
        let decision = IdentityCheck.resolve(
          config: config, beeperLogins: [], allowScripting: args.contains("--allow-scripting"))
        printJSON(decision.json)
        exit(decision.matched ? 0 : 3)
      }
      guard args.contains("--live") else {
        print("messagepilot-native --live --config <dedicated-account.json>")
        return
      }
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
      // Beeper reads chat.account_login, which is empty on a brand-new account ("default").
      let decision = IdentityCheck.resolve(
        config: config, beeperLogins: [current.email, current.phoneNumber].compactMap { $0 },
        allowScripting: true)
      guard decision.matched else {
        throw BridgeFailure(
          "Observed Messages account does not match expected identity (\(decision.reason))")
      }
      if decision.source != .chatAccountLogin {
        fputs(
          "MessagePilot: identity confirmed by \(decision.source!.rawValue) before the first conversation\n",
          stderr)
      }
      api.subscribeToEvents { events in
        Output.shared.write(["type": "event", "data": events.map { $0.jsonObject() }])
      }
      try await api.startEventWatchingFromCurrentState()
      let bridge = Bridge(api: api, config: config, identity: decision)
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
