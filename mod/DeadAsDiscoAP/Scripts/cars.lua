-- Prophet's native highway cars: two sets of three, or one car for the manual probe.
-- This adapter owns placement/timing/cleanup; native overlaps own all damage.
local Cars = {}
local BASE = "/Game/LevelPrototyping/Prototype_Blueprints/"
local CAR = BASE .. "BP_Prophet_Highway_Car.BP_Prophet_Highway_Car_C"
local WARNING = BASE .. "BP_CarWarningIndicator.BP_CarWarningIndicator_C"
local SPEED, DISTANCE, WARN_TIME, NEAR_TIME = 3200, 4000, 2, 0.5
local INIT_LIMIT, SET_LIMIT, LIFE_LIMIT, BATCH_LIMIT, SET_GAP = 2, 12, 14, 40, 1
local ROAD = {"Arrow_01", "Arrow_02", "Arrow_03", "Arrow_04", "Arrow_05", "Border_01", "Border_02"}

local function valid(o) return o ~= nil and o:IsValid() end
local validity_lib, validity_fn
local function alive(actor)
    if not valid(actor) then return false end
    if not valid(validity_lib) then validity_lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    if not valid(validity_fn) then validity_fn = validity_lib:GetPropertyValue("IsValid") end
    assert(valid(validity_lib) and valid(validity_fn), "native validity check unavailable")
    -- UE4SS wrappers can outlive native destruction. ProcessEvent on a destroyed
    -- actor may return default false even for IsActorBeingDestroyed; call the live CDO.
    -- GetPropertyValue returns the bound native function instead of UE4SS's own
    -- IsValid member. Supply its receiver just as an ordinary colon call would.
    local result = validity_fn(validity_lib, actor)
    assert(type(result) == "boolean", "native validity returned a non-boolean")
    return result
end
local function address(o) return valid(o) and o:GetAddress() or nil end
local function fail(reason, detail) error({reason = reason, detail = detail}) end
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < 1e9 end
local function xyz(v)
    assert(v and finite(v.X) and finite(v.Y) and finite(v.Z), "invalid native vector")
    return {X = v.X, Y = v.Y, Z = v.Z}
end
local function distance(a, b)
    return math.sqrt((a.X-b.X)^2 + (a.Y-b.Y)^2 + (a.Z-b.Z)^2)
end
local function rotate(v, yaw)
    local r = math.rad(yaw)
    return {X = v.X*math.cos(r)-v.Y*math.sin(r), Y = v.X*math.sin(r)+v.Y*math.cos(r), Z = v.Z}
end
local function statics() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function mathlib() return StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end
local function load_class(path)
    local cls = StaticFindObject(path)
    if valid(cls) then return cls end
    local ok, err = pcall(LoadAsset, path:match("^(.-)%."))
    if not ok then fail("asset_unavailable", tostring(err)) end
    cls = StaticFindObject(path)
    if not valid(cls) then fail("asset_unavailable", "cannot load " .. path) end
    return cls
end
local function bounds(component)
    assert(valid(component), "missing native component")
    local origin, extent = {}, {}
    -- Reflected vector out parameters, not opaque native handles.
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetComponentBounds(component, origin, extent, {})
    origin, extent = xyz(origin), xyz(extent)
    assert(extent.X > 0 and extent.Y > 0 and extent.Z >= 0
        and extent.X < 20000 and extent.Y < 20000 and extent.Z < 20000, "invalid component bounds")
    return origin, extent
end
local function transform(location, yaw, scale)
    return mathlib():MakeTransform(location, {Pitch = 0, Yaw = yaw, Roll = 0}, scale or {X=1,Y=1,Z=1})
end
local function actor_scale(actor)
    local scale = xyz(actor:GetActorScale3D())
    assert(scale.X > 0 and scale.Y > 0 and scale.Z > 0, "native actor scale must be positive")
    return scale
end
local function place(actor, location, yaw, scale)
    assert(actor:K2_SetActorTransform(transform(location, yaw, scale or actor_scale(actor)), false, {}, true), "cannot position native actor")
end
local function grounded(p)
    if not valid(p) then return false, "not_in_run" end
    if statics():IsGamePaused(p) then return false, "paused" end
    local movement = p.CharacterMovement
    if not valid(movement) or not valid(movement.UpdatedComponent)
        or (movement.MovementMode ~= 1 and movement.MovementMode ~= 2) then return false, "airborne" end
    return true
end

