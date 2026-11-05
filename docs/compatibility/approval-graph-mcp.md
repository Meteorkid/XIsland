# Approval graph MCP

Status: local vertical slice. The server is packaged as a `di-bridge mcp-server`
subcommand and talks to the running X Island process over the existing owner-only
Unix socket. Automatic edits to third-party MCP configuration files are not part of
the first protocol slice; guarded first-run registration is implemented separately.

## Automatic registration

X Island asks once before writing any MCP configuration. The confirmation shows
each affected client, its configuration path, the absolute `di-bridge` path, and
the complete `mcp-server --agent <client>` arguments. Consent is bound to that
client, path and server definition. A first-time decline leaves all client files
alone; declining after an earlier registration removes the exact X Island entry.
The permission can be reopened from Settings or the island context menu.

The guarded registration supports user-scope configuration for:

- Codex: `~/.codex/config.toml`, `[mcp_servers.xisland_approval_graph]`
- Claude Code: `~/.claude.json`, `mcpServers.xisland_approval_graph`
- Gemini CLI: `~/.gemini/settings.json`, `mcpServers.xisland_approval_graph`
- Cursor: `~/.cursor/mcp.json`, `mcpServers.xisland_approval_graph`
- Qwen Code: `~/.qwen/settings.json`, `mcpServers.xisland_approval_graph`

Codex honors `CODEX_HOME`, and Claude Code honors `CLAUDE_CONFIG_DIR`, when the
override is an absolute path. The manager only adds a user-scope entry after the
client directory exists; an old configuration folder alone is not installation
evidence. Existing same-name entries are compared as complete definitions. Any
user modification is preserved and reported as a conflict instead of being
overwritten or removed.

OpenCode is deliberately excluded from automatic writes in this stage because
its JSONC, alternate config path and project-override variants are not yet safe to
edit generically. WorkBuddy, Kimi, CodeBuddy, Trae, Cline, Roo, Continue, and
ACP-based clients also remain manual.

After a file is written, restart the client. The client's own MCP trust boundary
is still separate from X Island's consent: Codex/Cursor/VS Code-style hosts may ask
again before enabling the server or running a tool. X Island records file
configuration, the client's MCP handshake, and hook activity as separate evidence.
The bridge identifies itself with the executable path and full argument list and
reports on initialize, tool discovery and actual graph requests, so a handshake is
not lost when the App starts after the client. A configured client waits for a
matching MCP handshake under the current definition; an older hook-only
observation cannot be reused after MCP is enabled.

Turning off the approval context map removes only exact X Island entries and
leaves unrelated MCP servers intact. Cleanup is repeated at startup so an app exit
during a previous removal cannot leave an enabled entry behind indefinitely.
Declining the MCP permission also removes entries previously written for that
client. Rapid off/on changes are serialized so an older cleanup cannot win over a
newer enable request.

## Tools

- `approval_graph_get` reads accepted nodes, pending proposals and persisted comments.
- `approval_graph_write` atomically submits up to 32 task/step nodes. Every submitted
  node remains a proposal until the user selects **Keep** in the approval context map.

The write call requires `base_revision`, an idempotent `request_id`, and `nodes`.
The prompt can optionally pass `session_id`; otherwise the bridge binds by agent and
the process working directory, then by terminal session ID. Ambiguous or missing
sessions return an explicit error and are never created implicitly.

## Codex example

```toml
[mcp_servers.xisland_approval_graph]
command = "/Users/you/.xisland/bin/di-bridge"
args = ["mcp-server", "--agent", "codex"]
```

## JSON MCP client example

```json
{
  "mcpServers": {
    "xisland-approval-graph": {
      "command": "/Users/you/.xisland/bin/di-bridge",
      "args": ["mcp-server", "--agent", "claude_code"]
    }
  }
}
```

Use an explicit session when the same client has multiple chats in one directory:

```bash
~/.xisland/bin/di-bridge mcp-server --agent codex --session codex-<session-id>
```

## Data and limits

- Documents are stored under `~/.xisland/approval-graphs/`, directory mode `0700`
  and file mode `0600`; file names are SHA-256 hashes of session IDs.
- Node IDs are 1–64 ASCII characters; titles are at most 256 bytes and details at
  most 2,048 bytes. The graph is limited to 32 nodes and depth 4.
- Writes use revision checks. A stale revision is rejected without partial changes.
  Retrying the same `request_id` and payload is idempotent.
- Corrupt or unreadable graph files fall back to the existing derived context map;
  they are never silently overwritten.
- Graph writes cannot approve permissions, answer questions, execute commands or
  restore files.

## Verification

`Scripts/test.sh M20` starts the compiled MCP bridge against an isolated app and
checks `initialize`, `tools/list`, GET, WRITE, retry idempotency and stale revisions.
`ApprovalGraphTests` covers the reducer, persistence, keep/discard ordering, comments,
protocol round-trip and strict peer policy.
