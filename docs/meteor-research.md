# Aurora meteor trap: evidence and playtest notes

Research date: 2026-10-19. This trap reuses the game's falling meteor and its landed, strikeable remnant. It does not activate Aurora's full boss attack or introduce a general hazard framework. Cars remain outside this work.

## What is verified

| Evidence | Result |
| --- | --- |
| Offline Blueprint inspection | Target endpoint setup, ground indicator, impact damage, remnant creation, ordinary-enemy launch fallback, and timed expiry are present in native game behavior. |
| First live Arcade probe, 2026-10-19 | A meteor with no owner/instigator spawned, landed, and created the exact native remnant captured by the spawn hook. The player confirmed seeing it land. |
| Flight and warning | Height 3000 / speed 1500 initially landed in about 0.53 seconds. Disabling initial beat warping increased this to **1.98 seconds**; the player confirmed the native warning was readable. |
| Native impact damage | Three ordinary enemies each lost **60 HP (90 → 30)** through `ApplyImpact` and native `ProcessSimpleHit`. Reflected defaults were `DamageToPlayer = 10`, `DamageToEnemies = 60`. |
| Player interaction | The player struck/kicked the remnant and subsequently confirmed hitting NPCs. Native launch behavior is retained. |
| Remnant timer | The scoped native timer changed from about **4.56 to 11 seconds**. Decoded dissolve timing implies an approximately **8.25-second** strike window; that precise window has not been measured separately. |
| Player damage | Native `ApplyImpact` included the actual controlled Charlie pawn, and native `ProcessSimpleHit` reduced its health **100 → 90** before any experimental fallback ran. Native player damage is **10 HP**; no player-damage or selection adapter is needed. |
| Production integration, single meteor | A real AP server → client → installed-game run passed: one `effect_start`, one `effect_end` (`native_finished`), and persisted `effects_done = 1`. The player saw text and may have dodged; this adds no damage verification. |
| Random batch extension | Each Meteor Trap now chooses **1–5 sequential meteors**. This extension and its transition/queue checks are **not yet live-verified**. The earlier production pass exercised one meteor. |

The trap is opt-in. See the [player test guide](meteor.md) for batch count/pacing, current-pawn targeting, pause, downtime, transitions, death and reconnect checks.

## Native actors and deferred spawning

The relevant classes are:

- Falling actor: `/Game/Pagoda/Characters/Enemies/Doll/UniqueMechanics/BP_BigDoll_Meteor.BP_BigDoll_Meteor_C`.
- Landed actor: `/Game/Pagoda/Characters/Enemies/Doll/UniqueMechanics/BP_Destructable_BigDoll_Meteor.BP_Destructable_BigDoll_Meteor_C`.
- Falling parent: `/Game/LevelPrototyping/Prototype_Blueprints/Doll_FallingObject/BP_FallingObject.BP_FallingObject_C`.
- Warning actor: `/Game/Pagoda/Common/BP_GroundImpactIndicator.BP_GroundImpactIndicator_C`, used by the inherited projectile ground-indicator component.

Decoded `GA_Enemy_BigDoll_Meteors` uses this sequence:

1. `BeginDeferredActorSpawnFromClass(worldContext, meteorClass, transform, 3, bossOwner, 1)`.
2. Set `TargetLocation` to the landing point, `InitialSpeed` to 12000, and `Instigator` to the boss pawn.
3. `FinishSpawningActor(actor, transform, 1)`.

The trap adapts the location and speed, and the initial live probe successfully omitted owner/instigator. These properties must be set before finishing: `BP_BigDoll_Meteor` BeginPlay sets the projectile endpoint and rotation, then its parent sets launch speed and starts the projectile. The native boss's placement and speed are evidence, not suitable defaults for every Arcade arena.

Collision value 3 is `AdjustIfPossibleButDontSpawnIfColliding`; a blocked spawn can return no actor. Deferred construction and the six-argument contract were checked against the installed UE5.7 `GameplayStatics.h:67-71`, and the collision enum against `EngineTypes.h:4169`. See Epic's [spawn API](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UGameplayStatics) and [collision strategies](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/ESpawnActorCollisionHandlingMeth-).

