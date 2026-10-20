# Prophet cars: native evidence and candidate design

Status: **warnings, both sets, faster movement, player/enemy damage and cleanup verified in live Arcade**, 2026-10-19. The final X pattern also passed real AP delivery in the normal installed build, with the owner's visual confirmation. Broad arena and transition checks remain. See [the staged playtest guide](cars.md).

## Native contracts

The spawn classes are:

```text
/Game/LevelPrototyping/Prototype_Blueprints/BP_Prophet_Highway_Car.BP_Prophet_Highway_Car_C
/Game/LevelPrototyping/Prototype_Blueprints/BP_CarWarningIndicator.BP_CarWarningIndicator_C
```

The car inherits `BP_MovingHazard_Base`, then `BP_ObjectsMoving`, then Actor. It accepts an optional `BP_WarningIndicator` reference; `SetWarning(bIsOn,bIsNearHit)` updates that indicator. Its optional lane manager would randomly select lanes and reposition the car, so the candidate assigns warnings directly and leaves the manager unset. The boss's `GA_Enemy_Prophet_CarHazards` activates preplaced, tagged cars; spawning the native cars directly avoids that level dependency.

| Decoded behavior | Consequence for the adapter |
| --- | --- |
| BeginPlay waits 0.2 game seconds, captures `Train.RelativeLocation` as `StartLocation`, then sets `LevelLoaded=true`. | Configure placement before that capture; wait for readiness before starting. |
| Tick adds `Vector * Speed * DeltaSeconds` to the `Train` component only while `LevelLoaded && IsMoveActive`. | Preserve native movement; use positive local X and actor yaw to select routes. |
| At `LoopDistance`, it loops or stops depending on `ShouldLoop` and `ResetPositionOnEnd?`. It does not destroy itself. | Disable looping/reset and explicitly destroy owned cars and indicators. |
| `StartCar()` clears hit collections, unhides the car and starts movement, unless boss-finisher state blocks it. | Start the native lifecycle after the warning. |
| `DisableCollision()` disables both collision components; `StartCar()` does not restore them. | Preserve authored component settings and disable actor-level collision during the warning. |
| Positional warning updates run even while stopped. `HandleLooped()` resets their flags. | Suppress positional updates with `bPassedWarningEnd=true` while controlling warning timing. |

The adapter snapshots the controlled pawn's grounded position and facing once. Three parallel routes at facing minus 45° form the first diagonal; three at facing plus 45° form the second, crossing at the same original center. Moving or turning does not retarget set two. A manual single-car probe keeps the original facing. Lane width comes from runtime native bounds. It uses three native cars and three native warnings, then destroys all six before allowing the next set. Native loops are disabled. The adapter owns route selection, two-second warning timing, readiness, bounds validation and bounded cleanup; native code owns motion, collisions, hit reactions and damage. No generic hazard system or replacement damage is needed.

## Warnings and automatic activation

The warning actor creates the native scrolling-arrow and border materials, uses five arrow meshes plus two border meshes, and has a separate warning sign. `AddAsWarningSourceActor` / `RemoveAsWarningSourceActor` maintain early-warning and near-hit source sets, with native color, horn/audio and beat pulses. `SetArrowFlipped` overwrites arrow X scale from `DefaultArrowScaleX`; fitting must account for this rather than calling it blindly after resizing.

Both source-add branches synchronously call `Update Display States` through their bytecode continuation, so immediate `bEarlyWarningOn` / `bNearHitOn` readbacks are justified. Each set resets its warning deadline. A delayed mod tick extends the deadline to preserve at least 0.5 seconds in near-hit color rather than skipping that phase.

The car binds `OnSongCrafterGenericTagEvent`. Its handler rejects invalid incoming tags before comparing `StartTag`, `WarningYellowStartTag` and `WarningRedStartTag`. Clearing all three to invalid tags prevents valid song events from matching. Invalid `StartTag` also makes BeginPlay initially enable movement, so the candidate immediately disables movement after deferred spawn finishes, before a game frame runs.

An actor-scoped `GameplayEvent.Boss.CarHazards` listener remains native: an event specifically sent to the car could warn, delay by `StartDelayInBeats * BeatDurationSeconds`, and start it. Standalone cars must not receive that event or the boss-wave actor tags. The inspected boss ability finds its existing tagged cars; it does not broadcast to arbitrary actors. Boss-finisher callbacks stop/hide cars rather than start them.

