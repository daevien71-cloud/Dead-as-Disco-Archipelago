-- Dead as Disco <-> Archipelago bridge (UE4SS Lua mod).
--
-- Reports Arcade waves, kills and deaths to the Archipelago client through files in
-- %LOCALAPPDATA%\DeadAsDiscoAP, and applies traps, buffs and DeathLink kills it asks for.
-- Ctrl+Home shows a status pop-up and log line (not F11: that toggles the game's fullscreen). With TEST_HOTKEYS on, during a run:
--   Ctrl+F5 slow-mo  Ctrl+F6 fast-forward  Ctrl+F7 molasses  Ctrl+F8 blackout
--   Ctrl+F9 disco fever  Ctrl+F10 kill yourself (a real death: it goes out over DeathLink)

local VERSION = "0.2.0"
local TEST_HOTKEYS = false -- off for real sessions; the client's /testeffect and /testkill still work

local GAME_STATE_CLASS = "BP_PagodaGameState_InfiniteDisco_C"
local GAME_STATE = "/Game/Pagoda/Core/GameModes/InfiniteDisco/BP_PagodaGameState_InfiniteDisco.BP_PagodaGameState_InfiniteDisco_C"
local SUBSYSTEM = "/Script/Pagoda.PagodaInfiniteDiscoSubsystem"
local PLAYER_CLASS = "BP_PagodaPlayerCharacter_Charlie_C"
local PLAYER = "/Game/Pagoda/Characters/Player/BP_PagodaPlayerCharacter_Charlie.BP_PagodaPlayerCharacter_Charlie_C"
local CONTROLLER_CLASS = "BP_PagodaPlayerController_C"

local TICK_MS = 250
local STATUS_EVERY_TICKS = 4
local REGISTER_EVERY_TICKS = 8
local SEARCH_EVERY_TICKS = 4

-- Effect tuning. Global dilation slows or speeds the whole game; the music (FMOD) keeps its own clock.
local SLOWMO_SPEED = 0.6
local FASTFORWARD_SPEED = 1.4
local MOLASSES_SPEED = 0.6
local FEVER_WORLD_SPEED = 0.65
local BLACKOUT_ALPHA = 0.98

local function log(message)
    print("[DeadAsDiscoAP] " .. tostring(message) .. "\n")
end

local json
local meteor
do
    local ok, result = pcall(require, "json")
    if not ok then
        local here = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
        result = dofile(here .. "json.lua")
    end
    json = result
    local loaded, adapter = pcall(function()
        local found, module = pcall(require, "meteor")
        if not found then
            local here = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
            module = dofile(here .. "meteor.lua")
        end
        return assert(module.new(log), "meteor adapter construction returned nil")
    end)
    if loaded then meteor = adapter
    else log("meteor unavailable: " .. tostring(adapter)) end
end

-- The installer writes the bridge folder into bridge_dir.txt next to the Scripts folder; the
-- environment is only a fallback because the game's environment can't be relied on.
local function resolve_bridge_dir()
    local here = (debug.getinfo(1, "S").source or ""):match("^@(.*[\\/])")
    if here then
        local file = io.open(here .. "..\\bridge_dir.txt", "r")
        if file then
            local line = (file:read("l") or ""):gsub("%s+$", "")
            file:close()
            if line ~= "" then return line:gsub("[\\/]?$", "\\"), "bridge_dir.txt" end
        end
    end
    local localappdata = os.getenv("LOCALAPPDATA")
    if localappdata then return localappdata .. "\\DeadAsDiscoAP\\", "LOCALAPPDATA" end
    local profile = os.getenv("USERPROFILE")
    if profile then return profile .. "\\AppData\\Local\\DeadAsDiscoAP\\", "USERPROFILE" end
    return ".\\DeadAsDiscoAP\\", "working directory"
end

local BRIDGE_DIR, BRIDGE_SOURCE = resolve_bridge_dir()
local EVENTS_PATH = BRIDGE_DIR .. "events.jsonl"
local COMMANDS_PATH = BRIDGE_DIR .. "commands.jsonl"
local STATUS_PATH = BRIDGE_DIR .. "status.json"

math.randomseed(os.time())
local session = string.format("%d-%06d", os.time(), math.random(0, 999999))

---------------------------------------------------------------------------------------------
-- Bridge files
---------------------------------------------------------------------------------------------

local bridge_ready = false
local bridge_error_logged = false
local event_seq = 0
local queued_events = {}

local function open_bridge()
    if bridge_ready then return true end
    local file, err = io.open(EVENTS_PATH, "w")
    if not file then
        if not bridge_error_logged then
            bridge_error_logged = true
            log("cannot write to the bridge folder " .. BRIDGE_DIR .. " (from " .. BRIDGE_SOURCE .. "): " .. tostring(err))
        end
        return false
    end
    file:write(json.encode({type = "hello", session = session, version = VERSION, t = os.time()}) .. "\n")
    file:close()
    bridge_ready = true
    log("bridge open at " .. BRIDGE_DIR .. " (from " .. BRIDGE_SOURCE .. ")")
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

local gameplay_statics = nil
local function statics()
    if not valid(gameplay_statics) then
        gameplay_statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    return gameplay_statics
end

-- A restart can leave an old Charlie UObject valid. Resolve the controlled pawn
-- from the current world instead of taking the first actor of its class.
local function player()
    local state = game_state()
    if valid(state) then cached.player = statics():GetPlayerPawn(state, 0) end
    return valid(cached.player) and cached.player or nil
end

local function controller()
    local state = game_state()
    if valid(state) then cached.controller = statics():GetPlayerController(state, 0) end
    return valid(cached.controller) and cached.controller or cached_find("controller", CONTROLLER_CLASS)
end

---------------------------------------------------------------------------------------------
-- Run tracking
---------------------------------------------------------------------------------------------

local run = {active = false, round = 0, cleared = 0, dead = false, ended = false}

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
    run = {active = false, round = 0, cleared = 0, dead = false, ended = true}
    end_effect("run_ended")
end

local function observe_round(round)
    -- A level-end callback can precede destruction of its state. Its stale round must
    -- not reactivate effects while the menu or next scene is opening.
    if run.ended then return end
    if type(round) ~= "number" then return end
    if round < run.round then reset_run("new_run"); run.ended = false end
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
local popup -- defined with the pop-ups below
local SUPPORTED_EFFECTS = {"slowmo", "fastforward", "molasses", "blackout", "fever"}
if meteor then SUPPORTED_EFFECTS[#SUPPORTED_EFFECTS + 1] = "meteor" end

local function meteor_ready()
    if not meteor then return false, "unsupported" end
    if not in_run() then return false, "not_in_run" end
    if active_effect then return false, "busy" end
    local ok, ready, reason = pcall(function()
        if game_state().bWaveClearedRequested then return false, "downtime" end
        return meteor:ready(player())
    end)
    if not ok then
        log("meteor readiness failed: " .. tostring(ready))
        return false, "spawn_failed"
    end
    return ready, reason
end

local EFFECT_POPUPS = {
    slowmo = "SLOW-MO! Everything slows down",
    fastforward = "FAST-FORWARD! Everything speeds up",
    molasses = "MOLASSES! You're stuck in slow motion",
    blackout = "BLACKOUT!",
    fever = "DISCO FEVER! Enemies slowed",
    meteor = "METEOR INCOMING! Move away from this spot!",
}

local function meteor_warning(index, count)
    return string.format("METEOR %d OF %d! Move from the marked spot!", index, count)
end

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
    meteor = {
        apply = function()
            if not meteor then error({reason = "unsupported"}) end
            local ok, count_or_reason = meteor:start(player(), game_state(), function(index, count)
                if index > 1 then popup(meteor_warning(index, count)) end
            end)
            if not ok then error({reason = count_or_reason}) end
            return count_or_reason
        end,
        revert = function() if meteor then meteor:stop("effect_ended") end end,
    },
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
    -- A meteor owns the warning, flight and kickable remnant as one effect. Manual test
    -- commands must obey the same exclusivity as the AP queue, including Blackout.
    if key == "meteor" or (active_effect and active_effect.key == "meteor") then
        local ready, reason = meteor_ready()
        if not ready then
            emit({type = "effect_failed", effect = key, command_id = command_id, reason = reason})
            return
        end
    end
    end_effect("replaced")
    local ok, result = pcall(definition.apply)
    if not ok then
        local reason = tostring(result)
        local detail = reason
        if key == "meteor" then
            reason = "spawn_failed"
            if type(result) == "table" then
                local code = result.reason
                detail = tostring(result.detail or code or result)
                local known = {spawn_blocked = true, asset_unavailable = true, spawn_failed = true,
                    unsupported = true, busy = true, paused = true, airborne = true, downtime = true, not_in_run = true}
                if known[code] then reason = code end
            end
        end
        emit_log("effect " .. key .. " failed: " .. detail)
        emit({type = "effect_failed", effect = key, command_id = command_id, reason = reason})
        pcall(definition.revert)
        return
    end
    duration = math.max(1, math.min(tonumber(duration) or 15, 120))
    active_effect = {key = key, command_id = command_id, revert = definition.revert}
    if key ~= "meteor" then active_effect.ends_at = os.time() + duration end
    emit({type = "effect_start", effect = key, command_id = command_id, value = tostring(result),
        duration = key ~= "meteor" and duration or nil, meteor_count = key == "meteor" and result or nil})
    popup(key == "meteor" and meteor_warning(1, result) or (EFFECT_POPUPS[key] .. " (" .. duration .. "s)"))
    log("effect " .. key .. (key == "meteor" and " on (native lifecycle)" or (" on for " .. duration .. "s"))
        .. " (value " .. tostring(result) .. ")")
end

---------------------------------------------------------------------------------------------
-- DeathLink kill
---------------------------------------------------------------------------------------------

-- The game's damage effect (Characters/Common/Effects) and its native SetByCaller tag (from the exe).
-- Never apply GE_Die: it only marks a character as dead (Status.Death.Dead) without killing it, which
-- left the player unable to deal or take damage.
local GE_DAMAGE = "/Game/Pagoda/Characters/Common/Effects/GE_Damage_SetByCaller.GE_Damage_SetByCaller_C"
local DAMAGE_TAG = "SetByCaller.Damage"
local KILL_ATTEMPTS = 12        -- one every KILL_ATTEMPT_TICKS, so ~6 seconds in all
local KILL_ATTEMPT_TICKS = 2

local pending_kill = nil -- {attempt, ticks}
local last_death_at = -100

local function load_class(path)
    local class = StaticFindObject(path)
    if valid(class) then return class end
    local package = path:match("^(.-)%.")
    for _, name in ipairs({path, package}) do
        pcall(LoadAsset, name)
        class = StaticFindObject(path)
        if valid(class) then return class end
    end
    error("could not load " .. path)
end

local function player_health()
    local ok, value = pcall(function() return player():GetHealth() end)
    return ok and tostring(value) or "?"
end

-- Leave the player on a sliver of health so any damage that lands is lethal, even if the game caps
-- damage per hit (MaxDamageInHearts).
local function lower_health()
    local health = player().HealthAttributeSet.Health
    health.BaseValue = 0.01
    health.CurrentValue = 0.01
end

local function damage_player()
    local library = StaticFindObject("/Script/Pagoda.Default__PagodaCombatFunctionLibrary")
    if not valid(library) then error("combat library not found") end
    library:ApplySetByCallerEffect(player(), load_class(GE_DAMAGE), {TagName = FName(DAMAGE_TAG)}, 9999)
end

local function kill_attempt()
    local kill = pending_kill
    kill.attempt = kill.attempt + 1
    kill.ticks = 0
    if kill.attempt > KILL_ATTEMPTS then
        pending_kill = nil
        emit_log("DeathLink kill failed after " .. KILL_ATTEMPTS .. " hits (health " .. player_health() .. ")")
        emit({type = "kill_failed"})
        return
    end
    local before = player_health()
    if kill.attempt >= 2 then
        local ok, err = pcall(lower_health)
        if not ok and kill.attempt == 2 then log("could not lower health: " .. tostring(err)) end
    end
    local ok, err = pcall(damage_player)
    log(string.format("kill hit %d: health %s -> %s%s", kill.attempt, before, player_health(),
        ok and "" or (" error: " .. tostring(err))))
end

local function request_kill(source)
    if pending_kill then return end -- one attempt at a time
    if not in_run() or not valid(player()) then
        emit({type = "kill_failed", reason = "not_in_run"})
        return
    end
    log("DeathLink kill requested (" .. tostring(source) .. ")")
    pending_kill = {attempt = 0, ticks = 0}
    kill_attempt()
end

local function on_player_death()
    local now = os.time()
    if now - last_death_at < 3 then return end
    last_death_at = now
    if pending_kill then
        emit_log("DeathLink kill worked on hit " .. pending_kill.attempt)
        pending_kill = nil
    end
    run.dead = true
    run.active = false
    end_effect("player_died")
    emit({type = "death", round = run.round, cleared = run.cleared})
end

---------------------------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------------------------

local pending_kills = 0

local function state_hook(name)
    return function(context)
        local state = context:get()
        if not valid(state) then return end
        if valid(cached.state) and cached.state:GetAddress() ~= state:GetAddress() then
            reset_run("state_changed")
            cached.player, cached.controller = nil, nil
        end
        cached.state = state
        if name == "ReinitDiscoState" then
            reset_run("reinit")
            run.ended = false
            run.round = read_round(state) or 0
        elseif name == "HandleLevelEnded" or name == "HandleLevelRestarted" then
            reset_run(name)
        elseif name == "OnIncursionCleared_Event" then
            local round = read_round(state)
            if round and round >= 1 and not run.dead then report_cleared(round) end
        else
            run.ended = false -- AdvanceRound explicitly starts/resumes gameplay.
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
-- On-screen pop-ups
---------------------------------------------------------------------------------------------

-- The engine's UserWidget class is abstract (constructing it crashes), so a small concrete widget from
-- the game hosts ours: its widget tree gets replaced by a canvas holding one multi-line TextBlock.
local POPUP_HOSTS = {
    "/Game/Pagoda/UI/LevelSelect/WBP_LevelSelectLabelText.WBP_LevelSelectLabelText_C",
    "/Game/Pagoda/UI/Game/SongText/TextTemplates/WBP_SongText_Base.WBP_SongText_Base_C",
    "/Game/Pagoda/UI/Common/WBP_Star_WithCountText.WBP_Star_WithCountText_C",
}
local POPUP_SECONDS = 6
local POPUP_MAX_LINES = 5
local POPUP_FONT_SIZE = 26
local POPUP_POSITION = {X = 0.5, Y = 0.16} -- fraction of the screen; the text hangs down from here

local popup_lines = {} -- {text, expires}
local popup_overlay = nil -- {widget, text}
local popup_failures = 0
local popup_shown_text = nil

local function create_overlay()
    local pc = controller()
    if not valid(pc) then error("player controller not found") end
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not valid(library) then error("widget library not found") end
    local widget, host_errors = nil, {}
    for _, path in ipairs(POPUP_HOSTS) do
        local ok, result = pcall(function() return library:Create(pc, load_class(path), pc) end)
        if ok and valid(result) then widget = result break end
        host_errors[#host_errors + 1] = path:match("([^/]+)$") .. ": " .. tostring(result)
    end
    if not widget then error("no host widget: " .. table.concat(host_errors, "; ")) end

    local tree = widget.WidgetTree
    if not valid(tree) then error("host widget has no widget tree") end
    local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree, FName("DeadAsDiscoAPCanvas"))
    local text = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName("DeadAsDiscoAPText"))
    if not valid(canvas) or not valid(text) then error("could not construct canvas/text") end
    tree.RootWidget = canvas
    local slot = canvas:AddChildToCanvas(text)
    slot:SetAnchors({Minimum = POPUP_POSITION, Maximum = POPUP_POSITION})
    slot:SetAlignment({X = 0.5, Y = 0.0})
    slot:SetAutoSize(true)
    text:SetJustification(1) -- centre
    text:SetShadowOffset({X = 2.0, Y = 2.0})
    text:SetShadowColorAndOpacity({R = 0.0, G = 0.0, B = 0.0, A = 0.9})
    pcall(function()
        local font = text.Font
        font.Size = POPUP_FONT_SIZE
        text:SetFont(font)
    end)
    text:SetText(FText(""))
    widget:SetVisibility(3) -- HitTestInvisible: never takes clicks or focus
    widget:AddToViewport(1000)
    log("pop-up overlay created on " .. widget:GetClass():GetFullName())
    return {widget = widget, text = text}
end

local function refresh_popups()
    local now = os.time()
    local kept = {}
    for _, line in ipairs(popup_lines) do
        if line.expires > now then kept[#kept + 1] = line end
    end
    while #kept > POPUP_MAX_LINES do table.remove(kept, 1) end
    popup_lines = kept
    local texts = {}
    for _, line in ipairs(kept) do texts[#texts + 1] = line.text end
    local wanted = table.concat(texts, "\n")
    if wanted == popup_shown_text and popup_overlay and valid(popup_overlay.text) then return end
    if wanted == "" and not popup_overlay then return end
    if popup_failures >= 3 then return end -- give up quietly after repeated failures
    local ok, err = pcall(function()
        if not popup_overlay or not valid(popup_overlay.widget) or not valid(popup_overlay.text)
            or not popup_overlay.widget:IsInViewport() then
            popup_overlay = create_overlay()
        end
        popup_overlay.text:SetText(FText(wanted))
    end)
    if ok then
        popup_shown_text = wanted
    else
        popup_overlay = nil
        popup_failures = popup_failures + 1
        log("pop-up failed (" .. popup_failures .. "/3): " .. tostring(err))
    end
end

popup = function(text)
    text = tostring(text):gsub("[%c]", " ")
    if #text > 120 then text = text:sub(1, 117) .. "..." end
    popup_lines[#popup_lines + 1] = {text = text, expires = os.time() + POPUP_SECONDS}
    refresh_popups()
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
    elseif command.type == "message" then
        popup(command.text)
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
        effects = SUPPORTED_EFFECTS, meteor_ready = meteor_ready(),
        kill_pending = pending_kill ~= nil,
    }))
    file:close()
end

local tick_count = 0

local function status_line()
    return string.format("status: ticks=%d bridge=%s in_run=%s round=%d cleared=%d dead=%s effect=%s health=%s hooks=%d",
        tick_count, tostring(bridge_ready), tostring(in_run()), run.round, run.cleared, tostring(run.dead),
        active_effect and active_effect.key or "none", player_health(),
        (function() local n = 0 for _ in pairs(registered) do n = n + 1 end return n end)())
end

local function tick()
    tick_count = tick_count + 1
    if tick_count == 1 or tick_count == 40 then log("main loop running (tick " .. tick_count .. ")") end
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

    if active_effect and active_effect.key == "meteor" then
        local reason = meteor:tick(player(), game_state(), in_run())
        if reason then end_effect(reason) end
    elseif active_effect and os.time() >= active_effect.ends_at then end_effect("expired") end

    if pending_kill then
        pending_kill.ticks = pending_kill.ticks + 1
        if run.dead or not valid(player()) then
            pending_kill = nil
        elseif pending_kill.ticks >= KILL_ATTEMPT_TICKS then
            kill_attempt()
        end
    end

    if open_bridge() then
        for _, command in ipairs(read_commands()) do handle_command(command) end
    end
    if tick_count % STATUS_EVERY_TICKS == 0 then
        write_status()
        if #popup_lines > 0 then refresh_popups() end -- expire old lines
    end
    flush_events()
end

-- LoopAsync only fired once in this UE4SS build, so each tick schedules the next one on the
-- game thread before doing any work; an error in tick() can't stop the loop.
local function run_tick()
    ExecuteInGameThreadWithDelay(TICK_MS, run_tick)
    local ok, err = pcall(tick)
    if not ok then log("tick error: " .. tostring(err)) end
end
ExecuteInGameThread(run_tick)

local function hotkey(key, action)
    RegisterKeyBind(key, {ModifierKey.CONTROL}, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(action)
            if not ok then log("hotkey error: " .. tostring(err)) end
        end)
    end)
end

if TEST_HOTKEYS then
    hotkey(Key.F5, function() start_effect("slowmo", 10, "hotkey") end)
    hotkey(Key.F6, function() start_effect("fastforward", 10, "hotkey") end)
    hotkey(Key.F7, function() start_effect("molasses", 10, "hotkey") end)
    hotkey(Key.F8, function() start_effect("blackout", 10, "hotkey") end)
    hotkey(Key.F9, function() start_effect("fever", 10, "hotkey") end)
    hotkey(Key.F10, function() request_kill("hotkey") end)
end
hotkey(Key.HOME, function()
    emit_log(status_line())
    popup("Dead as Disco AP " .. VERSION .. ": " .. (in_run() and ("in a run, wave " .. run.round) or "not in a run"))
end)

log("Dead as Disco AP " .. VERSION .. " loaded; session " .. session)
