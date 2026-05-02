---@diagnostic disable: undefined-global

Config = {}

-- ─── Dev / Debug ──────────────────────────────────────────────────────────────
Config.Debug = false   -- Set true to enable server-side debug prints

-- ─── Mission Gating ───────────────────────────────────────────────────────────
-- Item that must be in inventory to start the mission (1 unit is consumed on start)
Config.RequiredItem    = 'dynamite'

-- Global cooldown in SECONDS after a mission completes or is cleaned up (1 hr)
Config.GlobalCooldown  = 3600

-- Seconds before a partially-running mission is force-cleaned if the activating
-- player does nothing (anti-grief / server-restart safety net)
Config.MissionTimeout  = 600

-- Delay in MS after mission COMPLETE before all spawned entities are deleted
Config.CleanupDelay    = 300000   -- 5 minutes

-- ─── Starter NPC ──────────────────────────────────────────────────────────────
-- The static, invincible mission-start ped near the Tesla Tower (Roanoke Ridge).
-- Hold E within 5 m to begin. Matching outsider_grave_robbery's proximity pattern.
--
-- Tesla Tower (Roanoke Ridge, New Hanover) is approx. (2362, -666, 155).
-- !! VERIFY IN-GAME and adjust coords to put the ped on solid ground beside it !!
Config.StarterPed = {
    model  = `U_M_M_RnkExp_01`,                      -- Scientist/ranger type – VERIFY
    coords = vector4(2362.4, -666.5, 155.3, 246.0),  -- VERIFY IN-GAME
}

-- How close (metres) the player must be to see / interact with the starter ped
Config.PedTriggerDist  = 5.0

-- ─── Prompt Key ───────────────────────────────────────────────────────────────
-- INPUT_CONTEXT = the standard RedM "E" interaction key
Config.PromptKey = 0x760A9C6F

-- ─── syn_minigame Parameters ─────────────────────────────────────────────────
-- Used for the dynamite-placement interaction (replaces a plain hold-E progress bar
-- with the proper skill-check minigame used by outsider / bcc scripts).
-- taskBar(difficulty, skillGap)
--   difficulty : higher = bar moves faster / harder.  ~5000 = medium-hard.
--   skillGap   : width of the "good zone".  7 = moderate, lower = harder.
Config.Minigame = {
    difficulty = 5000,
    skillGap   = 7,
}

-- ─── Wagon ────────────────────────────────────────────────────────────────────
-- Spawn: road just outside Fort Wallace (New Hanover) – VERIFY IN-GAME
-- Dest : The Loft (Heartlands, New Hanover)            – VERIFY IN-GAME
Config.WagonModel = `security_wagon`     -- VERIFY – should be the armoured variant
Config.WagonSpawn = vector4(2676.0, -1205.0, 44.8, 175.0)   -- VERIFY
Config.WagonDest  = vector3(476.0,  416.0,  111.0)           -- VERIFY

Config.WagonSpeed     = 12.0      -- m/s
-- 786603 = DRIVINGMODE_NORMAL (uses roads, avoids peds, no off-road shortcuts)
Config.WagonDriveMode = 786603

-- How close to the wagon the player must be for wagon-stage prompts
Config.WagonTriggerDist = 5.0

-- ─── Driver NPC ───────────────────────────────────────────────────────────────
Config.DriverModel = `U_M_M_BlwSciExp_01`   -- VERIFY

-- ─── Gatling Gunner ───────────────────────────────────────────────────────────
Config.GunnerModel  = `G_M_M_SpecOps_01`    -- VERIFY
Config.GunnerWeapon = `WEAPON_MINIGUN`
-- Vehicle seat index: -1=driver, 0=front passenger/turret, 1+ = rear
Config.GunnerSeat   = 0

-- ─── Mounted Guards (5 escorts) ──────────────────────────────────────────────
Config.GuardModel  = `G_M_M_SpecOps_01`             -- VERIFY
Config.GuardHorse  = `a_c_horse_morgan_flaxenchestnut` -- VERIFY
Config.GuardWeapon = `WEAPON_REVOLVER_CATTLEMAN`

