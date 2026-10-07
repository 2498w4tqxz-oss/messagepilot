import { z } from "zod";
/** Planning only. No installation, image pulling or Apple Account provisioning. */
export const containerPlanInput = z.object({
  name: z.string().regex(/^[a-z][a-z0-9-]{0,50}$/),
  image: z.string().regex(/^[a-zA-Z0-9./:_-]+@sha256:[a-f0-9]{64}$/),
  gatewayURL: z
    .string()
    .url()
    .refine(
      (s) =>
        new URL(s).protocol === "https:" &&
        !new URL(s).username &&
        !new URL(s).password,
    ),
  accountId: z.string().regex(/^[a-zA-Z0-9_-]+$/),
  cpus: z.number().int().min(1).max(16).default(2),
  memoryMiB: z.number().int().min(256).max(32768).default(2048),
});
export function containerPlan(input: unknown) {
  const v = containerPlanInput.parse(input);
  return {
    status: "plan_only",
    role: "linux-agent-workload",
    executable: "/usr/local/bin/container",
    arguments: [
      "run",
      "--name",
      v.name,
      "--cpus",
      String(v.cpus),
      "--memory",
      `${v.memoryMiB}M`,
      "--env",
      `MESSAGEPILOT_URL=${v.gatewayURL}`,
      "--env",
      `MESSAGEPILOT_ACCOUNT=${v.accountId}`,
      v.image,
    ],
    secretRequired:
      "Inject a scoped agent credential using your deployment secret mechanism; do not bake it into an image or this plan.",
    requirements: [
      "Apple silicon host with a supported container release and macOS version",
      "Dedicated authenticated macOS Messages worker remains outside Linux",
      "HTTPS gateway reachable from the container; its localhost is not the Mac localhost",
    ],
    mounts: [],
    limitations: [
      "Linux cannot host Messages, Apple Account enrollment or Xcode/iOS Simulator.",
      "No image was pulled and no container was launched by this planner.",
      "Confirm CLI flags against the installed pinned container release before execution.",
    ],
  };
}
