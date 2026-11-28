#!/usr/bin/env python3
"""Negative-path tests for Scripts/check-swift-safety.py using temporary fixtures."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECKER = REPO_ROOT / "Scripts/check-swift-safety.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


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
    with tempfile.TemporaryDirectory(prefix="xisland-check-swift-safety-") as temp:
        root = Path(temp)
        write(root / "Sources/Clean.swift", "let value = try? risky()\n")

        result = run_checker(root)
        require(result.returncode == 0, "clean fixture should pass", result)

        write(root / "Sources/TryBang.swift", "let value = try! risky()\n")
        result = run_checker(root)
        require(result.returncode != 0, "try! should fail", result)
        require("forbidden runtime token try!" in result.stdout, "try! error should be reported", result)

        write(root / "Sources/TryBang.swift", "let value = try? risky()\n")
        write(root / "Sources/Fatal.swift", "fatalError(\"boom\")\n")
        result = run_checker(root)
        require(result.returncode != 0, "fatalError should fail", result)
        require("forbidden runtime token fatalError" in result.stdout, "fatalError error should be reported", result)

        write(root / "Sources/Fatal.swift", "let value = try? risky()\n")
        write(root / "Sources/AsBang.swift", "let value = object as! String\n")
        result = run_checker(root)
        require(result.returncode != 0, "as! should fail", result)
        require("forbidden runtime token as!" in result.stdout, "as! error should be reported", result)

        write(root / "Sources/AsBang.swift", "let value = object as! String // swift-safety: allow CFTypeID-checked cast\n")
        result = run_checker(root)
        require(result.returncode == 0, "inline allow marker should pass", result)

    result = run_checker(REPO_ROOT)
    require(result.returncode == 0, "repository normal path should pass", result)

    print("check-swift-safety tests passed: clean, try!, fatalError, as!, allow marker, repository normal path.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
