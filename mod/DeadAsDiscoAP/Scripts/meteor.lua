-- A random 1-5 Aurora meteors, each using the native projectile and kickable remnant.
-- No boss ability, damage substitute or world-wide actor sweep. All calls run on the game thread.
local Meteor = {}
local FALLING = "/Game/Pagoda/Characters/Enemies/Doll/UniqueMechanics/BP_BigDoll_Meteor.BP_BigDoll_Meteor_C"
local LANDED = "/Game/Pagoda/Characters/Enemies/Doll/UniqueMechanics/BP_Destructable_BigDoll_Meteor.BP_Destructable_BigDoll_Meteor_C"
local SPAWN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local EXPIRY = "/Game/Pagoda/Characters/Enemies/Doll/UniqueMechanics/GA_ExplodeAfterTime_BigDollMeteor.GA_ExplodeAfterTime_BigDollMeteor_C"
local TIMER = "/Script/Pagoda.PagodaUtilsFunctionLibrary:DelayUntilTimelinePos"
local HEIGHT, SPEED, LIFETIME, REMNANT_TIME = 3000, 1500, 16, 11
local LAUNCH_GAP = 3 -- game seconds; also wait for the previous remnant to disappear

local function valid(o) return o ~= nil and o:IsValid() end
local function address(o) return valid(o) and o:GetAddress() or nil end
local function xyz(v) return {X = v.X, Y = v.Y, Z = v.Z} end
local function load_class(path)
    local cls = StaticFindObject(path)
    if valid(cls) then return cls end
    local ok, err = pcall(LoadAsset, path:match("^(.-)%."))
    if not ok then error({reason = "asset_unavailable", detail = tostring(err)}) end
    cls = StaticFindObject(path)
    if not valid(cls) then error({reason = "asset_unavailable", detail = "cannot load " .. path}) end
    return cls
end

