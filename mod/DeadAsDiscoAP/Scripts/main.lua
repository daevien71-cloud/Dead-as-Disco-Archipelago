-- Dead as Disco <-> Archipelago bridge (UE4SS Lua mod).
--
-- Reports Arcade waves, kills and deaths to the Archipelago client through files in
-- %LOCALAPPDATA%\DeadAsDiscoAP, and applies traps, buffs and DeathLink kills it asks for.
-- Debug hotkeys (work during a run, no client needed):
--   Ctrl+F5 slow-mo  Ctrl+F6 fast-forward  Ctrl+F7 molasses  Ctrl+F8 blackout
--   Ctrl+F9 disco fever  Ctrl+F10 test kill  Ctrl+F11 write a status line to the log

local VERSION = "0.1.0"

local GAME_STATE_CLASS = "BP_PagodaGameState_InfiniteDisco_C"
local GAME_STATE = "/Game/Pagoda/Core/GameModes/InfiniteDisco/BP_PagodaGameState_InfiniteDisco.BP_PagodaGameState_InfiniteDisco_C"
local SUBSYSTEM = "/Script/Pagoda.PagodaInfiniteDiscoSubsystem"
local PLAYER_CLASS = "BP_PagodaPlayerCharacter_Charlie_C"
local PLAYER = "/Game/Pagoda/Characters/Player/BP_PagodaPlayerCharacter_Charlie.BP_PagodaPlayerCharacter_Charlie_C"
local CONTROLLER_CLASS = "BP_PagodaPlayerController_C"
local COMBAT_LIBRARY = "/Script/Pagoda.PagodaCombatFunctionLibrary"

local TICK_MS = 250
local STATUS_EVERY_TICKS = 4
local REGISTER_EVERY_TICKS = 8
local SEARCH_EVERY_TICKS = 4
local KILL_STAGE_SECONDS = 3

-- Effect tuning. Global dilation slows or speeds the whole game; the music (FMOD) keeps its own clock.
local SLOWMO_SPEED = 0.6
local FASTFORWARD_SPEED = 1.4
local MOLASSES_SPEED = 0.6
local FEVER_WORLD_SPEED = 0.65
local BLACKOUT_ALPHA = 0.9

local function log(message)
    print("[DeadAsDiscoAP] " .. tostring(message) .. "\n")
end

local json
do
    local ok, result = pcall(require, "json")
    if not ok then
        local here = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
        result = dofile(here .. "json.lua")
    end
    json = result
end

local BRIDGE_DIR = (os.getenv("LOCALAPPDATA") or ".") .. "\\DeadAsDiscoAP\\"
local EVENTS_PATH = BRIDGE_DIR .. "events.jsonl"
local COMMANDS_PATH = BRIDGE_DIR .. "commands.jsonl"
local STATUS_PATH = BRIDGE_DIR .. "status.json"

math.randomseed(os.time())
local session = string.format("%d-%06d", os.time(), math.random(0, 999999))

---------------------------------------------------------------------------------------------
-- Bridge files
---------------------------------------------------------------------------------------------

local bridge_ready = false
local event_seq = 0
local queued_events = {}

local function open_bridge()
    if bridge_ready then return true end
    local file = io.open(EVENTS_PATH, "w")
    if not file then return false end
    file:write(json.encode({type = "hello", session = session, version = VERSION, t = os.time()}) .. "\n")
    file:close()
    bridge_ready = true
    log("bridge open at " .. BRIDGE_DIR)
    return true
end

local function emit(event)
    event_seq = event_seq + 1
    event.seq = event_seq
    event.t = os.time()
    if #queued_events < 2000 then queued_events[#queued_events + 1] = json.encode(event) end
end

local function flush_events()
    if #queued_events == 0 or not open_bridge() then return end
    local file = io.open(EVENTS_PATH, "a")
    if not file then return end
    file:write(table.concat(queued_events, "\n") .. "\n")
    file:close()
    queued_events = {}
end

local function emit_log(text)
    log(text)
    emit({type = "log", text = text})
end

