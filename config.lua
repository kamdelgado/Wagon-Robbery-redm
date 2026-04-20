-- ================================================================
--  STAGECOACH ROBBERY  |  config.lua
--  Shared script — loaded before client.lua and server.lua
--  VORP Core 2025/2026  |  Lua 5.4
-- ================================================================
--
--  Add to fxmanifest.lua:
--
--    shared_scripts {
--        'config.lua',
--    }
--    client_scripts {
--        'client.lua',
--    }
--    server_scripts {
--        'server.lua',
--    }
--
--  After adding this file, remove the local Config = { ... } blocks
--  from both client.lua and server.lua — Config is now global and
--  shared automatically by the shared_script manifest entry.
--
-- ================================================================

Config = {}

-- ════════════════════════════════════════════════════════════════
--  LOCATIONS
--  All world positions used by the mission.
--  npcPos  — where the quest giver / fence NPC stands.
--            This same NPC handles both starting the robbery and
--            fencing the stolen lockbox afterwards.
--  spawnPos — where the armored wagon and its escort spawn.
--  loftPos  — the wagon's destination. If it reaches within
--             Config.wagonDestProximity of this point the player
--             fails the mission.
-- ════════════════════════════════════════════════════════════════
Config.npcPos  = vector3(1433.2, 1332.1, 182.4)
Config.spawnPos = vector3(1106.3, 1378.5, 178.5)
Config.loftPos  = vector3(1131.2, 2372.9, 258.0)

-- ════════════════════════════════════════════════════════════════
--  MODELS
--  All ped and vehicle model strings used by the mission.
--  Change these to swap out visuals without touching script logic.
-- ════════════════════════════════════════════════════════════════
Config.starterNpcModel = "u_m_m_valcrimereader_01"  -- Quest giver / Fence NPC
Config.guardModel      = "s_m_m_pinkerton_01"        -- Driver, shooter, escorts, reinforcements
Config.wagonModel      = "wagonarmoured01x"           -- Armored stagecoach
Config.horseModel      = "a_c_horse_turkoman_gold"   -- Escort and reinforcement mounts

-- Heading the starter NPC faces when spawned (degrees, 180 = south)
Config.starterNpcHeading = 180.0

-- Heading the wagon faces when spawned (degrees, 90 = east)
Config.wagonHeading = 90.0

-- ════════════════════════════════════════════════════════════════
--  ITEMS
--  vorp_inventory item names. Must match your items.json exactly.
-- ════════════════════════════════════════════════════════════════
Config.dynamiteItem = "dynamite"       -- Consumed when blowing the wagon door
Config.lockboxItem  = "stolen_lockbox" -- Granted on successful blow, fenced for payout

-- ════════════════════════════════════════════════════════════════
--  ECONOMY  (server-side)
--  cooldownMinutes — how long a player must wait between attempts.
--  payoutMin/Max   — cash range paid by the fence (math.random).
--  watchdogMinutes — server auto-releases missionActive if the
--                    client crashes and never fires endMissionServer.
--  wantedPoints    — bounty added via vorp_wanted on mission start.
-- ════════════════════════════════════════════════════════════════
Config.cooldownMinutes  = 60
Config.payoutMin        = 800
Config.payoutMax        = 1200
Config.watchdogMinutes  = 20
Config.wantedPoints     = 20
Config.wantedReason     = "Stagecoach Robbery"

-- ════════════════════════════════════════════════════════════════
--  TIMING  (milliseconds unless noted)
--  missionTimeout     — total time allowed before auto-fail.
--  missionLoopMs      — main mission thread tick rate.
--  lootPollMs         — how often the client RPCs robbery:hasLockbox
--                       when standing near the NPC.
--  plantAnimMs        — WORLD_HUMAN_CROUCH_INSPECT animation length.
--  fuseBurnMs         — delay between animation end and explosion.
--  postExplosionMs    — delay between explosion and lockbox grant
--                       (lets the VFX settle).
-- ════════════════════════════════════════════════════════════════
Config.missionTimeout  = 15 * 60 * 1000   -- 15 minutes
Config.missionLoopMs   = 500
Config.lootPollMs      = 2000
Config.plantAnimMs     = 4000
Config.fuseBurnMs      = 3500
Config.postExplosionMs = 500