function Meteor.new(log)
    local self = {active = nil}
    local statics = function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    local function unhook(s, key, path)
        if not s[key] then return end
        local ids = s[key]
        UnregisterHook(path, ids[1], ids[2])
        s[key] = nil
    end
    local function destroy(actor)
        if valid(actor) then actor:K2_DestroyActor() end
    end

    local function stop_one(reason)
        local s = self.active
        if not s then return end
        self.active = nil
        if s.child and not s.timer_adjusted then log("meteor remnant timer was not adjusted; native timing remained in use") end
        for key, path in pairs({hook = SPAWN, timer_hook = TIMER}) do
            local ok, err = pcall(unhook, s, key, path)
            if not ok then log("meteor unhook failed: " .. tostring(err)) end
        end
        -- Destroy only the two actors whose spawning we directly observed.
        for _, actor in pairs({s.parent, s.child}) do
            local done, why = pcall(destroy, actor)
            if not done then log("meteor cleanup failed: " .. tostring(why)) end
        end
        log("meteor finished: " .. tostring(reason))
    end

    function self:stop(reason)
        self.batch = nil
        stop_one(reason)
    end

    local function grounded(p)
        if not valid(p) then return false, "not_in_run" end
        if statics():IsGamePaused(p) then return false, "paused" end
        -- Read the reflected mode directly: the inherited navigation query returned
        -- false for Walking in the live UE4SS probe. UE modes 1/2 are Walking/NavWalking.
        local movement = p.CharacterMovement
        local mode = movement.MovementMode
        if not valid(movement.UpdatedComponent) or (mode ~= 1 and mode ~= 2) then return false, "airborne" end
        return true
    end

    function self:ready(p)
        if self.active or self.batch then return false, "busy" end
        return grounded(p)
    end

    local function start_one(p, state)
        local s = {player = address(p), state = address(state), world = address(p:GetWorld())}
        self.active = s
        local ok, err = pcall(function()
            local falling, landed, expiry = load_class(FALLING), load_class(LANDED), load_class(EXPIRY)
            local gs = statics()
            s.ends_at = gs:GetTimeSeconds(p) + LIFETIME
            local target = xyz(p:K2_GetActorLocation())
            target.Z = target.Z - p.CapsuleComponent:GetScaledCapsuleHalfHeight()
            s.target = target -- locked at launch; never follows the player
            local start = {X = target.X, Y = target.Y, Z = target.Z + HEIGHT}
            local mathlib = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
            local transform = mathlib:MakeTransform(start, {Pitch = 0, Yaw = 0, Roll = 0}, {X = 1, Y = 1, Z = 1})
            s.parent = gs:BeginDeferredActorSpawnFromClass(p, falling, transform, 3, nil, 1)
            if not valid(s.parent) then error({reason = "spawn_blocked", detail = "meteor spawn blocked"}) end
            local parent_address, landed_address = address(s.parent), address(landed)
            -- Native post-hook order is Context, ReturnValue, then inputs (UE4SS 5e627997).
            -- Installed only for this flight; removal happens on tick, never inside this callback.
            local pre, post = RegisterHook(SPAWN, function() end, function(_, result, context, cls)
                if self.active ~= s or not valid(s.parent) then return end
                if address(context:get()) ~= parent_address then return end
                if address(cls:get()) ~= landed_address then return end
                local child = result:get()
                if valid(child) then
                    s.child = child
                    log("meteor native remnant captured: " .. child:GetFullName())
                end
            end)
            s.hook = {pre, post}
            -- The native dissolve makes the remnant untargetable at 75% of its timer.
            -- Extend only our child's ability, in its own music timeline, before it schedules.
            local timer_pre, timer_post = RegisterHook(TIMER, function(_, context, timeline)
                if self.active ~= s or s.timer_adjusted or not valid(s.child) then return end
                local good, why = pcall(function()
                    local ability = context:get()
                    if not valid(ability) or address(ability:GetClass()) ~= address(expiry) then return end
                    if address(ability:GetOwningActorFromActorInfo()) ~= address(s.child) then return end
                    local original, activated = timeline:get(), ability.MusicTimeActivated
                    local span = original - activated
                    if span ~= span or span < 0 or span > 60 then error("unexpected native meteor timer") end
                    local deadline = original + math.max(0, REMNANT_TIME - span)
                    ability.ExplodeGameSyncTime = deadline
                    timeline:set(deadline)
                    s.timer_adjusted = true
                    log(string.format("meteor remnant timer: %.2fs -> %.2fs (strike window ~%.2fs)",
                        span, deadline - activated, (deadline - activated) * 0.75))
                end)
                if not good then s.callback_error = tostring(why) end
            end)
            s.timer_hook = {timer_pre, timer_post}
            s.parent.TargetLocation = target
            s.parent.InitialSpeed = SPEED
            -- Its default beat warp shortened a 2-second flight to ~0.53s in Arcade.
            -- Only change the falling actor; kicking the remnant keeps native beat timing.
            s.parent.ProjectileMovementComponent:SetBeatWarpingEnabled(false)
            -- Leave native owner/instigator unset, so the player is not the shooter.
            gs:FinishSpawningActor(s.parent, transform, 1)
            if valid(s.parent) then s.parent:SetLifeSpan(LIFETIME) end
            log(string.format("meteor launched at %.1f,%.1f,%.1f; height=%d speed=%d", target.X, target.Y, target.Z, HEIGHT, SPEED))
            log("meteor native damage: player=" .. tostring(s.parent.DamageToPlayer) .. " enemies=" .. tostring(s.parent.DamageToEnemies))
        end)
        if not ok then
            local reason = type(err) == "table" and err.reason or "spawn_failed"
            log("meteor launch failed: " .. tostring(type(err) == "table" and err.detail or err))
            stop_one(reason)
            return false, reason
        end
        return true
    end

    -- Returns a completion reason, or nil while the meteor/remnant still exists.
    local function tick_one(p, state, in_run)
        local s = self.active
        if not s then return nil end
        local reason
        local ok, err = pcall(function()
            if not in_run or address(p) ~= s.player or address(state) ~= s.state
                or address(p:GetWorld()) ~= s.world then
                reason = "left_run"
                return
            end
            if s.callback_error then error(s.callback_error) end
            if s.child or not valid(s.parent) then
                unhook(s, "hook", SPAWN)
            end
            -- Child BeginPlay/ability activation can happen after its spawn callback.
            -- Keep this hook until the owned ability actually schedules its timer.
            if s.timer_adjusted then unhook(s, "timer_hook", TIMER) end
            if valid(s.child) and not s.child_bounded then
                s.child:SetLifeSpan(math.max(0.1, s.ends_at - statics():GetTimeSeconds(p)))
                s.child_bounded = true
            end
            if not valid(s.parent) and not s.child then
                log("meteor parent disappeared before its native remnant was observed; cancelling remaining meteors")
                reason = "remnant_unobserved"
            elseif statics():GetTimeSeconds(p) >= s.ends_at then reason = "expired"
            elseif not valid(s.parent) and not valid(s.child) then reason = "native_finished" end
        end)
        if not ok then reason = "runtime_failed: " .. tostring(err) end
        if reason then stop_one(reason) end
        return reason
    end

    local function announce(batch)
        if not batch.on_launch then return end
        local ok, err = pcall(batch.on_launch, batch.launched, batch.count)
        if not ok then log("meteor warning callback failed: " .. tostring(err)) end
    end

    function self:start(p, state, on_launch)
        local ready, reason = self:ready(p)
        if not ready then return false, reason end
        local count = math.random(1, 5)
        local now = statics():GetTimeSeconds(p)
        local batch = {count = count, launched = 1, next_at = now + LAUNCH_GAP,
            ends_at = now + count * 20 + 10, on_launch = on_launch,
            player = address(p), state = address(state), world = address(p:GetWorld())}
        local ok, why = start_one(p, state)
        if not ok then return false, why end
        self.batch = batch
        log("meteor batch started: " .. count)
        announce(batch)
        return true, count
    end

    function self:tick(p, state, in_run)
        local batch = self.batch
        if not batch then return nil end
        local reason
        local ok, err = pcall(function()
            if not in_run or address(p) ~= batch.player or address(state) ~= batch.state
                or address(p:GetWorld()) ~= batch.world then
                reason = "left_run"
                return
            end
            local now = statics():GetTimeSeconds(p)
            if now >= batch.ends_at then reason = "batch_expired"; return end
            local finished = tick_one(p, state, in_run)
            if finished and finished ~= "native_finished" and finished ~= "expired" then
                reason = finished
                return
            end
            if self.active then return end
            if batch.launched >= batch.count then reason = finished or "native_finished"; return end
            if now < batch.next_at or state.bWaveClearedRequested or not grounded(p) then return end
            batch.launched = batch.launched + 1
            batch.next_at = now + LAUNCH_GAP
            local started, why = start_one(p, state)
            if started then announce(batch)
            else
                -- The AP item was already spent at the first launch. Never replay a batch
                -- because one later spawn failed; skip that attempt and keep the hard cap.
                log("meteor " .. batch.launched .. "/" .. batch.count .. " skipped: " .. tostring(why))
                if batch.launched >= batch.count then reason = "batch_finished" end
            end
        end)
        if not ok then reason = "runtime_failed: " .. tostring(err) end
        if reason then
            self:stop(reason)
            log("meteor batch finished: " .. reason)
        end
        return reason
    end
    return self
end

return Meteor
