#!/usr/bin/env python3
"""Lightweight documentation quality gate for X Island.

This intentionally checks only repository-relative Markdown links and a few
release invariants. It is fast enough to run on every pull request and does not
require Swift or macOS.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parent.parent
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
VERSION_RE = re.compile(r'^\s*version\s+"([^"]+)"', re.MULTILINE)


def readme_files(root: Path) -> list[Path]:
    return [root / "README.md", root / "README_zh.md", root / "Sources/XIslandVSCode/README.md"]


def display(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def markdown_files(root: Path) -> list[Path]:
    try:
        result = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
            cwd=root,
            check=True,
            text=True,
            capture_output=True,
        )
        names = result.stdout.splitlines()
    except (subprocess.CalledProcessError, FileNotFoundError):
        # Temp fixtures are not git repositories; still check the same file set shape.
        names = [str(path.relative_to(root)) for path in root.rglob("*.md")]
    files = []
    for name in names:
        path = root / name
        if path in readme_files(root) or (name.startswith("docs/") and path.exists()):
            files.append(path)
    return sorted(set(files))


def strip_fenced_links(lines: list[str]) -> list[tuple[int, str]]:
    """Yield (line_number, line) outside Markdown fences."""
    in_fence = False
    for number, line in enumerate(lines, 1):
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence:
            yield number, line


def check_fences(path: Path, lines: list[str], errors: list[str], root: Path) -> None:
    fence_lines = [i for i, line in enumerate(lines, 1) if line.startswith("```")]
    if len(fence_lines) % 2:
        errors.append(f"{display(path, root)}: unbalanced ``` fences at line {fence_lines[-1]}")


def resolve_link(path: Path, raw: str) -> Path | None:
    target = raw.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1]
    target = target.split(" ")[0]
    if not target or target.startswith(("#", "/", "mailto:", "tel:", "data:", "javascript:")):
        return None
    if target.startswith(("http://", "https://")):
        return None
    target = target.split("#", 1)[0].split("?", 1)[0]
    if not target or "{{" in target or "}}" in target:
        return None
    target = urllib.parse.unquote(target)
    return (path.parent / target).resolve()


def check_links(path: Path, lines: list[str], errors: list[str], root: Path) -> None:
    for number, line in strip_fenced_links(lines):
        for match in LINK_RE.finditer(line):
            target = resolve_link(path, match.group(1))
            if target is not None and not target.exists():
                target_display = display(target, root) if target.is_relative_to(root) else str(target)
                errors.append(f"{display(path, root)}:{number}: missing link target {target_display}")


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", value)[:3])


def check_release_notes(errors: list[str], root: Path) -> None:
    releases = sorted((root / "docs/releases").glob("*.md"))
    for path in releases:
        version = version_tuple(path.stem)
        if version < (2, 3, 0):
            continue
        text = path.read_text()
        for section in ("## English summary", "## Integration changes", "## macOS Gatekeeper"):
            if section not in text:
                errors.append(f"{display(path, root)}: missing required section {section}")
        if "<pending>" in text:
            errors.append(f"{display(path, root)}: unresolved <pending> placeholder")


def check_version(errors: list[str], root: Path) -> None:
    version = (root / "VERSION").read_text().strip()
    cask = (root / "Casks/x-island.rb").read_text()
    match = VERSION_RE.search(cask)
    if not match or match.group(1) != version:
        errors.append(f"Casks/x-island.rb version does not match VERSION ({version})")
    release_note = root / "docs/releases" / f"{version}.md"
    if not release_note.exists():
        errors.append(f"missing release note for VERSION {version}: {display(release_note, root)}")


def check_prompt_library(paths: list[Path], errors: list[str], root: Path) -> None:
    path = root / "docs/compatibility/llm-setup-prompts.md"
    if not path.exists():
        errors.append("docs/compatibility/llm-setup-prompts.md is missing")
        return
    central_count = sum(1 for line in path.read_text().splitlines() if line.strip() == "```text")
    total_count = sum(
        1
        for markdown in paths
        for line in markdown.read_text().splitlines()
        if line.strip() == "```text"
    )
    if central_count < 15 or total_count < 30:
        errors.append(
            f"prompt coverage is too small: central={central_count}, total={total_count}; expected central>=15 and total>=30"
        )


def check_documentation(root: Path) -> tuple[list[Path], list[str]]:
    errors: list[str] = []
    files = markdown_files(root)
    for path in files:
        text = path.read_text()
        lines = text.splitlines()
        check_fences(path, lines, errors, root)
        check_links(path, lines, errors, root)
    check_release_notes(errors, root)
    check_version(errors, root)
    check_prompt_library(files, errors, root)
    return files, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check X Island Markdown docs and release invariants.")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="repository root to check (defaults to this checkout)")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if not root.is_dir():
        print(f"Documentation checks failed: root is not a directory: {root}")
        return 1

    files, errors = check_documentation(root)
    if errors:
        print("Documentation checks failed:")
        for error in errors:
            print(f"  - {error}")
        return 1
    print(f"Documentation checks passed: {len(files)} Markdown files, all fences and links valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
