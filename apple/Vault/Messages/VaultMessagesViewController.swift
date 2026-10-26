import Messages
import SwiftUI
import UIKit

/// Two sides of one bubble:
/// - The line (its Mac, driven by MessagePilot) pastes a request link minted by its backend and
///   sends an interactive bubble.
/// - The person taps that bubble; this extension opens with a secure field. The value goes
///   straight to the backend over HTTPS with the bubble's one-time token, and the bubble is
///   updated to "Connected". The value never enters the transcript or the line's Messages.
final class VaultMessagesViewController: MSMessagesAppViewController {
  private var host: UIHostingController<AnyView>?

  override func willBecomeActive(with conversation: MSConversation) { render(conversation) }
  override func didSelect(_ message: MSMessage, conversation: MSConversation) { render(conversation) }
  override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
    if let conversation = activeConversation { render(conversation) }
  }

  private var allowed: Set<String> { VaultLink.allowedHosts(Bundle.main) }

  private func render(_ conversation: MSConversation) {
    let selected = conversation.selectedMessage.flatMap { message in
      message.url.flatMap { VaultLink.parse($0, allowedHosts: allowed) }.map { (message, $0) }
    }
    let root: AnyView
    if let (message, link) = selected {
      if link.state == .pending, presentationStyle == .compact { requestPresentationStyle(.expanded) }
      root = AnyView(
        RespondView(link: link) { value in
          try await self.submit(value, link: link, message: message, conversation: conversation)
        })
    } else {
      root = AnyView(
        ComposeView(allowed: allowed) { link in
          try await self.sendRequest(link, conversation: conversation)
        })
    }
    host?.willMove(toParent: nil)
    host?.view.removeFromSuperview()
    host?.removeFromParent()
    let controller = UIHostingController(rootView: root)
    addChild(controller)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: view.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    controller.didMove(toParent: self)
    host = controller
  }

  static func layout(_ link: VaultLink) -> MSMessageTemplateLayout {
    let layout = MSMessageTemplateLayout()
    let connected = link.state == .connected
    layout.image = card(link.label, connected: connected)
    layout.caption = connected ? "\(link.label) connected" : "Connect \(link.label)"
    layout.subcaption = connected ? "Sent securely" : "Tap to paste it securely"
    return layout
  }

  static func card(_ label: String, connected: Bool) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { context in
      (connected ? UIColor.systemGreen : UIColor.systemIndigo).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
      let symbol = UIImage(
        systemName: connected ? "checkmark.shield.fill" : "lock.shield.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 110, weight: .semibold))?
        .withTintColor(.white, renderingMode: .alwaysOriginal)
      symbol?.draw(in: CGRect(x: 40, y: 80, width: 130, height: 140))
      (connected ? "Connected" : label).draw(
        in: CGRect(x: 200, y: 110, width: 370, height: 90),
        withAttributes: [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.white])
    }
  }

  /// Line side. MessagePilot opens this app in the line's Messages, types the link into the
  /// field (identifier vault.requestLink) and presses Send (vault.sendRequest).
  func sendRequest(_ link: VaultLink, conversation: MSConversation) async throws {
    let message = MSMessage(session: MSSession())
    message.layout = Self.layout(link)
    message.url = link.bubbleURL
    message.summaryText = "Secure request: \(link.label)"
    try await conversation.send(message)
    dismiss()
  }

  /// Person side: post to the backend, then update the same bubble to Connected.
  func submit(_ value: String, link: VaultLink, message: MSMessage, conversation: MSConversation)
    async throws
  {
    var request = URLRequest(url: link.submitURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try link.submission(
      value: value, device: conversation.localParticipantIdentifier.uuidString)
    // Ephemeral: no cache, cookies or credential storage on disk.
    let session = URLSession(configuration: .ephemeral)
    let (data, response): (Data, URLResponse)
    do { (data, response) = try await session.data(for: request) } catch { throw VaultError.transport }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      throw VaultError.rejected(reason ?? "The service did not accept this value.")
    }
    let done = link.connected()
    let update = MSMessage(session: message.session ?? MSSession())
    update.layout = Self.layout(done)
    update.url = done.bubbleURL
    update.summaryText = "\(link.label) connected"
    try await conversation.send(update)
    dismiss()
  }
}

struct ComposeView: View {
  let allowed: Set<String>
  let send: (VaultLink) async throws -> Void
  @State private var text = ""
  @State private var status = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Request a secret").font(.headline)
      TextField("Request link from the line's backend", text: $text)
        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
        .autocorrectionDisabled().accessibilityIdentifier("vault.requestLink")
      Button("Send request") {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let link = VaultLink.parse(url, allowedHosts: allowed), link.state == .pending
        else {
          status = "That isn't a request link from an allowed service."
          return
        }
        Task {
          do { try await send(link) } catch { status = error.localizedDescription }
        }
      }
      .buttonStyle(.borderedProminent).accessibilityIdentifier("vault.sendRequest")
      if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
    }.padding()
  }
}

struct RespondView: View {
  let link: VaultLink
  let submit: (String) async throws -> Void
  @State private var value = ""
  @State private var busy = false
  @State private var status = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if link.state == .connected {
        Label("\(link.label) is connected", systemImage: "checkmark.shield.fill")
          .font(.title3).accessibilityIdentifier("vault.connected")
      } else {
        Text("Connect \(link.label)").font(.title2.bold())
        Text("Paste it here. It goes straight to \(link.base.host ?? "the service") and never appears in this conversation.")
          .font(.callout).foregroundStyle(.secondary)
        SecureField(link.label, text: $value)
          .textFieldStyle(.roundedBorder).textContentType(.password)
          .privacySensitive().accessibilityIdentifier("vault.secret")
        Button(busy ? "Connecting…" : "Connect") {
          busy = true
          let pasted = value
          value = ""
          Task {
            do { try await submit(pasted) } catch {
              status = error.localizedDescription
              busy = false
            }
          }
        }
        .buttonStyle(.borderedProminent).disabled(busy || value.isEmpty)
        .accessibilityIdentifier("vault.connect")
        if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
      }
    }.padding()
  }
}
