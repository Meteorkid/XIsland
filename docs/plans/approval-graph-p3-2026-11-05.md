# Approval graph P3

Date: 2026-11-05

## Delivered slice

- Local stdio MCP server exposed as `di-bridge mcp-server --agent <agent>`.
- `approval_graph_get` and `approval_graph_write` tools.
- Explicit task/step nodes with stable IDs, parent links and status values.
- Pending proposals are shown in the existing approval context map; the user can
  keep or discard each node without changing the underlying tool approval.
- Comments on explicit graph nodes are persisted and returned by the next GET.
- Revision checks, idempotent request IDs, strict bridge process authentication,
  bounded input, private file permissions and corrupt-file fallback.

## Deliberately deferred

- Automatic third-party MCP client configuration and trust prompts.
- Free-position canvas coordinates, edges, drag/drop and moving accepted nodes.
- Graph-aware notifications or push updates; clients poll with GET.
- Remote/SSH graph writes.
- Any authority to approve commands, answer questions or revert files.

## Next increments

1. Add client-specific MCP configuration and one-time trust onboarding.
2. Add a visual tree/canvas shelf while retaining the compact list representation.
3. Add graph retention and deletion hooks when session history is removed.
4. Exercise real Codex and Claude Code MCP hosts after explicit configuration.

## Verification snapshot

- Swift: 2032 X Island tests (21 conditional skips) and 31 license tests
  (1 conditional skip), zero failures.
- Integration: 128 checks, including the compiled MCP bridge handshake, optional
  GET arguments, automatic session binding, write, idempotent retry and stale revision.
- Rendering: `.build/approval-graph-20261105/render/map-agent-graph.png`.
- Release build: `swift build -c release` passed.
