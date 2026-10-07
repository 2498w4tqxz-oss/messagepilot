import { performance } from "node:perf_hooks";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Gateway } from "../src/gateway.js";
import { Worker } from "../src/worker.js";
import { FixtureTransport } from "../src/native.js";
import { BridgeClient } from "../src/client.js";
import type { Operation } from "../src/protocol.js";
const root = mkdtempSync(join(tmpdir(), "messagepilot-bench-"));
const token = "b".repeat(40),
  agent = "a".repeat(40),
  starts = new Map<string, number>(),
  samples: number[] = [];
class TimedFixture extends FixtureTransport {
  override async execute(op: Operation, args: Record<string, unknown>) {
    samples.push(performance.now() - starts.get(args.sample as string)!);
    return super.execute(op, args);
  }
}
const native = new TimedFixture("benchmark@example.test");
const gateway = new Gateway(
  {
    host: "127.0.0.1",
    port: 0,
    database: join(root, "gateway.sqlite"),
    accounts: [
      { id: "bench", identity: "benchmark@example.test", workerTokenEnv: "W" },
    ],
    agents: [{ id: "bench", tokenEnv: "A", accounts: ["bench"] }],
  },
  { W: token, A: agent },
);
const port = await gateway.listen(),
  client = new BridgeClient(`http://127.0.0.1:${port}`, agent);
const worker = new Worker(
  {
    url: `ws://127.0.0.1:${port}/worker`,
    accountId: "bench",
    workerId: "bench",
    identity: "benchmark@example.test",
    token,
    spool: join(root, "spool.sqlite"),
  },
  native,
);
try {
  await worker.start();
  while (!(await client.request("bench", "capabilities")).online)
    await new Promise((r) => setTimeout(r, 5));
  const overall = performance.now();
  for (let i = 0; i < 250; i++) {
    const sample = String(i);
    starts.set(sample, performance.now());
    const command = await client.command(
      "bench",
      "messages.send",
      { chatId: "fixture-only", text: "benchmark", sample },
      sample,
    );
    while (
      ["queued", "executing"].includes(
        gateway.store.get("bench", command.id)!.state,
      )
    )
      await new Promise((r) => setTimeout(r, 1));
  }
  const elapsed = performance.now() - overall;
  const measured = samples.slice(10).sort((a, b) => a - b);
  const percentile = (p: number) =>
    Number(
      measured[
        Math.min(measured.length - 1, Math.floor(p * measured.length))
      ]!.toFixed(3),
    );
  console.log(
    JSON.stringify(
      {
        scope:
          "synthetic loopback HTTP request through durable SQLite WAL to persistent WebSocket fixture worker; excludes Messages, Apple network and model latency",
        samples: measured.length,
        warmup: 10,
        node: process.version,
        dispatchMs: {
          p50: percentile(0.5),
          p95: percentile(0.95),
          p99: percentile(0.99),
        },
        sequentialCommandsPerSecond: Number(
          (250 / (elapsed / 1000)).toFixed(1),
        ),
      },
      null,
      2,
    ),
  );
} finally {
  worker.close();
  await gateway.close();
  rmSync(root, { recursive: true, force: true });
}
