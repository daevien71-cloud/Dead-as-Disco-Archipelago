-- Runs mod/DeadAsDiscoAP/Scripts/main.lua against a fake UE4SS API.
-- Usage: LOCALAPPDATA=<temp dir> lua test_main.lua <repo root>
local root = assert(arg[1], "pass the repo root")
local bridge = assert(os.getenv("LOCALAPPDATA"), "set LOCALAPPDATA") .. "\\DeadAsDiscoAP\\"
package.path = root .. "/mod/DeadAsDiscoAP/Scripts/?.lua;" .. package.path
local json = require("json")

local failures, checks = 0, 0
local function check(condition, message)
    checks = checks + 1
    if not condition then
        failures = failures + 1
        io.stderr:write("FAIL: " .. message .. "\n")
    end
end

-- ----- fake UE4SS ----------------------------------------------------------------------
local output = {}
print = function(text) output[#output + 1] = text end

local next_address = 1000
local engine_world
local function object(name, props)
    next_address = next_address + 1
    local o = props or {}
    o._valid, o._name, o._address = true, name, next_address
    function o:IsValid() return self._valid end
    function o:GetFullName() return self._name end
    function o:GetAddress() return self._address end
    function o:GetPropertyValue(key) return self[key] end
    function o:GetWorld() return self._world or engine_world end
    return o
end
engine_world = object("UWorld /Game/Level")
local function param(value) return {get = function() return value end} end

local world = {}
function FindAllOf(short)
    local found = world[short]
    return found and {found} or nil
end

local functions = {}
function StaticFindObject(path)
    if functions[path] == nil then functions[path] = object(path) end
    return functions[path]
end

local hooks = {}
function RegisterHook(path, pre, post)
    hooks[path] = post or pre
    return 1, 2
end

-- The mod drives itself with ExecuteInGameThreadWithDelay; each test "tick" runs the pending one.
local scheduled = {}
function ExecuteInGameThreadWithDelay(_, callback) scheduled[#scheduled + 1] = callback end
function ExecuteInGameThread(callback) callback() end
local function loop()
    local due = scheduled
    scheduled = {}
    for _, callback in ipairs(due) do callback() end
end
local keybinds = {}
function RegisterKeyBind(key, _, callback) keybinds[key] = callback end
Key = {F5 = "F5", F6 = "F6", F7 = "F7", F8 = "F8", F9 = "F9", F10 = "F10", HOME = "HOME"}
ModifierKey = {CONTROL = "CTRL"}
function FName(text) return {name = text} end
function FText(text) return {text = text} end

-- Fake UMG: the host widget, its tree, and the canvas/text the mod builds inside it.
local widgets_created = {}
local widget_library = object("Default__WidgetBlueprintLibrary")
function widget_library:Create(_, class)
    local widget = object("WBP host", {WidgetTree = object("WidgetTree"), class = class, in_viewport = false})
    function widget:GetClass() return {GetFullName = function() return "class " .. class._name end} end
    function widget:SetVisibility(v) self.visibility = v end
    function widget:AddToViewport(z) self.in_viewport = true; self.z = z end
    function widget:IsInViewport() return self.in_viewport end
    widgets_created[#widgets_created + 1] = widget
    return widget
end
functions["/Script/UMG.Default__WidgetBlueprintLibrary"] = widget_library
function StaticConstructObject(class, outer, name)
    local o = object(name.name, {outer = outer, class = class})
    if class._name:find("CanvasPanel") then
        function o:AddChildToCanvas(child)
            self.child = child
            local slot = {}
            function slot:SetAnchors(a) self.anchors = a end
            function slot:SetAlignment(a) self.alignment = a end
            function slot:SetAutoSize(b) self.auto = b end
            return slot
        end
    else
        o.Font = {Size = 24}
        function o:SetText(t) self.shown = t.text end
        function o:SetJustification(j) self.justification = j end
        function o:SetShadowOffset(v) end
        function o:SetShadowColorAndOpacity(c) end
        function o:SetFont(f) self.font_size = f.Size end
    end
    return o
end

local statics = object("Default__GameplayStatics", {dilation = 1.0, audio_seconds = 0, paused = false})
function statics:SetGlobalTimeDilation(_, speed) self.dilation = speed end
function statics:GetGlobalTimeDilation() return self.dilation end
function statics:GetPlayerPawn() return self.controlled_pawn end
function statics:GetPlayerController() return self.local_controller end
function statics:GetAudioTimeSeconds()
    if self.audio_failure then error("audio clock unavailable") end
    return self.audio_override ~= nil and self.audio_override or self.audio_seconds
end
function statics:IsGamePaused()
    if self.pause_failure then error("pause query unavailable") end
    return self.paused
end
functions["/Script/Engine.Default__GameplayStatics"] = statics
local library = object("Default__PagodaCombatFunctionLibrary", {calls = {}})
function library:ApplySetByCallerEffect(target, effect, tag, value)
    self.calls[#self.calls + 1] = {target = target, effect = effect, tag = tag, value = value}
end
functions["/Script/Pagoda.Default__PagodaCombatFunctionLibrary"] = library

local GS = "/Game/Pagoda/Core/GameModes/InfiniteDisco/BP_PagodaGameState_InfiniteDisco.BP_PagodaGameState_InfiniteDisco_C"
local PLAYER = "/Game/Pagoda/Characters/Player/BP_PagodaPlayerCharacter_Charlie.BP_PagodaPlayerCharacter_Charlie_C"

-- ----- helpers -------------------------------------------------------------------------
os.execute('mkdir "' .. bridge:sub(1, -2) .. '" 2>NUL')
os.remove(bridge .. "commands.jsonl")
os.remove(bridge .. "events.jsonl")

local function read_events()
    local events = {}
    local file = io.open(bridge .. "events.jsonl", "rb")
    if not file then return events end
    for line in file:lines() do events[#events + 1] = json.decode(line) end
    file:close()
    return events
end
local function events_of(kind)
    local result = {}
    for _, e in ipairs(read_events()) do if e.type == kind then result[#result + 1] = e end end
    return result
end
local function tick(n)
    for _ = 1, (n or 1) do
        loop()
        if #scheduled ~= 1 then check(false, "exactly one next tick scheduled (got " .. #scheduled .. ")") end
    end
end
local command_id = 0
local function command(c)
    command_id = command_id + 1
    c.session, c.id = "testclient", command_id
    local file = io.open(bridge .. "commands.jsonl", "ab")
    file:write(json.encode(c) .. "\n")
    file:close()
end
local function read_status()
    local file = io.open(bridge .. "status.json", "rb")
    local status = json.decode(file:read("a"))
    file:close()
    return status
end

-- ----- scenario ------------------------------------------------------------------------
-- meteor.lua has its own native-contract harness. Here exercise the main-loop/event
-- integration with a controllable lifetime, independently of wall-clock trap duration.
local fake_meteor = {active = nil, starts = 0, stops = 0, ready_reason = nil, done = nil}
function fake_meteor:ready()
    if self.ready_throws then error("test readiness unavailable") end
    return not self.ready_reason, self.ready_reason
end
function fake_meteor:start(p, state, on_launch)
    if self.start_throws then error("native meteor setup unavailable") end
    if self.fail_reason then return false, self.fail_reason end
    self.last_player, self.on_launch = p, on_launch
    self.active = {}; self.starts = self.starts + 1
    local count = self.count or 1
    if on_launch then on_launch(1, count) end
    return true, count
end
function fake_meteor:stop() self.active = nil; self.stops = self.stops + 1 end
function fake_meteor:tick() local done = self.done; self.done = nil; return done end
package.loaded.meteor = {new = function() return fake_meteor end}
local fake_cars = {active = nil, starts = 0, stops = 0}
function fake_cars:ready()
    if self.ready_throws then error("test cars readiness unavailable") end
    return not self.ready_reason, self.ready_reason
end
function fake_cars:start(p, state, on_set, probe)
    self.last_player, self.on_set, self.last_probe = p, on_set, probe
    if self.partial_failure then self.active = {partial = true} end
    if self.start_throws then error("native cars setup unavailable") end
    if self.fail_reason then return false, self.fail_reason end
    self.active = {}; self.starts = self.starts + 1
    local count = probe and 1 or 2
    if on_set then on_set(1, count) end
    return true, count
end
function fake_cars:stop()
    self.active = nil; self.stops = self.stops + 1
    statics.audio_seconds = statics.audio_seconds + (self.stop_advance or 0)
end
function fake_cars:tick()
    if self.tick_throws then error("native cars tick unavailable") end
    local done = self.done; self.done = nil; return done
end
package.loaded.cars = {new = function() return fake_cars end}
dofile(root .. "/mod/DeadAsDiscoAP/Scripts/main.lua")
check(#scheduled == 1, "main loop schedules its next tick")
tick(1)
check(read_events()[1] and read_events()[1].type == "hello", "hello event written on start")
check(hooks[GS .. ":AdvanceRound"] ~= nil, "AdvanceRound hooked")
check(hooks["/Script/Pagoda.PagodaInfiniteDiscoSubsystem:NotifyEnemyKilled"] ~= nil, "kill hook registered")
check(hooks[PLAYER .. ":OnDeathStartedDelegate_Event"] ~= nil, "death hook registered")
check(keybinds.HOME ~= nil and keybinds.F5 == nil and keybinds.F10 == nil, "only the status hotkey is on by default")

-- Start an Arcade run.
local state = object("BP_PagodaGameState_InfiniteDisco_C /Game/Level.PersistentLevel.GS_1", {round = 0, bWaveClearedRequested = false})
local charlie = object("BP_PagodaPlayerCharacter_Charlie_C /Game/Level.PersistentLevel.Charlie_1", {CustomTimeDilation = 1.0,
    HealthAttributeSet = {Health = {BaseValue = 100, CurrentValue = 100}}})
function charlie:GetHealth() return self.HealthAttributeSet.Health.CurrentValue end
local camera = object("PlayerCameraManager", {fades = {}})
function camera:StartCameraFade(from, to) self.fades[#self.fades + 1] = {from, to} end
local pc = object("BP_PagodaPlayerController_C /Game/Level.PersistentLevel.PC_1", {PlayerCameraManager = camera})
world.BP_PagodaGameState_InfiniteDisco_C = state
world.BP_PagodaPlayerCharacter_Charlie_C = charlie
world.BP_PagodaPlayerController_C = pc
statics.controlled_pawn, statics.local_controller = charlie, pc

hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 1
hooks[GS .. ":AdvanceRound"](param(state))
tick(4)
check(read_status().in_run == true, "status shows in_run after round 1 starts")
check(#events_of("run_start") == 1, "run_start emitted once")

-- Clear waves 1-3 via hooks, then jump to 7 via polling only (missed hooks).
for wave = 1, 3 do
    state.bWaveClearedRequested = true
    hooks[GS .. ":OnIncursionCleared_Event"](param(state))
    state.round = wave + 1
    hooks[GS .. ":AdvanceRound"](param(state))
end
state.round = 8
tick(1)
local waves = {}
for _, e in ipairs(events_of("wave")) do waves[#waves + 1] = e.wave end
check(table.concat(waves, ",") == "1,2,3,7", "wave events 1,2,3,7 (got " .. table.concat(waves, ",") .. ")")

-- Kills are batched per tick.
for _ = 1, 5 do hooks["/Script/Pagoda.PagodaInfiniteDiscoSubsystem:NotifyEnemyKilled"](param(nil)) end
tick(1)
local kills = events_of("kill")
check(#kills == 1 and kills[1].count == 5, "five kills batched into one event")

-- Effects from the client.
command({type = "effect", effect = "slowmo", duration = 1})
tick(1)
check(statics.dilation == 0.6, "slow-mo sets global dilation 0.6")
check(#events_of("effect_start") == 1, "effect_start emitted")
local finish = os.time() + 2
while os.time() < finish do end
tick(1)
check(statics.dilation == 1.0, "slow-mo reverted after duration")
check(#events_of("effect_end") == 1, "effect_end emitted")

command({type = "effect", effect = "fever", duration = 30})
tick(1)
check(statics.dilation == 0.65 and math.abs(charlie.CustomTimeDilation - 1 / 0.65) < 1e-6, "fever slows world, not player")
command({type = "effect", effect = "blackout", duration = 30})
tick(1)
check(statics.dilation == 1.0 and charlie.CustomTimeDilation == 1.0, "starting blackout reverts fever")
check(camera.fades[1] and camera.fades[1][2] == 0.98, "blackout fades camera in to 98%")
command({type = "effect", effect = "nope"})
tick(1)
local failed = events_of("effect_failed")
check(#failed == 1 and failed[1].reason == "unknown effect", "unknown effect reported as failed")

-- DeathLink kill: the game's damage effect with its native SetByCaller tag. Never GE_Die.
local GE_DAMAGE = "/Game/Pagoda/Characters/Common/Effects/GE_Damage_SetByCaller.GE_Damage_SetByCaller_C"
functions[GE_DAMAGE] = object(GE_DAMAGE)
command({type = "kill", source = "Friend"})
command({type = "kill", source = "Friend again"})
tick(1)
check(#library.calls == 1 and library.calls[1].effect == functions[GE_DAMAGE] and library.calls[1].target == charlie
    and library.calls[1].value == 9999 and library.calls[1].tag.TagName.name == "SetByCaller.Damage",
    "kill applies GE_Damage_SetByCaller x9999 to the player, once even if asked twice")
check(charlie.HealthAttributeSet.Health.BaseValue == 100, "first hit leaves health alone")
hooks[PLAYER .. ":OnDeathStartedDelegate_Event"](param(charlie))
tick(4)
local credits = events_of("log")
check(credits[#credits].text:find("worked on hit 1", 1, true) ~= nil, "first hit credited for the death")
check(#events_of("death") == 1, "death event emitted")
check(camera.fades[#camera.fades][2] == 0.0, "death reverts blackout")
check(read_status().in_run == false, "not in_run after death")
command({type = "effect", effect = "slowmo", duration = 5})
tick(1)
failed = events_of("effect_failed")
check(failed[#failed].reason == "not_in_run", "effects refused while dead")

-- New run resets wave tracking.
hooks[GS .. ":ReinitDiscoState"](param(state)) -- round still 8 here; reinit resets anyway
state.round = 1
hooks[GS .. ":AdvanceRound"](param(state))
state.round = 2
hooks[GS .. ":AdvanceRound"](param(state))
tick(4)
local last_wave = events_of("wave")
check(last_wave[#last_wave].wave == 1, "new run reports wave 1 again")
check(read_status().cleared == 1, "status cleared resets per run")

-- If the first hit doesn't kill, health drops to a sliver and hits repeat every 2 ticks, 12 in all.
command({type = "kill"})
tick(1)
local calls_before = #library.calls
tick(2)
check(#library.calls == calls_before + 1 and charlie.HealthAttributeSet.Health.BaseValue == 0.01
    and charlie.HealthAttributeSet.Health.CurrentValue == 0.01, "second hit lowers health first")
tick(40)
check(#library.calls == calls_before + 11, "twelve hits in all (got " .. (#library.calls - calls_before + 1) .. ")")
check(#events_of("kill_failed") == 1, "kill_failed reported when nothing worked")
charlie.HealthAttributeSet.Health.BaseValue, charlie.HealthAttributeSet.Health.CurrentValue = 100, 100

-- Pop-ups: messages from the client show in one multi-line text, newest last, at most 5 lines.
command({type = "message", text = "Alex sent you Slow-Mo Trap"})
tick(1)
local host = widgets_created[#widgets_created]
check(host and host.in_viewport and host.visibility == 3, "pop-up overlay added to the viewport, click-through")
local popup_text = host and host.WidgetTree.RootWidget and host.WidgetTree.RootWidget.child
check(popup_text and popup_text.shown:match("([^\n]*)$") == "Alex sent you Slow-Mo Trap" and popup_text.font_size == 26,
    "message shown as the newest pop-up line")
check(popup_text.shown:find("SLOW-MO!", 1, true) ~= nil, "effects show their own pop-up")
for i = 1, 6 do command({type = "message", text = "line " .. i}) end
tick(1)
check(popup_text.shown == "line 2\nline 3\nline 4\nline 5\nline 6", "only the newest five lines are kept")
host.in_viewport = false -- e.g. the level changed
command({type = "message", text = "after level change"})
tick(1)
check(#widgets_created == 2 and widgets_created[2].in_viewport, "overlay recreated when it left the viewport")

-- Client restart truncates the command file; ids restart from 1 under a new session.
local file = io.open(bridge .. "commands.jsonl", "wb")
file:write(json.encode({type = "hello", session = "client2"}) .. "\n")
file:close()
tick(1)
file = io.open(bridge .. "commands.jsonl", "ab")
file:write(json.encode({type = "effect", effect = "molasses", duration = 5, session = "client2", id = 1}) .. "\n")
file:close()
tick(1)
check(charlie.CustomTimeDilation == 0.6, "commands after a client restart are read")
check(events_of("effect_start")[#events_of("effect_start")].command_session == "client2",
    "new client session is echoed on an ordinary effect start")

-- Level-end arrives before the UObject disappears. Polling its old round must not restart a run.
hooks[GS .. ":HandleLevelEnded"](param(state))
tick(8)
check(not read_status().in_run, "old state cannot restart a run after HandleLevelEnded")
check(charlie.CustomTimeDilation == 1.0, "level-end immediately reverts the active effect")
check(events_of("effect_end")[#events_of("effect_end")].command_session == "client2",
    "ordinary effect end retains its originating client session")
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 1
hooks[GS .. ":AdvanceRound"](param(state))
command({type = "effect", effect = "molasses", duration = 30})
tick(4)
check(read_status().in_run and charlie.CustomTimeDilation == 0.6, "explicit new round releases the end latch")

-- Leaving Arcade ends the run.
world.BP_PagodaGameState_InfiniteDisco_C = nil
state._valid = false
tick(4)
check(charlie.CustomTimeDilation == 1.0, "leaving Arcade reverts molasses")
check(read_status().in_run == false, "not in_run after leaving Arcade")

keybinds.HOME()
tick(1)
local logs = events_of("log")
check(logs[#logs].text:find("status:", 1, true) ~= nil, "Ctrl+Home logs a status line")

-- Meteor admission, exclusivity, native completion and run-end cleanup.
state._valid = true
world.BP_PagodaGameState_InfiniteDisco_C = state
state.round = 0
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 1
state.bWaveClearedRequested = false
hooks[GS .. ":AdvanceRound"](param(state))
tick(4)
check(read_status().effects[6] == "meteor" and read_status().meteor_ready, "meteor capability/readiness advertised")
for _, reason in ipairs({"spawn_blocked", "asset_unavailable", "spawn_failed"}) do
    fake_meteor.fail_reason = reason
    command({type = "effect", effect = "meteor"})
    tick()
    check(events_of("effect_failed")[#events_of("effect_failed")].reason == reason and fake_meteor.starts == 0,
        "meteor " .. reason .. " reaches client without Lua path or table-address prefixes")
end
fake_meteor.fail_reason = nil
fake_meteor.start_throws = true
command({type = "effect", effect = "meteor"})
tick()
check(events_of("effect_failed")[#events_of("effect_failed")].reason == "spawn_failed" and fake_meteor.starts == 0,
    "unexpected meteor setup exceptions become clean spawn_failed refusals")
check(events_of("log")[#events_of("log")].text:find("native meteor setup unavailable", 1, true) ~= nil,
    "meteor setup diagnostic detail remains in the log")
fake_meteor.start_throws = nil
fake_meteor.ready_throws = true
command({type = "effect", effect = "meteor"})
tick()
check(events_of("effect_failed")[#events_of("effect_failed")].reason == "spawn_failed" and fake_meteor.starts == 0,
    "meteor readiness exceptions become clean spawn_failed refusals")
fake_meteor.ready_throws = nil
local original_set_speed = statics.SetGlobalTimeDilation
function statics:SetGlobalTimeDilation() error("native speed failure") end
command({type = "effect", effect = "slowmo"})
tick()
local ordinary_failure = events_of("effect_failed")[#events_of("effect_failed")].reason
check(ordinary_failure:find("native speed failure", 1, true) ~= nil,
    "ordinary effect failures retain their existing diagnostic message")
statics.SetGlobalTimeDilation = original_set_speed
fake_meteor.ready_reason = "paused"
command({type = "effect", effect = "meteor"})
tick()
check(events_of("effect_failed")[#events_of("effect_failed")].reason == "paused" and fake_meteor.starts == 0,
    "pause defers meteor before native spawn")
fake_meteor.ready_reason = nil
state.bWaveClearedRequested = true
command({type = "effect", effect = "meteor"})
tick()
check(events_of("effect_failed")[#events_of("effect_failed")].reason == "downtime", "wave downtime defers meteor")
state.bWaveClearedRequested = false
command({type = "effect", effect = "blackout", duration = 10})
command({type = "effect", effect = "meteor"})
tick()
check(fake_meteor.starts == 0, "meteor cannot replace Blackout and hide its warning")
hooks[GS .. ":HandleLevelRestarted"](param(state))
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 2
hooks[GS .. ":AdvanceRound"](param(state))
-- A valid leftover pawn may be listed first after a restart. It must not be targeted.
world.BP_PagodaPlayerCharacter_Charlie_C = object("stale Charlie", {CustomTimeDilation = 1})
fake_meteor.count = 3
command({type = "effect", effect = "meteor", duration = 1})
tick(4)
check(fake_meteor.last_player == charlie, "meteor targets the controlled pawn, not a valid leftover Charlie")
check(fake_meteor.starts == 1 and read_status().effect == "meteor" and not read_status().meteor_ready,
    "one meteor owns the effect slot until native completion")
local meteor_start = events_of("effect_start")[#events_of("effect_start")]
check(meteor_start.meteor_count == 3 and type(meteor_start.meteor_count) == "number" and meteor_start.duration == nil,
    "one meteor batch start advertises its numeric count without a wall-clock duration")
local meteor_popup = widgets_created[#widgets_created].WidgetTree.RootWidget.child
local _, initial_warning_count = meteor_popup.shown:gsub("METEOR 1 OF 3!", "")
check(initial_warning_count == 1, "first meteor warning appears once despite first-launch callback")
local starts_before_later_launch = #events_of("effect_start")
fake_meteor.on_launch(2, 3)
tick()
check(meteor_popup.shown:match("([^\n]*)$") == "METEOR 2 OF 3! Move from the marked spot!",
    "later meteor callback shows its numbered warning")
check(#events_of("effect_start") == starts_before_later_launch,
    "later meteors retain the original item lifecycle without another effect_start")
command({type = "effect", effect = "meteor"})
command({type = "effect", effect = "blackout"})
command({type = "effect", effect = "cars"})
tick()
check(fake_meteor.starts == 1 and fake_meteor.active, "manual commands cannot overlap or replace a meteor")
check(fake_cars.starts == 0 and events_of("effect_failed")[#events_of("effect_failed")].reason == "busy",
    "cars cannot overlap or replace a meteor")
fake_meteor.done = "native_finished"
tick(4)
check(read_status().effect == nil and events_of("effect_end")[#events_of("effect_end")].reason == "native_finished",
    "native completion acknowledges effect end")
command({type = "effect", effect = "meteor"})
tick()
local stops_before = fake_meteor.stops
hooks[GS .. ":HandleLevelEnded"](param(state))
tick(4)
check(fake_meteor.stops == stops_before + 1 and not read_status().in_run, "run end cleans meteor once and stays ended")

-- Cars share the native effect slot but load and fail independently of meteors.
state.round = 0
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 1
hooks[GS .. ":AdvanceRound"](param(state))
tick(4)
check(read_status().version == "0.3.2" and read_status().effects[7] == "cars" and read_status().cars_ready,
    "cars capability and readiness advertised in version 0.3.2")
for _, reason in ipairs({"paused", "airborne"}) do
    fake_cars.ready_reason = reason
    command({type = "effect", effect = "cars"})
    tick()
    check(events_of("effect_failed")[#events_of("effect_failed")].reason == reason and fake_cars.starts == 0,
        reason .. " defers cars before spawn")
end
fake_cars.ready_reason = nil
state.bWaveClearedRequested = true
command({type = "effect", effect = "cars"})
tick()
check(events_of("effect_failed")[#events_of("effect_failed")].reason == "downtime" and fake_cars.starts == 0,
    "wave downtime defers cars")
state.bWaveClearedRequested = false
fake_cars.ready_throws = true
command({type = "effect", effect = "cars"})
tick()
check(events_of("effect_failed")[#events_of("effect_failed")].reason == "spawn_failed",
    "cars readiness exceptions become clean spawn_failed refusals")
fake_cars.ready_throws = nil
for _, reason in ipairs({"spawn_blocked", "asset_unavailable", "spawn_failed", "cleanup_failed"}) do
    fake_cars.fail_reason, fake_cars.partial_failure = reason, true
    local previous_starts, previous_stops = #events_of("effect_start"), fake_cars.stops
    command({type = "effect", effect = "cars"})
    tick()
    check(events_of("effect_failed")[#events_of("effect_failed")].reason == reason,
        "cars " .. reason .. " retains clean failure code")
    check(fake_cars.active == nil and fake_cars.stops == previous_stops + 1 and #events_of("effect_start") == previous_starts,
        "cars " .. reason .. " cleans a partial start without consuming the item")
end
fake_cars.fail_reason = nil
fake_cars.start_throws = true
command({type = "effect", effect = "cars"})
tick()
check(events_of("effect_failed")[#events_of("effect_failed")].reason == "spawn_failed" and not fake_cars.active,
    "unexpected cars setup throw cleans partial state and returns spawn_failed")
fake_cars.start_throws, fake_cars.partial_failure = nil, nil
command({type = "effect", effect = "blackout"})
command({type = "effect", effect = "cars"})
tick(4)
check(fake_cars.starts == 0 and read_status().effect == "blackout", "cars cannot replace Blackout and hide lane warnings")
hooks[GS .. ":HandleLevelRestarted"](param(state))
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 2
hooks[GS .. ":AdvanceRound"](param(state))
command({type = "effect", effect = "cars", probe = "true", duration = 1})
tick(4)
local cars_start = events_of("effect_start")[#events_of("effect_start")]
check(fake_cars.starts == 1 and fake_cars.last_player == charlie and fake_cars.last_probe == false,
    "cars use controlled pawn and only a boolean true enables probe mode")
check(cars_start.effect == "cars" and cars_start.car_sets == 2 and cars_start.car_count == 6 and cars_start.duration == nil,
    "normal cars event reports two sets and six cars without wall-clock expiry")
check(read_status().effect == "cars" and not read_status().cars_ready and not read_status().meteor_ready,
    "cars hold the native effect slot across sets")
local cars_popup = widgets_created[#widgets_created].WidgetTree.RootWidget.child
local _, first_set_warnings = cars_popup.shown:gsub("CARS: SET 1 OF 2!", "")
check(first_set_warnings == 1, "first car set receives exactly one warning")
local starts_before_next_set = #events_of("effect_start")
fake_cars.on_set(2, 2)
tick()
check(cars_popup.shown:match("([^\n]*)$") == "CARS: SET 2 OF 2! Move out of the marked lanes!",
    "second car set receives its numbered lane warning")
check(#events_of("effect_start") == starts_before_next_set, "second car set does not acknowledge another item")
local meteor_starts_before_cars = fake_meteor.starts
for _, effect in ipairs({"meteor", "blackout", "slowmo", "cars"}) do command({type = "effect", effect = effect, probe = true}) end
tick()
check(fake_cars.starts == 1 and fake_meteor.starts == meteor_starts_before_cars and fake_cars.active and statics.dilation == 1,
    "all competing native and ordinary effects remain blocked during cars")
local car_stops_before = fake_cars.stops
fake_cars.done = "native_finished"
tick(4)
check(not read_status().effect and fake_cars.stops == car_stops_before + 1
    and events_of("effect_end")[#events_of("effect_end")].reason == "native_finished", "car native completion releases effect slot and cleans once")
local car_ends_before = #events_of("effect_end")
tick(4)
check(#events_of("effect_end") == car_ends_before, "completed car lifecycle cannot acknowledge twice")

command({type = "effect", effect = "cars", probe = true})
tick(4)
cars_start = events_of("effect_start")[#events_of("effect_start")]
check(fake_cars.last_probe == true and cars_start.effect == "cars" and cars_start.car_sets == 1 and cars_start.car_count == 1,
    "single-car probe uses cars effect identity with one set and one car")
check(cars_popup.shown:match("([^\n]*)$") == "ONE CAR INCOMING! Move out of the marked lane!",
    "single-car probe has singular warning wording")
command({type = "effect", effect = "meteor"})
tick()
check(fake_meteor.starts == meteor_starts_before_cars and read_status().effect == "cars",
    "single-car probe also blocks the Archipelago effect slot")
car_stops_before = fake_cars.stops
hooks[GS .. ":HandleLevelEnded"](param(state))
tick(4)
check(not read_status().in_run and not fake_cars.active and fake_cars.stops == car_stops_before + 1,
    "scene/run end cleans active car probe once")
command({type = "effect", effect = "cars"})
tick()
check(events_of("effect_failed")[#events_of("effect_failed")].reason == "not_in_run", "cars cannot begin outside a run")
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 1
hooks[GS .. ":AdvanceRound"](param(state))
command({type = "effect", effect = "cars"})
tick()
check(fake_cars.last_probe == false, "ordinary AP car command defaults to the full trap")
fake_cars.tick_throws = true
tick(4)
check(not read_status().effect and not fake_cars.active
    and events_of("effect_end")[#events_of("effect_end")].reason == "runtime_failed",
    "unexpected cars runtime exception ends and cleans the effect instead of leaving it busy")
fake_cars.tick_throws = nil

-- Queue pacing uses a cumulative game-session clock, not wall time or dilated time.
-- Keep native time fixed across polling ticks so these assertions do not depend on
-- where the once-per-second status heartbeat falls within the test harness.
local function clock_status(delta)
    if not statics.paused then statics.audio_seconds = statics.audio_seconds + (delta or 0) end
    tick(4)
    return read_status()
end
local function close(a, b) return math.abs(a-b) < 1e-8 end
local function raw_effect(effect, id, origin, probe)
    local file = assert(io.open(bridge .. "commands.jsonl", "ab"))
    file:write(json.encode({type="effect", effect=effect, duration=30, id=id, session=origin, probe=probe}) .. "\n")
    file:close()
end
for _, event in ipairs(events_of("effect_failed")) do
    check(event.command_session == "testclient", "every refusal echoes its originating command session")
end
local clock = clock_status()
check(clock.clock_version == 1 and clock.active_play == true and type(clock.active_play_seconds) == "number",
    "status advertises a versioned active-play clock")
local total = clock.active_play_seconds
clock = clock_status(5.5)
check(close(clock.active_play_seconds, total+5.5), "active combat advances by native elapsed time")
statics.dilation = 0.6
clock = clock_status(3)
check(close(clock.active_play_seconds, total+8.5), "slow motion does not stretch the pacing clock")
statics.dilation = 1.4
clock = clock_status(4)
check(close(clock.active_play_seconds, total+12.5), "fast-forward does not shorten the pacing clock")
statics.dilation = 1
total = clock.active_play_seconds
statics.paused = true
clock = clock_status(100)
check(clock.active_play == false and close(clock.active_play_seconds,total), "pause contributes no active time")
statics.paused = false
clock = clock_status(25)
check(clock.active_play and close(clock.active_play_seconds,total), "resume rebases an inactive sample without credit")
clock = clock_status(1)
check(close(clock.active_play_seconds,total+1), "active time resumes after pause")
total = clock.active_play_seconds
state.bWaveClearedRequested = true
clock = clock_status(40)
check(not clock.active_play and close(clock.active_play_seconds,total), "wave downtime freezes pacing even while in_run")
state.bWaveClearedRequested = false
clock = clock_status(30)
check(clock.active_play and close(clock.active_play_seconds,total), "combat resumption does not credit the downtime interval")
clock = clock_status(2)
check(close(clock.active_play_seconds,total+2), "combat after downtime advances normally")
total = clock.active_play_seconds
state.bWaveClearedRequested = nil
clock = clock_status(10)
check(not clock.active_play and close(clock.active_play_seconds,total), "unknown combat readiness fails closed")
state.bWaveClearedRequested = false
clock_status()

local original_world = engine_world
engine_world = object("UWorld /Game/NextLevel")
statics.audio_seconds = 200
clock = clock_status()
check(close(clock.active_play_seconds,total), "world replacement rebases without resetting the cumulative total")
clock = clock_status(3)
check(close(clock.active_play_seconds,total+3), "new world can contribute active time after its baseline")
total = clock.active_play_seconds
local next_state = object("BP_PagodaGameState_InfiniteDisco_C /Game/NextLevel.GS", {round=1,bWaveClearedRequested=false})
world.BP_PagodaGameState_InfiniteDisco_C = next_state
hooks[GS .. ":AdvanceRound"](param(next_state))
clock = clock_status(50)
check(clock.active_play and close(clock.active_play_seconds,total), "state identity replacement cannot credit the old interval")
clock = clock_status(2)
check(close(clock.active_play_seconds,total+2), "replacement state resumes from its own sample")
total = clock.active_play_seconds
engine_world = original_world
world.BP_PagodaGameState_InfiniteDisco_C = state
state.round = 0
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 1
hooks[GS .. ":AdvanceRound"](param(state))
clock_status()
statics.audio_seconds = 1
clock = clock_status()
check(close(clock.active_play_seconds,total), "backward native time rebases without decreasing the cumulative clock")
clock = clock_status(2)
check(close(clock.active_play_seconds,total+2), "clock recovers after a backward native sample")

for _, value in ipairs({0/0, math.huge, -math.huge, -1, "not a clock"}) do
    total = clock.active_play_seconds
    statics.audio_override = value
    clock = clock_status(10)
    check(clock.active_play == false and close(clock.active_play_seconds,total), "invalid native time freezes the finite clock")
    statics.audio_override = nil
    clock = clock_status()
    check(close(clock.active_play_seconds,total), "invalid native time recovery does not credit missed time")
end
for _, field in ipairs({"audio_failure", "pause_failure"}) do
    total = clock.active_play_seconds
    statics[field] = true
    clock = clock_status(100)
    check(not clock.active_play and close(clock.active_play_seconds,total), field .. " stops pacing without stopping the main loop")
    statics[field] = nil
    clock = clock_status()
    check(close(clock.active_play_seconds,total), field .. " recovery rebases")
end
total = clock.active_play_seconds
statics.controlled_pawn = nil
clock = clock_status(15)
check(not clock.active_play and close(clock.active_play_seconds,total), "missing controlled pawn freezes the clock")
statics.controlled_pawn = charlie
clock_status()
charlie._world = object("UWorld /Game/StalePawnWorld")
clock = clock_status(20)
check(not clock.active_play and close(clock.active_play_seconds,total), "a pawn from another world cannot advance the clock")
charlie._world = nil
clock_status()

state.bWaveClearedRequested = true
hooks[GS .. ":OnIncursionCleared_Event"](param(state))
state.bWaveClearedRequested = false -- downtime ended between polling samples
clock = clock_status(100)
check(close(clock.active_play_seconds,total), "wave-clear hook invalidates an otherwise unobserved downtime interval")
hooks[GS .. ":HandleLevelEnded"](param(state))
clock = clock_status(100)
check(not clock.active_play and close(clock.active_play_seconds,total), "menu/end latch freezes the clock while the old state remains valid")
state.round = 0
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 1
hooks[GS .. ":AdvanceRound"](param(state))
clock = clock_status(100)
check(clock.active_play and close(clock.active_play_seconds,total), "run restart preserves the total and discards the transition interval")
local real_time = os.time
os.time = function() return real_time()+100 end -- avoid the existing death-notification debounce
hooks[PLAYER .. ":OnDeathStartedDelegate_Event"](param(charlie))
os.time = real_time
clock = clock_status(100)
check(not clock.active_play and close(clock.active_play_seconds,total), "death immediately invalidates pacing")
state.round = 0
hooks[GS .. ":ReinitDiscoState"](param(state))
state.round = 1
hooks[GS .. ":AdvanceRound"](param(state))
clock_status()

-- A probe and an AP client may reuse the same id. Acknowledgements preserve origin,
-- and lifecycle timestamps reflect completion rather than the last status heartbeat.
raw_effect("cars", 1, "probe-origin", true)
clock = clock_status()
local probe_start = events_of("effect_start")[#events_of("effect_start")]
check(probe_start.command_session == "probe-origin" and probe_start.car_count == 1
    and close(probe_start.active_play_seconds,clock.active_play_seconds), "probe start echoes origin and its active-clock stamp")
raw_effect("cars", 1, "other-origin", true)
clock_status()
local probe_refusal = events_of("effect_failed")[#events_of("effect_failed")]
check(probe_refusal.reason == "busy" and probe_refusal.command_session == "other-origin",
    "same-id competing probe refusal keeps the competing session")
total = clock.active_play_seconds
fake_cars.done = "native_finished"
fake_cars.stop_advance = 0.375 -- completion occurs after the main loop's initial clock sample
clock = clock_status(2.75)
fake_cars.stop_advance = nil
local probe_end = events_of("effect_end")[#events_of("effect_end")]
check(close(clock.active_play_seconds,total+3.125), "active effect and airborne-capable play still advance pacing")
check(probe_end.command_session == "probe-origin" and probe_end.command_id == 1
    and close(probe_end.active_play_seconds,total+3.125), "probe end retains original session and samples after actual cleanup")
raw_effect("slowmo", 9000, nil)
clock_status()
local legacy_start = events_of("effect_start")[#events_of("effect_start")]
check(legacy_start.command_session == nil and type(legacy_start.active_play_seconds) == "number",
    "legacy command without a session remains supported")
command({type="effect",effect="fever",duration=30})
clock_status(0.75)
check(events_of("effect_end")[#events_of("effect_end")].command_session == nil,
    "legacy effect end does not borrow the replacing command session")
hooks[GS .. ":HandleLevelEnded"](param(state))
clock_status()

-- A missing optional native adapter must leave the other adapter and original traps usable.
-- Reload only initialization here, discarding the previous scheduled loop.
local real_require, real_dofile = require, dofile
for _, missing in ipairs({"meteor", "cars"}) do
    local other = missing == "meteor" and "cars" or "meteor"
    local other_adapter = other == "cars" and fake_cars or fake_meteor
    for _, failure in ipairs({"missing_file", "constructor_failure", "nil_adapter"}) do
        local label = missing .. " " .. failure
        scheduled, hooks = {}, {}
        state.round, state.bWaveClearedRequested = 0, false
        package.loaded[other] = {new = function() return other_adapter end}
        local output_before = #output
        if failure == "missing_file" then
            package.loaded[missing] = nil
            require = function(name)
                if name == missing then error("test " .. missing .. " module unavailable") end
                return real_require(name)
            end
            dofile = function(path)
                if path:match(missing .. "%.lua$") then error("test " .. missing .. " file unavailable") end
                return real_dofile(path)
            end
        else
            package.loaded[missing] = {new = function()
                if failure == "constructor_failure" then error("test adapter constructor unavailable") end
                return nil
            end}
        end
        local loaded, why = pcall(real_dofile, root .. "/mod/DeadAsDiscoAP/Scripts/main.lua")
        require, dofile = real_require, real_dofile
        check(loaded and #scheduled == 1, label .. " preserves main startup: " .. tostring(why))
        if loaded then
            tick()
            hooks[GS .. ":ReinitDiscoState"](param(state))
            state.round = 1
            hooks[GS .. ":AdvanceRound"](param(state))
            tick(4)
            local status, advertised = read_status(), false
            check(status.clock_version == 1 and status.active_play_seconds == 0,
                label .. " starts a fresh cumulative clock for a new mod session")
            for _, key in ipairs(status.effects) do if key == missing then advertised = true end end
            check(not advertised and #status.effects == 6 and not status[missing .. "_ready"] and status[other .. "_ready"],
                label .. " removes only its own capability and readiness")
            command({type = "effect", effect = missing})
            tick()
            check(events_of("effect_failed")[#events_of("effect_failed")].reason == "unsupported",
                label .. " produces clean unsupported refusal")
            command({type = "effect", effect = other})
            tick()
            check(other_adapter.active and events_of("effect_start")[#events_of("effect_start")].effect == other,
                label .. " leaves the other native trap operational")
            other_adapter.done = "native_finished"
            tick()
            command({type = "effect", effect = "slowmo"})
            tick()
            check(statics.dilation == 0.6 and events_of("effect_start")[#events_of("effect_start")].effect == "slowmo",
                label .. " leaves ordinary traps operational")
            hooks[GS .. ":HandleLevelEnded"](param(state))
            tick()
            check(statics.dilation == 1.0, label .. " preserves ordinary trap cleanup")
            local logged = false
            for index = output_before + 1, #output do
                if output[index]:find(missing .. " unavailable:", 1, true) then logged = true end
            end
            check(logged, label .. " logs the unavailable adapter")
        end
    end
end

for _, line in ipairs(output) do
    if line:find("error", 1, true) and not line:find("kill stage", 1, true) then
        check(false, "unexpected error output: " .. line)
    end
end

print = function(text) io.stdout:write(text) end
print(string.format("%d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
