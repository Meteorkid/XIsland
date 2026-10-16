#!/usr/bin/env python3
"""用临时 Unix socket 检查编译后的 bridge；不启动 AI 客户端或读取实际 hooks。"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
from threading import Thread
from typing import Any


def invoke(binary: Path, agent: str, hook: str, payload: dict[str, Any] | None, *,
           decision: bool | None = None, connect: bool = True,
           environment: dict[str, str] | None = None,
           adapter: str | None = None, answer: str | None = None) -> tuple[dict[str, Any] | None, str, int]:
    with tempfile.TemporaryDirectory(prefix="xi-hook-", dir="/tmp") as directory:
        captured: list[dict[str, Any]] = []
        errors: list[Exception] = []
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.settimeout(5)
        worker: Thread | None = None
        if connect:
            server.bind(directory + "/di.sock")
            server.listen(1)

            def receive() -> None:
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(5)
                        stream = connection.makefile("rb")
                        with stream:
                            message = json.loads(stream.readline(16 * 1024 * 1024))
                        captured.append(message)
                        if decision is not None:
                            response = {"type": "permission_response", "sessionId": message["sessionId"],
                                        "timestamp": "2026-09-18T00:00:00Z", "approved": decision}
                            connection.sendall(json.dumps(response).encode() + b"\n")
                        elif answer is not None:
                            response = {"type": "question_response", "sessionId": message["sessionId"],
                                        "timestamp": "2026-09-18T00:00:00Z", "answer": answer}
                            connection.sendall(json.dumps(response).encode() + b"\n")
                except Exception as error:
                    errors.append(error)

            worker = Thread(target=receive, daemon=True)
            worker.start()
        env = dict(os.environ)
        # 测试身份不继承父会话，也不接触常驻应用的 socket 或日志。
        for key in ["DI_SESSION_ID", "DI_SOCKET_PATH", "DEVIN_PROJECT_DIR", "DI_BRIDGE_DEBUG_LOG"]:
            env.pop(key, None)
        env.update({"X_ISLAND_TEST_MODE": "1", "X_ISLAND_TEST_RUNTIME_DIR": directory})
        env.update(environment or {})
        try:
            arguments = [str(binary), "--agent", agent, "--hook", hook]
            if adapter:
                arguments += ["--adapter", adapter]
            result = subprocess.run(arguments,
                                    input="" if payload is None else json.dumps(payload), text=True, capture_output=True, env=env, timeout=7)
            if worker:
                worker.join(timeout=6)
                if worker.is_alive():
                    raise AssertionError("mock socket worker did not finish")
                if errors:
                    raise errors[0]
            return captured[0] if captured else None, result.stdout.strip(), result.returncode
        finally:
            server.close()


def verify(binary: Path) -> list[str]:
    passed: list[str] = []
    for event in ["agentSpawn", "userPromptSubmit", "preToolUse", "postToolUse", "stop"]:
        payload = {"hook_event_name": event, "session_id": "kiro-native", "cwd": "/tmp/project",
                   "prompt": "fixture", "tool_name": "read", "tool_input": {"path": "fixture"},
                   "tool_response": {"success": False, "error": "fixture"}, "assistant_response": "Finished"}
        message, output, code = invoke(binary, "kiro", event, payload, adapter="kiro_cli")
        assert code == 0 and output == "" and message, (event, code, output, message)
        assert message["agentType"] == "kiro" and message["type"] not in ["permission_request", "session_end"]
        assert "toolCallId" not in message and "nativeRequestId" not in message
        if event == "preToolUse":
            assert message["type"] == "status_update"
        if event == "postToolUse":
            assert message["type"] == "tool_complete" and message["observedState"] == "error"
        if event == "stop":
            assert message["observedState"] == "completionUnconfirmed"
        passed.append("kiro:" + event)
    _, output, code = invoke(binary, "kiro", "agentSpawn", {"hook_event_name": "agentSpawn", "cwd": "/tmp"},
                             adapter="kiro_cli", connect=False)
    assert code != 0 and output == "", (code, output)
    passed.append("kiro:missing-native-identity-rejected")
    _, output, code = invoke(binary, "kiro", "stop", {"hook_event_name": "stop", "session_id": "native",
                             "cwd": "/tmp", "assistant_response": "done"}, adapter="kiro_cli", connect=False)
    assert code == 0 and output == "", (code, output)
    passed.append("kiro:disconnected-observation-empty-output")
    for event, expected in [("SessionStart", "session_start"), ("UserPromptSubmit", "session_start"),
                            ("PreToolUse", "status_update"), ("PostToolUse", "tool_complete"),
                            ("Stop", "status_update"), ("SessionEnd", "session_end")]:
        payload = {"hook_event_name": event, "session_id": "kiro-v3", "cwd": "/tmp/project",
                   "prompt": "fixture", "tool_name": "read", "tool_input": {"path": "fixture"},
                   "tool_response": {"success": True, "content": "fixture"}}
        message, output, code = invoke(binary, "kiro", event, payload, adapter="kiro_cli")
        assert code == 0 and output == "" and message and message["type"] == expected
        if event == "Stop":
            assert message["observedState"] == "completionUnconfirmed" and message["statusIsAssistantReply"] is False
        if event == "SessionEnd":
            assert message["observedState"] == "completed"
        passed.append("kiro-v3:" + event)
    config_args = [str(binary), "kiro-config-v3", "--cli-version", "2.31.0", "--engine", "v3"]
    exported = subprocess.run(config_args, input="{}", capture_output=True, text=True, timeout=5)
    assert exported.returncode == 0 and not exported.stderr
    config = json.loads(exported.stdout)
    assert config["version"] == "v1" and len(config["hooks"]) == 6
    assert {hook["trigger"] for hook in config["hooks"]} == {
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"}
    passed.append("kiro-v3:compiled-config-export")
    repeated = subprocess.run(config_args, input=exported.stdout, capture_output=True, text=True, timeout=5)
    assert repeated.returncode == 0 and json.loads(repeated.stdout) == config
    removed = subprocess.run([str(binary), "kiro-config-v3", "--remove"], input=repeated.stdout,
                             capture_output=True, text=True, timeout=5)
    assert removed.returncode == 0 and json.loads(removed.stdout)["hooks"] == []
    passed.append("kiro-v3:compiled-idempotence-and-removal")
    rejected = subprocess.run([str(binary), "kiro-config-v3", "--cli-version", "unknown", "--engine", "v3"],
                              input="{}", capture_output=True, text=True, timeout=5)
    assert rejected.returncode != 0 and not rejected.stdout
    passed.append("kiro-v3:compiled-unknown-version-rejected")
    model_cases = [
        ("claude_code", "SessionStart", None, {"hook_event_name": "SessionStart", "session_id": "glm", "model": "glm-5.3"}),
        ("opencode", "prompt.submitted", "opencode_plugin", {"native_event": "prompt.submitted", "session_id": "glm", "model": "glm-5.3"}),
        ("cline", "TaskStart", None, {"hookName": "TaskStart", "taskId": "glm", "timestamp": "1789550000000",
                                     "taskStart": {}, "model": {"slug": "glm-5.3"}}),
        ("pi", "session_start", None, {"native_event": "session_start", "hook_event_name": "SessionStart", "session_id": "glm", "model": "glm-5.3"}),
    ]
    for agent, event, adapter, payload in model_cases:
        message, _, code = invoke(binary, agent, event, payload, adapter=adapter)
        assert code == 0 and message and message["agentType"] == agent and message["model"] == "glm-5.3"
        passed.append("glm-model:" + agent)
    for agent in ["claude_code", "codex", "qwen", "qoder"]:
        message, output, code = invoke(binary, agent, "PermissionRequest", {
            "hook_event_name": "PermissionRequest", "session_id": "permission-fixture", "cwd": "/tmp/project",
            "tool_name": "Bash", "tool_input": {"command": "fixture-only; not executed"},
        }, decision=False)
        assert message and message["type"] == "permission_request", (agent, message)
        assert code == 0, (agent, code)
        assert json.loads(output)["hookSpecificOutput"]["decision"]["behavior"] == "deny", (agent, output)
        passed.append(agent + ":structured-denial")
    _, output, code = invoke(binary, "codex", "PermissionRequest", {
        "hook_event_name": "PermissionRequest", "session_id": "allow-fixture", "cwd": "/tmp/project",
        "tool_name": "Bash", "tool_input": {"command": "fixture-only"},
    }, decision=True)
    assert code == 0 and json.loads(output)["hookSpecificOutput"]["decision"]["behavior"] == "allow"
    passed.append("codex:structured-approval")

    devin = {"hook_event_name": "PermissionRequest", "session_id": "devin-fixture", "prompt_id": "turn",
             "tool_name": "exec", "tool_input": {"command": "fixture-only"}}
    _, output, code = invoke(binary, "devin", "PermissionRequest", devin, decision=False)
    assert code == 0 and json.loads(output)["decision"] == "block"
    passed.append("devin:structured-denial")
    _, output, code = invoke(binary, "devin", "PermissionRequest", devin, connect=False)
    assert code == 2 and json.loads(output)["decision"] == "block"
    passed.append("devin:unavailable-bridge-denial")

    observations: list[tuple[str, str, dict[str, Any], str, str | None]] = [
        ("claude_code", "notification", {"session_id": "fixture", "hook_event_name": "Stop", "cwd": "/tmp/project"}, "status_update", "completionUnconfirmed"),
        ("codex", "Stop", {"session_id": "fixture", "hook_event_name": "Stop", "last_assistant_message": "No errors found"}, "status_update", "completionUnconfirmed"),
        ("codex", "session_end", {"session_id": "fixture", "hook_event_name": "SessionEnd"}, "session_end", "completed"),
        ("qwen", "notification", {"session_id": "fixture", "hook_event_name": "Stop", "stop_hook_active": True, "last_assistant_message": "Review ready"}, "status_update", "completionUnconfirmed"),
        ("qoder", "notification", {"session_id": "fixture", "hook_event_name": "Stop", "stop_hook_active": True, "last_assistant_message": "Review ready"}, "status_update", "completionUnconfirmed"),
        ("droid", "toolstart", {"session_id": "fixture", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": {}}, "tool_start", None),
        ("droid", "notification", {"session_id": "fixture", "hook_event_name": "Stop", "stop_hook_active": True}, "status_update", "completionUnconfirmed"),
        ("droid", "subagent_end", {"session_id": "fixture", "hook_event_name": "SubagentStop", "task_name": "Review", "task_result": "Ready", "stop_hook_active": True}, "subagent_end", None),
        ("gemini_cli", "notification", {"session_id": "fixture", "hook_event_name": "AfterAgent", "prompt_response": "Done"}, "status_update", "completionUnconfirmed"),
        ("windsurf", "post_cascade_response", {"trajectory_id": "fixture", "execution_id": "turn", "agent_action_name": "post_cascade_response", "timestamp": "2026-09-18T00:00:00Z", "model_name": "Unknown", "tool_info": {"response": "Done"}}, "status_update", "idle"),
        ("amp", "toolcomplete", {"session_id": "fixture", "native_event": "tool.result", "hook_event_name": "PostToolUse", "tool_use_id": "call", "tool_name": "Bash", "tool_response": {"value": "fixture"}, "native_status": "error"}, "tool_complete", "error"),
        ("pi", "notification", {"session_id": "fixture", "native_event": "agent_settled", "hook_event_name": "Stop"}, "status_update", "idle"),
        ("copilot_cli", "notification", {"sessionId": "fixture", "timestamp": 1789689600000, "cwd": "/tmp/project", "message": "Native permission required", "notification_type": "permission_prompt"}, "status_update", "waitingPermission"),
        ("copilot_cli", "agentStop", {"sessionId": "fixture", "timestamp": 1789689600000, "cwd": "/tmp/project", "stopReason": "end_turn", "stop_hook_active": True, "transcriptPath": "/tmp/unused"}, "status_update", "completionUnconfirmed"),
        ("tabnine", "notification", {"session_id": "fixture", "hook_event_name": "AfterAgent", "prompt_response": "Reply preview"}, "status_update", "completionUnconfirmed"),
        ("tabnine", "Notification", {"session_id": "fixture", "hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "Unknown notice"}, "status_update", None),
        ("gemini_cli", "Notification", {"session_id": "fixture", "hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "Unknown notice"}, "status_update", None),
        ("tabnine", "toolstart", {"session_id": "fixture", "hook_event_name": "BeforeTool", "tool_name": "AskUserQuestion", "tool_input": {}}, "tool_start", None),
    ]
    for agent, hook, payload, expected_type, state in observations:
        message, output, code = invoke(binary, agent, hook, payload)
        assert code == 0 and message and message["type"] == expected_type, (agent, message, code)
        assert message.get("observedState") == state, (agent, message)
        assert message["sessionId"] == agent + "-fixture", (agent, message)
        if agent == "amp":
            assert message["toolCallId"] == "call"
        if agent == "droid" and hook == "subagent_end":
            assert message.get("subagentEndIsProvisional") is True
            assert message.get("subagentId") is None and message.get("parentSessionId") is None
        if output:
            assert json.loads(output) == {}, (agent, output)
        passed.append(agent + ":" + hook)

    for event, trigger, expected_type, state in [
        ("Interrupt", None, "status_update", "completionUnconfirmed"),
        ("PreCompact", "manual", "context_compact", None),
        ("PreCompact", "auto", "context_compact", None),
        ("PostCompact", "manual", "status_update", "completionUnconfirmed"),
        ("PostCompact", "auto", "status_update", "completionUnconfirmed"),
    ]:
        payload = {"session_id": "codex-lifecycle", "hook_event_name": event,
                   "turn_id": "native-turn", "cwd": "/tmp/project", "permission_mode": "default"}
        if trigger is not None:
            payload["trigger"] = trigger
        message, output, code = invoke(binary, "codex", event, payload)
        assert code == 0 and message and message["type"] == expected_type, (event, message, code)
        assert message["sessionId"] == "codex-codex-lifecycle" and message["nativeTurnId"] == "native-turn"
        assert message["nativeEvent"] == event and message.get("observedState") == state
        assert message["statusIsAssistantReply"] is False and json.loads(output) == {}
        passed.append("codex:" + event + (":" + trigger if trigger else ""))
        _, output, code = invoke(binary, "codex", event, payload, connect=False)
        assert code == 0 and json.loads(output) == {}, (event, output, code)
        passed.append("codex:disconnected:" + event + (":" + trigger if trigger else ""))

    for event in ("Interrupt", "PreCompact", "PostCompact"):
        _, _, code = invoke(binary, "codex", event, {
            "session_id": "codex-invalid", "hook_event_name": event, "turn_id": "", "trigger": "manual",
        }, connect=False)
        assert code != 0, event
        passed.append("codex:missing-turn-rejected:" + event)

    for event, fields, expected_type, state in [
        ("preToolUse", {"tool_name": "AskUserQuestion", "tool_use_id": "call", "tool_input": {}}, "tool_start", None),
        ("afterAgentResponse", {"text": "No errors found"}, "status_update", None),
        ("stop", {"status": "completed"}, "status_update", "idle"),
    ]:
        payload = {"conversation_id": "fixture", "generation_id": "turn", "hook_event_name": event,
                   "workspace_roots": ["/tmp/project"], **fields}
        message, output, code = invoke(binary, "cursor", event, payload)
        assert code == 0 and message and message["type"] == expected_type
        assert message["sessionId"] == "cursor-fixture" and message.get("observedState") == state
        passed.append("cursor:" + event)

    for agent in ["codex", "claude_code", "qwen", "qoder"]:
        for event in ["SubagentStart", "SubagentStop"]:
            payload = {"session_id": "parent", "hook_event_name": event, "cwd": "/tmp/project",
                       "agent_id": "child", "agent_type": "reviewer", "stop_hook_active": True}
            hook = event if agent == "codex" else ("subagent_start" if event == "SubagentStart" else "subagent_end")
            message, output, code = invoke(binary, agent, hook, payload)
            assert code == 0 and message and json.loads(output) == {}
            assert message["type"] == ("subagent_start" if event == "SubagentStart" else "subagent_end")
            assert message["sessionId"] == agent + "-parent"
            assert message.get("parentSessionId") == (None if agent in ["qwen", "qoder"] else agent + "-parent")
            assert message["subagentId"] == agent + "-child"
            assert message.get("subagentEndIsProvisional") == (True if event == "SubagentStop" else None)
            passed.append(agent + ":" + event)

    for event, fields, expected_type, state in [
        ("PreToolUse", {"tool_name": "AskUserQuestion", "tool_use_id": "call", "tool_input": {}}, "tool_start", None),
        ("Notification", {"notification_type": "document_review", "message": "Review in Trae"}, "status_update", "waitingPlanReview"),
        ("Stop", {"last_assistant_message": "Done", "stop_hook_active": False}, "status_update", "completionUnconfirmed"),
        ("Stop", {"last_assistant_message": "Continue checking", "stop_hook_active": True, "loop_count": 1}, "status_update", "completionUnconfirmed"),
    ]:
        payload = {"session_id": "fixture", "cwd": "/tmp/project", "hook_event_name": event, **fields}
        message, output, code = invoke(binary, "trae", event, payload, adapter="trae_cn")
        assert code == 0 and message and message["type"] == expected_type
        assert message["sessionId"] == "trae-fixture" and message.get("observedState") == state
        assert json.loads(output) == {}
        passed.append("trae_cn:" + event + (":continued" if fields.get("stop_hook_active") else ""))

    message, output, code = invoke(binary, "claude_code", "PermissionRequest", devin, connect=False,
                                   environment={"DEVIN_PROJECT_DIR": "/tmp/project"})
    assert message is None and code == 0 and json.loads(output) == {}
    passed.append("devin:imported-claude-neutral-output")

    for event, fields, expected_type, state in [
        ("PreToolUse", {"tool_name": "AskUserQuestion", "tool_input": {}, "tool_call_id": "call"}, "tool_start", None),
        ("PostToolUseFailure", {"tool_name": "Shell", "tool_input": {}, "error": "fixture"}, "tool_complete", "error"),
        ("Stop", {}, "status_update", "completionUnconfirmed"),
        ("SessionEnd", {"reason": "exit"}, "session_end", "completed"),
    ]:
        message, output, code = invoke(binary, "kimi", event, {"session_id": "fixture", "hook_event_name": event, **fields})
        assert code == 0 and message and message["type"] == expected_type
        assert message["sessionId"] == "kimi-fixture" and message.get("observedState") == state
        assert json.loads(output) == {}
        passed.append("kimi:" + event)

    node_fixtures = json.loads((Path(__file__).resolve().parent.parent
        / "Tests/Fixtures/companion/kimi-code-hooks.json").read_text())["cases"]
    for fixture in node_fixtures:
        event, payload = fixture["event"], fixture["input"]
        message, output, code = invoke(binary, "kimi", event, payload, adapter="kimi_code")
        assert code == 0 and output == "" and message, (event, code, output, message)
        assert message["sessionId"] == "kimi_code-node-fixture" and message["agentType"] == "kimi"
        assert message["nativeEvent"] == "kimi_code." + event
        assert message["type"] == fixture["expectedType"] and message.get("observedState") == fixture["expectedState"]
        assert message.get("statusIsAssistantReply") is False
        assert message["type"] not in ["permission_request", "question", "plan_review"]
        assert message.get("approved") is None and message.get("nativeTaskId") is None
        assert message.get("subagentId") is None and message.get("sourceInstanceId") is None
        if event in ("PermissionRequest", "PermissionResult"):
            assert message["nativeRequestId"] == "approval_fixture"
            assert message["nativeAgentId"] == "agent-main" and message["nativeTurnId"] == "0"
        if event == "UserPromptSubmit":
            assert message["prompt"] == "Inspect fixture"
        if event in ("TurnStarted", "UserPromptQueued"):
            assert message.get("prompt") is None
        passed.append("kimi_code:" + event)
    for event in ("UserPromptSubmit", "Stop"):
        payload = next(row["input"] for row in node_fixtures if row["event"] == event)
        _, output, code = invoke(binary, "kimi", event, payload, adapter="kimi_code", connect=False)
        assert code == 0 and output == "", (event, code, output)
        passed.append("kimi_code:disconnected:" + event)
    payload = dict(node_fixtures[0]["input"])
    payload.pop("session_id")
    _, output, code = invoke(binary, "kimi", "SessionStart", payload, adapter="kimi_code", connect=False)
    assert code == 1 and output == "", (code, output)
    passed.append("kimi_code:missing-native-identity-rejected")

    for event, fields, expected_type, state in [
        ("PreToolUse", {"tool_name": "AskUserQuestion", "tool_input": {}}, "tool_start", None),
        ("Notification", {"notification_type": "permission_prompt", "message": "Respond in CodeBuddy"}, "status_update", "waitingPermission"),
        ("Stop", {"stop_hook_active": False}, "status_update", "completionUnconfirmed"),
    ]:
        message, output, code = invoke(binary, "code_buddy", event, {"session_id": "fixture", "hook_event_name": event, **fields})
        assert code == 0 and message and message["type"] == expected_type
        assert message["sessionId"] == "code_buddy-fixture" and message.get("observedState") == state
        assert message["statusIsAssistantReply"] is False
        passed.append("code_buddy:" + event)

    for event, field, value, expected_type, state in [
        ("TaskStart", "taskStart", {"taskMetadata": {"initialTask": "Fixture"}}, "session_start", None),
        ("PreToolUse", "preToolUse", {"toolName": "ask_followup_question", "parameters": {"question": "Choose"}}, "tool_start", None),
        ("PostToolUse", "postToolUse", {"toolName": "read_file", "parameters": {}, "result": "Failed"}, "tool_complete", "error"),
        ("TaskComplete", "taskComplete", {"taskMetadata": {"result": "Done"}}, "status_update", "idle"),
    ]:
        payload = {"taskId": "fixture", "hookName": event, "timestamp": "1790208000000", "workspaceRoots": ["/tmp/project"], field: value}
        message, output, code = invoke(binary, "cline", event, payload)
        assert code == 0 and message and message["type"] == expected_type
        assert message["sessionId"] == "cline-fixture" and message.get("observedState") == state
        passed.append("cline:" + event)

    for event, fields, expected_type in [
        ("UserPromptSubmit", {"prompt": "Fixture"}, "session_start"),
        ("PreToolUse", {"tool_name": "AskUserQuestion", "tool_input": {}, "tool_use_id": "call"}, "tool_start"),
        ("SubagentStop", {"agent_id": "sub-1", "agent_type": "Plan"}, "subagent_end"),
        ("Stop", {"stop_hook_active": False}, "status_update"),
    ]:
        payload = {"session_id": "fixture", "hook_event_name": event, "timestamp": "2026-09-24T00:00:00Z", **fields}
        message, output, code = invoke(binary, "copilot", event, payload, adapter="vscode_local")
        assert code == 0 and message and message["type"] == expected_type
        assert message["sessionId"] == "copilot-local-fixture"
        assert message.get("observedState") == ("completionUnconfirmed" if event == "Stop" else None)
        assert message["statusIsAssistantReply"] is False
        if event == "SubagentStop":
            assert message["subagentId"] == "copilot-local-fixture-subagent-sub-1"
            assert message["subagentEndIsProvisional"] is True
        passed.append("vscode_local:" + event)

    for event, payload, fields, expected_type, state in [
        ("session_start", None, {}, "session_start", None),
        ("tool_call_before", None, {"DEEPSEEK_TOOL_NAME": "AskUserQuestion", "DEEPSEEK_TOOL_ARGS": "{}",
                                    "CODEWHALE_TOOL_CALL_ID": "call"}, "tool_start", None),
        ("tool_call_after", None, {"DEEPSEEK_TOOL_NAME": "Shell", "DEEPSEEK_TOOL_RESULT": "failed",
                                   "DEEPSEEK_TOOL_SUCCESS": "false", "CODEWHALE_TOOL_CALL_ID": "call"}, "tool_complete", "error"),
        ("waiting_for_user", {"from": "in_progress", "to": "waiting", "reason": "approval"}, {}, "status_update", "waitingPermission"),
        ("turn_end", {"event": "turn_end", "status": "completed", "totals": {"session_tokens": 30, "input_tokens": 20, "output_tokens": 10}}, {}, "status_update", None),
        ("session_end", None, {}, "session_end", "completed"),
    ]:
        environment = {"CODEWHALE_SESSION_ID": "fixture", "DEEPSEEK_SESSION_ID": "fixture",
                       "DEEPSEEK_WORKSPACE": "/tmp/project", "DEEPSEEK_TOTAL_TOKENS": "30", "DEEPSEEK_SESSION_COST": "0.02", **fields}
        message, output, code = invoke(binary, "deepseek", event, payload, environment=environment)
        assert code == 0 and message and message["type"] == expected_type
        assert message["sessionId"] == "deepseek-fixture" and message.get("observedState") == state
        assert message["nativeEvent"] == event and message["usageIsCumulative"] is True
        assert message["statusIsAssistantReply"] is False
        assert message.get("nativeRequestId") is None and message.get("questionText") is None
        passed.append("codewhale:" + event)

    request = {"session_id": "fixture", "native_event": "permission.asked", "native_request_id": "upstream-id",
               "native_request_kind": "permission", "permission": "external_directory", "patterns": ["/fixture"]}
    message, output, code = invoke(binary, "opencode", "permission.asked", request, adapter="opencode_plugin", decision=False)
    assert code == 0 and json.loads(output) == {"decision": "deny"}
    assert message and message["nativeRequestId"] == "upstream-id" and message["nativeRequestKind"] == "permission"
    passed.append("opencode:explicit-denial")
    selected = '中文\n"quoted"'
    question = {"session_id": "fixture", "native_event": "question.asked", "native_request_id": "question-id",
                "native_request_kind": "question", "question": "Choose", "options": [selected, "Other"]}
    message, output, code = invoke(binary, "opencode", "question.asked", question, adapter="opencode_plugin", answer=selected)
    assert code == 0 and json.loads(output) == {"answer": selected}
    assert message and message["nativeRequestKind"] == "question"
    passed.append("opencode:structured-question-answer")
    custom_answer = "自定义路径 /tmp/项目\n保留换行和引号 \"fixture\""
    custom_question = {**question, "native_request_id": "free-text", "options": [], "allow_custom_answer": True}
    message, output, code = invoke(binary, "opencode", "question.asked", custom_question,
                                  adapter="opencode_plugin", answer=custom_answer)
    assert code == 0 and json.loads(output) == {"answer": custom_answer}
    assert message and message["allowsCustomAnswer"] is True and message["options"] == []
    passed.append("opencode:free-text-question-roundtrip")
    resolution = {"session_id": "fixture", "native_event": "interaction.resolved", "native_request_id": "upstream-id", "native_request_kind": "permission"}
    message, _, code = invoke(binary, "opencode", "interaction.resolved", resolution, adapter="opencode_plugin")
    assert code == 0 and message and message["type"] == "interaction_resolved"
    assert message["nativeRequestId"] == "upstream-id" and message["sessionId"] == "opencode-fixture"
    passed.append("opencode:external-resolution")
    return passed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / ".build/debug/DIBridge")
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args()
    binary = arguments.binary.resolve(strict=True)
    passed = verify(binary)
    report = {"checkedAt": datetime.now(timezone.utc).isoformat(), "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "scope": "Compiled bridge stdin/socket/stdout against synthetic local peer; not vendor client acceptance.",
              "passed": passed, "count": len(passed), "realClientVerified": False}
    if arguments.report:
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Native hook bridge: {len(passed)} scenarios passed")


if __name__ == "__main__":
    main()
