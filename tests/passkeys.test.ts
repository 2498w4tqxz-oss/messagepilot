import test from "node:test";
import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  randomBytes,
  sign,
} from "node:crypto";
import { encodeCBOR } from "@levischuck/tiny-cbor";
import { Store } from "../src/store.js";
import { Passkeys } from "../src/passkeys.js";
import { Gateway } from "../src/gateway.js";
import { BridgeClient } from "../src/client.js";
const configuration = {
  rpId: "fixture.example",
  origin: "https://fixture.example",
  appIds: ["TESTTEAM.dev.example.app"],
};
function authenticator() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const jwk = publicKey.export({ format: "jwk" });
  const cose = encodeCBOR(
    new Map<any, any>([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, new Uint8Array(Buffer.from(jwk.x!, "base64url"))],
      [-3, new Uint8Array(Buffer.from(jwk.y!, "base64url"))],
    ]),
  );
  const id = randomBytes(32);
  const base = {
    id: id.toString("base64url"),
    rawId: id.toString("base64url"),
    type: "public-key",
    authenticatorAttachment: "platform",
    clientExtensionResults: {},
  };
  const authData = (
    flags: number,
    counter: number,
    rp = configuration.rpId,
  ) => {
    const count = Buffer.alloc(4);
    count.writeUInt32BE(counter);
    return Buffer.concat([
      createHash("sha256").update(rp).digest(),
      Buffer.from([flags]),
      count,
    ]);
  };
  return {
    registration(challenge: string) {
      const length = Buffer.alloc(2);
      length.writeUInt16BE(id.length);
      const data = Buffer.concat([
        authData(0x45, 0),
        Buffer.alloc(16),
        length,
        id,
        cose,
      ]);
      const attestation = encodeCBOR(
        new Map<any, any>([
          ["fmt", "none"],
          ["attStmt", new Map()],
          ["authData", new Uint8Array(data)],
        ]),
      );
      return {
        ...base,
        response: {
          clientDataJSON: Buffer.from(
            JSON.stringify({
              type: "webauthn.create",
              challenge,
              origin: configuration.origin,
            }),
          ).toString("base64url"),
          attestationObject: Buffer.from(attestation).toString("base64url"),
          transports: ["internal"],
        },
      };
    },
    assertion(
      challenge: string,
      counter = 1,
      flags = 5,
      origin = configuration.origin,
      rp = configuration.rpId,
    ) {
      const client = Buffer.from(
        JSON.stringify({ type: "webauthn.get", challenge, origin }),
      );
      const data = authData(flags, counter, rp);
      const signature = sign(
        "sha256",
        Buffer.concat([data, createHash("sha256").update(client).digest()]),
        privateKey,
      );
      return {
        ...base,
        response: {
          clientDataJSON: client.toString("base64url"),
          authenticatorData: data.toString("base64url"),
          signature: signature.toString("base64url"),
        },
      };
    },
  };
}
test("passkey registration/sign-in verify real signatures and bind cards-only sessions to the enrolled account", async () => {
  const A = "owner-".padEnd(40, "a"),
    W = "worker-".padEnd(40, "w"),
    B = "other-".padEnd(40, "b");
  const gateway = new Gateway(
    {
      host: "127.0.0.1",
      port: 0,
      database: ":memory:",
      passkeys: configuration,
      accounts: [
        { id: "a", identity: "a@example.test", workerTokenEnv: "W" },
        { id: "b", identity: "b@example.test", workerTokenEnv: "B" },
      ],
      agents: [{ id: "owner", tokenEnv: "A", accounts: ["a", "b"] }],
    },
    { A, W, B },
  );
  const port = await gateway.listen(),
    url = `http://127.0.0.1:${port}`;
  const owner = new BridgeClient(url, A),
    device = authenticator();
  const post = async (path: string, body: any) =>
    fetch(`${url}/v1/passkeys/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  try {
    const aasa = await (
      await fetch(`${url}/.well-known/apple-app-site-association`)
    ).json();
    assert.deepEqual(aasa.webcredentials.apps, configuration.appIds);
    const options = await owner.request(
      "a",
      "passkeys/register-options",
      "POST",
      {},
    );
    const registered = await owner.request(
      "a",
      "passkeys/register-verify",
      "POST",
      {
        challengeId: options.challengeId,
        response: device.registration(options.options.challenge),
      },
    );
    assert.equal(registered.registered, true);
    const start = await (
      await post("signin-options", { accountId: "a" })
    ).json();
    const payload = {
      accountId: "a",
      challengeId: start.challengeId,
      response: device.assertion(start.options.challenge),
    };
    const response = await post("signin-verify", payload);
    assert.equal(response.status, 200);
    const session = await response.json();
    const cardClient = new BridgeClient(url, session.token);
    await owner.request("a", "cards/auth-test", "PUT", {
      expectedRevision: 0,
      body: { title: "Private", items: [] },
    });
    assert.equal(
      (await cardClient.request("a", "cards/auth-test")).body.title,
      "Private",
    );
    await assert.rejects(
      cardClient.command("a", "computer.exec", { executable: "/usr/bin/true" }),
      /403/,
    );
    await assert.rejects(
      cardClient.command("a", "messages.send", {
        chatId: "x",
        text: "blocked",
      }),
      /403/,
    );
    await assert.rejects(cardClient.request("b", "cards/auth-test"), /403/);
    assert.equal((await post("signin-verify", payload)).status, 401);
    await owner.request("a", `passkeys/${registered.credentialId}`, "DELETE");
    await assert.rejects(cardClient.request("a", "cards/auth-test"), /401/);
  } finally {
    await gateway.close();
  }
});
test("passkeys reject wrong origins, wrong relying parties, missing verification, replay and expired challenges", async () => {
  const store = new Store(":memory:"),
    keys = new Passkeys(store.db, configuration),
    device = authenticator();
  try {
    const registration = await keys.registrationOptions("a");
    await keys.register(
      "a",
      registration.challengeId,
      device.registration(registration.options.challenge),
    );
    for (const [flags, origin, rp] of [
      [5, "https://attacker.example", configuration.rpId],
      [1, configuration.origin, configuration.rpId],
      [5, configuration.origin, "wrong.example"],
    ] as const) {
      const options = await keys.authenticationOptions("a");
      await assert.rejects(
        keys.authenticate(
          "a",
          options.challengeId,
          device.assertion(options.options.challenge, 1, flags, origin, rp),
        ),
      );
    }
    const options = await keys.authenticationOptions("a");
    store.db.prepare("UPDATE passkey_challenges SET expires=0").run();
    await assert.rejects(
      keys.authenticate(
        "a",
        options.challengeId,
        device.assertion(options.options.challenge),
      ),
      /expired/,
    );
    await assert.rejects(keys.authenticationOptions("b"), /No passkey/);
    assert.throws(
      () =>
        new Passkeys(store.db, {
          ...configuration,
          origin: "http://fixture.example",
        }),
      /HTTPS/,
    );
  } finally {
    store.close();
  }
});
