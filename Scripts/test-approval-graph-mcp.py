#!/usr/bin/env python3
"""Raw MCP stdio end-to-end check for the approval graph bridge."""

from __future__ import annotations

import json
import os
import subprocess
import sys


def send(process: subprocess.Popen[str], payload: dict) -> None:
    process.stdin.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    process.stdin.flush()


def receive(process: subprocess.Popen[str]) -> dict:
    line = process.stdout.readline()
    if not line:
        raise AssertionError("MCP server exited without a response")
    value = json.loads(line)
    if "error" in value:
        raise AssertionError(f"JSON-RPC error: {value['error']}")
    return value


def call_tool(process: subprocess.Popen[str], request_id: int, name: str,
              arguments: dict | None = None) -> dict:
    params = {"name": name}
    if arguments is not None:
        params["arguments"] = arguments
    send(process, {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": params,
    })
    result = receive(process) ["result"]
    content = result.get("content") or []
    if not content or content[0].get("type") != "text":
        raise AssertionError(f"Missing text result: {result}")
    if result.get("isError"):
        return {"isError": True, "text": content[0].get("text", "")}
    return {"isError": False, "document": json.loads(content[0]["text"])}


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: test-approval-graph-mcp.py <bridge> <session-id> <cwd>", file=sys.stderr)
        return 64
    bridge, session_id, cwd = sys.argv[1:]
    env = os.environ.copy()
    env["DI_SOCKET_PATH"] = os.environ["DI_SOCKET_PATH"]
    env["X_ISLAND_TEST_MODE"] = "1"
    process = subprocess.Popen(
        [bridge, "mcp-server", "--agent", "codex"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, cwd=cwd, env=env,
    )
    try:
        send(process, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "xisland-test", "version": "1"}},
        })
        initialized = receive(process)["result"]
        assert initialized["serverInfo"]["name"] == "xisland-approval-graph"
        send(process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

        send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools = {item["name"] for item in receive(process)["result"]["tools"]}
        assert tools == {"approval_graph_get", "approval_graph_write"}, tools

        # arguments is optional in the MCP tools/call schema.
        initial = call_tool(process, 3, "approval_graph_get")
        assert not initial["isError"], initial
        assert initial["document"]["sessionID"] == session_id
        assert initial["document"]["revision"] == 0

        nodes = [
            {"id": "goal", "parent_id": None, "kind": "task",
             "title": "实现显式任务图", "status": "active"},
            {"id": "mcp", "parent_id": "goal", "kind": "step",
             "title": "增加本地 MCP 写入", "detail": "只写任务图，不触碰审批决定",
             "status": "pending"},
        ]
        write_args = {"base_revision": 0, "request_id": "mcp-e2e-write", "nodes": nodes}
        written = call_tool(process, 4, "approval_graph_write", write_args)
        assert not written["isError"], written
        assert len(written["document"]["proposals"]) == 2
        assert written["document"]["revision"] == 1

        # Retry is idempotent even with the original base revision.
        retried = call_tool(process, 5, "approval_graph_write", write_args)
        assert not retried["isError"], retried
        assert retried["document"]["revision"] == 1

        stale = call_tool(process, 6, "approval_graph_write", {
            **write_args, "request_id": "mcp-e2e-stale", "nodes": nodes[:1],
        })
        assert stale["isError"] and "revision" in stale["text"].lower(), stale

        read_back = call_tool(process, 7, "approval_graph_get", {"session_id": session_id})
        assert not read_back["isError"], read_back
        assert read_back["document"]["proposals"][0]["node"]["id"] == "goal"
        print("approval graph MCP handshake, tools/list, GET, WRITE, retry and stale revision passed")
        return 0
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=3)
        stderr = process.stderr.read()
        if process.returncode not in (0, -15) and stderr:
            print(stderr, file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