The full boss ability also touches camera framing, boss phases, EQS and NPC spawners. Reusing its projectile avoids those dependencies.

## Damage and player interaction

`BP_FallingObject:ApplyImpact` processes the actors affected by the projectile explosion. `HitCharacters` skips already knocked-down targets, chooses enemy/player damage using the `AIGroup` tag, and invokes the game's hit subsystem with `GE_Damage_SetByCaller` and `SetByCaller.Damage`.

Live tracing proved the original native impact damages both the actual player (10 HP) and ordinary enemies (60 HP). All experimental filter and player-hit hooks were removed. The final implementation leaves native target filtering, damage, hit-state rules, owner and instigator unchanged.

The apparent player exclusion came from inspecting a stale Charlie actor returned by a class-wide lookup. Native impact had already hit the actual controlled pawn. Actor validity alone does not establish that it is the player: resolve the current pawn with `GameplayStatics:GetPlayerPawn(worldContext, 0)` and require it to match the current run/world. A subsequent native-only probe placed the actual player approximately 320 units from an impact with radius 200; that miss was consistent with the geometry. Pawn replacement across transitions remains a manual check.

Two discarded diagnostics complicated the investigation. A direct native-filter construction call crashed the game, and chaining returned target-data/filter structs through Lua produced an invalid zero-count result. This UE4SS revision's [ordinary struct returns](https://github.com/UE4SS-RE/RE-UE4SS/blob/5e627997bf265ae6fc89d23357543d8c8ac05a6f/UE4SS/src/LuaType/LuaUObject.cpp#L312) become tables of reflected fields, losing these handles' opaque native storage. Neither experiment is part of the final implementation; their results do not establish a native player-filter defect.

On impact, `BP_BigDoll_Meteor` itself creates the landed actor at the impact point plus 40 vertical units, with no owner. The landed actor settles on the ground and retains its native hit listeners, effects and abilities. Its `HandleActorHit` supports ordinary characters; the boss branch only adds special reaction tags.

`GA_Launch_BigDollMeteor:TrySelectCustomTarget` prefers Aurora's boss actors. When they are absent, its parent `GA_Launch_DestructibleObject` uses ordinary cone targeting based on the attacker's actor yaw. It excludes dead, knocked-down and invalid targets. If no endpoint is selected, it uses the attacker's forward direction and configured range. Live kicks hit NPCs, so this native targeting remains unchanged; facing the arena edge can still send a remnant out of the arena.

## Scoped ownership and timing hooks

The landed actor has no native owner link to the falling actor. Track its exact creation through a native post-hook on:

`/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass`

For the installed UE4SS build, the post-hook arguments are:

```lua
function(Context, ReturnValue, WorldContextObject, ActorClass,
         SpawnTransform, CollisionHandlingOverride, Owner, TransformScaleMethod)
```

