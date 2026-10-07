import SwiftUI

/// Minimal containing app. The optional primary app port is not included in this target.
@main struct MessagePilotApp: App {
  var body: some Scene { WindowGroup { MinimalSetup() } }
}
struct MinimalSetup: View {
  @State private var settings = BridgeSettings.load()
  @State private var token = ""
  @State private var status = ""
  var body: some View {
    Form {
      Text("MessagePilot Messages extension").font(.headline)
      TextField("HTTPS gateway", text: $settings.url).textInputAutocapitalization(.never)
      TextField("Account ID", text: $settings.accountId).textInputAutocapitalization(.never)
      SecureField("Card access token", text: $token)
      Button("Save pairing") {
        do {
          guard settings.accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw BridgeIssue("Invalid account ID") }
          _ = try settings.endpoint("capabilities")
          if !token.isEmpty { try Secrets.put("agent-token", token) }
          settings.save(); token = ""; status = "Open this extension in Messages."
        } catch { status = error.localizedDescription }
      }
      Text(status)
    }
  }
}
