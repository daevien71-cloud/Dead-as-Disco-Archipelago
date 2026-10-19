#!/usr/bin/env python3
"""Updates the Dead as Disco Archipelago mod on Linux: fetches the latest version, reinstalls the mod and
installs the new .apworld into Archipelago. Run through Update-Linux.sh. Close the game first.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
FINGERPRINT_FILES = ["dead_as_disco.apworld", "mod/DeadAsDiscoAP/Scripts/main.lua",
                     "mod/DeadAsDiscoAP/Scripts/meteor.lua"]


def fingerprint() -> list[str]:
    return [hashlib.sha256((ROOT / f).read_bytes()).hexdigest() if (ROOT / f).exists() else "" for f in FINGERPRINT_FILES]


def archipelago_worlds(override: Path | None) -> Path | None:
    """Where the Archipelago AppImage loads custom worlds from (its user folder's "worlds")."""
    data_home = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    candidates = [override / "worlds", override / "custom_worlds"] if override else []
    candidates += [data_home / "Archipelago" / "worlds", Path.home() / "Archipelago" / "worlds"]
    return next((c for c in candidates if c.is_dir()), None)


def download(url: str, target: Path) -> None:
    print(f"Downloading {url}")
    try:
        with urllib.request.urlopen(url, timeout=60) as response, target.open("wb") as out:
            shutil.copyfileobj(response, out)
    except urllib.error.URLError as exc:
        sys.exit(f"Download failed ({exc}). If the GitHub repo is private, the download needs it to be public, "
                 "or update with git instead (git clone, then run Update-Linux.sh inside that folder).")


def refresh_from_zip(zip_path: Path) -> None:
    with tempfile.TemporaryDirectory() as temp:
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(temp)
        found = next(Path(temp).rglob("install_linux.py"), None)
        if not found:
            sys.exit("The download does not look like the Dead as Disco AP mod.")
        new_root = found.parent.parent
        shutil.copytree(new_root, ROOT, dirs_exist_ok=True)
    for script in ["Install-Linux.sh", "Uninstall-Linux.sh", "Update-Linux.sh",
                   "install/install_linux.py", "install/update_linux.py"]:
        if (ROOT / script).exists():
            (ROOT / script).chmod(0o755)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source-zip", type=Path, help="Use this zip instead of downloading (for testing)")
    parser.add_argument("--game-dir", type=Path)
    parser.add_argument("--archipelago-dir", type=Path, help="Archipelago's user folder, if not the default")
    args = parser.parse_args()

    before = fingerprint()
    if not args.source_zip and (ROOT / ".git").exists():
        print("Updating with git...")
        if subprocess.run(["git", "-C", str(ROOT), "pull", "--ff-only"]).returncode != 0:
            sys.exit("git pull failed; see the message above.")
    else:
        source = json.loads((HERE / "update_source.json").read_text())
        with tempfile.TemporaryDirectory() as temp:
            zip_path = args.source_zip
            if not zip_path:
                zip_path = Path(temp) / "latest.zip"
                download(f"https://github.com/{source['repo']}/archive/refs/heads/{source['branch']}.zip", zip_path)
            refresh_from_zip(zip_path)

    # Run the freshly downloaded installer, not this (possibly older) process's copy.
    install = [sys.executable, str(ROOT / "install" / "install_linux.py")]
    if args.game_dir:
        install += ["--game-dir", str(args.game_dir)]
    if subprocess.run(install).returncode != 0:
        sys.exit("Installing the mod failed; see the message above.")

    worlds = archipelago_worlds(args.archipelago_dir)
    if worlds:
        shutil.copy2(ROOT / "dead_as_disco.apworld", worlds / "dead_as_disco.apworld")
        print(f"Installed dead_as_disco.apworld into {worlds}")
    else:
        print('Could not find Archipelago. Give dead_as_disco.apworld to its Launcher with "Install APWorld".')

    print("\nAlready up to date." if fingerprint() == before else
          "\nUpdated! Restart the Archipelago Launcher / Dead as Disco Client to use the new version.")


if __name__ == "__main__":
    main()
