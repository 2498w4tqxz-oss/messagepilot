import ARKit
import RoomPlan
import SwiftUI

@main struct MessagePilotApp: App {
  @StateObject private var device = DeviceBridge()
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      SetupView().environmentObject(device).onChange(of: phase) { _, value in
        if value == .background { device.disconnect() }
      }
    }
  }
}
struct SetupView: View {
  @EnvironmentObject var device: DeviceBridge
  @State private var settings = BridgeSettings.load()
  @State private var agentToken = ""
  @State private var deviceToken = ""
  @State private var error = ""
  @State private var capturing = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Bridge connection") {
          TextField("HTTPS bridge URL", text: $settings.url).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("Account ID", text: $settings.accountId).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("Agent Apple identity", text: $settings.identity).textInputAutocapitalization(
            .never
          ).autocorrectionDisabled()
          SecureField("Agent token for cards", text: $agentToken)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .textContentType(.oneTimeCode)
          SecureField("Device worker token", text: $deviceToken)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .textContentType(.oneTimeCode)
          Button("Save pairing") {
            do {
              guard
                settings.accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
              else { throw BridgeIssue("Invalid account ID") }
              _ = try settings.endpoint("capabilities")
              guard agentToken.isEmpty || agentToken.count >= 32,
                deviceToken.isEmpty || deviceToken.count >= 32
              else {
                throw BridgeIssue("Tokens must contain at least 32 characters")
              }
              if !agentToken.isEmpty { try Secrets.put("agent-token", agentToken) }
              if !deviceToken.isEmpty { try Secrets.put("device-token", deviceToken) }
              settings.save()
              agentToken = ""
              deviceToken = ""
              error = ""
            } catch { self.error = error.localizedDescription }
          }
        }
        Section("Phone capabilities") {
          Text(device.status)
          Button("Connect device bridge") { device.connect() }
          Button("Disconnect") { device.disconnect() }
          Text(
            "Location and camera requests run while this app is active. Agents receive explicit capture events."
          ).font(.caption)
          if let id = device.captureID {
            Text("Capture requested: \(device.captureKind)")
            Text(id).font(.caption)
            Button("Start capture") { capturing = true }
            Button("Decline") { device.cancelCapture() }
          }
        }
        Section("Messages") {
          Text(
            "Open MessagePilot in the Messages app to load and send agent-authored carousels, previews, and interactive cards."
          )
        }
        Section("Optional authentication") {
          Button("Register passkey") { Task { await authenticate(register: true) } }
          Button("Sign in with passkey") { Task { await authenticate(register: false) } }
          Button("Sign out") {
            Task {
              do {
                try await AuthenticationPort.shared.signOut()
                error = "Signed out"
              } catch { self.error = error.localizedDescription }
            }
          }
          Button("Verify with biometrics") {
            Task {
              do {
                _ = try await AuthenticationPort.shared.biometric(
                  reason: "Authorize this MessagePilot app action")
                error = "Local authentication succeeded"
              } catch { self.error = error.localizedDescription }
            }
          }
          Text(
            "Passkeys require the configured relying-party domain and associated-domain entitlement. System authentication requires a person."
          ).font(.caption)
        }
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
      }.navigationTitle("MessagePilot").sheet(isPresented: $capturing) {
        if device.captureKind == "room" && RoomCaptureSession.isSupported {
          RoomScanner(onDone: { data in
            device.captureFinished(data)
            capturing = false
          })
        } else if device.captureKind == "ar" && ARWorldTrackingConfiguration.isSupported {
          ARCapture(onDone: { data in
            device.captureFinished(data)
            capturing = false
          })
        } else {
          VStack {
            Text("This capture is not supported by this device.")
            Button("Close") {
              capturing = false
              device.cancelCapture()
            }
          }.padding()
        }
      }
    }
  }
}
extension SetupView {
  private func authenticate(register: Bool) async {
    do {
      try await AuthenticationPort.shared.signIn(register: register)
      error = register ? "Passkey registered" : "Signed in for private cards"
    } catch { self.error = error.localizedDescription }
  }
}
struct RoomScanner: UIViewRepresentable {
  let onDone: ([String: Any]) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(onDone) }
  func makeUIView(context: Context) -> RoomCaptureView {
    let view = RoomCaptureView(frame: .zero)
    view.delegate = context.coordinator
    let button = UIButton(type: .system)
    button.setTitle("Finish scan", for: .normal)
    button.backgroundColor = .systemBackground
    button.layer.cornerRadius = 12
    button.addAction(UIAction { [weak view] _ in view?.captureSession.stop() }, for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
      button.widthAnchor.constraint(equalToConstant: 160),
      button.heightAnchor.constraint(equalToConstant: 48),
    ])
    view.captureSession.run(configuration: RoomCaptureSession.Configuration())
    return view
  }
  func updateUIView(_ view: RoomCaptureView, context: Context) {}
  static func dismantleUIView(_ view: RoomCaptureView, coordinator: Coordinator) {
    view.captureSession.stop()
  }
  @objc(MPRoomCaptureCoordinator) final class Coordinator: NSObject, RoomCaptureViewDelegate {
    let done: ([String: Any]) -> Void
    init(_ done: @escaping ([String: Any]) -> Void) { self.done = done }
    required init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {}  // This transient delegate is never archived.
    func captureView(shouldPresent roomData: CapturedRoomData, error: Error?) -> Bool {
      if let error {
        done(["error": error.localizedDescription])
        return false
      }
      return true
    }
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
      do {
        let data = try JSONEncoder().encode(processedResult)
        let object = try JSONSerialization.jsonObject(with: data)
        done(["kind": "room", "room": object, "capturedAt": Date().timeIntervalSince1970])
      } catch { done(["error": error.localizedDescription]) }
    }
  }
}
struct ARCapture: View {
  let onDone: ([String: Any]) -> Void
  @State private var view = ARSCNView(frame: .zero)
  var body: some View {
    ZStack(alignment: .bottom) {
      ARView(view: view).ignoresSafeArea()
      Button("Capture AR pose") {
        if let frame = view.session.currentFrame {
          let t = frame.camera.transform
          onDone([
            "kind": "ar", "timestamp": Date().timeIntervalSince1970,
            "cameraTransform": [t.columns.0, t.columns.1, t.columns.2, t.columns.3].map {
              [$0.x, $0.y, $0.z, $0.w]
            }, "tracking": "\(frame.camera.trackingState)",
          ])
        }
      }.buttonStyle(.borderedProminent).padding()
    }.onDisappear { view.session.pause() }
  }
}
struct ARView: UIViewRepresentable {
  let view: ARSCNView
  func makeUIView(context: Context) -> ARSCNView {
    view.session.run(ARWorldTrackingConfiguration())
    return view
  }
  func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
