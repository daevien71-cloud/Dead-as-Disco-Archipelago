-- STAGED ONLY: diagnostic observation, no gameplay calls or AP transport.
-- A root-owned derived copy must enable this and supply a unique test nonce.
local ENABLE_PROBE = false
local SESSION_NONCE = ""
local PROBE_BUILD = "wave-observer-20261011-v1"
if not ENABLE_PROBE then return end
if #SESSION_NONCE < 16 or #SESSION_NONCE > 80
    or not SESSION_NONCE:match("^[A-Za-z0-9_-]+$") then
    print("[DADAPWave] invalid_session_nonce; no hooks registered\n")
    return
end

local GAME_STATE = "/Game/Pagoda/Core/GameModes/InfiniteDisco/BP_PagodaGameState_InfiniteDisco.BP_PagodaGameState_InfiniteDisco_C"
local NATIVE_CLASS = "/Script/Pagoda.PagodaInfiniteDiscoSubsystem"
local EXPECTED_STATE_CLASS = "BlueprintGeneratedClass " .. GAME_STATE
local TARGETS = {
    {path = NATIVE_CLASS .. ":NotifyInfiniteDiscoRoundStart", label = "NotifyInfiniteDiscoRoundStart", state = false},
    {path = NATIVE_CLASS .. ":NotifyWaveEnded", label = "NotifyWaveEnded", state = false},
    {path = NATIVE_CLASS .. ":NotifyEnemyKilled", label = "NotifyEnemyKilled", state = false},
    {path = GAME_STATE .. ":OnIncursionCleared_Event", label = "OnIncursionCleared_Event", state = true},
    {path = GAME_STATE .. ":AdvanceRound", label = "AdvanceRound", state = true},
    {path = GAME_STATE .. ":OnTimer_WaveCleared", label = "OnTimer_WaveCleared", state = true},
    {path = GAME_STATE .. ":ReinitDiscoState", label = "ReinitDiscoState", state = true},
    {path = GAME_STATE .. ":HandleLevelEnded", label = "HandleLevelEnded", state = true},
    {path = GAME_STATE .. ":HandleLevelRestarted", label = "HandleLevelRestarted", state = true},
}
-- All seven are OWNED scalar fields in the successful captured metadata pass.
-- No free-play field is proved; no referenced component or hook argument is read.
local SCALARS = {
    {name = "round", kind = "int32"},
    {name = "bIsActive", kind = "boolean"},
    {name = "bIsInfinite", kind = "boolean"},
    {name = "bInfiniteDiscoByUI", kind = "boolean"},
    {name = "bWaveClearedRequested", kind = "boolean"},
    {name = "DoInfiniteDiscoNextSong", kind = "boolean"},
    {name = "bShowSongListOnNextLevelRestart", kind = "boolean"},
}
local MAX_TOTAL_LINES = 768
local MAX_LINE_BYTES = 3072
local MAX_TEXT_BYTES = 768
local MAX_EVENTS_PER_HOOK = 300
local MAX_CONTEXTS = 8
local MAX_ATTEMPTS_PER_TARGET = 3
local lines, capped, sequence, context_count = 0, false, 0, 0
local registered, attempts, event_counts, previous = {}, {}, {}, {}
local function clean(value)
    local text = tostring(value):gsub("[%c]", " ")
    if #text > MAX_TEXT_BYTES then return text:sub(1, MAX_TEXT_BYTES) .. "<truncated>" end
    return text
end
local function emit(message)
    if capped then return end
    local prefix = "[DADAPWave] utc=" .. os.date("!%Y-%m-%dT%H:%M:%SZ")
        .. " nonce=" .. SESSION_NONCE .. " build=" .. PROBE_BUILD .. " "
    if lines >= MAX_TOTAL_LINES - 1 then
        print(prefix .. "output_cap_reached; observation incomplete\n")
        lines, capped = lines + 1, true
        return
    end
    local line = prefix .. message
    if #line > MAX_LINE_BYTES then line = line:sub(1, MAX_LINE_BYTES - 12) .. " <truncated>" end
    print(line .. "\n")
    lines = lines + 1
