#!/usr/bin/env python3
"""在临时目录中验证 CLI 升级；所有系统/网络动作均由替身接管。"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


LIB = Path(__file__).resolve().parent / "lib" / "xisland-cli.sh"
DMG_BYTES = b"isolated DMG fixture\n"
DMG_NAME = "XIsland-1.2.3.dmg"
SHA256 = hashlib.sha256(DMG_BYTES).hexdigest()

STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(os.environ["CLI_TEST_ROOT"])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / "events.jsonl").open("a") as stream:
    stream.write(json.dumps([name, args]) + "\n")
failure = os.environ.get("CLI_TEST_FAILURE", "")
def inside(value):
    path = pathlib.Path(os.path.abspath(value))
    assert path != root and root in path.parents, (name, value)
    return path
if name == "gh":
    assert args[0] == "release"
    if args[1] == "list":
        print("v1.2.3")
    elif args[1] == "view":
        print((root / "release.json").read_text())
    elif args[1] == "download":
        if failure == "download": sys.exit(1)
        inside(args[args.index("--output") + 1]).write_bytes((root / "fixture.dmg").read_bytes())
    else: raise AssertionError(args)
elif name == "mktemp":
    assert args[0] == "-d", args
    template = inside(args[1]) if len(args) > 1 else root / "tmp" / "download.XXXXXX"
    print(tempfile.mkdtemp(prefix=template.name.removesuffix("XXXXXX"), dir=template.parent))
elif name == "hdiutil":
    if args[0] == "attach":
        if failure == "mount": sys.exit(1)
        mount = inside(args[args.index("-mountpoint") + 1]) if "-mountpoint" in args else root / "Volumes" / "Fixture"
        mount.mkdir(parents=True, exist_ok=True)
        if failure != "missing-app": shutil.copytree(root / "source.app", mount / "X Island.app")
        print("/dev/fixture\tApple_HFS\t" + str(mount))
    else:
        assert args[0] == "detach"
        mount = inside(args[1])
        if failure == "detach": sys.exit(1)
        if mount.exists(): shutil.rmtree(mount)
elif name == "codesign":
    assert args[:3] == ["--verify", "--deep", "--strict"], args
    path = inside(args[-1])
    if failure == "mounted-signature" and "mount" in path.parts: sys.exit(1)
    if failure == "staged-signature" and ".xisland-upgrade." in str(path): sys.exit(1)
    assert (path / "Contents" / "version").read_text() == "new"
elif name == "cp":
    source, target = inside(args[-2]), inside(args[-1])
    if failure == "copy":
        target.mkdir(parents=True, exist_ok=True)
        (target / "partial").write_text("incomplete")
        sys.exit(1)
    sys.exit(subprocess.call(["/bin/cp", *args]))
elif name == "mv":
    source, target = inside(args[-2]), inside(args[-1])
    if failure == "replace" and source.name == "X Island.app" and target == root / "Applications" / "X Island.app": sys.exit(1)
    if failure == "backup" and target.name == "previous.app": sys.exit(1)
    if failure == "rollback" and source.name == "previous.app": sys.exit(1)
    sys.exit(subprocess.call(["/bin/mv", *args]))
elif name == "rm":
    for arg in args:
        if not arg.startswith("-"): inside(arg)
    sys.exit(subprocess.call(["/bin/rm", *args]))
elif name == "open":
    path = inside(args[-1])
    if failure in ("launch", "rollback") and (path / "Contents" / "version").read_text() == "new": sys.exit(1)
elif name == "pkill":
    assert args == ["-x", "XIsland"], args
elif name == "xattr":
    inside(args[-1])
else: raise AssertionError(name)
'''


class UpgradeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="xisland-cli-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Applications" / "X Island.app"
        self.app.joinpath("Contents").mkdir(parents=True)
        self.app.joinpath("Contents/version").write_text("old")
        self.root.joinpath("source.app/Contents").mkdir(parents=True)
        self.root.joinpath("source.app/Contents/version").write_text("new")
        self.root.joinpath("fixture.dmg").write_bytes(DMG_BYTES)
        self.root.joinpath("tmp").mkdir()
        self.root.joinpath("bin").mkdir()
        for command in ("gh", "mktemp", "hdiutil", "codesign", "open", "pkill", "xattr", "cp", "mv", "rm"):
            stub = self.root / "bin" / command
            stub.write_text(STUB)
            stub.chmod(0o755)
        self.release = {
            "tagName": "v1.2.3",
            "body": f"{DMG_NAME} SHA256: {SHA256}",
            "assets": [{"name": DMG_NAME, "url": f"https://github.com/Meteorkid/XIsland/releases/download/v1.2.3/{DMG_NAME}"}],
        }

    def run_upgrade(self, failure: str = "", app_path: str | None = None) -> subprocess.CompletedProcess[str]:
        self.root.joinpath("release.json").write_text(json.dumps(self.release))
        environment = os.environ.copy()
        environment.pop("X_ISLAND_REPO", None)
        environment.pop("X_ISLAND_TEST_MODE", None)
        environment.update(
            PATH=f"{self.root / 'bin'}:{environment['PATH']}",
            TMPDIR=str(self.root / "tmp"),
            X_ISLAND_APP_PATH=str(self.app) if app_path is None else app_path,
            CLI_TEST_ROOT=str(self.root),
            CLI_TEST_FAILURE=failure,
            CLI_TEST_LIB=str(LIB),
        )
        result = subprocess.run(
            ["/bin/bash", "-c", 'source "$CLI_TEST_LIB"; xisland_configure_cli_path() { echo "path-config:stub"; }; xisland_dispatch upgrade'],
            env=environment, text=True, capture_output=True, timeout=15,
        )
        self.assertNotIn("Traceback", result.stderr, result.stdout + result.stderr)
        return result

    def events(self, name: str) -> list[list[str]]:
        path = self.root / "events.jsonl"
        return [args for command, args in map(json.loads, path.read_text().splitlines()) if command == name] if path.exists() else []

    def assert_old_preserved(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.app.joinpath("Contents/version").exists(), result.stdout + result.stderr)
        self.assertEqual(self.app.joinpath("Contents/version").read_text(), "old")

    def assert_clean(self) -> None:
        self.assertEqual(list(self.root.joinpath("tmp").iterdir()), [])
        self.assertEqual(list(self.app.parent.glob(".xisland-upgrade.*")), [])

    def test_missing_checksum_preserves_old_app(self) -> None:
        self.release["body"] = "No checksum published"
        result = self.run_upgrade()
        self.assert_old_preserved(result)
        self.assertEqual(self.events("hdiutil"), [])
        self.assertEqual(self.events("pkill"), [])

    def test_copy_failure_preserves_old_app(self) -> None:
        result = self.run_upgrade("copy")
        self.assert_old_preserved(result)
        self.assertEqual(self.events("pkill"), [])
        self.assert_clean()

    def test_success_uses_official_repo_exact_asset_and_cleans_artifacts(self) -> None:
        self.release["assets"].insert(0, {"name": "unrelated.dmg", "url": "https://example.com/unrelated.dmg"})
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.app.joinpath("Contents/version").read_text(), "new")
        for args in self.events("gh"):
            self.assertEqual(args[args.index("--repo") + 1], "Meteorkid/XIsland")
        download = next(args for args in self.events("gh") if args[1] == "download")
        self.assertEqual(download[2], "v1.2.3")
        self.assertEqual(download[download.index("--pattern") + 1], DMG_NAME)
        self.assertEqual(len(self.events("codesign")), 2)
        self.assertEqual(len(self.events("hdiutil")), 2)
        self.assertIn("path-config:stub", result.stdout)
        self.assert_clean()

    def test_mismatching_checksum_never_mounts(self) -> None:
        self.release["body"] = f"{DMG_NAME} SHA256: {'0' * 64}"
        self.assert_old_preserved(self.run_upgrade())
        self.assertEqual(self.events("hdiutil"), [])
        self.assert_clean()

    def test_checksum_must_name_selected_asset(self) -> None:
        self.release["body"] = f"other.dmg SHA256: {SHA256}"
        self.assert_old_preserved(self.run_upgrade())
        self.assertEqual(self.events("gh")[-1][1], "view")

    def test_conflicting_checksums_rejected(self) -> None:
        self.release["body"] += f"\n{DMG_NAME} SHA256: {'0' * 64}"
        self.assert_old_preserved(self.run_upgrade())
        self.assertEqual(self.events("hdiutil"), [])

    def test_gnu_and_bsd_checksum_formats(self) -> None:
        for body in (f"{SHA256}  {DMG_NAME}", f"SHA256 ({DMG_NAME}) = {SHA256}"):
            with self.subTest(body=body):
                self.release["body"] = body
                result = self.run_upgrade()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_release_tag_mismatch_rejected(self) -> None:
        self.release["tagName"] = "v9.9.9"
        self.assert_old_preserved(self.run_upgrade())
        self.assertEqual(self.events("hdiutil"), [])

    def test_duplicate_exact_assets_rejected(self) -> None:
        self.release["assets"].append(self.release["assets"][0].copy())
        self.assert_old_preserved(self.run_upgrade())
        self.assertEqual(self.events("hdiutil"), [])

    def test_missing_exact_asset_rejected(self) -> None:
        self.release["assets"][0]["name"] = "different.dmg"
        self.assert_old_preserved(self.run_upgrade())
        self.assertEqual(self.events("hdiutil"), [])

    def test_signature_failures_preserve_old_app(self) -> None:
        for failure in ("mounted-signature", "staged-signature"):
            with self.subTest(failure=failure):
                self.assert_old_preserved(self.run_upgrade(failure))
                self.assertEqual(self.events("pkill"), [])
                self.assert_clean()

    def test_replace_failure_restores_old_app(self) -> None:
        self.assert_old_preserved(self.run_upgrade("replace"))
        self.assert_clean()

    def test_launch_failure_restores_old_app(self) -> None:
        self.assert_old_preserved(self.run_upgrade("launch"))
        self.assert_clean()

    def test_backup_rename_failure_preserves_old_app(self) -> None:
        self.assert_old_preserved(self.run_upgrade("backup"))
        self.assert_clean()

    def test_rollback_failure_retains_recovery_copy(self) -> None:
        result = self.run_upgrade("rollback")
        self.assertNotEqual(result.returncode, 0)
        recovery = list(self.app.parent.glob(".xisland-upgrade.*/previous.app/Contents/version"))
        self.assertEqual(len(recovery), 1)
        self.assertEqual(recovery[0].read_text(), "old")
        self.assertIn(str(recovery[0].parent.parent), result.stderr)
        self.assertEqual(list(self.root.joinpath("tmp").iterdir()), [])

    def test_first_install_and_failed_first_launch(self) -> None:
        shutil.rmtree(self.app)
        result = self.run_upgrade("launch")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.app.exists())
        self.assert_clean()
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.app.joinpath("Contents/version").read_text(), "new")
        self.assert_clean()

    def test_target_path_shell_characters_remain_literal(self) -> None:
        quoted_path = self.app.parent / "X Island's $literal `name`.app"
        self.app.rename(quoted_path)
        self.app = quoted_path
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.app.joinpath("Contents/version").read_text(), "new")
        self.assertEqual(self.events("open")[-1], [str(self.app)])
        self.assert_clean()

    def test_mount_failure_cleans_partial_mount_location(self) -> None:
        self.assert_old_preserved(self.run_upgrade("mount"))
        self.assertEqual(self.events("pkill"), [])
        self.assert_clean()

    def test_detach_failure_retains_mount_for_recovery(self) -> None:
        result = self.run_upgrade("detach")
        self.assert_old_preserved(result)
        self.assertEqual(self.events("pkill"), [])
        self.assertIn("temporary files retained", result.stderr)
        self.assertEqual(len(list(self.root.joinpath("tmp").glob("*/mount"))), 1)
        self.assertEqual(list(self.app.parent.glob(".xisland-upgrade.*")), [])

    def test_missing_app_and_download_failure_preserve_old_app(self) -> None:
        for failure in ("missing-app", "download"):
            with self.subTest(failure=failure):
                self.assert_old_preserved(self.run_upgrade(failure))
                self.assertEqual(self.events("pkill"), [])
                self.assert_clean()

    def test_rejects_dangerous_target_paths_before_network(self) -> None:
        for path in ("", "/", "relative.app", str(self.app.parent), str(self.app.parent / ".app"), str(self.app.parent / ".." / "Bad.app")):
            with self.subTest(path=path):
                self.assert_old_preserved(self.run_upgrade(app_path=path))
                self.assertEqual(self.events("gh"), [])

    def test_rejects_symlink_target_before_network(self) -> None:
        link = self.app.parent / "Link.app"
        link.symlink_to(self.app)
        self.assert_old_preserved(self.run_upgrade(app_path=str(link)))
        self.assertEqual(self.events("gh"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
