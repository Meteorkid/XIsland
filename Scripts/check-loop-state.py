#!/usr/bin/env python3
"""Validate the engineering-loop control plane in docs/engineering-loop/STATE.md.

The checker is intentionally dependency-free. It verifies the fields that drive
the loop and the counter/status invariants, so a malformed state file cannot
silently schedule an out-of-range or duplicate iteration.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DEFAULT_STATE = Path(__file__).resolve().parent.parent / "docs/engineering-loop/STATE.md"
FIELD_RE = re.compile(r"^- ([a-z][a-z0-9_]*):\s*(.*)$")
REQUIRED_FIELDS = (
    "cycle",
    "cycle_start_iteration",
    "cycle_end_iteration",
    "planned_iterations",
    "completed_iterations",
    "next_iteration",
    "status",
    "branch",
    "last_iteration",
    "last_task",
    "last_check",
    "next_task",
)
INTEGER_FIELDS = (
    "cycle",
    "cycle_start_iteration",
    "cycle_end_iteration",
    "planned_iterations",
    "completed_iterations",
    "next_iteration",
    "last_iteration",
)
STATUSES = {"active", "complete", "blocked"}


def parse_fields(path: Path) -> tuple[dict[str, str], list[str]]:
    if not path.is_file():
        return {}, [f"state file does not exist: {path}"]

    fields: dict[str, str] = {}
    errors: list[str] = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = FIELD_RE.match(line)
        if not match:
            continue
        key, value = match.groups()
        if key in fields:
            errors.append(f"duplicate field: {key} at line {number}")
            continue
        fields[key] = value.strip()
    return fields, errors


def check_state(path: Path) -> tuple[dict[str, str], list[str]]:
    fields, errors = parse_fields(path)
    if errors:
        return fields, errors

    for key in REQUIRED_FIELDS:
        if key not in fields:
            errors.append(f"missing required field: {key}")
        elif not fields[key]:
            errors.append(f"required field is empty: {key}")
    if errors:
        return fields, errors

    numbers: dict[str, int] = {}
    for key in INTEGER_FIELDS:
        try:
            numbers[key] = int(fields[key])
        except ValueError:
            errors.append(f"field {key} is not an integer: {fields[key]}")
    if errors:
        return fields, errors

    cycle = numbers["cycle"]
    start = numbers["cycle_start_iteration"]
    end = numbers["cycle_end_iteration"]
    planned = numbers["planned_iterations"]
    completed = numbers["completed_iterations"]
    next_iteration = numbers["next_iteration"]
    last_iteration = numbers["last_iteration"]
    status = fields["status"]

    if status not in STATUSES:
        errors.append(f"invalid status: {status}")
    if cycle < 1:
        errors.append(f"cycle must be at least 1: {cycle}")
    if start < 1:
        errors.append(f"cycle_start_iteration must be at least 1: {start}")
    if end < start:
        errors.append(f"cycle_end_iteration {end} is before cycle_start_iteration {start}")
    if planned != end:
        errors.append(f"planned_iterations {planned} must equal cycle_end_iteration {end}")
    if completed < start - 1:
        errors.append(f"completed_iterations {completed} is before cycle_start_iteration {start}")
    if completed > end:
        errors.append(f"completed_iterations {completed} exceeds cycle_end_iteration {end}")
    if next_iteration != completed + 1:
        errors.append("next_iteration must equal completed_iterations + 1")
    if last_iteration != completed:
        errors.append("last_iteration must equal completed_iterations")

    if status == "complete":
        if completed != end:
            errors.append(f"complete state requires completed_iterations {end}, found {completed}")
        if next_iteration != end + 1:
            errors.append(f"complete state requires next_iteration {end + 1}, found {next_iteration}")
    elif status in {"active", "blocked"}:
        if next_iteration < start:
            errors.append(f"next_iteration {next_iteration} is before cycle_start_iteration {start} for {status} state")
        if next_iteration > end:
            errors.append(f"next_iteration {next_iteration} exceeds cycle_end_iteration {end} for {status} state")

    return fields, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate the engineering-loop STATE.md control plane.")
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE, help="state file to check (defaults to this checkout)")
    args = parser.parse_args(argv)

    fields, errors = check_state(args.state.resolve())
    if errors:
        print("Loop state checks failed:")
        for error in errors:
            print(f"  - {error}")
        return 1
    print(
        "Loop state checks passed: "
        f"cycle {fields['cycle']}, iteration {fields['completed_iterations']}/{fields['cycle_end_iteration']}, "
        f"status {fields['status']}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
