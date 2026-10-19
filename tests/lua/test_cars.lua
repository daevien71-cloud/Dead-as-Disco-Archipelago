-- Offline UE4SS contract tests; these do not verify Unreal rendering or damage.
-- Usage: lua tests/lua/test_cars.lua <repo root>
local root = assert(arg[1], "pass the repo root")
package.path = root .. "/mod/DeadAsDiscoAP/Scripts/?.lua;" .. package.path
local Cars = require("cars")
local BASE = "/Game/LevelPrototyping/Prototype_Blueprints/"
local CAR = BASE .. "BP_Prophet_Highway_Car.BP_Prophet_Highway_Car_C"
local WARNING = BASE .. "BP_CarWarningIndicator.BP_CarWarningIndicator_C"
local ROAD = {"Arrow_01", "Arrow_02", "Arrow_03", "Arrow_04", "Arrow_05", "Border_01", "Border_02"}
local checks, failures, scenarios, next_address = 0, 0, 0, 100

local function check(ok, message)
    checks = checks + 1
    if not ok then failures = failures + 1; io.stderr:write("FAIL: " .. message .. "\n") end
end
local function scenario(name, run)
    scenarios = scenarios + 1
    local ok, err = pcall(run)
    if not ok then failures = failures + 1; io.stderr:write("ERROR " .. name .. ": " .. tostring(err) .. "\n") end
end
local function approx(a, b) return type(a) == "number" and math.abs(a - b) < 0.001 end
local function vec(x, y, z) return {X=x, Y=y, Z=z} end
local function copy(v) return vec(v.X, v.Y, v.Z) end
local function object(name, fields)
    local o = fields or {}
    next_address = next_address + 1
    o._valid, o._address, o._name = true, next_address, name
    function o:IsValid() return self._valid end
    function o:GetAddress() return self._address end
    function o:GetFullName() return self._name end
    return o
end
local function transformed(t, point)
    local c, s = math.cos(math.rad(t.yaw)), math.sin(math.rad(t.yaw))
    return vec(t.location.X + point.X*t.scale.X*c - point.Y*t.scale.Y*s,
        t.location.Y + point.X*t.scale.X*s + point.Y*t.scale.Y*c,
        t.location.Z + point.Z*t.scale.Z)