end
local function scalar_snapshot(object)
    local values = {}
    for _, field in ipairs(SCALARS) do
        local ok, value = pcall(function() return object:GetPropertyValue(field.name) end)
        local text
        if not ok then
            text = "<read-error>"
        elseif field.kind == "boolean" and type(value) == "boolean" then
            text = tostring(value)
        elseif field.kind == "int32" and type(value) == "number"
            and value >= -2147483648 and value <= 2147483647 and value % 1 == 0 then
            text = tostring(value)
        else
            -- Never stringify a non-scalar UE4SS value or call any returned member.
            text = "<unexpected-type>"
        end
        values[#values + 1] = field.name .. "=" .. text
    end
    return table.concat(values, ",")
end
local function observe(target, context, argument_count)
    if capped then return end
    local count = (event_counts[target.path] or 0) + 1
    event_counts[target.path] = count
    if count > MAX_EVENTS_PER_HOOK then
        if count == MAX_EVENTS_PER_HOOK + 1 then emit("event_cap_reached hook=" .. target.label) end
        return
    end
    sequence = sequence + 1
    local event = "event=" .. target.label .. " seq=" .. sequence
        .. " hook_count=" .. count .. " phase=post argument_count=" .. argument_count
    -- Only unwrap self. Function parameters and return wrappers are never read.
    local object = context:get()
    if not object or not object:IsValid() then
        emit(event .. " context=<invalid>; no scalar reads")
        return
    end
    local identity = object:GetFullName()
    local class = object:GetClass()
    if not class or not class:IsValid() then
        emit(event .. " context=" .. clean(identity) .. " class=<invalid>; no scalar reads")
        return
    end
    local class_name = class:GetFullName()
    event = event .. " context=" .. clean(identity) .. " class=" .. clean(class_name)
    if not target.state then
        emit(event .. " state=<context-is-not-game-state>")
        return
    end
    if class_name ~= EXPECTED_STATE_CLASS then
        emit(event .. " state=<exact-class-mismatch>; no scalar reads")
        return
    end
    if type(identity) ~= "string" or #identity > MAX_TEXT_BYTES then
        emit(event .. " state=<identity-too-long>; no scalar reads")
        return
    end
    local prior = previous[identity]
    if not prior and context_count >= MAX_CONTEXTS then
        emit(event .. " state=<context-cap>; no scalar reads")
        return
    end
    local current = scalar_snapshot(object)
    local prior_text = prior and ("seq=" .. prior.sequence .. "," .. prior.snapshot) or "<none>"
    -- A prior post snapshot is NOT a pre-call read. Keep only Lua strings/numbers;
    -- retain no UObject or parameter wrapper after this synchronous callback.
    emit(event .. " previous_observation={" .. prior_text .. "} current_post={" .. current .. "}")
    if not prior then context_count = context_count + 1 end
    previous[identity] = {sequence = sequence, snapshot = current}
end
local function register_available()
    if capped then return end
    for _, target in ipairs(TARGETS) do
        local count = attempts[target.path] or 0
        if not registered[target.path] and count < MAX_ATTEMPTS_PER_TARGET then
            attempts[target.path] = count + 1
            local ok, result = pcall(function()
                local found = StaticFindObject(target.path)
                if not found or not found:IsValid() then return false end
                local callback = function(context, ...)
                    local callback_ok, error_text = pcall(observe, target, context, select("#", ...))
                    if not callback_ok then emit("callback_error hook=" .. target.label .. " detail=" .. clean(error_text)) end
                    return nil
                end
                if target.state then
                    RegisterHook(target.path, callback)
                else
                    RegisterHook(target.path, function() return nil end, callback)
                end
                return true
            end)
            if ok and result == true then
                registered[target.path] = true
                emit("registered=" .. target.path)
            elseif not ok then
                emit("registration_error=" .. target.path .. " detail=" .. clean(result))
            else
                emit("not_loaded=" .. target.path .. " attempt=" .. attempts[target.path])
            end
        end
    end
end
local function arrange(class_path)
    -- Allowlisted base-class notification may include subclasses. Ignore its
    -- constructed object; only retry exact function descriptors, once then remove.
    local ok, error_text = pcall(NotifyOnNewObject, class_path, function()
        if not capped then
            local queued, queue_error = pcall(ExecuteInGameThread, register_available)
            if not queued then emit("registration_queue_error detail=" .. clean(queue_error)) end
        end
        return true
    end)
    if not ok then emit("notification_error class=" .. class_path .. " detail=" .. clean(error_text)) end
end
emit("enabled observation_only=true AP_checks=false free_play_mode=unverified prior_is_previous_post=true")
arrange(GAME_STATE)
arrange(NATIVE_CLASS)
local queued, queue_error = pcall(ExecuteInGameThread, register_available)
if not queued then emit("initial_queue_error detail=" .. clean(queue_error)) end
