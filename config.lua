Config = {}

-- How long (minutes) before the same robbery location respawns after completion
Config.CooldownMinutes = 15

-- How long (seconds) before an abandoned robbery auto-cancels (player walked away, died, etc.)
Config.RobberyTimeout = 120

-- Distance (units) within which a player can see the prompt to rob
Config.TriggerDistance = 10.0

-- Distance (units) the server validates the player must be within before allowing robbery start
-- Kept tighter than TriggerDistance to prevent position exploits
Config.MaxRobDistance = 15.0

-- How long the lockpick / loot progress bar runs (ms)
Config.LootDuration = 8000

-- Required item to start the robbery (set to nil to require nothing)
Config.RequiredItem = 'lockpick'

-- Prompt key binding
Config.PromptKey = 0x760A9C6F -- INPUT_CONTEXT

-- Wagon model hash to spawn (stagecoach)
Config.WagonModel = `stagecoach`

-- Guard ped model hash
Config.GuardModel = `A_M_M_RanchWorker01`

-- Guard weapon hash
Config.GuardWeapon = `WEAPON_REVOLVER_CATTLEMAN`

-- Blip shown on map when wagon is active
Config.ActiveBlip = {
    sprite  = -1117567375, -- wagon blip sprite
    color   = 1,           -- red
    scale   = 0.8,
    label   = 'Wagon Robbery',
}

-- Job alerts – which jobs get notified when a robbery starts
Config.JobsToAlert = { 'sheriff', 'marshall' }

-- Whether to use the outsider_jobalerts resource for job notifications
Config.UseOutsiderJobAlerts = false
Config.OutsiderJobAlertCommand = 'wagonrobbery'

-- Loot table: each entry rolls separately. 'chance' is 0.0–1.0
Config.Loot = {
    { item = 'goldnugget',  amount = 2, chance = 0.6,  label = 'Gold Nugget' },
    { item = 'money',       amount = 50, chance = 0.8, label = 'Cash' },
    { item = 'whiskey',     amount = 1, chance = 0.4,  label = 'Whiskey' },
    { item = 'ammo_rifle',  amount = 20, chance = 0.3, label = 'Rifle Ammo' },
}

-- Robbery encounter locations
-- coords  = where the wagon spawns (vector4: x,y,z,heading)
-- guards  = table of guard spawn positions relative to wagon (or world coords)
-- town    = district name shown in job alerts
Config.Encounters = {
    {
        id      = 1,
        name    = 'Flat Iron Lake Road',
        town    = 'Blackwater',
        coords  = vector4(-862.35, -1280.22, 43.85, 270.0),
        guards  = {
            vector4(-855.0, -1280.22, 43.85, 90.0),
            vector4(-870.0, -1278.0,  43.85, 80.0),
        },
    },
    {
        id      = 2,
        name    = 'Flat Neck Station Road',
        town    = 'Valentine',
        coords  = vector4(-289.47, 774.2, 117.38, 130.0),
        guards  = {
            vector4(-283.0, 780.0, 117.38, 310.0),
            vector4(-296.0, 769.0, 117.38, 130.0),
        },
    },
}

-- Notification textures (used with VorpCore left-tip notifications)
Config.Textures = {
    alert = { 'generic_textures', 'hud_corner' },
}

Config.Texts = {
    Prompt          = 'Rob Wagon',
    TooFar          = 'You are too far from the wagon.',
    AlreadyRobbed   = 'This wagon has already been robbed.',
    InProgress      = 'Someone else is already robbing this wagon.',
    NoItem          = 'You need a lockpick to rob this wagon.',
    RobberyStart    = 'You begin breaking into the strongbox...',
    RobberySuccess  = 'You loot the wagon!',
    RobberyFail     = 'The robbery failed.',
    FoundItem       = 'You found',
    NothingFound    = 'The strongbox was empty.',
    GuardsAlert     = 'A wagon robbery has been reported!',
}
