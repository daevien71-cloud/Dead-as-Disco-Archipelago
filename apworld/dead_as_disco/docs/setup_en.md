# Dead as Disco setup guide

## You need

- Dead as Disco on Steam (Windows, or Linux through Proton).
- [Archipelago](https://github.com/ArchipelagoMW/Archipelago/releases) 0.6.4 or newer.
- The `DeadAsDiscoAP` release zip.

## Install

1. Close Dead as Disco.
2. Extract the release zip anywhere and double-click `Install.bat`. It finds the game through Steam,
   installs UE4SS (the mod loader) if you don't have it, and adds the `DeadAsDiscoAP` mod. If Windows
   says access is denied, right-click `Install.bat` and choose **Run as administrator**.
3. Double-click `dead_as_disco.apworld` (or use **Install APWorld** in the Archipelago Launcher).

To remove it later, run `Uninstall.bat`. Your saves are never touched.

### Linux (Steam + Proton)

1. Close Dead as Disco. If you've never started it on this PC, start it once first so Steam creates its
   Proton prefix.
2. Extract the release zip and run `bash Install-Linux.sh` in a terminal from that folder. It finds the game in
   your Steam libraries (native, Flatpak or Snap Steam), installs UE4SS if needed and adds the mod.
3. In Steam: right-click Dead as Disco > **Properties** > **Launch Options**, and enter
   `WINEDLLOVERRIDES="dwmapi=n,b" %command%`. Without it Proton ignores UE4SS. The installer tells you if
   it's already set.
4. Install `dead_as_disco.apworld` with **Install APWorld** in the Linux Archipelago Launcher (AppImage).

The client finds the game's Proton prefix by itself and says "Talking to the game through ..." when it starts.
To remove the mod: `bash Uninstall-Linux.sh`.

## Update

Close the game, then run `Update.bat` (Windows) or `bash Update-Linux.sh` (Linux) from the mod's folder. It
downloads the latest version (or uses `git pull` if the folder is a git clone), reinstalls the mod and puts the
new `dead_as_disco.apworld` where Archipelago loads it. Restart the Archipelago Launcher afterwards.

## Generate a multiworld

Archipelago's website can't generate games for custom worlds, so whoever generates the multiworld
needs `dead_as_disco.apworld` installed and runs **Generate** in the Archipelago Launcher with
everyone's YAML files. The resulting `.zip` can then be hosted on archipelago.gg (**Host Game**) or
locally. Your friends' games don't need anything extra.

## Play

1. Start Dead as Disco.
2. In the Archipelago Launcher, open **Dead as Disco Client** and connect to the room. It says
   "Dead as Disco detected." once it can see the game.
3. Play **Arcade**. Checks, item messages and DeathLink rolls show up in the client window.
   Type `/disco` there to see your Gold Records, kills and queued traps.

Keep the client open while you play: kills only count while it's running.

## Testing

Ctrl+F11 in the game shows a status pop-up (and writes a line to `ue4ss\UE4SS.log`), so you can check the
mod is running. In the client window:

- `/disco`: Gold Records, kills, shields and queued effects.
- `/testeffect slowmo` (or fastforward, molasses, blackout, fever): try an effect during a run.
- `/testdeathlink`: pretend a friend died. Goes to your slot only, then rolls your receive chance like a real one.
- `/testkill`: die right away. This is a real death, so it can go out to everyone over DeathLink.

The mod also has Ctrl+F5 to F10 test keys for the effects and a kill. They're off by default; set
`TEST_HOTKEYS = true` near the top of `mod/DeadAsDiscoAP/Scripts/main.lua` (and reinstall) to turn them on.
