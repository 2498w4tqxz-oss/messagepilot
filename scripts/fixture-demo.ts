import { Gateway } from "../src/gateway.js";
import { Worker } from "../src/worker.js";
import { FixtureTransport } from "../src/native.js";
import { BridgeClient } from "../src/client.js";
import { randomBytes } from "node:crypto";
const W = randomBytes(32).toString("hex"),
  A = randomBytes(32).toString("hex");
const gateway = new Gateway(
  {
    host: "127.0.0.1",
    port: 0,
    database: ":memory:",
    accounts: [
      { id: "demo", identity: "fixture@example.test", workerTokenEnv: "W" },
    ],
    agents: [{ id: "demo", tokenEnv: "A", accounts: ["demo"] }],
  },
  { W, A },
);
const port = await gateway.listen();
const worker = new Worker(
  {
    url: `ws://127.0.0.1:${port}/worker`,
    token: W,
    accountId: "demo",
    workerId: "fixture",
    identity: "fixture@example.test",
    spool: ":memory:",
  },
  new FixtureTransport("fixture@example.test"),
);
const client = new BridgeClient(`http://127.0.0.1:${port}`, A);
try {
  await worker.start();
  while (!(await client.request("demo", "capabilities")).online)
    await new Promise((r) => setTimeout(r, 5));
  const command = await client.command(
    "demo",
    "messages.send",
    { chatId: "fixture-only", text: "Hello from MessagePilot" },
    "demo",
  );
  console.log(JSON.stringify(await client.wait("demo", command.id), null, 2));
} finally {
  worker.close();
  await gateway.close();
}
