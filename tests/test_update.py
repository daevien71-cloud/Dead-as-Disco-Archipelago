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
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=True).stdout
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
        installed = (self.win64 / "ue4ss" / "Mods" / "DeadAsDiscoAP" / "Scripts" / "main.lua").read_bytes()
        self.assertEqual(installed, (ROOT / "mod" / "DeadAsDiscoAP" / "Scripts" / "main.lua").read_bytes())
        self.assertEqual((worlds / "dead_as_disco.apworld").read_bytes(), (ROOT / "dead_as_disco.apworld").read_bytes())
        self.assertTrue((self.old / "README.md").exists(), "the folder itself was refreshed")

    def test_linux(self) -> None:
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
        self.assertIn("Already up to date.", again.stdout, again.stdout + again.stderr)

    @unittest.skipUnless(sys.platform == "win32", "PowerShell updater")
    def test_windows(self) -> None:
        archipelago = self.base / "Archipelago"
        (archipelago / "custom_worlds").mkdir(parents=True)
        run = lambda: subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(self.old / "install" / "Update-DeadAsDiscoAP.ps1"), "-SourceZip", str(self.zip),
             "-GameDir", str(self.game), "-ArchipelagoDir", str(archipelago)], capture_output=True, text=True)
        result = run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.check_updated(result.stdout, archipelago / "custom_worlds")
        again = run()
        self.assertIn("Already up to date.", again.stdout, again.stdout + again.stderr)


if __name__ == "__main__":
    unittest.main()
