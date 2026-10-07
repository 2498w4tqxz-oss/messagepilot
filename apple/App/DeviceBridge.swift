import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class DeviceBridge: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
  @Published var status = "Disconnected"
  @Published var captureID: String?
  @Published var captureKind = "room"
  private var socket: URLSessionWebSocketTask?
  private var generation = ""
  private var location = CLLocationManager()
  private var pendingLocation: (String, String)?
  private var locationDeadline: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var reconnect: Task<Void, Never>?
  private var shouldConnect = false
  private var outbox: [[String: Any]] = []
  private let appPort = AppPort()
  override init() {
    super.init()
    location.delegate = self
    appPort.event = { [weak self] kind, data in self?.emit(kind: kind, data: data) }
    if let saved = UserDefaults.standard.data(forKey: "device.outbox"),
      let rows = try? JSONSerialization.jsonObject(with: saved) as? [[String: Any]]
    {
      outbox = rows
    }
    if !BridgeSettings.load().accountId.isEmpty { appPort.watchPushStart() }
  }
  func connect() {
    appPort.watchPushStart()
    shouldConnect = true
    socket?.cancel(with: .goingAway, reason: nil)
    do {
      let settings = BridgeSettings.load()
      guard let token = Secrets.get("device-token"), token.count >= 32,
        var parts = URLComponents(string: settings.url), parts.scheme == "https"
      else { throw BridgeIssue("Pair a HTTPS endpoint and device token") }
      parts.scheme = "wss"
      parts.path = "/worker"
      parts.query = nil
      guard let url = parts.url else { throw BridgeIssue("Invalid endpoint") }
      var request = URLRequest(url: url)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let ws = URLSession.shared.webSocketTask(with: request)
      socket = ws
      ws.resume()
      status = "Connecting"
      Task {
        do {
          try await send([
            "type": "hello", "role": "device", "accountId": settings.accountId,
            "workerId": "iphone-\(settings.accountId)", "identity": settings.identity,
            "capabilities": [
              "device.capture", "location.get", "device.auth.biometric", "device.auth.passkey",
              "device.surface.publish", "device.activity.list",
              "device.activity.start", "device.activity.update", "device.activity.end",
            ].map {
              [
                "operation": $0, "available": true, "path": "foreground-ios-companion",
                "verification": "compiled",
                "detail": "Requires an active paired app; capture requires user interaction",
              ] as [String: Any]
            },
          ])
          while self.socket === ws {
            let frame = try await ws.receive()
            if case .string(let text) = frame, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
              await receive(object)
            }
          }
        } catch {
          if self.socket === ws {
            self.status = "Disconnected: \(error.localizedDescription)"
            self.heartbeat?.cancel()
            if self.shouldConnect {
              self.reconnect = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { self.connect() }
              }
            }
          }
        }
      }
    } catch { status = error.localizedDescription }
  }
  func disconnect() {
    shouldConnect = false
    reconnect?.cancel()
    heartbeat?.cancel()
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    status = "Disconnected"
  }
  private func send(_ object: [String: Any]) async throws {
    guard let socket else { throw BridgeIssue("Not connected") }
    let data = try JSONSerialization.data(withJSONObject: object)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }
  private func receive(_ object: [String: Any]) async {
    if object["type"] as? String == "welcome" {
      generation = object["generation"] as? String ?? ""
      status = "Connected while app is active"
      for event in outbox { try? await send(event) }
      heartbeat?.cancel()
      heartbeat = Task {
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 15_000_000_000)
          if !Task.isCancelled { try? await self.send(["type": "heartbeat"]) }
        }
      }
      return
    }
    if object["type"] as? String == "ack", let id = object["sourceId"] as? String {
      outbox.removeAll { $0["sourceId"] as? String == id }
      persist()
      return
    }
    guard object["type"] as? String == "command", let command = object["command"] as? [String: Any],
      let id = command["id"] as? String, let operation = command["operation"] as? String,
      let gen = object["generation"] as? String
    else { return }
    let args = command["args"] as? [String: Any] ?? [:]
    if operation == "device.auth.biometric" || operation == "device.auth.passkey" {
      do {
        let result: [String: Any]
        if operation == "device.auth.biometric" {
          result = try await AuthenticationPort.shared.biometric(
            reason: args["reason"] as? String ?? "Authorize this agent-requested app action",
            allowPasscode: args["allowPasscode"] as? Bool ?? false)
        } else {
          result = try await AuthenticationPort.shared.authorize(
            options: args["options"] as? [String: Any] ?? [:],
            registration: args["registration"] as? Bool ?? false)
        }
        await finish(id, gen, result: result)
      } catch { await finish(id, gen, error: error.localizedDescription) }
      return
    }
    if operation.hasPrefix("device.surface.") || operation.hasPrefix("device.activity.") {
      do { await finish(id, gen, result: try await appPort.execute(operation, args)) } catch {
        await finish(id, gen, error: error.localizedDescription)
      }
      return
    }
    switch operation {
    case "device.capture":
      guard captureID == nil else {
        await finish(id, gen, error: "A capture is already waiting for the user")
        return
      }
      let kind = args["kind"] as? String ?? "room"
      guard ["room", "ar"].contains(kind) else {
        await finish(id, gen, error: "Capture kind must be room or ar")
        return
      }
      captureID = id
      captureKind = kind
      await finish(id, gen, result: ["state": "awaiting_user", "captureId": id, "kind": kind])
    case "location.get":
      guard pendingLocation == nil else {
        await finish(id, gen, error: "Location request already pending")
        return
      }
      pendingLocation = (id, gen)
      locationDeadline = Task {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        if !Task.isCancelled, let p = self.pendingLocation {
          self.pendingLocation = nil
          await self.finish(p.0, p.1, error: "Location request timed out")
        }
      }
      if location.authorizationStatus == .notDetermined {
        location.requestWhenInUseAuthorization()
      } else {
        location.requestLocation()
      }
    default: await finish(id, gen, error: "Unsupported device operation")
    }
  }
  private func finish(
    _ id: String, _ gen: String, result: [String: Any] = [:], error: String? = nil
  ) async {
    var frame: [String: Any] = [
      "type": "result", "commandId": id, "generation": gen, "ok": error == nil, "result": result,
    ]
    if let error { frame["error"] = error }
    try? await send(frame)
  }
  func emit(kind: String, data: [String: Any]) {
    let event: [String: Any] = [
      "type": "event", "sourceId": UUID().uuidString, "kind": kind, "data": data,
    ]
    outbox.append(event)
    persist()
    Task {
      if kind == "device.activity.token" {
        await sendActivityEvent(event)
      } else {
        try? await send(event)
      }
    }
  }
  private func sendActivityEvent(_ event: [String: Any]) async {
    // ActivityKit grants limited background runtime for token rotation. Use HTTP;
    // no foreground-only WebSocket connection or permanent background loop is needed.
    do {
      guard let token = Secrets.get("device-token"), let source = event["sourceId"] as? String
      else { return }
      var parts = URLComponents(
        url: try BridgeSettings.load().endpoint("events"), resolvingAgainstBaseURL: false)!
      parts.path = "/v1/device-events"
      var request = URLRequest(url: parts.url!, timeoutInterval: 15)
      request.httpMethod = "POST"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: event)
      let (_, response) = try await URLSession.shared.data(for: request)
      if (response as? HTTPURLResponse)?.statusCode == 200 {
        outbox.removeAll { $0["sourceId"] as? String == source }
        persist()
      }
    } catch { /* Retain for the next foreground reconnect if background delivery fails. */  }
  }
  private func persist() {
    UserDefaults.standard.set(
      try? JSONSerialization.data(withJSONObject: outbox), forKey: "device.outbox")
  }
  func captureFinished(_ data: [String: Any]) {
    guard let id = captureID else { return }
    emit(kind: "device.capture.completed", data: ["captureId": id, "result": data])
    captureID = nil
  }
  func cancelCapture() {
    guard let id = captureID else { return }
    emit(kind: "device.capture.cancelled", data: ["captureId": id])
    captureID = nil
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard let pending = pendingLocation else { return }
    if [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) {
      manager.requestLocation()
    } else if [.denied, .restricted].contains(manager.authorizationStatus) {
      pendingLocation = nil
      locationDeadline?.cancel()
      Task { await finish(pending.0, pending.1, error: "Location permission denied") }
    }
  }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let p = pendingLocation, let value = locations.last else { return }
    pendingLocation = nil
    locationDeadline?.cancel()
    Task {
      await finish(
        p.0, p.1,
        result: [
          "latitude": value.coordinate.latitude, "longitude": value.coordinate.longitude,
          "horizontalAccuracy": value.horizontalAccuracy,
          "timestamp": value.timestamp.timeIntervalSince1970, "source": "core-location-own-device",
        ])
    }
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let p = pendingLocation else { return }
    pendingLocation = nil
    locationDeadline?.cancel()
    Task { await finish(p.0, p.1, error: error.localizedDescription) }
  }
}
