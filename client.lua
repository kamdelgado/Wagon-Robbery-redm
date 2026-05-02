---@diagnostic disable: undefined-global

--[[
    client.lua – Armoured Wagon Robbery
    ════════════════════════════════════════════════════════════════════════════

    PATTERNS TAKEN FROM REAL SCRIPTS:
    ─────────────────────────────────────────────────────────────────────────
    • Prompt loop structure:  outsider_grave_robbery (repeat-until, optimised
      sleep, PromptGroup, UiPromptSetActiveGroupThisFrame)
    • Minigame integration:   syn_minigame export taskBar(difficulty, skillGap)
    • Notification:           TriggerEvent("vorp:TipBottom", …) from outsider
    • NotifyLeft (job alert): VorpCore.NotifyLeft from outsider server → mirrored
      here for VFX notifications on client
    • NPC task assignment:    activating client owns the AI tasks because
      server-side TaskVehicleDriveToCoordLongrange is not available in OneSync
    • Guard tracking thread:  repeat-until loop with configurable sleep,
      mirroring outsider's digging_timer pattern
    • Entity resolution:      waitForNetEntity() with explicit timeout – no
      infinite loops (lesson from outsider's while-not-HasModelLoaded pattern)

    ZERO CreateVehicle / CreatePed HERE – all entities are server-spawned and
    resolved via NetworkGetEntityFromNetworkId().
--]]

-- ─── Shared constants from Config ─────────────────────────────────────────────
local TEXTS    = Config.Texts
local TEXTURES = Config.Textures

-- ─── Prompt Group (single persistent group, same approach as outsider) ────────
local PromptGroup   = GetRandomIntInRange(0, 0xffffff)

-- Prompt handles – created/destroyed as needed
local starterPrompt = nil
local wagonPrompt   = nil

-- ─── Client State ─────────────────────────────────────────────────────────────
local isActivator    = false
local missionPhase   = 'idle'    -- mirrors server phase

local wagonEnt       = nil
local driverEnt      = nil
local gunnerEnt      = nil
local guardEnts      = {}
local guardHorseEnts = {}
local reinfEnts      = {}
local reinfHorseEnts = {}

local totalHostiles  = 0
local totalReinf     = 0

local wagonBlip      = nil
local starterPedEnt  = nil   -- our local client-only ped at Tesla Tower

-- Thread kill flags
local monitorGuardsAlive = false
local monitorReinfAlive  = false
local deathWatchAlive    = false
local wagonProxAlive     = false

-- ─── Notification helper (matches outsider_grave_robbery exactly) ─────────────
local function notify(msg)
    TriggerEvent('vorp:TipBottom', msg, 5000)
end

-- ─── Debug helper ─────────────────────────────────────────────────────────────
local function dbg(...)
    if Config.Debug then print('[WagonRob:Client]', ...) end
end

-- ─── Model loader (mirrors outsider pattern: while not HasModelLoaded) ────────
local function loadModel(model)
    if HasModelLoaded(model) then return true end
    RequestModel(model, false)
    local t = 0
    while not HasModelLoaded(model) and t < 5000 do
        Wait(100); t = t + 100
    end
    return HasModelLoaded(model)
end

local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local t = 0
    while not HasAnimDictLoaded(dict) and t < 5000 do
        Wait(100); t = t + 100
    end
    return HasAnimDictLoaded(dict)
end

-- ─── Wait for a server netId to resolve into a local entity ──────────────────
-- Has a hard timeout so we never hang in an infinite loop.
local function waitForNetEntity(netId, timeout)
    if not netId then return nil end
    timeout = timeout or 8000
    local elapsed = 0
    while elapsed < timeout do
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local ent = NetworkGetEntityFromNetworkId(netId)
            if DoesEntityExist(ent) then return ent end
        end
        Wait(150); elapsed = elapsed + 150
    end
    dbg('waitForNetEntity timed out for netId=' .. tostring(netId))
    return nil
end

-- ─── Prompt helpers ───────────────────────────────────────────────────────────
-- Standard-mode prompt: single press (used for starter ped & loot stage).
local function makeStandardPrompt(label)
    local p = UiPromptRegisterBegin()
    UiPromptSetControlAction(p, Config.PromptKey)
    UiPromptSetText(p, VarString(10, 'LITERAL_STRING', label))
    UiPromptSetEnabled(p, true)
    UiPromptSetVisible(p, true)
    UiPromptSetStandardMode(p, true)
    UiPromptSetGroup(p, PromptGroup, 0)
    UiPromptRegisterEnd(p)
    return p
end

local function deletePrompt(p)
    if p then pcall(UiPromptDelete, p) end
end

-- ─── Blip ─────────────────────────────────────────────────────────────────────
local function addBlip()
    if wagonBlip and DoesBlipExist(wagonBlip) then RemoveBlip(wagonBlip) end
    if not (wagonEnt and DoesEntityExist(wagonEnt)) then return end
    wagonBlip = BlipAddForEntity(Config.Blip.sprite, wagonEnt)
    BlipSetRotation(wagonBlip, 0)
    BlipSetScale(wagonBlip, Config.Blip.scale)
    BlipAddModifier(wagonBlip, Config.Blip.color)
    BeginTextCommandSetBlipName('LITERAL_STRING')
    AddTextComponentSubstringPlayerName(Config.Blip.label)
    EndTextCommandSetBlipName(wagonBlip)
end

local function removeBlip()
    if wagonBlip and DoesBlipExist(wagonBlip) then RemoveBlip(wagonBlip) end
    wagonBlip = nil
end

-- ─── NPC AI (applied by activating client after netId resolves) ───────────────
local function applyNpcAI(ped, targetPed)
    if not (ped and DoesEntityExist(ped)) then return end
    SetPedAccuracy(ped, Config.NpcAccuracy)
    SetPedCombatAbility(ped, Config.NpcCombatAbility)
    SetPedCombatAttributes(ped, 2,  true)
    SetPedCombatAttributes(ped, 5,  true)
    SetPedCombatAttributes(ped, 46, true)
    SetPedCombatAttributes(ped, 52, true)
    if targetPed and DoesEntityExist(targetPed) then
        TaskCombatPed(ped, targetPed, 0, 16)
    end
end

-- ─── Full client reset ────────────────────────────────────────────────────────
local function fullReset()
    dbg('fullReset()')
    isActivator      = false
    missionPhase     = 'idle'
    wagonEnt         = nil; driverEnt  = nil; gunnerEnt  = nil
    guardEnts        = {}; guardHorseEnts = {}
    reinfEnts        = {}; reinfHorseEnts = {}
    totalHostiles    = 0; totalReinf = 0
    monitorGuardsAlive = false
    monitorReinfAlive  = false
    deathWatchAlive    = false
    wagonProxAlive     = false
    removeBlip()
    deletePrompt(wagonPrompt); wagonPrompt = nil
end

-- ─── Count dead among a table ─────────────────────────────────────────────────
local function countDead(tbl)
    local dead = 0
    for _, e in ipairs(tbl) do
        if DoesEntityExist(e) and IsEntityDead(e) then dead = dead + 1 end
    end
    return dead
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- STARTER PED: spawn + prompt loop
-- Mirrors outsider_grave_robbery's CreateThread / proximity loop exactly.
-- ═══════════════════════════════════════════════════════════════════════════════

CreateThread(function()
    repeat Wait(5000) until LocalPlayer.state.IsInSession

    local pc = Config.StarterPed.coords
    if loadModel(Config.StarterPed.model) then
        starterPedEnt = CreatePed(Config.StarterPed.model, pc.x, pc.y, pc.z, pc.w, false, false)
        if DoesEntityExist(starterPedEnt) then
            SetEntityInvincible(starterPedEnt, true)
            FreezeEntityPosition(starterPedEnt, true)
            SetBlockingOfNonTemporaryEvents(starterPedEnt, true)
            SetEntityAsMissionEntity(starterPedEnt, true, true)
            dbg('Starter ped spawned.')
        else
            print('[WagonRobbery] ERROR: Could not create starter ped. Verify Config.StarterPed.model.')
        end
        SetModelAsNoLongerNeeded(Config.StarterPed.model)
    else
        print('[WagonRobbery] ERROR: Starter ped model failed to load.')
    end
end)

-- Build starter prompt once, reuse it every frame (outsider style)
CreateThread(function()
    repeat Wait(5000) until LocalPlayer.state.IsInSession

    starterPrompt = makeStandardPrompt(TEXTS.StartPrompt)

    while true do
        local sleep = 1000
        local pped  = PlayerPedId()
        local isdead = IsEntityDead(pped)

        if not isdead and starterPedEnt and DoesEntityExist(starterPedEnt) then
            local dist = #(GetEntityCoords(pped) - GetEntityCoords(starterPedEnt))

            if dist < Config.PedTriggerDist then
                -- Enter tight loop – same pattern as outsider's repeat…until
                repeat
                    pped   = PlayerPedId()
                    isdead = IsEntityDead(pped)
                    dist   = #(GetEntityCoords(pped) - GetEntityCoords(starterPedEnt))
                    sleep  = 0

                    -- Show the prompt group header (outsider's UiPromptSetActiveGroupThisFrame)
                    UiPromptSetActiveGroupThisFrame(
                        PromptGroup,
                        VarString(10, 'LITERAL_STRING', 'Armoured Wagon'),
                        0, 0, 0, 0
                    )

                    if UiPromptHasStandardModeCompleted(starterPrompt, 0) then
                        TriggerServerEvent('wagonrobbery:requestStart')
                        Wait(3000)  -- debounce
                    end

                    Wait(sleep)
                until dist > Config.PedTriggerDist or isdead
            end
        end

        Wait(sleep)
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- NET EVENT: Mission Started (activating player only)
-- ═══════════════════════════════════════════════════════════════════════════════

RegisterNetEvent('wagonrobbery:missionStarted')
AddEventHandler('wagonrobbery:missionStarted', function(data)
    dbg('missionStarted received')
    isActivator   = true
    missionPhase  = 'guards'
    totalHostiles = data.totalHostiles

    notify(TEXTS.MissionStarted)

    -- ── Resolve wagon ──────────────────────────────────────────────────────────
    wagonEnt = waitForNetEntity(data.wagonNetId)
    if not wagonEnt then
        print('[WagonRobbery] Client: wagon entity never resolved. netId=' .. tostring(data.wagonNetId))
        return
    end
    dbg('Wagon resolved, handle=' .. wagonEnt)
    addBlip()

    -- ── Resolve driver + issue drive task ─────────────────────────────────────
    if data.driverNetId then
        driverEnt = waitForNetEntity(data.driverNetId)
        if driverEnt and wagonEnt then
            local dest = data.wagonDest
            TaskVehicleDriveToCoordLongrange(
                driverEnt, wagonEnt,
                dest.x, dest.y, dest.z,
                Config.WagonSpeed,
                Config.WagonDriveMode,
                10.0
            )
            dbg('Drive task set on driver.')
        end
    end

    -- ── Resolve gunner + combat AI ────────────────────────────────────────────
    if data.gunnerNetId then
        gunnerEnt = waitForNetEntity(data.gunnerNetId)
        if gunnerEnt then applyNpcAI(gunnerEnt, PlayerPedId()) end
    end

    -- ── Resolve guards + set escort AI ────────────────────────────────────────
    guardEnts = {}; guardHorseEnts = {}
    local myPed  = PlayerPedId()
    local dest   = data.wagonDest

    for i, netId in ipairs(data.guardNetIds) do
        local guard = waitForNetEntity(netId)
        if guard then
            guardEnts[#guardEnts+1] = guard
            applyNpcAI(guard, myPed)

            local horseNId = data.guardHorseNetIds[i]
            if horseNId then
                local horse = waitForNetEntity(horseNId)
                if horse then
                    guardHorseEnts[#guardHorseEnts+1] = horse
                    -- Guard's horse follows the same wagon route
                    TaskVehicleDriveToCoordLongrange(
                        guard, horse,
                        dest.x, dest.y, dest.z,
                        Config.WagonSpeed,
                        Config.WagonDriveMode,
                        10.0
                    )
                end
            end
        end
    end
    dbg(('Guards resolved: %d'):format(#guardEnts))

    -- ── Thread: monitor guard deaths ──────────────────────────────────────────
    -- Pattern: repeat-until, 2 s sleep, mirrors outsider digging_timer
    monitorGuardsAlive = true
    CreateThread(function()
        repeat
            Wait(2000)
            if not monitorGuardsAlive or missionPhase ~= 'guards' then break end

            local dead = countDead(guardEnts)
            if gunnerEnt and DoesEntityExist(gunnerEnt) and IsEntityDead(gunnerEnt) then
                dead = dead + 1
            end
            dbg(('Guards dead: %d/%d'):format(dead, totalHostiles))

            if dead >= totalHostiles then
                monitorGuardsAlive = false
                missionPhase = 'dynamite'
                TriggerServerEvent('wagonrobbery:guardsEliminated')
                notify(TEXTS.AllGuardsDead)
            end
        until not monitorGuardsAlive
    end)

    -- ── Thread: death watch (player dies = fail) ──────────────────────────────
    deathWatchAlive = true
    CreateThread(function()
        repeat
            Wait(1000)
            if not deathWatchAlive or missionPhase == 'idle' then break end
            if IsEntityDead(PlayerPedId()) then
                deathWatchAlive = false
                notify(TEXTS.MissionFailed)
                TriggerServerEvent('wagonrobbery:playerDied')
                fullReset()
            end
        until not deathWatchAlive
    end)

    -- ── Thread: wagon proximity (dynamite prompt + loot prompt) ───────────────
    wagonProxAlive = true
    CreateThread(function()
        local lastPhasePromptBuilt = nil

        while wagonProxAlive and isActivator do
            local sleep  = 1000
            local phase  = missionPhase

            if (phase == 'dynamite' or phase == 'loot') and
               wagonEnt and DoesEntityExist(wagonEnt) then

                local pped  = PlayerPedId()
                local dist  = #(GetEntityCoords(pped) - GetEntityCoords(wagonEnt))

                if dist < Config.WagonTriggerDist then
                    sleep = 0

                    -- Rebuild prompt only if phase changed
                    if lastPhasePromptBuilt ~= phase then
                        deletePrompt(wagonPrompt)
                        local label = (phase == 'dynamite') and TEXTS.PlaceDynamitePrompt or TEXTS.LootPrompt
                        wagonPrompt = makeStandardPrompt(label)
                        lastPhasePromptBuilt = phase
                    end

                    UiPromptSetActiveGroupThisFrame(
                        PromptGroup,
                        VarString(10, 'LITERAL_STRING', Config.Blip.label),
                        0, 0, 0, 0
                    )

                    if UiPromptHasStandardModeCompleted(wagonPrompt, 0) then
                        deletePrompt(wagonPrompt); wagonPrompt = nil
                        lastPhasePromptBuilt = nil

                        if phase == 'dynamite' then
                            -- Gate so we can't fire this twice
                            missionPhase = 'placing_dynamite'

                            -- Run the syn_minigame skill check (same export
                            -- outsider_grave_robbery references)
                            CreateThread(function()
                                local result = exports['syn_minigame']:taskBar(
                                    Config.Minigame.difficulty,
                                    Config.Minigame.skillGap
                                )

                                if result == 100 then
                                    -- Play a short dynamite-place animation
                                    local ped      = PlayerPedId()
                                    local animDict = 'melee@ground@base'
                                    local animClip = 'ground_attack_0'
                                    if loadAnimDict(animDict) then
                                        TaskPlayAnim(ped, animDict, animClip,
                                            1.0, 1.0, 2500, 1, 0, false, false, false)
                                        Wait(2400)
                                        ClearPedTasks(ped)
                                        RemoveAnimDict(animDict)
                                    end
                                    notify(TEXTS.DynamitePlaced)
                                    TriggerServerEvent('wagonrobbery:dynamitePlaced')
                                    -- Phase will be updated to 'fuse' by server event
                                else
                                    -- Minigame failed → revert so they can try again
                                    notify(TEXTS.MinigameFailed)
                                    missionPhase = 'dynamite'
                                end
                            end)

                        elseif phase == 'loot' then
                            missionPhase    = 'rewarding'
                            wagonProxAlive  = false
                            TriggerServerEvent('wagonrobbery:lootComplete')
                            removeBlip()
                        end

                        Wait(2000) -- debounce
                    end

                else
                    -- Left range: destroy stale prompt
                    if lastPhasePromptBuilt then
                        deletePrompt(wagonPrompt); wagonPrompt = nil
                        lastPhasePromptBuilt = nil
                    end
                end
            else
                -- Phase doesn't need this prompt; destroy if leftover
                if lastPhasePromptBuilt then
                    deletePrompt(wagonPrompt); wagonPrompt = nil
                    lastPhasePromptBuilt = nil
                end
            end

            Wait(sleep)
        end

        deletePrompt(wagonPrompt); wagonPrompt = nil
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- NET EVENT: Fuse started (activating player only)
-- ═══════════════════════════════════════════════════════════════════════════════

RegisterNetEvent('wagonrobbery:startFuse')
AddEventHandler('wagonrobbery:startFuse', function()
    dbg('startFuse received')
    missionPhase = 'fuse'
    notify(TEXTS.FuseWarning)

    -- Countdown thread – mirrors outsider's digging_timer pattern
    CreateThread(function()
        local elapsed = 0
        repeat
            Wait(1000)
            elapsed = elapsed + 1000
            if missionPhase ~= 'fuse' then return end
        until elapsed >= Config.DynamiteFuseMs

        if missionPhase == 'fuse' then
            TriggerServerEvent('wagonrobbery:fuseExpired')
        end
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- NET EVENT: Wagon exploded (all clients)
-- ═══════════════════════════════════════════════════════════════════════════════

RegisterNetEvent('wagonrobbery:wagonExploded')
AddEventHandler('wagonrobbery:wagonExploded', function()
    dbg('wagonExploded received')

    if isActivator then
        -- Local VFX at wagon position
        if wagonEnt and DoesEntityExist(wagonEnt) then
            local wc = GetEntityCoords(wagonEnt)
            AddExplosion(wc.x, wc.y, wc.z, 2, 10.0, true, false, 1.0)
        end
        notify(TEXTS.WagonExploded)
        missionPhase = 'reinforcements'
        removeBlip()
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- NET EVENT: Reinforcements spawned (activating player only)
-- ═══════════════════════════════════════════════════════════════════════════════

RegisterNetEvent('wagonrobbery:reinforcementsSpawned')
AddEventHandler('wagonrobbery:reinforcementsSpawned', function(data)
    dbg(('reinforcementsSpawned received, count=%d'):format(#data.reinfNetIds))

    missionPhase = 'reinforcements'
    totalReinf   = #data.reinfNetIds
    reinfEnts    = {}; reinfHorseEnts = {}

    local myPed    = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)

    for i, netId in ipairs(data.reinfNetIds) do
        local r = waitForNetEntity(netId)
        if r then
            reinfEnts[#reinfEnts+1] = r
            applyNpcAI(r, myPed)

            local horseNId = data.reinfHorseNetIds and data.reinfHorseNetIds[i]
            if horseNId then
                local horse = waitForNetEntity(horseNId)
                if horse then
                    reinfHorseEnts[#reinfHorseEnts+1] = horse
                    TaskVehicleDriveToCoordLongrange(
                        r, horse,
                        myCoords.x, myCoords.y, myCoords.z,
                        20.0,
                        Config.WagonDriveMode,
                        5.0
                    )
                end
            end
        end
    end

    dbg(('Reinforcements resolved: %d'):format(#reinfEnts))

    -- Thread: monitor reinf deaths + update target periodically
    -- Mirrors outsider's repeat-until timer pattern
    monitorReinfAlive = true
    local updateAccum = 0

    CreateThread(function()
        repeat
            Wait(2000)
            if not monitorReinfAlive then break end
            updateAccum = updateAccum + 2000

            -- Player death = reinfs "won"
            if IsEntityDead(PlayerPedId()) then
                monitorReinfAlive = false
                TriggerServerEvent('wagonrobbery:reinforcementsWon')
                fullReset()
                break
            end

            local dead = countDead(reinfEnts)
            dbg(('Reinfs dead: %d/%d'):format(dead, totalReinf))

            if dead >= totalReinf then
                monitorReinfAlive = false
                missionPhase = 'loot'
                TriggerServerEvent('wagonrobbery:reinforcementsEliminated')
                notify(TEXTS.ReinfsDead)
                break
            end

            -- Re-issue ride task every Config.ReinfUpdateMs so they track the player
            if updateAccum >= Config.ReinfUpdateMs then
                updateAccum = 0
                local nc = GetEntityCoords(PlayerPedId())
                for idx, r in ipairs(reinfEnts) do
                    if DoesEntityExist(r) and not IsEntityDead(r) then
                        local h = reinfHorseEnts[idx]
                        if h and DoesEntityExist(h) and not IsEntityDead(h) then
                            TaskVehicleDriveToCoordLongrange(
                                r, h,
                                nc.x, nc.y, nc.z,
                                20.0,
                                Config.WagonDriveMode,
                                5.0
                            )
                        end
                    end
                end
            end
        until not monitorReinfAlive
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- NET EVENT: Mission broadcast (ALL clients)
-- Non-activating players receive this so late joiners also get it via
-- wagonrobbery:requestSync on session entry.
-- ═══════════════════════════════════════════════════════════════════════════════

RegisterNetEvent('wagonrobbery:missionBroadcast')
AddEventHandler('wagonrobbery:missionBroadcast', function(data)
    if isActivator then return end
    -- Non-activators: nothing to do client-side except optionally show a
    -- world notification. They can still shoot guards and reinfs normally.
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- NET EVENT: Mission failed
-- ═══════════════════════════════════════════════════════════════════════════════

RegisterNetEvent('wagonrobbery:missionFailed')
AddEventHandler('wagonrobbery:missionFailed', function()
    notify(TEXTS.MissionFailed)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- NET EVENT: Cleanup (all clients)
-- ═══════════════════════════════════════════════════════════════════════════════

RegisterNetEvent('wagonrobbery:cleanup')
AddEventHandler('wagonrobbery:cleanup', function()
    dbg('cleanup received')
    fullReset()
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Session join: request current mission state (late joiners)
-- ═══════════════════════════════════════════════════════════════════════════════

CreateThread(function()
    repeat Wait(5000) until LocalPlayer.state.IsInSession
    TriggerServerEvent('wagonrobbery:requestSync')
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Resource stop – clean up everything we own client-side
-- Mirrors outsider_grave_robbery's onResourceStop handler
-- ═══════════════════════════════════════════════════════════════════════════════

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if starterPedEnt and DoesEntityExist(starterPedEnt) then
        DeleteEntity(starterPedEnt)
        starterPedEnt = nil
    end

    deletePrompt(starterPrompt); starterPrompt = nil
    deletePrompt(wagonPrompt);   wagonPrompt   = nil
    removeBlip()
    fullReset()
end)
