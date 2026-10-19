-- Offline contract tests for meteor.lua using a fake UE4SS API.
-- Usage: lua tests/lua/test_meteor.lua <repo root>
-- These verify the adapter's calls and ownership, not Unreal rendering or damage.
local root = assert(arg[1], "pass the repo root")
package.path = root .. "/mod/DeadAsDiscoAP/Scripts/?.lua;" .. package.path
local Meteor = require("meteor")

local FALLING = "/Game/Pagoda/Characters/Enemies/Doll/UniqueMechanics/BP_BigDoll_Meteor.BP_BigDoll_Meteor_C"
local LANDED = "/Game/Pagoda/Characters/Enemies/Doll/UniqueMechanics/BP_Destructable_BigDoll_Meteor.BP_Destructable_BigDoll_Meteor_C"
local SPAWN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local EXPIRY = "/Game/Pagoda/Characters/Enemies/Doll/UniqueMechanics/GA_ExplodeAfterTime_BigDollMeteor.GA_ExplodeAfterTime_BigDollMeteor_C"
local TIMER = "/Script/Pagoda.PagodaUtilsFunctionLibrary:DelayUntilTimelinePos"
local checks, failures, scenarios, next_address = 0, 0, 0, 1000

local function check(condition, message)
    checks = checks + 1
    if not condition then
        failures = failures + 1
        io.stderr:write("FAIL: " .. message .. "\n")
    end
end

local function scenario(name, run)
    scenarios = scenarios + 1
    local ok, err = pcall(run)
    if not ok then
        failures = failures + 1
        io.stderr:write("ERROR in " .. name .. ": " .. tostring(err) .. "\n")
    end
end

local function object(name, props)
    next_address = next_address + 1
    local o = props or {}
    o._valid, o._name, o._address = true, name, next_address
    function o:IsValid() return self._valid end
    function o:GetFullName() return self._name end
    function o:GetAddress() return self._address end
    return o
end

local function param(value)
    local wrapped = {writes = 0}
    function wrapped:get() return value end
    function wrapped:set(new_value) value = new_value; self.writes = self.writes + 1 end
    return wrapped
end
local function vector_equal(a, b)
    return a and b and a.X == b.X and a.Y == b.Y and a.Z == b.Z
end

