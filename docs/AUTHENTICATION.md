# Optional passkeys and local biometrics

Passkeys are disabled on the gateway unless `passkeys` is configured. Native authentication is included only in the optional primary app port. Agent-to-worker tokens continue to work independently; passkey sign-in does not grant a person or a card recipient control of an agent's computer.

## Configure an app and relying party

```sh
node dist/src/cli.js app-create /agent/workspace/SecureApp com.example.secure \
  --primary-port --passkey-domain bridge.example.com
```

The equivalent `apps.create` arguments are `primaryPort: true` and `passkeyDomain: "bridge.example.com"`. XcodeGen adds the host's `webcredentials` Associated Domains entitlement. Replace the example domain with the domain you control, and use the matching real developer team when signing.

Add this optional block to the gateway configuration:

```json
{
  "passkeys": {
    "rpId": "bridge.example.com",
    "origin": "https://bridge.example.com",
    "appIds": ["YOURTEAMID.com.example.secure.app"]
  }
}
```

The gateway serves `/.well-known/apple-app-site-association` with the configured `webcredentials.apps`. Host it on that exact HTTPS domain without redirecting the AASA request. The domain must match the relying-party ID and expected native WebAuthn origin. Apple must approve the signed app/domain association on the installed device. [Apple passkey support](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys), [Apple's connection sample](https://developer.apple.com/documentation/authenticationservices/connecting-to-a-service-with-passkeys).

## Enrollment and sign-in

Pair the primary app with an owner bootstrap credential authorized for the account's `computer.input` scope. Tap Register passkey. Enrollment options and verification are authenticated endpoints under `/v1/accounts/{account}/passkeys/register-options` and `/register-verify`. A card-only session cannot enroll or revoke credentials.

Successful registration removes the bootstrap agent token from that phone's Keychain; it does not revoke the owner's server-side credential. Tap Sign in with passkey to obtain a one-hour private-card session. The native AuthenticationServices prompt requires user verification. Depending on system settings, passkey verification can use biometrics or the device's permitted unlock method. MessagePilot cannot emulate Face ID/Touch ID or bypass Apple's prompt.

Public sign-in endpoints are `/v1/passkeys/signin-options` and `/signin-verify`, each with `accountId`. Options return `{challengeId, options}`; verification accepts `{accountId, challengeId, response}`. The native port also exposes `device.auth.passkey` for developers using their own relying-party server: pass standard WebAuthn options and a `registration` flag, then verify the returned credential on that server. Client output alone is not an authentication decision.

The included server uses [SimpleWebAuthn](https://simplewebauthn.dev/docs/packages/server) to verify challenge, origin, relying-party hash, user verification and signatures. Challenges are account-bound, single-use and expire in two minutes. Stored credential counters prevent replay where the authenticator supplies counters; synchronized passkeys may use zero counters, so single-use challenges remain essential. Session tokens are hashed in SQLite, expire after one hour, and grant only private card reads/writes/actions. They cannot enqueue Messages commands, access account event history, enroll workers, connect MCP servers, or take over a computer.

An owner can list credentials with `GET /v1/accounts/{account}/passkeys`, revoke one and its sessions with `DELETE /v1/accounts/{account}/passkeys/{credentialId}`, or a signed-in app can terminate its session with `POST /v1/accounts/{account}/passkeys/logout`. Configure infrastructure rate limits for internet-facing sign-in routes. Pending challenge counts are bounded per account. No registration was performed against a real device in this build.

## Local biometric actions

`device.auth.biometric` uses LocalAuthentication in the active primary app. Supply a human-readable `reason`; `allowPasscode` defaults to false. A successful result is **local authorization only**, marked `serverProof: false`. Developers can invoke the same API directly before a local action. A remote service needing cryptographic proof should use a verified passkey assertion instead of trusting an RPC boolean.

Face ID usage text is included in the optional primary app. Device capability, enrolled biometrics, locked state, and user cancellation determine the outcome. Agents may request the system prompt but cannot satisfy it on behalf of a person. The simulator targets compile; physical biometric acceptance and domain association remain untested.