end
local function fixture(options)
    options = options or {}
    local f = {time=100, paused=false, actors={}, cars={}, warnings={}, logs={}, notices={}, events={},
        loads={}, begin_calls=0, finish_calls=0, synthetic_damage_calls=0, native_starts=0}
    f.world, f.state = object("Arcade world"), object("Arcade state")
    f.position, f.yaw = vec(1000,2000,500), options.yaw or 0
    f.player = object("controlled Charlie", {
        CharacterMovement=object("movement", {MovementMode=1, UpdatedComponent=object("capsule")}),
        CapsuleComponent={GetScaledCapsuleHalfHeight=function() return 90 end},
    })
    function f.player:GetWorld() return f.world end
    function f.player:K2_GetActorLocation() return f.position end
    function f.player:K2_GetActorRotation() return {Yaw=f.yaw} end
    f.car_class, f.warning_class = object(CAR), object(WARNING)
    f.classes = {[CAR]=f.car_class, [WARNING]=f.warning_class}
    if options.unloaded then f.classes = {} end

    local function component(actor, name, local_position, extent, parent, kind)
        local c = object(name, {actor=actor, local_position=local_position, extent=extent, parent=parent, kind=kind})
        function c:GetAttachParent() return self.parent end
        function c:GetLocalBounds(lower, upper)
            for _, axis in ipairs({"X","Y","Z"}) do lower[axis],upper[axis]=-self.extent[axis],self.extent[axis] end
            if options.bad_warning_bounds and not actor.is_car then upper.X=lower.X end
        end
        function c:K2_GetComponentToWorld()
            local t = {location=transformed(actor.transform,self.local_position), yaw=actor.transform.yaw, scale=copy(actor.transform.scale)}
            if options.bad_axis then t.yaw = t.yaw + 90 end
            if options.scaled_axis then t.scale.X = 2 end
            if options.absolute_root_rotation and self==actor.root then t.yaw=0 end
            if options.warning_absolute and not actor.is_car then
                t.location=vec(actor.transform.location.X+self.local_position.X,actor.transform.location.Y+self.local_position.Y,
                    actor.transform.location.Z+self.local_position.Z)
                t.yaw,t.scale=0,vec(1,1,1)
            end
            return t
        end
        return c
    end

    function f.world_bounds(c)
        local local_position = copy(c.local_position)
        if c.kind == "train" then local_position = copy(c.actor.Train.RelativeLocation)
        elseif c.kind == "collider" then
            local train = c.actor.Train.RelativeLocation
            local_position = vec(train.X+local_position.X, train.Y+local_position.Y, train.Z+local_position.Z)
        end
        local origin = transformed(c.actor.transform, local_position)
        local t, e = c.actor.transform, c.extent
        local cs, sn = math.abs(math.cos(math.rad(t.yaw))), math.abs(math.sin(math.rad(t.yaw)))
        local extent = vec(e.X*t.scale.X*cs+e.Y*t.scale.Y*sn, e.X*t.scale.X*sn+e.Y*t.scale.Y*cs, e.Z*t.scale.Z)
        if options.invalid_bounds then extent.X = 0 end
        if options.nan_bounds then origin.X = 0/0 end
        return origin, extent
    end

    local function actor(is_car, t)
        local a = object(is_car and "native car" or "native lane indicator", {
            is_car=is_car, transform=t, collision=true, hidden=false, destroy_calls=0, starts={}, warnings={},
        })
        a.ordinal = #f.actors + 1
        function a:IsActorBeingDestroyed() return self._destroying == true end
        function a:K2_GetActorLocation() return self.transform.location end
        function a:K2_SetActorTransform(new_t, sweep, hit, teleport)
            assert(sweep == false and teleport == true, "placement uses no sweep and teleports")
            if options.place_fails and self.ordinal == options.place_fails then return false end
            self.transform = new_t
            return true
        end
        function a:SetActorEnableCollision(enabled)
            if options.cleanup_collision_throws and not enabled then error("native collision call unavailable") end
            self.collision = enabled
        end
        function a:GetActorEnableCollision()
            if options.collision_read_nil then return nil end
            return self.collision
        end
        function a:SetActorHiddenInGame(hidden)
            if options.cleanup_hidden_throws and hidden then error("native visibility call unavailable") end
            self.hidden = hidden
        end
        function a:SetLifeSpan(seconds) self.lifespan=seconds; self.expires=f.time+seconds end
        function a:K2_DestroyActor()
            self.destroy_calls = self.destroy_calls + 1
            if options.destroy_throws == true or options.destroy_throws == self.ordinal then error("native destroy unavailable") end
            if options.destroy_ignored == true or options.destroy_ignored == self.ordinal then return end
            self._destroying = true
            if not options.defer_gc then self._valid = false end
        end
        function a:HitCharacters() f.synthetic_damage_calls=f.synthetic_damage_calls+1; error("must use native overlaps") end
        if is_car then
            a.root = component(a, "car root", vec(0,0,0), vec(1,1,1), nil)
            a.Train = component(a, "Train", vec(120,20,60), vec(160,70,60), a.root, "train")
            a.Train.RelativeLocation = vec(120,20,60)
            a.HitCollisionSphere = component(a, "HitCollisionSphere", vec(-20,20,0), vec(200,95,65), a.Train, "collider")
            a.BodyCollisionBox = component(a, "BodyCollisionBox", vec(5,-30,-5), vec(180,80,55), a.Train, "collider")
            if options.bad_hierarchy then a.BodyCollisionBox.parent = object("unrelated scene component") end
            if options.absolute_collider then a.BodyCollisionBox.bAbsoluteRotation = true end
            if options.absolute_train then a.Train.bAbsoluteLocation = true end
            if options.missing_train then a.Train._valid = false end
            if options.huge_car then a.HitCollisionSphere.extent.Y = 1300 end
            a.DamageToPlayer, a.DamageToEnemy = 30, 70
            if options.zero_player_damage then a.DamageToPlayer = 0 end
            if options.zero_enemy_damage then a.DamageToEnemy = 0 end
            a.PlayersHit, a.EnemiesHit = {"previous player"}, {"previous enemy"}
            function a:SetWarning(early, near)
                self.warnings[#self.warnings+1] = {at=f.time, early=early, near=near}
                if options.warning_throws then error("native warning unavailable") end
                if not options.warning_ignored then
                    self.BP_WarningIndicator.bEarlyWarningOn = early
                    self.BP_WarningIndicator.bNearHitOn = near
                end
            end
            function a:StartCar()
                f.native_starts = f.native_starts+1
                self.starts[#self.starts+1] = f.time
                self.PlayersHit, self.EnemiesHit = {}, {}
                if options.start_refused == true or options.start_refused == self.ordinal then return end
                self.IsMoveActive = true
                self.drive_at = f.time
                -- Native StartCar changes movement/hit bookkeeping, not actor collision or placement.
            end
            f.cars[#f.cars+1] = a
        else
            for i, name in ipairs(ROAD) do
                local position, extent
                if i <= 5 then position, extent = vec((i-3)*200,0,0), vec(100,20,1)
                else position, extent = vec(0,i==6 and -60 or 60,0), vec(500,5,1) end
                if options.warning_long_y then position.X,position.Y=position.Y,position.X;extent.X,extent.Y=extent.Y,extent.X end
                a[name] = component(a, name, position, extent, nil)
            end
            a.TrainArrowLeft, a.BorderLeftMaterial = object("arrow dynamic material"), object("border dynamic material")
            if options.missing_material then a.BorderLeftMaterial._valid = false end
            if options.missing_road then a.Border_02._valid = false end
            f.warnings[#f.warnings+1] = a
        end
        f.actors[#f.actors+1] = a
        return a
    end

    f.statics = object("GameplayStatics")
    function f.statics:IsGamePaused() return f.paused end
    function f.statics:GetTimeSeconds() return f.time end
    function f.statics:BeginDeferredActorSpawnFromClass(context, cls, t, collision, owner, scale)
        f.begin_calls = f.begin_calls+1
        assert(context == f.player and owner == nil and scale == 1 and collision == 1, "native deferred spawn contract")
        assert(cls == f.car_class or cls == f.warning_class, "only native cars and warnings are spawned")
        if options.spawn_fails == f.begin_calls then return nil end
        return actor(cls == f.car_class, t)
    end
    function f.statics:FinishSpawningActor(a, t, scale)
        f.finish_calls = f.finish_calls+1
        assert(a.transform == t and scale == 1, "finish receives the deferred transform")
        assert(not a.collision, "collision disabled before native BeginPlay")
        if a.is_car then
            assert(a.ShouldLoop == false and a["ResetPositionOnEnd?"] == false, "loop/reset disabled before native BeginPlay")
            assert(a.Vector.X == 1 and a.Vector.Y == 0 and a.Vector.Z == 0 and a.Speed == 1600 and a.LoopDistance == 4000,
                "native movement configured before BeginPlay")
            assert(a.StartTag.TagName == "None" and a.WarningYellowStartTag.TagName == "None"
                and a.WarningRedStartTag.TagName == "None" and a.BP_CarLaneManager == nil,
                "native car initialized without boss lane manager or tag triggers")
            a.IsMoveActive = true -- invalid StartTag's synchronous BeginPlay activation
            a.load_at = f.time+(options.load_delay or 0.25)
        end
        if options.finish_fails == f.finish_calls then error("native finish failed") end
        if options.finish_invalid == f.finish_calls then a._valid = false end
        return a
    end
    local mathlib, system = object("KismetMathLibrary"), object("KismetSystemLibrary")
    function mathlib:MakeTransform(location, rotation, scale)
        return {location=copy(location), yaw=rotation.Yaw, scale=copy(scale)}
    end
    function mathlib:TransformLocation(t, point) return transformed(t, point) end
    function system:GetComponentBounds(c, origin, extent)
        local o, e = f.world_bounds(c)
        for _, axis in ipairs({"X","Y","Z"}) do origin[axis],extent[axis] = o[axis],e[axis] end
    end
    StaticFindObject = function(path)
        if path == "/Script/Engine.Default__GameplayStatics" then return f.statics end
        if path == "/Script/Engine.Default__KismetMathLibrary" then return mathlib end
        if path == "/Script/Engine.Default__KismetSystemLibrary" then return system end
        assert(not path:find("Combat"), "adapter must not call synthetic damage APIs")
        return f.classes[path]
    end
    LoadAsset = function(path)
        f.loads[#f.loads+1] = path
        if options.load_throws then error("native asset load failed") end
        if options.load_missing then return end
        if path == CAR:match("^(.-)%.") then f.classes[CAR] = f.car_class end
        if path == WARNING:match("^(.-)%.") then f.classes[WARNING] = f.warning_class end
    end
    FName = function(name) return name end
    function f.advance(seconds)
        if f.paused then return end
        f.time = f.time+seconds
        for _, a in ipairs(f.actors) do
            if a._valid and not a._destroying and a.is_car then
                if not a.LevelLoaded and a.load_at and f.time >= a.load_at and not options.load_never then
                    a.LevelLoaded, a.StartLocation = true, copy(a.Train.RelativeLocation)
                    if options.bad_start_location then a.StartLocation.X=a.StartLocation.X+20 end
                end
                if a.IsMoveActive and a.drive_at then
                    local elapsed = f.time-a.drive_at
                    a.Train.RelativeLocation.X = a.StartLocation.X + math.min(elapsed,2.5)*a.Speed
                    if elapsed >= 2.5 and not options.movement_stuck then a.IsMoveActive=false end
                end
            end
            if a._valid and a.expires and f.time >= a.expires then a._valid=false;a._destroying=true end
        end
    end
    function f.tick(seconds)
        if seconds then f.advance(seconds) end
        return f.adapter:tick(f.player,f.state,true)
    end
    function f.start(probe)
        return f.adapter:start(f.player,f.state,function(index,total)
            f.notices[#f.notices+1] = {index=index,total=total,at=f.time}
        end,probe)
    end
    function f.begin_driving()
        f.tick(options.load_delay or 0.25)
        f.tick(1.5)
        f.tick(0.5)
    end
    function f.live_count()
        local n=0; for _, a in ipairs(f.actors) do if a._valid and not a._destroying then n=n+1 end end; return n
    end
    f.adapter = Cars.new(function(message) f.logs[#f.logs+1]=message end)
    return f
end

scenario("native deferred initialization and measured geometry", function()
    local f=fixture({unloaded=true})
    local ok,sets=f.start()
    check(ok and sets==2 and #f.cars==3 and #f.warnings==3 and #f.loads==2,"normal trap prepares exactly three native cars and three warnings")
    check(#f.notices==1 and f.notices[1].index==1 and f.notices[1].total==2,"set is announced after all native actors are prepared")
    for i,car in ipairs(f.cars) do
        local center,extent=f.world_bounds(car.Train)
        check(approx(center.X,-1000) and approx(center.Y,2000+(i-2)*490) and approx(center.Z-extent.Z,415),
            "measured car footprint positions lane "..i.." above ground with correct lateral clearance")
        check(not car.IsMoveActive and not car.collision and car.DamageToPlayer==30 and car.DamageToEnemy==70,
            "native car "..i.." is frozen with original damage unchanged")
        check(car.lifespan==14 and car.BP_WarningIndicator==f.warnings[i] and car.bPassedWarningEnd,
            "car owns its bounded native warning and suppresses premature warning-end logic")
        local w=f.warnings[i]
        check(approx(w.transform.scale.X,4.52) and approx(w.transform.scale.Y,310/130) and approx(w.transform.location.Z,414),
            "native warning fits complete swept footprint for lane "..i)
    end
    check(f.synthetic_damage_calls==0 and f.native_starts==0,"preparation uses neither substitute damage nor premature StartCar")
    f.adapter:stop("test cleanup")
    check(f.live_count()==0,"all six prepared actors are owned and removed")
end)

scenario("route follows actor yaw without swapping measured dimensions", function()
    local f=fixture({yaw=90})
    check(f.start(),"rotated route starts")
    for i,car in ipairs(f.cars) do
        local center=f.world_bounds(car.Train)
        check(approx(center.X,1000-(i-2)*490) and approx(center.Y,0) and car.transform.yaw==90,
            "lane "..i.." starts two thousand units behind player along rotated native movement axis")
        check(f.warnings[i].transform.yaw==90,"warning shares exact route yaw")
    end
    f.adapter:stop("test cleanup")
end)

scenario("diagonal route retains actual lane width and swept length",function()
    local f=fixture({yaw=45});check(f.start(),"diagonal route starts")
    for i,car in ipairs(f.cars) do
        local center=f.world_bounds(car.Train);local lane=(i-2)*490
        check(approx(center.X,1000+(-2000-lane)/math.sqrt(2)) and approx(center.Y,2000+(-2000+lane)/math.sqrt(2)),
            "diagonal lane center follows rotated native route")
        check(approx(f.warnings[i].transform.scale.X,4.52) and approx(f.warnings[i].transform.scale.Y,310/130),
            "diagonal warning scaling uses projected mesh corners rather than world AABB width")
    end
    f.adapter:stop("test cleanup")
end)

scenario("absolute movement-parent rotation fails post-placement readback",function()
    local f=fixture({yaw=90,absolute_root_rotation=true});local ok,reason=f.start()
    check(not ok and reason=="spawn_failed" and f.live_count()==0,"axis that passes initial pose but ignores route yaw is rejected")
    check(f.native_starts==0 and #f.notices==0,"unsafe rotated route never starts or advertises")
end)

scenario("delayed LevelLoaded precedes complete warning and near-hit timing", function()
    local f=fixture({load_delay=1.5})
    check(f.start(true),"delayed one-car probe starts")
    local car=f.cars[1]
    f.tick(1.49)
    check(f.native_starts==0 and not car.LevelLoaded and not car.collision and car.Train.RelativeLocation.X==120,
        "latent initialization never allows movement or collision")
    f.tick(0.01)
    check(car.LevelLoaded and f.adapter.active.warn_until==103.5,"full two-second warning begins only after LevelLoaded")
    f.tick(1.49)
    check(not f.warnings[1].bNearHitOn and f.native_starts==0,"early warning persists until final half-second")
    f.tick(0.01)
    check(f.warnings[1].bNearHitOn and f.native_starts==0 and not car.collision,"near-hit warning begins half-second before movement")
    f.tick(0.49)
    check(f.native_starts==0 and car.Train.RelativeLocation.X==120,"car stays frozen for the whole warning")
    f.tick(0.01)
    check(f.native_starts==1 and car.IsMoveActive and car.collision and #car.PlayersHit==0 and #car.EnemiesHit==0,
        "native StartCar clears hit bookkeeping and collision is enabled only after full warning")
    check(approx(car.starts[1],103.5) and f.synthetic_damage_calls==0,"launch timing is exact and damage remains native")
    check(f.tick(2.5)=="native_finished" and f.live_count()==0,"native movement stops after 2.5 seconds and owned actors are cleaned")
end)

scenario("two sets serialize all six actors and enforce a one-second gap", function()
    local f=fixture()
    check(f.start(),"two-set trap starts")
    f.begin_driving()
    check(f.native_starts==3,"first set starts three native cars")
    f.tick(2.49)
    check(f.begin_calls==6 and f.live_count()==6,"second set never overlaps the first moving set")
    f.tick(0.01)
    check(f.live_count()==0 and f.adapter.active.phase=="between","all six first-set actors are invalid before between-set phase")
    f.tick(0.99)
    check(f.begin_calls==6,"second set waits at least one game second")
    f.tick(0.01)
    check(f.begin_calls==12 and f.live_count()==6 and #f.notices==2,"second set prepares only after complete cleanup and gap")
    f.begin_driving()
    check(f.tick(2.5)=="native_finished" and f.live_count()==0 and f.native_starts==6,"two sets finish with exactly six native car launches")
end)

scenario("destroyed actors awaiting garbage collection do not cause false quarantine",function()
    local f=fixture({defer_gc=true});check(f.start(),"deferred-GC batch starts")
    f.begin_driving();f.tick(2.5)
    local removed=true
    for _,a in ipairs(f.actors) do removed=removed and a:IsValid() and a:IsActorBeingDestroyed() and a.destroy_calls==1 end
    check(removed and f.live_count()==0 and #f.adapter.stranded==0,
        "native destruction counts as removal even while UObject wrappers remain valid")
    f.tick(1)
    check(f.begin_calls==12 and f.live_count()==6,"second set is admitted after removal and gap without waiting for GC")
    f.adapter:stop("left_run")
    check(f.live_count()==0 and #f.adapter.stranded==0,"deferred-GC cleanup leaves no live actor quarantine")
end)

scenario("each set independently receives two seconds of warning and half-second red",function()
    local f=fixture();check(f.start(),"two-warning batch starts")
    for set=1,2 do
        f.tick(0.25)
        local loaded_at=f.time
        local first=(set-1)*3+1
        check(f.native_starts==(set-1)*3,"set "..set.." remains stationary when latent initialization completes")
        f.tick(1.49)
        check(f.native_starts==(set-1)*3 and not f.warnings[first].bNearHitOn,"set "..set.." receives its own early-warning interval")
        f.tick(0.01)
        check(f.warnings[first].bNearHitOn and f.native_starts==(set-1)*3,"set "..set.." turns red without moving")
        local red_at=f.time
        f.tick(0.49)
        check(f.native_starts==(set-1)*3,"set "..set.." cannot move before red warning lasts half a second")
        f.tick(0.01)
        check(f.native_starts==set*3 and approx(f.cars[first].starts[1]-loaded_at,2)
            and approx(f.cars[first].starts[1]-red_at,0.5),"set "..set.." starts only after both warning durations")
        local reason=f.tick(2.5)
        if set==1 then check(reason==nil and f.live_count()==0,"first set is fully removed before next warning");f.tick(1)
        else check(reason=="native_finished","second fully warned set completes batch") end
    end
end)

scenario("frame hitch past warning deadline still presents half-second red",function()
    local f=fixture();check(f.start(true),"hitch probe starts")
    f.tick(0.25)
    f.tick(3)
    check(f.native_starts==0 and f.warnings[1].bNearHitOn and not f.cars[1].collision,
        "hitch cannot jump directly from early warning to moving car")
    local red_at=f.time
    f.tick(0.49)
    check(f.native_starts==0,"late red phase receives its own full half-second")
    f.tick(0.01)
    check(f.native_starts==1 and approx(f.cars[1].starts[1]-red_at,0.5),"hitch-delayed launch begins only after red interval")
    f.adapter:stop("test cleanup")
end)

for _,sample in ipairs({{value=true,sets=1,cars=1},{value=false,sets=2,cars=3},{value="true",sets=2,cars=3},{value=1,sets=2,cars=3}}) do
    scenario("strict probe flag "..tostring(sample.value).." "..type(sample.value),function()
        local f=fixture(); local ok,sets=f.start(sample.value)
        check(ok and sets==sample.sets and #f.cars==sample.cars and #f.warnings==sample.cars,"only boolean true selects the single-car probe")
        f.adapter:stop("test cleanup")
    end)
end

for _,failure in ipairs({"invalid_bounds","nan_bounds","missing_material","missing_road","missing_train","bad_hierarchy","absolute_collider","absolute_train","bad_axis","scaled_axis","huge_car","zero_player_damage","zero_enemy_damage","warning_throws","warning_ignored","warning_absolute","warning_long_y","collision_read_nil"}) do
    scenario("reject unsafe native setup "..failure,function()
        local f=fixture({[failure]=true}); local ok,reason=f.start()
        check(not ok and reason=="spawn_failed",failure.." fails closed with clean code")
        check(not f.adapter.active and f.live_count()==0 and f.native_starts==0,failure.." rolls back every partial native actor")
    end)
end

for _,stage in ipairs({{spawn_fails=2},{spawn_fails=4},{finish_fails=2},{finish_fails=4},{finish_invalid=2},{place_fails=1},{place_fails=4}}) do
    scenario("partial native setup rollback",function()
        local f=fixture(stage); local ok,reason=f.start()
        check(not ok and (reason=="spawn_failed" or reason=="spawn_blocked"),"partial setup failure reports clean failure")
        check(f.live_count()==0 and not f.adapter.active and #f.notices==0,"partial setup owns and removes actors before reporting failure")
    end)
end

for _,failure in ipairs({"load_missing","load_throws"}) do
    scenario("asset failure "..failure,function()
        local f=fixture({[failure]=true,unloaded=true});local ok,reason=f.start()
        check(not ok and reason=="asset_unavailable" and f.begin_calls==0,"asset failure never spawns an incomplete set")
    end)
end

scenario("cleanup attempts independent actions and quarantines survivors",function()
    local options={};local f=fixture(options)
    check(f.start(),"cleanup scenario starts")
    options.cleanup_collision_throws,options.cleanup_hidden_throws=true,true
    f.adapter:stop("left_run")
    check(f.live_count()==0 and #f.adapter.stranded==0,"failed collision/visibility calls cannot prevent destruction")
    options.cleanup_collision_throws,options.cleanup_hidden_throws=nil,nil
    check(f.start(),"later set may start after complete cleanup")
    options.destroy_throws=f.cars[4].ordinal
    f.adapter:stop("left_run")
    check(f.live_count()==1 and #f.adapter.stranded==1 and f.adapter.stranded[1].hidden and not f.adapter.stranded[1].collision,
        "failed destruction retains exact surviving actor disabled and hidden")
    local before=f.begin_calls;local ok,reason=f.start()
    check(not ok and reason=="busy" and f.begin_calls==before,"quarantine temporarily blocks new native actors while cleanup still fails")
    options.destroy_throws=nil
    check(f.adapter:ready(f.player) and f.live_count()==0 and #f.adapter.stranded==0,"readiness retries and clears quarantine only after destruction succeeds")
end)

scenario("ignored destruction cannot allow second set",function()
    local options={};local f=fixture(options)
    check(f.start(),"survivor batch starts")
    f.begin_driving();options.destroy_ignored=f.warnings[2].ordinal
    check(f.tick(2.5)=="cleanup_failed","silent native destroy failure aborts batch")
    check(f.begin_calls==6 and #f.adapter.stranded==1 and not f.adapter.active,"no second set exists while a first-set warning survives")
    f.advance(2);local ok,reason=f.start()
    check(not ok and reason=="busy" and f.begin_calls==6,"survivor temporarily blocks new batches without consuming another item")
    f.advance(20)
    check(f.adapter:ready(f.player) and #f.adapter.stranded==0,"native lifespan can clear quarantined actors without a world sweep")
end)

scenario("warning disappearance during rush aborts the owned set",function()
    local f=fixture();check(f.start(),"warning-loss batch starts")
    f.begin_driving();f.warnings[2]._valid=false
    check(f.tick()=="runtime_failed" and f.live_count()==0 and not f.adapter.active,
        "missing live route warning immediately cleans all moving cars")
    f.tick(10)
    check(f.begin_calls==6,"warning failure cannot launch another set")
end)

scenario("second-set partial setup failure removes its new actors",function()
    local options={};local f=fixture(options);check(f.start(),"second-set failure batch starts")
    f.begin_driving();f.tick(2.5);options.finish_fails=8
    check(f.tick(1)=="runtime_failed" and f.live_count()==0 and not f.adapter.active,
        "failure after first set completion rolls back only newly owned second-set actors")
    check(#f.notices==1 and f.native_starts==3,"failed second set is neither announced nor launched")
end)

scenario("partial spawn with failed rollback is quarantined",function()
    local f=fixture({finish_fails=2,destroy_throws=1})
    local ok,reason=f.start()
    check(not ok and reason=="cleanup_failed" and not f.adapter.active and #f.adapter.stranded==1,"failed startup preserves rollback survivor ownership")
    local before=f.begin_calls;ok,reason=f.start()
    check(not ok and reason=="busy" and f.begin_calls==before,"failed-start survivor temporarily prevents a retry pileup")
end)

scenario("init, set and batch caps use bounded game time",function()
    local f=fixture({load_never=true});check(f.start(true),"initialization cap starts")
    check(f.tick(2)=="initialization_timeout" and f.live_count()==0,"latent initialization cannot exceed two game seconds")
    f=fixture();check(f.start(),"warning cap starts")
    f.state.bWaveClearedRequested=true
    check(f.tick(12)=="set_expired" and f.live_count()==0,"wave downtime cannot preserve one set indefinitely")
    f=fixture();check(f.start(),"batch cap starts")
    f.begin_driving();f.tick(2.5);f.state.bWaveClearedRequested=true
    f.time=140
    check(f.tick()=="batch_expired" and not f.adapter.active and f.live_count()==0,"between-set downtime cannot outlive whole-batch cap")
end)

scenario("native movement that does not stop is bounded",function()
    local f=fixture({movement_stuck=true});check(f.start(true),"stuck movement probe starts")
    f.begin_driving();f.tick(3.49)
    check(f.live_count()==2,"running native movement is retained through its grace interval")
    check(f.tick(0.01)=="native_finished" and f.live_count()==0,"movement beyond native duration plus grace is forcibly cleaned")
end)

scenario("pause does not spend warning or cap budget",function()
    local f=fixture();check(f.start(true),"pause scenario starts")
    f.tick(0.25);f.tick(1);f.paused=true
    f.tick(1000)
    check(f.native_starts==0 and f.time==101.25 and f.adapter.active,"paused wall time neither launches nor expires a car")
    f.paused=false;f.tick(0.49)
    check(f.native_starts==0,"unpause preserves remaining warning time")
    f.tick(0.01);f.tick(0.49)
    check(f.native_starts==0,"resumed red phase remains visible before movement")
    f.tick(0.01)
    check(f.native_starts==1,"remaining game-time warning completes after unpause")
    f.adapter:stop("test cleanup")
end)

scenario("downtime polls reset warning once and resume full warning",function()
    local f=fixture();check(f.start(),"downtime polling scenario starts")
    f.tick(0.25);f.tick(1.5)
    local function all_warning_counts(expected)
        for _,car in ipairs(f.cars) do if #car.warnings~=expected then return false end end
        return true
    end
    check(all_warning_counts(2) and f.warnings[1].bNearHitOn,"each lane enters red before downtime")
    f.state.bWaveClearedRequested=true;f.tick(0.1)
    check(all_warning_counts(3) and not f.warnings[1].bNearHitOn,"downtime restores early warning once per lane")
    for _=1,5 do f.tick(0.1) end
    check(all_warning_counts(3) and f.native_starts==0,"repeated downtime polls make no additional native warning calls")
    f.state.bWaveClearedRequested=false;f.tick()
    local resumed_at=f.time
    f.tick(1.49)
    check(all_warning_counts(3) and f.native_starts==0 and not f.warnings[1].bNearHitOn,
        "resumed combat receives a fresh early-warning interval")
    f.tick(0.01)
    local red_at=f.time
    check(all_warning_counts(4) and f.warnings[1].bNearHitOn and f.native_starts==0,
        "resumed warning turns red once per lane without launching")
    f.tick(0.49)
    check(f.native_starts==0,"resumed red warning lasts at least half a second")
    f.tick(0.01)
    check(f.native_starts==3 and approx(f.cars[1].starts[1]-resumed_at,2)
        and approx(f.cars[1].starts[1]-red_at,0.5),"resumed launch honors full warning and red durations")
    f.adapter:stop("test cleanup")
end)

scenario("downtime restarts full warning and postpones second set",function()
    local f=fixture();check(f.start(),"downtime scenario starts")
    f.tick(0.25);f.tick(1.75);f.state.bWaveClearedRequested=true;f.tick(0.25)
    check(f.native_starts==0 and not f.warnings[1].bNearHitOn,"wave downtime cancels imminent launch and restores early warning")
    f.state.bWaveClearedRequested=false;f.tick();f.tick(1.49)
    check(f.native_starts==0,"resumed combat receives a fresh full warning")
    f.tick(0.01);f.tick(0.5);f.tick(2.5)
    f.player.CharacterMovement.MovementMode=3;f.tick(1)
    check(f.begin_calls==6,"second set waits while player is airborne")
    f.player.CharacterMovement.MovementMode=1;f.state.bWaveClearedRequested=true;f.tick()
    check(f.begin_calls==6,"second set waits during wave downtime")
    f.state.bWaveClearedRequested=false;f.tick()
    check(f.begin_calls==12,"second set resumes only after valid grounded combat")
    f.adapter:stop("test cleanup")
end)

scenario("initial readiness rejects pause, airborne and invalid components",function()
    local f=fixture();f.paused=true;local ok,reason=f.start()
    check(not ok and reason=="paused" and f.begin_calls==0,"paused start cannot spawn")
    f.paused=false;f.player.CharacterMovement.MovementMode=3;ok,reason=f.start()
    check(not ok and reason=="airborne" and f.begin_calls==0,"airborne start cannot spawn")
    f.player.CharacterMovement.MovementMode=1;f.player.CharacterMovement.UpdatedComponent._valid=false;ok,reason=f.start()
    check(not ok and reason=="airborne","walking with invalid updated component cannot spawn")
    f.player.CharacterMovement.UpdatedComponent._valid=true;f.state.bWaveClearedRequested=true;ok,reason=f.start()
    check(not ok and reason=="downtime" and f.begin_calls==0,"initial wave downtime cannot spawn")
end)

for _,stage in ipairs({"warning","between"}) do
    for _,change in ipairs({"run","player","state","world","invalid_player","invalid_state"}) do
        scenario(stage.." identity transition "..change,function()
            local f=fixture();check(f.start(),"transition scenario starts")
            if stage=="between" then f.begin_driving();f.tick(2.5) end
            local p,state,in_run=f.player,f.state,true
            if change=="run" then in_run=false
            elseif change=="player" then p=object("replacement player")
            elseif change=="state" then state=object("replacement Arcade state")
            elseif change=="world" then f.world=object("next world")
            elseif change=="invalid_player" then f.player._valid=false
            else f.state._valid=false end
            check(f.adapter:tick(p,state,in_run)=="left_run" and not f.adapter.active and f.live_count()==0,
                "transition removes owned set and pending next set")
            local before=f.begin_calls;f.advance(10);f.adapter:tick(p,state,in_run)
            check(f.begin_calls==before,"cancelled car batch cannot resume")
        end)
    end
end

for _,corruption in ipairs({"moved","collision","active","vector","loop","origin","nil_active","nil_loop","nil_passed"}) do
    scenario("unexpected native warning-time mutation "..corruption,function()
        local f=fixture();check(f.start(true),"mutation scenario starts")
        f.tick(0.25);local car=f.cars[1]
        if corruption=="moved" then car.Train.RelativeLocation.X=car.Train.RelativeLocation.X+2
        elseif corruption=="collision" then car.collision=true
        elseif corruption=="active" then car.IsMoveActive=true
        elseif corruption=="vector" then car.Vector.Y=1
        elseif corruption=="loop" then car.ShouldLoop=true
        elseif corruption=="origin" then car.StartLocation.X=car.StartLocation.X+2
        elseif corruption=="nil_active" then car.IsMoveActive=nil
        elseif corruption=="nil_loop" then car.ShouldLoop=nil
        else car.bPassedWarningEnd=nil end
        check(f.tick()=="runtime_failed" and f.live_count()==0 and f.native_starts==0,
            "changed native state fails closed before movement can launch")
    end)
end

scenario("native StartCar refusal rolls back the whole set",function()
    local f=fixture({start_refused=2});check(f.start(),"refused launch scenario starts")
    f.tick(0.25);f.tick(1.5)
    check(f.tick(0.5)=="runtime_failed" and f.live_count()==0 and not f.adapter.active and f.native_starts==2,
        "failure after first car activates still removes all cars and warnings")
end)

io.stdout:write(string.format("%d car scenarios, %d checks, %d failures\n",scenarios,checks,failures))
os.exit(failures==0 and 0 or 1)
