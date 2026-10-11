-- Bundled by prepare_arcade_checks_runtime.py. Sources remain disabled.
-- json and ThreeWave are scoped modules supplied by that deterministic bundler.
local ENABLE_CHECKS = false
local CONFIG = nil
if not ENABLE_CHECKS or type(CONFIG) ~= "table" then return end
local GAME_STATE = "/Game/Pagoda/Core/GameModes/InfiniteDisco/BP_PagodaGameState_InfiniteDisco.BP_PagodaGameState_InfiniteDisco_C"
local CLASS = "BlueprintGeneratedClass " .. GAME_STATE
local WORLD_PREFIX = "BP_PagodaGameState_InfiniteDisco_C /Game/Pagoda/Levels/InfiniteDisco/L_InfiniteDisco_Persistent.L_InfiniteDisco_Persistent:PersistentLevel."
local BUILD = "dad-arcade-milestones-v1-" .. CONFIG.install_id
local HOOK = GAME_STATE .. ":AdvanceRound"
local TARGETS = {"ReinitDiscoState", "AdvanceRound", "OnIncursionCleared_Event",
    "OnTimer_WaveCleared", "HandleLevelEnded", "HandleLevelRestarted"}
local BOOLS = {"bIsActive", "bIsInfinite", "bInfiniteDiscoByUI", "bWaveClearedRequested",
    "DoInfiniteDiscoNextSong", "bShowSongListOnNextLevelRestart"}
local detector, adopted_sha, current_session, session_bytes = nil, nil, nil, nil
local sequence, lines, registrations, attempts = 0, 0, {}, {}
local stopped, timer, poll_handle, last_binding = false, nil, nil, nil
local MAX_MS = 86400000
local function integer(value, lo, hi)
    return type(value)=="number" and value==value and value%1==0 and value>=lo and value<=hi
end
local function emit(kind, data)
    if lines>=2048 then return end
    lines=lines+1
    data=data or {}; data.kind=kind; data.utc=os.date("!%Y-%m-%dT%H:%M:%SZ")
    data.install_id=CONFIG.install_id; data.adapter_build=BUILD; data.profile="arcade_milestones_v1"
    print("[DADAPArcadeCheck] " .. json.encode(data) .. "\n")
end
local function revoke(reason)
    current_session,session_bytes=nil,nil
    if detector then detector.revoke() end
    if last_binding~=reason then emit("session_inactive",{reason=reason}); last_binding=reason end
end
local function stop(reason)
    stopped=true; revoke(reason)
end
local function clock()
    if stopped or not integer(timer,1,9007199254740991) or not IsDelayedActionActive(timer) then
        error("bounded observer lifetime ended")
    end
    local remaining=GetDelayedActionTimeRemaining(timer)
    if not integer(remaining,0,MAX_MS) then error("invalid monotonic timer") end
    return os.time(),(MAX_MS-remaining)/1000
