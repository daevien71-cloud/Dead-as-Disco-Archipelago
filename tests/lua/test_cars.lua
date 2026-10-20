-- Offline UE4SS contract tests; these do not verify Unreal rendering or damage.
-- Usage: lua tests/lua/test_cars.lua <repo root>
local root = assert(arg[1], "pass the repo root")
package.path = root .. "/mod/DeadAsDiscoAP/Scripts/?.lua;" .. package.path
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
local function composed(relative, parent)
    -- UE5.7 TransformNonVectorized.h:1341-1343 and SceneComponent.cpp:720:
    -- positive scales multiply componentwise before the combined rotation.
    -- This is FTransform composition, not an affine matrix containing shear.
    return {location=transformed(parent,relative.location), yaw=parent.yaw+relative.yaw,
        scale=vec(relative.scale.X*parent.scale.X,relative.scale.Y*parent.scale.Y,relative.scale.Z*parent.scale.Z)}
end
local function warning_bounds_in_route(warning, origin, yaw)
    local lo,hi=vec(math.huge,math.huge,math.huge),vec(-math.huge,-math.huge,-math.huge)
    local c,s=math.cos(math.rad(yaw)),math.sin(math.rad(yaw))
    for _,name in ipairs(ROAD) do
        local mesh=warning[name]
        for _,x in ipairs({-mesh.extent.X,mesh.extent.X}) do
            for _,y in ipairs({-mesh.extent.Y,mesh.extent.Y}) do
                for _,z in ipairs({-mesh.extent.Z,mesh.extent.Z}) do
                    local p=transformed(mesh:K2_GetComponentToWorld(),vec(x,y,z))
                    local dx,dy=p.X-origin.X,p.Y-origin.Y
                    local route=vec(dx*c+dy*s,-dx*s+dy*c,p.Z-origin.Z)
                    for _,axis in ipairs({"X","Y","Z"}) do lo[axis]=math.min(lo[axis],route[axis]);hi[axis]=math.max(hi[axis],route[axis]) end
                end
            end
        end
    end
    return lo,hi
