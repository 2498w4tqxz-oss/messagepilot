import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { VaultService, startVaultServer } from "../src/vault.js";

const admin = "admin-" + "x".repeat(40);
function setup(t: any, now = () => Date.now()) {
  const dir = mkdtempSync(join(tmpdir(), "mp-vault-"));
  const vault = new VaultService(
    join(dir, "vault.sqlite"),
    randomBytes(32),
    "http://127.0.0.1:4390",
    now,
  );
  t.after(() => {
    vault.close();
    rmSync(dir, { recursive: true, force: true });
  });
  return { vault, dir };
}
const tokenOf = (url: string) =>
  new URLSearchParams(new URL(url).hash.slice(1)).get("t")!;

test("a vault request is single-use, token-bound and never stores plaintext", (t) => {
  const { vault, dir } = setup(t);
  const req = vault.create({
    line: "door",
    recipient: "+15550100100",
    label: "Lofty API key",
  });
  const url = new URL(req.url);
  assert.equal(url.pathname, `/v1/vault/r/${req.id}`);
  assert.equal(url.searchParams.get("state"), "pending");
  assert.match(
    url.search,
    /label=Lofty%20API%20key/,
    "spaces percent-encoded for URLComponents",
  );
  assert.equal(
    url.searchParams.get("t"),
    null,
    "token never travels in the query string",
  );
  assert.throws(
    () => vault.submit({ id: req.id, token: "wrong", value: "sk_live_123" }),
    /invalid/,
  );
  const ok = vault.submit({
    id: req.id,
    token: tokenOf(req.url),
    value: "sk_live_123",
    device: "uuid-1",
  });
  assert.deepEqual(ok, { state: "connected", label: "Lofty API key" });
  assert.throws(
    () => vault.submit({ id: req.id, token: tokenOf(req.url), value: "again" }),
    /invalid/,
  );
  const status = vault.status(req.id)!;
  assert.equal(status.state, "connected");
  assert.equal(status.device, "uuid-1");
  assert.ok(
    !JSON.stringify(status).includes("sk_live_123"),
    "status never carries the value",
  );
  const stored = readdirSync(dir).map((f) => readFileSync(join(dir, f)));
  assert.ok(
    stored.some((b) => b.includes("Lofty API key")),
    "database files were read",
  );
  assert.ok(
    !stored.some((b) => b.includes("sk_live_123")),
    "encrypted at rest, WAL included",
  );
  assert.equal(vault.reveal(req.id), "sk_live_123");
});

test("vault requests expire and lock after repeated bad tokens", (t) => {
  let clock = 1_000_000;
  const { vault } = setup(t, () => clock);
  const req = vault.create({
    line: "door",
    recipient: "+15550100100",
    label: "Key",
    ttlSeconds: 60,
  });
  clock += 61_000;
  assert.equal(vault.status(req.id)!.state, "expired");
  assert.throws(
    () => vault.submit({ id: req.id, token: tokenOf(req.url), value: "v" }),
    /expired/,
  );
  const locked = vault.create({
    line: "door",
    recipient: "+15550100100",
    label: "Key",
  });
  for (let i = 0; i < 5; i++)
    assert.throws(() =>
      vault.submit({ id: locked.id, token: "guess" + i, value: "v" }),
    );
  assert.throws(
    () =>
      vault.submit({ id: locked.id, token: tokenOf(locked.url), value: "v" }),
    /invalid/,
  );
});

test("vault HTTP surface: admin-only minting, public submit, no secret in responses", async (t) => {
  const { vault } = setup(t);
  const server = await startVaultServer(vault, admin, "127.0.0.1", 0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  const unauthorized = await fetch(`${base}/v1/vault/requests`, {
    method: "POST",
    body: "{}",
  });
  assert.equal(unauthorized.status, 401);
  const created = await fetch(`${base}/v1/vault/requests`, {
    method: "POST",
    headers: { authorization: `Bearer ${admin}` },
    body: JSON.stringify({
      line: "door",
      recipient: "+15550100100",
      label: "Lofty API key",
    }),
  });
  assert.equal(created.status, 201);
  const req = (await created.json()) as { id: string; url: string };
  const page = await fetch(`${base}/v1/vault/r/${req.id}`);
  assert.equal(page.status, 200);
  assert.match(
    page.headers.get("content-security-policy") ?? "",
    /form-action 'none'/,
  );
  const submit = await fetch(`${base}/v1/vault/submit`, {
    method: "POST",
    body: JSON.stringify({
      id: req.id,
      token: tokenOf(req.url),
      value: "sk_live_secret",
    }),
  });
  const body = await submit.text();
  assert.equal(submit.status, 200);
  assert.ok(!body.includes("sk_live_secret"));
  const status = await fetch(`${base}/v1/vault/requests/${req.id}`, {
    headers: { authorization: `Bearer ${admin}` },
  });
  const json = await status.text();
  assert.match(json, /"state":"connected"/);
  assert.ok(!json.includes("sk_live_secret"));
  const replay = await fetch(`${base}/v1/vault/submit`, {
    method: "POST",
    body: JSON.stringify({ id: req.id, token: tokenOf(req.url), value: "x" }),
  });
  assert.equal(replay.status, 400);
});

test("vault refuses cleartext public URLs except loopback", () => {
  assert.throws(
    () =>
      new VaultService(":memory:", randomBytes(32), "http://vault.example.com"),
    /https/,
  );
  assert.doesNotThrow(() =>
    new VaultService(
      ":memory:",
      randomBytes(32),
      "https://vault.example.com",
    ).close(),
  );
});
