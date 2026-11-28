#!/usr/bin/env python3
"""Lightweight Swift runtime-safety gate for X Island.

The gate intentionally scans a narrow token set so it stays fast and does not
need SwiftSyntax or a macOS toolchain. An inline ``swift-safety: allow`` marker
is required for reviewed exceptions.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parent.parent
ALLOW_MARKER = "swift-safety: allow"
FORBIDDEN_TOKENS = (
    ("try!", re.compile(r"\btry!")),
    ("fatalError", re.compile(r"\bfatalError\s*\(")),
    ("as!", re.compile(r"\bas!")),
)


def display(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def swift_files(root: Path) -> list[Path]:
    sources = root / "Sources"
    if not sources.is_dir():
        return []
    return sorted(sources.rglob("*.swift"))


def check_safety(root: Path) -> tuple[list[Path], list[str]]:
    files = swift_files(root)
    errors: list[str] = []
    if not files:
        errors.append("Sources directory is missing or contains no Swift files")
        return files, errors

    for path in files:
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if ALLOW_MARKER in line:
                continue
            code = line.split("//", 1)[0]
            for name, pattern in FORBIDDEN_TOKENS:
                if pattern.search(code):
                    errors.append(f"{display(path, root)}:{number}: forbidden runtime token {name}")
    return files, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check Swift sources for forced runtime-failure tokens.")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="repository root to check (defaults to this checkout)")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if not root.is_dir():
        print(f"Swift safety checks failed: root is not a directory: {root}")
        return 1

    files, errors = check_safety(root)
    if errors:
        print("Swift safety checks failed:")
        for error in errors:
            print(f"  - {error}")
        return 1
    print(f"Swift safety checks passed: {len(files)} Swift source files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
