-- ================================================================
--  STAGECOACH ROBBERY  |  server.lua
--  VORP Core 2025/2026  |  Lua 5.4  |  vorp_inventory 3.6+
-- ================================================================
--  Verified against:
--    docs.vorp-core.com (2026)
--    iboss21/lxr-bounty-quests (multi-framework reference, 2026)
-- ================================================================

local VORPcore = exports.vorp_core:GetCore()

-- ── State ────────────────────────────────────────────────────────
local missionActive        = false
local currentMissionPlayer = nil
local missionStartTime     = nil
local playerCooldowns      = {}   -- [identifier] = unix timestamp
local fencingInProgress    = {}   -- [source]     = bool

-- ── Config ───────────────────────────────────────────────────────
local Config = {
    cooldownMinutes  = 60,
    payoutMin        = 800,
    payoutMax        = 1200,
    watchdogMinutes  = 20,   -- server auto-reset if client never fires cleanup
}
-- ─────────────────────────────────────────────────────────────────

-- Seed randomiser on resource start (lxr-bounty-quests omits this — we keep it)
math.randomseed(os.time())

-- ────────────────────────────────────────────────────────────────
--  HELPER  getItemCount
--  Official vorp_inventory 3.6+ signature:
--    getItemCount(source, callback, item, metadata, percentage)
--  Passing nil as callback returns synchronously.
--  Always returns a number — never nil.
-- ────────────────────────────────────────────────────────────────
local function getItemCount(src, itemName)
    local n = exports.vorp_inventory:getItemCount(src, nil, itemName)
    return n or 0
end

-- ════════════════════════════════════════════════════════════════
--  WATCHDOG THREAD
--  Releases missionActive if the client crashes and never calls
--  robbery:endMissionServer.  Fires once per minute.
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

    -- Use vorp_inventory export — char.getItemCount is legacy and
    -- silently returns nil on vorp_inventory 3.6+
    if getItemCount(_source, "dynamite") < 1 then
        return {success = false, msg = "You need Dynamite to blow the wagon doors!"}
    end

    -- Prevent timing exploit: can't start while already holding a lockbox
    if getItemCount(_source, "stolen_lockbox") > 0 then
        return {success = false, msg = "You already have a stolen lockbox. Fence it first!"}
    end

    missionActive        = true
    currentMissionPlayer = _source
    missionStartTime     = os.time()

    -- pcall: prevents server error if law script event doesn't exist
    pcall(function()
        TriggerEvent('vorp_wanted:add', _source, 20, "Stagecoach Robbery")
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
    exports.vorp_inventory:subItem(_source, "dynamite", 1)
end)

-- ════════════════════════════════════════════════════════════════
--  RPCs: robbery:checkDynamite  /  robbery:hasLockbox
-- ════════════════════════════════════════════════════════════════
RPC.register('robbery:checkDynamite', function(source)
    return getItemCount(source, "dynamite") > 0
end)

RPC.register('robbery:hasLockbox', function(source)
    return getItemCount(source, "stolen_lockbox") > 0
end)

-- ════════════════════════════════════════════════════════════════
--  robbery:giveLockbox
--  Auth guard: only the active mission player may trigger this.
-- ════════════════════════════════════════════════════════════════
RegisterServerEvent('robbery:giveLockbox')
AddEventHandler('robbery:giveLockbox', function()
    local _source = source
    if _source ~= currentMissionPlayer then return end
    exports.vorp_inventory:addItem(_source, "stolen_lockbox", 1)
end)

-- ════════════════════════════════════════════════════════════════
--  robbery:fenceLoot
--  Spam-protected with fencingInProgress lock.
--  Server-side inventory re-verify via export (not char method).
--  Reward via character.addCurrency(0 = cash).
--  Modern server notification via VORPcore.NotifyTip.
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

    if getItemCount(_source, "stolen_lockbox") < 1 then
        fencingInProgress[_source] = nil
        return
    end

    exports.vorp_inventory:subItem(_source, "stolen_lockbox", 1)

    local character = user.getUsedCharacter
    local payout    = math.random(Config.payoutMin, Config.payoutMax)
    character.addCurrency(0, payout)   -- 0 = cash, 1 = gold

    -- Modern server-side notify (Core object — not legacy TriggerClientEvent)
    VORPcore.NotifyTip(_source, "The Fence paid $" .. payout .. ". Ride easy.", 8000)

    playerCooldowns[character.identifier] = os.time() + (Config.cooldownMinutes * 60)
    missionActive            = false
    currentMissionPlayer     = nil
    missionStartTime         = nil
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
-- ════════════════════════════════════════════════════════════════
AddEventHandler('playerDropped', function()
    if source == currentMissionPlayer then
        missionActive        = false
        currentMissionPlayer = nil
        missionStartTime     = nil
        TriggerClientEvent('robbery:forceCleanup', -1)
    end
end)
