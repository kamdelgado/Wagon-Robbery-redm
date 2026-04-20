-- ================================================================
--  STAGECOACH ROBBERY  |  client.lua
--  VORP Core 2025/2026  |  Lua 5.4
-- ================================================================
--  Verified against:
--    docs.vorp-core.com (2026)
--    iboss21/lxr-bounty-quests (multi-framework reference, 2026)
--
--  Improvements adopted from lxr-bounty-quests:
--    ✔ PlayerLoaded guard via vorp:SelectedCharacter — NPC and
--      prompts now wait for character selection before activating
--    ✔ Adaptive sleep in interaction thread (1000ms default → 0ms
--      when near NPC) — replaces blanket Wait(0) every frame
--    ✔ SetEntityCanBeDamaged(ped, false) on starter NPC
--    ✔ Wait(100) in model load loops (industry standard vs Wait(10))
--    ✔ Network entity flag on spawned NPCs
--
--  Fixes carried from all previous passes:
--    ✔ GetCore() — current VORP API
--    ✔ VORPcore.NotifyTip() — current notify API
--    ✔ RPC throttled to 1 call/2s — no server hammering
--    ✔ Driver/shooter spawn at wagon coords — never at 0,0,0
--    ✔ SetEntityAsMissionEntity on all spawned entities
--    ✔ RequestModelSync before every CreateVehicle/CreatePed
--    ✔ RequestModelSync in SpawnReinforcements (was missing)
--    ✔ TaskStartScenarioInPlace raw string — not GetHashKey int
--    ✔ boomPrompt registered exactly once via boomPromptCreated
--    ✔ isMissionActive=false before PlantAndExplode Wait()s
--    ✔ isCleaningUp guard — no re-entrant CleanupMission calls
--    ✔ fromServer flag — no echo back on forceCleanup path
--    ✔ DoesEntityExist check on wagon each loop tick
--    ✔ Batched entity delete — single Wait(200) for all control
--    ✔ Blip handles nilled after every RemoveBlip
--    ✔ guards = {} reset in CleanupMission
--    ✔ Fence blip created AFTER CleanupMission — was invisible
--    ✔ Reinforcement guards staggered left/right
--    ✔ missionWagon nilled in CleanupMission — no stale handles
--    ✔ Escort guards use TaskCombatPed(player) not TaskVehicleChase(driver)
--    ✔ Driver dead check uses IsEntityDead + DoesEntityExist — no dismount false-positive
--    ✔ AddExplosion uses type 0 — type 1 is GTA5 enum, invalid in RedM
--    ✔ RPC.execute wrapped in pcall — prevents crash on server timeout
--    ✔ Native hashes commented with their function names
-- ================================================================

local VORPcore = exports.vorp_core:GetCore()

-- ── State ────────────────────────────────────────────────────────
local PlayerLoaded    = false   -- set true on vorp:SelectedCharacter
local isMissionActive = false
local isCleaningUp    = false   -- re-entrancy guard for CleanupMission
local entities        = {}      -- every spawned entity for batch cleanup
local guards          = {}      -- escort peds tracked separately
local wagonBlip       = nil
local fenceBlip       = nil
local missionWagon    = nil

-- ── Config ───────────────────────────────────────────────────────
local Config = {
    npcPos         = vector3(1433.2, 1332.1, 182.4),  -- Starter / Fence NPC
    spawnPos       = vector3(1106.3, 1378.5, 178.5),  -- Wagon spawn
    loftPos        = vector3(1131.2, 2372.9, 258.0),  -- Wagon destination (fail if reached)
    missionTimeout = 15 * 60 * 1000,                  -- 15 minutes in ms
}
-- ─────────────────────────────────────────────────────────────────

-- ────────────────────────────────────────────────────────────────
--  vorp:SelectedCharacter
--  Pattern from lxr-bounty-quests: wait for character selection
--  before activating any NPC or prompt logic.
--  Without this, the thread starts before the character is loaded
--  which can cause inventory/identity RPC calls to fail silently.
-- ────────────────────────────────────────────────────────────────
RegisterNetEvent('vorp:SelectedCharacter')
AddEventHandler('vorp:SelectedCharacter', function()
    PlayerLoaded = true
end)

