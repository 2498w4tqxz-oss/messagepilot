import type { IncomingMessage, ServerResponse } from "node:http";
import type { Principal } from "../auth.js";
import { PilotError } from "../errors.js";
import { startProgress, updateProgress } from "./schema.js";
import type { ProgressService } from "./service.js";
export async function progressRoute(ctx: {
  req: IncomingMessage;
  res: ServerResponse;
  url: URL;
  account: string;
  agent: Principal;
  segments: string[];
  service: ProgressService;
  body: (req: IncomingMessage) => Promise<unknown>;
  reply: (res: ServerResponse, status: number, value: unknown) => void;
}) {
  const { req, res, url, account, agent, segments, service, body, reply } = ctx;
  const id = segments[4];
  if (req.method === "GET" && segments.length === 4) {
    const chat = url.searchParams.get("chatId");
    if (!chat)
      throw new PilotError("invalid_arguments", "An exact chatId is required");
    reply(res, 200, service.list(account, chat, agent));
    return;
  }
  if (req.method === "GET" && id && segments.length === 5) {
    reply(res, 200, service.get(account, id, agent));
    return;
  }
  if (req.method === "POST" && !id) {
    const parsed = startProgress.safeParse(await body(req));
    if (!parsed.success)
      throw new PilotError("invalid_arguments", parsed.error.message);
    reply(res, 202, service.start(account, agent, parsed.data));
    return;
  }
  if (
    req.method === "POST" &&
    id &&
    segments[5] === "updates" &&
    segments.length === 6
  ) {
    const parsed = updateProgress.safeParse(await body(req));
    if (!parsed.success)
      throw new PilotError("invalid_arguments", parsed.error.message);
    reply(res, 200, service.update(account, id, agent, parsed.data));
    return;
  }
  throw new PilotError("not_found", "Unknown progress endpoint", 404);
}
