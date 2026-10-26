import Foundation

/// The full native worker's operation catalog. `capabilities` reports it; docs/capabilities.md
/// explains the evidence behind each verification level.
public enum OperationCatalog {
  public enum Requirement: String {
    case none, ui, computer, toolkit, files, effects
  }

  public struct Spec {
    public let name: String
    public let requirement: Requirement
    /// "device-tested" only when exercised on macOS 26 through this worker's code path.
    public let verification: String
    public let detail: String
  }

  public struct Flags {
    public var enableComputer: Bool
    public var enableEffects: Bool
    public var enableUI: Bool
    public var enableFiles: Bool
    public var hasToolkit: Bool
    public init(
      enableComputer: Bool, enableEffects: Bool, enableUI: Bool, enableFiles: Bool,
      hasToolkit: Bool
    ) {
      self.enableComputer = enableComputer
      self.enableEffects = enableEffects
      self.enableUI = enableUI
      self.enableFiles = enableFiles
      self.hasToolkit = hasToolkit
    }
  }

  static let live26 = "Exercised on macOS 26.6.2 (DOOR line)"
  static let fixture26 =
    "Selectors replayed against recorded macOS 26.6.2 Accessibility trees; live calibration pending"

  public static let specs: [Spec] = [
    Spec(name: "identity", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "chats.list", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "messages.list", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "messages.search", requirement: .none, verification: "compiled", detail: "Beeper database search"),
    Spec(name: "messages.get", requirement: .none, verification: "compiled",
      detail: "One message with links, attachments, mentions, reactions and schedule state; chat.db fixture-tested"),
    Spec(name: "messages.send", requirement: .none, verification: "device-tested",
      detail: "Text and threaded replies exercised on macOS 26.6.2; filePath via Beeper; filePaths (photo stack) uses the UI and needs enableUIAutomation"),
    Spec(name: "messages.react", requirement: .none, verification: "device-tested",
      detail: "Classic Tapbacks on macOS 26.6.2; any single emoji via the same Beeper path"),
    Spec(name: "messages.unreact", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "messages.reactions", requirement: .none, verification: "compiled",
      detail: "Classic, emoji and sticker Tapbacks with current-state resolution; chat.db fixture-tested"),
    Spec(name: "messages.edit", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "messages.unsend", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "chats.create", requirement: .none, verification: "compiled", detail: "Beeper compose path"),
    Spec(name: "chats.read", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "chats.unread", requirement: .none, verification: "compiled", detail: "Beeper conversation action"),
    Spec(name: "chats.typing", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "chats.mute", requirement: .none, verification: "compiled", detail: "Beeper Hide Alerts action"),
    Spec(name: "chats.delete", requirement: .none, verification: "compiled",
      detail: "Beeper delete; requires confirm:true"),
    Spec(name: "chats.notifyAnyway", requirement: .none, verification: "compiled",
      detail: "Beeper Notify Anyway for recipients with a Focus enabled"),
    Spec(name: "attachments.download", requirement: .none, verification: "compiled",
      detail: "Copies a received attachment (photo, video, audio, sticker, file) into the workspace; chat.db fixture-tested"),
    Spec(name: "media.create", requirement: .none, verification: "compiled",
      detail: "Card images, transparent sticker images, format conversion and MP4 slideshows; unit-tested renders"),
    Spec(name: "messages.scheduled.list", requirement: .none, verification: "compiled",
      detail: "Send Later rows Beeper hides; chat.db fixture-tested"),
    Spec(name: "apps.messages.installed", requirement: .none, verification: "compiled",
      detail: "Enumerates com.apple.message-payload-provider extensions with pluginkit"),
    Spec(name: "messages.effect", requirement: .effects, verification: "compiled",
      detail: "Rebuilt for macOS 26: messageBodyField composer, add menu → message_effects, Effect: buttons, sendButton. " + fixture26),
    Spec(name: "messages.format", requirement: .effects, verification: "compiled",
      detail: "Format menu identifiers bold/italic/underline/strikethrough recorded on macOS 26.6.2. " + fixture26),
    Spec(name: "messages.sticker", requirement: .ui, verification: "compiled",
      detail: "Sends a sticker from the Emoji & Stickers picker. " + fixture26),
    Spec(name: "messages.sticker.attach", requirement: .ui, verification: "compiled",
      detail: "Places a sticker on a bubble through the Attach Sticker… action recorded on macOS 26.6.2. " + fixture26),
    Spec(name: "messages.forward", requirement: .ui, verification: "compiled",
      detail: "Forward… bubble action recorded on macOS 26.6.2. " + fixture26),
    Spec(name: "messages.schedule", requirement: .ui, verification: "compiled",
      detail: "Send Later from the add menu; reconciled through schedule_type in chat.db. " + fixture26),
    Spec(name: "messages.scheduled.cancel", requirement: .ui, verification: "compiled",
      detail: "Deletes a pending Send Later message. " + fixture26),
    Spec(name: "apps.messages.list", requirement: .ui, verification: "compiled",
      detail: "Lists the add menu: Photos, Stickers, #images, Audio, Message Effects, Send Later, Polls and installed iMessage apps"),
    Spec(name: "apps.messages.open", requirement: .ui, verification: "compiled",
      detail: "Opens one add-menu item and returns its Accessibility summary"),
    Spec(name: "apps.messages.prompt", requirement: .ui, verification: "compiled",
      detail: "Types a query or prompt into the opened app's text field (e.g. #images search)"),
    Spec(name: "chats.details", requirement: .ui, verification: "compiled",
      detail: "Opens Conversation › Show Details and returns its controls"),
    Spec(name: "chats.rename", requirement: .ui, verification: "compiled",
      detail: "Group name through the details view. " + fixture26),
    Spec(name: "chats.participants.add", requirement: .ui, verification: "compiled",
      detail: "Adds members to a group through the details view. " + fixture26),
    Spec(name: "chats.participants.remove", requirement: .ui, verification: "compiled",
      detail: "Removes a member through the details view. " + fixture26),
    Spec(name: "chats.leave", requirement: .ui, verification: "compiled",
      detail: "Leave this Conversation through the details view. " + fixture26),
    Spec(name: "chats.pin", requirement: .ui, verification: "compiled",
      detail: "Pin/Unpin action on the selected conversation row"),
    Spec(name: "apps.snapshot", requirement: .none, verification: "device-tested", detail: live26),
    Spec(name: "apps.interact", requirement: .none, verification: "device-tested",
      detail: "waitFor probes exercised on macOS 26.6.2"),
    Spec(name: "computer.exec", requirement: .computer, verification: "compiled", detail: ""),
    Spec(name: "computer.input", requirement: .computer, verification: "compiled", detail: ""),
    Spec(name: "computer.apps", requirement: .computer, verification: "compiled", detail: ""),
    Spec(name: "computer.screenshot", requirement: .computer, verification: "compiled", detail: ""),
    Spec(name: "files.read", requirement: .files, verification: "compiled", detail: "Workspace only"),
    Spec(name: "files.write", requirement: .files, verification: "compiled", detail: "Workspace only"),
    Spec(name: "apps.build", requirement: .computer, verification: "compiled", detail: ""),
    Spec(name: "apps.create", requirement: .toolkit, verification: "compiled", detail: ""),
    Spec(name: "apps.ios.run", requirement: .toolkit, verification: "compiled", detail: ""),
  ]

  public static func available(_ spec: Spec, _ flags: Flags) -> Bool {
    switch spec.requirement {
    case .none: true
    case .ui: flags.enableUI
    case .effects: flags.enableEffects
    case .computer: flags.enableComputer
    case .toolkit: flags.enableComputer && flags.hasToolkit
    case .files: flags.enableComputer || flags.enableFiles
    }
  }

  public static func capabilities(_ flags: Flags) -> [[String: Any]] {
    specs.map { spec in
      let ok = available(spec, flags)
      return [
        "operation": spec.name, "available": ok, "path": "sip-enabled-native",
        "verification": ok ? spec.verification : "unavailable",
        "detail": ok
          ? spec.detail
          : "Disabled by worker configuration (\(spec.requirement.rawValue))",
      ]
    }
  }
}
