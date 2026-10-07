import Messages
import UIKit

/// Use only from the active extension. A successful callback means sending started, not delivery.
@MainActor final class ConversationPort {
  enum Mode { case stage, direct }
  enum Content {
    case text(String)
    case attachment(URL, name: String?)
    case sticker(MSSticker)
    case message(MSMessage)
  }
  weak var controller: MSMessagesAppViewController?
  init(_ controller: MSMessagesAppViewController) { self.controller = controller }
  func submit(_ content: Content, mode: Mode, completion: @escaping (Error?) -> Void) {
    guard let controller, let conversation = controller.activeConversation,
      controller.viewIfLoaded?.window != nil
    else {
      completion(BridgeIssue("Open the Messages extension first"))
      return
    }
    if mode == .direct && controller.presentationContext != .messages {
      completion(BridgeIssue("Direct sends require the Messages presentation context"))
      return
    }
    // Apple enforces recent touch interaction. Never retry an uncertain send automatically.
    switch (content, mode) {
    case (.text(let text), .direct): conversation.sendText(text, completionHandler: completion)
    case (.text(let text), .stage): conversation.insertText(text, completionHandler: completion)
    case (.attachment(let url, let name), .direct):
      conversation.sendAttachment(url, withAlternateFilename: name, completionHandler: completion)
    case (.attachment(let url, let name), .stage):
      conversation.insertAttachment(url, withAlternateFilename: name, completionHandler: completion)
    case (.sticker(let sticker), .direct): conversation.send(sticker, completionHandler: completion)
    case (.sticker(let sticker), .stage):
      conversation.insert(sticker, completionHandler: completion)
    case (.message(let message), .direct): conversation.send(message, completionHandler: completion)
    case (.message(let message), .stage):
      conversation.insert(message, completionHandler: completion)
    }
  }
  /// Reuse a session only for an update to the same authored experience.
  static func message(
    layout: MSMessageLayout, url: URL, summary: String, continuing: MSMessage? = nil
  ) -> MSMessage {
    let message = MSMessage(session: continuing?.session ?? MSSession())
    message.layout = layout
    message.url = url
    message.summaryText = summary
    return message
  }
}
/// Supports bundled sticker packs and downloaded, locally verified sticker files.
final class PilotStickerBrowser: MSStickerBrowserViewController {
  var stickers: [MSSticker] = [] { didSet { stickerBrowserView.reloadData() } }
  override func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
    stickers.count
  }
  override func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView, stickerAt index: Int)
    -> MSSticker
  { stickers[index] }
}
