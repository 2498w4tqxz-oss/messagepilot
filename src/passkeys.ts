import { createHash, randomBytes, randomUUID } from "node:crypto";
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from "@simplewebauthn/server";
import type { DatabaseSync } from "node:sqlite";
import { PilotError, type Operation } from "./protocol.js";
export type PasskeyConfig = { rpId: string; origin: string; appIds: string[] };
const hash = (value: string) =>
  createHash("sha256").update(value).digest("hex");
export class Passkeys {
  constructor(
    private db: DatabaseSync,
    readonly config: PasskeyConfig,
  ) {
    const origin = new URL(config.origin);
    if (
      origin.protocol !== "https:" ||
      origin.origin !== config.origin ||
      origin.hostname !== config.rpId
    )
      throw new Error("Passkeys require an exact HTTPS origin matching rpId");
    db.exec(`CREATE TABLE IF NOT EXISTS passkey_challenges(id TEXT PRIMARY KEY,account TEXT NOT NULL,kind TEXT NOT NULL,challenge TEXT NOT NULL,expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS passkeys(id TEXT PRIMARY KEY,account TEXT NOT NULL,publicKey TEXT NOT NULL,counter INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS passkey_sessions(hash TEXT PRIMARY KEY,account TEXT NOT NULL,credential TEXT NOT NULL,expires INTEGER NOT NULL);`);
  }
  private challenge(account: string, kind: string, challenge: string) {
    this.db
      .prepare("DELETE FROM passkey_challenges WHERE expires<?")
      .run(Date.now());
    this.db
      .prepare("DELETE FROM passkey_sessions WHERE expires<?")
      .run(Date.now());
    const count = this.db
      .prepare(
        "SELECT COUNT(*) AS count FROM passkey_challenges WHERE account=?",
      )
      .get(account)!;
    if (Number(count.count) >= 20)
      throw new PilotError(
        "rate_limited",
        "Too many pending authentication challenges",
        429,
      );
    const id = randomUUID();
    this.db
      .prepare("INSERT INTO passkey_challenges VALUES(?,?,?,?,?)")
      .run(id, account, kind, challenge, Date.now() + 120000);
    return id;
  }
  private consume(account: string, kind: string, id: string) {
    const row = this.db
      .prepare(
        "DELETE FROM passkey_challenges WHERE id=? AND account=? AND kind=? AND expires>? RETURNING challenge",
      )
      .get(id, account, kind, Date.now());
    if (!row)
      throw new PilotError(
        "invalid_challenge",
        "Challenge expired, consumed or belongs to another account",
        401,
      );
    return String(row.challenge);
  }
  credentials(account: string) {
    return this.db
      .prepare("SELECT id FROM passkeys WHERE account=?")
      .all(account)
      .map((row) => ({ id: String(row.id) }));
  }
  async registrationOptions(account: string) {
    const options = await generateRegistrationOptions({
      rpName: "MessagePilot",
      rpID: this.config.rpId,
      userName: account,
      userID: new Uint8Array(
        createHash("sha256").update(`${this.config.rpId}:${account}`).digest(),
      ),
      attestationType: "none",
      supportedAlgorithmIDs: [-7],
      authenticatorSelection: {
        residentKey: "required",
        userVerification: "required",
        authenticatorAttachment: "platform",
      },
      excludeCredentials: this.credentials(account),
    });
    return {
      challengeId: this.challenge(account, "register", options.challenge),
      options,
    };
  }
  async register(account: string, id: string, response: any) {
    const challenge = this.consume(account, "register", id);
    const result = await verifyRegistrationResponse({
      response,
      expectedChallenge: challenge,
      expectedOrigin: this.config.origin,
      expectedRPID: this.config.rpId,
      requireUserVerification: true,
      supportedAlgorithmIDs: [-7],
    });
    if (!result.verified || !result.registrationInfo)
      throw new PilotError(
        "invalid_passkey",
        "Passkey verification failed",
        401,
      );
    const credential = result.registrationInfo.credential;
    this.db
      .prepare("INSERT INTO passkeys VALUES(?,?,?,?)")
      .run(
        credential.id,
        account,
        Buffer.from(credential.publicKey).toString("base64url"),
        credential.counter,
      );
    return { registered: true, credentialId: credential.id };
  }
  async authenticationOptions(account: string) {
    const credentials = this.credentials(account);
    if (!credentials.length)
      throw new PilotError(
        "not_enrolled",
        "No passkey is enrolled for this account",
        404,
      );
    const options = await generateAuthenticationOptions({
      rpID: this.config.rpId,
      userVerification: "required",
      allowCredentials: credentials,
    });
    return {
      challengeId: this.challenge(account, "authenticate", options.challenge),
      options,
    };
  }
  async authenticate(account: string, id: string, response: any) {
    const challenge = this.consume(account, "authenticate", id);
    const credential = this.db
      .prepare("SELECT * FROM passkeys WHERE id=? AND account=?")
      .get(String(response?.id ?? ""), account);
    if (!credential)
      throw new PilotError(
        "invalid_passkey",
        "Credential is not enrolled for this account",
        401,
      );
    const result = await verifyAuthenticationResponse({
      response,
      expectedChallenge: challenge,
      expectedOrigin: this.config.origin,
      expectedRPID: this.config.rpId,
      requireUserVerification: true,
      credential: {
        id: String(credential.id),
        publicKey: new Uint8Array(
          Buffer.from(String(credential.publicKey), "base64url"),
        ),
        counter: Number(credential.counter),
      },
    });
    if (!result.verified)
      throw new PilotError(
        "invalid_passkey",
        "Passkey verification failed",
        401,
      );
    const updated = this.db
      .prepare(
        "UPDATE passkeys SET counter=? WHERE id=? AND account=? AND counter=?",
      )
      .run(
        result.authenticationInfo.newCounter,
        String(credential.id),
        account,
        Number(credential.counter),
      );
    if (Number(updated.changes) !== 1)
      throw new PilotError(
        "credential_changed",
        "Retry authentication with a fresh challenge",
        409,
      );
    const token = randomBytes(32).toString("base64url"),
      expiresAt = Date.now() + 3600000;
    this.db
      .prepare("INSERT INTO passkey_sessions VALUES(?,?,?,?)")
      .run(hash(token), account, String(credential.id), expiresAt);
    return { token, expiresAt, scope: "cards-only", accountId: account };
  }
  principal(token: string) {
    const row = this.db
      .prepare(
        "SELECT s.account,s.credential FROM passkey_sessions s JOIN passkeys p ON p.id=s.credential AND p.account=s.account WHERE s.hash=? AND s.expires>?",
      )
      .get(hash(token), Date.now());
    return row
      ? {
          id: `passkey:${row.credential}`,
          accounts: [String(row.account)],
          operations: ["messages.list", "messages.send"] as Operation[],
          cardOnly: true,
        }
      : undefined;
  }
  logout(token: string) {
    this.db
      .prepare("DELETE FROM passkey_sessions WHERE hash=?")
      .run(hash(token));
  }
  revoke(account: string, credentialId: string) {
    this.db
      .prepare("DELETE FROM passkeys WHERE account=? AND id=?")
      .run(account, credentialId);
    this.db
      .prepare("DELETE FROM passkey_sessions WHERE account=? AND credential=?")
      .run(account, credentialId);
    return { revoked: true };
  }
}
