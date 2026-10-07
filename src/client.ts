import { randomUUID } from "node:crypto";
import type { Command, Operation } from "./protocol.js";
export class BridgeClient {
  constructor(
    readonly url: string,
    private token: string,
  ) {}
  async request(
    accountId: string,
    path: string,
    method = "GET",
    body?: unknown,
  ) {
    const response = await fetch(
      `${this.url}/v1/accounts/${encodeURIComponent(accountId)}/${path}`,
      {
        method,
        headers: {
          authorization: `Bearer ${this.token}`,
          "content-type": "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(30000),
      },
    );
    const value = await response.json();
    if (!response.ok)
      throw new Error(`${response.status}: ${JSON.stringify(value)}`);
    return value;
  }
  async command(
    accountId: string,
    operation: Operation,
    args: Record<string, unknown>,
    idempotencyKey: string = randomUUID(),
  ) {
    return this.request(accountId, "commands", "POST", {
      operation,
      args,
      idempotencyKey,
    }) as Promise<Command>;
  }
  async wait(accountId: string, id: string, timeout = 60000) {
    const deadline = Date.now() + timeout;
    while (true) {
      const c = (await this.request(
        accountId,
        `commands/${encodeURIComponent(id)}`,
      )) as Command;
      if (!["queued", "executing"].includes(c.state) || Date.now() >= deadline)
        return c;
      await new Promise((r) => setTimeout(r, 50));
    }
  }
}