-- ════════════════════════════════════════════════════════════════
--  AI / COMBAT
--  escortCount         — mounted guards that ride alongside the wagon.
--  reinforcementCount  — guards spawned behind the player when all
--                        escorts are killed.
--  guardAccuracy       — SetPedAccuracy value (0–100).
--  guardWeapon         — weapon hash string given to all guards.
--  guardAmmo           — ammo count given with the weapon.
--  wagonSpeedNormal    — wagon drive speed before taking damage.
--  wagonSpeedAlarmed   — wagon drive speed after taking any damage.
--  drivingStyle        — TaskVehicleDriveToCoord flag bitfield.
--                        786603 = stop for vehicles + peds, avoid
--                        traffic, keep lane. Standard for RDR2 NPCs.
-- ════════════════════════════════════════════════════════════════
Config.escortCount        = 5
Config.reinforcementCount = 3
Config.guardAccuracy      = 65
Config.guardWeapon        = "WEAPON_RIFLE_CARCANO"
Config.guardAmmo          = 999
Config.wagonSpeedNormal   = 5.0
Config.wagonSpeedAlarmed  = 12.0
Config.drivingStyle       = 786603

-- Escort spawn layout relative to Config.spawnPos
-- escortSpreadStep   — x-axis spacing between each escort horse
-- escortSpreadOffset — x-axis base shift to centre the escort line
--                      (default: -(escortCount * escortSpreadStep / 2) = -10)
-- escortYOffset      — how far behind the wagon the escorts form up
Config.escortSpreadStep   = 4.0
Config.escortSpreadOffset = -10.0
Config.escortYOffset      = -8.0

-- Reinforcement spawn offsets relative to the player
-- reinforcementLateral — left/right stagger distance (alternating each spawn)
-- reinforcementBase    — how far directly behind the player they start
-- reinforcementStep    — additional rearward spacing per spawn index
Config.reinforcementLateral = 10.0
Config.reinforcementBase    = -80.0
Config.reinforcementStep    = -15.0

-- ════════════════════════════════════════════════════════════════
--  INTERACTION RANGES
--  npcActiveRange   — within this range the thread switches from
--                     1000ms sleep to 0ms (full resolution).
--  npcInteractRange — within this range prompts are shown.
--  doorProximity    — how close the player must be to the wagon's
--                     rear door to see the dynamite prompt.
--  wagonDestProximity — wagon within this distance of loftPos = fail.
--  wagonDoorOffset  — local offset from wagon origin to rear door.
-- ════════════════════════════════════════════════════════════════
Config.npcActiveRange      = 50.0
Config.npcInteractRange    = 3.0
Config.doorProximity       = 3.0
Config.wagonDestProximity  = 20.0
Config.wagonDoorOffset     = vector3(0.0, -3.5, 0.0)

-- ════════════════════════════════════════════════════════════════
--  EXPLOSION
--  explosionType         — RDR2 explosion enum. 0 = default/generic.
--                          Do NOT use 1 — that is the GTA5 grenade
--                          enum and is invalid in RedM.
--  explosionScale        — blast radius scalar.
--  explosionHeightOffset — Z lift above coords before detonating,
--                          keeps the blast above ground level.
--  explosionCamShake     — camera shake intensity passed to AddExplosion.
-- ════════════════════════════════════════════════════════════════
Config.explosionType         = 0
Config.explosionScale        = 1.5
Config.explosionHeightOffset = 0.5
Config.explosionCamShake     = 1.8

-- ════════════════════════════════════════════════════════════════
--  PROMPTS
--  Text shown on each hold-prompt and its group label.
--  Changing these requires no logic changes — purely cosmetic.
-- ════════════════════════════════════════════════════════════════
Config.promptTextStart    = "Start Stagecoach Robbery"
Config.promptTextFence    = "Sell Stolen Goods"
Config.promptTextDynamite = "Plant Dynamite"

Config.promptGroupRobbery = "Robbery"
Config.promptGroupFence   = "Fence"
Config.promptGroupWagon   = "Armored Wagon"

-- ════════════════════════════════════════════════════════════════
--  NOTIFICATIONS
--  All user-facing messages in one place.
--  Duration values are in milliseconds.
-- ════════════════════════════════════════════════════════════════
Config.notify = {
    -- Mission flow
    missionStart       = { msg = "Go stop the armored stagecoach!",        dur = 8000 },
    reinforcements     = { msg = "Lawmen reinforcements incoming!",         dur = 5000 },
    noDynamite         = { msg = "You need Dynamite!",                     dur = 4000 },
    lockboxSecured     = { msg = "Lockbox secured! Head to the fence.",     dur = 6000 },
    lockboxCleanup     = { msg = "Lockbox secured! Return to the fence.",   dur = 6000 },

    -- Failures
    failUnexpected     = { msg = "Mission ended unexpectedly.",             dur = 5000 },
    failTimeout        = { msg = "Mission timed out.",                      dur = 5000 },
    failWagonEscaped   = { msg = "Failed: The wagon reached safety!",       dur = 5000 },
    failPlayerDied     = { msg = "Failed: You died.",                       dur = 5000 },

    -- Generic fallback (RPC error)
    genericError       = { msg = "Something went wrong.",                   dur = 5000 },
}
