"""Tests install/install_linux.py against a fake home folder with a fake Steam library.

Run: python tests/test_install_linux.py   (works on Windows too; only paths are faked)
"""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


installer = load("install_linux", ROOT / "install" / "install_linux.py")
bridge = load("dad_bridge", ROOT / "apworld" / "dead_as_disco" / "bridge.py")  # stdlib only


class FakeSteam:
    """~/.local/share/Steam plus a second library on another drive, with the game in the second one."""

    def __init__(self, base: Path, prefix: bool = True, launch_options: str | None = None):
        self.home = base / "home"
        steam = self.home / ".local" / "share" / "Steam"
        self.library = base / "games" / "SteamLibrary"
        (steam / "steamapps").mkdir(parents=True)
        (steam / "steamapps" / "libraryfolders.vdf").write_text(
            f'"libraryfolders"\n{{\n\t"0"\n\t{{\n\t\t"path"\t\t"{steam.as_posix()}"\n\t}}\n'
            f'\t"1"\n\t{{\n\t\t"path"\t\t"{self.library.as_posix()}"\n\t}}\n}}\n')
        self.game = self.library / "steamapps" / "common" / "Dead as Disco"
        self.win64 = self.game / "Pagoda" / "Binaries" / "Win64"
        self.win64.mkdir(parents=True)
        (self.win64 / "PagodaSteam-Win64-Shipping.exe").write_text("x")
        self.local = (self.library / "steamapps" / "compatdata" / "3404260" / "pfx" / "drive_c" / "users"
                      / "steamuser" / "AppData" / "Local")
        if prefix:
            self.local.mkdir(parents=True)
        if launch_options is not None:
            config = steam / "userdata" / "1234" / "config"
            config.mkdir(parents=True)
            escaped = launch_options.replace('"', '\\"')
            (config / "localconfig.vdf").write_text(
                f'"UserLocalConfigStore"\n{{\n"apps"\n{{\n"3404260"\n{{\n"LastPlayed"\t"1"\n'
                f'"LaunchOptions"\t"{escaped}"\n}}\n}}\n}}\n')


class InstallLinuxTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)

    def run_in(self, steam: FakeSteam, *args: str) -> str:
        output: list[str] = []
        with mock.patch("pathlib.Path.home", return_value=steam.home), \
                mock.patch.object(installer, "game_running", return_value=False), \
                mock.patch("sys.argv", ["install_linux.py", *args]), \
                mock.patch("builtins.print", lambda *a, **k: output.append(" ".join(map(str, a)))):
            installer.main()
        return "\n".join(output)

    def test_install_and_uninstall(self) -> None:
        steam = FakeSteam(self.base)
        out = self.run_in(steam)
        mod = steam.win64 / "ue4ss" / "Mods" / "DeadAsDiscoAP"
        self.assertTrue((steam.win64 / "dwmapi.dll").exists())
        self.assertTrue((mod / "Scripts" / "main.lua").exists())
        self.assertEqual((mod / "bridge_dir.txt").read_text(), "C:\\users\\steamuser\\AppData\\Local\\DeadAsDiscoAP")
        mods_txt = (steam.win64 / "ue4ss" / "Mods" / "mods.txt").read_text()
        self.assertIn("DeadAsDiscoAP : 1", mods_txt)
        self.assertIn("Keybinds : 0", mods_txt)
        self.assertFalse((steam.win64 / "ue4ss" / "Mods" / "mods.json").exists())
        self.assertTrue((steam.local / "DeadAsDiscoAP").is_dir())
        self.assertIn('WINEDLLOVERRIDES="dwmapi=n,b" %command%', out)

        self.run_in(steam)  # reinstall over the top
        self.assertTrue(json.loads((steam.win64 / "DeadAsDiscoAP-install.json").read_text())["installed_ue4ss"])

        self.run_in(steam, "--uninstall")
        self.assertFalse((steam.win64 / "ue4ss").exists())
        self.assertFalse((steam.win64 / "dwmapi.dll").exists())
        self.assertTrue((steam.win64 / "PagodaSteam-Win64-Shipping.exe").exists())

    def test_existing_ue4ss_is_kept(self) -> None:
        steam = FakeSteam(self.base)
        (steam.win64 / "dwmapi.dll").write_text("theirs")
        other = steam.win64 / "ue4ss" / "Mods" / "SomeoneElsesMod"
        other.mkdir(parents=True)
        (steam.win64 / "ue4ss" / "Mods" / "mods.txt").write_text("SomeoneElsesMod : 1\n")
        self.run_in(steam)
        self.assertEqual((steam.win64 / "dwmapi.dll").read_text(), "theirs")
        self.assertEqual((steam.win64 / "ue4ss" / "Mods" / "mods.txt").read_text(),
                         "SomeoneElsesMod : 1\nDeadAsDiscoAP : 1\n")
        self.run_in(steam, "--uninstall")
        self.assertEqual((steam.win64 / "dwmapi.dll").read_text(), "theirs")
        self.assertTrue(other.exists())
        self.assertEqual((steam.win64 / "ue4ss" / "Mods" / "mods.txt").read_text(), "SomeoneElsesMod : 1\n")

    def test_launch_option_already_set(self) -> None:
        steam = FakeSteam(self.base, launch_options='WINEDLLOVERRIDES="dwmapi=n,b" %command%')
        out = self.run_in(steam)
        self.assertIn("already load UE4SS", out)

    def test_no_prefix_yet(self) -> None:
        steam = FakeSteam(self.base, prefix=False)
        out = self.run_in(steam)
        self.assertIn("Proton prefix doesn't exist yet", out)

    def test_client_finds_the_prefix(self) -> None:
        steam = FakeSteam(self.base)
        with mock.patch("pathlib.Path.home", return_value=steam.home), mock.patch.object(sys, "platform", "linux"):
            self.assertEqual(bridge.default_bridge_dir(), steam.local / "DeadAsDiscoAP")

    def test_client_fallback_without_prefix(self) -> None:
        steam = FakeSteam(self.base, prefix=False)
        with mock.patch("pathlib.Path.home", return_value=steam.home), mock.patch.object(sys, "platform", "linux"):
            self.assertEqual(bridge.default_bridge_dir(), steam.home / ".local" / "share" / "DeadAsDiscoAP")


if __name__ == "__main__":
    unittest.main()
