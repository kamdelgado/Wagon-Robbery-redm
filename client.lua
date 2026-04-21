---@diagnostic disable: undefined-global

--[[
    client.lua — Wagon Robbery (VORP / RedM)

    DESIGN PRINCIPLES (fixes for the AI-generated version):
    ─────────────────────────────────────────────────────────
    1. NO CreateVehicle / CreatePed here. Wagons and guards are spawned by the
       server. This client resolves server entities using NetworkGetEntityFromNetworkId.

    2. The main proximity loop sleeps aggressively (1000ms when far, 0ms when
       close) so it doesn't tank resmon for every player.

    3. All robbery authority is on the server. The client only fires animations
       and progress bars after receiving explicit server approval via
       'wagonrobbery:beginLoot'.

    4. A single PromptGroup per encounter is created/destroyed as needed, not
       recreated every frame.
--]]

-- ─── State ───────────────────────────────────────────────────────────────────

-- activeEncounters[encounterId] = { wagonNetId, guardNetIds, blip, promptGroup, prompts }
local activeEncounters = {}

-- Are we currently mid-loot animation?
local isLooting = false

-- Which encounter are we looting (nil if none)
local currentLootEncounter = nil

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function notify(msg)
    TriggerEvent('vorp:TipBottom', msg, 5000)
end

--[[
    Wait until the given netId resolves to a valid local entity handle.
    Returns the entity handle, or nil if it never resolved.
    Timeout after 5 seconds to avoid infinite loops.
--]]
local function waitForEntity(netId, timeout)
    timeout = timeout or 5000
    local elapsed = 0
    while elapsed < timeout do
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local ent = NetworkGetEntityFromNetworkId(netId)
            if DoesEntityExist(ent) then
                return ent
            end
        end
        Wait(100)
        elapsed = elapsed + 100
    end
    return nil
end

--[[
    Create the interaction prompt for an encounter.
    Returns the promptGroup handle and prompt handle.
--]]
local function createPrompt(encounterId)
    local group = GetRandomIntInRange(0, 0xffffff)
    local prompt = UiPromptRegisterBegin()
    UiPromptSetControlAction(prompt, Config.PromptKey)
    local str = VarString(10, 'LITERAL_STRING', Config.Texts.Prompt)
    UiPromptSetText(prompt, str)
    UiPromptSetEnabled(prompt, true)
    UiPromptSetVisible(prompt, true)
    UiPromptSetStandardMode(prompt, true)
    UiPromptSetGroup(prompt, group, 0)
    UiPromptRegisterEnd(prompt)
    return group, prompt
end

local function deletePrompt(promptHandle)
    if promptHandle then
        UiPromptDelete(promptHandle)
    end
end

local function addBlip(encounterId)
    local enc = Config.Encounters[encounterId]
    if not enc then return nil end
    local c = enc.coords
    local blip = BlipAddForCoords(Config.ActiveBlip.sprite, c.x, c.y, c.z)
    BlipSetRotation(blip, 0)
    BlipSetScale(blip, Config.ActiveBlip.scale)
    BlipAddModifier(blip, Config.ActiveBlip.color)
    local label = VarString(10, 'LITERAL_STRING', Config.ActiveBlip.label)
    BeginTextCommandSetBlipName('LITERAL_STRING')
    AddTextComponentSubstringPlayerName(enc.name)
    EndTextCommandSetBlipName(blip)
    return blip
end

local function removeBlip(blip)
    if blip and DoesBlipExist(blip) then
        RemoveBlip(blip)
    end
end

-- ─── Server Events ────────────────────────────────────────────────────────────

--[[
    Server tells us a new encounter is active.
    We record the netIds and create a blip. The proximity loop does the rest.
--]]
RegisterNetEvent('wagonrobbery:syncEncounter')
AddEventHandler('wagonrobbery:syncEncounter', function(encounterId, wagonNetId, guardNetIds)
    -- Clean up any stale data for this encounter first
    if activeEncounters[encounterId] then
        removeBlip(activeEncounters[encounterId].blip)
        deletePrompt(activeEncounters[encounterId].prompt)
    end

    local blip = addBlip(encounterId)

    activeEncounters[encounterId] = {
        wagonNetId  = wagonNetId,
        guardNetIds = guardNetIds,
        blip        = blip,
        promptGroup = nil,
        prompt      = nil,
        inRange     = false,
    }
end)

--[[
    Server tells us to wipe the encounter (robbery done / cooldown started).
--]]
RegisterNetEvent('wagonrobbery:clearEncounter')
AddEventHandler('wagonrobbery:clearEncounter', function(encounterId)
    local enc = activeEncounters[encounterId]
    if not enc then return end

    removeBlip(enc.blip)
    deletePrompt(enc.prompt)
    activeEncounters[encounterId] = nil

    -- If we were looting this one, cancel
    if currentLootEncounter == encounterId then
        isLooting = false
        currentLootEncounter = nil
        ClearPedTasks(PlayerPedId())
    end
end)

