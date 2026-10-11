-- Pure checks-only state machine. No UE4SS, file, network, ability or goal APIs.
-- Explicitly enabled only by the separately prepared, reviewed runtime wrapper.
local M = {}
local BUILD_PREFIX = "dad-arcade-milestones-v1"
local WIRE_PROFILE = "arcade_milestones_v1"
local GAME = "Dead as Disco (Arcade Milestones)"
local HOOK = "/Game/Pagoda/Core/GameModes/InfiniteDisco/BP_PagodaGameState_InfiniteDisco.BP_PagodaGameState_InfiniteDisco_C:AdvanceRound"
local MILESTONES = {1,2,3,5,10,15,20,25,30,40,50,75,100,150,200}
local MILESTONE_SET = {}; for _,wave in ipairs(MILESTONES) do MILESTONE_SET[wave]=true end
local PROFILE = "owner_requested_arcade_20261011"
local CLASS = "BlueprintGeneratedClass /Game/Pagoda/Core/GameModes/InfiniteDisco/BP_PagodaGameState_InfiniteDisco.BP_PagodaGameState_InfiniteDisco_C"
local BOOLS = {"bIsActive", "bIsInfinite", "bInfiniteDiscoByUI", "bWaveClearedRequested",
    "DoInfiniteDiscoNextSong", "bShowSongListOnNextLevelRestart"}
local EVENTS = {ReinitDiscoState=true, AdvanceRound=true, OnIncursionCleared_Event=true,
    OnTimer_WaveCleared=true, HandleLevelEnded=true, HandleLevelRestarted=true}
local SESSION_FIELDS = {schema_version=true,purpose=true,profile=true,integration_version=true,game=true,
    checks_enabled=true,unlock_application_enabled=true,ability_gating=true,identity=true,session_nonce=true,
    locations=true,clear_rounds=true,confirming_advance_rounds=true,published_at_utc=true,valid_until_utc=true,
    lease_revision=true,adapter_build=true,hook_path=true,adapter_sha256=true,install_id=true}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and v>-math.huge and v<math.huge end
local function integer(v, lo, hi) return finite(v) and v>=lo and v<=hi and v%1==0 end
local function text(v, lo, hi) return type(v)=="string" and #v>=lo and #v<=hi and not v:find("[%c]") end
local function hex(v, n) return type(v)=="string" and #v==n and v:match("^[a-f0-9]+$")~=nil end
local function copy(v)
    if type(v)~="table" then return v end
    local result={}; for k,value in pairs(v) do result[k]=copy(value) end; return result
end
local function identity(v)
    if not plain(v) or not text(v.seed_name,1,160) or not integer(v.team,0,2147483647)
        or not integer(v.slot,1,2147483647) then return false end
    for k in pairs(v) do if k~="seed_name" and k~="team" and k~="slot" then return false end end
    return true
end
local function same_identity(a,b)
    return identity(a) and identity(b) and a.seed_name==b.seed_name and a.team==b.team and a.slot==b.slot
end
local function snapshot(v)
    if not plain(v) or not integer(v.round,-2147483648,2147483647) then return false end
    for _,key in ipairs(BOOLS) do if type(v[key])~="boolean" then return false end end
    return true
end
local function profile(v)
    -- Captured values, not general assertions about activity or Arcade mode.
    return not v.bIsActive and not v.bIsInfinite and v.bInfiniteDiscoByUI
        and not v.DoInfiniteDiscoNextSong and not v.bShowSongListOnNextLevelRestart
end

