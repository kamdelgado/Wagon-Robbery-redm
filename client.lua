-- ================================================================
--  STAGECOACH ROBBERY  |  client.lua
--  VORP Core 2025/2026  |  Lua 5.4
-- ================================================================
--  Verified against:
--    docs.vorp-core.com (2026)
--    iboss21/lxr-bounty-quests (multi-framework reference, 2026)
--
--  All tuneable values live in config.lua.
--  Do not hardcode magic numbers here — add to config.lua instead.
-- ================================================================

local VORPcore = exports.vorp_core:GetCore()

-- ── State ────────────────────────────────────────────────────────
local PlayerLoaded    = false
local isMissionActive = false
local isCleaningUp    = false
local entities        = {}
local guards          = {}
local wagonBlip       = nil
local fenceBlip       = nil
local missionWagon    = nil

-- ────────────────────────────────────────────────────────────────
--  vorp:SelectedCharacter
--  Wait for character selection before activating NPC or prompts.
-- ────────────────────────────────────────────────────────────────
RegisterNetEvent('vorp:SelectedCharacter')
AddEventHandler('vorp:SelectedCharacter', function()
    PlayerLoaded = true
end)

-- ────────────────────────────────────────────────────────────────
--  HELPER  Notify
-- ────────────────────────────────────────────────────────────────
local function Notify(msg, duration)
    VORPcore.NotifyTip(msg, duration or 5000)
end

-- ────────────────────────────────────────────────────────────────
--  HELPER  NotifyEntry
--  Accepts a Config.notify.* table {msg, dur} directly.
-- ────────────────────────────────────────────────────────────────
local function NotifyEntry(entry)
    if entry then Notify(entry.msg, entry.dur) end
end

-- ────────────────────────────────────────────────────────────────
--  HELPER  RequestModelSync
--  Blocks until a model hash is fully streamed in.
-- ────────────────────────────────────────────────────────────────
local function RequestModelSync(model)
    RequestModel(model)
    while not HasModelLoaded(model) do
        Wait(100)
    end
end

-- ────────────────────────────────────────────────────────────────
--  HELPER  SafeRPC
--  Wraps RPC.execute in pcall — prevents a crash on server timeout.
--  Returns: ok (bool), result (value or nil)
-- ────────────────────────────────────────────────────────────────
local function SafeRPC(name, ...)
    local ok, result = pcall(RPC.execute, name, ...)
    if not ok then
        print("[robbery] RPC failed for " .. name .. ": " .. tostring(result))
        return false, nil
    end
    return true, result
end

-- ════════════════════════════════════════════════════════════════
--  INTERACTION THREAD
--  Adaptive sleep: 1000ms far from NPC, 0ms within active range.
-- ════════════════════════════════════════════════════════════════
Citizen.CreateThread(function()
    while not PlayerLoaded do Wait(1000) end

    local npcHash = GetHashKey(Config.starterNpcModel)
    RequestModelSync(npcHash)

    local starterPed = CreatePed(
        npcHash,
        Config.npcPos.x, Config.npcPos.y, Config.npcPos.z - 1.0,
        Config.starterNpcHeading, false, false
    )
    Citizen.InvokeNative(0x283978A15512B2FE, starterPed, true)  -- NetworkSetEntityIsNetworked
    SetEntityCanBeDamaged(starterPed, false)
    SetEntityInvincible(starterPed, true)
    FreezeEntityPosition(starterPed, true)
    SetBlockingOfNonTemporaryEvents(starterPed, true)
    SetModelAsNoLongerNeeded(npcHash)

    -- Prompts registered ONCE outside the loop
    local startPrompt = PromptRegisterBegin()
    PromptSetControlAction(startPrompt, 0xCEFD9220)
    PromptSetText(startPrompt, CreateVarString(10, "LITERAL_STRING", Config.promptTextStart))
    PromptSetHoldMode(startPrompt, true)
    PromptRegisterEnd(startPrompt)

    local fencePrompt = PromptRegisterBegin()
    PromptSetControlAction(fencePrompt, 0xCEFD9220)
    PromptSetText(fencePrompt, CreateVarString(10, "LITERAL_STRING", Config.promptTextFence))
    PromptSetHoldMode(fencePrompt, true)
    PromptRegisterEnd(fencePrompt)

    local hasLoot       = false
    local lastLootCheck = 0

    while true do
        local sleep     = 1000
        local playerPed = PlayerPedId()
        local dist      = #(GetEntityCoords(playerPed) - Config.npcPos)

        if dist < Config.npcActiveRange then
            sleep = 0

            if dist < Config.npcInteractRange then
                local now = GetGameTimer()
                if now - lastLootCheck > Config.lootPollMs then
                    lastLootCheck = now
                    local ok, result = SafeRPC('robbery:hasLockbox')
                    hasLoot = ok and result or false
                end

                if hasLoot then
                    PromptSetActiveGroupThisFrame(fencePrompt, CreateVarString(10, "LITERAL_STRING", Config.promptGroupFence))
                    if PromptHasHoldModeCompleted(fencePrompt) then
                        if fenceBlip then RemoveBlip(fenceBlip) fenceBlip = nil end
                        TriggerServerEvent('robbery:fenceLoot')
                        hasLoot = false
                        Wait(1500)
                    end

                elseif not isMissionActive then
                    PromptSetActiveGroupThisFrame(startPrompt, CreateVarString(10, "LITERAL_STRING", Config.promptGroupRobbery))
                    if PromptHasHoldModeCompleted(startPrompt) then
                        local ok, res = SafeRPC('robbery:tryStart')
                        if ok and res and res.success then
                            StartMission()
                        else
                            Notify(
                                (res and res.msg) or Config.notify.genericError.msg,
                                Config.notify.genericError.dur
                            )
                        end
                    end
                end
            end
        else
            hasLoot       = false
            lastLootCheck = 0
        end

        Wait(sleep)
    end
end)