end
local function fixture(options)
    options = options or {}
    local f = {time=100, paused=false, actors={}, cars={}, warnings={}, logs={}, notices={}, events={},
        loads={}, begin_calls=0, finish_calls=0, synthetic_damage_calls=0, native_starts=0, validity_calls=0}
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
        local c = object(name, {actor=actor, extent=extent, parent=parent, kind=kind,
            RelativeLocation=copy(local_position), RelativeScale3D=vec(1,1,1), RelativeRotation={Pitch=0,Yaw=0,Roll=0}})
        function c:GetAttachParent() return self.parent end
        function c:GetLocalBounds(lower, upper)
            for _, axis in ipairs({"X","Y","Z"}) do lower[axis],upper[axis]=-self.extent[axis],self.extent[axis] end
            if options.bad_warning_bounds and not actor.is_car then upper.X=lower.X end
        end
        function c:K2_GetComponentToWorld()
            local parent_world=self.parent and self.parent:K2_GetComponentToWorld() or actor.transform
            local t=composed({location=self.RelativeLocation,yaw=self.RelativeRotation.Yaw,scale=self.RelativeScale3D},parent_world)
            if self.bAbsoluteLocation then t.location=copy(self.RelativeLocation) end
            if self.bAbsoluteRotation then t.yaw=self.RelativeRotation.Yaw end
            if self.bAbsoluteScale then t.scale=copy(self.RelativeScale3D) end
            if options.bad_axis then t.yaw = t.yaw + 90 end
            if options.scaled_axis then t.scale.X = 2 end
            if options.absolute_root_rotation and self==actor.root then t.yaw=0 end
            if options.warning_absolute and not actor.is_car then
                t.location=vec(actor.transform.location.X+self.RelativeLocation.X,actor.transform.location.Y+self.RelativeLocation.Y,
                    actor.transform.location.Z+self.RelativeLocation.Z)
                t.yaw,t.scale=0,vec(1,1,1)
            end
            return t
        end
        return c
    end

    function f.world_bounds(c)
        local t, e = c:K2_GetComponentToWorld(), c.extent
        local origin=copy(t.location)
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
        function a:IsActorBeingDestroyed()
            if options.refuse_destroyed_events and self._garbage then return false end
            return self._destroying == true
        end
        function a:K2_GetActorLocation() return self.transform.location end
        function a:GetActorScale3D() return copy(self.transform.scale) end
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
            self._destroying, self._garbage = true, true
            if not options.defer_gc then self._valid = false end
        end
        function a:HitCharacters() f.synthetic_damage_calls=f.synthetic_damage_calls+1; error("must use native overlaps") end
        if is_car then
            a.root = component(a, "car root", vec(0,0,0), vec(1,1,1), nil)
            a.Train = component(a, "Train", vec(120,20,60), vec(160,70,60), a.root, "train")
            a.Train.RelativeLocation = vec(120,20,60)
            if options.authored_train_scale then a.Train.RelativeScale3D=copy(options.authored_train_scale) end
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
                if options.warning_offset then
                    position=vec(position.X+options.warning_offset.X,position.Y+options.warning_offset.Y,position.Z+options.warning_offset.Z)
                end
                if options.rotated_road then extent=vec(extent.Y,extent.X,extent.Z) end
                a[name] = component(a, name, position, extent, nil)
                if options.rotated_road then a[name].RelativeRotation.Yaw=90 end
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
        assert(f.preflight_valid and f.preflight_nil,"native validity is preflighted on a live object and nil before any spawn")
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
        local authored_scale
        if a.is_car then authored_scale=options.authored_car_scale else authored_scale=options.authored_warning_scale end
        if authored_scale then a.transform={location=copy(t.location),yaw=t.yaw,scale=copy(authored_scale)} end
        if a.is_car then
            assert(a.ShouldLoop == false and a["ResetPositionOnEnd?"] == false, "loop/reset disabled before native BeginPlay")
            assert(a.Vector.X == 1 and a.Vector.Y == 0 and a.Vector.Z == 0 and type(a.Speed)=="number" and a.Speed>0 and a.LoopDistance == 4000,
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
    local native_validity = object("/Script/Engine.KismetSystemLibrary:IsValid")
    setmetatable(native_validity,{__call=function(fn, context, actor)
        assert(fn==native_validity and context==system,"bound native validity receives the live library CDO as explicit receiver")
        f.validity_calls=f.validity_calls+1
        if actor==f.statics then f.preflight_valid=true end
        if actor==nil then f.preflight_nil=true end
        if options.validity_throws then error("native validity binding failed") end
        if options.validity_always_false then return false end
        if options.validity_always_true then return true end
        if options.validity_returns_nil then return nil end
        return actor~=nil and actor._valid and not actor._garbage
    end})
    function system:GetPropertyValue(name)
        assert(name=="IsValid","only the colliding reflected IsValid function needs explicit property lookup")
        return native_validity
    end
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
                    local travelled=math.min(elapsed*a.Speed,a.LoopDistance)
                    a.Train.RelativeLocation.X = a.StartLocation.X + travelled
                    if travelled >= a.LoopDistance and not options.movement_stuck then a.IsMoveActive=false end
                end
            end
            if a._valid and a.expires and f.time >= a.expires then a._valid=false;a._destroying=true;a._garbage=true end
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
    -- A fresh adapter module matches a new game load and keeps cached CDOs fixture-local.
    f.adapter = dofile(root .. "/mod/DeadAsDiscoAP/Scripts/cars.lua").new(function(message) f.logs[#f.logs+1]=message end)
    return f
end

scenario("fixture composes rotated components using native FTransform scale order",function()
    local t=composed({location=vec(10,20,0),yaw=90,scale=vec(2,3,1)},
        {location=vec(0,0,0),yaw=0,scale=vec(4,5,1)})
    local p=transformed(t,vec(1,0,0))
    check(approx(p.X,40) and approx(p.Y,108),"component scale multiplies before combined rotation; affine nesting would produce Y=110")
    check(t.scale.X==8 and t.scale.Y==15 and t.yaw==90,"relative and parent scale remain componentwise")
end)

scenario("rotated warning meshes expose naive actor-axis fit safely",function()
    local f=fixture({rotated_road=true})
    local ok,reason=f.start(true)
    check(not ok and reason=="spawn_failed","rotated local mesh axes prevent an unsafe warning fit")
    check(f.warnings[1].Arrow_01.RelativeRotation.Yaw==90 and f.native_starts==0 and f.live_count()==0,
        "unfitted rotated warning and frozen car are removed before launch")
    check(table.concat(f.logs,"\n"):find("native warning does not follow the fitted route",1,true)~=nil,
        "rotated mesh reproduction reaches the post-placement bounds check")
end)

for _,failure in ipairs({"validity_throws","validity_always_false","validity_always_true","validity_returns_nil"}) do
    scenario("native validity preflight rejects "..failure,function()
        local f=fixture({[failure]=true});local ok,reason=f.start()
        check(not ok and reason=="spawn_failed","bad native validity binding returns a clean startup failure")
        check(f.begin_calls==0 and #f.actors==0 and not f.adapter.active and #f.adapter.stranded==0,
            "failed validity preflight owns no actors and needs no rollback")
    end)
end

for _,deferred in ipairs({false,true}) do
    scenario("validity exception cannot abandon actors with deferred GC="..tostring(deferred),function()
        local options={defer_gc=deferred,refuse_destroyed_events=true}
        local f=fixture(options);check(f.start(),"validity exception batch starts with working binding")
        options.validity_throws=true
        local ok=pcall(function() f.adapter:stop("left_run") end)
        local all_attempted=true
        for _,a in ipairs(f.actors) do
            all_attempted=all_attempted and a.destroy_calls==1 and not a.collision and a.hidden
        end
        check(ok and all_attempted and f.live_count()==0 and not f.adapter.active,
            "cleanup independently attempts destruction on every tracked actor after validity calls fail")
        check(#f.adapter.stranded==(deferred and 6 or 0),
            "only actors whose removal remains unverified are retained in quarantine")
        options.validity_throws=false
        check(f.adapter:ready(f.player) and #f.adapter.stranded==0,
            "restored native validity clears removed actors without leaving a permanent block")
    end)
end

scenario("malformed runtime validity retains unverified actors until binding recovers",function()
    local options={defer_gc=true,refuse_destroyed_events=true}
    local f=fixture(options);check(f.start(),"malformed validity scenario starts with working binding")
    options.validity_returns_nil=true
    local ok=pcall(function() f.adapter:stop("left_run") end)
    local all_attempted=true
    for _,a in ipairs(f.actors) do all_attempted=all_attempted and a.destroy_calls==1 end
    check(ok and all_attempted and f.live_count()==0,"malformed validity cannot skip destruction of tracked actors")
    check(#f.adapter.stranded==6 and not f.adapter.active,"non-boolean validity leaves all unverified references quarantined")
    local started,reason=f.start()
    check(not started and reason=="busy" and f.begin_calls==6,"unverified removal blocks additional spawns")
    options.validity_returns_nil=false
    check(f.adapter:ready(f.player) and #f.adapter.stranded==0,"verified removal clears quarantine after binding recovers")
end)

scenario("native deferred initialization and measured geometry", function()
    local f=fixture({unloaded=true,yaw=45})
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
    local f=fixture({yaw=135})
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
    local f=fixture({yaw=90});check(f.start(),"diagonal route starts")
    for i,car in ipairs(f.cars) do
        local center=f.world_bounds(car.Train);local lane=(i-2)*490
        check(approx(center.X,1000+(-2000-lane)/math.sqrt(2)) and approx(center.Y,2000+(-2000+lane)/math.sqrt(2)),
            "diagonal lane center follows rotated native route")
        check(approx(f.warnings[i].transform.scale.X,4.52) and approx(f.warnings[i].transform.scale.Y,310/130),
            "diagonal warning scaling uses projected mesh corners rather than world AABB width")
    end
    f.adapter:stop("test cleanup")
end)

for _,yaw in ipairs({0,-138.555}) do
    scenario("authored warning scale survives fitting at yaw "..yaw,function()
        local f=fixture({yaw=yaw+45,authored_warning_scale=vec(3,3,3),authored_train_scale=vec(1.5,1.5,1.5),
            warning_offset=vec(81,-35,4)})
        check(f.start(),"authored-scale set fits after native construction")
        local c,s=math.cos(math.rad(yaw)),math.sin(math.rad(yaw))
        for i,car in ipairs(f.cars) do
            local center,extent=f.world_bounds(car.Train)
            local lane=(i-2)*605
            check(approx(center.X,1000-2000*c-lane*s) and approx(center.Y,2000-2000*s+lane*c)
                and approx(center.Z-extent.Z,415),"authored car mesh size and floor clearance survive route placement")
            check(car:GetActorScale3D().X==1 and car.Train.RelativeScale3D.X==1.5,
                "unit movement parent and authored mesh scale remain independent")
            local warning=f.warnings[i]
            check(approx(warning:GetActorScale3D().X,4.74) and approx(warning:GetActorScale3D().Y,425/130)
                and warning:GetActorScale3D().Z==3,"fit multiplies the authored warning scale by measured ratios")
            local lo,hi=warning_bounds_in_route(warning,vec(1000-lane*s,2000+lane*c,410),yaw)
            check(approx(lo.X,-2370) and approx(hi.X,2370) and approx(lo.Y,-212.5) and approx(hi.Y,212.5)
                and approx(lo.Z,3),"native warning corners cover the entire swept lane with the required floor offset")
        end
        f.adapter:stop("test cleanup")
    end)
end

scenario("authored actor scale cannot silently change native travel distance",function()
    local f=fixture({authored_car_scale=vec(1.5,1.5,1.5)})
    local ok,reason=f.start(true)
    check(not ok and reason=="spawn_failed" and f.native_starts==0,"scaled movement parent fails closed before a longer-than-marked sweep")
    check(f.live_count()==0 and #f.adapter.stranded==0 and f.cars[1]:GetActorScale3D().X==1.5,
        "unsupported authored car scale is preserved for diagnosis and its actor cleaned")
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
    check(f.tick(1.25)=="native_finished" and f.live_count()==0,"native movement stops after 1.25 seconds and owned actors are cleaned")
end)

scenario("doubled driving speed crosses the warning center halfway through a 1.25-second sweep",function()
    local f=fixture();check(f.start(true),"faster car probe starts")
    f.begin_driving()
    local car=f.cars[1]
    f.tick(0.625)
    local center=f.world_bounds(car.Train)
    check(approx(center.X,f.position.X) and approx(center.Y,f.position.Y) and car.IsMoveActive and car.collision,
        "native car covers the first two thousand units in 0.625 seconds")
    f.tick(0.615)
    check(f.live_count()==2 and car.IsMoveActive and approx(car.Train.RelativeLocation.X-car.StartLocation.X,3968),
        "car remains active just before completing the unchanged four-thousand-unit route")
    check(f.tick(0.01)=="native_finished" and f.live_count()==0
        and approx(car.Train.RelativeLocation.X-car.StartLocation.X,4000),"full route ends after 1.25 seconds with native cleanup")
end)

scenario("two sets serialize all six actors and enforce a one-second gap", function()
    local f=fixture()
    check(f.start(),"two-set trap starts")
    f.begin_driving()
    check(f.native_starts==3,"first set starts three native cars")
    f.tick(1.24)
    check(f.begin_calls==6 and f.live_count()==6,"second set never overlaps the first moving set")
    f.tick(0.01)
    check(f.live_count()==0 and f.adapter.active.phase=="between","all six first-set actors are invalid before between-set phase")
    f.tick(0.99)
    check(f.begin_calls==6,"second set waits at least one game second")
    f.tick(0.01)
    check(f.begin_calls==12 and f.live_count()==6 and #f.notices==2,"second set prepares only after complete cleanup and gap")
    f.begin_driving()
    check(f.tick(1.25)=="native_finished" and f.live_count()==0 and f.native_starts==6,"two sets finish with exactly six native car launches")
end)

scenario("sequential diagonal sets form a fixed X despite player movement and turning",function()
    local f=fixture({yaw=30,authored_warning_scale=vec(3,3,3)})
    local anchor=copy(f.position);anchor.Z=anchor.Z-90
    check(f.start(),"crossing set batch starts")
    for set=1,2 do
        local yaw=set==1 and -15 or 75
        local c,s=math.cos(math.rad(yaw)),math.sin(math.rad(yaw))
        for lane_index=1,3 do
            local index=(set-1)*3+lane_index
            local car,warning=f.cars[index],f.warnings[index]
            local lane=(lane_index-2)*490
            local lane_center=vec(anchor.X-lane*s,anchor.Y+lane*c,anchor.Z)
            local center,extent=f.world_bounds(car.Train)
            check(approx(car.transform.yaw,yaw) and approx(warning.transform.yaw,yaw)
                and approx(center.X,lane_center.X-2000*c) and approx(center.Y,lane_center.Y-2000*s)
                and approx(center.Z-extent.Z,anchor.Z+5),"set "..set.." lane "..lane_index.." begins on its diagonal around the original grounded center")
            local lo,hi=warning_bounds_in_route(warning,lane_center,yaw)
            check(approx(lo.X,-2260) and approx(hi.X,2260) and approx(lo.Y,-155) and approx(hi.Y,155)
                and approx(lo.Z,3),"set "..set.." warning covers its complete rotated sweep at the fixed floor")
        end
        f.begin_driving();f.tick(0.625)
        for lane_index=1,3 do
            local index=(set-1)*3+lane_index
            local lane=(lane_index-2)*490
            local center=f.world_bounds(f.cars[index].Train)
            check(approx(center.X,anchor.X-lane*s) and approx(center.Y,anchor.Y+lane*c),
                "set "..set.." native movement follows its diagonal through the original crossing")
        end
        local reason=f.tick(0.625)
        if set==1 then
            check(reason==nil and f.live_count()==0 and f.begin_calls==6,"first diagonal is fully removed before preparing the crossing set")
            -- Mutate the returned location table too, catching an accidentally retained alias.
            f.position.X,f.position.Y,f.position.Z=4200,-800,900
            f.yaw=-70
            f.tick(1)
        else
            check(reason=="native_finished" and f.live_count()==0 and f.native_starts==6,"second diagonal completes without overlapping the first set")
        end
    end
    check(approx(f.cars[4].transform.yaw-f.cars[1].transform.yaw,90),"the two diagonals cross at ninety degrees despite later player facing")
end)

scenario("destroyed actors awaiting garbage collection do not cause false quarantine",function()
    local f=fixture({defer_gc=true});check(f.start(),"deferred-GC batch starts")
    f.begin_driving();f.tick(1.25)
    local removed=true
    for _,a in ipairs(f.actors) do removed=removed and a:IsValid() and a:IsActorBeingDestroyed() and a.destroy_calls==1 end
    check(removed and f.live_count()==0 and #f.adapter.stranded==0,
        "native destruction counts as removal even while UObject wrappers remain valid")
    f.tick(1)
    check(f.begin_calls==12 and f.live_count()==6,"second set is admitted after removal and gap without waiting for GC")
    f.adapter:stop("left_run")
    check(f.live_count()==0 and #f.adapter.stranded==0,"deferred-GC cleanup leaves no live actor quarantine")
end)

scenario("garbage actors with default ProcessEvent returns are removed without quarantine",function()
    local f=fixture({defer_gc=true,refuse_destroyed_events=true});check(f.start(),"garbage actor batch starts")
    f.begin_driving();f.tick(1.25)
    local removed=true
    for _,a in ipairs(f.actors) do
        removed=removed and a:IsValid() and not a:IsActorBeingDestroyed() and a._garbage and a.destroy_calls==1
    end
    check(removed and f.live_count()==0 and #f.adapter.stranded==0 and f.validity_calls>0,
        "live library validity rejects garbage actors even when their destruction method returns default false")
    f.tick(1)
    check(f.begin_calls==12 and f.live_count()==6,"second set follows native removal without waiting for UObject garbage collection")
    f.adapter:stop("left_run")
    check(f.live_count()==0 and #f.adapter.stranded==0,"default actor method results do not create false survivors")
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
        local reason=f.tick(1.25)
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
        local f=fixture({yaw=77}); local ok,sets=f.start(sample.value)
        check(ok and sets==sample.sets and #f.cars==sample.cars and #f.warnings==sample.cars,"only boolean true selects the single-car probe")
        local expected_yaw=sample.value==true and 77 or 32
        check(approx(f.cars[1].transform.yaw,expected_yaw) and approx(f.warnings[1].transform.yaw,expected_yaw),
            "single probe retains facing while normal batches begin on the first diagonal")
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
    check(f.tick(1.25)=="cleanup_failed","silent native destroy failure aborts batch")
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
    f.begin_driving();f.tick(1.25);options.finish_fails=8
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
    f.begin_driving();f.tick(1.25);f.state.bWaveClearedRequested=true
    f.time=140
    check(f.tick()=="batch_expired" and not f.adapter.active and f.live_count()==0,"between-set downtime cannot outlive whole-batch cap")
end)

scenario("native movement that does not stop is bounded",function()
    local f=fixture({movement_stuck=true});check(f.start(true),"stuck movement probe starts")
    f.begin_driving();f.tick(2.24)
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
    f.tick(0.01);f.tick(0.5);f.tick(1.25)
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
            if stage=="between" then f.begin_driving();f.tick(1.25) end
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
