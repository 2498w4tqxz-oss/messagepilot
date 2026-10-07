import Messages
import SwiftUI
import UIKit

final class MessagesController: MSMessagesAppViewController {
  private var host: UIHostingController<CardsView>?
  override func willBecomeActive(with conversation: MSConversation) { render(conversation) }
  override func didSelect(_ message: MSMessage, conversation: MSConversation) {
    render(conversation)
  }
  override func didReceive(_ message: MSMessage, conversation: MSConversation) {
    render(conversation)
  }
  override func contentSizeThatFits(_ size: CGSize) -> CGSize {
    CGSize(width: size.width, height: 320)
  }
  private func render(_ conversation: MSConversation) {
    host?.willMove(toParent: nil)
    host?.view.removeFromSuperview()
    host?.removeFromParent()
    let selected = conversation.selectedMessage?.url.flatMap {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)
    }
    let cardID = selected?.queryItems?.first(where: { $0.name == "card" })?.value ?? ""
    let account = selected?.queryItems?.first(where: { $0.name == "account" })?.value
    let root = CardsView(
      initialID: cardID, selectedAccount: account, transcript: presentationStyle == .transcript,
      onSend: { [weak self] card in self?.send(card, conversation: conversation) },
      onSticker: { [weak self] text in self?.sendSticker(text, conversation: conversation) })
    let controller = UIHostingController(rootView: root)
    addChild(controller)
    view.addSubview(controller.view)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: view.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    controller.didMove(toParent: self)
    host = controller
  }
  private func send(_ card: CardRecord, conversation: MSConversation) {
    let fallback = MSMessageTemplateLayout()
    fallback.caption = card.body.title
    fallback.subcaption = card.body.summary ?? "Open MessagePilot to interact"
    fallback.image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { _ in
      UIColor.systemBlue.setFill()
      UIBezierPath(rect: CGRect(x: 0, y: 0, width: 600, height: 300)).fill()
      (card.body.title as NSString).draw(
        in: CGRect(x: 32, y: 35, width: 536, height: 130),
        withAttributes: [.font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.white])
      ((card.body.summary ?? "Open MessagePilot to interact") as NSString).draw(
        in: CGRect(x: 32, y: 178, width: 536, height: 90),
        withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.white])
    }
    let message = MSMessage(session: conversation.selectedMessage?.session ?? MSSession())
    message.layout = MSMessageLiveLayout(alternateLayout: fallback)
    message.summaryText = card.body.title
    var url = URLComponents()
    url.scheme = "messagepilot"
    url.host = "card"
    url.queryItems = [
      URLQueryItem(name: "card", value: card.id),
      URLQueryItem(name: "account", value: BridgeSettings.load().accountId),
    ]
    message.url = url.url
    // Called directly from the user's Send button. No fabricated background send capability.
    conversation.send(message) { [weak self] error in
      if let error {
        DispatchQueue.main.async {
          let alert = UIAlertController(
            title: "Message not sent", message: error.localizedDescription, preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: "OK", style: .default))
          self?.present(alert, animated: true)
        }
      }
    }
  }
  private func sendSticker(_ text: String, conversation: MSConversation) {
    do {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = false
      let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format)
        .image { context in
          UIColor.systemBlue.setFill()
          UIBezierPath(roundedRect: CGRect(x: 8, y: 65, width: 284, height: 170), cornerRadius: 38)
            .fill()
          let paragraph = NSMutableParagraphStyle()
          paragraph.alignment = .center
          (String(text.prefix(35)) as NSString).draw(
            in: CGRect(x: 22, y: 92, width: 256, height: 130),
            withAttributes: [
              .font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.white,
              .paragraphStyle: paragraph,
            ])
        }
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sticker-\(UUID().uuidString).png")
      try image.pngData()?.write(to: file)
      let sticker = try MSSticker(contentsOfFileURL: file, localizedDescription: text)
      conversation.send(sticker) { error in
        if let error { NSLog("Sticker send failed: %@", error.localizedDescription) }
      }
    } catch { NSLog("Sticker generation failed: %@", error.localizedDescription) }
  }
}
struct CardsView: View {
  let initialID: String
  let selectedAccount: String?
  let transcript: Bool
  let onSend: (CardRecord) -> Void
  let onSticker: (String) -> Void
  @State private var stickerText = ""
  @State private var id = ""
  @State private var card: CardRecord?
  @State private var error = ""
  @State private var loading = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !transcript {
        HStack {
          Text("MessagePilot").font(.headline)
          Spacer()
          Button("Refresh") { Task { await load() } }
        }
        TextField("Card ID", text: $id).textFieldStyle(.roundedBorder)
        HStack {
          TextField("Sticker text", text: $stickerText).textFieldStyle(.roundedBorder)
          Button("Send sticker") { onSticker(stickerText) }.disabled(stickerText.isEmpty)
        }
      }
      if let card {
        Text(card.body.title).font(.headline)
        TabView {
          ForEach(card.body.items) { item in
            VStack(alignment: .leading) {
              if let address = item.imageURL, let url = URL(string: address), url.scheme == "https"
              {
                AsyncImage(url: url) { image in
                  image.resizable().scaledToFit()
                } placeholder: {
                  ProgressView()
                }.frame(maxHeight: 140)
              }
              Text(item.title).font(.headline)
              if let subtitle = item.subtitle { Text(subtitle).font(.subheadline) }
              if let address = item.linkURL, let url = URL(string: address), url.scheme == "https" {
                Link("Open", destination: url)
              }
            }.padding().tag(item.id)
          }
        }.tabViewStyle(.page).frame(height: 220)
        HStack {
          ForEach(card.body.actions ?? [], id: \.self) { name in
            Button(name) {
              Task {
                do {
                  try await CardClient(settings: BridgeSettings.load()).action(
                    card: card.id, revision: card.revision, name: name)
                } catch { self.error = error.localizedDescription }
              }
            }
          }
        }
        if !transcript { Button("Send carousel") { onSend(card) }.buttonStyle(.borderedProminent) }
      }
      if loading { ProgressView() }
      if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
    }.padding().task {
      id = initialID
      if !id.isEmpty { await load() }
    }
  }
  private func load() async {
    loading = true
    defer { loading = false }
    do {
      let settings = BridgeSettings.load()
      guard selectedAccount == nil || selectedAccount == settings.accountId else {
        throw BridgeIssue("This card belongs to another account")
      }
      card = try await CardClient(settings: settings).load(id)
      error = ""
    } catch { self.error = error.localizedDescription }
  }
}
