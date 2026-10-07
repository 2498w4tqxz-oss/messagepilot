import { connect } from "node:http2";
import { readFile } from "node:fs/promises";
import { sign } from "node:crypto";

export function activityPayload(
  a: Record<string, any>,
  timestamp = Math.floor(Date.now() / 1000),
) {
  if (!["start", "update", "end"].includes(a.event))
    throw new Error("Invalid ActivityKit event");
  if (a.event === "start" && (!a.attributesType || !a.attributes || !a.alert))
    throw new Error(
      "Push-to-start requires attributesType, attributes and alert",
    );
  const aps: Record<string, unknown> = {
    timestamp,
    event: a.event,
    "content-state": a.contentState,
  };
  if (a.event === "start")
    Object.assign(aps, {
      "attributes-type": a.attributesType,
      attributes: a.attributes,
      alert: a.alert,
    });
  if (a.staleDate !== undefined) aps["stale-date"] = a.staleDate;
  if (a.event === "start" && a.requestUpdateToken) aps["input-push-token"] = 1;
  if (a.dismissalDate !== undefined) aps["dismissal-date"] = a.dismissalDate;
  const body = JSON.stringify({ aps });
  if (Buffer.byteLength(body) > 4096)
    throw new Error("APNs payload exceeds 4096 bytes");
  return body;
}
export function providerToken(
  key: string,
  keyID: string,
  teamID: string,
  now = Math.floor(Date.now() / 1000),
) {
  const header = Buffer.from(
    JSON.stringify({ alg: "ES256", kid: keyID }),
  ).toString("base64url");
  const body = Buffer.from(JSON.stringify({ iss: teamID, iat: now })).toString(
    "base64url",
  );
  const unsigned = `${header}.${body}`;
  return `${unsigned}.${sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}
export async function pushActivity(a: Record<string, any>, env = process.env) {
  const get = (name: string) => {
    const value = env[name];
    if (!value)
      throw new Error(`Configure ${name} in the dedicated worker environment`);
    return value;
  };
  const body = activityPayload(a);
  if (!/^[a-fA-F0-9]{32,512}$/.test(a.pushToken))
    throw new Error("Invalid APNs activity token");
  const key = await readFile(get("MESSAGEPILOT_APNS_KEY_PATH"), "utf8");
  const token = providerToken(
    key,
    get("MESSAGEPILOT_APNS_KEY_ID"),
    get("MESSAGEPILOT_APNS_TEAM_ID"),
  );
  const bundle = get("MESSAGEPILOT_APNS_BUNDLE_ID");
  const environment = get("MESSAGEPILOT_APNS_ENVIRONMENT");
  if (!["sandbox", "production"].includes(environment))
    throw new Error("APNs environment must be sandbox or production");
  const session = connect(
    environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com",
  );
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => finish(new Error("APNs timed out; acceptance is unknown")),
      20000,
    );
    let done = false,
      status = 0,
      response = "",
      apnsID: string | undefined;
    const finish = (error?: Error) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      session.destroy();
      if (error) reject(error);
      else
        resolve({
          accepted: status === 200,
          status,
          apnsID,
          response,
          receipt: "apns-response",
          delivery: "not-asserted",
        });
    };
    session.on("error", finish);
    const request = session.request({
      ":method": "POST",
      ":path": `/3/device/${a.pushToken}`,
      authorization: `bearer ${token}`,
      "apns-topic": `${bundle}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": a.event === "start" ? "10" : "5",
      "content-type": "application/json",
    });
    request.on("response", (h) => {
      status = Number(h[":status"]);
      apnsID = String(h["apns-id"] ?? "");
    });
    request.on("data", (c) => {
      response += c;
      if (response.length > 65536) finish(new Error("APNs response too large"));
    });
    request.on("error", finish);
    request.on("end", () => finish());
    request.end(body);
  });
}
