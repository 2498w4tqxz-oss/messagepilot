import { z } from "zod";
import { PilotError } from "./errors.js";
export const workspaceOperations = [
  "drive.list",
  "drive.get",
  "drive.export",
  "docs.get",
  "docs.create",
  "docs.update",
  "sheets.get",
  "sheets.create",
  "sheets.read",
  "sheets.write",
  "slides.get",
  "slides.create",
  "slides.update",
  "calendar.list",
  "calendar.create",
  "gmail.get",
  "gmail.send",
] as const;
export const workspaceConfig = z
  .object({
    id: z.string().regex(/^[a-zA-Z0-9_-]+$/),
    accountId: z.string(),
    chatId: z.string().min(1),
    agentIds: z.array(z.string()).min(1),
    operations: z.array(z.enum(workspaceOperations)).min(1),
    accessTokenEnv: z.string().optional(),
    oauth: z
      .object({
        clientIdEnv: z.string(),
        clientSecretEnv: z.string(),
        refreshTokenEnv: z.string(),
      })
      .optional(),
  })
  .refine(
    (v) => Boolean(v.accessTokenEnv) !== Boolean(v.oauth),
    "Choose access token or refresh credentials",
  );
export const workspaceInput = z
  .object({
    operation: z.enum(workspaceOperations),
    args: z.record(z.unknown()).default({}),
  })
  .strict();
