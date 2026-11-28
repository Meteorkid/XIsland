#!/usr/bin/env python3
"""Negative-path tests for Scripts/check-loop-state.py using temporary fixtures."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECKER = REPO_ROOT / "Scripts/check-loop-state.py"


def state_text(
    *,
    completed: int = 10,
    next_iteration: int = 11,
    cycle_start: int = 9,
    cycle_end: int = 16,
    planned: int = 16,
    status: str = "active",
    omit: str | None = None,
) -> str:
    values = {
        "started_at": "2026-11-28T01:09:29+08:00",
        "cycle": "2",
        "cycle_started_at": "2026-11-28T12:18:10+08:00",
        "cycle_start_iteration": str(cycle_start),
        "cycle_end_iteration": str(cycle_end),
        "planned_iterations": str(planned),
        "completed_iterations": str(completed),
        "next_iteration": str(next_iteration),
        "status": status,
        "branch": "codex/release-2.0.19",
        "last_iteration": str(completed),
        "last_task": "G11 循环控制面校验器",
        "last_check": "fixture",
        "next_task": "G12 接入循环状态 CI",
        "notes": "fixture",
    }
    lines = ["# Engineering Loop State", ""]
    for key, value in values.items():
        if key != omit:
            lines.append(f"- {key}: {value}")
    return "\n".join(lines) + "\n"


def write_state(root: Path, text: str) -> Path:
    path = root / "STATE.md"
    path.write_text(text)
    return path


def run_checker(state: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER), "--state", str(state)],
        text=True,
        capture_output=True,
    )


def require(condition: bool, message: str, result: subprocess.CompletedProcess[str] | None = None) -> None:
    if condition:
        return
    if result is not None:
        message += f"\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    raise SystemExit(message)


def expect_failure(root: Path, text: str, needle: str, label: str) -> None:
    result = run_checker(write_state(root, text))
    require(result.returncode != 0, f"{label} should fail", result)
    require(needle in result.stdout, f"{label} error should be reported", result)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="xisland-check-loop-state-") as temp:
        root = Path(temp)

        result = run_checker(write_state(root, state_text()))
        require(result.returncode == 0, "normal active state should pass", result)
        require("iteration 10/16" in result.stdout, "normal state summary should include counters", result)

        expect_failure(
            root,
            state_text(omit="cycle_end_iteration"),
            "missing required field: cycle_end_iteration",
            "missing required field",
        )

        expect_failure(
            root,
            state_text(status="paused"),
            "invalid status: paused",
            "invalid status",
        )

        expect_failure(
            root,
            state_text(next_iteration=17),
            "next_iteration 17 exceeds cycle_end_iteration 16 for active state",
            "out-of-range iteration",
        )

        expect_failure(
            root,
            state_text(next_iteration=12),
            "next_iteration must equal completed_iterations + 1",
            "inconsistent counters",
        )

        result = run_checker(
            write_state(
                root,
                state_text(completed=16, next_iteration=17, status="complete"),
            )
        )
        require(result.returncode == 0, "complete state should pass", result)
        require("status complete" in result.stdout, "complete state summary should include status", result)

    result = run_checker(REPO_ROOT / "docs/engineering-loop/STATE.md")
    require(result.returncode == 0, "repository normal path should pass", result)

    print(
        "check-loop-state tests passed: normal active, missing field, invalid status, "
        "out-of-range iteration, inconsistent counters, complete state, repository normal path."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
