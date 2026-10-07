import AuthenticationServices
import LocalAuthentication
import UIKit

extension Data {
  fileprivate init?(base64URL: String) {
    let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
  }
  fileprivate var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
}
@MainActor
final class AuthenticationPort: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  static let shared = AuthenticationPort()
  private var pending: CheckedContinuation<[String: Any], Error>?
  private var controller: ASAuthorizationController?
  private var deadline: Task<Void, Never>?
  private var window: UIWindow?
  func biometric(reason: String, allowPasscode: Bool = false) async throws -> [String: Any] {
    guard UIApplication.shared.applicationState == .active else {
      throw BridgeIssue("Authentication requires the active primary app")
    }
    let context = LAContext()
    let timeout = Task {
      try? await Task.sleep(nanoseconds: 75_000_000_000)
      if !Task.isCancelled { context.invalidate() }
    }
    defer { timeout.cancel() }
    let policy: LAPolicy =
      allowPasscode ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
    var error: NSError?
    guard context.canEvaluatePolicy(policy, error: &error) else {
      throw error ?? BridgeIssue("Biometric authentication unavailable") as NSError
    }
    let result = try await context.evaluatePolicy(policy, localizedReason: reason)
    return [
      "authenticatedLocally": result, "method": "\(context.biometryType)", "serverProof": false,
    ]
  }
  func authorize(options: [String: Any], registration: Bool) async throws -> [String: Any] {
    guard pending == nil, UIApplication.shared.applicationState == .active,
      let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(
        where: { $0.activationState == .foregroundActive }),
      let window = scene.windows.first(where: { $0.isKeyWindow }),
      let challenge = options["challenge"] as? String, let bytes = Data(base64URL: challenge)
    else {
      throw BridgeIssue("Active primary app, valid challenge and no pending authorization required")
    }
    self.window = window
    let rp =
      registration
      ? (options["rp"] as? [String: Any])?["id"] as? String : options["rpId"] as? String
    guard let rp, !rp.isEmpty else { throw BridgeIssue("Relying party ID required") }
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
    let request: ASAuthorizationRequest
    if registration {
      guard let user = options["user"] as? [String: Any], let name = user["name"] as? String,
        let userID = user["id"] as? String, let data = Data(base64URL: userID)
      else { throw BridgeIssue("Passkey user ID/name required") }
      let registration = provider.createCredentialRegistrationRequest(
        challenge: bytes, name: name, userID: data)
      registration.userVerificationPreference = .required
      request = registration
    } else {
      let assertion = provider.createCredentialAssertionRequest(challenge: bytes)
      assertion.userVerificationPreference = .required
      assertion.allowedCredentials = (options["allowCredentials"] as? [[String: Any]] ?? [])
        .compactMap { value in
          guard let id = value["id"] as? String, let data = Data(base64URL: id) else { return nil }
          return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: data)
        }
      request = assertion
    }
    return try await withCheckedThrowingContinuation { continuation in
      pending = continuation
      let controller = ASAuthorizationController(authorizationRequests: [request])
      self.controller = controller
      controller.delegate = self
      controller.presentationContextProvider = self
      deadline = Task {
        try? await Task.sleep(nanoseconds: 75_000_000_000)
        if !Task.isCancelled {
          self.controller?.cancel()
          self.finish(.failure(BridgeIssue("Authentication timed out")))
        }
      }
      controller.performRequests()
    }
  }
  private func finish(_ result: Result<[String: Any], Error>) {
    deadline?.cancel()
    let continuation = pending
    pending = nil
    controller = nil
    window = nil
    continuation?.resume(with: result)
  }
  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    window ?? UIWindow()
  }
  func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: Error
  ) { finish(.failure(error)) }
  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    if let credential = authorization.credential
      as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
      let attestation = credential.rawAttestationObject
    {
      finish(
        .success([
          "id": credential.credentialID.base64URL, "rawId": credential.credentialID.base64URL,
          "type": "public-key", "authenticatorAttachment": "platform",
          "clientExtensionResults": [:],
          "response": [
            "clientDataJSON": credential.rawClientDataJSON.base64URL,
            "attestationObject": attestation.base64URL, "transports": ["internal"],
          ],
        ]))
    } else if let credential = authorization.credential
      as? ASAuthorizationPlatformPublicKeyCredentialAssertion
    {
      finish(
        .success([
          "id": credential.credentialID.base64URL, "rawId": credential.credentialID.base64URL,
          "type": "public-key", "authenticatorAttachment": "platform",
          "clientExtensionResults": [:],
          "response": [
            "clientDataJSON": credential.rawClientDataJSON.base64URL,
            "authenticatorData": credential.rawAuthenticatorData.base64URL,
            "signature": credential.signature.base64URL, "userHandle": credential.userID.base64URL,
          ],
        ]))
    } else {
      finish(.failure(BridgeIssue("Unsupported passkey response")))
    }
  }
  private func request(_ path: String, payload: [String: Any], enrolled: Bool) async throws
    -> [String: Any]
  {
    let settings = BridgeSettings.load()
    var parts = URLComponents(url: try settings.endpoint(path), resolvingAgainstBaseURL: false)!
    if !enrolled { parts.path = "/v1/passkeys/\(path)" }
    var request = URLRequest(url: parts.url!, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if enrolled {
      guard let token = Secrets.get("agent-token") else {
        throw BridgeIssue("Pair an owner credential to enroll a passkey")
      }
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw BridgeIssue(
        "Authentication endpoint rejected the request; check optional passkey setup")
    }
    return object
  }
  func signIn(register: Bool) async throws {
    let account = BridgeSettings.load().accountId
    let start = try await request(
      register ? "passkeys/register-options" : "signin-options", payload: ["accountId": account],
      enrolled: register)
    guard let options = start["options"] as? [String: Any],
      let challengeID = start["challengeId"] as? String
    else { throw BridgeIssue("Invalid challenge response") }
    let credential = try await authorize(options: options, registration: register)
    let result = try await request(
      register ? "passkeys/register-verify" : "signin-verify",
      payload: ["accountId": account, "challengeId": challengeID, "response": credential],
      enrolled: register)
    if !register {
      guard let token = result["token"] as? String else {
        throw BridgeIssue("No authenticated session returned")
      }
      try Secrets.put("card-session", token)
      BridgeSettings.defaults.set(
        result["expiresAt"] as? Double ?? 0, forKey: "card-session-expiry")
    } else {
      Secrets.remove("agent-token")
      Secrets.remove("card-session")
      BridgeSettings.defaults.removeObject(forKey: "card-session-expiry")
    }
  }
  func signOut() async throws {
    if let token = Secrets.get("card-session") {
      var request = URLRequest(url: try BridgeSettings.load().endpoint("passkeys/logout"))
      request.httpMethod = "POST"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      _ = try await URLSession.shared.data(for: request)
    }
    Secrets.remove("card-session")
    BridgeSettings.defaults.removeObject(forKey: "card-session-expiry")
  }
}