-- ════════════════════════════════════════════════════════════════
--  StartMission
-- ════════════════════════════════════════════════════════════════
function StartMission()
    isMissionActive = true
    isCleaningUp    = false
    guards          = {}
    entities        = {}

    NotifyEntry(Config.notify.missionStart)

    -- ── Armored Wagon ─────────────────────────────────────────
    local wModel = GetHashKey(Config.wagonModel)
    RequestModelSync(wModel)

    missionWagon = CreateVehicle(
        wModel,
        Config.spawnPos.x, Config.spawnPos.y, Config.spawnPos.z,
        Config.wagonHeading, true, false
    )
    SetEntityAsMissionEntity(missionWagon, true, true)
    table.insert(entities, missionWagon)
    SetModelAsNoLongerNeeded(wModel)

    -- ── Driver + Shooter ──────────────────────────────────────
    local wCoords = GetEntityCoords(missionWagon)
    local driver  = CreateMissionNPC(missionWagon, -1, wCoords)
    local shooter = CreateMissionNPC(missionWagon,  0, wCoords)

    -- ── Mounted Escort Guards ─────────────────────────────────
    local horseHash = GetHashKey(Config.horseModel)
    RequestModelSync(horseHash)

    for i = 1, Config.escortCount do
        local offset  = vector3(
            (i * Config.escortSpreadStep) + Config.escortSpreadOffset,
            Config.escortYOffset,
            0.0
        )
        local hCoords = Config.spawnPos + offset

        local horse = CreateVehicle(horseHash, hCoords.x, hCoords.y, hCoords.z, Config.wagonHeading, true, false)
        SetEntityAsMissionEntity(horse, true, true)

        local guard = CreateMissionNPC(nil, nil, GetEntityCoords(horse))
        SetPedIntoVehicle(guard, horse, -1)
        TaskCombatPed(guard, PlayerPedId(), 0, 16)

        table.insert(entities, horse)
        table.insert(guards,   guard)
    end
    SetModelAsNoLongerNeeded(horseHash)

    -- ── Wagon AI Route ────────────────────────────────────────
    TaskVehicleDriveToCoord(
        driver, missionWagon,
        Config.loftPos.x, Config.loftPos.y, Config.loftPos.z,
        Config.wagonSpeedNormal, 0, 0, Config.drivingStyle, 5.0, true
    )

    -- ── Wagon Blip ────────────────────────────────────────────
    -- 0x23F74C1382440316 = BlipAddForEntity
    wagonBlip = Citizen.InvokeNative(0x23F74C1382440316, GetHashKey("BLIP_STYLE_ENEMY"), missionWagon)

    -- ════════════════════════════════════════════════════════
    --  MAIN MISSION LOOP
    -- ════════════════════════════════════════════════════════
    Citizen.CreateThread(function()
        local startTime         = GetGameTimer()
        local spedUp            = false
        local reinforced        = false
        local boomPrompt        = nil
        local boomPromptCreated = false

        while isMissionActive do
            Wait(Config.missionLoopMs)

            if not DoesEntityExist(missionWagon) then
                CleanupMission(Config.notify.failUnexpected, 0)
                break
            end

            local wagonCoords = GetEntityCoords(missionWagon)
            local playerPed   = PlayerPedId()
            local elapsed     = GetGameTimer() - startTime

            -- ── TIMEOUT ──────────────────────────────────────
            if elapsed > Config.missionTimeout then
                if boomPrompt then PromptDelete(boomPrompt) boomPrompt = nil end
                CleanupMission(Config.notify.failTimeout, 0)
                break
            end

            -- ── REINFORCEMENTS ────────────────────────────────
            if not reinforced then
                local dead = 0
                for _, g in ipairs(guards) do
                    if IsEntityDead(g) then dead = dead + 1 end
                end
                if #guards > 0 and dead >= #guards then
                    reinforced = true
                    SpawnReinforcements()
                end
            end

            -- ── WAGON SPEEDS UP on damage ─────────────────────
            if not spedUp and HasEntityBeenDamagedByAnyPed(missionWagon) then
                spedUp = true
                TaskVehicleDriveToCoord(
                    driver, missionWagon,
                    Config.loftPos.x, Config.loftPos.y, Config.loftPos.z,
                    Config.wagonSpeedAlarmed, 0, 0, Config.drivingStyle, 5.0, true
                )
            end

            -- ── FAIL: wagon reached destination ───────────────
            if #(wagonCoords - Config.loftPos) < Config.wagonDestProximity then
                if boomPrompt then PromptDelete(boomPrompt) boomPrompt = nil end
                CleanupMission(Config.notify.failWagonEscaped, 0)
                break
            end

            -- ── FAIL: player died ─────────────────────────────
            if IsEntityDead(playerPed) then
                if boomPrompt then PromptDelete(boomPrompt) boomPrompt = nil end
                CleanupMission(Config.notify.failPlayerDied, 0)
                break
            end

            -- ── SUCCESS: driver + shooter neutralised ─────────
            -- DoesEntityExist as secondary — avoids false-positive
            -- from driver dismounting (seat-empty check would fire
            -- even when driver is alive but on foot).
            local driverDead  = IsEntityDead(driver)  or not DoesEntityExist(driver)
            local shooterDead = IsEntityDead(shooter) or not DoesEntityExist(shooter)

            if driverDead and shooterDead then
                local backDoor = GetOffsetFromEntityInWorldCoords(
                    missionWagon,
                    Config.wagonDoorOffset.x,
                    Config.wagonDoorOffset.y,
                    Config.wagonDoorOffset.z
                )
                local nearDoor = #(GetEntityCoords(playerPed) - backDoor) < Config.doorProximity

                -- Register prompt exactly ONCE — not every tick
                if nearDoor and not boomPromptCreated then
                    boomPromptCreated = true
                    boomPrompt = PromptRegisterBegin()
                    PromptSetControlAction(boomPrompt, 0xCEFD9220)
                    PromptSetText(boomPrompt, CreateVarString(10, "LITERAL_STRING", Config.promptTextDynamite))
                    PromptSetHoldMode(boomPrompt, true)
                    PromptRegisterEnd(boomPrompt)
                end

                if nearDoor and boomPrompt then
                    PromptSetActiveGroupThisFrame(boomPrompt, CreateVarString(10, "LITERAL_STRING", Config.promptGroupWagon))

                    if PromptHasHoldModeCompleted(boomPrompt) then
                        local ok, hasDynamite = SafeRPC('robbery:checkDynamite')
                        if ok and hasDynamite then
                            PromptDelete(boomPrompt)
                            boomPrompt = nil

                            -- Set false BEFORE PlantAndExplode so the loop
                            -- exits cleanly during the Wait() sequence inside it
                            isMissionActive = false

                            PlantAndExplode(backDoor)

                            -- Fence blip AFTER CleanupMission — CleanupMission
                            -- removes all blips, so creating before = invisible
                            CleanupMission(Config.notify.lockboxCleanup, 0)

                            if fenceBlip then RemoveBlip(fenceBlip) fenceBlip = nil end
                            -- 0x554D9D10F6928432 = BlipAddForCoords
                            fenceBlip = Citizen.InvokeNative(
                                0x554D9D10F6928432,
                                GetHashKey("BLIP_STYLE_FRIENDLY"),
                                Config.npcPos.x, Config.npcPos.y, Config.npcPos.z
                            )
                            break
                        else
                            NotifyEntry(Config.notify.noDynamite)
                        end
                    end
                end
            end
        end

        if boomPrompt then PromptDelete(boomPrompt) end
    end)
