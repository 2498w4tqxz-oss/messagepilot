import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { userInfo } from "node:os";
import { z } from "zod";
import { Gateway } from "./gateway.js";
import { Worker } from "./worker.js";
import { FixtureTransport, NativeProcess } from "./native.js";
import { configSchema } from "./protocol.js";
import { startMCP } from "./mcp.js";
import { createApp } from "./scaffold.js";
const [command, file, ...rest] = process.argv.slice(2);
const secret = (key: string) => {
  const v = process.env[key];
  if (!v || v.length < 32)
    throw new Error(`Missing ${key}: at least 32 characters required`);
  return v;
};
async function main() {
  if (command === "gateway") {
    if (!file) throw new Error("Usage: gateway config.json");
    const config = configSchema.parse(JSON.parse(readFileSync(file, "utf8")));
    config.database = resolve(config.database);
    const g = new Gateway(config);
    const port = await g.listen();
    process.stderr.write(
      `MessagePilot bridge listening on ${config.host}:${port}\n`,
    );
    const stop = () => void g.close().then(() => process.exit());
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
  } else if (command === "worker") {
    if (!file) throw new Error("Usage: worker config.json [--live]");
    const config = z
      .object({
        accountId: z.string(),
        workerId: z.string(),
        identity: z.string(),
        url: z.string().url(),
        tokenEnv: z.string(),
        spool: z.string(),
        mode: z.enum(["fixture", "live"]),
        nativeBinary: z.string().optional(),
        nativeConfig: z.string().optional(),
        expectedOSUser: z.string().optional(),
      })
      .parse(JSON.parse(readFileSync(file, "utf8")));
    const url = new URL(config.url);
    if (!["ws:", "wss:"].includes(url.protocol))
      throw new Error("Worker URL must use ws or wss");
    if (
      url.protocol === "ws:" &&
      !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
    )
      throw new Error("Remote workers require wss");
    if (
      config.mode === "live" &&
      (!rest.includes("--live") ||
        !config.expectedOSUser ||
        userInfo().username !== config.expectedOSUser ||
        !config.nativeBinary ||
        !config.nativeConfig)
    )
      throw new Error(
        "Live worker requires --live, matching dedicated OS user, nativeBinary, and nativeConfig",
      );
    const native =
      config.mode === "fixture"
        ? new FixtureTransport(config.identity)
        : new NativeProcess(resolve(config.nativeBinary!), [
            "--live",
            "--config",
            resolve(config.nativeConfig!),
          ]);
    const w = new Worker(
      {
        ...config,
        spool: resolve(config.spool),
        token: secret(config.tokenEnv),
      },
      native,
    );
    await w.start();
    process.stderr.write(
      `MessagePilot ${config.mode} worker started for ${config.accountId}\n`,
    );
    const stop = () => {
      w.close();
      process.exit();
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
  } else if (command === "mcp") {
    await startMCP(
      process.env.MESSAGEPILOT_URL ?? "http://127.0.0.1:4380",
      secret("MESSAGEPILOT_AGENT_TOKEN"),
    );
  } else if (command === "app-create") {
    if (!file || !rest[0])
      throw new Error("Usage: app-create <output-directory> <bundle-id>");
    await createApp(resolve(file), rest[0]);
  } else {
    process.stderr.write(
      "MessagePilot bridge\n  gateway <config.json>\n  worker <config.json> [--live]\n  mcp\n  app-create <output-directory> <bundle-id>\n",
    );
  }
}
main().catch((e) => {
  process.stderr.write(String(e) + "\n");
  process.exitCode = 1;
});
