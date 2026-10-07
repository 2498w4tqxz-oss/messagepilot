/** Explicit live self-chat acceptance. Never imported by npm test/CI. */
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { BridgeClient } from "../src/client.js";
import {
  textEffects,
  bubbleEffects,
  screenEffects,
  textStyles,
} from "../src/rich-messages.js";
import type { Operation } from "../src/protocol.js";
const [account, chatId, flag, output] = process.argv.slice(2);
if (
  !account ||
  !chatId ||
  flag !== "--send-to-self" ||
  !process.env.MESSAGEPILOT_AGENT_TOKEN
)
  throw new Error(
    "Usage: MESSAGEPILOT_AGENT_TOKEN=... MESSAGEPILOT_URL=... tsx scripts/rich-acceptance.ts ACCOUNT CHAT_ID --send-to-self OUTPUT.json. Sends 26 test messages plus edits/Tapbacks to the enrolled self-chat.",
  );
const client = new BridgeClient(
  process.env.MESSAGEPILOT_URL ?? "http://127.0.0.1:4380",
  process.env.MESSAGEPILOT_AGENT_TOKEN,
);
const caps = await client.request(account, "capabilities");
if (
  caps.allowedChatIds?.length !== 1 ||
  caps.allowedChatIds[0] !== chatId ||
  !caps.capabilities.some(
    (c: any) => c.available && c.path === "chat-restricted-native",
  )
)
  throw new Error(
    "Requires one exact chat allowlist and the chat-restricted native worker",
  );
const runId = randomUUID().slice(0, 8),
  results: any[] = [];
async function command(operation: Operation, args: Record<string, unknown>) {
  const queued = await client.command(
    account!,
    operation,
    { chatId, ...args },
    `${runId}:${results.length}:${operation}:${randomUUID()}`,
  );
  const receipt = await client.wait(account!, queued.id, 60000);
  if (receipt.state !== "completed")
    throw new Error(`${operation}: ${receipt.state}: ${receipt.error}`);
  return receipt.result as any;
}
async function record(
  name: string,
  operation: Operation,
  args: Record<string, unknown>,
) {
  const start = performance.now();
  const value = await command(operation, args);
  results.push({
    name,
    milliseconds: performance.now() - start,
    result: value,
  });
  if (output)
    writeFileSync(output, JSON.stringify({ runId, results }, null, 2) + "\n", {
      mode: 0o600,
    });
  console.log(`${name}: ${value.receipt ?? "completed"}`);
  return value;
}
for (const style of textStyles)
  await record(style, "messages.format", {
    text: `MessagePilot ${runId}: ${style}`,
    styles: [style],
  });
for (const [kind, effects] of [
  ["text", textEffects],
  ["bubble", bubbleEffects],
  ["screen", screenEffects],
] as const)
  for (const effect of effects)
    await record(`${kind}:${effect}`, "messages.effect", {
      text: `MessagePilot ${runId}: ${kind} ${effect}`,
      kind,
      effect,
    });
const original = await record("edit target", "messages.send", {
  text: `MessagePilot ${runId}: edit target`,
});
await record("edit", "messages.edit", {
  messageId: original.message.id,
  text: `MessagePilot ${runId}: edited`,
});
for (const reaction of [
  "love",
  "like",
  "dislike",
  "laugh",
  "emphasize",
  "question",
])
  for (const operation of ["messages.react", "messages.unreact"] as const)
    await record(`${operation}:${reaction}`, operation, {
      messageId: original.message.id,
      reaction,
    });
const temporary = await record("unsend target", "messages.send", {
  text: `MessagePilot ${runId}: unsend target`,
});
await record("unsend", "messages.unsend", { messageId: temporary.message.id });
// Query only the enrolled self-chat. Receipt success alone never proves recipient rendering.
await record("scoped reconciliation", "messages.search", {
  query: `MessagePilot ${runId}`,
});
console.log(
  "Native receipts saved. Verify payload attributes, incoming self-copies, and recipient rendering before recording acceptance.",
);
