# Dead as Disco

## What does randomization do to this game?

Nothing in the game itself is shuffled. Playing Arcade mode sends checks to the multiworld, and the
items you get back change your runs: traps that mess with game speed or the screen, buffs, and shields
against DeathLink.

## What are the checks?

- **Wave clears**: waves 1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150 and 200, plus every Nth wave
  if `wave_check_interval` is set. Waves count per run, so "Clear Wave 100" means reaching it in one run.
- **Lifetime kills**: 25, 50, 100 and more enemies defeated, added up across all your Arcade runs.

## What items are there?

- **Gold Record**: collect enough, then clear your goal wave in one run to win.
- **Disco Fever**: enemies slow down for a while; you don't.
- **Mirror Ball Shield**: blocks the next DeathLink that would have killed you.
- **Slow-Mo, Fast-Forward, Molasses and Blackout traps**: change the game's speed, your speed or
  darken the screen for a while. The music keeps playing at normal speed, so expect to fight off-beat.
- **Groovy Vibes**: nothing, just vibes.

Traps and buffs wait until you're in an Arcade run, then fire one at a time.

## DeathLink

When DeathLink is on, each of your deaths has a chance (default 25%) to kill everyone else, and each of
their deaths has a chance (default 40%) to kill you, but only while you're in an Arcade run.
