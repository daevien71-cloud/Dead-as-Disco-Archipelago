#!/usr/bin/env python3
"""Installs the Dead as Disco Archipelago mod on Linux (Steam + Proton).

Run from the release folder:  ./Install-Linux.sh   (or: python3 install/install_linux.py)
Close the game first. Game saves are never touched.
Use --uninstall to remove the mod (and UE4SS, if this script installed it and no other mods use it).
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

MOD_NAME = "DeadAsDiscoAP"
APP_ID = "3404260"
UE4SS_ZIP = "third_party/UE4SS_v3.0.1-1164-g5e627997.zip"
# Inside the Proton prefix, as the game sees it.
BRIDGE_DIR_IN_GAME = "C:\\users\\steamuser\\AppData\\Local\\DeadAsDiscoAP"
LAUNCH_OPTION = 'WINEDLLOVERRIDES="dwmapi=n,b" %command%'
STOCK_MODS = ["CheatManagerEnablerMod", "ConsoleCommandsMod", "ConsoleEnablerMod", "SplitScreenMod",
              "LineTraceMod", "BPML_GenericFunctions", "BPModLoaderMod", "Keybinds"]
HERE = Path(__file__).resolve().parent


def package_file(relative: str) -> Path:
    for base in (HERE, HERE.parent):
        if (base / relative).exists():
            return base / relative
    sys.exit(f"Could not find {relative} next to this script.")


def steam_roots() -> list[Path]:
    home = Path.home()
    return [home / ".steam" / "steam", home / ".local" / "share" / "Steam",
            home / ".var" / "app" / "com.valvesoftware.Steam" / ".local" / "share" / "Steam",
            home / "snap" / "steam" / "common" / ".local" / "share" / "Steam"]


def steam_libraries() -> list[Path]:
    libraries: list[Path] = []
    for root in steam_roots():
        libraries.append(root)
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if vdf.exists():
            libraries += [Path(p) for p in re.findall(r'"path"\s+"([^"]+)"', vdf.read_text(errors="replace"))]
    seen, unique = set(), []
    for library in libraries:
        key = str(library.resolve())
        if key not in seen and library.exists():
            seen.add(key)
            unique.append(library)
    return unique


def find_game() -> tuple[Path, Path]:
    """(game folder, steam library)."""
    for library in steam_libraries():
        game = library / "steamapps" / "common" / "Dead as Disco"
        if (game / "Pagoda" / "Binaries" / "Win64" / "PagodaSteam-Win64-Shipping.exe").exists():
            return game, library
    sys.exit('Could not find Dead as Disco in your Steam libraries. Pass --game-dir "/path/to/Dead as Disco".')


def library_of(game: Path) -> Path:
    # .../steamapps/common/Dead as Disco -> library root
    return game.parent.parent.parent


def game_running() -> bool:
    try:
        return subprocess.run(["pgrep", "-f", "PagodaSteam-Win64-Shipping"], capture_output=True).returncode == 0
    except FileNotFoundError:
        return False


def set_mods_txt(path: Path, name: str, enabled: int | None) -> None:
    lines = path.read_text().splitlines() if path.exists() else []
    lines = [line for line in lines if line.strip() and not re.match(rf"^\s*{re.escape(name)}\s*:", line)]
    if enabled is not None:
        lines.append(f"{name} : {enabled}")
    path.write_text("\n".join(lines) + "\n")


def launch_option_status() -> str | None:
    """The game's current Steam launch options, if we can read them."""
    for root in steam_roots():
        for config in (root / "userdata").glob("*/config/localconfig.vdf"):
            text = config.read_text(errors="replace")
            start = text.find(f'"{APP_ID}"')
            if start < 0:
                continue
            match = re.search(r'"LaunchOptions"\s+"((?:[^"\\]|\\.)*)"', text[start:start + 4000])
            if match:
                return match.group(1).replace('\\"', '"')
    return None


