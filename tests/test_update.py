"""Tests both updaters: an older copy of the mod updates itself from a GitHub-style zip of this repo,
reinstalls into a fake game folder and drops the .apworld into a fake Archipelago folder.

Run: python tests/test_update.py   (the PowerShell test runs on Windows only)
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COPY = ["install", "mod", "third_party", "dead_as_disco.apworld", "Install-Linux.sh", "Update-Linux.sh",
        "Install.bat", "Update.bat"]


def tracked_files() -> list[str]:
    # Include newly added source files so a new module is tested before its first commit too.
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--cached", "--others", "--exclude-standard"],
                         capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if not line.startswith("baseline/")]


def github_zip(target: Path) -> Path:
    """What GitHub's "Download ZIP" gives: every file under one top-level folder."""
    with zipfile.ZipFile(target, "w") as archive:
        for name in tracked_files():
            archive.write(ROOT / name, f"test-claude-branch/{name}")
    return target


def old_copy(base: Path) -> Path:
    """An installed copy that's one version behind (main.lua differs, no git checkout)."""
    old = base / "old"
    for name in COPY:
        source = ROOT / name
        if source.is_dir():
            shutil.copytree(source, old / name, ignore=shutil.ignore_patterns("__pycache__"))
        else:
            old.mkdir(exist_ok=True)
            shutil.copy2(source, old / name)
    main = old / "mod" / "DeadAsDiscoAP" / "Scripts" / "main.lua"
    main.write_text(main.read_text() + "\n-- old version\n")
    return old


class UpdateTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.zip = github_zip(self.base / "latest.zip")
        self.old = old_copy(self.base)
        self.game = self.base / "Dead as Disco"
        self.win64 = self.game / "Pagoda" / "Binaries" / "Win64"
        self.win64.mkdir(parents=True)
        (self.win64 / "PagodaSteam-Win64-Shipping.exe").write_text("x")

    def check_updated(self, output: str, worlds: Path) -> None:
        self.assertIn("Updated!", output)
        for script in ("main.lua", "meteor.lua"):
            installed = (self.win64 / "ue4ss" / "Mods" / "DeadAsDiscoAP" / "Scripts" / script).read_bytes()
            self.assertEqual(installed, (ROOT / "mod" / "DeadAsDiscoAP" / "Scripts" / script).read_bytes())
        self.assertEqual((worlds / "dead_as_disco.apworld").read_bytes(), (ROOT / "dead_as_disco.apworld").read_bytes())
        self.assertTrue((self.old / "README.md").exists(), "the folder itself was refreshed")

    def meteor_only_old_copy(self, missing: bool = False) -> None:
        """Leave main.lua and the APWorld identical; only the meteor module needs updating."""
        scripts = Path("mod") / "DeadAsDiscoAP" / "Scripts"
        shutil.copy2(ROOT / scripts / "main.lua", self.old / scripts / "main.lua")
        meteor = self.old / scripts / "meteor.lua"
        if missing:
            meteor.unlink()  # releases before 0.2.0 did not ship this module
        else:
            meteor.write_bytes(meteor.read_bytes() + b"\n-- older meteor tuning\n")

    def check_linux_update(self) -> None:
        home = self.base / "home"
        worlds = home / ".local" / "share" / "Archipelago" / "worlds"
        worlds.mkdir(parents=True)
        env = dict(os.environ, HOME=str(home), USERPROFILE=str(home), XDG_DATA_HOME=str(home / ".local" / "share"))
        run = lambda: subprocess.run(
            [sys.executable, str(self.old / "install" / "update_linux.py"), "--source-zip", str(self.zip),
             "--game-dir", str(self.game)], env=env, capture_output=True, text=True)
        result = run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.check_updated(result.stdout, worlds)
        again = run()
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn("Already up to date.", again.stdout, again.stdout + again.stderr)

    def check_windows_update(self) -> None:
        archipelago = self.base / "Archipelago"
        (archipelago / "custom_worlds").mkdir(parents=True)
        env = dict(os.environ, LOCALAPPDATA=str(self.base / "local_appdata"))
        run = lambda: subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(self.old / "install" / "Update-DeadAsDiscoAP.ps1"), "-SourceZip", str(self.zip),
             "-GameDir", str(self.game), "-ArchipelagoDir", str(archipelago)], env=env,
            capture_output=True, text=True)
        result = run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.check_updated(result.stdout, archipelago / "custom_worlds")
        again = run()
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn("Already up to date.", again.stdout, again.stdout + again.stderr)

    def test_linux(self) -> None:
        self.check_linux_update()

    def test_linux_meteor_only_change(self) -> None:
        self.meteor_only_old_copy()
        self.check_linux_update()

    def test_linux_adds_missing_meteor(self) -> None:
        self.meteor_only_old_copy(missing=True)
        self.check_linux_update()

    @unittest.skipUnless(sys.platform == "win32", "PowerShell updater")
    def test_windows(self) -> None:
        self.check_windows_update()

    @unittest.skipUnless(sys.platform == "win32", "PowerShell updater")
    def test_windows_meteor_only_change(self) -> None:
        self.meteor_only_old_copy()
        self.check_windows_update()

    @unittest.skipUnless(sys.platform == "win32", "PowerShell updater")
    def test_windows_adds_missing_meteor(self) -> None:
        self.meteor_only_old_copy(missing=True)
        self.check_windows_update()


if __name__ == "__main__":
    unittest.main()
