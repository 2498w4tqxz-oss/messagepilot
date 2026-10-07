import type { Principal } from "./auth.js";
import {
  PilotError,
  type CommandInput,
  type Config,
  type Event,
  type Operation,
} from "./protocol.js";

// Deliberate allowlist: new tools do not automatically inherit chat-scoped authority.
export const chatOperations = new Set<Operation>([
  "messages.list",
  "messages.search",
  "messages.send",
  "messages.react",
  "messages.unreact",
  "messages.edit",
  "messages.unsend",
  "messages.effect",
  "messages.format",
  "messages.inspect",
  "messages.draft.discard",
  "chats.read",
  "chats.unread",
  "chats.typing",
]);
export function chatScope(
  config: Config,
  principal: Principal,
  account: string,
): string[] | undefined {
  const workerScope = config.accounts.find(
    (a) => a.id === account,
  )?.allowedChatIds;
  const agentScope =
    principal.chats === undefined
      ? undefined
      : (principal.chats[account] ?? []);
  if (workerScope === undefined) return agentScope;
  if (agentScope === undefined) return workerScope;
  return workerScope.filter((id) => agentScope.includes(id));
}
export function scopedOperation(operation: Operation): boolean {
  return chatOperations.has(operation) || operation === "messages.features";
}
export function assertChatScope(
  scope: string[] | undefined,
  input: CommandInput,
): void {
  if (scope === undefined) return;
  if (input.operation === "messages.features") return;
  if (
    !chatOperations.has(input.operation) ||
    typeof input.args.chatId !== "string" ||
    !scope.includes(input.args.chatId)
  )
    throw new PilotError(
      "chat_forbidden",
      "Operation requires an explicitly permitted chat and cannot bypass chat scope",
      403,
    );
  // Arbitrary selectors can target another part of Messages. Restricted workers own their selectors.
  if (
    input.args.selectors &&
    Object.keys(input.args.selectors as object).length
  )
    throw new PilotError(
      "chat_forbidden",
      "Chat-restricted commands cannot override native selectors",
      403,
    );
}
export function visibleEvent(
  scope: string[] | undefined,
  event: Event,
): boolean {
  if (scope === undefined) return true;
  // Account-wide native event batches and cards do not carry trustworthy per-chat ownership.
  // Fail closed. Scoped message reads and scoped command receipts remain available.
  if (event.kind !== "command.updated") return false;
  try {
    assertChatScope(scope, event.data as CommandInput);
    return true;
  } catch {
    return false;
  }
}