export type WorkspaceConnection = z.infer<typeof workspaceConfig>;
export function workspaceRoute(
  operation: (typeof workspaceOperations)[number],
  a: Record<string, any>,
) {
  const id = (key: string) => {
    if (typeof a[key] !== "string" || !a[key] || a[key].length > 1000)
      throw new PilotError("invalid_arguments", `${key} required`);
    return encodeURIComponent(a[key]);
  };
  const body = (key = "body") => {
    if (!a[key] || typeof a[key] !== "object" || Array.isArray(a[key]))
      throw new PilotError("invalid_arguments", `${key} object required`);
    return a[key];
  };
  const q = (v: Record<string, string>) => new URLSearchParams(v).toString();
  let url = "",
    method = "GET",
    payload: any,
    binary = false;
  switch (operation) {
    case "drive.list":
      url =
        "https://www.googleapis.com/drive/v3/files?" +
        q({
          pageSize: "100",
          fields:
            "nextPageToken,files(id,name,mimeType,modifiedTime,webViewLink)",
          ...(typeof a.query === "string" ? { q: a.query } : {}),
          ...(typeof a.pageToken === "string"
            ? { pageToken: a.pageToken }
            : {}),
        });
      break;
    case "drive.get":
      url = `https://www.googleapis.com/drive/v3/files/${id("fileId")}?fields=id,name,mimeType,size,modifiedTime,webViewLink`;
      break;
    case "drive.export":
      if (
        ![
          "application/pdf",
          "text/plain",
          "text/csv",
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ].includes(a.mimeType)
      )
        throw new PilotError(
          "invalid_arguments",
          "Unsupported export MIME type",
        );
      url = `https://www.googleapis.com/drive/v3/files/${id("fileId")}/export?${q({ mimeType: a.mimeType })}`;
      binary = true;
      break;
    case "docs.get":
      url = `https://docs.googleapis.com/v1/documents/${id("documentId")}`;
      break;
    case "docs.create":
      url = "https://docs.googleapis.com/v1/documents";
      method = "POST";
      payload = body();
      break;
    case "docs.update":
      url = `https://docs.googleapis.com/v1/documents/${id("documentId")}:batchUpdate`;
      method = "POST";
      payload = body();
      break;
    case "sheets.get":
      url = `https://sheets.googleapis.com/v4/spreadsheets/${id("spreadsheetId")}`;
      break;
    case "sheets.create":
      url = "https://sheets.googleapis.com/v4/spreadsheets";
      method = "POST";
      payload = body();
      break;
    case "sheets.read":
      url = `https://sheets.googleapis.com/v4/spreadsheets/${id("spreadsheetId")}/values/${id("range")}`;
      break;
    case "sheets.write":
      url = `https://sheets.googleapis.com/v4/spreadsheets/${id("spreadsheetId")}/values/${id("range")}?valueInputOption=RAW`;
      method = "PUT";
      payload = body();
      break;
    case "slides.get":
      url = `https://slides.googleapis.com/v1/presentations/${id("presentationId")}`;
      break;
    case "slides.create":
      url = "https://slides.googleapis.com/v1/presentations";
      method = "POST";
      payload = body();
      break;
    case "slides.update":
      url = `https://slides.googleapis.com/v1/presentations/${id("presentationId")}:batchUpdate`;
      method = "POST";
      payload = body();
      break;
    case "calendar.list":
      url = `https://www.googleapis.com/calendar/v3/calendars/${id("calendarId")}/events?${q({ maxResults: "100", ...(typeof a.pageToken === "string" ? { pageToken: a.pageToken } : {}), ...(typeof a.timeMin === "string" ? { timeMin: a.timeMin } : {}) })}`;
      break;
    case "calendar.create":
      url = `https://www.googleapis.com/calendar/v3/calendars/${id("calendarId")}/events?sendUpdates=none`;
      method = "POST";
      payload = body();
      break;
    case "gmail.get":
      url = `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id("messageId")}?format=full`;
      break;
    case "gmail.send":
      url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send";
      method = "POST";
      if (typeof a.raw !== "string" || !/^[A-Za-z0-9_-]+={0,2}$/.test(a.raw))
        throw new PilotError(
          "invalid_arguments",
          "Base64url RFC 2822 raw message required",
        );
      payload = { raw: a.raw };
      break;
  }
  return { url, method, payload, binary };
}
export class GoogleWorkspace {
  private cached = new Map<string, { token: string; expires: number }>();
  constructor(
    private connections: WorkspaceConnection[],
    private env: NodeJS.ProcessEnv,
    private fetcher: typeof fetch = fetch,
  ) {
    if (new Set(connections.map((c) => c.id)).size !== connections.length)
      throw new Error("Workspace connection IDs must be unique");
  }
  authorize(
    account: string,
    id: string,
    agent: string,
    scope: string[] | undefined,
  ) {
    const c = this.connections.find(
      (c) => c.id === id && c.accountId === account,
    );
    if (
      !c ||
      !c.agentIds.includes(agent) ||
      (scope !== undefined && !scope.includes(c.chatId))
    )
      throw new PilotError(
        "forbidden",
        "Workspace connection not granted",
        403,
      );
    return c;
  }
  private async bounded(r: Response, limit = 4 * 1024 * 1024) {
    let size = 0;
    const chunks: Uint8Array[] = [];
    if (!r.body) return Buffer.alloc(0);
    for await (const part of r.body as any) {
      size += part.length;
      if (size > limit)
        throw new PilotError(
          "too_large",
          "Workspace response exceeds bridge limit",
          413,
        );
      chunks.push(part);
    }
    return Buffer.concat(chunks);
  }
  private async token(c: WorkspaceConnection) {
    if (c.accessTokenEnv) {
      const t = this.env[c.accessTokenEnv];
      if (!t)
        throw new PilotError(
          "not_configured",
          "Workspace access token missing",
          503,
        );
      return t;
    }
    const cached = this.cached.get(c.id);
    if (cached && cached.expires > Date.now() + 60000) return cached.token;
    const oauth = c.oauth!;
    const fields = {
      client_id: this.env[oauth.clientIdEnv],
      client_secret: this.env[oauth.clientSecretEnv],
      refresh_token: this.env[oauth.refreshTokenEnv],
      grant_type: "refresh_token",
    };
    if (Object.values(fields).some((v) => !v))
      throw new PilotError(
        "not_configured",
        "Workspace OAuth secrets missing",
        503,
      );
    const r = await this.fetcher("https://oauth2.googleapis.com/token", {
      method: "POST",
      redirect: "error",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(fields as Record<string, string>),
      signal: AbortSignal.timeout(15000),
    });
    if (!r.ok)
      throw new PilotError(
        "reauthentication_required",
        "Google token refresh failed",
        401,
      );
    const value = JSON.parse((await this.bounded(r, 65536)).toString());
    if (typeof value.access_token !== "string")
      throw new PilotError(
        "reauthentication_required",
        "Google did not return a token",
        401,
      );
    this.cached.set(c.id, {
      token: value.access_token,
      expires:
        Date.now() + Math.min(Number(value.expires_in) || 300, 3600) * 1000,
    });
    return value.access_token;
  }
  async execute(c: WorkspaceConnection, input: z.infer<typeof workspaceInput>) {
    if (!c.operations.includes(input.operation))
      throw new PilotError("forbidden", "Workspace action is not granted", 403);
    const route = workspaceRoute(input.operation, input.args),
      token = await this.token(c);
    let r: Response;
    try {
      r = await this.fetcher(route.url, {
        method: route.method,
        redirect: "error",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body:
          route.payload === undefined
            ? undefined
            : JSON.stringify(route.payload),
        signal: AbortSignal.timeout(30000),
      });
    } catch {
      throw new PilotError(
        route.method === "GET" ? "provider_error" : "outcome_unknown",
        route.method === "GET"
          ? "Google request failed"
          : "Google write outcome unknown; reconcile before retrying",
        502,
      );
    }
    if (!r.ok)
      throw new PilotError(
        "google_error",
        `Google API returned ${r.status}; no automatic retry`,
        502,
      );
    const data = await this.bounded(r);
    return route.binary
      ? {
          mimeType: input.args.mimeType,
          bytes: data.length,
          base64: data.toString("base64"),
          source: "google-workspace-export",
        }
      : JSON.parse(data.toString());
  }
}
