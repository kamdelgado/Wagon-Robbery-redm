---@diagnostic disable: undefined-global

--[[
    server.lua – Armoured Wagon Robbery
    ════════════════════════════════════════════════════════════════════════════

    ARCHITECTURE (derived from outsider_grave_robbery + bcc-robbery patterns):
    ─────────────────────────────────────────────────────────────────────────
    • All entity creation (CreateVehicle / CreatePed) is server-side.
      The client NEVER spawns entities – it resolves netIds sent from here.
    • A single-active-mission gate + server-side cooldown timer prevent
      concurrent missions and abuse.
    • Server-side distance check before every event is accepted (mirrors
      outsider's exploit detection pattern in check_shovel).
    • playerDropped triggers full cleanup, exactly as outsider does with
      DIGGING_GRAVE cleanup.
    • Job alert event mirrors the outsider_alertjobs pattern exactly.

    PHASE STATE MACHINE:
        idle           – nothing active
        guards         – wagon moving, guards alive; player must kill them
        dynamite       – all guards dead; activator approaches wagon for minigame
        fuse           – minigame passed, 10s countdown running on client
        reinforcements – wagon blown; 10 reinfs riding toward player
        loot           – all reinfs dead; activator loots wagon for $300
        complete       – loot collected; 5-min cleanup timer running
        cooldown       – between missions (1 hr)
--]]

local VorpCore = exports.vorp_core:GetCore()

-- ─── Job Alert Table (mirrors outsider_grave_robbery exactly) ─────────────────
local JobsTable = {}

-- ─── Mission State ────────────────────────────────────────────────────────────
local M = {
    phase        = 'idle',
    player       = nil,     -- source of the activating player
    cooldownEnd  = 0,       -- os.time() value at which cooldown expires

    -- Entity handles (server owns these)
    wagon        = nil,
    driver       = nil,
    gunner       = nil,
    guards       = {},
    guardHorses  = {},
    reinfs       = {},
    reinfHorses  = {},

    -- Network IDs sent to clients
    wagonNetId       = nil,
    driverNetId      = nil,
    gunnerNetId      = nil,
    guardNetIds      = {},
    guardHorseNetIds = {},
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function dbg(...)
    if Config.Debug then print('[WagonRobbery]', ...) end
end

local function isActive()
    return M.phase ~= 'idle' and M.phase ~= 'cooldown'
end

local function isOnCooldown()
    return M.cooldownEnd > 0 and os.time() < M.cooldownEnd
end

local function startCooldown()
    M.cooldownEnd = os.time() + Config.GlobalCooldown
    dbg(('Cooldown started. Expires at os.time()=%d'):format(M.cooldownEnd))
end

-- Checks that a table (not counting nils) has at least 1 element – same helper
-- pattern bcc-robbery uses internally.
local function tableHasEntry(t)
    for _ in pairs(t) do return true end
    return false
end

-- ─── NPC Setup (applied after CreatePed server-side) ─────────────────────────

local function configureNpc(ped, weapon)
    if not DoesEntityExist(ped) then return end
    SetPedAccuracy(ped, Config.NpcAccuracy)
    SetPedCombatAbility(ped, Config.NpcCombatAbility)
    SetEntityHealth(ped, GetEntityHealth(ped) + Config.NpcBonusHealth)
    SetPedArmour(ped, Config.NpcArmour)
    SetPedCombatAttributes(ped, 2,  true)   -- always fight
    SetPedCombatAttributes(ped, 5,  true)   -- fight armed peds
    SetPedCombatAttributes(ped, 46, true)   -- use cover
    SetPedCombatAttributes(ped, 52, true)   -- face enemy
    SetPedRelationshipGroupHash(ped, `AMBIENT_GANG_WANTED`)
    if weapon then
        GiveWeaponToPed(ped, weapon, 999, true, true)
    end
end

-- Spawn a ped on a horse; returns (ped, horse) or (nil, nil) on failure.
local function spawnMounted(pedModel, horseModel, coords, weapon)
    local x, y, z, h = coords.x, coords.y, coords.z, coords.w

    local horse = CreateVehicle(horseModel, x, y, z, h, true, false)
    if not DoesEntityExist(horse) then
        print(('[WagonRobbery] ERROR: CreateVehicle(horse) failed at %s %s %s'):format(x,y,z))
        return nil, nil
    end
    SetEntityDistanceCullingRadius(horse, 0.0)

    local ped = CreatePed(pedModel, x, y, z + 0.5, h, true, false)
    if not DoesEntityExist(ped) then
        print(('[WagonRobbery] ERROR: CreatePed failed at %s %s %s'):format(x,y,z))
        DeleteEntity(horse)
        return nil, nil
    end
    SetEntityDistanceCullingRadius(ped, 0.0)
    configureNpc(ped, weapon)
    TaskWarpPedIntoVehicle(ped, horse, -1)  -- -1 = driver/rider seat

    return ped, horse
end

-- ─── Full Cleanup ─────────────────────────────────────────────────────────────

local function cleanupAll()
    dbg('cleanupAll() called, phase was: ' .. M.phase)

    local function tryDel(e) if e and DoesEntityExist(e) then DeleteEntity(e) end end

    tryDel(M.wagon); tryDel(M.driver); tryDel(M.gunner)
    for _, e in ipairs(M.guards)      do tryDel(e) end
    for _, e in ipairs(M.guardHorses) do tryDel(e) end
    for _, e in ipairs(M.reinfs)      do tryDel(e) end
    for _, e in ipairs(M.reinfHorses) do tryDel(e) end

    -- Tell all clients to clear local state, blips, prompts
    TriggerClientEvent('wagonrobbery:cleanup', -1)

    -- Reset state (preserve cooldownEnd – it keeps ticking after cleanup)
    M.phase        = 'idle'
    M.player       = nil
    M.wagon        = nil; M.driver       = nil; M.gunner    = nil
    M.guards       = {}; M.guardHorses  = {}
    M.reinfs       = {}; M.reinfHorses  = {}
    M.wagonNetId       = nil; M.driverNetId   = nil; M.gunnerNetId  = nil
    M.guardNetIds  = {}; M.guardHorseNetIds = {}

    dbg('cleanupAll() complete.')
end

-- ─── Mission Launch ───────────────────────────────────────────────────────────

local function launchMission(src)
    dbg('launchMission() for source ' .. src)
    local sc = Config.WagonSpawn

    -- Wagon
    M.wagon = CreateVehicle(Config.WagonModel, sc.x, sc.y, sc.z, sc.w, true, false)
    if not DoesEntityExist(M.wagon) then
        print('[WagonRobbery] FATAL: wagon CreateVehicle failed. Check Config.WagonModel hash.')
        return false
    end
    M.wagonNetId = NetworkGetNetworkIdFromEntity(M.wagon)
    SetEntityDistanceCullingRadius(M.wagon, 0.0)
    dbg('Wagon spawned netId=' .. M.wagonNetId)

    -- Driver (non-combat, drives the wagon)
    M.driver = CreatePed(Config.DriverModel, sc.x, sc.y, sc.z, sc.w, true, false)
    if DoesEntityExist(M.driver) then
        M.driverNetId = NetworkGetNetworkIdFromEntity(M.driver)
        SetEntityDistanceCullingRadius(M.driver, 0.0)
        SetPedCombatAbility(M.driver, 0)
        SetBlockingOfNonTemporaryEvents(M.driver, true)
        TaskWarpPedIntoVehicle(M.driver, M.wagon, -1)
    else
        print('[WagonRobbery] WARNING: driver CreatePed failed.')
        M.driverNetId = nil
    end

    -- Gatling gunner (turret seat)
    M.gunner = CreatePed(Config.GunnerModel, sc.x, sc.y, sc.z, sc.w, true, false)
    if DoesEntityExist(M.gunner) then
        M.gunnerNetId = NetworkGetNetworkIdFromEntity(M.gunner)
        SetEntityDistanceCullingRadius(M.gunner, 0.0)
        configureNpc(M.gunner, Config.GunnerWeapon)
        TaskWarpPedIntoVehicle(M.gunner, M.wagon, Config.GunnerSeat)
    else
        print('[WagonRobbery] WARNING: gunner CreatePed failed.')
        M.gunnerNetId = nil
    end

    -- 5 Mounted guards
    M.guards = {}; M.guardHorses = {}
    M.guardNetIds = {}; M.guardHorseNetIds = {}

    for _, gc in ipairs(Config.GuardSpawns) do
        local ped, horse = spawnMounted(Config.GuardModel, Config.GuardHorse, gc, Config.GuardWeapon)
        if ped and horse then
            M.guards[#M.guards+1]           = ped
            M.guardHorses[#M.guardHorses+1] = horse
            M.guardNetIds[#M.guardNetIds+1]            = NetworkGetNetworkIdFromEntity(ped)
            M.guardHorseNetIds[#M.guardHorseNetIds+1]  = NetworkGetNetworkIdFromEntity(horse)
        end
    end

    dbg(('Guards spawned: %d/%d requested'):format(#M.guards, #Config.GuardSpawns))

    -- Update state before triggering client events
    M.phase  = 'guards'
    M.player = src
    startCooldown()

    -- Total hostiles the activating client monitors (guards + gunner if alive)
    local totalHostiles = #M.guards + (M.gunnerNetId and 1 or 0)

    -- Tell the activating client everything it needs
    TriggerClientEvent('wagonrobbery:missionStarted', src, {
        wagonNetId       = M.wagonNetId,
        driverNetId      = M.driverNetId,
        gunnerNetId      = M.gunnerNetId,
        guardNetIds      = M.guardNetIds,
        guardHorseNetIds = M.guardHorseNetIds,
        totalHostiles    = totalHostiles,
        wagonDest        = Config.WagonDest,
    })

    -- Broadcast to all OTHER clients so they can see/participate but won't get
    -- blip or prompts (only activator gets those)
    TriggerClientEvent('wagonrobbery:missionBroadcast', -1, {
        wagonNetId  = M.wagonNetId,
        activatorSrc = src,
    })

    -- Job alert after 10 s delay (identical to outsider_grave_robbery)
    SetTimeout(10000, function()
        if M.phase ~= 'idle' then
            TriggerEvent('wagonrobbery:alertJobs', src)
        end
    end)

    -- Safety-net mission timeout (kicks in if activator goes AFK)
    SetTimeout(Config.MissionTimeout * 1000, function()
        if isActive() and M.player == src then
            dbg('Mission timeout reached for source ' .. src .. '. Cleaning up.')
            cleanupAll()
        end
    end)

    dbg('launchMission() complete.')
    return true
end

-- ─── Reinforcement Spawn ──────────────────────────────────────────────────────

local function spawnReinforcements()
    dbg(('Spawning %d reinforcements...'):format(Config.ReinfCount))
    M.reinfs = {}; M.reinfHorses = {}
    local reinfNetIds = {}; local reinfHorseNetIds = {}

    local rc = Config.ReinfSpawn
    for i = 1, Config.ReinfCount do
        -- Scatter slightly so they don't all stack on one spot
        local ox = ((i-1) % 4) * 4.0 - 6.0
        local oy = math.floor((i-1) / 4) * 5.0
        local sc = vector4(rc.x+ox, rc.y+oy, rc.z, rc.w)

        local ped, horse = spawnMounted(Config.ReinfModel, Config.ReinfHorse, sc, Config.ReinfWeapon)
        if ped and horse then
            M.reinfs[#M.reinfs+1]           = ped
            M.reinfHorses[#M.reinfHorses+1] = horse
            reinfNetIds[#reinfNetIds+1]           = NetworkGetNetworkIdFromEntity(ped)
            reinfHorseNetIds[#reinfHorseNetIds+1] = NetworkGetNetworkIdFromEntity(horse)
        end
    end

    M.phase = 'reinforcements'

    TriggerClientEvent('wagonrobbery:reinforcementsSpawned', M.player, {
        reinfNetIds      = reinfNetIds,
        reinfHorseNetIds = reinfHorseNetIds,
    })

    dbg(('Reinforcements spawned: %d'):format(#M.reinfs))
end

-- ─── Resource Lifecycle ───────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(name)
    if GetCurrentResourceName() ~= name then return end
    dbg('Resource started.')
end)

AddEventHandler('onResourceStop', function(name)
    if GetCurrentResourceName() ~= name then return end
    cleanupAll()
end)

-- ─── Job Alert (outsider_grave_robbery pattern, verbatim structure) ───────────

AddEventHandler('vorp:SelectedCharacter', function(src, char)
    local job = char.job
    for _, j in ipairs(Config.JobsToAlert) do
        if j == job then
            JobsTable[#JobsTable+1] = { source = src, job = job }
            break
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source

    -- Remove from job table (outsider pattern)
    for idx, v in pairs(JobsTable) do
        if v.source == src then JobsTable[idx] = nil end
    end

    -- If this player was the activating player, clean up
    if isActive() and M.player == src then
        dbg('Activating player ' .. src .. ' dropped. Cleaning up mission.')
        cleanupAll()
    end
end)

AddEventHandler('wagonrobbery:alertJobs', function(src)
    -- outsider_jobalerts integration (mirrors outsider_grave_robbery exactly)
    if Config.UseOutsiderJobAlerts then
        if exports['outsider_jobalerts'] then
            exports['outsider_jobalerts']:InsertAlert(src, Config.OutsiderJobAlertCmd)
        end
        return
    end

    for _, jobHolder in pairs(JobsTable) do
        if jobHolder.source ~= src then
            VorpCore.NotifyLeft(
                jobHolder.source,
                'Armoured Wagon',
                'A wagon robbery has been reported!',
                Config.Textures.alert[1],
                Config.Textures.alert[2],
                8000,
                'COLOR_WHITE'
            )
        end
    end
end)

-- ─── Server Events ────────────────────────────────────────────────────────────

-- 1. Player held E on starter ped ─────────────────────────────────────────────
RegisterServerEvent('wagonrobbery:requestStart')
AddEventHandler('wagonrobbery:requestStart', function()
    local src = source

    -- Cooldown gate
    if isOnCooldown() then
        VorpCore.NotifyRightTip(src, Config.Texts.OnCooldown, 6000)
        return
    end

    -- Single-active gate
    if isActive() then
        VorpCore.NotifyRightTip(src, Config.Texts.MissionAlreadyActive, 5000)
        return
    end

    -- Distance check vs starter ped (server-side, mirrors outsider exploit detection)
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local pedCoords    = Config.StarterPed.coords
    local dist = #(playerCoords - vector3(pedCoords.x, pedCoords.y, pedCoords.z))
    if dist > 15.0 then
        print(('[WagonRobbery] Exploit? %s triggered requestStart from %.1fm away.'):format(GetPlayerName(src), dist))
        return
    end

    -- Item check + consume (mirrors outsider check_shovel pattern)
    local item = exports.vorp_inventory:getItem(src, Config.RequiredItem)
    if not item then
        VorpCore.NotifyRightTip(src, Config.Texts.NeedDynamite, 5000)
        return
    end
    exports.vorp_inventory:subItem(src, Config.RequiredItem, 1)

    local ok = launchMission(src)
    if not ok then
        -- Refund on spawn failure
        exports.vorp_inventory:addItem(src, Config.RequiredItem, 1)
        VorpCore.NotifyRightTip(src, 'Server error: failed to spawn mission. Refunding item.', 5000)
    end
end)

-- 2. Activating client reports all guards dead ────────────────────────────────
RegisterServerEvent('wagonrobbery:guardsEliminated')
AddEventHandler('wagonrobbery:guardsEliminated', function()
    local src = source
    if not isActive() or M.player ~= src or M.phase ~= 'guards' then return end
    M.phase = 'dynamite'
    dbg('Phase → dynamite')
end)

-- 3. Activating client passed the minigame → dynamite placed ──────────────────
RegisterServerEvent('wagonrobbery:dynamitePlaced')
AddEventHandler('wagonrobbery:dynamitePlaced', function()
    local src = source
    if not isActive() or M.player ~= src or M.phase ~= 'dynamite' then return end

    -- Server-side distance check: player must still be near the wagon
    if M.wagon and DoesEntityExist(M.wagon) then
        local playerCoords = GetEntityCoords(GetPlayerPed(src))
        local wagonCoords  = GetEntityCoords(M.wagon)
        if #(playerCoords - wagonCoords) > Config.WagonTriggerDist + 5.0 then
            print(('[WagonRobbery] Exploit? %s sent dynamitePlaced from too far away.'):format(GetPlayerName(src)))
            return
        end
    end

    M.phase = 'fuse'
    dbg('Phase → fuse')
    TriggerClientEvent('wagonrobbery:startFuse', src)
end)

-- 4. Client fuse timer expired → blow wagon, spawn reinfs ─────────────────────
RegisterServerEvent('wagonrobbery:fuseExpired')
AddEventHandler('wagonrobbery:fuseExpired', function()
    local src = source
    if not isActive() or M.player ~= src or M.phase ~= 'fuse' then return end

    -- Explode the wagon server-side
    if M.wagon and DoesEntityExist(M.wagon) then
        NetworkExplodeVehicle(M.wagon, true, false, false)
    end

    TriggerClientEvent('wagonrobbery:wagonExploded', -1)
    spawnReinforcements()
    dbg('Phase → reinforcements')
end)

-- 5. All reinforcements dead ──────────────────────────────────────────────────
RegisterServerEvent('wagonrobbery:reinforcementsEliminated')
AddEventHandler('wagonrobbery:reinforcementsEliminated', function()
    local src = source
    if not isActive() or M.player ~= src or M.phase ~= 'reinforcements' then return end
    M.phase = 'loot'
    dbg('Phase → loot')
end)

-- 6. Player completed loot hold-E → pay out ───────────────────────────────────
RegisterServerEvent('wagonrobbery:lootComplete')
AddEventHandler('wagonrobbery:lootComplete', function()
    local src = source
    if not isActive() or M.player ~= src or M.phase ~= 'loot' then return end
    M.phase = 'complete'

    -- Distance check
    if M.wagon and DoesEntityExist(M.wagon) then
        local playerCoords = GetEntityCoords(GetPlayerPed(src))
        local wagonCoords  = GetEntityCoords(M.wagon)
        if #(playerCoords - wagonCoords) > Config.WagonTriggerDist + 5.0 then
            print(('[WagonRobbery] Exploit? %s sent lootComplete from too far away.'):format(GetPlayerName(src)))
            M.phase = 'loot'
            return
        end
    end

    -- Pay reward (mirrors vorp_core addCurrency pattern from bcc-robbery)
    local user = VorpCore.getUser(src)
    if user then
        local char = user.getUsedCharacter
        if char then
            char.addCurrency(0, Config.CashReward)
            VorpCore.NotifyRightTip(src, Config.Texts.MissionComplete, 7000)
            dbg(('Paid $%d to source %d'):format(Config.CashReward, src))
        end
    end

    -- Start the 5-minute cleanup timer
    SetTimeout(Config.CleanupDelay, function()
        if M.phase == 'complete' then
            dbg('Cleanup delay elapsed after mission complete.')
            cleanupAll()
        end
    end)
end)

-- 7. Activating player died mid-mission ───────────────────────────────────────
RegisterServerEvent('wagonrobbery:playerDied')
AddEventHandler('wagonrobbery:playerDied', function()
    local src = source
    if not isActive() or M.player ~= src then return end
    dbg('Activating player died. Cleaning up.')
    cleanupAll()
end)

-- 8. Reinforcements reached the player / player fled too long ──────────────────
RegisterServerEvent('wagonrobbery:reinforcementsWon')
AddEventHandler('wagonrobbery:reinforcementsWon', function()
    local src = source
    if not isActive() or M.player ~= src then return end
    dbg('Reinforcements won. Cleaning up.')
    TriggerClientEvent('wagonrobbery:missionFailed', src)
    cleanupAll()
end)

-- 9. Late-joining client asks for current mission state ────────────────────────
RegisterServerEvent('wagonrobbery:requestSync')
AddEventHandler('wagonrobbery:requestSync', function()
    local src = source
    if not isActive() then return end
    -- Send them the broadcast so they see the wagon blip (non-activators)
    TriggerClientEvent('wagonrobbery:missionBroadcast', src, {
        wagonNetId   = M.wagonNetId,
        activatorSrc = M.player,
    })
end)