Accept a child only when `WorldContextObject:get()` is an exact tracked trap meteor and `ActorClass:get()` is the exact remnant class. Read `ReturnValue:get()` and leave the original result unchanged. This avoids class-wide actor scans and avoids touching meteors from the boss encounter. The return value is the **second** argument, not the last one, as verified in [matching UE4SS source](https://github.com/UE4SS-RE/RE-UE4SS/blob/5e627997bf265ae6fc89d23357543d8c8ac05a6f/UE4SS/src/Mod/LuaMod.cpp#L329).

For flight, native `ProjectileMovementComponent:SetBeatWarpingEnabled(bool)` is confirmed by a decoded game call. Turning it off on the falling actor produced the measured 1.98-second flight. The remnant's launch retains its native beat settings.

Remnant expiry belongs to `GA_ExplodeAfterTime_BigDollMeteor`, whose parent `GA_ExplodeAfterTime_Base` computes:

```text
ExplodeGameSyncTime = music sync time + time to next beat
                     + BeatsWaitBeforeExplosion * beat duration
```

The child starts its dissolve and becomes an invalid target after about 75% of this lifetime. Extending actor `SetLifeSpan` alone cannot postpone that ability. The precise native pre-hook for a timer adjustment is:

```lua
RegisterHook("/Script/Pagoda.PagodaUtilsFunctionLibrary:DelayUntilTimelinePos",
    function(Context, WorldContextObject, TimelinePos, LatentInfo, LastBool)
        -- Observe or adjust only the exact expiry ability of a tracked remnant.
    end)
```

This pre-hook has no return-value argument. `TimelinePos:set(deadline)` changes the input; update that ability's `ExplodeGameSyncTime` to the same deadline before native scheduling. Leave the latent information and final bool unchanged. The adapter extends the ability's own music-sync deadline to at least 11 seconds from activation; its live readback confirmed this change. The [matching parameter-wrapper implementation](https://github.com/UE4SS-RE/RE-UE4SS/blob/5e627997bf265ae6fc89d23357543d8c8ac05a6f/UE4SS/src/LuaType/LuaUObject.cpp#L2338) supports `get()`/`set()`; [hook documentation](https://docs.ue4ss.com/dev/lua-api/global-functions/registerhook.html) explains native pre/post registration.

Each native meteor keeps its 11-second remnant timer and a 16-second game-time cap from launch. Ownership tracking covers only its exact falling and landed actors. Native expiry listens for major transitions, but the inspected falling projectile's Blueprint transition handler is empty, so explicit cleanup remains necessary.

The batch extension chooses an integer count from 1–5 once per AP trap. Meteors run strictly sequentially: launch only after the previous meteor/remnant is gone, at least three game seconds after its launch, and during active grounded Arcade combat. The batch cap is `count * 20 + 10` game seconds. Later failed spawns skip that meteor. One AP item is consumed on the first meteor's start; reconnect must not replay a partially completed batch. Run exit destroys the active meteor and aborts all remaining launches. Pausing stops the game-time budgets. These new batch semantics still need live verification.

Ground readiness reads `CharacterMovement.MovementMode` as 1 (Walking) or 2 (NavWalking), with a valid `UpdatedComponent`. This matches Epic's `CharacterMovementComponent.cpp:3766-3769`; enum values are in `EngineTypes.h:1006-1019`. The reflected navigation query returned false during a live Walking probe, so the adapter reads these fields directly. Received AP items wait for readiness. Manual `/testeffect meteor` requests outside a run or while an effect is active are refused rather than queued.

## Remaining manual checks

Run **`/testeffect meteor`** in the updated Dead as Disco client during active Arcade combat, then follow the [player guide](meteor.md). Repeat the real AP delivery test for the random batch: verify one item consumption, chosen count, no overlap, spacing and both per-meteor/batch caps. Also check current-pawn targeting, pause/resume, menu/song transitions, cramped arenas, death, reconnect and two queued AP batches. The earlier single-meteor production pass does not establish these new behaviors.

## Local research provenance

The separate local `meteor-research` folder contains inspection scripts, input hashes and `RESEARCH.md`, `TIMING.md`, and `FILTERS.md`. The initial 13 packages yielded 85 complete, byte-for-byte-roundtripped Blueprint functions using retoc v0.1.5 and UAssetAPI v1.1.0. Follow-up inspection of `GA_AttackBase` confirmed the team-mask operation and optional tag structure; its oversized ubergraph was skipped at the parser safety cap. The parser used source-checked version compatibility and only bypassed property parsing after proving an empty section; native property schemas were not invented.

The local production delivery evidence is `playtest/live-meteor-20261019-115052-UTC-d538ea/result.json` and its accompanying logs. Its scope is real AP delivery, installed-mod acknowledgements and saved consumption for the single-meteor version; gameplay observation and the later random-batch extension are separate.

Installed UE4SS identifies commit `5e627997bf265ae6fc89d23357543d8c8ac05a6f`; downloaded reference source was checked against Git blob hashes. Offline inspection established code paths, not runtime performance or complete default values. Proprietary game assets, dumps and binaries are intentionally absent from this repository.
