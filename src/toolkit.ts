import { richFeatures } from "./rich-messages.js";
import type { NativeTransport } from "./native.js";
import { Registry } from "./registry.js";
import { MCPHost } from "./mcp-host.js";
import { appCatalog, compileWorkflow } from "./imessage-apps.js";
import {
  appleToolCommand,
  appleTools,
  developerFrameworks,
} from "./apple-tools.js";
import type { Capability, Operation } from "./protocol.js";
import { pushActivity } from "./activity-push.js";
export const toolkitOperations = [
  "mcp.registry.search",
  "mcp.registry.get",
  "mcp.connections",
  "mcp.connect",
  "mcp.disconnect",
  "mcp.tools.list",
  "mcp.tools.call",
  "mcp.resources.list",
  "mcp.resources.read",
  "mcp.prompts.list",
  "mcp.prompts.get",
  "imessage.catalog",
  "imessage.recipe",
  "imessage.run",
  "apple.tools.catalog",
  "apple.tools.run",
  "apple.activity.push",
] as const;
export class ToolkitTransport implements NativeTransport {
  private mcp: MCPHost;
  constructor(
    private native: NativeTransport,
    private enabled: boolean,
    private registry = new Registry(),
    private env = process.env,
  ) {
    this.mcp = new MCPHost(env);
  }
  chatScope() {
    return this.native.chatScope?.() ?? Promise.resolve(undefined);
  }
  identity() {
    return this.native.identity();
  }
  async capabilities(): Promise<Capability[]> {
    const native = await this.native.capabilities();
    const restricted = (await this.chatScope()) !== undefined;
    const dependencies: Record<string, string> = {
      "apple.tools.run": "computer.exec",
      "imessage.run": "apps.ios.run",
    };
    return [
      ...native,
      {
        operation: "messages.features",
        available: true,
        path: "feature-catalog",
        verification: "compiled",
      },
      ...toolkitOperations.map((operation) => {
        const available =
          this.enabled &&
          !restricted &&
          (!dependencies[operation] ||
            native.some(
              (c) => c.operation === dependencies[operation] && c.available,
            )) &&
          (operation !== "apple.activity.push" ||
            [
              "MESSAGEPILOT_APNS_KEY_PATH",
              "MESSAGEPILOT_APNS_KEY_ID",
              "MESSAGEPILOT_APNS_TEAM_ID",
              "MESSAGEPILOT_APNS_BUNDLE_ID",
              "MESSAGEPILOT_APNS_ENVIRONMENT",
            ].every((key) => !!this.env[key]));
        return {
          operation,
          available,
          path: "dedicated-worker-toolkit",
          verification: available
            ? ("compiled" as const)
            : ("unavailable" as const),
          detail: available
            ? "Implementation configured; inspect operation results and verify the target environment."
            : "Toolkit, native dependency or required APNs environment is not configured.",
        };
      }),
    ];
  }
  async execute(
    operation: Operation,
    a: Record<string, any>,
  ): Promise<unknown> {
    if (operation === "messages.features") return richFeatures;
    if (!(toolkitOperations as readonly string[]).includes(operation))
      return this.native.execute(operation, a);
    if (!this.enabled || (await this.chatScope()) !== undefined)
      throw new Error(
        "Enable the toolkit in this dedicated worker's configuration",
      );
    if (operation === "apple.activity.push") return pushActivity(a, this.env);
    if (operation === "mcp.registry.search")
      return this.registry.search(a.search, a.cursor, a.limit);
    if (operation === "mcp.registry.get")
      return this.registry.get(a.name, a.version);
    if (operation.startsWith("mcp.")) {
      if (operation === "mcp.connect" && a.registry) {
        const result = await this.registry.get(
          a.registry.name,
          a.registry.version,
        );
        const manifest = result.server;
        if (!manifest || manifest.version !== a.registry.version)
          throw new Error("Registry version mismatch");
        if (
          a.transport !== "stdio" &&
          !manifest.remotes?.some(
            (r: any) => r.type === a.transport && r.url === a.url,
          )
        )
          throw new Error(
            "Remote URL/transport does not match pinned registry manifest",
          );
        // Stdio executable/package arguments are explicit caller choices, not trusted registry commands.
      }
      return this.mcp.execute(operation, a);
    }
    if (operation === "imessage.catalog") return appCatalog();
    if (operation === "imessage.recipe") return compileWorkflow(a);
    if (operation === "imessage.run") {
      const compiled = compileWorkflow(a.workflow);
      return this.native.execute("apps.ios.run", {
        ...a,
        recipe: compiled.recipe,
      });
    }
    if (operation === "apple.tools.catalog")
      return {
        tools: appleTools.map(([id, executable, prefix, purpose]) => ({
          id,
          executable,
          prefix,
          purpose,
          availability: "probe with --help on dedicated worker",
        })),
        frameworks: developerFrameworks,
      };
    if (operation === "apple.tools.run")
      return this.native.execute(
        "computer.exec",
        appleToolCommand(a.tool, a.arguments ?? [], a.cwd, a.timeoutSeconds),
      );
    throw new Error("Unknown toolkit operation");
  }
  onEvent(callback: (data: unknown) => void) {
    this.native.onEvent(callback);
  }
  onExit(callback: () => void) {
    this.native.onExit?.(callback);
  }
  close() {
    this.mcp.close();
    this.native.close();
  }
}
