import { createHash, timingSafeEqual } from "node:crypto";
import type { Config, Operation } from "./protocol.js";
import { PilotError } from "./protocol.js";
const equal = (a: string, b: string) =>
  timingSafeEqual(
    createHash("sha256").update(a).digest(),
    createHash("sha256").update(b).digest(),
  );
export type Principal = {
  id: string;
  accounts: string[];
  operations?: Operation[];
  cardOnly?: boolean;
  chats?: Record<string, string[]>;
};
export class Auth {
  constructor(
    private config: Config,
    private env: NodeJS.ProcessEnv = process.env,
    private session?: (token: string) => Principal | undefined,
  ) {
    const tokens = [
      ...config.accounts.flatMap((a) => [
        a.workerTokenEnv,
        ...(a.deviceTokenEnv ? [a.deviceTokenEnv] : []),
      ]),
      ...config.agents.map((a) => a.tokenEnv),
    ].map((k) => env[k]);
    if (tokens.some((t) => !t || t.length < 32))
      throw new Error(
        "Every configured token environment variable must contain at least 32 characters",
      );
    if (new Set(tokens).size !== tokens.length)
      throw new Error("Tokens must be unique per worker and agent");
    if (new Set(config.agents.map((a) => a.id)).size !== config.agents.length)
      throw new Error("Agent IDs must be unique for control ownership");
    if (
      new Set(config.accounts.map((a) => a.id)).size !== config.accounts.length
    )
      throw new Error("Duplicate account IDs");
    if (
      new Set(config.accounts.map((a) => a.identity.toLowerCase())).size !==
      config.accounts.length
    )
      throw new Error("Each account must have a distinct Apple identity");
  }
  private token(header?: string) {
    if (!header?.startsWith("Bearer "))
      throw new PilotError("unauthorized", "Bearer token required", 401);
    return header.slice(7);
  }
  agent(header: string | undefined, account: string, operation?: Operation) {
    const token = this.token(header),
      agent: Principal | undefined =
        this.config.agents.find((a) => equal(this.env[a.tokenEnv]!, token)) ??
        this.session?.(token);
    if (!agent)
      throw new PilotError("unauthorized", "Invalid agent token", 401);
    if (
      !agent.accounts.includes(account) ||
      !this.config.accounts.some((a) => a.id === account)
    )
      throw new PilotError(
        "forbidden",
        "Account not granted to this agent",
        403,
      );
    if (operation && agent.operations && !agent.operations.includes(operation))
      throw new PilotError(
        "forbidden",
        "Operation not granted to this agent",
        403,
      );
    return agent;
  }
  worker(header?: string) {
    const token = this.token(header);
    for (const account of this.config.accounts) {
      if (equal(this.env[account.workerTokenEnv]!, token))
        return { account, role: "computer" as const };
      if (
        account.deviceTokenEnv &&
        equal(this.env[account.deviceTokenEnv]!, token)
      )
        return { account, role: "device" as const };
    }
    throw new PilotError("unauthorized", "Invalid worker token", 401);
  }
}