end

-- ════════════════════════════════════════════════════════════════
--  SpawnReinforcements
-- ════════════════════════════════════════════════════════════════
function SpawnReinforcements()
    NotifyEntry(Config.notify.reinforcements)

    local horseHash = GetHashKey(Config.horseModel)
    RequestModelSync(horseHash)

    for i = 1, Config.reinforcementCount do
        local side  = (i % 2 == 0) and Config.reinforcementLateral or -Config.reinforcementLateral
        local spawn = GetOffsetFromEntityInWorldCoords(
            PlayerPedId(),
            side,
            Config.reinforcementBase + (i * Config.reinforcementStep),
            0.0
        )

        local horse = CreateVehicle(horseHash, spawn.x, spawn.y, spawn.z, 0.0, true, false)
        SetEntityAsMissionEntity(horse, true, true)

        local guard = CreateMissionNPC(nil, nil, spawn)
        SetPedIntoVehicle(guard, horse, -1)
        TaskCombatPed(guard, PlayerPedId(), 0, 16)

        table.insert(entities, horse)
        table.insert(entities, guard)
        table.insert(guards,   guard)
    end

    SetModelAsNoLongerNeeded(horseHash)
end

-- ════════════════════════════════════════════════════════════════
--  PlantAndExplode
--  TaskStartScenarioInPlace takes a RAW STRING — not a hash int.
-- ════════════════════════════════════════════════════════════════
function PlantAndExplode(coords)
    TriggerServerEvent('robbery:consumeDynamite')

    TaskStartScenarioInPlace(PlayerPedId(), "WORLD_HUMAN_CROUCH_INSPECT", Config.plantAnimMs, true)
    Wait(Config.plantAnimMs)
    ClearPedTasks(PlayerPedId())

    Wait(Config.fuseBurnMs)

    AddExplosion(
        coords.x,
        coords.y,
        coords.z + Config.explosionHeightOffset,
        Config.explosionType,
        Config.explosionScale,
        true, false,
        Config.explosionCamShake
    )

    Wait(Config.postExplosionMs)
    TriggerServerEvent('robbery:giveLockbox')
    NotifyEntry(Config.notify.lockboxSecured)