def install(game: Path) -> None:
    win64 = game / "Pagoda" / "Binaries" / "Win64"
    ue4ss = win64 / "ue4ss"
    mods = ue4ss / "Mods"
    record_path = win64 / "DeadAsDiscoAP-install.json"

    installed_ue4ss = False
    if not (win64 / "dwmapi.dll").exists():
        print(f"Installing UE4SS into {win64}")
        with zipfile.ZipFile(package_file(UE4SS_ZIP)) as archive:
            archive.extractall(win64)
        (mods / "mods.json").unlink(missing_ok=True)
        (mods / "mods.txt").write_text("".join(f"{name} : 0\n" for name in STOCK_MODS))
        installed_ue4ss = True
    elif record_path.exists():
        installed_ue4ss = bool(json.loads(record_path.read_text()).get("installed_ue4ss"))

    target = mods / MOD_NAME
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(package_file(f"mod/{MOD_NAME}"), target)
    (target / "enabled.txt").write_text("")
    (target / "bridge_dir.txt").write_text(BRIDGE_DIR_IN_GAME)
    set_mods_txt(mods / "mods.txt", MOD_NAME, 1)
    record_path.write_text(json.dumps({"installed_ue4ss": installed_ue4ss,
                                       "installed_at": datetime.now(timezone.utc).isoformat()}, indent=1))

    print(f"\nInstalled the Dead as Disco AP mod into {win64}")
    prefix_local = (library_of(game) / "steamapps" / "compatdata" / APP_ID / "pfx" / "drive_c" / "users"
                    / "steamuser" / "AppData" / "Local")
    if prefix_local.is_dir():
        (prefix_local / "DeadAsDiscoAP").mkdir(exist_ok=True)
    else:
        print("\nNote: the game's Proton prefix doesn't exist yet. Start the game once from Steam, then run the "
              "Dead as Disco Client; it finds the prefix on its own.")

    options = launch_option_status()
    if options and "dwmapi=n,b" in options:
        print("\nSteam launch options already load UE4SS.")
    else:
        print("\nOne manual step: in Steam, right-click Dead as Disco > Properties > Launch Options, and enter:\n"
              f"    {LAUNCH_OPTION}\n"
              "Without it, Proton ignores UE4SS and the mod won't load.")
    print("\nThen: start the game, open the Archipelago Launcher, start \"Dead as Disco Client\", connect, play Arcade.")


def uninstall(game: Path) -> None:
    win64 = game / "Pagoda" / "Binaries" / "Win64"
    mods = win64 / "ue4ss" / "Mods"
    record_path = win64 / "DeadAsDiscoAP-install.json"
    record = json.loads(record_path.read_text()) if record_path.exists() else {}
    shutil.rmtree(mods / MOD_NAME, ignore_errors=True)
    if (mods / "mods.txt").exists():
        set_mods_txt(mods / "mods.txt", MOD_NAME, None)
    if record.get("installed_ue4ss"):
        others = [p.name for p in mods.iterdir() if p.is_dir() and p.name not in STOCK_MODS + ["shared"]]
        if others:
            print(f"Left UE4SS in place because other mods use it: {', '.join(others)}")
        else:
            shutil.rmtree(win64 / "ue4ss")
            (win64 / "dwmapi.dll").unlink(missing_ok=True)
            print("Removed UE4SS (this installer had added it).")
    record_path.unlink(missing_ok=True)
    print("Dead as Disco AP mod removed. Your saves were not touched.")
    print(f'You can also remove {LAUNCH_OPTION.split(" %")[0]} from the game\'s Steam launch options.')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--game-dir", type=Path, help='The "Dead as Disco" folder, if it isn\'t found automatically')
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()

    game = args.game_dir or find_game()[0]
    if not (game / "Pagoda" / "Binaries" / "Win64" / "PagodaSteam-Win64-Shipping.exe").exists():
        sys.exit(f"{game} doesn't look like the Dead as Disco folder.")
    if game_running():
        sys.exit("Dead as Disco is running. Close it and run this again.")
    try:
        uninstall(game) if args.uninstall else install(game)
    except PermissionError as exc:
        sys.exit(f"Permission denied: {exc.filename}. Check that you own the Steam library folder.")


if __name__ == "__main__":
    main()
