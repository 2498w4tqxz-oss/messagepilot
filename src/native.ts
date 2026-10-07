import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { operations, type Capability, type Operation } from "./protocol.js";
export interface NativeTransport {
  identity(): Promise<string>;
  capabilities(): Promise<Capability[]>;
  chatScope?(): Promise<string[] | undefined>;
  execute(
    operation: Operation,
    args: Record<string, unknown>,
  ): Promise<unknown>;
  onEvent(callback: (data: unknown) => void): void;
  onExit?(callback: () => void): void;
  close(): void;
}
export class NativeProcess implements NativeTransport {
  private child: ChildProcessWithoutNullStreams;
  private pending = new Map<
    string,
    {
      resolve: (v: any) => void;
      reject: (e: Error) => void;
      timer: NodeJS.Timeout;
    }
  >();
  private events = new EventEmitter();
  private alive = true;
  constructor(binary: string, args: string[], env = process.env) {
    this.child = spawn(binary, args, {
      stdio: ["pipe", "pipe", "pipe"],
      env,
      detached: process.platform !== "win32",
    });
    createInterface({ input: this.child.stdout }).on("line", (line) => {
      try {
        const r = JSON.parse(line);
        if (r.type === "event") {
          this.events.emit("event", r.data);
          return;
        }
        const p = this.pending.get(r.id);
        if (!p) return;
        clearTimeout(p.timer);
        this.pending.delete(r.id);
        if (r.error) p.reject(new Error(r.error));
        else p.resolve(r.result);
      } catch {
        /* Native logs must use stderr; ignore malformed lines. */
      }
    });
    this.child.stderr.on("data", (data) => process.stderr.write(data));
    const fail = (e: Error) => {
      if (!this.alive) return;
      this.alive = false;
      for (const p of this.pending.values()) {
        clearTimeout(p.timer);
        p.reject(e);
      }
      this.pending.clear();
      this.events.emit("exit");
    };
    this.child.on("error", fail);
    this.child.stdin.on("error", fail);
    this.child.on("exit", () =>
      fail(new Error("Native worker exited; dispatched outcome is unknown")),
    );
  }
  request(method: string, params: Record<string, unknown> = {}) {
    if (!this.alive)
      return Promise.reject(new Error("Native worker is offline"));
    return new Promise<any>((resolve, reject) => {
      const id = randomUUID();
      const timer = setTimeout(
        () => {
          this.pending.delete(id);
          this.close();
          reject(new Error("Native operation timed out; outcome is unknown"));
        },
        ["computer.exec", "apps.build", "apps.ios.run"].includes(method)
          ? 590000
          : 85000,
      );
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(
        JSON.stringify({ id, method, params }) + "\n",
        (error) => {
          if (error) {
            clearTimeout(timer);
            this.pending.delete(id);
            reject(error);
          }
        },
      );
    });
  }
  async identity() {
    return (await this.request("identity")).identity as string;
  }
  async chatScope() {
    return (await this.request("identity")).allowedChatIds as
      string[] | undefined;
  }
  capabilities() {
    return this.request("capabilities") as Promise<Capability[]>;
  }
  execute(operation: Operation, args: Record<string, unknown>) {
    return this.request(operation, args);
  }
  onEvent(callback: (data: unknown) => void) {
    this.events.on("event", callback);
  }
  onExit(callback: () => void) {
    this.events.on("exit", callback);
  }
  close() {
    if (this.child.pid && process.platform !== "win32") {
      try {
        process.kill(-this.child.pid, "SIGTERM");
      } catch {
        this.child.kill();
      }
    } else this.child.kill();
  }
}
export class FixtureTransport implements NativeTransport {
  calls: { operation: Operation; args: Record<string, unknown> }[] = [];
  private events = new EventEmitter();
  constructor(
    private address: string,
    private delay = 0,
  ) {}
  async identity() {
    return this.address;
  }
  async capabilities(): Promise<Capability[]> {
    return operations.map((operation) => ({
      operation,
      available: true,
      path: "fixture",
      verification: "fixture",
    }));
  }
  async execute(operation: Operation, args: Record<string, unknown>) {
    this.calls.push({ operation, args });
    if (this.delay) await new Promise((r) => setTimeout(r, this.delay));
    return {
      fixture: true,
      operation,
      account: this.address,
      receipt: "simulated",
      args,
    };
  }
  emit(data: unknown) {
    this.events.emit("event", data);
  }
  onEvent(callback: (data: unknown) => void) {
    this.events.on("event", callback);
  }
  close() {}
}
