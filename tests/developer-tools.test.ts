import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { createApp } from "../src/scaffold.js";

test("app generator creates independent app groups and refuses overwrites", async () => {
  const root = await mkdtemp(join(tmpdir(), "mp-app-")),
    destination = join(root, "NewApp");
  try {
    await createApp(destination, "dev.example.newapp");
    assert.match(
      await readFile(join(destination, "project.yml"), "utf8"),
      /dev.example.newapp.app.messages/,
    );
    assert.match(
      await readFile(join(destination, "Shared/BridgeModels.swift"), "utf8"),
      /group.dev.example.newapp/,
    );
    assert.doesNotMatch(
      await readFile(join(destination, "project.yml"), "utf8"),
      /MessagePilotVM|MessagePilotWidgets|NSSupportsLiveActivities|aps-environment/,
    );
    assert.equal(
      (await readdir(join(destination, "App"))).includes("AppPort.swift"),
      false,
    );
    const full = join(root, "FullApp");
    await createApp(full, "dev.example.fullapp", {
      primaryPort: true,
      passkeyDomain: "fixture.example",
    });
    assert.match(
      await readFile(join(full, "project.yml"), "utf8"),
      /webcredentials:fixture.example/,
    );
    await assert.rejects(
      createApp(join(root, "bad-domain"), "dev.example.bad", {
        passkeyDomain: "fixture.example",
      }),
      /requires primaryPort/,
    );
    assert.match(
      await readFile(join(full, "project.yml"), "utf8"),
      /MessagePilotWidgets/,
    );
    assert.match(
      await readFile(join(full, "Widgets/Widgets.entitlements"), "utf8"),
      /group.dev.example.fullapp/,
    );
    assert.ok((await readdir(join(full, "App"))).includes("AppPort.swift"));
    await assert.rejects(createApp(destination, "dev.example.again"), /exists/);
    await assert.rejects(createApp(join(root, "bad"), "invalid"), /Bundle/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
test("iOS recipe preparation requires an enrolled device and never invokes xcodebuild", async () => {
  const root = await mkdtemp(join(tmpdir(), "mp-ios-"));
  try {
    const run = join(root, "tests.xctestrun"),
      recipe = join(root, "recipe.json"),
      enrollment = join(root, "device.json");
    await writeFile(
      run,
      '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Harness</key><dict><key>TestBundlePath</key><string>__TESTROOT__/MessagePilotHarness.xctest</string></dict></dict></plist>',
    );
    await writeFile(
      recipe,
      JSON.stringify({
        bundleId: "com.example.fixture",
        actions: [{ action: "snapshot" }],
      }),
    );
    await writeFile(
      enrollment,
      JSON.stringify({
        purpose: "messagepilot-agent-device",
        deviceId: "FAKE-DEVICE-NOT-CONNECTED",
        allowedBundles: ["com.example.fixture"],
      }),
    );
    const script = resolve("scripts/run-ios.py"),
      args = [
        script,
        "--xctestrun",
        run,
        "--recipe",
        recipe,
        "--device-id",
        "FAKE-DEVICE-NOT-CONNECTED",
        "--enrollment",
        enrollment,
        "--result",
        join(root, "results"),
        "--prepare-only",
      ];
    const result = spawnSync("python3", args, { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /"prepared": true/);
    assert.deepEqual((await readdir(root)).sort(), [
      "device.json",
      "recipe.json",
      "tests.xctestrun",
    ]);
    await writeFile(
      enrollment,
      JSON.stringify({
        purpose: "personal",
        deviceId: "FAKE-DEVICE-NOT-CONNECTED",
      }),
    );
    const denied = spawnSync("python3", args, { encoding: "utf8" });
    assert.notEqual(denied.status, 0);
    assert.match(denied.stderr, /not explicitly enrolled/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("native process multiplexes requests and reports exit without touching Apple APIs", async () => {
  const { NativeProcess } = await import("../src/native.js");
  const script = `const r=require('node:readline').createInterface({input:process.stdin});r.on('line',line=>{const q=JSON.parse(line);if(q.method==='exit'){process.exit(0);return;}setTimeout(()=>process.stdout.write(JSON.stringify({id:q.id,result:{method:q.method}})+'\\n'),q.method==='slow'?40:1);});`;
  const native = new NativeProcess(process.execPath, ["-e", script]);
  try {
    const order: string[] = [];
    await Promise.all([
      native.request("slow").then(() => order.push("slow")),
      native.request("fast").then(() => order.push("fast")),
    ]);
    assert.deepEqual(order, ["fast", "slow"]);
    const exited = new Promise<void>((resolve) => native.onExit(resolve));
    await assert.rejects(native.request("exit"), /exited/);
    await exited;
    await assert.rejects(native.request("later"), /offline/);
  } finally {
    native.close();
  }
});