function Cars.new(log)
    local self = {active = nil, stranded = {}}

    local function cleanup(actors)
        local remaining = {}
        for _, actor in ipairs(actors) do
            local checked,live = pcall(alive,actor)
            if not checked then log("cars cleanup validity check failed: " .. tostring(live)); live=valid(actor) end
            if live then
                -- Separate calls: one unavailable native method must not prevent destruction.
                for _, action in ipairs({
                    function() actor:SetActorEnableCollision(false) end,
                    function() actor:SetActorHiddenInGame(true) end,
                    function() actor:K2_DestroyActor() end,
                }) do
                    local ok, err = pcall(action)
                    if not ok then log("cars cleanup: " .. tostring(err)) end
                end
                local checked_after,live_after = pcall(alive,actor)
                if not checked_after or live_after then remaining[#remaining+1] = actor end
            end
        end
        return remaining
    end

    function self:stop(reason)
        local s = self.active
        self.active = nil
        if s then
            self.stranded = cleanup(s.owned)
            log("cars finished: " .. tostring(reason) .. "; surviving owned actors=" .. #self.stranded)
        elseif #self.stranded > 0 then self.stranded = cleanup(self.stranded) end
    end

    function self:ready(p)
        if self.active then return false, "busy" end
        if #self.stranded > 0 then
            self.stranded = cleanup(self.stranded)
            if #self.stranded > 0 then return false, "busy" end
        end
        return grounded(p)
    end

    local function spawn(s, p, cls, location, is_car)
        local t = transform(location, 0)
        local actor = statics():BeginDeferredActorSpawnFromClass(p, cls, t, 1, nil, 1)
        if not valid(actor) then fail("spawn_blocked", "native actor spawn blocked") end
        s.owned[#s.owned+1] = actor -- track before any further native call can fail
        actor:SetActorEnableCollision(false)
        actor.InitialLifeSpan = LIFE_LIMIT
        if is_car then
            actor.ShouldLoop, actor["ResetPositionOnEnd?"] = false, false
            actor.Vector, actor.Speed, actor.LoopDistance = {X=1,Y=0,Z=0}, SPEED, DISTANCE
            actor.LevelLoaded, actor.IsMoveActive = false, false
            actor.bDisableCollision, actor.bHideUntilActivation = false, false
            actor.StartTag = {TagName = FName("None")}
            actor.WarningYellowStartTag = {TagName = FName("None")}
            actor.WarningRedStartTag = {TagName = FName("None")}
            actor.BP_CarLaneManager = nil
        end
        statics():FinishSpawningActor(actor, t, 1)
        if is_car then
            -- Invalid StartTag makes BeginPlay activate. Freeze before the next game frame.
            actor.IsMoveActive, actor.bPassedWarningEnd = false, true
        end
        actor:SetActorEnableCollision(false)
        actor:SetActorHiddenInGame(false)
        actor:SetLifeSpan(LIFE_LIMIT)
        assert(alive(actor), "native actor disappeared during initialization")
        assert(actor:GetActorEnableCollision() == false, "warning actor still has collision")
        return actor
    end

    local function attached_to(component, ancestor)
        for _ = 1, 16 do
            if not valid(component) then return false end
            if component.bAbsoluteLocation or component.bAbsoluteRotation or component.bAbsoluteScale then return false end
            if address(component) == address(ancestor) then return true end
            component = component:GetAttachParent()
        end
        return false
    end

    local function movement_axis(car, yaw)
        -- Native movement adds local X to Train.RelativeLocation. Confirm its parent maps
        -- that direction/length to actor X; otherwise this route calculation is unsafe.
        local parent = car.Train:GetAttachParent()
        assert(valid(parent), "car Train has no movement parent")
        local pt = parent:K2_GetComponentToWorld()
        local zero = xyz(mathlib():TransformLocation(pt, {X=0,Y=0,Z=0}))
        local unit = xyz(mathlib():TransformLocation(pt, {X=100,Y=0,Z=0}))
        local expected = rotate({X=100,Y=0,Z=0},yaw)
        assert(distance({X=unit.X-zero.X,Y=unit.Y-zero.Y,Z=unit.Z-zero.Z},expected) < 0.5,
            "native movement axis requires live inspection")
    end

    local function car_geometry(car)
        assert(valid(car.Train), "car has no Train component")
        assert(attached_to(car.HitCollisionSphere, car.Train)
            and attached_to(car.BodyCollisionBox, car.Train), "car colliders do not follow Train")
        movement_axis(car,0)
        local center, mesh = bounds(car.Train)
        local actor_pos = xyz(car:K2_GetActorLocation())
        local geometry = {offset = {X=center.X-actor_pos.X,Y=center.Y-actor_pos.Y,Z=center.Z-actor_pos.Z},
            half_height = mesh.Z, half_width = mesh.Y, half_length = mesh.X}
        for _, component in ipairs({car.HitCollisionSphere, car.BodyCollisionBox}) do
            local origin, extent = bounds(component)
            geometry.half_width = math.max(geometry.half_width, math.abs(origin.Y-center.Y)+extent.Y)
            geometry.half_length = math.max(geometry.half_length, math.abs(origin.X-center.X)+extent.X)
        end
        assert(geometry.half_width < 1200 and geometry.half_length < DISTANCE/2,
            "native car footprint exceeds candidate route")
        assert(finite(car.DamageToPlayer) and car.DamageToPlayer > 0
            and finite(car.DamageToEnemy) and car.DamageToEnemy > 0, "native car damage is not configured")
        log(string.format("cars native footprint: half-width=%.1f half-length=%.1f; damage player=%g enemies=%g",
            geometry.half_width, geometry.half_length, car.DamageToPlayer, car.DamageToEnemy))
        local scale = actor_scale(car)
        log(string.format("cars native actor scale: %.3f,%.3f,%.3f",scale.X,scale.Y,scale.Z))
        return geometry
    end

    local function road_bounds(indicator, origin, yaw)
        local lo = {X=math.huge,Y=math.huge,Z=math.huge}
        local hi = {X=-math.huge,Y=-math.huge,Z=-math.huge}
        for _, name in ipairs(ROAD) do
            local component = indicator[name]
            assert(valid(component), "missing native road mesh")
            local lower, upper = {}, {}
            component:GetLocalBounds(lower,upper)
            lower, upper = xyz(lower), xyz(upper)
            local world = component:K2_GetComponentToWorld()
            -- Project actual mesh corners into the route's axes. World AABBs alone
            -- overestimate a rotated strip and cannot validate its fitted width.
            for _, x in ipairs({lower.X,upper.X}) do
                for _, y in ipairs({lower.Y,upper.Y}) do
                    for _, z in ipairs({lower.Z,upper.Z}) do
                        local p = xyz(mathlib():TransformLocation(world,{X=x,Y=y,Z=z}))
                        p = rotate({X=p.X-origin.X,Y=p.Y-origin.Y,Z=p.Z-origin.Z},-yaw)
                        for _, axis in ipairs({"X","Y","Z"}) do
                            lo[axis], hi[axis] = math.min(lo[axis],p[axis]), math.max(hi[axis],p[axis])
                        end
                    end
                end
            end
        end
        return lo,hi
    end

    local function fit_warning(indicator, center, yaw, length, width)
        local lo,hi = road_bounds(indicator,{X=0,Y=0,Z=0},0)
        assert(hi.X-lo.X >= hi.Y-lo.Y, "native warning's long axis is not the travel axis")
        local sx, sy = length/(hi.X-lo.X), width/(hi.Y-lo.Y)
        assert(finite(sx) and finite(sy) and sx > 0.01 and sy > 0.01 and sx < 100 and sy < 100,
            "native warning cannot fit the route")
        local pos = xyz(indicator:K2_GetActorLocation())
        local original_scale = actor_scale(indicator)
        local offset = rotate({X=((lo.X+hi.X)/2-pos.X)*sx, Y=((lo.Y+hi.Y)/2-pos.Y)*sy, Z=lo.Z-pos.Z}, yaw)
        -- FinishSpawning preserves the native root scale (3x in the live warning).
        -- Ratios derived from its measured bounds must multiply that authored scale.
        place(indicator, {X=center.X-offset.X,Y=center.Y-offset.Y,Z=center.Z-offset.Z+3}, yaw,
            {X=original_scale.X*sx,Y=original_scale.Y*sy,Z=original_scale.Z})
        local fitted_lo,fitted_hi = road_bounds(indicator,center,yaw)
        local fits = math.abs(fitted_lo.X+length/2)<1 and math.abs(fitted_hi.X-length/2)<1
            and math.abs(fitted_lo.Y+width/2)<1 and math.abs(fitted_hi.Y-width/2)<1
            and math.abs(fitted_lo.Z-3)<1
        if not fits then
            log(string.format("cars warning fit: yaw=%.3f original=(%.3f,%.3f,%.3f)-(%.3f,%.3f,%.3f) scale=(%.6f,%.6f,1) expected=%.3fx%.3f actual=(%.3f,%.3f,%.3f)-(%.3f,%.3f,%.3f)",
                yaw,lo.X,lo.Y,lo.Z,hi.X,hi.Y,hi.Z,sx,sy,length,width,
                fitted_lo.X,fitted_lo.Y,fitted_lo.Z,fitted_hi.X,fitted_hi.Y,fitted_hi.Z))
            local ok, why = pcall(function()
                for _, name in ipairs(ROAD) do
                    local component = indicator[name]
                    local loc, scale, rot = component.RelativeLocation,component.RelativeScale3D,component.RelativeRotation
                    log(string.format("cars warning %s: relative=(%.3f,%.3f,%.3f) scale=(%.3f,%.3f,%.3f) rotation=(%.3f,%.3f,%.3f) absolute=%s/%s/%s",
                        name,loc.X,loc.Y,loc.Z,scale.X,scale.Y,scale.Z,rot.Pitch,rot.Yaw,rot.Roll,
                        tostring(component.bAbsoluteLocation),tostring(component.bAbsoluteRotation),tostring(component.bAbsoluteScale)))
                end
            end)
            if not ok then log("cars warning inspection: " .. tostring(why)) end
        end
        assert(fits, "native warning does not follow the fitted route")
        log(string.format("cars warning fitted: original scale=%.3f,%.3f,%.3f route=%.1fx%.1f yaw=%.1f",
            original_scale.X,original_scale.Y,original_scale.Z,length,width,yaw))
        assert(valid(indicator.TrainArrowLeft) and valid(indicator.BorderLeftMaterial), "native warning materials unavailable")
    end

    local function frozen(record)
        local car = record.car
        assert(alive(car) and alive(record.warning), "owned car or warning disappeared")
        assert(car.IsMoveActive == false and car:GetActorEnableCollision() == false, "car activated before warning completed")
        assert(car.ShouldLoop == false and car["ResetPositionOnEnd?"] == false and car.bPassedWarningEnd == true,
            "native car lifecycle configuration changed")
        assert(distance(xyz(car.Train.RelativeLocation), record.initial) < 0.1, "car moved during warning")
        assert(distance(xyz(car.Vector), {X=1,Y=0,Z=0}) < 0.001 and car.Speed == SPEED
            and car.LoopDistance == DISTANCE, "native movement configuration changed")
    end

    local function prepare_set(s, p, now)
        local car_class, warning_class = load_class(CAR), load_class(WARNING)
        local anchor = s.anchor
        s.records, s.owned = {}, {}
        s.set_index = s.set_index + 1
        -- Both diagonals cross the original center, even if the player moves away.
        s.yaw = s.facing + (s.probe and 0 or (s.set_index == 1 and -45 or 45))
        s.set_started, s.phase = now, "preparing"
        s.warn_until, s.near = nil, false -- each set gets its own complete warning
        local half_width, half_length = 0, 0
        for _ = 1, s.per_set do
            local car = spawn(s, p, car_class, anchor, true)
            local g = car_geometry(car)
            half_width, half_length = math.max(half_width,g.half_width), math.max(half_length,g.half_length)
            s.records[#s.records+1] = {car=car, geometry=g, initial=xyz(car.Train.RelativeLocation)}
        end
        local width, length = half_width*2+80, DISTANCE+half_length*2+80
        for i, record in ipairs(s.records) do
            local lane = (i-(s.per_set+1)/2)*(width+180)
            local route = rotate({X=0,Y=lane,Z=0}, s.yaw)
            local g = record.geometry
            local start = rotate({X=-DISTANCE/2-g.offset.X,Y=lane-g.offset.Y,Z=0}, s.yaw)
            place(record.car, {X=anchor.X+start.X,Y=anchor.Y+start.Y,Z=anchor.Z+g.half_height-g.offset.Z+5}, s.yaw)
            movement_axis(record.car,s.yaw)
            record.warning = spawn(s, p, warning_class, anchor, false)
            fit_warning(record.warning, {X=anchor.X+route.X,Y=anchor.Y+route.Y,Z=anchor.Z}, s.yaw, length, width)
            record.car.BP_WarningIndicator = record.warning
            record.car:SetWarning(true, false)
            assert(record.warning.bEarlyWarningOn, "native early warning did not activate")
            frozen(record)
        end
        log(string.format("cars set %d/%d prepared: %d lanes; yaw=%.1f width=%.1f length=%.1f center=%.1f,%.1f,%.1f",
            s.set_index,s.sets,s.per_set,s.yaw,width,length,anchor.X,anchor.Y,anchor.Z))
        if s.on_set then
            local ok, err = pcall(s.on_set, s.set_index, s.sets)
            if not ok then log("cars popup callback: " .. tostring(err)) end
        end
    end

    function self:start(p, state, on_set, probe)
        local ready, reason = self:ready(p)
        if not ready then return false, reason end
        if not valid(state) or state.bWaveClearedRequested then return false, "downtime" end
        local s = {owned={}, records={}, set_index=0, probe=probe == true, sets=probe == true and 1 or 2,
            per_set=probe == true and 1 or 3, on_set=on_set,
            player=address(p), state=address(state), world=address(p:GetWorld())}
        self.active = s
        local ok, err = pcall(function()
            -- Validate the native call on known inputs before owning any spawned actors.
            assert(alive(statics()) and validity_fn(validity_lib,nil) == false,
                "native validity preflight failed")
            local now = statics():GetTimeSeconds(p)
            s.ends_at = now+BATCH_LIMIT
            s.facing = p:K2_GetActorRotation().Yaw
            assert(finite(s.facing), "invalid player facing")
            s.anchor = xyz(p:K2_GetActorLocation())
            s.anchor.Z = s.anchor.Z - p.CapsuleComponent:GetScaledCapsuleHalfHeight()
            prepare_set(s,p,now)
        end)
        if not ok then
            local why = type(err)=="table" and err.reason or "spawn_failed"
            log("cars start failed: " .. tostring(type(err)=="table" and err.detail or err))
            self:stop(why)
            return false, #self.stranded > 0 and "cleanup_failed" or why
        end
        return true, s.sets
    end

    function self:tick(p, state, in_run)
        local s = self.active
        if not s then return nil end
        local reason
        local ok, err = pcall(function()
            if not in_run or address(p)~=s.player or address(state)~=s.state or address(p:GetWorld())~=s.world then
                reason="left_run"; return
            end
            local now = statics():GetTimeSeconds(p)
            if now >= s.ends_at then reason="batch_expired"; return end
            if statics():IsGamePaused(p) then return end
            if s.phase == "between" then
                if now >= s.next_at and not state.bWaveClearedRequested and grounded(p) then prepare_set(s,p,now) end
                return
            end
            if now-s.set_started >= SET_LIMIT then reason="set_expired"; return end
            if s.phase == "preparing" or s.phase == "warning" then
                local loaded = true
                for _, record in ipairs(s.records) do
                    frozen(record)
                    loaded = loaded and record.car.LevelLoaded
                    if record.car.LevelLoaded then
                        assert(distance(xyz(record.car.StartLocation),record.initial) < 0.1, "native movement origin changed")
                    end
                end
                if not loaded then
                    if now-s.set_started >= INIT_LIMIT then reason="initialization_timeout" end
                    return
                end
                if state.bWaveClearedRequested then
                    if s.warn_until then
                        for _, record in ipairs(s.records) do record.car:SetWarning(true,false) end
                    end
                    s.warn_until, s.near = nil, false
                    return
                end
                if not s.warn_until then s.warn_until=now+WARN_TIME; s.phase="warning"; s.near=false end
                if not s.near and now >= s.warn_until-NEAR_TIME then
                    for _, record in ipairs(s.records) do
                        record.car:SetWarning(true,true)
                        assert(record.warning.bNearHitOn, "native near-hit warning did not activate")
                    end
                    s.near = true
                    -- A delayed mod tick must not skip the red phase or shorten it.
                    s.warn_until = math.max(s.warn_until,now+NEAR_TIME)
                elseif now >= s.warn_until then
                    for _, record in ipairs(s.records) do
                        frozen(record)
                        record.car:StartCar()
                        assert(record.car.IsMoveActive, "native StartCar refused activation")
                        record.car:SetActorEnableCollision(true)
                        assert(record.car:GetActorEnableCollision(), "native car collision did not enable")
                    end
                    s.phase, s.drive_started = "driving", now
                    log("cars set " .. s.set_index .. " driving: " .. #s.records)
                end
            elseif s.phase == "driving" then
                local done = true
                for _, record in ipairs(s.records) do
                    assert(alive(record.warning), "route warning disappeared during the rush")
                    if alive(record.car) and record.car.IsMoveActive then done=false end
                end
                if not done and now-s.drive_started < DISTANCE/SPEED+1 then return end
                local remaining = cleanup(s.owned)
                if #remaining > 0 then reason="cleanup_failed"; return end
                s.owned, s.records = {}, {}
                log("cars set " .. s.set_index .. " fully removed")
                if s.set_index >= s.sets then reason="native_finished"
                else s.phase, s.next_at = "between", now+SET_GAP end
            end
        end)
        if not ok then
            reason="runtime_failed"
            log("cars runtime failed: " .. tostring(type(err)=="table" and err.detail or err))
        end
        if reason then self:stop(reason) end
        return reason
    end
    return self
end

return Cars
