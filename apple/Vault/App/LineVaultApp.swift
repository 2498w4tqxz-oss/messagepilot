import SwiftUI

/// Containing app. Its only job is to carry the Messages extension; people use the vault from
/// a bubble in Messages.
@main struct LineVaultApp: App {
  var body: some Scene {
    WindowGroup {
      VStack(spacing: 16) {
        Image(systemName: "lock.shield.fill").font(.system(size: 64)).foregroundStyle(.indigo)
        Text("Secure connections").font(.title.bold())
        Text(
          "When a line asks you for a key or password in Messages, tap its bubble. You paste the value there and it goes straight to the service, never into the conversation."
        )
        .multilineTextAlignment(.center).foregroundStyle(.secondary)
      }.padding(32)
    }
  }
}
