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

With the v0.3.2 mod and APWorld, queued traps arrive with a random **20–30 seconds of active Arcade play
after the preceding trap ends**. A meteor batch or both car sets count as one trap. Pauses, menus and
between-wave downtime freeze the rest, and reconnecting resumes the saved remainder. Existing
multiworlds work without regeneration. `/disco` shows the remaining rest. Update both parts together;
an older game mod cannot provide this clock, so the new client holds waiting traps and asks for an update.

## Testing

Ctrl+Home in the game shows a status pop-up (and writes a line to `ue4ss\UE4SS.log`), so you can check the
mod is running. In the client window:

- `/disco`: Gold Records, kills, shields, queued effects and remaining trap rest.
- `/testeffect slowmo` (or fastforward, molasses, blackout, fever): try an effect during a run.
- `/testeffect meteor`: try a random batch of **1–5 meteors** while on the ground during Arcade combat.
  They arrive one at a time; dodge each warning, whose target stays where you stood when that meteor launched.
  Requires the updated game mod as well as the updated APWorld.
- `/testeffect car`: send a **single-car probe** during Arcade combat before testing a full car trap.
- `/testeffect cars`: try **two sets of three cars in a sequential X pattern**. Both sets use your starting
  position and facing: the first crosses at 45 degrees left, then the second at 45 degrees right.
  Each set has its own two-second warning and roughly 1.25-second rush. The second waits for the first
  cars and warnings to disappear, then a one-second gap. The single-car probe follows your facing directly.
  Both commands require the updated mod and APWorld and spend no AP item. Faster cars, both earlier parallel
  sets and native player/enemy damage passed live tests. The installed X layout also passed real AP delivery.
- `/testdeathlink`: pretend a friend died. Goes to your slot only, then rolls your receive chance like a real one.
- `/testkill`: die right away. This is a real death, so it can go out to everyone over DeathLink.

The mod also has Ctrl+F5 to F10 test keys for the effects and a kill. They're off by default; set
`TEST_HOTKEYS = true` near the top of `mod/DeadAsDiscoAP/Scripts/main.lua` (and reinstall) to turn them on.

To test queue spacing, use a private test room and have its server console send two trap items, for
example `/send YourSlotName Slow-Mo Trap` twice. Let the first finish, then expect the second after
20–30 seconds of active combat. Pause for ten seconds during that rest: the pause must not shorten it.
Check `/disco`, restart the client during another rest, and confirm the remaining time resumes without
a new roll. Repeat with a meteor batch or car trap to check the rest starts after its final cleanup.
`/testeffect` sends an immediate manual probe and does not exercise the received-item queue.

Meteor Trap is off by default. To include it in a new multiworld, add `"Meteor Trap"` to `enabled_traps`
in your YAML. One item chooses 1–5 meteors once; the batch has its own time limits instead of using
`effect_duration`, and waits through menus, pauses, downtime, and airborne movement. The next meteor waits
for the previous one and its remnant to disappear, with at least 3 seconds of game time between launches.
Pauses stop the batch clock; leaving Arcade cancels the remaining meteors. Other effects wait for the whole
batch, and reconnecting does not spend or replay it again. If an older mod is running, the client keeps the item queued and
shows one update notice. Update the game mod and APWorld together before testing it with friends.

The native attack has base damage of 10 to you and 60 to enemies; normal game modifiers still apply.
Meteor kills use the regular kill checks, and a meteor death uses the normal DeathLink send chance once.
Failure to load/spawn the first meteor retries after 3 seconds, up to 3 attempts; the client reports a skipped
item if all three fail, then continues the queue. Menus, pauses, downtime and airborne movement do not use
these attempts. Once the batch starts, later failed launches may be skipped without replaying the item.

Prophet Car Trap remains experimental in v0.3.1 and is **off by default**. To include it in a new
multiworld, add `"Prophet Car Trap"` to `enabled_traps`. It uses one item for both sets of three and its own
time limits, independent of `effect_duration`. All other effects wait through both sets and the gap between
them. A client restart does not replay an accepted car trap. Older mods keep the car item queued with one
update notice. Startup failures retry after 3 seconds, up to 3 attempts; after acceptance, a later failure
ends the same trap rather than spending another item or restarting both sets.

Cars hurt you and enemies through the native attack, confirmed in live Arcade. Their configured damage
values are 10 for the player and 1000 for enemies; these are not measurements of exact health lost, and
normal game modifiers apply. Kills and deaths go through the regular game hooks, kill checks and normal
DeathLink chance; the car trap adds no separate kill count or DeathLink roll. Routes do not follow you
after the trap starts. The mod does not check the entire route for walls or uneven ground, so test in an
open, flat arena first. Pause and menu/song/death/reconnect transitions still need live checks.