-- World positions for 5 mounted guards, scattered around the wagon spawn.
-- VERIFY IN-GAME – must be on or very near the road.
Config.GuardSpawns = {
    vector4(2671.0, -1200.0, 44.8, 175.0),
    vector4(2674.0, -1197.0, 44.8, 175.0),
    vector4(2678.0, -1194.0, 44.8, 175.0),
    vector4(2682.0, -1200.0, 44.8, 175.0),
    vector4(2685.0, -1197.0, 44.8, 175.0),
}

-- ─── Reinforcements (10 riders) ──────────────────────────────────────────────
Config.ReinfCount        = 10
Config.ReinfModel        = `G_M_M_SpecOps_01`             -- VERIFY
Config.ReinfHorse        = `a_c_horse_morgan_flaxenchestnut` -- VERIFY
Config.ReinfWeapon       = `WEAPON_REVOLVER_SCHOFIELD`

-- Spawn point ~300 m from The Loft on the nearest road. VERIFY IN-GAME.
Config.ReinfSpawn        = vector4(780.0, 420.0, 112.0, 270.0)

-- How often (ms) the activating client re-issues the "ride toward player" task
-- for reinforcements (keeps them tracking a moving player)
Config.ReinfUpdateMs     = 6000

-- ─── NPC Combat Stats ────────────────────────────────────────────────────────
-- Matching the high-stat "professional" guards used by bcc-robbery & bcc-legendaries
Config.NpcAccuracy      = 75   -- 0–100
Config.NpcCombatAbility = 2    -- 0=poor 1=average 2=professional
Config.NpcBonusHealth   = 150  -- Added onto default NPC health pool
Config.NpcArmour        = 100

-- ─── Dynamite Fuse ────────────────────────────────────────────────────────────
Config.DynamiteFuseMs = 10000  -- 10 seconds from placement to explosion

-- ─── Reward ───────────────────────────────────────────────────────────────────
Config.CashReward = 300        -- $300 cash (addCurrency type 0)

-- ─── Blip (activating player only) ───────────────────────────────────────────
Config.Blip = {
    sprite = -1117567375,   -- wagon blip sprite
    scale  = 0.8,
    color  = 1,             -- red
    label  = 'Armoured Wagon',
}

-- ─── Job Alerts ───────────────────────────────────────────────────────────────
-- Mirrors outsider_grave_robbery's job-alert pattern exactly.
Config.JobsToAlert = { 'sheriff', 'marshall' }

-- Set true if outsider_jobalerts resource is installed on your server.
Config.UseOutsiderJobAlerts = false
Config.OutsiderJobAlertCmd  = 'wagonrobbery'  -- command registered in outsider_jobalerts

-- ─── Texts ────────────────────────────────────────────────────────────────────
Config.Texts = {
    -- Starter ped prompt (what the player sees on the hold-E circle)
    StartPrompt         = 'Armoured Wagon Robbery',

    -- Notification shown to the activating player on mission begin
    MissionStarted      = 'Armoured Wagon Robbery Mission Has Began',

    -- Rejection messages
    NeedDynamite        = 'You need dynamite in your inventory to start this mission.',
    MissionAlreadyActive= 'An armoured wagon robbery is already in progress.',
    OnCooldown          = 'The armoured wagon is not available right now. Try again later.',

    -- In-mission guidance
    KillGuards          = 'Eliminate all guards to approach the wagon.',
    AllGuardsDead       = 'Guards eliminated! Approach the wagon to place dynamite.',
    PlaceDynamitePrompt = 'Place Dynamite',
    DynamitePlaced      = 'Dynamite placed! Get back!',
    FuseWarning         = 'Detonating in 10 seconds!',
    WagonExploded       = 'The wagon has been blown open! Reinforcements are incoming!',
    ReinfsDead          = 'Reinforcements down! Loot the wagon.',
    LootPrompt          = 'Loot Strongbox',
    MissionComplete     = 'Mission complete! You have been paid $300.',
    MissionFailed       = 'Mission failed.',
    MinigameFailed      = 'You failed to place the dynamite.',
}

-- ─── Textures (notification icons) ───────────────────────────────────────────
-- Matches outsider_grave_robbery Config.Textures pattern
Config.Textures = {
    alert = { 'generic_textures', 'temp_pedshot' },
}