## Native damage

The hit sphere independently recognizes `BP_PagodaPlayerCharacter` and `BP_Enemy_Base`; this path does not construct a team filter. It rejects previously hit actors and respects `PlayerHitIgnoreTags` / `EnemyHitIgnoreTags`, then uses `DamageToPlayer` / `DamageToEnemy`.

`HitActor` calls the game's hazard-damage calculation, adds the target to its ignore set, applies the authored facing/hit settings, then calls `PagodaAbilityHitSubsystem:ProcessSimpleHit` with `GE_Damage_SetByCaller`, the car as attacker and `bSkipDamage=false`.

`BPFL_Gameplay:CalcHazardDamageToActor` has no boss or player-only dependency. It preserves input damage except when the target has `Gameplay.Status.HazardDamageReduction` and `floor(damage/5)>=2`, when it returns `(floor(damage/5)-1)*5`. Keep that native resistance. Live reads confirmed configured `DamageToPlayer=10` and `DamageToEnemy=1000`; these are **configuration values, not measured health deltas**. The owner confirmed player and enemy damage in the faster two-set test. Ignore-tag effects and overlap reliability across frame rates remain broader test requirements.

## Geometry and evidence limits

Cooked component templates have nonempty unversioned properties without available mappings. Their precise transforms, collision dimensions, attachment hierarchy and car wheel-height origin were **not decoded**; no serialized schema was invented. The adapter instead reads actual component bounds, checks collider ancestry, and validates the movement parent's X axis before and after actor rotation. It fits the whole warning actor from the seven road meshes' local bounds transformed into world coordinates, then reads their corners back in route coordinates to check the fit. Missing, degenerate or mismatched geometry cancels before activation.

The first live probe exposed a scale error: the warning actor retained its authored **3× scale** after FinishSpawning, while the car's scale was 1×. Fitting replaced that authored scale with ratios computed from already-scaled bounds, making the warning exactly one-third of the requested dimensions. Live road components had zero relative rotation and no absolute transform flags. The correction multiplies the original actor scale by the measured ratios, preserves scale when placing cars, and retains the final corner check. Native materials and mesh layout remain intact; individual mesh reconstruction was unnecessary. The corrected single probe passed at yaw 0 with a 4,942.4 × 388.3 warning route and car half-footprint 431.2 × 154.1 units. Other orientations and the separate scaled warning sign still warrant visual checks.

The `Train_GEN_VARIABLE` export headers identify `/Script/Engine.StaticMeshComponent` in all three classes (class indices -26, -87 and -53 in the inspected base/base/car exports). Zero Train bounds therefore cancel rather than using collision volumes as an unsupported substitute for wheel height. Absolute location/rotation/scale flags anywhere in the collider-to-Train chain also cancel.

Current tuning: 4,000-unit travel at **3,200 units/second**, two seconds of warning after native readiness, the final 0.5 seconds in near-hit color, then native movement. The nominal rush is 1.25 seconds; this doubled speed was requested after the successful 1,600-unit/second probe and passed live with about 1.3 seconds between driving and removal logs. Both sets share the original center and floor height, with perpendicular diagonal routes. There is a one-second gap after complete first-set removal, a two-second initialization limit, a 12-second set limit, a 14-second actor lifespan fallback, and a 40-second whole-batch limit, all in game time. InitialLifeSpan is also set before FinishSpawning to bound setup failures. At most three cars and three warnings are owned. Uncertain survivors are quarantined and prevent a new car batch.

Cleanup uses native validity through a live library object. The pinned UE4SS `LuaUObject.hpp:761` tests the object map and unreachable flag, which can retain a wrapper after native destruction. `UWorld::DestroyActor` marks the actor as garbage and synchronously unregisters components/ticks (`LevelActor.cpp:1051–1061`), but `UObject::ProcessEvent` rejects later calls on that garbage actor (`ScriptCore.cpp:2032`). Consequently, calling `actor:IsActorBeingDestroyed()` can return default false even after destruction.

