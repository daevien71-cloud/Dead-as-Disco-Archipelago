# Prophet cars: native evidence and candidate design

Status: **offline research and an unverified Arcade candidate**, 2026-10-19. No live car spawn, warning, movement or damage result is claimed. The installed meteor build was left untouched during candidate preparation. See [the staged playtest guide](cars.md).

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

The candidate snapshots three parallel routes for each set around the current controlled pawn, fitting lane width from runtime native bounds. Routes remain fixed through that set's warning and rush. It uses three native cars and three native warnings, then destroys all six before allowing the next set. Native loops are disabled. The adapter owns route selection, two-second warning timing, readiness, bounds validation and bounded cleanup; native code owns motion, collisions, hit reactions and damage. No generic hazard system or replacement damage is needed.

## Warnings and automatic activation

The warning actor creates the native scrolling-arrow and border materials, uses five arrow meshes plus two border meshes, and has a separate warning sign. `AddAsWarningSourceActor` / `RemoveAsWarningSourceActor` maintain early-warning and near-hit source sets, with native color, horn/audio and beat pulses. `SetArrowFlipped` overwrites arrow X scale from `DefaultArrowScaleX`; fitting must account for this rather than calling it blindly after resizing.

Both source-add branches synchronously call `Update Display States` through their bytecode continuation, so immediate `bEarlyWarningOn` / `bNearHitOn` readbacks are justified. Each set resets its warning deadline. A delayed mod tick extends the deadline to preserve at least 0.5 seconds in near-hit color rather than skipping that phase.

The car binds `OnSongCrafterGenericTagEvent`. Its handler rejects invalid incoming tags before comparing `StartTag`, `WarningYellowStartTag` and `WarningRedStartTag`. Clearing all three to invalid tags prevents valid song events from matching. Invalid `StartTag` also makes BeginPlay initially enable movement, so the candidate immediately disables movement after deferred spawn finishes, before a game frame runs.

An actor-scoped `GameplayEvent.Boss.CarHazards` listener remains native: an event specifically sent to the car could warn, delay by `StartDelayInBeats * BeatDurationSeconds`, and start it. Standalone cars must not receive that event or the boss-wave actor tags. The inspected boss ability finds its existing tagged cars; it does not broadcast to arbitrary actors. Boss-finisher callbacks stop/hide cars rather than start them.

## Native damage

The hit sphere independently recognizes `BP_PagodaPlayerCharacter` and `BP_Enemy_Base`; this path does not construct a team filter. It rejects previously hit actors and respects `PlayerHitIgnoreTags` / `EnemyHitIgnoreTags`, then uses `DamageToPlayer` / `DamageToEnemy`.

`HitActor` calls the game's hazard-damage calculation, adds the target to its ignore set, applies the authored facing/hit settings, then calls `PagodaAbilityHitSubsystem:ProcessSimpleHit` with `GE_Damage_SetByCaller`, the car as attacker and `bSkipDamage=false`.

`BPFL_Gameplay:CalcHazardDamageToActor` has no boss or player-only dependency. It preserves input damage except when the target has `Gameplay.Status.HazardDamageReduction` and `floor(damage/5)>=2`, when it returns `(floor(damage/5)-1)*5`. Keep that native resistance. Default damage amounts, ignore tags and Arcade overlap behavior remain unverified.

## Geometry and evidence limits

Cooked component templates have nonempty unversioned properties without available mappings. Their precise transforms, collision dimensions, attachment hierarchy and car wheel-height origin were **not decoded**; no serialized schema was invented. The adapter reads actual component bounds, checks collider ancestry, and validates the movement parent's X axis before and after actor rotation. It fits the whole warning actor from the seven road meshes' local bounds transformed into world coordinates, then reads their corners back in route coordinates to check the fit. This preserves native materials and layout; the separate sign also inherits actor scaling and needs visual review. Missing, degenerate or mismatched geometry cancels before activation.

The `Train_GEN_VARIABLE` export headers identify `/Script/Engine.StaticMeshComponent` in all three classes (class indices -26, -87 and -53 in the inspected base/base/car exports). Zero Train bounds therefore cancel rather than using collision volumes as an unsupported substitute for wheel height. Absolute location/rotation/scale flags anywhere in the collider-to-Train chain also cancel.

Candidate tuning: 4,000-unit travel at 1,600 units/second, two seconds of warning after native readiness, the final 0.5 seconds in near-hit color, then native movement. The first and second sets use the same facing but each snapshots the current player position. There is a one-second gap after complete first-set removal, a two-second initialization limit, a 12-second set limit, a 14-second actor lifespan fallback, and a 40-second whole-batch limit, all in game time. At most three cars and three warnings are owned. Failed destruction quarantines surviving owned actors and prevents a new car batch until they disappear.

Cleanup checks actor destruction separately from UObject memory validity. The pinned UE4SS `LuaUObject.hpp:761` tests the object map and unreachable flag, which can leave destroyed memory valid until GC. UE 5.7's Blueprint-callable `Actor:IsActorBeingDestroyed()` (`Actor.h:2155`) stays true after destruction; `UWorld::DestroyActor` synchronously unregisters components and ticks (`LevelActor.cpp:1051–1061`). The adapter waits for every owned actor to be invalid or natively destroyed before allowing set two; it never waits for garbage collection to decide whether a car has left the battlefield.

Visual fit, floor contact, route clearance and collision behavior remain live-test requirements. No wall or terrain traces are implemented: actor placement uses AlwaysSpawn and native movement is unswept. Open, flat arena testing comes first; this candidate cannot promise suitable routes in every arena.

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

Read-only extraction used retoc v0.1.5 and UAssetAPI 1.1.0 against exact packages in the locally installed game, with the prior meteor decoder. All **58 decoded functions across seven packages** passed bytecode roundtrip, complete-export consumption and unchanged-input checks. They cover the car, both parents, indicator, lane manager, boss car-hazards ability and hazard-damage calculation. The reader supplied no fabricated property mappings and executed no game bytecode.

Local scripts, hashes, reports and proprietary extracts are retained outside the repository in the sibling `car-research` folder (`RESEARCH.md`, `integrity.json`, per-function result files and readable traces). The repository contains this summary and original adapter code only. No game assets or binary dumps are committed. Live validation must follow the single-car probe before the two-set test, then cover pause, death, menu/song/arena transitions, reconnect and real AP delivery.