function M.new(options)
    options=plain(options) and options or {}
    local enabled=options.enabled==true
    local config_ok=enabled and options.runtime_checks==true
        and options.profile==PROFILE and options.accept_calibration_assumption==true
        and identity(options.identity) and hex(options.install_id,32)
        and options.adapter_build==BUILD_PREFIX.."-"..options.install_id and hex(options.adapter_sha256,64)
        and type(options.clock)=="function" and type(options.encode)=="function" and type(options.publish)=="function"
    local cfg=config_ok and {identity=copy(options.identity), install_id=options.install_id,
        adapter_build=options.adapter_build, adapter_sha256=options.adapter_sha256} or {}
    local clock,encode,publish=options.clock,options.encode,options.publish
    local session,deadline,last_mono=nil,nil,nil
    local retired,session_count={},0
    local outbox,produced={},{}
    local phase,context,binding,round="await_reinit",nil,nil,nil
    local prefix,attempt,last_sequence,observations={},0,0,0
    local suspended,busy,last_reason=false,false,"disabled"
    local function reset_attempt(reason)
        phase,context,binding,round="await_reinit",nil,nil,nil
        prefix={}; last_reason=reason
        return nil,reason
    end
    local function retire(reason)
        if session then retired[session.session_nonce]=true end
        session,deadline=nil,nil
        outbox,produced={},{}
        reset_attempt(reason)
        return false,reason
    end
    local function now()
        if not config_ok then return nil end
        local ok,utc,mono=pcall(clock)
        if not ok or not finite(utc) or not finite(mono) or mono<0 or (last_mono and mono<last_mono) then
            retire("invalid_clock"); return nil
        end
        last_mono=mono
        return utc,mono
    end
    local function live()
        local utc,mono=now()
        if not utc or not session then return false end
        if mono>=deadline or utc>=session.valid_until_utc or session.published_at_utc>utc+1 then
            retire("expired_session"); return false
        end
        return true
    end
    local function bind_session(s)
        if busy then return false,"busy" end
        if not config_ok then return false,enabled and "configuration_not_accepted" or "disabled" end
        local utc,mono=now()
        if not utc then return false,"invalid_clock" end
        -- Check the existing monotonic deadline before considering any renewal.
        if session and (mono>=deadline or utc>=session.valid_until_utc or session.published_at_utc>utc+1) then
            retire("expired_session")
        end
        local function milestone_array(value,offset)
            if not plain(value) then return false end
            local count=0
            for k in pairs(value) do if not integer(k,1,#MILESTONES) then return false end;count=count+1 end
            if count~=#MILESTONES then return false end
            for i,wave in ipairs(MILESTONES) do if value[i]~=wave+offset then return false end end
            return true
        end
        local valid=plain(s) and s.schema_version==1 and s.purpose=="checks_only"
            and s.profile==WIRE_PROFILE and s.integration_version==3 and s.game==GAME
            and s.checks_enabled==true and s.unlock_application_enabled==false and s.ability_gating==false
            and milestone_array(s.locations,814000100) and milestone_array(s.clear_rounds,0)
            and milestone_array(s.confirming_advance_rounds,1)
            and same_identity(s.identity,cfg.identity) and hex(s.session_nonce,32)
            and s.install_id==cfg.install_id and s.adapter_build==cfg.adapter_build and s.hook_path==HOOK
            and s.adapter_sha256==cfg.adapter_sha256 and integer(s.lease_revision,1,9007199254740991)
            and integer(s.published_at_utc,0,9007199254740991) and integer(s.valid_until_utc,0,9007199254740991)
            and s.published_at_utc<=utc and s.published_at_utc>=utc-10
            and s.valid_until_utc>utc+1 and s.valid_until_utc>s.published_at_utc
            and s.valid_until_utc-s.published_at_utc<=10 and s.valid_until_utc<=utc+10
        if valid then for k in pairs(s) do if not SESSION_FIELDS[k] then valid=false end end end
        if not valid then return retire("invalid_session") end
        if retired[s.session_nonce] then return retire("retired_nonce") end
        if session and s.session_nonce==session.session_nonce then
            if s.lease_revision<session.lease_revision or s.published_at_utc<session.published_at_utc then
                return retire("session_revision_reversed")
            end
            if s.lease_revision==session.lease_revision then
                if s.published_at_utc~=session.published_at_utc or s.valid_until_utc~=session.valid_until_utc then
                    return retire("conflicting_revision")
                end
                return true,"same_lease_no_extension"
            end
            if s.published_at_utc==session.published_at_utc then
                if s.valid_until_utc~=session.valid_until_utc then return retire("same_second_expiry_changed") end
                session=copy(s)
                last_reason="revision_advanced_without_extension"; return true,last_reason
            end
            session=copy(s); deadline=mono+math.min(10,s.valid_until_utc-utc-1)
            last_reason="lease_renewed"; return true,last_reason
        end
        if session_count>=64 then return retire("session_cap") end
        retire("new_session")
        session_count=session_count+1
        session=copy(s); deadline=mono+math.min(10,s.valid_until_utc-utc-1)
        attempt,last_sequence,observations,suspended=0,0,0,false
        last_reason="bound_await_reinit"; return true,last_reason
    end
    local function queue_completion(n)
        if not MILESTONE_SET[n] then return nil,"non_milestone_clear" end
        if produced[n] then return nil,"location_already_produced" end
        if #outbox>=15 then suspended=true; return nil,"outbox_cap" end
        local run=cfg.install_id.."-"..attempt
        local event_id=session.session_nonce.."-"..run.."-wave"..n
        local payload={schema_version=1,kind="wave_cleared",origin="game_runtime",mode="arcade",
            profile=WIRE_PROFILE,integration_version=3,completed=true,
            identity=copy(cfg.identity),session_nonce=session.session_nonce,install_id=cfg.install_id,
            adapter_build=cfg.adapter_build,adapter_sha256=cfg.adapter_sha256,hook_path=HOOK,
            run_id=run,event_id=event_id,observed_context=context,binding_id=binding,
            wave=n,location=814000100+n,anchor_reinit_sequence=prefix.anchor_reinit_sequence,
            anchor_advance_sequence=prefix.anchor_advance_sequence,
            clear_sequence=prefix["clear_"..n.."_sequence"],advance_sequence=prefix["advance_"..n.."_sequence"],contiguous_clears=n,
            prefix={{wave=n,clear_sequence=prefix["clear_"..n.."_sequence"],advance_sequence=prefix["advance_"..n.."_sequence"]}}}
        local ok,bytes=pcall(encode,copy(payload))
        if not ok or type(bytes)~="string" or #bytes<2 or #bytes>4096 then
            suspended=true; return nil,"encoding_failed"
        end
        local entry={payload=payload,bytes=bytes,event_id=event_id,state="pending",attempts=0}
        outbox[#outbox+1]=entry; produced[n]=true
        return copy(payload),"completion_once"
    end
    local function observe(e)
        if busy then return nil,"busy" end
        if not config_ok then return nil,enabled and "configuration_not_accepted" or "disabled" end
        if not live() then return nil,last_reason end
        if suspended then return nil,"suspended" end
        observations=observations+1
        if observations>100000 then suspended=true; return reset_attempt("observation_cap") end
        if not plain(e) or not EVENTS[e.name] or e.class~=CLASS or e.phase~="post"
            or not text(e.context,1,768) or not text(e.binding_id,1,160)
            or not integer(e.sequence,1,9007199254740991) or not snapshot(e.snapshot)
            or e.session_nonce~=session.session_nonce or not same_identity(e.identity,cfg.identity) then
            return reset_attempt("invalid_observation")
        end
        if e.sequence<=last_sequence then return reset_attempt("nonincreasing_sequence") end
        last_sequence=e.sequence
        if e.name=="HandleLevelEnded" or e.name=="HandleLevelRestarted" then
            return reset_attempt("lifecycle_boundary")
        end
        if not profile(e.snapshot) then return reset_attempt("profile_mismatch") end
        local r,requested=e.snapshot.round,e.snapshot.bWaveClearedRequested
        if e.name=="ReinitDiscoState" then
            if r~=0 or requested then return reset_attempt("unrecognized_reinit") end
            attempt=attempt+1
            if attempt>2048 then suspended=true; return reset_attempt("attempt_cap") end
            context,binding,round,phase=e.context,e.binding_id,0,"await_one"
            prefix={anchor_reinit_sequence=e.sequence}
            return nil,"attempt_started"
        end
        if not context then return nil,"await_reinit" end
        if e.context~=context or e.binding_id~=binding then return reset_attempt("context_changed") end
        if e.name=="OnTimer_WaveCleared" then
            if (phase=="active" or phase=="complete") and round>=2 and r==round and not requested
                and prefix["advance_"..(round-1).."_sequence"] then
                return nil,"post_advance_timer"
            end
            return reset_attempt("uncalibrated_timer_order")
        end
        if e.name=="OnIncursionCleared_Event" then
            if (phase=="active" or phase=="pending") and r==round and r>=1 and r<=200 and requested then
                if phase~="pending" then prefix["clear_"..r.."_sequence"]=e.sequence end
                phase="pending"; return nil,"clear_pending"
            end
            return reset_attempt("unrecognized_clear")
        end
        if e.name=="AdvanceRound" then
            if phase=="await_one" and r==1 and not requested then
                prefix.anchor_advance_sequence=e.sequence; phase,round="active",1
                return nil,"round_one_started"
            end
            if (phase=="active" or phase=="complete") and r==round and not requested then
                return nil,"duplicate_advance"
            end
            if phase=="pending" and r==round+1 and not requested then
                local completed=round
                prefix["advance_"..completed.."_sequence"]=e.sequence
                round=r; phase=completed==200 and "complete" or "active"
                return queue_completion(completed)
            end
            return reset_attempt("unrecognized_advance")
        end
        return reset_attempt("unrecognized_event")
    end
    local function tick()
        if busy then return 0,"busy" end
        if not config_ok then return 0,enabled and "configuration_not_accepted" or "disabled" end
        if not live() then return 0,last_reason end
        if suspended then return 0,"suspended" end
        local published=0
        for _,entry in ipairs(outbox) do
            if entry.state=="pending" then
                if not live() then return published,last_reason end
                if entry.attempts>=8 then entry.state="failed"; suspended=true; return published,"retry_cap" end
                entry.attempts=entry.attempts+1
                local nonce=session.session_nonce
                busy=true
                local ok,result=pcall(publish,entry.bytes,entry.event_id)
                busy=false
                if not live() or not session or nonce~=session.session_nonce then
                    return published,"lease_lost_during_publish"
                end
                if ok and (result=="published" or result=="already_present_identical") then
                    entry.state="published"; published=published+1
                else
                    if entry.attempts>=8 then entry.state="failed"; suspended=true; return published,"retry_cap" end
                    return published,"publication_deferred"
                end
            end
        end
        return published,"drained"
    end
    return {
        bind_session=bind_session, observe=observe, tick=tick,
        authorized=function() return config_ok and live() and not suspended end,
        discard_attempt=function() return reset_attempt("missed_observation_without_readable_lease") end,
        revoke=function() return retire("revoked") end,
        pending=function() return copy(outbox) end,
        status=function()
            local active=config_ok and live() or false
            return {enabled=enabled,configured=not not config_ok,active=not not active,
                session_nonce=session and session.session_nonce or nil,phase=phase,round=round,
                attempt=attempt,observations=observations,suspended=suspended,outbox_count=#outbox,
                reason=last_reason,runtime_checks=true,ability_gating=false,goal_supported=false}
        end,
    }
end
return M