-- ────────────────────────────────────────────────────────────────
--  HELPER  Notify
--  Single wrapper — swap one line here to change notify system.
-- ────────────────────────────────────────────────────────────────
local function Notify(msg, duration)
    VORPcore.NotifyTip(msg, duration or 5000)
end

-- ────────────────────────────────────────────────────────────────
--  HELPER  RequestModelSync
--  Blocks until a model hash is fully streamed in.
--  Uses Wait(100) — industry standard from lxr-bounty-quests
--  (Wait(10) is unnecessarily tight for model streaming).
-- ────────────────────────────────────────────────────────────────
local function RequestModelSync(model)
    RequestModel(model)
    while not HasModelLoaded(model) do
        Wait(100)
    end
end

-- ────────────────────────────────────────────────────────────────
--  HELPER  SafeRPC
--  Wraps RPC.execute in a pcall to prevent a client crash if the
--  server is unavailable or the call times out.
--  Returns: success (bool), result (value or nil)
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
--  Waits for PlayerLoaded before doing anything.
--  Adaptive sleep from lxr-bounty-quests:
--    - Default sleep = 1000ms (barely any CPU when far away)
--    - Drops to 0ms only when player is within 50 units of NPC
--  Previous version used Wait(0) always = full 60fps burn
--  even when the player was on the other side of the map.
-- ════════════════════════════════════════════════════════════════
Citizen.CreateThread(function()
    -- Wait for character to be fully loaded before spawning anything
    while not PlayerLoaded do Wait(1000) end

    local npcHash = GetHashKey("u_m_m_valcrimereader_01")
    RequestModelSync(npcHash)

    local starterPed = CreatePed(
        npcHash,
        Config.npcPos.x, Config.npcPos.y, Config.npcPos.z - 1.0,
        180.0, false, false
    )
    -- Full NPC lockdown — pattern from lxr-bounty-quests
    Citizen.InvokeNative(0x283978A15512B2FE, starterPed, true)  -- NetworkSetEntityIsNetworked
    SetEntityCanBeDamaged(starterPed, false)
    SetEntityInvincible(starterPed, true)
    FreezeEntityPosition(starterPed, true)
    SetBlockingOfNonTemporaryEvents(starterPed, true)
    SetModelAsNoLongerNeeded(npcHash)

    -- Prompts registered ONCE outside the loop
    local startPrompt = PromptRegisterBegin()
    PromptSetControlAction(startPrompt, 0xCEFD9220)   -- E key
    PromptSetText(startPrompt, CreateVarString(10, "LITERAL_STRING", "Start Stagecoach Robbery"))
    PromptSetHoldMode(startPrompt, true)
    PromptRegisterEnd(startPrompt)

    local fencePrompt = PromptRegisterBegin()
    PromptSetControlAction(fencePrompt, 0xCEFD9220)   -- E key
    PromptSetText(fencePrompt, CreateVarString(10, "LITERAL_STRING", "Sell Stolen Goods"))
    PromptSetHoldMode(fencePrompt, true)
    PromptRegisterEnd(fencePrompt)

    -- RPC throttle state
    local hasLoot       = false
    local lastLootCheck = 0
    local LOOT_POLL_MS  = 2000

    while true do
        -- Adaptive sleep: 1000ms default, 0ms when near NPC
        -- Pattern directly from lxr-bounty-quests main thread
        local sleep      = 1000
        local playerPed  = PlayerPedId()
        local dist       = #(GetEntityCoords(playerPed) - Config.npcPos)

        if dist < 50.0 then
            sleep = 0   -- full resolution within interaction range

            if dist < 3.0 then
                local now = GetGameTimer()
                if now - lastLootCheck > LOOT_POLL_MS then
                    lastLootCheck = now
                    -- FIX: SafeRPC wrapper — prevents crash if server times out
                    local ok, result = SafeRPC('robbery:hasLockbox')
                    hasLoot = ok and result or false
                end

                if hasLoot then
                    PromptSetActiveGroupThisFrame(fencePrompt, CreateVarString(10, "LITERAL_STRING", "Fence"))
                    if PromptHasHoldModeCompleted(fencePrompt) then
                        if fenceBlip then RemoveBlip(fenceBlip) fenceBlip = nil end
                        TriggerServerEvent('robbery:fenceLoot')
                        hasLoot = false
                        Wait(1500)
                    end

                elseif not isMissionActive then
                    PromptSetActiveGroupThisFrame(startPrompt, CreateVarString(10, "LITERAL_STRING", "Robbery"))
                    if PromptHasHoldModeCompleted(startPrompt) then
                        -- FIX: SafeRPC wrapper — prevents crash if server times out
                        local ok, res = SafeRPC('robbery:tryStart')
                        if ok and res and res.success then
                            StartMission()
                        else
                            Notify((res and res.msg) or "Something went wrong.", 5000)
                        end
                    end
                end
            end
        else
            -- Reset cached state when far from NPC
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

    Notify("Go stop the armored stagecoach!", 8000)

    -- ── Armored Wagon ─────────────────────────────────────────
    local wModel = GetHashKey("wagonarmoured01x")
    RequestModelSync(wModel)

    missionWagon = CreateVehicle(
        wModel,
        Config.spawnPos.x, Config.spawnPos.y, Config.spawnPos.z,
        90.0, true, false
    )
    SetEntityAsMissionEntity(missionWagon, true, true)
    table.insert(entities, missionWagon)
    SetModelAsNoLongerNeeded(wModel)

    -- ── Driver + Shooter ──────────────────────────────────────
    local wCoords = GetEntityCoords(missionWagon)
    local driver  = CreateMissionNPC(missionWagon, -1, wCoords)
    local shooter = CreateMissionNPC(missionWagon,  0, wCoords)

    -- ── 5 Mounted Escort Guards ───────────────────────────────
    local horseHash = GetHashKey("a_c_horse_turkoman_gold")
    RequestModelSync(horseHash)   -- once before loop

    for i = 1, 5 do
        local offset  = vector3((i * 4) - 10, -8.0, 0.0)
        local hCoords = Config.spawnPos + offset

        local horse = CreateVehicle(horseHash, hCoords.x, hCoords.y, hCoords.z, 90.0, true, false)
        SetEntityAsMissionEntity(horse, true, true)

        local guard = CreateMissionNPC(nil, nil, GetEntityCoords(horse))
        SetPedIntoVehicle(guard, horse, -1)

        -- FIX: was TaskVehicleChase(guard, driver) — driver is inside the wagon so
        -- guards would just shadow the wagon and never engage the player.
        -- TaskCombatPed targets the player directly, matching reinforcement behaviour.
        TaskCombatPed(guard, PlayerPedId(), 0, 16)

        table.insert(entities, horse)
        table.insert(guards,   guard)
    end
    SetModelAsNoLongerNeeded(horseHash)

    -- ── Wagon AI Route ────────────────────────────────────────
    TaskVehicleDriveToCoord(
        driver, missionWagon,
        Config.loftPos.x, Config.loftPos.y, Config.loftPos.z,
        5.0, 0, 0, 786603, 5.0, true
    )

    -- ── Wagon Blip (red enemy, entity-attached) ───────────────
    -- 0x23F74C1382440316 = BlipAddForEntity
    wagonBlip = Citizen.InvokeNative(0x23F74C1382440316, GetHashKey("BLIP_STYLE_ENEMY"), missionWagon)

    -- ════════════════════════════════════════════════════════
    --  MAIN MISSION LOOP — 500ms tick
    -- ════════════════════════════════════════════════════════
    Citizen.CreateThread(function()
        local startTime         = GetGameTimer()
        local spedUp            = false
        local reinforced        = false
        local boomPrompt        = nil
        local boomPromptCreated = false

        while isMissionActive do
            Wait(500)

            -- Guard: wagon deleted by external script
            if not DoesEntityExist(missionWagon) then
                CleanupMission("Mission ended unexpectedly.", 0)
                break
            end

            local wagonCoords = GetEntityCoords(missionWagon)
            local playerPed   = PlayerPedId()
            local elapsed     = GetGameTimer() - startTime

            -- ── TIMEOUT ──────────────────────────────────────
            if elapsed > Config.missionTimeout then
                if boomPrompt then PromptDelete(boomPrompt) boomPrompt = nil end
                CleanupMission("Mission timed out.", 0)
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
                    12.0, 0, 0, 786603, 5.0, true
                )
            end

            -- ── FAIL: wagon reached destination ───────────────
            if #(wagonCoords - Config.loftPos) < 20.0 then
                if boomPrompt then PromptDelete(boomPrompt) boomPrompt = nil end
                CleanupMission("Failed: The wagon reached safety!", 0)
                break
            end

            -- ── FAIL: player died ──────────────────────────────
            if IsEntityDead(playerPed) then
                if boomPrompt then PromptDelete(boomPrompt) boomPrompt = nil end
                CleanupMission("Failed: You died.", 0)
                break
            end

            -- ── SUCCESS: driver + shooter dead ────────────────
            -- FIX: old fallback was GetPedInVehicleSeat == 0 which also fires
            -- when the driver dismounts voluntarily (not dead), causing a false-
            -- positive success. Replace with DoesEntityExist as the secondary
            -- check — a deleted/removed ped always means they are neutralised.
            local driverDead  = IsEntityDead(driver)  or not DoesEntityExist(driver)
            local shooterDead = IsEntityDead(shooter) or not DoesEntityExist(shooter)

            if driverDead and shooterDead then
                local backDoor = GetOffsetFromEntityInWorldCoords(missionWagon, 0.0, -3.5, 0.0)
                local nearDoor = #(GetEntityCoords(playerPed) - backDoor) < 3.0

                -- Register prompt exactly ONCE (not every tick — was a prompt leak)
                if nearDoor and not boomPromptCreated then
                    boomPromptCreated = true
                    boomPrompt = PromptRegisterBegin()
                    PromptSetControlAction(boomPrompt, 0xCEFD9220)
                    PromptSetText(boomPrompt, CreateVarString(10, "LITERAL_STRING", "Plant Dynamite"))
                    PromptSetHoldMode(boomPrompt, true)
                    PromptRegisterEnd(boomPrompt)
                end

                if nearDoor and boomPrompt then
                    PromptSetActiveGroupThisFrame(boomPrompt, CreateVarString(10, "LITERAL_STRING", "Armored Wagon"))

                    if PromptHasHoldModeCompleted(boomPrompt) then
                        -- FIX: SafeRPC wrapper — prevents crash if server times out
                        local ok, hasDynamite = SafeRPC('robbery:checkDynamite')
                        if ok and hasDynamite then
                            PromptDelete(boomPrompt)
                            boomPrompt = nil

                            -- Set false BEFORE PlantAndExplode so the loop
                            -- exits cleanly during the 8s Wait() sequence
                            isMissionActive = false

                            PlantAndExplode(backDoor)

                            -- CRITICAL: fence blip AFTER CleanupMission —
                            -- CleanupMission removes all blips, so blip must
                            -- be created after, or it's immediately destroyed
                            CleanupMission("Lockbox secured! Return to the fence.", 0)

                            if fenceBlip then RemoveBlip(fenceBlip) fenceBlip = nil end
                            -- 0x554D9D10F6928432 = BlipAddForCoords
                            fenceBlip = Citizen.InvokeNative(
                                0x554D9D10F6928432,
                                GetHashKey("BLIP_STYLE_FRIENDLY"),
                                Config.npcPos.x, Config.npcPos.y, Config.npcPos.z
                            )
                            break
                        else
                            Notify("You need Dynamite!", 4000)
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
--  RequestModelSync present (was missing in early versions).
--  Guards staggered left/right — not single column.
-- ════════════════════════════════════════════════════════════════
function SpawnReinforcements()
    Notify("Lawmen reinforcements incoming!", 5000)

    local horseHash = GetHashKey("a_c_horse_turkoman_gold")
    RequestModelSync(horseHash)

    for i = 1, 3 do
        local side  = (i % 2 == 0) and 10.0 or -10.0
        local spawn = GetOffsetFromEntityInWorldCoords(PlayerPedId(), side, -80.0 - (i * 15), 0.0)

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
--  Using GetHashKey() here caused the animation to silently fail.
--
--  FIX: AddExplosion type changed from 1 to 0.
--  Type 1 is the GTA5 grenade enum (EXP_TAG_GRENADE) and is not
--  valid in RedM — it either does nothing or behaves incorrectly.
--  Type 0 is the default/generic explosion in RDR2.
-- ════════════════════════════════════════════════════════════════
function PlantAndExplode(coords)
    TriggerServerEvent('robbery:consumeDynamite')

    TaskStartScenarioInPlace(PlayerPedId(), "WORLD_HUMAN_CROUCH_INSPECT", 4000, true)
    Wait(4000)
    ClearPedTasks(PlayerPedId())

    Wait(3500)   -- fuse burn

    -- FIX: was type 1 (GTA5 grenade enum) — use 0 for default RDR2 explosion
    AddExplosion(coords.x, coords.y, coords.z + 0.5, 0, 1.5, true, false, 1.8)

    Wait(500)    -- settle before granting lockbox
    TriggerServerEvent('robbery:giveLockbox')
    Notify("Lockbox secured! Head to the fence.", 6000)
end

-- ════════════════════════════════════════════════════════════════
--  CreateMissionNPC
--  Spawns at real coords — never at 0,0,0.
--  Full NPC lockdown matching lxr-bounty-quests pattern.
--  SetEntityAsMissionEntity prevents engine auto-despawn.
-- ════════════════════════════════════════════════════════════════
function CreateMissionNPC(veh, seat, coords)
    local pHash = GetHashKey("s_m_m_pinkerton_01")
    RequestModelSync(pHash)

    local pos = coords or Config.spawnPos
    local npc = CreatePed(pHash, pos.x, pos.y, pos.z, 0.0, true, false)
    SetEntityAsMissionEntity(npc, true, true)

    if veh ~= nil and seat ~= nil then
        SetPedIntoVehicle(npc, veh, seat)
    end

    GiveWeaponToPed_2(npc, GetHashKey("WEAPON_RIFLE_CARCANO"), 999, true, true, 0, false, 0.0, 0.0, 0, true, 0, false)
    SetPedCombatAttributes(npc, 1, true)   -- use cover
    SetPedCombatAttributes(npc, 2, true)   -- always fight
    SetPedCombatAbility(npc, 2)            -- professional
    SetPedAccuracy(npc, 65)

    table.insert(entities, npc)
    SetModelAsNoLongerNeeded(pHash)
    return npc
end

-- ════════════════════════════════════════════════════════════════
--  CleanupMission
--
--  isCleaningUp  — prevents re-entrant double-execution
--  fromServer    — suppresses endMissionServer echo when the
--                  server already reset state via forceCleanup
--  Blip nilling  — prevents double-RemoveBlip errors
--  Batch delete  — one Wait(200) for all NetworkRequestControl,
--                  then delete pass (no per-entity Wait lag)
--  FIX: missionWagon nilled after deletion — no stale handles
-- ════════════════════════════════════════════════════════════════
function CleanupMission(msg, delay, fromServer)
    if isCleaningUp then return end
    isCleaningUp = true

    if msg then Notify(msg, 6000) end

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

    -- FIX: nil the wagon handle so nothing can reference a deleted entity
    missionWagon = nil

    if not fromServer then
        TriggerServerEvent('robbery:endMissionServer')
    end
end

-- ════════════════════════════════════════════════════════════════
--  robbery:forceCleanup
--  Server → client (e.g. playerDropped).
--  fromServer=true prevents the endMissionServer echo.
-- ════════════════════════════════════════════════════════════════
RegisterNetEvent('robbery:forceCleanup')
AddEventHandler('robbery:forceCleanup', function()
    CleanupMission(nil, 0, true)
end)
