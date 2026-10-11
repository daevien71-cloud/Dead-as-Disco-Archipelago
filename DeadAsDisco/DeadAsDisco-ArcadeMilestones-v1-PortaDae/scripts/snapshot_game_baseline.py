"""Copy closed-game saves/config/accepted mods; never edit game files."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Dead as Disco")
SAVED = Path(r"C:\Users\sip22\AppData\Local\Pagoda\Saved")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = ROOT / "runtime" / "game-baselines" / stamp
    target.mkdir(parents=True, exist_ok=False)
    rows = []
    for name in ("SaveGames", "SaveGamesBackup", "Config"):
        source = SAVED / name
        if not source.exists():
            continue
        for path in sorted(source.rglob("*")):
            if path.is_symlink() or path.is_junction():
                raise RuntimeError("Refusing reparse point in backup source")
            if not path.is_file():
                continue
            relative = path.relative_to(SAVED)
            backup = target / "Saved" / relative
            backup.parent.mkdir(parents=True, exist_ok=True)
            before = digest(path)
            shutil.copy2(path, backup)
            after = digest(path)
            if before != after or digest(backup) != before:
                raise RuntimeError(f"Source changed during backup: {relative}")
            rows.append({"source": str(path), "backup": str(backup), "bytes": path.stat().st_size,
                         "sha256": before, "kind": "save_or_config"})
    mods = GAME / "Pagoda" / "Content" / "Paks" / "~mods"
    for path in sorted(mods.rglob("*")):
        if path.is_symlink() or path.is_junction():
            raise RuntimeError("Refusing reparse point in accepted mods")
        if path.is_file():
            before = digest(path)
            backup = target / "AcceptedMods" / path.relative_to(mods)
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, backup)
            if digest(path) != before or digest(backup) != before:
                raise RuntimeError("Accepted mod changed during backup")
            rows.append({"source": str(path), "bytes": path.stat().st_size,
                         "backup": str(backup), "sha256": before,
                         "kind": "accepted_mod_readonly_hash"})
    exe = GAME / "Pagoda" / "Binaries" / "Win64" / "PagodaSteam-Win64-Shipping.exe"
    rows.append({"source": str(exe), "bytes": exe.stat().st_size,
                 "sha256": digest(exe), "kind": "game_executable_readonly_hash"})
    for path in sorted((exe.parent).iterdir()):
        if path.is_file():
            rows.append({"source": str(path), "bytes": path.stat().st_size,
                         "sha256": digest(path), "kind": "win64_initial_file"})
    manifest = {"created_utc": datetime.now(timezone.utc).isoformat(),
                "backup_root": str(target), "entries": rows,
                "save_contents_inspected": False, "game_files_modified": False}
    (target / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    summary = {"backup_root": str(target), "manifest": str(target / "manifest.json"),
               "saved_config_files_backed_up": sum(r["kind"] == "save_or_config" for r in rows),
               "accepted_mod_files_hashed": sum(r["kind"] == "accepted_mod_readonly_hash" for r in rows)}
    (ROOT / "evidence" / "game-baseline-latest.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