local function fixture(options)
    options = options or {}
    local f = {
        game_time = 100, wall_time = 100, paused = false,
        events = {}, actors = {}, loads = {}, unregistered = {}, hooks = {}, logs = {},
        begin_calls = 0, finish_calls = 0, inside_callback = false,
    }
    f.random_calls = 0
    math.random = function(low, high)
        assert(low == 1 and high == 5, "meteor count is chosen from one through five")
        f.random_calls = f.random_calls + 1
        return options.count or 1
    end
    f.world = object("Arcade world")
    f.state = object("InfiniteDisco state")
    f.location = {X = 100, Y = 200, Z = 400}
    f.player = object("Charlie", {
        CharacterMovement = {MovementMode = 1, UpdatedComponent = object("moving capsule")},
        CapsuleComponent = {GetScaledCapsuleHalfHeight = function() return 90 end},
    })
    function f.player:GetWorld() return f.world end
    function f.player:K2_GetActorLocation() return f.location end

    function f.actor(name)
        local actor = object(name, {destroy_calls = 0, lifespans = {}, DamageToPlayer = 10, DamageToEnemies = 80})
        actor.ProjectileMovementComponent = {SetBeatWarpingEnabled = function(_, enabled) actor.beat_warp = enabled end}
        function actor:K2_DestroyActor()
            assert(not f.inside_callback, "NEVER destroy an actor from inside its native hook callback")
            self.destroy_calls = self.destroy_calls + 1
            self._valid = false
            f.events[#f.events + 1] = "destroy:" .. self._name
        end
        function actor:SetLifeSpan(seconds)
            self.lifespans[#self.lifespans + 1] = seconds
        end
        f.actors[#f.actors + 1] = actor
        return actor
    end

    f.falling, f.landed, f.expiry = object(FALLING), object(LANDED), object(EXPIRY)
    f.classes = {[FALLING] = f.falling, [LANDED] = f.landed, [EXPIRY] = f.expiry}
    if options.unloaded then f.classes = {} end
    f.statics = object("GameplayStatics")
    function f.statics:IsGamePaused(player)
        assert(player == f.player, "pause check uses the current player")
        return f.paused
    end
    function f.statics:GetTimeSeconds(player)
        assert(player == f.player, "lifetime reads the current game world")
        return f.game_time
    end
    function f.statics:BeginDeferredActorSpawnFromClass(context, cls, transform, collision, owner, scale)
        f.begin_calls = f.begin_calls + 1
        f.events[#f.events + 1] = "begin"
        f.spawn_args = {context = context, cls = cls, transform = transform, collision = collision, owner = owner, scale = scale}
        if options.spawn_throws then error("fake native spawn exception") end
        if options.spawn_invalid then
            local invalid = object("invalid spawn")
            invalid._valid = false
            return invalid
        end
        if options.spawn_nil then return nil end
        f.parent = f.actor("owned falling meteor")
        return f.parent
    end
    function f.statics:FinishSpawningActor(parent, transform, scale)
        f.finish_calls = f.finish_calls + 1
        f.events[#f.events + 1] = "finish"
        assert(parent == f.parent, "finish only the deferred parent")
        assert(transform == f.spawn_args.transform and scale == 1, "finish uses the deferred transform")
        -- BeginPlay must see the target and speed on its very first invocation.
        assert(vector_equal(parent.TargetLocation, {X = f.location.X, Y = f.location.Y, Z = f.location.Z - 90}),
            "current target initialized BEFORE FinishSpawningActor")
        assert(parent.InitialSpeed and parent.InitialSpeed > 0, "speed initialized BEFORE FinishSpawningActor")
        assert(parent.beat_warp == false, "falling actor beat warp disabled BEFORE BeginPlay")
        assert(f.hooks[SPAWN], "native child hook installed BEFORE FinishSpawningActor")
        assert(f.hooks[TIMER], "native expiry hook installed BEFORE FinishSpawningActor")
        if options.finish_throws then error("fake native finish exception") end
        if options.child_on_finish then
            f.child = f.actor("owned native remnant")
            f.emit_spawn(f.parent, f.landed, f.child)
        end
        return parent
    end
    local mathlib = object("KismetMathLibrary")
    function mathlib:MakeTransform(location, rotation, scale)
        return {location = location, rotation = rotation, scale = scale}
    end

    StaticFindObject = function(path)
        if path == "/Script/Engine.Default__GameplayStatics" then return f.statics end
        if path == "/Script/Engine.Default__KismetMathLibrary" then return mathlib end
        return f.classes[path]
    end
    LoadAsset = function(path)
        f.loads[#f.loads + 1] = path
        if options.load_throws then error("fake load exception") end
        if options.load_missing then return nil end
        if path == FALLING:match("^(.-)%.") then f.classes[FALLING] = f.falling end
        if path == LANDED:match("^(.-)%.") then f.classes[LANDED] = f.landed end
        if path == EXPIRY:match("^(.-)%.") then f.classes[EXPIRY] = f.expiry end
    end
    RegisterHook = function(path, pre, post)
        assert((path == SPAWN or path == TIMER) and type(pre) == "function")
        assert(path ~= SPAWN or type(post) == "function", "spawn uses native post callback")
        f.events[#f.events + 1] = "hook"
        if options.hook_throws or (options.timer_hook_throws and path == TIMER) then error("fake registration exception") end
        assert(not f.hooks[path], "at most one hook registration")
        local ids = path == SPAWN and {41, 42} or {43, 44}
        f.hooks[path] = {pre = pre, post = post, ids = ids}
        return ids[1], ids[2]
    end
    UnregisterHook = function(path, pre, post)
        assert(not f.inside_callback, "NEVER unregister a hook from inside its callback")
        local hook = assert(f.hooks[path], "only unregister an installed hook")
        assert(pre == hook.ids[1] and post == hook.ids[2], "unregister exact hook ids")
        f.unregistered[#f.unregistered + 1] = path
        f.hooks[path] = nil
    end
    function f.emit_spawn(context, cls, result)
        local hook = assert(f.hooks[SPAWN], "spawn hook is installed")
        f.inside_callback = true
        -- UE4SS native post callback: Context, ReturnValue, then UFunction inputs.
        local ok, err = pcall(hook.post, param(f.statics), param(result), param(context), param(cls),
            param({}), param(3), param(nil), param(1))
        f.inside_callback = false
        assert(ok, err)
    end
    function f.finish_native()
        local child = f.meteor.active.child
        if not child then
            child = f.actor("observed completed native remnant")
            f.emit_spawn(f.parent, f.landed, child)
        end
        f.parent._valid, child._valid = false, false
    end
    function f.ability(owner, cls, activated, deadline)
        local ability = object("native expiry ability", {MusicTimeActivated = activated, ExplodeGameSyncTime = deadline})
        function ability:GetClass() return cls or f.expiry end
        function ability:GetOwningActorFromActorInfo() return owner end
        return ability
    end
    function f.emit_timer(ability, timeline)
        local hook = assert(f.hooks[TIMER], "timer hook is installed")
        f.inside_callback = true
        -- Native void pre callback: Context, then UFunction inputs (no ReturnValue).
        local ok, err = pcall(hook.pre, param(f.statics), param(ability), timeline, param({}), param(true))
        f.inside_callback = false
        assert(ok, err)
    end
    function f.advance(seconds, dilation)
        f.wall_time = f.wall_time + seconds
        if not f.paused then f.game_time = f.game_time + seconds * (dilation or 1) end
    end
    f.meteor = Meteor.new(function(text) f.logs[#f.logs + 1] = text end)
    return f
end

scenario("deferred initialization and fixed ground target", function()
    local f = fixture({unloaded = true, child_on_finish = true})
    local ok = f.meteor:start(f.player, f.state)
    check(ok and f.begin_calls == 1 and f.finish_calls == 1, "one deferred meteor starts successfully")
    check(table.concat(f.events, ",") == "begin,hook,hook,finish", "hooks and field initialization precede native BeginPlay")
    check(#f.loads == 3, "cold start loads projectile, remnant and expiry classes")
    check(f.spawn_args.context == f.player and f.spawn_args.cls == f.falling, "spawn uses current world and native falling class")
    check(f.spawn_args.owner == nil and f.parent.Instigator == nil, "native owner/instigator remain unset")
    check(f.spawn_args.transform.location.Z > f.parent.TargetLocation.Z, "meteor starts above its ground target")
    check(f.parent.TargetLocation ~= f.location, "target is a copied location, not the player's live vector")
    f.location.X, f.location.Y, f.location.Z = 999, 888, 777
    f.meteor:tick(f.player, f.state, true)
    check(vector_equal(f.parent.TargetLocation, {X = 100, Y = 200, Z = 310}), "moving player does not retarget warning/impact")
    check(f.meteor.active.child == f.child, "native post-hook ReturnValue captures remnant spawned during Finish")
    check(#f.unregistered == 1 and f.hooks[SPAWN] == nil and f.hooks[TIMER],
        "remnant capture removes spawn hook but retains timer hook until owned ability activates")
    check(f.parent.DamageToPlayer == 10 and f.parent.DamageToEnemies == 80, "native damage settings are preserved")
    f.meteor:stop("test cleanup")
end)

scenario("only exact parent and landed class confer ownership", function()
    local f = fixture()
    check(f.meteor:start(f.player, f.state), "ownership scenario starts")
    local other_parent = f.actor("other boss meteor")
    local other_class = object("unrelated projectile class")
    local unrelated = f.actor("unrelated actor")
    f.emit_spawn(other_parent, f.landed, unrelated)
    check(f.meteor.active.child == nil, "same landed class from another parent is ignored")
    f.emit_spawn(f.parent, other_class, unrelated)
    check(f.meteor.active.child == nil, "different actor class from owned parent is ignored")
    local invalid = f.actor("invalid remnant")
    invalid._valid = false
    f.emit_spawn(f.parent, f.landed, invalid)
    check(f.meteor.active.child == nil, "invalid returned actor is ignored")
    local child = f.actor("owned remnant")
    f.emit_spawn(f.parent, f.landed, child)
    check(f.meteor.active.child == child, "matching native callback captures exactly its returned actor")
    check(#f.unregistered == 0 and f.hooks[SPAWN], "callback leaves spawn hook registered until game-thread tick")
    f.meteor:tick(f.player, f.state, true)
    check(#f.unregistered == 1 and f.hooks[TIMER], "tick preserves unadjusted timer hook after child capture")
    f.meteor:stop("left_run")
    check(f.parent.destroy_calls == 1 and child.destroy_calls == 1, "cleanup destroys owned parent and child")
    check(unrelated.destroy_calls == 0 and other_parent.destroy_calls == 0, "cleanup never destroys unrelated actors")
    f.meteor:stop("again")
    check(f.parent.destroy_calls == 1 and child.destroy_calls == 1 and #f.unregistered == 2, "cleanup is idempotent")
end)

scenario("expiry extension belongs only to the exact native child ability", function()
    local f = fixture()
    check(f.meteor:start(f.player, f.state), "expiry-ownership scenario starts")
    local child = f.actor("owned native remnant")
    local ability = f.ability(child, nil, 250.25, 252.75)
    local timeline = param(252.75)
    f.emit_timer(ability, timeline)
    check(timeline.writes == 0, "timer before child capture is ignored")
    f.emit_spawn(f.parent, f.landed, child)

    local wrong_class = f.ability(child, object("other native expiry class"), 250.25, 252.75)
    f.emit_timer(wrong_class, timeline)
    check(timeline.writes == 0 and wrong_class.ExplodeGameSyncTime == 252.75, "different ability class on owned child is untouched")
    local other_child = f.actor("another boss remnant")
    local wrong_owner = f.ability(other_child, nil, 250.25, 252.75)
    f.emit_timer(wrong_owner, timeline)
    check(timeline.writes == 0 and wrong_owner.ExplodeGameSyncTime == 252.75, "same expiry class on another child is untouched")
    local invalid_ability = f.ability(child, nil, 250.25, 252.75)
    invalid_ability._valid = false
    f.emit_timer(invalid_ability, timeline)
    check(timeline.writes == 0 and f.meteor.active.callback_error == nil, "invalid ability is ignored safely")

    f.emit_timer(ability, timeline)
    check(timeline:get() == 261.25 and ability.ExplodeGameSyncTime == 261.25,
        "matching ability extends both native deadline values to 11 seconds after activation")
    check(f.meteor.active.timer_adjusted and timeline.writes == 1, "matching timer is adjusted once")
    f.emit_timer(ability, timeline)
    check(timeline.writes == 1, "repeated native callback cannot extend or rewrite the timer again")
    check(#f.unregistered == 0 and child.destroy_calls == 0, "timer callback performs no unregistration or actor destruction")
    f.meteor:tick(f.player, f.state, true)
    check(#f.unregistered == 2 and not f.hooks[TIMER] and not f.hooks[SPAWN], "following tick removes both remaining transient hooks")
    f.meteor:stop("test cleanup")
    check(other_child.destroy_calls == 0, "expiry scoping does not confer ownership of other remnants")
end)

scenario("owned expiry ability may activate after a later tick", function()
    local f = fixture({child_on_finish = true})
    check(f.meteor:start(f.player, f.state), "delayed expiry scenario starts")
    f.parent._valid = false
    f.meteor:tick(f.player, f.state, true)
    f.advance(1)
    f.meteor:tick(f.player, f.state, true)
    check(not f.hooks[SPAWN] and f.hooks[TIMER] and #f.unregistered == 1,
        "timer hook survives child capture, parent destruction and intervening ticks")
    local ability = f.ability(f.child, nil, 430, 432)
    local deadline = param(432)
    f.emit_timer(ability, deadline)
    check(ability.ExplodeGameSyncTime == 441 and deadline:get() == 441,
        "late native ability receives the full minimum timer")
    check(f.hooks[TIMER], "successful timer callback still defers unregistration")
    f.meteor:tick(f.player, f.state, true)
    check(not f.hooks[TIMER] and #f.unregistered == 2, "following tick removes adjusted timer hook")
    f.meteor:stop("test cleanup")
end)

scenario("missing native timer activation retains diagnostics and cleanup", function()
    local f = fixture({child_on_finish = true})
    check(f.meteor:start(f.player, f.state), "missing timer scenario starts")
    f.meteor:tick(f.player, f.state, true)
    f.meteor:stop("left_run")
    check(#f.unregistered == 2 and next(f.hooks) == nil, "stop removes an unadjusted retained timer hook")
    local warned = false
    for _, entry in ipairs(f.logs) do if entry:find("timer was not adjusted", 1, true) then warned = true end end
    check(warned, "missing timer activation is explicitly reported")
end)

scenario("one-meteor batch selects count once and announces only its launch", function()
    local f, notices = fixture({count = 1}), {}
    local ok, count = f.meteor:start(f.player, f.state, function(index, total)
        notices[#notices + 1] = {index, total}
    end)
    check(ok and count == 1 and f.random_calls == 1, "accepted item chooses exactly one random count")
    check(#notices == 1 and notices[1][1] == 1 and notices[1][2] == 1, "one-meteor batch announces first launch once")
    local accepted, reason = f.meteor:start(f.player, f.state)
    check(not accepted and reason == "busy" and f.random_calls == 1, "busy retry neither rerolls nor adds a meteor")
    f.finish_native()
    check(f.meteor:tick(f.player, f.state, true) == "native_finished" and not f.meteor.batch,
        "one meteor completes item only after native lifecycle ends")
    f.advance(100)
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 1 and #notices == 1, "completed item cannot replay later")
end)

scenario("five-meteor batch waits for every native remnant and retargets each launch", function()
    local f, notices = fixture({count = 5}), {}
    local ok, count = f.meteor:start(f.player, f.state, function(index, total)
        notices[#notices + 1] = {index, total}
    end)
    check(ok and count == 5 and f.meteor.batch.ends_at == 210, "five-meteor item has a 110-game-second total cap")
    for index = 1, 5 do
        local parent = f.parent
        local child = f.actor("owned batch remnant " .. index)
        f.emit_spawn(parent, f.landed, child)
        parent._valid = false
        f.advance(4)
        f.meteor:tick(f.player, f.state, true)
        check(f.begin_calls == index and f.meteor.active.child == child,
            "meteor " .. index .. " keeps later launches blocked while its remnant exists")
        child._valid = false
        f.location.X = f.location.X + 75
        local reason = f.meteor:tick(f.player, f.state, true)
        if index < 5 then
            check(reason == nil and f.begin_calls == index + 1 and f.parent.TargetLocation.X == f.location.X,
                "next meteor targets current player position only after previous remnant disappears")
        else
            check(reason == "native_finished" and not f.meteor.active and not f.meteor.batch,
                "fifth remnant completion releases the batch")
        end
    end
    local ordered = #notices == 5
    for index, notice in ipairs(notices) do ordered = ordered and notice[1] == index and notice[2] == 5 end
    check(ordered and f.random_calls == 1, "five actual launches produce five ordered warnings from one count draw")
    check(#f.unregistered == 10 and next(f.hooks) == nil, "all per-meteor hooks are cleaned after the five-meteor batch")
end)

scenario("launch gap remains enforced when native actors finish immediately", function()
    local f = fixture({count = 2})
    check(f.meteor:start(f.player, f.state), "launch-gap batch starts")
    f.finish_native()
    f.meteor:tick(f.player, f.state, true)
    check(not f.meteor.active and f.meteor.batch and f.begin_calls == 1, "batch remains busy between native lifecycles")
    local ready, reason = f.meteor:ready(f.player)
    check(not ready and reason == "busy", "effect cannot overlap during empty gap")
    f.advance(2.99)
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 1, "no next launch before three game seconds")
    f.game_time = 103
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 2 and f.meteor.active, "next launch becomes eligible at three game seconds")
    f.meteor:stop("test cleanup")
end)

scenario("later launch waits through airborne state, wave downtime and pause", function()
    local f = fixture({count = 5})
    check(f.meteor:start(f.player, f.state), "waiting batch starts")
    f.finish_native()
    f.player.CharacterMovement.MovementMode = 3
    f.advance(3)
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 1 and f.meteor.batch and not f.meteor.active, "airborne player delays later meteor")
    f.player.CharacterMovement.MovementMode = 1
    f.state.bWaveClearedRequested = true
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 1, "wave downtime delays later meteor")
    f.state.bWaveClearedRequested = false
    f.paused = true
    f.advance(1000)
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 1 and f.game_time == 103 and f.meteor.batch,
        "paused wall time neither launches nor expires waiting batch")
    f.paused = false
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 2 and f.meteor.active, "valid unpaused play resumes remaining meteors")
    f.meteor:stop("test cleanup")
end)

for _, transition in ipairs({"run", "player", "state", "world", "invalid_player", "invalid_state"}) do
    scenario("batch identity guard between actors: " .. transition, function()
        local f = fixture({count = 5})
        check(f.meteor:start(f.player, f.state), transition .. " batch starts")
        f.finish_native()
        f.meteor:tick(f.player, f.state, true)
        local player, state, in_run = f.player, f.state, true
        if transition == "run" then in_run = false
        elseif transition == "player" then player = object("next Charlie")
        elseif transition == "state" then state = object("next Arcade state")
        elseif transition == "world" then f.world = object("next world")
        elseif transition == "invalid_player" then f.player._valid = false
        elseif transition == "invalid_state" then f.state._valid = false end
        check(f.meteor:tick(player, state, in_run) == "left_run", transition .. " cancels waiting batch")
        check(not f.meteor.batch and not f.meteor.active and next(f.hooks) == nil,
            transition .. " leaves no queued meteor or hook")
        f.advance(20)
        f.meteor:tick(player, state, in_run)
        check(f.begin_calls == 1, transition .. " cannot replay remaining meteors")
    end)
end

scenario("batch cap prevents indefinite downtime queue", function()
    local f = fixture({count = 5})
    check(f.meteor:start(f.player, f.state), "bounded waiting batch starts")
    f.finish_native()
    f.state.bWaveClearedRequested = true
    f.game_time = f.meteor.batch.ends_at - 0.01
    check(f.meteor:tick(f.player, f.state, true) == nil and f.meteor.batch,
        "waiting batch survives until its game-time deadline")
    f.game_time = 210
    check(f.meteor:tick(f.player, f.state, true) == "batch_expired" and not f.meteor.batch,
        "hard batch deadline discards remaining meteors")
    f.state.bWaveClearedRequested = false
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 1 and next(f.hooks) == nil, "expired batch cannot resume after downtime")
end)

scenario("batch deadline also removes a late active meteor and remnant", function()
    local f = fixture({count = 2})
    check(f.meteor:start(f.player, f.state), "late active batch starts")
    f.finish_native()
    f.state.bWaveClearedRequested = true
    f.meteor:tick(f.player, f.state, true)
    f.game_time = 149
    f.state.bWaveClearedRequested = false
    f.meteor:tick(f.player, f.state, true)
    local parent, child = f.parent, f.actor("late final remnant")
    f.emit_spawn(parent, f.landed, child)
    check(f.begin_calls == 2 and f.meteor.active.child == child, "last meteor may launch shortly before total deadline")
    f.game_time = 150
    check(f.meteor:tick(f.player, f.state, true) == "batch_expired", "total deadline supersedes later per-meteor lifetime")
    check(parent.destroy_calls == 1 and child.destroy_calls == 1 and next(f.hooks) == nil and not f.meteor.batch,
        "batch expiry removes both still-active native actors and hooks")
end)

scenario("blocked later meteor skips its attempt without replaying the AP item", function()
    local options, notices = {count = 3}, {}
    local f = fixture(options)
    check(f.meteor:start(f.player, f.state, function(index) notices[#notices + 1] = index end), "partial batch starts")
    f.finish_native()
    options.spawn_nil = true
    f.advance(3)
    check(f.meteor:tick(f.player, f.state, true) == nil, "blocked middle launch does not fail or replay accepted item")
    check(f.begin_calls == 2 and not f.meteor.active and f.meteor.batch.launched == 2 and #notices == 1,
        "failed attempt advances batch without announcing a nonexistent meteor")
    options.spawn_nil = false
    f.advance(2)
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 2, "failed attempt still observes launch gap")
    f.advance(1)
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 3 and #notices == 2 and notices[2] == 3, "remaining attempt launches once with its original batch index")
    f.finish_native()
    check(f.meteor:tick(f.player, f.state, true) == "native_finished" and not f.meteor.batch,
        "partially blocked batch completes after last native lifecycle")
end)

scenario("blocked final meteor ends batch and callback failures do not abort a native launch", function()
    local options = {count = 2}
    local f = fixture(options)
    local ok = f.meteor:start(f.player, f.state, function() error("warning sink unavailable") end)
    check(ok and f.meteor.active and f.meteor.batch, "warning callback failure does not lose an already spawned meteor")
    f.finish_native()
    options.spawn_nil = true
    f.advance(3)
    check(f.meteor:tick(f.player, f.state, true) == "batch_finished", "blocked final attempt completes accepted batch")
    check(not f.meteor.batch and not f.meteor.active and next(f.hooks) == nil, "blocked final attempt leaves no state or hooks")
end)

scenario("native callback failure aborts all remaining batch meteors", function()
    local f = fixture({count = 5, child_on_finish = true})
    check(f.meteor:start(f.player, f.state), "callback-failure batch starts")
    f.emit_timer(f.ability(f.child, nil, 100, 99), param(99))
    local reason = f.meteor:tick(f.player, f.state, true)
    check(reason and reason:match("^runtime_failed:") and not f.meteor.batch,
        "native callback failure cancels remaining batch")
    f.advance(10)
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 1 and next(f.hooks) == nil, "failed callback cannot trigger later meteors")
end)

for _, activated in ipairs({-400.5, 9876.25}) do
    scenario("expiry preserves music timeline origin " .. activated, function()
        local f = fixture({child_on_finish = true})
        check(f.meteor:start(f.player, f.state), "timeline-origin scenario starts")
        local ability = f.ability(f.child, nil, activated, activated + 2.75)
        local timeline = param(activated + 2.75)
        f.emit_timer(ability, timeline)
        check(timeline:get() == activated + 11 and ability.ExplodeGameSyncTime == activated + 11,
            "deadline stays in the ability's music timeline, independently of world time")
        check(f.meteor.active.ends_at == 116, "music deadline adjustment does not change the game-time safety cap")
        f.meteor:stop("test cleanup")
    end)
end

scenario("already-long native timer is not shortened", function()
    local f = fixture({child_on_finish = true})
    check(f.meteor:start(f.player, f.state), "long-timer scenario starts")
    local ability = f.ability(f.child, nil, 500.25, 512.75)
    local timeline = param(512.75)
    f.emit_timer(ability, timeline)
    check(timeline:get() == 512.75 and ability.ExplodeGameSyncTime == 512.75, "native duration above minimum remains unchanged")
    f.meteor:stop("test cleanup")
end)

for _, failure in ipairs({"negative_span", "excessive_span", "nan_span", "owner_throws", "timeline_set_throws"}) do
    scenario("expiry callback failure " .. failure, function()
        local f = fixture({child_on_finish = true})
        check(f.meteor:start(f.player, f.state), failure .. " callback scenario starts")
        local ability = f.ability(f.child, nil, 500, 502)
        local value = failure == "negative_span" and 499 or failure == "excessive_span" and 561
            or failure == "nan_span" and (0 / 0) or 502
        local timeline = param(value)
        if failure == "owner_throws" then
            function ability:GetOwningActorFromActorInfo() error("native owner unavailable") end
        elseif failure == "timeline_set_throws" then
            function timeline:set() error("native timeline write failed") end
        end
        f.emit_timer(ability, timeline)
        check(type(f.meteor.active.callback_error) == "string", failure .. " is caught in native callback")
        check(#f.unregistered == 0 and f.parent.destroy_calls == 0 and f.child.destroy_calls == 0,
            failure .. " defers cleanup until outside native callback")
        local reason = f.meteor:tick(f.player, f.state, true)
        check(reason and reason:match("^runtime_failed:"), failure .. " surfaces a diagnostic lifecycle failure")
        check(f.meteor.active == nil and f.parent.destroy_calls == 1 and f.child.destroy_calls == 1,
            failure .. " removes both owned actors on following tick")
        check(#f.unregistered == 2, failure .. " removes both remaining native hooks")
    end)
end

scenario("late expiry callback cannot change a new flight", function()
    local f = fixture({child_on_finish = true})
    check(f.meteor:start(f.player, f.state), "late-timer scenario starts")
    local old_callback = f.hooks[TIMER].pre
    local ability = f.ability(f.child, nil, 20, 22)
    local timeline = param(22)
    f.meteor:stop("left_run")
    old_callback(param(f.statics), param(ability), timeline)
    check(timeline.writes == 0 and ability.ExplodeGameSyncTime == 22, "stopped flight's timer callback is harmless")
    check(f.meteor:start(f.player, f.state), "next flight starts after expiry cleanup")
    old_callback(param(f.statics), param(ability), timeline)
    check(timeline.writes == 0 and not f.meteor.active.timer_adjusted, "stale timer callback cannot alter new flight")
    f.meteor:stop("test cleanup")
end)

scenario("late remnant extension remains within total game-time cap", function()
    local f = fixture()
    check(f.meteor:start(f.player, f.state), "late-remnant scenario starts")
    f.advance(14)
    local child = f.actor("late owned remnant")
    f.emit_spawn(f.parent, f.landed, child)
    local ability = f.ability(child, nil, 950, 952)
    f.emit_timer(ability, param(952))
    f.meteor:tick(f.player, f.state, true)
    check(child.lifespans[1] == 2, "late remnant is bounded to remaining two game seconds")
    f.advance(2)
    check(f.meteor:tick(f.player, f.state, true) == "expired", "safety cap overrides a later native music deadline")
    check(child.destroy_calls == 1, "late remnant cannot outlive total cap")
end)

scenario("one active meteor across flight and remnant", function()
    local f = fixture()
    check(f.meteor:start(f.player, f.state), "first meteor accepted")
    local ok, reason = f.meteor:start(f.player, f.state)
    check(not ok and reason == "busy" and f.begin_calls == 1, "second meteor rejected during flight")
    local child = f.actor("owned remnant")
    f.emit_spawn(f.parent, f.landed, child)
    f.parent._valid = false
    f.meteor:tick(f.player, f.state, true)
    ok, reason = f.meteor:start(f.player, f.state)
    check(not ok and reason == "busy" and f.begin_calls == 1, "second meteor rejected while remnant remains")
    child._valid = false
    check(f.meteor:tick(f.player, f.state, true) == "native_finished", "native destruction completes lifecycle")
    check(f.meteor.active == nil and child.destroy_calls == 0, "already destroyed native actors are not destroyed twice")
    check(f.meteor:start(f.player, f.state) and f.begin_calls == 2, "next meteor can start after native completion")
    f.meteor:stop("test cleanup")
end)

scenario("paused and airborne starts wait", function()
    local f = fixture()
    f.paused = true
    local ok, reason = f.meteor:start(f.player, f.state)
    check(not ok and reason == "paused" and f.begin_calls == 0, "paused start does not spawn")
    f.paused, f.player.CharacterMovement.MovementMode = false, 3
    ok, reason = f.meteor:start(f.player, f.state)
    check(not ok and reason == "airborne" and f.begin_calls == 0, "airborne start does not spawn")
    f.player._valid = false
    ok, reason = f.meteor:start(f.player, f.state)
    check(not ok and reason == "not_in_run" and f.meteor.active == nil, "invalid player is rejected without active state")
    ok, reason = f.meteor:start(nil, f.state)
    check(not ok and reason == "not_in_run", "missing player is rejected safely")
    check(f.random_calls == 0, "unready start never rolls a meteor count")
end)

scenario("ground readiness uses reflected walking modes and a valid updated component", function()
    local f = fixture()
    -- A misleading inherited query must not override reflected CharacterMovement state.
    f.player.CharacterMovement.IsMovingOnGround = function() error("do not use inherited navigation query") end
    for mode = 0, 7 do
        f.player.CharacterMovement.MovementMode = mode
        local ok, reason = f.meteor:ready(f.player)
        check((mode == 1 or mode == 2) and ok or ((mode ~= 1 and mode ~= 2) and not ok and reason == "airborne"),
            "movement mode " .. mode .. " has correct grounded readiness")
    end
    f.player.CharacterMovement.MovementMode = 1
    f.player.CharacterMovement.UpdatedComponent._valid = false
    local ok, reason = f.meteor:ready(f.player)
    check(not ok and reason == "airborne", "walking with invalid updated component cannot spawn")
    f.player.CharacterMovement.UpdatedComponent = nil
    ok, reason = f.meteor:ready(f.player)
    check(not ok and reason == "airborne", "walking with missing updated component cannot spawn")
    check(f.begin_calls == 0, "readiness checks have no spawning side effects")
end)

scenario("lifetime follows game time, pause and dilation", function()
    local f = fixture()
    check(f.meteor:start(f.player, f.state), "timing scenario starts")
    local lifetime = assert(f.parent.lifespans[1])
    check(lifetime == 16, "parent lifetime is bounded to 16 game seconds")
    f.paused = true
    f.advance(1000)
    check(f.meteor:tick(f.player, f.state, true) == nil and f.parent.destroy_calls == 0, "wall time during pause does not expire meteor")
    f.paused = false
    f.advance(lifetime, 0.5)
    check(f.meteor:tick(f.player, f.state, true) == nil, "slow game time does not expire at wall-time deadline")
    local child = f.actor("owned remnant")
    f.emit_spawn(f.parent, f.landed, child)
    f.meteor:tick(f.player, f.state, true)
    check(#child.lifespans == 1 and child.lifespans[1] == lifetime / 2, "remnant receives only remaining game-time budget")
    f.advance(lifetime / 2 - 0.1)
    check(f.meteor:tick(f.player, f.state, true) == nil and #child.lifespans == 1, "tick does not extend remnant lifetime")
    f.advance(0.1)
    check(f.meteor:tick(f.player, f.state, true) == "expired", "expiry occurs at bounded game-time deadline")
    check(f.meteor.active == nil and f.parent.destroy_calls == 1 and child.destroy_calls == 1, "expiry cleans both owned actors")
end)

for _, transition in ipairs({"run", "player", "state", "world", "invalid_player", "invalid_state"}) do
    scenario("cleanup on " .. transition .. " transition", function()
        local f = fixture({child_on_finish = true})
        check(f.meteor:start(f.player, f.state), transition .. " scenario starts")
        local player, state, in_run = f.player, f.state, true
        if transition == "run" then in_run = false
        elseif transition == "player" then player = object("new Charlie")
        elseif transition == "state" then state = object("new Arcade state")
        elseif transition == "world" then f.world = object("next scene")
        elseif transition == "invalid_player" then f.player._valid = false
        elseif transition == "invalid_state" then f.state._valid = false end
        check(f.meteor:tick(player, state, in_run) == "left_run", transition .. " transition ends lifecycle")
        check(f.meteor.active == nil and f.parent.destroy_calls == 1 and f.child.destroy_calls == 1,
            transition .. " transition removes owned parent and child")
        check(#f.unregistered == 2, transition .. " transition unregisters all native hooks")
    end)
end

scenario("parent completion without observed remnant aborts remaining batch", function()
    local f = fixture({count = 5})
    check(f.meteor:start(f.player, f.state), "natural-completion scenario starts")
    f.parent._valid = false
    check(f.meteor:tick(f.player, f.state, true) == "remnant_unobserved",
        "parent finishing without an observed child aborts the batch")
    check(#f.unregistered == 2 and f.parent.destroy_calls == 0, "natural completion unhooks without destroying dead actor")
    check(not f.meteor.batch and not f.meteor.active, "unobserved remnant clears all pending meteor state")
    f.advance(20)
    f.meteor:tick(f.player, f.state, true)
    check(f.begin_calls == 1, "unobserved remnant cannot be followed by more meteors")
    local warned = false
    for _, entry in ipairs(f.logs) do if entry:find("before its native remnant was observed", 1, true) then warned = true end end
    check(warned, "unobserved remnant logs the reason for cancellation")
end)

scenario("late callback cannot take ownership after cleanup", function()
    local f = fixture()
    check(f.meteor:start(f.player, f.state), "late-callback scenario starts")
    local old_parent, old_callback = f.parent, f.hooks[SPAWN].post
    f.meteor:stop("left_run")
    local unrelated = f.actor("late unrelated remnant")
    local ok = pcall(old_callback, param(f.statics), param(unrelated), param(old_parent), param(f.landed))
    check(ok and f.meteor.active == nil and unrelated.destroy_calls == 0, "late callback is harmless after stop")
    check(f.meteor:start(f.player, f.state), "new meteor starts after stop")
    old_callback(param(f.statics), param(unrelated), param(old_parent), param(f.landed))
    check(f.meteor.active.child == nil, "old flight callback cannot attach an actor to the new flight")
    f.meteor:stop("test cleanup")
    check(unrelated.destroy_calls == 0, "late actor never becomes cleanup-owned")
end)

for _, failure in ipairs({"load_missing", "load_throws", "spawn_nil", "spawn_invalid", "spawn_throws", "hook_throws", "timer_hook_throws", "finish_throws"}) do
    scenario("recover from " .. failure, function()
        local options = {[failure] = true, unloaded = failure:match("^load") ~= nil}
        local f = fixture(options)
        local ok, reason = f.meteor:start(f.player, f.state)
        local expected = failure:match("^load") and "asset_unavailable"
            or (failure == "spawn_nil" or failure == "spawn_invalid") and "spawn_blocked" or "spawn_failed"
        check(not ok and reason == expected, failure .. " returns a clean failure code")
        check(f.meteor.active == nil and f.meteor.batch == nil, failure .. " clears busy state and never starts a batch")
        check(f.hooks[SPAWN] == nil and f.hooks[TIMER] == nil, failure .. " leaves no owned hook")
        if f.parent then
            check(f.parent.destroy_calls == 1, failure .. " removes partial spawned parent")
        else
            check(#f.actors == 0, failure .. " creates no actors")
        end
        options[failure] = false
        check(f.meteor:start(f.player, f.state), failure .. " permits a later successful retry")
        f.meteor:stop("test cleanup")
    end)
end

scenario("runtime exception cleans ownership", function()
    local f = fixture({child_on_finish = true})
    check(f.meteor:start(f.player, f.state), "runtime-failure scenario starts")
    function f.player:GetWorld() error("world disappeared") end
    local reason = f.meteor:tick(f.player, f.state, true)
    check(reason and reason:match("^runtime_failed:"), "runtime error returns diagnostic completion")
    check(f.meteor.active == nil and f.parent.destroy_calls == 1 and f.child.destroy_calls == 1,
        "runtime failure removes both owned actors")
    check(#f.unregistered == 2, "runtime failure removes all hooks outside callback")
end)

io.stdout:write(string.format("%d meteor scenarios, %d checks, %d failures\n", scenarios, checks, failures))
os.exit(failures == 0 and 0 or 1)