--[[
    Server authorises OUR robbery attempt — play loot animation then report back.
--]]
RegisterNetEvent('wagonrobbery:beginLoot')
AddEventHandler('wagonrobbery:beginLoot', function(encounterId)
    if isLooting then return end
    isLooting = true
    currentLootEncounter = encounterId

    local ped = PlayerPedId()
    notify(Config.Texts.RobberyStart)

    -- Play a loot animation while the "progress bar" timer runs
    local animDict = 'amb_camp@world_human_crouch_idle@male@idle_a'
    local animName = 'idle_a'

    if not HasAnimDictLoaded(animDict) then
        RequestAnimDict(animDict)
        local t = 0
        while not HasAnimDictLoaded(animDict) and t < 3000 do
            Wait(100)
            t = t + 100
        end
    end

    if HasAnimDictLoaded(animDict) then
        TaskPlayAnim(ped, animDict, animName, 1.0, 1.0, Config.LootDuration, 1, 0, false, false, false)
    end

    -- Show a simple text countdown (replace with your progress bar if you have one)
    local elapsed = 0
    local cancelled = false

    while elapsed < Config.LootDuration do
        Wait(500)
        elapsed = elapsed + 500

        -- If the encounter was cleared from under us (robbery cancelled by server)
        if not activeEncounters[encounterId] then
            cancelled = true
            break
        end

        -- If the player moved too far, cancel
        local enc = activeEncounters[encounterId]
        if enc then
            local wagon = waitForEntity(enc.wagonNetId, 100)
            if wagon then
                local dist = #(GetEntityCoords(ped) - GetEntityCoords(wagon))
                if dist > Config.MaxRobDistance then
                    cancelled = true
                    TriggerServerEvent('wagonrobbery:cancelRob', encounterId)
                    break
                end
            end
        end
    end

    ClearPedTasks(ped)
    RemoveAnimDict(animDict)

    if not cancelled then
        notify(Config.Texts.RobberySuccess)
        TriggerServerEvent('wagonrobbery:completeLoot', encounterId)
    else
        notify(Config.Texts.RobberyFail)
    end

    isLooting = false
    currentLootEncounter = nil
end)

--[[
    Server notified us the guards are now active (another player started robbing).
    Nothing to do visually for now — guards are server-side entities and will
    replicate automatically via OneSync.
--]]
RegisterNetEvent('wagonrobbery:guardsAlerted')
AddEventHandler('wagonrobbery:guardsAlerted', function(encounterId)
    -- Optional: play a distant gunshot sound, show a screen flash, etc.
end)

--[[
    Server says robbery was cancelled (timeout, player dropped, etc.)
--]]
RegisterNetEvent('wagonrobbery:robberyCancelled')
AddEventHandler('wagonrobbery:robberyCancelled', function(encounterId)
    if currentLootEncounter == encounterId then
        isLooting = false
        currentLootEncounter = nil
        ClearPedTasks(PlayerPedId())
        notify(Config.Texts.RobberyFail)
    end
end)

-- ─── Main Proximity Loop ─────────────────────────────────────────────────────

CreateThread(function()
    -- Wait until the player is fully in session before doing anything
    repeat Wait(5000) until LocalPlayer.state.IsInSession

    -- Ask server for current encounter states (handles late joins / reconnects)
    TriggerServerEvent('wagonrobbery:requestSync')

    while true do
        local sleep = 1000
        local ped   = PlayerPedId()

        if not IsEntityDead(ped) then
            local pcoords = GetEntityCoords(ped)

            for encounterId, enc in pairs(activeEncounters) do

                -- Resolve the wagon entity from its network ID
                local wagon = nil
                if NetworkDoesEntityExistWithNetworkId(enc.wagonNetId) then
                    wagon = NetworkGetEntityFromNetworkId(enc.wagonNetId)
                end

                if wagon and DoesEntityExist(wagon) then
                    local dist = #(pcoords - GetEntityCoords(wagon))

                    if dist < Config.TriggerDistance then
                        -- Player is close — switch to high-frequency loop for this encounter
                        sleep = 0
                        enc.inRange = true

                        -- Create prompt on first entry
                        if not enc.prompt then
                            enc.promptGroup, enc.prompt = createPrompt(encounterId)
                        end

                        -- Show prompt header
                        local label = VarString(10, 'LITERAL_STRING', Config.Encounters[encounterId].name)
                        UiPromptSetActiveGroupThisFrame(enc.promptGroup, label, 0, 0, 0, 0)

                        -- Check if player pressed the prompt
                        if not isLooting and UiPromptHasStandardModeCompleted(enc.prompt, 0) then
                            TriggerServerEvent('wagonrobbery:requestRob', encounterId)
                            Wait(2000) -- debounce
                        end

                    else
                        -- Player left range — destroy prompt, reset flag
                        if enc.inRange then
                            deletePrompt(enc.prompt)
                            enc.prompt      = nil
                            enc.promptGroup = nil
                            enc.inRange     = false
                        end
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

-- ─── Resource Stop Cleanup ────────────────────────────────────────────────────

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, enc in pairs(activeEncounters) do
        removeBlip(enc.blip)
        deletePrompt(enc.prompt)
    end

    activeEncounters = {}
    isLooting = false
    currentLootEncounter = nil
end)
