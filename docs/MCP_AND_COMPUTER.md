# Registry, connected MCP servers, and virtual computer control

MessagePilot is both an MCP server for agents and an MCP client inside each dedicated worker. Set `enableToolkit: true` in that worker's local configuration to enable the client, Registry, recipes and Apple-tool catalog. The fixture worker never connects to external MCP servers.

## Official Registry to iMessage

1. `mcp_registry_search` accepts `search`, `cursor` and `limit`; `mcp_registry_get` accepts a Registry server `name` and `version`. The client uses the [Official Registry API](https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/api/official-registry-api.md). A listing is metadata, not an execution instruction or security endorsement.
2. `bridge_registry_card` performs a search through the account worker and stores the results as a versioned card. Load that card ID in the MessagePilot extension and send it, or use the enrolled UI runner to perform those steps.
3. Each result has a Select action. Selecting it emits `card.action` with authenticated actor, card ID, revision and selected Registry server/version. The external agent reads `bridge_events`, inspects the manifest, and chooses the next command. Message text and card actions never directly become executable code.
4. `mcp_connect` connects a chosen endpoint or installed executable. Remote Registry-backed connections must match the URL and transport in the pinned manifest. Stdio command/arguments are explicit developer choices; MessagePilot does not infer trusted shell commands from Registry prose. Install packages in the dedicated VM using a concrete package version before connecting them. No public Registry publication of this private project is performed.

All worker operations are invoked with `accountId`, an `args` object, and an `idempotencyKey`. Example `mcp_connect` arguments for a configured remote server:

```json
{
  "id": "my-server",
  "transport": "streamable-http",
  "url": "https://your-mcp-server.example.com/mcp",
  "headerRefs": { "Authorization": "MY_MCP_AUTHORIZATION" },
  "registry": { "name": "com.example/my-server", "version": "1.2.3" }
}
```

This is a configuration example, not a real Registry entry. Set `MY_MCP_AUTHORIZATION` to the complete authorization header in the worker environment. Secrets do not belong in command arguments, cards or Git. OAuth sign-in/token acquisition is handled by the developer's normal authorization flow; the bridge consumes configured credentials and does not implement an interactive OAuth login browser.

For an installed local server use `transport: "stdio"`, an absolute `command`, an `arguments` array and optional `environmentRefs`. Only explicitly named secret variables are forwarded; bridge credentials are not automatically passed to the child. A local process has the authority of its dedicated VM user. Remote servers use HTTPS, with HTTP permitted only for loopback. Legacy SSE is also supported by the SDK transport.

`mcp_connections`, `mcp_tools_list`, `mcp_tools_call`, `mcp_resources_list`, `mcp_resources_read`, `mcp_prompts_list`, `mcp_prompts_get`, and `mcp_disconnect` operate on a connection ID scoped to that worker. Tool results are preserved as MCP content, including errors and resource/image blocks. The outer command receipt still distinguishes completion of the bridge operation from success of the remote tool: inspect `result.isError` and its content. Connections are resident for speed, and must be reconnected after worker restart. A dispatched remote call with uncertain outcome is not retried automatically.

Registry and discovery traffic have their own execution lane. Tool calls share the desktop lane with Messages because an arbitrary MCP server might manipulate the same computer. Build tooling retains its separate lane.

## Take over the virtual computer

The worker runs **inside the dedicated guest**. MessagePilot does not hijack the host's personal desktop or create a virtual identity merely by opening a window.

1. Call `bridge_computer_control` with `action: "claim"`, the account ID, and a lease lifetime of 15–900 seconds. The account must have no queued/executing commands when a new lease begins.
2. Discover running apps with `computer_apps`, inspect allowed apps with `apps_snapshot`, and capture `computer_screenshot`. Use `files_read` to retrieve screenshot bytes in bounded chunks.
3. Use `computer_input` for activate, pointer move/click/drag, scroll, hardware key codes with modifiers, and Unicode text. Specify the exact target bundle. Input requires a lease and the target must remain foreground. Coordinates are Quartz desktop points from observed screen content; account for screenshot backing-pixel scale. Add allowed bundle IDs in the dedicated native configuration before operating new apps.
4. Renew with the same lease ID before expiry. Other agents are rejected while the lease is active. One distinct agent credential identifies one controller; do not share it between competing controllers.
5. Wait for commands to finish, then release with the lease ID. Expiry prevents continued exclusive ownership; it does not undo or forcibly interrupt already accepted work. Dispatched actions require explicit reconciliation after disconnect.

`computer_exec` remains the general development/process interface inside the VM. It is powerful and is not sandboxed by a workspace path check. OS isolation and the agent's operation scopes are the boundaries. The control lease excludes other bridge agents; it cannot lock out a person at the VM console or unrelated processes running inside that guest.