The adapter gets the KismetSystemLibrary CDO, fetches its bound native function with `bound = lib:GetPropertyValue("IsValid")`, and calls `bound(lib, actor)`. This bypasses UE4SS's same-named `IsValid` member and executes the native check on the live CDO. The native function returns `::IsValid(Object)` (`KismetSystemLibrary.h:2333`). A separate unbound `CallFunction` attempt failed live with a binding error and is not used. The bound function passed known-true/known-false preflight and live cleanup, reporting zero survivors. Query failures still attempt cleanup for every owned actor and quarantine uncertainty; set two requires all owned actors to be natively invalid.

The first successful probe's log records warning preparation at **20:08:50.607**, driving at **20:08:52.948**, and complete removal at **20:08:55.565**, with zero surviving owned actors. The faster probe passed at yaw -167.8. The two-set test at yaw -154.7 logged set one driving at **20:12:40.094**, fully removed at **20:12:41.412**, set two prepared at **20:12:42.487**, driving at **20:12:44.827**, and fully removed at **20:12:46.128**, with zero survivors. The owner confirmed both sets, full warnings, and player/enemy damage. These are game-log timestamps on 2026-10-19. Floor placement across arenas, collision reliability across frame rates, pause and run/song/death/reconnect behavior remain live-test requirements. No wall or terrain traces are implemented: placement uses AlwaysSpawn and native movement is unswept, so suitable routes in cramped or uneven arenas are not guaranteed.

Native APIs were checked against installed Epic UE 5.7 source:

| API | Signature / source |
| --- | --- |
| `Actor:GetActorBounds` | `bool bOnlyCollidingComponents, FVector& Origin, FVector& BoxExtent, bool bIncludeFromChildActors=false`; `Engine/Classes/GameFramework/Actor.h:1614` |
| `StaticMeshComponent:GetLocalBounds` | `FVector& Min, FVector& Max`; `Engine/Classes/Components/StaticMeshComponent.h:486` |
| `KismetSystemLibrary:GetComponentBounds` | `const USceneComponent*, FVector& Origin, FVector& BoxExtent, float& SphereRadius`; `Engine/Classes/Kismet/KismetSystemLibrary.h:1753` |
| `SceneComponent:GetAttachParent` | No arguments, returns the parent component; `Engine/Classes/Components/SceneComponent.h:696` |

Only fully reflected vectors/transforms are used. Opaque target-data/filter handles are never reconstructed through Lua. Native hit amounts must be positive and are logged before warning activation; they are not overridden by the adapter.

Use the actual controlled pawn from `GameplayStatics:GetPlayerPawn(context,0)`. Earlier meteor investigation established that class scans can return a valid stale player actor; a failed test against that actor must not motivate substitute damage.

## Inspection provenance

Final production X proof: set one prepared at yaw -18.7 and set two at 71.3, both centered at (621.0, -57.9, -93.4), a 90-degree difference with no center drift. The first set drove at 20:36:43.029 and was removed at 20:36:44.348; the second prepared at 20:36:45.393, drove at 20:36:47.730, and was removed at 20:36:49.016. The log reported zero surviving owned actors. One real AP item produced one start (`car_sets=2`, `car_count=6`) and one `native_finished` end, with one persisted consumption and no pending command. The user confirmed the X looked correct. Timestamps are from the October 19 game log; ignored evidence is in `playtest/live-cars-20261020-013638-UTC-f979af/`.

Read-only extraction used retoc v0.1.5 and UAssetAPI 1.1.0 against exact packages in the locally installed game, with the prior meteor decoder. All **58 decoded functions across seven packages** passed bytecode roundtrip, complete-export consumption and unchanged-input checks. They cover the car, both parents, indicator, lane manager, boss car-hazards ability and hazard-damage calculation. The reader supplied no fabricated property mappings and executed no game bytecode.

Local scripts, hashes, reports and proprietary extracts are retained outside the repository in the sibling `car-research` folder (`RESEARCH.md`, `integrity.json`, per-function result files and readable traces). Live bring-up findings are recorded in [NOTES.md](../NOTES.md); detailed local logs remain outside the release. No game assets or binary dumps are committed. Continue with the faster single-car probe, then the two-set test, actual damage checks, pause, death, menu/song/arena transitions, reconnect and real AP delivery.
