export const OFFICIAL_REGISTRY = "https://registry.modelcontextprotocol.io";
export class Registry {
  constructor(private fetcher: typeof fetch = fetch) {}
  private async read(path: string) {
    const response = await this.fetcher(`${OFFICIAL_REGISTRY}/v0.1/${path}`, {
      signal: AbortSignal.timeout(15000),
      redirect: "error",
      headers: { accept: "application/json" },
    });
    if (!response.ok)
      throw new Error(`Official Registry returned ${response.status}`);
    const text = await response.text();
    if (Buffer.byteLength(text) > 4 * 1024 * 1024)
      throw new Error("Registry response too large");
    return JSON.parse(text);
  }
  search(search = "", cursor?: string, limit = 20) {
    const query = new URLSearchParams({
      search,
      limit: String(limit),
      version: "latest",
    });
    if (cursor) query.set("cursor", cursor);
    return this.read(`servers?${query}`);
  }
  get(name: string, version: string) {
    return this.read(
      `servers/${encodeURIComponent(name)}/versions/${encodeURIComponent(version)}`,
    );
  }
}
// Registry metadata is displayed as data. A listing never installs or executes a server.
export function registryCard(result: any) {
  const entries = Array.isArray(result.servers)
    ? result.servers.slice(0, 20)
    : [];
  return {
    title: "Official MCP Registry",
    summary:
      "Choose a server for your agent to inspect and connect. Listing is not a security endorsement.",
    items: entries.map(({ server }: any) => ({
      id: `${server.name}@${server.version}`,
      title: String(server.title ?? server.name),
      subtitle: `${server.version} · ${String(server.description ?? "").slice(0, 500)}`,
      action: `Inspect ${server.name}@${server.version}`,
    })),
    actions: entries.map(
      ({ server }: any) => `Inspect ${server.name}@${server.version}`,
    ),
  };
}
