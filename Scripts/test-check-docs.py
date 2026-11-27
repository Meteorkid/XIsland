#!/usr/bin/env python3
"""Negative-path tests for Scripts/check-docs.py using a temporary fixture."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECKER = REPO_ROOT / "Scripts/check-docs.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def prompt_doc(count: int, title: str) -> str:
    blocks = "\n\n".join("```text\nfixture prompt\n```" for _ in range(count))
    return f"# {title}\n\n{blocks}\n"


def build_fixture(root: Path) -> None:
    write(root / "VERSION", "2.3.0\n")
    write(
        root / "Casks/x-island.rb",
        'cask "x-island" do\n  version "2.3.0"\n  sha256 "fixture"\nend\n',
    )
    write(
        root / "docs/releases/2.3.0.md",
        "# X Island 2.3.0\n\n"
        "## English summary\n\nFixture release.\n\n"
        "## Integration changes\n\nNone.\n\n"
        "## macOS Gatekeeper\n\nFixture note.\n",
    )
    write(root / "docs/compatibility/llm-setup-prompts.md", prompt_doc(15, "Central prompts"))
    write(root / "docs/more-prompts.md", prompt_doc(15, "More prompts"))
    write(root / "README.md", "# Fixture\n\n[release note](docs/releases/2.3.0.md)\n")


def run_checker(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(root)],
        text=True,
        capture_output=True,
    )


def require(condition: bool, message: str, result: subprocess.CompletedProcess[str] | None = None) -> None:
    if condition:
        return
    if result is not None:
        message += f"\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    raise SystemExit(message)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="xisland-check-docs-") as temp:
        root = Path(temp)
        build_fixture(root)

        result = run_checker(root)
        require(result.returncode == 0, "fixture baseline should pass", result)

        write(
            root / "README.md",
            "# Fixture\n\n[release note](docs/releases/2.3.0.md)\n[missing](missing.md)\n",
        )
        result = run_checker(root)
        require(result.returncode != 0, "missing link should fail", result)
        require("missing link target missing.md" in result.stdout, "missing link error should be reported", result)

        build_fixture(root)
        write(root / "README.md", "# Fixture\n\n```text\nunclosed fence\n")
        result = run_checker(root)
        require(result.returncode != 0, "unclosed fence should fail", result)
        require("unbalanced ``` fences" in result.stdout, "unclosed fence error should be reported", result)

        build_fixture(root)
        release = root / "docs/releases/2.3.0.md"
        write(release, release.read_text().replace("## macOS Gatekeeper\n", "", 1))
        result = run_checker(root)
        require(result.returncode != 0, "missing release section should fail", result)
        require("missing required section ## macOS Gatekeeper" in result.stdout, "missing section error should be reported", result)

    result = run_checker(REPO_ROOT)
    require(result.returncode == 0, "repository normal path should pass", result)

    print("check-docs tests passed: fixture baseline, missing link, unclosed fence, missing release section, repository normal path.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