end
-- A bounded lexical guard rejects duplicate/escaped keys before the pinned JSON
-- decoder. Arrays are allowed only as values; the core validates their exact keys.
local function guarded_json(bytes)
    local stack,quoted,escaped,start={},false,false,0
    for i=1,#bytes do
        local c=bytes:sub(i,i)
        if quoted then
            if escaped then escaped=false
            elseif c=="\\" then escaped=true
            elseif c=='"' then
                quoted=false
                if bytes:sub(i+1):match("^%s*:") then
                    local key=bytes:sub(start+1,i-1)
                    local frame=stack[#stack]
                    if not key:match("^[A-Za-z_][A-Za-z_0-9]*$") or not frame or frame.kind~="{"
                        or frame.keys[key] then return false end
                    frame.keys[key]=true
                end
            end
        elseif c=='"' then quoted,start=true,i
        elseif c=="{" or c=="[" then
            if #stack>=3 then return false end
            stack[#stack+1]={kind=c,keys={}}
        elseif c=="}" or c=="]" then
            local frame=stack[#stack]
            if not frame or frame.kind~=(c=="}" and "{" or "[") then return false end
            stack[#stack]=nil
        end
    end
    return #stack==0 and not quoted and bytes:match("^%s*{")~=nil
end
local function read_bytes(path)
    local file=io.open(path,"rb"); if not file then return nil end
    local bytes=file:read(4097); file:close()
    if not bytes or #bytes>4096 then return nil end
    return bytes
end
local function raw_session()
    local file=io.open(CONFIG.bridge_dir.."/check-session.json","rb")
    if not file then return nil,nil,"read_unavailable" end
    local bytes=file:read(4097);file:close()
    if not bytes or #bytes>4096 or not guarded_json(bytes) then return nil,nil,"invalid_json" end
    local ok,value=pcall(json.decode,bytes)
    if not ok or type(value)~="table" then return nil,nil,"invalid_json" end
    return value,bytes
end
local function publish(bytes,event_id)
    -- The core fixes both strings once. Existing destination bytes must match.
    if not detector or not detector.authorized() or not session_bytes
        or read_bytes(CONFIG.bridge_dir.."/check-session.json")~=session_bytes then return false end
    if type(event_id)~="string" or #event_id>120 or not event_id:match("^[a-z0-9%-]+$") then return false end
    local destination=CONFIG.bridge_dir.."/events/"..event_id..".json"
    local temporary=CONFIG.bridge_dir.."/events/"..event_id..".tmp"
    local exists=io.open(destination,"rb")
    if exists then
        local prior=exists:read(4097); exists:close()
        if prior==bytes then
            emit("event_already_present_identical",{event_id=event_id,session_nonce=current_session.session_nonce})
            return "already_present_identical"
        end
        emit("event_conflict",{event_id=event_id}); return false
    end
    local file=io.open(temporary,"wb"); if not file then return false end
    local written=file:write(bytes); local flushed=file:flush(); local closed=file:close()
    if not written or not flushed or not closed then return false end
    -- A stale/replaced lease cannot publish a completed temporary file.
    if not detector.authorized() or read_bytes(CONFIG.bridge_dir.."/check-session.json")~=session_bytes then return false end
    local moved=os.rename(temporary,destination); if not moved then return false end
    local event=json.decode(bytes)
    emit("event_published",{event_id=event_id,session_nonce=event.session_nonce,wave=event.wave,
        location=event.location,run_id=event.run_id,clear_sequence=event.clear_sequence,
        advance_sequence=event.advance_sequence})
    return "published"
end
local function refresh(observation_pending)
    if stopped then return false end
    local session,bytes,read_reason=raw_session()
    if not session then
        if read_reason=="read_unavailable" then
            current_session,session_bytes=nil,nil
            -- Windows sharing can briefly prevent a read during replacement.
            -- Never extend authority or publish while unavailable. Expiry still
            -- retires the old nonce; a missed game callback discards its chain.
            if detector then
                detector.authorized()
                if observation_pending then detector.discard_attempt() end
            end
            if last_binding~="read_unavailable" then emit("session_suspended",{reason=read_reason});last_binding=read_reason end
        else revoke(read_reason) end
        return false
    end
    if not detector then
        local sha=session.adapter_sha256
        if type(sha)~="string" or #sha~=64 or not sha:match("^[a-f0-9]+$") then return false end
        local candidate=ThreeWave.new({enabled=true,runtime_checks=true,
            profile="owner_requested_arcade_20261011",accept_calibration_assumption=true,
            identity=CONFIG.identity,install_id=CONFIG.install_id,adapter_build=BUILD,adapter_sha256=sha,
            clock=clock,encode=json.encode,publish=publish})
        local accepted,reason=candidate.bind_session(session)
        if not accepted then
            if last_binding~=reason then emit("session_rejected",{reason=reason});last_binding=reason end
            return false
        end
        detector,adopted_sha=candidate,sha
    else
        local accepted,reason=detector.bind_session(session)
        if not accepted then revoke(reason);return false end
    end
    current_session,session_bytes=session,bytes
    if last_binding~=session.session_nonce then
        emit("session_bound",{session_nonce=session.session_nonce,adapter_sha256=adopted_sha,
            lease_revision=session.lease_revision,waiting_for_reinit=detector.status().phase=="await_reinit",
            runtime_self_hash_verified=false})
        last_binding=session.session_nonce
    end
    return true
end
local function observe(name,remote)
    if not refresh(true) then return end
    local object=remote:get()
    if not object or not object:IsValid() then revoke("invalid_context"); return end
    local class=object:GetClass()
    if not class or not class:IsValid() or class:GetFullName()~=CLASS then revoke("wrong_class");return end
    local context=object:GetFullName()
    if type(context)~="string" or context:sub(1,#WORLD_PREFIX)~=WORLD_PREFIX then revoke("wrong_world");return end
    local address=object:GetAddress()
    if not integer(address,1,9007199254740991) then revoke("invalid_context_address");return end
    local binding=tostring(address)
    local snapshot={round=object:GetPropertyValue("round")}
    for _,field in ipairs(BOOLS) do snapshot[field]=object:GetPropertyValue(field) end
    if not object:IsValid() or object:GetAddress()~=address or object:GetFullName()~=context then
        revoke("context_changed_during_read");return
    end
    sequence=sequence+1
    local event={name=name,class=CLASS,phase="post",context=context,binding_id=binding,sequence=sequence,
        snapshot=snapshot,identity=CONFIG.identity,session_nonce=current_session.session_nonce}
    local completion,reason=detector.observe(event)
    emit("observation",{name=name,class=CLASS,phase="post",observed_context=context,binding_id=binding,
        sequence=sequence,snapshot=snapshot,session_nonce=current_session.session_nonce,result=reason})
    if completion then emit("completion_queued",completion) end
    if refresh() then detector.tick() end
end
local function register_available()
    if stopped then return end
    for _,name in ipairs(TARGETS) do
        if not registrations[name] and (attempts[name] or 0)<4 then
            attempts[name]=(attempts[name] or 0)+1
            local path=GAME_STATE..":"..name
            local found=StaticFindObject(path)
            if found and found:IsValid() then
                local flags=found:GetFunctionFlags()
                if not integer(flags,0,4294967295) or (flags & 0x400)~=0 then
                    stop("unexpected_native_hook");return
                end
                local pre,post=RegisterHook(path,function(remote,...)
                    local ok=pcall(observe,name,remote)
                    if not ok then revoke("callback_error_"..name) end
                    return nil
                end)
                if not integer(pre,1,9007199254740991) or pre~=post then stop("script_post_contract_failed");return end
                registrations[name]=true
                emit("registered",{hook_path=path,function_flags=flags,pre_id=pre,post_id=post})
            else emit("not_loaded",{hook_path=path}) end
        end
    end
end
local function poll()
    if stopped then return end
    local ok=pcall(function()
        clock()
        if refresh() then detector.tick() end
    end)
    if not ok then stop("poll_error");return end
    poll_handle=ExecuteInGameThreadWithDelay(500,poll)
    if not integer(poll_handle,1,9007199254740991) then stop("poll_timer_failed") end
end
emit("enabled",{checks_only=true,integration_version=3,locations={814000101,814000102,814000103,814000105,814000110,814000115,814000120,814000125,814000130,814000140,814000150,814000175,814000200,814000250,814000300},
    unlock_application_enabled=false,ability_gating=false,death_link_enabled=false,runtime_self_hash_verified=false})
ExecuteInGameThread(function()
    timer=ExecuteInGameThreadWithDelay(MAX_MS,function() stop("bounded_lifetime_expired") end)
    if not integer(timer,1,9007199254740991) then stop("lifetime_timer_failed");return end
    register_available(); poll()
end)
NotifyOnNewObject(GAME_STATE,function()
    -- Notification can include subclasses; ignore the constructed object and
    -- resolve only the six exact allowlisted descriptors on the game thread.
    if not stopped then ExecuteInGameThread(register_available) end
    return true
end)