end

-- ════════════════════════════════════════════════════════════════
--  CreateMissionNPC
--  Spawns at real coords — never at 0,0,0.
--  SetEntityAsMissionEntity prevents engine auto-despawn.
-- ════════════════════════════════════════════════════════════════
function CreateMissionNPC(veh, seat, coords)
    local pHash = GetHashKey(Config.guardModel)
    RequestModelSync(pHash)

    local pos = coords or Config.spawnPos
    local npc = CreatePed(pHash, pos.x, pos.y, pos.z, 0.0, true, false)
    SetEntityAsMissionEntity(npc, true, true)

    if veh ~= nil and seat ~= nil then
        SetPedIntoVehicle(npc, veh, seat)
    end

    GiveWeaponToPed_2(npc, GetHashKey(Config.guardWeapon), Config.guardAmmo, true, true, 0, false, 0.0, 0.0, 0, true, 0, false)
    SetPedCombatAttributes(npc, 1, true)
    SetPedCombatAttributes(npc, 2, true)
    SetPedCombatAbility(npc, 2)
    SetPedAccuracy(npc, Config.guardAccuracy)

    table.insert(entities, npc)
    SetModelAsNoLongerNeeded(pHash)
    return npc
end

-- ════════════════════════════════════════════════════════════════
--  CleanupMission
--  notifyEntry — a Config.notify.* table {msg, dur}, or nil.
--  delay       — Wait() ms before entity deletion.
--  fromServer  — suppresses endMissionServer echo on forceCleanup.
-- ════════════════════════════════════════════════════════════════
function CleanupMission(notifyEntry, delay, fromServer)
    if isCleaningUp then return end
    isCleaningUp = true

    NotifyEntry(notifyEntry)

    if wagonBlip then RemoveBlip(wagonBlip) wagonBlip = nil end
    if fenceBlip  then RemoveBlip(fenceBlip)  fenceBlip  = nil end

    Wait(delay or 0)

    for _, ent in ipairs(entities) do
        if DoesEntityExist(ent) then NetworkRequestControlOfEntity(ent) end
    end
    Wait(200)
    for _, ent in ipairs(entities) do
        if DoesEntityExist(ent) then DeleteEntity(ent) end
    end

    entities        = {}
    guards          = {}
    isMissionActive = false
    isCleaningUp    = false
    missionWagon    = nil

    if not fromServer then
        TriggerServerEvent('robbery:endMissionServer')
    end
end

-- ════════════════════════════════════════════════════════════════
--  robbery:forceCleanup
--  Server → client (playerDropped).
-- ════════════════════════════════════════════════════════════════
RegisterNetEvent('robbery:forceCleanup')
AddEventHandler('robbery:forceCleanup', function()
    CleanupMission(nil, 0, true)
end)