local command_offset = nil
local command_partial = ""
local last_command_id = {}

local function file_size(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

local function read_commands()
    local size = file_size(COMMANDS_PATH)
    if command_offset == nil then
        -- Ignore commands written before the game started.
        command_offset = size or 0
        return {}
    end
    if not size then return {} end
    if size < command_offset then
        command_offset, command_partial = 0, "" -- the client restarted and truncated the file
    end
    if size == command_offset then return {} end
    local file = io.open(COMMANDS_PATH, "rb")
    if not file then return {} end
    file:seek("set", command_offset)
    local data = file:read(size - command_offset) or ""
    file:close()
    command_offset = command_offset + #data
    data = command_partial .. data
    local commands = {}
    local last = 1
    for line, finish in data:gmatch("([^\n]*)\n()") do
        last = finish
        local ok, value = pcall(json.decode, line)
        if ok and type(value) == "table" then commands[#commands + 1] = value end
    end
    command_partial = data:sub(last)
    return commands
end

---------------------------------------------------------------------------------------------
-- Game objects
---------------------------------------------------------------------------------------------

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function find_live(short_class)
    local all = FindAllOf(short_class)
    if not all then return nil end
    for _, object in pairs(all) do
        if object:IsValid() and not object:GetFullName():find("Default__", 1, true) then
            return object
        end
    end
    return nil
end

local cached = {}
local function cached_find(key, short_class)
    if valid(cached[key]) then return cached[key] end
    cached[key] = find_live(short_class)
    return cached[key]
end

local function game_state() return cached_find("state", GAME_STATE_CLASS) end
local function player() return cached_find("player", PLAYER_CLASS) end
local function controller() return cached_find("controller", CONTROLLER_CLASS) end

local gameplay_statics = nil
local function statics()
    if not valid(gameplay_statics) then
        gameplay_statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    return gameplay_statics
end

---------------------------------------------------------------------------------------------
-- Run tracking
---------------------------------------------------------------------------------------------

local run = {active = false, round = 0, cleared = 0, dead = false}

local end_effect -- forward declaration

local function report_cleared(wave)
    if wave > run.cleared then
        run.cleared = wave
        emit({type = "wave", wave = wave})
    end
end

local function reset_run(reason)
    if run.active or run.cleared > 0 then
        emit({type = "run_end", reason = reason, cleared = run.cleared})
    end
    run = {active = false, round = 0, cleared = 0, dead = false}
    end_effect("run_ended")
end

local function observe_round(round)
    if type(round) ~= "number" then return end
    if round < run.round then reset_run("new_run") end
    if round == run.round then return end
    if run.dead and round > run.round then
        run.dead = false -- the game moved on to another wave, so the player got back up
    end
    run.round = round
    if round >= 1 and not run.dead then
        if not run.active then emit({type = "run_start"}) end
        run.active = true
    end
    if round >= 2 then report_cleared(round - 1) end
end

local function read_round(state)
    local ok, round = pcall(function() return state:GetPropertyValue("round") end)
    if ok and type(round) == "number" then return round end
    return nil
end

local function in_run()
    return run.active and not run.dead and valid(game_state())
end

---------------------------------------------------------------------------------------------
-- Effects (traps and buffs)
---------------------------------------------------------------------------------------------

local active_effect = nil -- {key, command_id, ends_at, revert}

local function world_context()
    local p = player()
    if valid(p) then return p end
    return game_state()
end

local function set_global_speed(speed)
    statics():SetGlobalTimeDilation(world_context(), speed)
    return statics():GetGlobalTimeDilation(world_context())
end

local function set_player_speed(speed)
    local p = player()
    if not valid(p) then error("player character not found") end
    p.CustomTimeDilation = speed
    return p.CustomTimeDilation
end

local function camera_fade(from_alpha, to_alpha, hold)
    local pc = controller()
    if not valid(pc) then error("player controller not found") end
    local camera = pc.PlayerCameraManager
    if not valid(camera) then error("camera manager not found") end
    camera:StartCameraFade(from_alpha, to_alpha, 0.75, {R = 0.0, G = 0.0, B = 0.0, A = 1.0}, false, hold)
    return to_alpha
end

local EFFECTS = {
    slowmo = {
        apply = function() return set_global_speed(SLOWMO_SPEED) end,
        revert = function() set_global_speed(1.0) end,
    },
    fastforward = {
        apply = function() return set_global_speed(FASTFORWARD_SPEED) end,
        revert = function() set_global_speed(1.0) end,
    },
    molasses = {
        apply = function() return set_player_speed(MOLASSES_SPEED) end,
        revert = function() set_player_speed(1.0) end,
    },
    fever = {
        -- Slow the world, then speed the player back up so only enemies are slowed.
        apply = function()
            local world = set_global_speed(FEVER_WORLD_SPEED)
            set_player_speed(1.0 / FEVER_WORLD_SPEED)
            return world
        end,
        revert = function()
            set_global_speed(1.0)
            set_player_speed(1.0)
        end,
    },
    blackout = {
        apply = function() return camera_fade(0.0, BLACKOUT_ALPHA, true) end,
        revert = function() camera_fade(BLACKOUT_ALPHA, 0.0, false) end,
    },
}

end_effect = function(reason)
    local effect = active_effect
    if not effect then return end
    active_effect = nil
    local ok, err = pcall(effect.revert)
    if not ok then log("could not revert " .. effect.key .. ": " .. tostring(err)) end
    emit({type = "effect_end", effect = effect.key, command_id = effect.command_id, reason = reason})
end

local function start_effect(key, duration, command_id)
    local definition = EFFECTS[key]
    if not definition then
        emit({type = "effect_failed", effect = key, command_id = command_id, reason = "unknown effect"})
        return
    end
    if not in_run() then
        emit({type = "effect_failed", effect = key, command_id = command_id, reason = "not_in_run"})
        return
    end
    end_effect("replaced")
    local ok, result = pcall(definition.apply)
    if not ok then
        emit_log("effect " .. key .. " failed: " .. tostring(result))
        emit({type = "effect_failed", effect = key, command_id = command_id, reason = tostring(result)})
        pcall(definition.revert)
        return
    end
    duration = math.max(1, math.min(tonumber(duration) or 15, 120))
    active_effect = {key = key, command_id = command_id, ends_at = os.time() + duration, revert = definition.revert}
    emit({type = "effect_start", effect = key, command_id = command_id, value = tostring(result), duration = duration})
    log("effect " .. key .. " on for " .. duration .. "s (value " .. tostring(result) .. ")")
end

---------------------------------------------------------------------------------------------
-- DeathLink kill
---------------------------------------------------------------------------------------------

-- The first time an enemy damages the player, remember how the game applied it, so a
-- DeathLink can apply a lethal hit the same way.
local learned_damage = nil -- {effect = UClass, tag = string, sign = 1 or -1}
local damage_samples_logged = 0
local pending_kill = nil -- {stage, at}
local last_death_at = -100

local function lethal_learned_hit()
    if not learned_damage then error("no enemy hit seen yet this session") end
    local library = StaticFindObject("/Script/Pagoda.Default__PagodaCombatFunctionLibrary")
    if not valid(library) then error("combat library not found") end
    library:ApplySetByCallerEffect(player(), learned_damage.effect,
        {TagName = FName(learned_damage.tag)}, 99999 * learned_damage.sign)
end

local function engine_damage()
    statics():ApplyDamage(player(), 99999, controller(), player(), nil)
end

local function finish_death()
    player():FinishDeath()
end

local KILL_STAGES = {
    {name = "learned enemy hit", run = lethal_learned_hit},
    {name = "engine ApplyDamage", run = engine_damage},
    {name = "FinishDeath", run = finish_death},
}

local function try_kill_stage(stage)
    local definition = KILL_STAGES[stage]
    if not definition then
        pending_kill = nil
        emit_log("DeathLink kill failed: every method was tried")
        emit({type = "kill_failed"})
        return
    end
    pending_kill = {stage = stage, at = os.time()}
    local ok, err = pcall(definition.run)
    if ok then
        log("kill stage " .. stage .. " (" .. definition.name .. ") called")
    else
        log("kill stage " .. stage .. " (" .. definition.name .. ") error: " .. tostring(err))
        pending_kill.at = -100 -- move on next tick
    end
end

local function request_kill(source)
    if not in_run() or not valid(player()) then
        emit({type = "kill_failed", reason = "not_in_run"})
        return
    end
    log("DeathLink kill requested (" .. tostring(source) .. ")")
    try_kill_stage(1)
end

local function on_player_death()
    local now = os.time()
    if now - last_death_at < 3 then return end
    last_death_at = now
    if pending_kill then
        emit_log("DeathLink kill worked with method " .. pending_kill.stage .. " (" .. KILL_STAGES[pending_kill.stage].name .. ")")
        pending_kill = nil
    end
    run.dead = true
    run.active = false
    end_effect("player_died")
    emit({type = "death", round = run.round, cleared = run.cleared})
end

local function on_damage_effect(target, effect, tag, value)
    local target_object = target:get()
    if not valid(target_object) then return end
    local target_name = target_object:GetFullName()
    local effect_class = effect:get()
    local effect_name = valid(effect_class) and effect_class:GetFullName() or "?"
    local tag_name = "?"
    pcall(function() tag_name = tag:get().TagName:ToString() end)
    local amount = value:get()
    if damage_samples_logged < 12 then
        damage_samples_logged = damage_samples_logged + 1
        log(string.format("damage sample: target=%s effect=%s tag=%s value=%s",
            target_name, effect_name, tag_name, tostring(amount)))
    end
    if not learned_damage and target_name:find(PLAYER_CLASS, 1, true) and valid(effect_class)
        and tag_name ~= "?" and type(amount) == "number" and amount ~= 0 then
        learned_damage = {effect = effect_class, tag = tag_name, sign = amount > 0 and 1 or -1}
        emit_log("learned how enemies damage you: " .. effect_name .. " / " .. tag_name)
    end
end

---------------------------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------------------------

local pending_kills = 0

local function state_hook(name)
    return function(context)
        local state = context:get()
        if not valid(state) then return end
        cached.state = state
        if name == "ReinitDiscoState" then
            reset_run("reinit")
            run.round = read_round(state) or 0
        elseif name == "HandleLevelEnded" or name == "HandleLevelRestarted" then
            reset_run(name)
        elseif name == "OnIncursionCleared_Event" then
            local round = read_round(state)
            if round and round >= 1 and not run.dead then report_cleared(round) end
        else
            observe_round(read_round(state))
        end
    end
end

-- {path, callback, native}. Native functions get a post-hook; blueprint hooks always run after.
local HOOKS = {
    {path = GAME_STATE .. ":ReinitDiscoState", callback = state_hook("ReinitDiscoState")},
    {path = GAME_STATE .. ":AdvanceRound", callback = state_hook("AdvanceRound")},
    {path = GAME_STATE .. ":OnIncursionCleared_Event", callback = state_hook("OnIncursionCleared_Event")},
    {path = GAME_STATE .. ":HandleLevelEnded", callback = state_hook("HandleLevelEnded")},
    {path = GAME_STATE .. ":HandleLevelRestarted", callback = state_hook("HandleLevelRestarted")},
    {path = SUBSYSTEM .. ":NotifyEnemyKilled", native = true,
     callback = function() pending_kills = pending_kills + 1 end},
    {path = PLAYER .. ":OnDeathStartedDelegate_Event", callback = function() on_player_death() end},
    {path = COMBAT_LIBRARY .. ":ApplySetByCallerEffect", native = true, pre = true,
     callback = function(_, target, effect, tag, value) on_damage_effect(target, effect, tag, value) end},
}

local registered = {} -- path -> address of the UFunction we hooked

local function register_hooks()
    for _, hook in ipairs(HOOKS) do
        local ok, err = pcall(function()
            local fn = StaticFindObject(hook.path)
            if not valid(fn) then return end
            local address = fn:GetAddress()
            if registered[hook.path] == address then return end
            local safe = function(...)
                local call_ok, call_err = pcall(hook.callback, ...)
                if not call_ok then log("hook error in " .. hook.path .. ": " .. tostring(call_err)) end
            end
            if hook.native and not hook.pre then
                RegisterHook(hook.path, function() end, safe)
            else
                RegisterHook(hook.path, safe)
            end
            registered[hook.path] = address
            log("hooked " .. hook.path)
        end)
        if not ok then log("could not hook " .. hook.path .. ": " .. tostring(err)) end
    end
end

---------------------------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------------------------

local function handle_command(command)
    local client, id = command.session, command.id
    if type(client) == "string" and type(id) == "number" then
        if (last_command_id[client] or 0) >= id then return end
        last_command_id[client] = id
    end
    if command.type == "effect" then
        start_effect(command.effect, command.duration, command.id)
    elseif command.type == "kill" then
        request_kill(command.source)
    end
end

local function write_status()
    if not open_bridge() then return end
    local file = io.open(STATUS_PATH, "w")
    if not file then return end
    file:write(json.encode({
        version = VERSION, session = session, t = os.time(), in_run = in_run(),
        round = run.round, cleared = run.cleared, dead = run.dead,
        effect = active_effect and active_effect.key or nil,
        learned_damage = learned_damage ~= nil,
    }))
    file:close()
end

local function status_line()
    return string.format("status: in_run=%s round=%d cleared=%d dead=%s effect=%s learned_damage=%s hooks=%d",
        tostring(in_run()), run.round, run.cleared, tostring(run.dead),
        active_effect and active_effect.key or "none", tostring(learned_damage ~= nil),
        (function() local n = 0 for _ in pairs(registered) do n = n + 1 end return n end)())
end

local tick_count = 0

local function tick()
    tick_count = tick_count + 1
    if tick_count % REGISTER_EVERY_TICKS == 1 then register_hooks() end

    -- Poll the wave counter as a backstop for missed hook calls.
    if tick_count % SEARCH_EVERY_TICKS == 0 or valid(cached.state) then
        local state = game_state()
        if valid(state) then
            observe_round(read_round(state))
        elseif run.active then
            reset_run("left_arcade")
        end
    end

    if pending_kills > 0 then
        emit({type = "kill", count = pending_kills})
        pending_kills = 0
    end

    if active_effect and os.time() >= active_effect.ends_at then end_effect("expired") end

    if pending_kill and os.time() - pending_kill.at >= KILL_STAGE_SECONDS then
        if run.dead then
            pending_kill = nil
        else
            try_kill_stage(pending_kill.stage + 1)
        end
    end

    if open_bridge() then
        for _, command in ipairs(read_commands()) do handle_command(command) end
    end
    if tick_count % STATUS_EVERY_TICKS == 0 then write_status() end
    flush_events()
end

local tick_queued = false
LoopAsync(TICK_MS, function()
    if not tick_queued then
        tick_queued = true
        ExecuteInGameThread(function()
            local ok, err = pcall(tick)
            tick_queued = false
            if not ok then log("tick error: " .. tostring(err)) end
        end)
    end
    return false
end)

local function hotkey(key, action)
    RegisterKeyBind(key, {ModifierKey.CONTROL}, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(action)
            if not ok then log("hotkey error: " .. tostring(err)) end
        end)
    end)
end

hotkey(Key.F5, function() start_effect("slowmo", 10, "hotkey") end)
hotkey(Key.F6, function() start_effect("fastforward", 10, "hotkey") end)
hotkey(Key.F7, function() start_effect("molasses", 10, "hotkey") end)
hotkey(Key.F8, function() start_effect("blackout", 10, "hotkey") end)
hotkey(Key.F9, function() start_effect("fever", 10, "hotkey") end)
hotkey(Key.F10, function() request_kill("hotkey") end)
hotkey(Key.F11, function() emit_log(status_line()) end)

log("Dead as Disco AP " .. VERSION .. " loaded; session " .. session)
