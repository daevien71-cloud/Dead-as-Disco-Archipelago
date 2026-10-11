"""Build dist/dead_as_disco.apworld and the release zip.

Usage: python build.py
"""

import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).parent
DIST = ROOT / "dist"
WORLD = ROOT / "apworld" / "dead_as_disco"
VERSION = json.loads((WORLD / "archipelago.json").read_text())["world_version"]
RELEASE_FILES = [
    "README.md",
    "Install.bat",
    "Uninstall.bat",
    "Dead as Disco.yaml",
    "install/Install-DeadAsDiscoAP.ps1",
    "mod/DeadAsDiscoAP/Scripts/main.lua",
    "mod/DeadAsDiscoAP/Scripts/json.lua",
    "third_party/UE4SS_v3.0.1-1164-g5e627997.zip",
    "third_party/README.md",
]


def build_apworld() -> Path:
    target = DIST / "dead_as_disco.apworld"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(WORLD.rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts:
                archive.write(path, Path("dead_as_disco") / path.relative_to(WORLD))
    return target


def build_release(apworld: Path) -> Path:
    name = f"DeadAsDiscoAP-v{VERSION}"
    target = DIST / f"{name}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(apworld, f"{name}/dead_as_disco.apworld")
        for relative in RELEASE_FILES:
            archive.write(ROOT / relative, f"{name}/{relative}")
    return target


if __name__ == "__main__":
    shutil.rmtree(DIST, ignore_errors=True)
    DIST.mkdir()
    apworld = build_apworld()
    release = build_release(apworld)
    print(f"Built {apworld.relative_to(ROOT)} and {release.relative_to(ROOT)}")
