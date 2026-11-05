# Approval graph MCP

Status: local vertical slice. The server is packaged as a `di-bridge mcp-server`
subcommand and talks to the running X Island process over the existing owner-only
Unix socket. Automatic edits to third-party MCP configuration files are not part of
this stage.

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
