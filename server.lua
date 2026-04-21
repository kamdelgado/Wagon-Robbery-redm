---@diagnostic disable: undefined-global

--[[
    server.lua — Wagon Robbery (VORP / RedM)

    DESIGN PRINCIPLES (fixes for the AI-generated version):
    ─────────────────────────────────────────────────────────
    1. The SERVER owns all entity spawning. Wagons and guards are created here,
       their network IDs are sent to clients. Clients NEVER call CreateVehicle or
       CreatePed for this script.

    2. One robbery per encounter at a time. A server-side state table acts as the
       single source of truth. Any client trying to start a second robbery on the
       same encounter is rejected immediately.

    3. Distance is verified on the SERVER using GetEntityCoords(GetPlayerPed(source))
       before anything is authorised. This blocks teleport exploits.

    4. playerDropped cleans up any in-progress robbery for that player so the
       encounter doesn't get permanently locked.
--]]

local VorpCore  = exports.vorp_core:GetCore()

-- ─── State ───────────────────────────────────────────────────────────────────

--[[
    encounterState[encounterId] = {
        status        = 'idle' | 'active' | 'cooldown',
        wagonEntity   = <entity handle>,
        wagonNetId    = <network id>,
        guardEntities = { <entity>, … },
        guardNetIds   = { <netId>, … },
        robbingPlayer = <source> | nil,
        cooldownTimer = <timer handle> | nil,
    }
--]]
local encounterState = {}

-- Jobs table: players whose job qualifies them for robbery alerts
local jobAlertPlayers = {}

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getState(encounterId)
    if not encounterState[encounterId] then
        encounterState[encounterId] = {
            status        = 'idle',
            wagonEntity   = nil,
            wagonNetId    = nil,
            guardEntities = {},
            guardNetIds   = {},
            robbingPlayer = nil,
            cooldownTimer = nil,
        }
    end
    return encounterState[encounterId]
end

local function isJobInAlertList(job)
    for _, j in ipairs(Config.JobsToAlert) do
        if j == job then return true end
    end
    return false
end

local function notifyJobHolders(source, encounterId)
    local enc = Config.Encounters[encounterId]
    if not enc then return end

    if Config.UseOutsiderJobAlerts then
        -- If outsider_jobalerts is installed, use it
        if exports['outsider_jobalerts'] then
            exports['outsider_jobalerts']:InsertAlert(source, Config.OutsiderJobAlertCommand)
        end
        return
    end

    for _, holder in pairs(jobAlertPlayers) do
        if holder.source ~= source then
            VorpCore.NotifyLeft(
                holder.source,
                enc.town,
                Config.Texts.GuardsAlert,
                'generic_textures',
                'temp_pedshot',
                8000,
                'COLOR_WHITE'
            )
        end
    end
end

