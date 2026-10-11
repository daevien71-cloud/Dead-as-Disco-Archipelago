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
local function object(name, props)
    next_address = next_address + 1
    local o = props or {}
    o._valid, o._name, o._address = true, name, next_address
    function o:IsValid() return self._valid end
    function o:GetFullName() return self._name end
    function o:GetAddress() return self._address end
    function o:GetPropertyValue(key) return self[key] end
    return o
end
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

local loop
function LoopAsync(_, callback) loop = callback end
function ExecuteInGameThread(callback) callback() end
local keybinds = {}
function RegisterKeyBind(key, _, callback) keybinds[key] = callback end
Key = {F5 = "F5", F6 = "F6", F7 = "F7", F8 = "F8", F9 = "F9", F10 = "F10", F11 = "F11"}
ModifierKey = {CONTROL = "CTRL"}
function FName(text) return {name = text} end

local statics = object("Default__GameplayStatics", {dilation = 1.0, damage_calls = 0})
function statics:SetGlobalTimeDilation(_, speed) self.dilation = speed end
function statics:GetGlobalTimeDilation() return self.dilation end
function statics:ApplyDamage() self.damage_calls = self.damage_calls + 1 end
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
local function tick(n) for _ = 1, (n or 1) do loop() end end
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
dofile(root .. "/mod/DeadAsDiscoAP/Scripts/main.lua")
check(loop ~= nil, "main loop registered")
tick(1)
check(read_events()[1] and read_events()[1].type == "hello", "hello event written on start")
check(hooks[GS .. ":AdvanceRound"] ~= nil, "AdvanceRound hooked")
check(hooks["/Script/Pagoda.PagodaInfiniteDiscoSubsystem:NotifyEnemyKilled"] ~= nil, "kill hook registered")
check(hooks[PLAYER .. ":OnDeathStartedDelegate_Event"] ~= nil, "death hook registered")

-- Start an Arcade run.
local state = object("BP_PagodaGameState_InfiniteDisco_C /Game/Level.PersistentLevel.GS_1", {round = 0})
local charlie = object("BP_PagodaPlayerCharacter_Charlie_C /Game/Level.PersistentLevel.Charlie_1", {CustomTimeDilation = 1.0})
local camera = object("PlayerCameraManager", {fades = {}})
function camera:StartCameraFade(from, to) self.fades[#self.fades + 1] = {from, to} end
local pc = object("BP_PagodaPlayerController_C /Game/Level.PersistentLevel.PC_1", {PlayerCameraManager = camera})
function charlie:FinishDeath() self.finished = true end
world.BP_PagodaGameState_InfiniteDisco_C = state
world.BP_PagodaPlayerCharacter_Charlie_C = charlie
world.BP_PagodaPlayerController_C = pc

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
check(camera.fades[1] and camera.fades[1][2] == 0.9, "blackout fades camera in")
command({type = "effect", effect = "nope"})
tick(1)
local failed = events_of("effect_failed")
check(#failed == 1 and failed[1].reason == "unknown effect", "unknown effect reported as failed")

-- Learn enemy damage, then a DeathLink kill uses it.
local damage_effect = object("BlueprintGeneratedClass /Game/GE_Damage.GE_Damage_C")
hooks["/Script/Pagoda.PagodaCombatFunctionLibrary:ApplySetByCallerEffect"](
    param(library), param(charlie), param(damage_effect), param({TagName = {ToString = function() return "Data.Damage" end}}), param(12))
command({type = "kill", source = "Friend"})
tick(1)
check(#library.calls == 1 and library.calls[1].value == 99999 and library.calls[1].tag.TagName.name == "Data.Damage",
    "kill applies a lethal hit using the learned damage effect")
hooks[PLAYER .. ":OnDeathStartedDelegate_Event"](param(charlie))
tick(4)
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

-- Kill fallback: no learned damage path -> engine damage -> FinishDeath.
command({type = "kill"})
tick(1)
check(#library.calls == 2, "kill stage 1 tried learned hit again")
local t = os.time() + 4
while os.time() < t do end
tick(1)
check(statics.damage_calls == 1, "kill stage 2 tries engine ApplyDamage")
t = os.time() + 4
while os.time() < t do end
tick(1)
check(charlie.finished == true, "kill stage 3 calls FinishDeath")

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

-- Leaving Arcade ends the run.
world.BP_PagodaGameState_InfiniteDisco_C = nil
state._valid = false
tick(4)
check(charlie.CustomTimeDilation == 1.0, "leaving Arcade reverts molasses")
check(read_status().in_run == false, "not in_run after leaving Arcade")

keybinds.F11()
tick(1)
local logs = events_of("log")
check(logs[#logs].text:find("status:", 1, true) ~= nil, "Ctrl+F11 logs a status line")

for _, line in ipairs(output) do
    if line:find("error", 1, true) and not line:find("kill stage", 1, true) then
        check(false, "unexpected error output: " .. line)
    end
end

print = function(text) io.stdout:write(text) end
print(string.format("%d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
