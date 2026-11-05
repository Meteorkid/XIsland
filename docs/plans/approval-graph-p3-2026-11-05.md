# Approval graph P3

Date: 2026-11-05

## Delivered slice

- Local stdio MCP server exposed as `di-bridge mcp-server --agent <agent>`.
- `approval_graph_get` and `approval_graph_write` tools.
- Explicit task/step nodes with stable IDs, parent links and status values.
- Pending proposals are shown in the existing approval context map; the user can
  keep or discard each node without changing the underlying tool approval.
- Comments on explicit graph nodes are persisted and returned by the next GET.
- First-run consent and guarded user-scope registration for Codex, Claude Code,
  Gemini CLI, Cursor and Qwen Code. Consent is bound to the client, resolved path
  and exact server definition; OpenCode remains manual until JSONC/path variants
  have a safe editor.
- MCP `initialize` is reported to the App as separate connection evidence. Hook
  activity cannot mark an opted-in client connected when its MCP server was never
  loaded by the client. The handshake is bound to the exact executable and argument
  list, retained until it can be matched, and consumed after one successful match.
- Rejecting MCP registration removes prior exact entries. Startup cleanup and
  rapid off/on operations converge to the latest setting.
- Revision checks, idempotent request IDs, strict bridge process authentication,
  bounded input, private file permissions and corrupt-file fallback.

## Deliberately deferred

- Additional client-specific MCP configuration beyond the stable five-client set.
- Free-position canvas coordinates, edges, drag/drop and moving accepted nodes.
- Graph-aware notifications or push updates; clients poll with GET.
- Remote/SSH graph writes.
- Any authority to approve commands, answer questions or revert files.

## Next increments

1. Add client-specific MCP configuration beyond the stable five-client set.
2. Add a visual tree/canvas shelf while retaining the compact list representation.
3. Add graph retention and deletion hooks when session history is removed.
4. Complete the remaining Claude model-backed call, Cursor GUI call, and custom
   configuration-root checks.

## Verification snapshot

- Swift: 2046 X Island tests (21 conditional skips) and 31 license tests
  (1 conditional skip), zero failures.
- Integration: 128 checks, including the compiled MCP bridge handshake, optional
  GET arguments, automatic session binding, write, idempotent retry and stale revision.
- Rendering: `.build/approval-graph-20261105/render/map-agent-graph.png`.
- Release build: `swift build -c release` passed.

## Automatic-registration verification

- Consent, environment-path resolution, exact Codex block matching, user-owned
  entry preservation and MCP handshake evidence have unit coverage.
- Real Codex and Claude Code MCP-host verification is recorded separately in the
  acceptance evidence after the candidate build is exercised.
- Codex completed a real `approval_graph_get` against the installed candidate.
  Claude Code loaded the server, exposed its tools and produced a matching MCP
  handshake, but its configured third-party model endpoint rejected the model
  before a tool-use event, so Claude tool execution remains partial evidence.