--[[
    Spawn the wagon and guards for an encounter on the server side.
    Returns true on success, false if something went wrong.
--]]
local function spawnEncounter(encounterId)
    local enc = Config.Encounters[encounterId]
    if not enc then
        print(('[WagonRobbery] ERROR: no encounter config for id %d'):format(encounterId))
        return false
    end

    local state = getState(encounterId)
    if state.status ~= 'idle' then
        -- Already active or on cooldown — don't double-spawn
        return false
    end

    -- ── Spawn wagon (server-side, OneSync) ──────────────────────────────────
    local c       = enc.coords
    local wagon   = CreateVehicle(Config.WagonModel, c.x, c.y, c.z, c.w, true, false)

    if not DoesEntityExist(wagon) then
        print(('[WagonRobbery] ERROR: CreateVehicle failed for encounter %d'):format(encounterId))
        return false
    end

    local wagonNetId = NetworkGetNetworkIdFromEntity(wagon)

    -- Make entity persistent so OneSync doesn't cull it when no player is nearby
    SetEntityDistanceCullingRadius(wagon, 0.0) -- 0 = no forced culling radius override
    -- The wagon is owned by the server; freeze it in place (it's a stationary target)
    FreezeEntityPosition(wagon, true)

    -- ── Spawn guards ────────────────────────────────────────────────────────
    local guardEntities = {}
    local guardNetIds   = {}

    for _, gcoords in ipairs(enc.guards) do
        local guard = CreatePed(
            Config.GuardModel,
            gcoords.x, gcoords.y, gcoords.z, gcoords.w,
            true, false
        )

        if DoesEntityExist(guard) then
            -- Arm the guard
            GiveWeaponToPed(guard, Config.GuardWeapon, 100, true, true)
            SetPedRelationshipGroupHash(guard, `AMBIENT_GANG_WANTED`)
            -- Keep guard alive and in place until the robbery starts
            SetEntityInvincible(guard, true)
            FreezeEntityPosition(guard, true)

            local gNetId = NetworkGetNetworkIdFromEntity(guard)
            guardEntities[#guardEntities + 1] = guard
            guardNetIds[#guardNetIds + 1]     = gNetId
        else
            print(('[WagonRobbery] WARNING: CreatePed failed for a guard in encounter %d'):format(encounterId))
        end
    end

    -- ── Update state ────────────────────────────────────────────────────────
    state.status        = 'active'
    state.wagonEntity   = wagon
    state.wagonNetId    = wagonNetId
    state.guardEntities = guardEntities
    state.guardNetIds   = guardNetIds
    state.robbingPlayer = nil

    -- ── Tell ALL clients about the new encounter ─────────────────────────────
    TriggerClientEvent('wagonrobbery:syncEncounter', -1, encounterId, wagonNetId, guardNetIds)

    print(('[WagonRobbery] Encounter %d spawned. Wagon netId: %d, Guards: %d'):format(
        encounterId, wagonNetId, #guardNetIds
    ))
    return true
end

--[[
    Clean up all entities for an encounter and begin the cooldown timer.
--]]
local function despawnEncounter(encounterId)
    local state = getState(encounterId)

    -- Delete wagon
    if state.wagonEntity and DoesEntityExist(state.wagonEntity) then
        DeleteEntity(state.wagonEntity)
    end

    -- Delete guards
    for _, guard in ipairs(state.guardEntities) do
        if DoesEntityExist(guard) then
            DeleteEntity(guard)
        end
    end

    state.status        = 'cooldown'
    state.wagonEntity   = nil
    state.wagonNetId    = nil
    state.guardEntities = {}
    state.guardNetIds   = {}
    state.robbingPlayer = nil

    -- Tell ALL clients to remove blips / local references
    TriggerClientEvent('wagonrobbery:clearEncounter', -1, encounterId)

    -- After cooldown, mark as idle and re-spawn
    if state.cooldownTimer then
        -- Cancel any previous timer (shouldn't happen, but be safe)
        state.cooldownTimer = nil
    end

    state.cooldownTimer = SetTimeout(Config.CooldownMinutes * 60000, function()
        state.status        = 'idle'
        state.cooldownTimer = nil
        spawnEncounter(encounterId)
    end)

    print(('[WagonRobbery] Encounter %d despawned. Respawning in %d minutes.'):format(
        encounterId, Config.CooldownMinutes
    ))
end

-- ─── Resource Lifecycle ──────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    -- Small delay so VorpCore has time to initialise
    SetTimeout(2000, function()
        for i, _ in ipairs(Config.Encounters) do
            spawnEncounter(i)
        end
    end)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for i, _ in ipairs(Config.Encounters) do
        local state = getState(i)
        if state.wagonEntity and DoesEntityExist(state.wagonEntity) then
            DeleteEntity(state.wagonEntity)
        end
        for _, guard in ipairs(state.guardEntities) do
            if DoesEntityExist(guard) then DeleteEntity(guard) end
        end
    end
end)

-- ─── Player Character Selected (for job alert table) ─────────────────────────

AddEventHandler('vorp:SelectedCharacter', function(source, char)
    if isJobInAlertList(char.job) then
        jobAlertPlayers[source] = { source = source, job = char.job }
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    jobAlertPlayers[src] = nil

    -- If this player was mid-robbery, cancel it and re-activate guards
    for i, _ in ipairs(Config.Encounters) do
        local state = getState(i)
        if state.robbingPlayer == src then
            state.robbingPlayer = nil
            -- Re-freeze guards (they were made mortal for the fight)
            for _, guard in ipairs(state.guardEntities) do
                if DoesEntityExist(guard) then
                    SetEntityInvincible(guard, true)
                    FreezeEntityPosition(guard, true)
                end
            end
            TriggerClientEvent('wagonrobbery:robberyCancelled', -1, i)
            print(('[WagonRobbery] Player %d dropped mid-robbery of encounter %d — cancelled.'):format(src, i))
        end
    end
end)

-- ─── Server Events (called by clients) ───────────────────────────────────────

--[[
    Client requests to start robbing an encounter.
    Server validates distance, item ownership, and encounter state before authorising.
--]]
RegisterServerEvent('wagonrobbery:requestRob', function(encounterId)
    local src   = source
    local state = getState(encounterId)

    -- ── Guard: encounter must be active ─────────────────────────────────────
    if state.status ~= 'active' then
        VorpCore.NotifyRightTip(src, Config.Texts.AlreadyRobbed, 4000)
        return
    end

    -- ── Guard: only one player can rob at a time ─────────────────────────────
    if state.robbingPlayer ~= nil then
        VorpCore.NotifyRightTip(src, Config.Texts.InProgress, 4000)
        return
    end

    -- ── Guard: distance check (server-side) ──────────────────────────────────
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local wagonCoords  = GetEntityCoords(state.wagonEntity)
    local distance     = #(playerCoords - wagonCoords)

    if distance > Config.MaxRobDistance then
        print(('[WagonRobbery] Exploit attempt: %s tried to rob encounter %d from %.1f units away.'):format(
            GetPlayerName(src), encounterId, distance
        ))
        VorpCore.NotifyRightTip(src, Config.Texts.TooFar, 4000)
        return
    end

    -- ── Guard: required item check ───────────────────────────────────────────
    if Config.RequiredItem then
        local item = exports.vorp_inventory:getItem(src, Config.RequiredItem)
        if not item then
            VorpCore.NotifyRightTip(src, Config.Texts.NoItem, 4000)
            return
        end
    end

    -- ── All checks passed — authorise ────────────────────────────────────────
    state.robbingPlayer = src

    -- Make guards mortal and unfreeze so they react
    for _, guard in ipairs(state.guardEntities) do
        if DoesEntityExist(guard) then
            SetEntityInvincible(guard, false)
            FreezeEntityPosition(guard, false)
        end
    end

    -- Tell the robbing player to start the loot sequence
    TriggerClientEvent('wagonrobbery:beginLoot', src, encounterId)

    -- Tell all other clients guards have been activated (so they see the fight)
    TriggerClientEvent('wagonrobbery:guardsAlerted', -1, encounterId)

    -- Set a server-side timeout in case the player disconnects or walks away
    -- without completing (prevents encounter being permanently locked)
    SetTimeout(Config.RobberyTimeout * 1000, function()
        local freshState = getState(encounterId)
        if freshState.robbingPlayer == src then
            freshState.robbingPlayer = nil
            -- Re-freeze guards
            for _, guard in ipairs(freshState.guardEntities) do
                if DoesEntityExist(guard) then
                    SetEntityInvincible(guard, true)
                    FreezeEntityPosition(guard, true)
                end
            end
            TriggerClientEvent('wagonrobbery:robberyCancelled', -1, encounterId)
            print(('[WagonRobbery] Encounter %d robbery timed out for player %d.'):format(encounterId, src))
        end
    end)

    -- Notify law enforcement (10 second delay for realism)
    SetTimeout(10000, function()
        notifyJobHolders(src, encounterId)
    end)
end)

--[[
    Client reports that the loot sequence completed successfully.
--]]
RegisterServerEvent('wagonrobbery:completeLoot', function(encounterId)
    local src   = source
    local state = getState(encounterId)

    -- Anti-exploit: only the registered robber can complete it
    if state.robbingPlayer ~= src then
        print(('[WagonRobbery] Exploit attempt: %s tried to complete encounter %d but is not the robber.'):format(
            GetPlayerName(src), encounterId
        ))
        return
    end

    -- ── Roll loot ────────────────────────────────────────────────────────────
    local foundAnything = false

    for _, loot in ipairs(Config.Loot) do
        if math.random() <= loot.chance then
            local canCarry = exports.vorp_inventory:canCarryItem(src, loot.item, loot.amount)
            if canCarry then
                exports.vorp_inventory:addItem(src, loot.item, loot.amount)
                VorpCore.NotifyRightTip(src, Config.Texts.FoundItem .. ' ' .. loot.label, 5000)
                foundAnything = true
            end
        end
    end

    if not foundAnything then
        VorpCore.NotifyRightTip(src, Config.Texts.NothingFound, 4000)
    end

    -- ── Despawn and start cooldown ────────────────────────────────────────────
    despawnEncounter(encounterId)
end)

--[[
    Client reports the robbery was interrupted (player cancelled, guards killed player, etc.)
--]]
RegisterServerEvent('wagonrobbery:cancelRob', function(encounterId)
    local src   = source
    local state = getState(encounterId)

    if state.robbingPlayer ~= src then return end

    state.robbingPlayer = nil
    for _, guard in ipairs(state.guardEntities) do
        if DoesEntityExist(guard) then
            SetEntityInvincible(guard, true)
            FreezeEntityPosition(guard, true)
        end
    end
    TriggerClientEvent('wagonrobbery:robberyCancelled', -1, encounterId)
end)

--[[
    A client asks for the current state of all encounters (called on spawn/character select
    so late joiners get the active wagon positions).
--]]
RegisterServerEvent('wagonrobbery:requestSync', function()
    local src = source
    for i, _ in ipairs(Config.Encounters) do
        local state = getState(i)
        if state.status == 'active' then
            TriggerClientEvent('wagonrobbery:syncEncounter', src, i, state.wagonNetId, state.guardNetIds)
        end
    end
end)
