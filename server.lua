-- ================================================================
--  STAGECOACH ROBBERY  |  server.lua
--  VORP Core 2025/2026  |  Lua 5.4  |  vorp_inventory 3.6+
-- ================================================================
--  Verified against:
--    docs.vorp-core.com (2026)
--    iboss21/lxr-bounty-quests (multi-framework reference, 2026)
--
--  All tuneable values live in config.lua.
--  Do not hardcode item names, payouts, or cooldowns here.
-- ================================================================

local VORPcore = exports.vorp_core:GetCore()

-- ── State ────────────────────────────────────────────────────────
local missionActive        = false
local currentMissionPlayer = nil
local missionStartTime     = nil
local playerCooldowns      = {}   -- [identifier] = unix timestamp
local fencingInProgress    = {}   -- [source]     = bool

-- ─────────────────────────────────────────────────────────────────
-- Seed randomiser on resource start
math.randomseed(os.time())

-- ────────────────────────────────────────────────────────────────
--  HELPER  getItemCount
--  vorp_inventory 3.6+ — passing nil as callback returns
--  synchronously. Re-verify this if vorp_inventory is updated.
-- ────────────────────────────────────────────────────────────────
local function getItemCount(src, itemName)
    local n = exports.vorp_inventory:getItemCount(src, nil, itemName)
    return n or 0
end

-- ════════════════════════════════════════════════════════════════
--  WATCHDOG THREAD
--  Releases missionActive if the client crashes and never calls
--  robbery:endMissionServer. Fires once per minute.
-- ════════════════════════════════════════════════════════════════
Citizen.CreateThread(function()
    while true do
        Wait(60000)
        if missionActive and missionStartTime then
            if os.time() - missionStartTime > (Config.watchdogMinutes * 60) then
                print("[robbery] Watchdog: force-releasing stuck mission.")
                missionActive        = false
                currentMissionPlayer = nil
                missionStartTime     = nil
            end
        end
    end
end)

-- ════════════════════════════════════════════════════════════════
--  RPC: robbery:tryStart
--  Full server-side gate before mission is allowed to begin.
--  Returns {success, msg} — client shows the message on failure.
-- ════════════════════════════════════════════════════════════════
RPC.register('robbery:tryStart', function(source)
    local _source = source
    local user    = VORPcore.getUser(_source)
    if not user then
        return {success = false, msg = "Could not load your character. Try again."}
    end

    local char       = user.getUsedCharacter
    local identifier = char.identifier

    if missionActive then
        return {success = false, msg = "A heist is already in progress!"}
    end

    if playerCooldowns[identifier] and os.time() < playerCooldowns[identifier] then
        local rem = math.ceil((playerCooldowns[identifier] - os.time()) / 60)
        return {success = false, msg = "The law is watching. Wait " .. rem .. " more min(s)."}
    end

    if getItemCount(_source, Config.dynamiteItem) < 1 then
        return {success = false, msg = "You need Dynamite to blow the wagon doors!"}
    end

    -- Prevent timing exploit: can't start while already holding a lockbox
    if getItemCount(_source, Config.lockboxItem) > 0 then
        return {success = false, msg = "You already have a stolen lockbox. Fence it first!"}
    end

    missionActive        = true
    currentMissionPlayer = _source
    missionStartTime     = os.time()

    -- pcall: prevents server error if vorp_wanted doesn't exist
    pcall(function()
        TriggerEvent('vorp_wanted:add', _source, Config.wantedPoints, Config.wantedReason)
    end)

    return {success = true}
end)

-- ════════════════════════════════════════════════════════════════
--  robbery:consumeDynamite
--  Auth guard: only the active mission player may trigger this.
-- ════════════════════════════════════════════════════════════════
RegisterServerEvent('robbery:consumeDynamite')
AddEventHandler('robbery:consumeDynamite', function()
    local _source = source
    if _source ~= currentMissionPlayer then return end
    exports.vorp_inventory:subItem(_source, Config.dynamiteItem, 1)
end)

-- ════════════════════════════════════════════════════════════════
--  RPCs: robbery:checkDynamite  /  robbery:hasLockbox
-- ════════════════════════════════════════════════════════════════
RPC.register('robbery:checkDynamite', function(source)
    return getItemCount(source, Config.dynamiteItem) > 0
end)

RPC.register('robbery:hasLockbox', function(source)
    return getItemCount(source, Config.lockboxItem) > 0
end)

-- ════════════════════════════════════════════════════════════════
--  robbery:giveLockbox
--  Auth guard: only the active mission player may trigger this.
-- ════════════════════════════════════════════════════════════════
RegisterServerEvent('robbery:giveLockbox')
AddEventHandler('robbery:giveLockbox', function()
    local _source = source
    if _source ~= currentMissionPlayer then return end
    exports.vorp_inventory:addItem(_source, Config.lockboxItem, 1)
end)

-- ════════════════════════════════════════════════════════════════
--  robbery:fenceLoot
--  Spam-protected with fencingInProgress lock.
--  Server-side inventory re-verify before paying out.
-- ════════════════════════════════════════════════════════════════
RegisterServerEvent('robbery:fenceLoot')
AddEventHandler('robbery:fenceLoot', function()
    local _source = source

    if fencingInProgress[_source] then return end
    fencingInProgress[_source] = true

    local user = VORPcore.getUser(_source)
    if not user then
        fencingInProgress[_source] = nil
        return
    end

    if getItemCount(_source, Config.lockboxItem) < 1 then
        fencingInProgress[_source] = nil
        return
    end

    exports.vorp_inventory:subItem(_source, Config.lockboxItem, 1)

    local character = user.getUsedCharacter
    local payout    = math.random(Config.payoutMin, Config.payoutMax)
    character.addCurrency(0, payout)   -- 0 = cash, 1 = gold

    VORPcore.NotifyTip(_source, "The Fence paid $" .. payout .. ". Ride easy.", 8000)

    playerCooldowns[character.identifier] = os.time() + (Config.cooldownMinutes * 60)
    missionActive              = false
    currentMissionPlayer       = nil
    missionStartTime           = nil
    fencingInProgress[_source] = nil
end)

-- ════════════════════════════════════════════════════════════════
--  robbery:endMissionServer
--  Called by the client on all normal exit paths.
-- ════════════════════════════════════════════════════════════════
RegisterServerEvent('robbery:endMissionServer')
AddEventHandler('robbery:endMissionServer', function()
    missionActive        = false
    currentMissionPlayer = nil
    missionStartTime     = nil
end)

-- ════════════════════════════════════════════════════════════════
--  playerDropped
--  If the mission player disconnects, release the lock and
--  broadcast forceCleanup to all clients.
--
--  fencingInProgress[source] cleared unconditionally — source IDs
--  are recycled by RedM, so a dangling true entry would permanently
--  block any new player assigned that same ID.
-- ════════════════════════════════════════════════════════════════
AddEventHandler('playerDropped', function()
    fencingInProgress[source] = nil

    if source == currentMissionPlayer then
        missionActive        = false
        currentMissionPlayer = nil
        missionStartTime     = nil
        TriggerClientEvent('robbery:forceCleanup', -1)
    end
end)
