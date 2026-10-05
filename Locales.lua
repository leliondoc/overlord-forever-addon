-- Locales.lua: Localisation automatique (EN/FR/ES/DE/RU selon le client)
-- Détection via GetLocale() au chargement de l'addon.
Overlord = Overlord or {}
local L = {}
Overlord.L = L
L.OUTPOST_SILVERPINE_NAME = "Savix Chapel"

function Overlord.IsFrenchLocale()
    local loc = GetLocale() or "enUS"
    return loc == "frFR" or loc:sub(1, 2) == "fr"
end

function Overlord.IsSpanishLocale()
    local loc = GetLocale() or "enUS"
    return loc == "esES" or loc == "esMX" or loc:sub(1, 2) == "es"
end

function Overlord.IsGermanLocale()
    local loc = GetLocale() or "enUS"
    return loc == "deDE" or loc:sub(1, 2) == "de"
end

function Overlord.IsRussianLocale()
    local loc = GetLocale() or "enUS"
    return loc == "ruRU" or loc:sub(1, 2) == "ru"
end

function Overlord.IsPortugueseLocale()
    return (GetLocale() or "enUS") == "ptBR"
end

function Overlord.IsChineseLocale()
    return (GetLocale() or "enUS") == "zhCN"
end

function Overlord.UsesCommaDecimalLocale()
    return Overlord.IsFrenchLocale() or Overlord.IsSpanishLocale() or Overlord.IsGermanLocale()
        or Overlord.IsRussianLocale() or Overlord.IsPortugueseLocale()
end

-- ================================================================
-- ANGLAIS
-- ================================================================

-- Noms des zones
L.ZONE_NAMES = {
    stromgarde = "Stromgarde Keep",
    faldir     = "Faldir's Cove",
    witherbark = "Witherbark Village",
    goshek     = "Go'Shek Farm",
    dabyrie    = "Dabyrie's Farmstead",
    refuge     = "Refuge Pointe",
    highperch  = "Western Highlands",
    newstead   = "Thoradin’s Wall",
    hammerfell = "Hammerfall",
    argorok    = "Circle of West Binding",
    loch_alliance_capital = "Thelsamar",
    loch_horde_capital = "Mo'grosh Stronghold",
    loch_valley_of_kings = "Valley of Kings",
    loch_south_gate_pass = "South Gate Pass",
    loch_silver_stream_mine = "Silver Stream Mine",
    loch_algaz_post = "Algaz Post",
    loch_farstrider_lodge = "Farstrider Lodge",
    loch_ironband = "Ironband's Excavation Site",
    loch_the_loch = "The Loch",
    loch_stonewrought_dam = "Stonewrought Dam",
    durotar_tiragarde_keep = "Tiragarde Keep",
    durotar_alliance_fleet = "Kolkar Crag",
    durotar_senjin_village = "Sen'jin Village",
    durotar_razor_hill = "Razor Hill",
    durotar_deadeye_shore = "Deadeye Shore",
    durotar_southfury = "Southfury River",
    durotar_spirit_rock = "Valley of Trials",
    durotar_thunder_ridge = "Thunder Ridge",
    durotar_drygulch_ravine = "Drygulch Ravine",
    durotar_dranosh_blockade = "Orgrimmar Approach",
    elwynn_westbrook = "Westbrook Garrison",
    elwynn_goldshire = "Goldshire",
    elwynn_tower_of_azora = "Tower of Azora",
    elwynn_ridgepoint = "Ridgepoint Tower",
    elwynn_mirror_lake = "Crystal Lake",
    elwynn_fargodeep = "Fargodeep Mine",
    elwynn_jerods_landing = "Jerod's Landing",
    elwynn_stone_cairn = "Stone Cairn Lake",
    elwynn_eastvale = "Eastvale Logging Camp",
    elwynn_invasion_camp = "Blackrock Advance",
    ash_astranaar = "Astranaar",
    ash_iris_lake = "Iris Lake",
    ash_raynewood = "Raynewood Retreat",
    ash_night_run = "Night Run",
    ash_bloodtooth_camp = "Bloodtooth Camp",
    ash_silverwind = "Silverwind Refuge",
    ash_mystral_lake = "Mystral Lake",
    ash_fallen_sky_lake = "Fallen Sky Lake",
    ash_dor_danil = "Dor'Danil Barrow Den",
    ash_splintertree = "Splintertree Post",
}

L.FRONT_ARATHI_NAME = "Arathi Highlands"
L.FRONT_LOCH_MODAN_NAME = "Loch Modan"
L.FRONT_DUROTAR_NAME = "Durotar"
L.FRONT_ELWYNN_NAME = "Elwynn Forest"
-- Libelle court pour le menu front (bouton): mapName reste le nom complet pour alertes / carte.
L.FRONT_ARATHI_DROPDOWN = "Arathi"
L.FRONT_LOCH_MODAN_DROPDOWN = "Loch Modan"
L.FRONT_DUROTAR_DROPDOWN = "Durotar"
L.FRONT_ELWYNN_DROPDOWN = "Elwynn"
L.FRONT_ASHENVALE_NAME = "Ashenvale"
L.FRONT_ASHENVALE_DROPDOWN = "Ashenvale"
-- Sous-zone puis région du front pour les alertes (ex. « Poste d'Algaz (Loch Modan) »)
L.CAPTURE_ALERT_SUBZONE_IN_REGION = "%s (%s)"

-- Factions (forme narrative pour les messages)
L.THE_HORDE    = "the Horde"
L.THE_ALLIANCE = "the Alliance"

-- Factions majuscules (victoire totale)
L.VICTORY_FACTION_HORDE    = "THE HORDE"
L.VICTORY_FACTION_ALLIANCE = "THE ALLIANCE"

-- Format de date
L.DATE_FORMAT = "%m/%d/%Y"

-- === Core ===
L.WEEKLY_RESET   = "New week! Campaign has been reset on the US beta schedule."
L.MODULE_ERROR   = "Error module %s: %s"
L.ADDON_LOADED   = "v%s loaded. |cFFFFFF00/ov help|r for commands."
L.SYNC_LOGIN_WAIT = "Synchronizing zone data... Map will update shortly."
L.ALL_ZONES_RESET = "All zones have been reset!"
L.FRONT_CAPITAL_RELEASED = "%s: truce over. The conquest holds and the fallen capital rises again; both capitals are protected until %s."
L.CAPITAL_PROTECTED_UNTIL = "Protected until %s"
L.CAPITAL_PROTECTED_SHORT = "Until %s"

-- === Commands ===
L.HELP_HEADER   = "|cFF00FF00========== Overlord: Commands ==========|r"
L.HELP_SHOW     = "|cFFFFFF00/ov show|r: Show the interface"
L.HELP_HIDE     = "|cFFFFFF00/ov hide|r: Hide the interface"
L.HELP_TOGGLE   = "|cFFFFFF00/ov toggle|r: Toggle the interface"
L.HELP_HUD      = "|cFFFFFF00/ov hud [auto|on|off|toggle]|r: Set top HUD visibility"
L.HUD_SHOWN     = "|cFF00FF00[Overlord]|r Top HUD enabled."
L.HUD_HIDDEN    = "|cFF00FF00[Overlord]|r Top HUD disabled."
L.HUD_AUTO      = "|cFF00FF00[Overlord]|r Top HUD set to Auto."
L.HELP_STATUS   = "|cFFFFFF00/ov status|r: Show zone status"
L.HELP_ZONES    = "|cFFFFFF00/ov zones|r: Show available zones with coordinates"
L.HELP_WHERE    = "|cFFFFFF00/ov where|r: Toggle zone indicator"
L.HELP_START    = "|cFFFFFF00/ov start <zone>|r: Start capturing a zone"
L.HELP_LB       = "|cFFFFFF00/ov lb|r: Show the leaderboard"
L.HELP_SYNC     = "|cFFFFFF00/ov sync [PlayerName-Realm]|r: Request sync (target whisper or group/raid/community)"
L.HELP_DOM      = "|cFFFFFF00/ov dom|r: Weekly domination bar debug (front victories, display %)"
L.HELP_SCALE    = "|cFFFFFF00/ov scale [0.8-1.2]|r: Panel UI scale (also: Esc > Options > AddOns > Overlord)"
L.DOM_DEBUG_HEADER = "Weekly domination:"
L.DOM_DEBUG_COUNTS = "A: %d victories / H: %d victories | bar: %s / %s"
L.HELP_GUIDE    = "|cFFFFFF00/ov guide|r: Quick visual guide"
L.HELP_FOOTER   = "|cFF00FF00=============================================|r"

L.STATUS_HEADER      = "|cFF00FF00========== Overlord: Status ==========|r"
L.STATUS_IN_PROGRESS = "IN PROGRESS (%d:%02d hold)"
L.STATUS_AVAILABLE   = "AVAILABLE"
L.STATUS_LOCKED      = "LOCKED"
L.STATUS_TOTAL       = "Total: %d/%d zones (%d%%)"
L.STATUS_FOOTER      = "|cFF00FF00=============================================|r"

L.NOT_INITIALIZED  = "Addon is not yet initialized."
L.USAGE_START      = "Usage: /ov start <zone>"
L.ZONE_UNKNOWN     = "Unknown zone: %s"
L.ZONE_NOT_AVAILABLE = "%s is not available!"
L.MUST_BE_IN_ZONE  = "You must be in %s to start the capture! (%.1f, %.1f)"
L.UNKNOWN_COMMAND  = "Unknown command: %s"
L.HELP_HINT        = "Type /ov help to see available commands."
L.POS_RESET        = "Panel position has been reset."

-- === UI ===
L.CONTROL_ZONES     = "CONTROL ZONES"
L.ACTIVE_ZONE       = "ACTIVE ZONE"
L.NO_ACTIVE_ZONE    = "No active zone"
L.HOLD_LABEL        = "Hold"
L.UI_CONTESTED      = "CONTESTED"
L.UI_PAUSED         = "PAUSED: outside zone, timer decaying"
L.UI_IN_PROGRESS    = "IN PROGRESS: hold the position"
L.UI_ENEMY_CAPTURING = "ENEMY CAPTURING: contest the zone!"
L.UI_COMPLETE       = "COMPLETE"
L.ACTION_SHORTCUT_LABEL = "Action bar shortcut"
L.ACTION_SHORTCUT_TOOLTIP = "Puts the Overlord icon on your cursor: click an action bar slot to drop it there."
L.ACTION_SHORTCUT_COMBAT = "The action bar shortcut cannot be created during combat."
L.ACTION_SHORTCUT_FAILED = "Unable to create or pick up the shortcut. Make sure you are out of combat, then try again."
L.UI_SCALE_LABEL    = "Panel scale"
L.UI_SCALE_TOOLTIP  = "Size of the main panel and leaderboard. You can also use |cffffffff/ov scale|r."
L.NOTIFICATION_CHAT_LABEL = "Overlord messages"
L.NOTIFICATION_CHAT_TOOLTIP = "Chat tab where Overlord alerts and messages appear."
L.NOTIFICATION_CHAT_DEFAULT = "Main chat (default)"
L.CHAT_TAB_LABEL = "Overlord chat tab"
L.CHAT_TAB_BUTTON = "Create tab"
L.CHAT_TAB_TOOLTIP = "Creates a chat tab named Overlord and sends Overlord messages there. Move, hide or close it like any other tab."
L.CHAT_TAB_READY = "Overlord messages now appear in this tab."
L.CHAT_TAB_FAILED = "No free chat tab. Close one, then try again."
L.ACTION_SHORTCUT_BUTTON = "Pick up"
L.SETTINGS_SECTION_GENERAL = "General"
L.SETTINGS_SECTION_CHAT = "Chat"
L.SETTINGS_SECTION_MAP = "Map and minimap"
L.SETTINGS_SECTION_HUD = "On-screen panels"
L.UI_FRONT_SELECT = "Battlefront (list)"
L.UI_FRONT_PICKER_TOOLTIP = "Choose which zone list to show. Your capture timer and combat still follow the map where you are fighting."
L.UI_FRONT_READONLY_TOOLTIP = "You are viewing another front or you are not on a war zone. Clicks do not start captures; waypoints use the selected front map."
L.UI_CAPTURE_READONLY = "Read-only: go to this front in the open world to capture from this list."
L.MAP_OVERLAY_OPACITY_LABEL   = "Map capture opacity"
L.MAP_OVERLAY_OPACITY_TOOLTIP = "Transparency of capture zone circles on the |cffffffffworld map|r only. Lower values reveal more map detail underneath.\nDoes not affect the minimap (see Minimap capture opacity) or coin mine circles."
L.MINIMAP_OVERLAY_OPACITY_LABEL   = "Minimap capture opacity"
L.MINIMAP_OVERLAY_OPACITY_TOOLTIP = "Transparency of capture zone circles on the |cffffffffminimap|r. Lower values reveal more map detail underneath.\nDoes not affect the world map, guild keep icons, or coin mine circles."
L.MAP_ICON_OPACITY_LABEL = "Map icon opacity"
L.MAP_ICON_OPACITY_TOOLTIP = "Transparency of capture point, fortress and outpost icons on the |cffffffffworld map|r. Lower values keep quest markers in towns readable. Set to 0 to hide them."
L.MAP_ICON_SCALE_LABEL = "Map icon size"
L.MAP_ICON_SCALE_TOOLTIP = "Size of capital, capture point, fortress and outpost icons on the |cffffffffworld map|r."
L.MINIMAP_BUTTON_LABEL          = "Minimap button"
L.MINIMAP_BUTTON_TOOLTIP        = "Shows the Overlord button around the minimap. Enable this to bring the button back; minimap button managers may collect it into their own menu."
L.MINIMAP_CAPTURE_ZONES_LABEL   = "Minimap icons"
L.MINIMAP_CAPTURE_ZONES_TOOLTIP = "Show Overlord's icons on the |cffffffffminimap|r: capture circles, generals, mines, guild keeps and outposts. Mouse hover passes through to hunter and food tracking dots. Turn off to hide them all (the world map keeps its own settings)."
L.MAP_ZONE_TITLES_LABEL         = "Map zone names"
L.MAP_ZONE_TITLES_TOOLTIP       = "Show the parchment name banners on capture zones and coin mines on the |cffffffffworld map|r. Turn off for a cleaner map if you already know the areas."
L.MAP_PATH_OPACITY_LABEL      = "Map path opacity"
L.MAP_PATH_OPACITY_TOOLTIP    = "Opacity of the |cffffffffdotted lines|r between capture zones on the world map (1 = faint, 3 = very visible)."
L.SETTINGS_TOGGLE_ON          = "Enabled"
L.SETTINGS_TOGGLE_OFF         = "Disabled"
L.AUTO_WAYPOINT_LABEL         = "Automatic objective pin"
L.AUTO_WAYPOINT_TOOLTIP       = "Places the Blizzard map pin on the next available objective. If you remove or replace that pin, Overlord waits for a new objective before placing it again. The pin is removed when the objective is no longer valid."
L.SHOW_TOP_HUD_LABEL          = "Top HUD"
L.SHOW_TOP_HUD_TOOLTIP        = "Auto shows relevant panels near captures, mines and guild keeps. Always shows them throughout eligible maps; Never hides them. The next objective indicator remains available."
L.TOP_HUD_MODE_AUTO           = "Auto"
L.TOP_HUD_MODE_ALWAYS         = "Always"
L.TOP_HUD_MODE_NEVER          = "Never"
L.SHOW_TUTORIAL_BOOK_LABEL    = "Tutorial book icon"
L.SHOW_TUTORIAL_BOOK_TOOLTIP  = "Shows the tutorial book icon on the top HUD. Turn off to hide only that icon while keeping the coins and guild keep panels."
L.SOUND_ENABLED_LABEL         = "Overlord sounds"
L.SOUND_ENABLED_TOOLTIP       = "Mute all sounds from Overlord (alerts, war horn, captures, panels, coin buff, general duel music, etc.)."
L.SETTINGS_BUTTON             = "Settings"
L.LAYER_JUMPER_BUTTON = "Layer Jumper"
L.NET_HEALTH_TITLE = "Overlord network"
L.NET_HEALTH_OK = "All good"
L.NET_HEALTH_WARN = "Worth watching"
L.NET_HEALTH_BAD = "Problem"
L.NET_HEALTH_HINT = "Type /ov network for details."
L.MW_ALERT = "Most Wanted nearby: %s (#%d %s, %d kills this week)!"
L.HELP_WANTED = "|cFFFFFF00/ov wanted [on|off]|r: Most Wanted: alert when a top-5 enemy is nearby"
L.MW_STATE_ON = "Most Wanted alerts: on"
L.MW_STATE_OFF = "Most Wanted alerts: off"
L.LAYER_JUMPER_TOOLTIP = "Change layer in your zone"
L.HELP_LAYER = "|cFFFFFF00/ov layer [help on|off]|r: Layer Jumper (change layer; volunteer to help others)"
L.LJ_TITLE = "Layer Jumper"
L.LJ_ZONE_LAYER = "%s - your layer: %s"
L.LJ_LAYER_UNKNOWN = "unknown"
L.LJ_LAYER_NAME = "Layer #%s"
L.LJ_HELPERS = "%d helper(s)"
L.LJ_HERE = "you are here"
L.LJ_JOIN = "Join"
L.LJ_SEARCH = "Search"
L.LJ_RANDOM = "Change layer"
L.LJ_RANDOM_TOOLTIP = "Jump to any other layer of this zone (searches first if needed)."
L.LJ_CANCEL = "Cancel"
L.LJ_LIST_EMPTY = "Target an NPC to read your layer, then click Search to list the layers of this zone."
L.LJ_HELP_MODE = "Help others: %s"
L.LJ_HELP_MODE_AUTO = "on"
L.LJ_HELP_MODE_OFF = "off"
L.LJ_HELP_MODE_TOOLTIP = "Volunteer helper (off by default). When on, an Overlord player of your faction who searches for your layer gets an automatic invite from you, with no popup; they leave the group once switched. Only while you are alone, out of combat and instances."
L.LJ_EXPLAIN = "A volunteer helper on the chosen layer invites you to a group. Out of combat, the game moves you to their layer within a few seconds, then you leave the group automatically. Only your zone and layer are shared, never your position."
L.LJ_STATUS_IDLE = "Search for helpers in your zone."
L.LJ_STATUS_SEARCHING = "Searching for helpers in %s..."
L.LJ_STATUS_READY = "%d helper(s) found."
L.LJ_STATUS_NONE = "No volunteer helper available in this zone right now. Try again in a moment or in a busier zone."
L.LJ_STATUS_REQUESTING = "Asking %s for an invite..."
L.LJ_STATUS_JOINING = "Invite accepted, joining %s's group..."
L.LJ_STATUS_VERIFYING = "Switching layer... (%ds)"
L.LJ_STATUS_VERIFY_COMBAT = "In combat: the switch waits for the end of combat (%ds)."
L.LJ_STATUS_SUCCESS = "Done: you are now on %s."
L.LJ_STATUS_UNCONFIRMED = "Left the group; the new layer could not be confirmed (no NPC in sight)."
L.LJ_STATUS_CROWDED = "Left the group: the helper brought other players in."
L.LJ_STATUS_FAILED = "No helper invited you. Try again in a moment."
L.LJ_STATUS_CANCELLED = "Cancelled."
L.LJ_ERR_GROUPED = "Leave your group first: the helper must invite you."
L.LJ_ERR_INSTANCE = "Not available in instances and battlegrounds."
L.LJ_ERR_QUEUE = "Not available while queued for a battleground."
L.LJ_ERR_COOLDOWN = "Wait %d s before searching again."
L.LJ_ERR_SAME_LAYER = "You are already on this layer."
L.LJ_ERR_NO_NETWORK = "The Overlord network is not ready yet (no guild or channel). Try again in a moment."
L.LJ_ERR_LAYER_UNKNOWN = "Target an NPC first: your layer must be known to jump to another one."
L.LJ_GUEST_REMOVED = "%s removed from the group (layer change over)."
L.LJ_LATE_LEAVE = "Left %s's group: that layer jump was cancelled."
L.CHECK_PVP_BUTTON = "Export"
L.SETTINGS_BUTTON_TOOLTIP     = "Open Overlord settings."
L.SETTINGS_OPEN_UNAVAILABLE   = "Settings are not available right now. Use Esc, then Options, then AddOns."
L.SCALE_CURRENT     = "Panel scale: %.1f (range %.1f to %.1f)."
L.SCALE_SET         = "Panel scale set to %.1f."
L.ATTACK            = "Attack!"
L.LOCKED            = "Locked"
L.NEXT_OBJECTIVE_HEADER   = "Next Objective"
L.NEXT_OBJECTIVE_COLLAPSE = "Hide next objective"
L.NEXT_OBJECTIVE_NONE = "No objective available"
L.NEXT_OBJECTIVE_NO_FRONT = "Outside a war front"
-- Outside a war front: one short line for the player's race (faction fallback).
L.HOME_MOTTOS = {
    Human = "Stormwind still stands.",
    Dwarf = "Ironforge endures.",
    Gnome = "Gnomeregan shall rise!",
    NightElf = "Under Elune's gaze.",
    Orc = "Lok'tar ogar!",
    Troll = "Da spirits be watchin'.",
    Scourge = "The Dark Lady watches.",
    Tauren = "The Earth Mother guides.",
    Skyborne = "The song of the winds.",
    Alliance = "For the Alliance!",
    Horde = "For the Horde!",
}
L.NEXT_OBJECTIVE_OUTSIDE_FRONT = "Enter a war front to see your next objective."
L.NEXT_OBJECTIVE_GO         = "Go here: stand in the zone to start the capture timer."
L.GUIDE_BAR_LABEL           = "Tutorial"
L.GUIDE_CLOSE               = "Close"
L.GUIDE_TITLE               = "Tutorial"
L.GUIDE_PAGE_INDICATOR      = "Page %d / %d"
L.GUIDE_PREV                = "Previous"
L.GUIDE_NEXT                = "Next"
L.GUIDE_PAGE2_TITLE         = "Captures & resources"
L.VICTORY_DOMINATION_BONUS  = "Total front victory: +%d%% weekly domination for your faction."
L.TOOLTIP_SHIFT_GUIDE       = "Shift + left click: Quick guide"

-- Shard (phasing / instance layer ID from NPC GUID)
L.SHARD_TOOLTIP_TITLE          = "Shard ID"
L.SHARD_TOOLTIP_CURRENT        = "Current shard ID: %s"
L.SHARD_TOOLTIP_REFERENCE_REALM = "Reference player: %s"
L.SHARD_BADGE_REFERENCE       = "via %s"
L.SHARD_TOOLTIP_PLAYERS_HEADER = "Players on a different shard:"
L.SHARD_TOOLTIP_ALL_SAME       = "All synced players are on the same shard."
L.SHARD_TOOLTIP_UNDETECTED     = "Shard not detected yet (no vignette, mouseover NPC, or nameplate GUID available)."
L.SHARD_ALERT_TAG              = " #%s"

L.ASSAULT_LAUNCHED    = "Assault on %s launched!"
L.CAPTURE_LAUNCHED    = "Capture of %s started!"
L.GO_TO_ZONE          = "Go to %s (%.1f, %.1f) to capture!"
L.ENEMY_CONTROL_MSG   = "%s is under enemy control. Capture prerequisites first."
L.CAPTURE_BLOCKED_RULES = "%s cannot be captured yet (front truce, protected capital or prerequisites)."
L.ZONE_IS_LOCKED      = "%s is locked."
L.ALREADY_IN_PROGRESS = "%s already in progress..."
L.ZONE_UNDER_CONTROL  = "%s is controlled by %s."

-- === Zones ===
L.CAPTURE_CANCELLED  = "Capture of %s cancelled! Prerequisites lost."
L.ZONE_NOW_AVAILABLE = "%s is now available for capture!"

-- === ZoneControl ===
L.ENTERED_ZONE       = "You entered %s! Capture started!"
L.CAPTURE_NEEDS_PVP = "%s: enable PvP (/pvp) to capture this objective."
L.AUTO_DISMOUNT_CAPTURE_CIRCLE = "You are flying in %s: automatic dismount in %d seconds."
L.AUTO_DISMOUNT_MINE_CIRCLE    = "You are flying in the %s mining circle: automatic dismount in %d seconds."
L.HOLD_TIMER_STARTED = "Hold timer started for %s (%d:%02d). Stay in the zone!"
L.CAPTURE_SYNC_WAITING = "Initial sync pending: capture of %s is temporarily blocked."
L.ZONE_CONTESTED_OUTNUMBER = "%s is contested! Enemies outnumber (%d vs %d)."
L.ZONE_CONTESTED_EVEN      = "%s is contested! Forces are even (%d vs %d)."
L.ZONE_SECURED       = "%s secured! Capture resumes."
L.BACK_IN_ZONE       = "You're back in %s! Capture resumes."
L.LEFT_ZONE          = "You left %s! Progress is decaying..."
L.CAPTURE_LOST       = "Capture of %s lost! Return there to restart."
L.ENEMY_CAPTURE_REVERSED = "Enemy capture of %s reversed! Zone secured."
L.ZONE_CAPTURED_BY   = "%s has been captured by %s!"
L.TOTAL_VICTORY_MSG  = "   TOTAL VICTORY FOR %s!   "
L.TOTAL_VICTORY_FRONT_MSG = "   TOTAL VICTORY FOR %s! Front: %s   "
-- === CombatTracker ===

-- === LeaderboardUI ===
L.LB_TITLE         = "LEADERBOARD"
L.LB_SEARCH_PLACEHOLDER = "Player or guild..."
L.LB_SEARCH_EMPTY = "No matches"
L.LB_SEARCH_WORKING = "Searching..."
L.LB_BUTTON        = "Leaderboard"
L.LB_BUTTON_TOOLTIP = "Open weekly kills and captures ranking"
L.HOF_BUTTON        = "Hall of Fame"
L.HOF_BUTTON_TOOLTIP = "Open the Hall of Fame: honors, feats and donors"
L.DISCORD_BUTTON = "Discord"
L.DISCORD_BUTTON_TOOLTIP = "Join the Discord server"
L.DISCORD_POPUP_TITLE = "Join the Discord server"
L.DISCORD_POPUP_HINT = "Open Discord in your browser and paste the invite link below."
L.DISCORD_URL_LABEL = "Discord invite link"
L.DISCORD_POPUP_COPY_HINT = "URL selected: copy (Ctrl+C)"
L.HOF_TITLE = "Hall of Fame"
L.HOF_SECTION_EMPTY = "No entries yet."
L.HOF_CAT_GUILD = "Guild honors"
L.HOF_CAT_PLAYER = "Player honors"
L.HOF_CAT_LIFETIME = "Your feats"
L.HOF_PROGRESS_COUNT = "%d / %d"
L.HOF_CAT_ALLIANCE = "Alliance"
L.HOF_CAT_HORDE = "Horde"
L.HOF_CAT_WEEKLY = "Weekly feats"
L.HOF_CAT_DONORS = "Donors"
L.HOF_DONOR_LINE = "Over 100 gold gifted to the war chest"
L.HOF_POINTS_LABEL = "War front achievement points"
L.HOF_RECENT_TITLE = "Recent feats"
L.HOF_PROGRESS_TITLE = "Progress overview"
L.HOF_PROGRESS_TOTAL = "Honors earned"
L.HOF_SEARCH_NO_RESULTS = "No matching honors."
L.HOF_WEEKLY_PLAYER_RANK_LINE = "Beta, weekly killers: rank %d"
L.HOF_WEEKLY_GUILD_RANK_LINE = "Beta, weekly guilds: rank %d"
L.LB_CAMPAIGN_DATE = "Campaign %s to %s"
L.LB_INFO_ENDS = "Campaign ends in"
L.LB_INFO_RANKED = "Ranked players:"
L.LB_INFO_RANKED_VALUE = "|cFF4488FF%s Alliance|r · |cFFFF4444%s Horde|r"
L.LB_INFO_YOU = "You:"
L.LB_INFO_UNRANKED = "not ranked yet"
L.LB_INFO_NEXT = "%s HK to pass #%d"
L.LB_INFO_FIRST = "You lead the ladder!"
L.LB_RULESET_LABEL = "%s ruleset"
L.RULESET_NAME_PVP = "PvP"
L.RULESET_NAME_NORMAL = "Normal"
L.RULESET_NAME_RP = "RP"
L.RULESET_NAME_HARDCORE = "Hardcore"
L.LB_CACHED_REFRESHING = "Saved ranking · updating…"
L.LB_COL_CLASS     = "Class"
L.LB_COL_RACE      = "Race"
L.LB_COL_PLAYER    = "Player"
L.LB_COL_KILLS     = "HK"
L.LB_TOTAL_FORMAT  = "|cFF4488FFAlliance: %d Kills|r  |cFFFF4444Horde: %d Kills|r"
L.LB_CAPTURES_ALLIANCE = "Alliance: Captures"
L.LB_CAPTURES_HORDE    = "Horde: Captures"
L.LB_CAPTURES_SCROLL_TOOLTIP = "Mouse wheel to scroll the list"
L.LB_KILLS_SCROLL_TOOLTIP     = "Mouse wheel to scroll the ranking"
L.LB_ROW_GUILD = "Guild: %s"
L.LB_ROW_NO_GUILD = "Guild unknown"
L.LB_GUILD_TIP_SUMMARY = "%d ranked members, %d kills"
L.LB_GUILD_TIP_MORE = "+ %d more"
L.LB_GUILD_TIP_TOTAL = "%d kills"
L.LB_COL_GUILD                = "Guild"
L.LB_COL_KEEP                 = "Keep"
L.LB_GUILD_EMPTY              = "No ranked guilds yet."
L.LB_GUILD_KEEP_EMPTY         = "No guild holds a keep yet."
L.LB_COL_OUTPOST              = "Outpost"
L.LB_COL_CAPTURES             = "Captures"
L.LB_OUTPOST_EMPTY            = "No outpost captures yet."
L.OUTPOST_SHORT               = "Outpost"
L.OUTPOST_LOCH_MODAN_NAME     = "Katrell's Retreat"
L.OUTPOST_ARATHI_NAME         = "Sage's Tower"
L.OUTPOST_DUROTAR_NAME        = "Jaggedswine Farm"
L.OUTPOST_ELWYNN_NAME         = "Thunder Falls"
L.OUTPOST_ASHENVALE_NAME      = "Shobek'Aran"
L.OUTPOST_NEUTRAL             = "Unclaimed"
L.OUTPOST_CAPTURING           = "Capturing..."
L.OUTPOST_NO_GUILD            = "You must be in a guild to capture an outpost."
L.OUTPOST_HOLD_STARTED        = "Capturing %s (%d min)…"
L.OUTPOST_CAPTURE_LOST        = "Outpost capture lost."
L.OUTPOST_UNDER_ATTACK        = "%s is under attack!"
L.OUTPOST_CONTESTED_OUTNUMBER = "%s is contested! Enemies outnumber (%d vs %d). Progress is falling back."
L.OUTPOST_CONTESTED_EVEN      = "%s is contested! Forces are even (%d vs %d). Progress is frozen."
L.OUTPOST_INDICATOR_TITLE     = "|cFFFFFF00Outpost Capture|r"
L.OUTPOST_DEFENSE_TITLE       = "|cFFFFFF00Outpost Defense|r"
L.OUTPOST_ON_POINT            = "You are on the outpost point."
L.OUTPOST_ASSAULT_READY       = "Assault available: hold the square for %d min."
L.OUTPOST_PANEL_HELD          = "Held by %s"
L.OUTPOST_CAPTURE_ALERT_FRIENDLY = "%s is now held by guild %s!"
L.OUTPOST_CAPTURE_ALERT_ENEMY    = "%s captured by guild %s (%s)!"
L.OUTPOST_DEFENDER_UNDER_ATTACK = "%s: your guild's outpost is under attack (%s)!"
L.OUTPOST_DEFENDER_UNDER_ATTACK_BY = "%s: your guild's outpost is under attack by guild %s (%s)!"
L.OUTPOST_ALLIED_UNDER_ATTACK = "%s: allied outpost held by guild %s is under attack (%s)!"
L.OUTPOST_ENEMY_ASSAULT      = "%s: %s launched an assault!"
L.OUTPOST_ENEMY_ASSAULT_VS   = "%s: %s is assaulting %s!"
L.OUTPOST_ALLY_ASSAULT       = "%s: %s started an assault."
L.OUTPOST_ALLY_ASSAULT_VS    = "%s: %s started an assault on %s."

-- Repere carte depuis le panel des zones (UI.lua)
L.ZONE_WAYPOINT_BLOCKED = "|cFFFFD100[Overlord]|r Cannot place a pin on this map."
L.ZONE_WAYPOINT_FAIL    = "|cFFFFD100[Overlord]|r Could not create map pin."

-- === MapMarkers ===
L.MAP_AVAILABLE       = "AVAILABLE"
L.MAP_LOCKED          = "LOCKED"
L.MAP_NEUTRAL         = "NEUTRAL"
L.MAP_SYNC_PENDING    = "SYNCING"
L.FRONT_ZONES_HEADER = "%s zones:"
L.TOOLTIP_FRIENDLY    = "Friendly: %d/%d"
L.TOOLTIP_ENEMY       = "Enemy: %d/%d"
L.TOOLTIP_LEFT_CLICK      = "Left click: Main panel"
L.TOOLTIP_RIGHT_DRAG      = "Right click + drag: Move"
L.DISABLED_IN_INSTANCE    = "Overlord is disabled in instances."
L.MM_NEUTRAL          = "Neutral"
L.ZONE_NEUTRAL        = "Neutral"

-- === ZoneIndicator ===
L.INDICATOR_TITLE = "|cFFFFFF00Capture Zone|r"
L.INDICATOR_CLICK_WAYPOINT = "Left click: set waypoint"
L.IN_THE_ZONE     = "You are in the zone!"
L.INDICATOR_DISMOUNT_TO_CAPTURE = "Dismount."
L.INDICATOR_ENABLE_PVP = "Enable PvP (/pvp)."
L.INDICATOR_STEALTH_TO_CAPTURE   = "Leave stealth to capture."
L.INDICATOR_HUD_DISABLED         = "Return to the capture zone."
L.DISTANCE_FORMAT = "Distance: ~%.0f yards"
L.COORDS_FORMAT   = "Coords: %.1f, %.1f"

-- === Siege (capital timer) ===
L.SIEGE_COOLDOWN_LABEL = "Truce (%s)"
L.MAP_CAPITAL_LABEL = "Capital"
L.FORCES_PRESENT = "%d %s nearby"
L.NOT_IN_WARZONE = "Not in a war zone"

-- === Combat ===
L.CANNOT_IN_COMBAT   = "Cannot open in combat."
L.HONORABLE_KILLS_CONFIRM = "+%d honorable kills: Total: %d"

-- === Manual gold bounty ===

-- === Domination ===
L.DOMINATION_LABEL = "Weekly Territory Domination"

-- === Sync ===
L.SYNC_CAPTURED_FRIENDLY = "%s has been captured by %s!"
L.SYNC_CAPTURED_ENEMY    = "%s has been taken by %s!"
L.SYNC_CAPTURED_ENEMY_BY = "%s has been taken by %s (%s)!"
L.ENEMY_CAPTURING        = "%s: under attack by %s!"
L.ENEMY_CAPTURING_BY     = "%s: under attack by %s (%s)!"
L.SYNC_REQUESTED        = "Sync requested. You should receive the current state shortly."
L.SYNC_WHISPER_SENT     = "Sync request sent to %s by addon whisper."
L.COMMUNITY_BTN_JOIN    = "Community"
L.COMMUNITY_BTN_TOOLTIP = "Community invite"
L.FACTION_CALL_TOOLTIP_TITLE = "Call faction"
L.FACTION_CALL_BUTTON       = "Call to arms"
L.GENERAL_BUTTON            = "Command"
L.FACTION_CALL_TOOLTIP  = "Sound the war horn! Every ally of your faction running Overlord gets a raid warning with your front and zone."
L.FACTION_CALL_TOOLTIP_SHARED = "Once every 4 hours for the whole faction: only one herald at a time."
L.FACTION_CALL_TOOLTIP_CD = "Available in %s"
L.FACTION_CALL_COOLDOWN_SHARED = "Faction call on cooldown: an ally called recently (%s remaining)."
L.FACTION_CALL_SENT     = "Faction call sent to every Overlord ally of your faction."
L.FACTION_CALL_RECEIVED = "%s calls the faction: %s (%s)!"
L.FACTION_CALL_RECEIVED_NO_ZONE = "%s calls the faction: %s!"
L.FACTION_CALL_RECEIVED_GENERIC = "%s calls the faction!"
L.GUILD_KILL_ALERT_ENABLED_LABEL = "Enemy guild raid alerts"
L.GUILD_KILL_ALERT_ENABLED_TOOLTIP = "Warns in chat when an enemy guild gets 20+ kills with 5+ members within 5 minutes."
L.GUILD_KILL_ALERT = "Guild %s: %d+ kills by %d+ members%s!"
L.GUILD_KILL_ALERT_FRONT = "Guild %s: %d+ kills by %d+ members in %s%s!"
L.GUILD_KILL_DIAG_HEADER = "Enemy guild raid alert: %s, threshold %d kills and %d members in 5 min."
L.GUILD_KILL_DIAG_EMPTY = "No guild kills received in the last 5 minutes."
L.GUILD_KILL_DIAG_ROW = "%s (%s): %d kills, %d members"
L.GUILD_KILL_HELP = "/ov guildkills [on|off|test]"
L.HELP_GUILD_KILLS = "|cFFFFFF00/ov guildkills [on|off|test]|r: Enemy guild raid alert"
L.FACTION_CALL_NO_ONLINE  = "No online allies of your faction found in the community."
L.FACTION_CALL_COMBAT     = "Cannot call faction during combat lockdown."
L.FACTION_CALL_NOT_IN_FRONT = "You must be on an active war front."
L.FACTION_CALL_TOOLTIP_NOT_IN_FRONT = "Available only on an active war front."
L.GENERAL_TOOLTIP_TITLE_ALLIANCE = "Alliance General"
L.GENERAL_TOOLTIP_TITLE_HORDE = "Horde General"
L.GENERAL_TOOLTIP = "Assume command. Your icon guides all allies on the war map. One general per banner."
L.GENERAL_TOOLTIP_RELEASE = "Click again to relinquish command."
L.GENERAL_ASSUMED_SELF = "You are the Alliance General on |cFFFFD100%s|r. The banner follows your steps."
L.GENERAL_ASSUMED_SELF_HORDE = "You are the Horde General on |cFFFFD100%s|r. The banner follows your steps."
L.GENERAL_RELEASED_SELF = "You have relinquished command of the banner."
L.GENERAL_SLOT_TAKEN = "General |cFFFFD100%s|r already leads the banner."
L.GENERAL_NOT_LEADER = "Only the group or raid leader may assume this role."
L.GENERAL_NOT_ON_FRONT = "You must be on an active war front."
L.GENERAL_COMBAT = "Command cannot be assumed during combat."
L.GENERAL_INSTANCE = "Command is unavailable inside instances."
L.GENERAL_RECEIVED = "%s assumes command on |cFFFFD100%s|r!"
L.GENERAL_MAP_TOOLTIP = "General: %s"
L.GENERAL_ENEMY_MAP_TOOLTIP = "Enemy general: %s"
L.GENERAL_FALLEN = "General %s has fallen! Slain by %s."
L.GENERAL_COUNTERPART_SLAIN = "Enemy general %s has been slain by %s!"
L.GENERAL_ENEMY_ASSUMED = "Enemy general %s leads the banner on |cFFFFD100%s|r!"
L.GENERAL_SHARD_UNKNOWN = "Shard different or unknown."
L.VERSION_OUTDATED      = "A newer version (%s) is available. Please update!"
L.POPUP_OK = "Understood"
L.POPUP_WELCOME_TITLE_ALLIANCE = "For the Alliance"
L.POPUP_WELCOME_TITLE_HORDE    = "For the Horde"
L.POPUP_WELCOME_BODY           = "Welcome to the battlefield, |cFFFFD100%s|r.\n\nHead to a |cFFFFD100|Haddon:Overlord:panel|hwar front|h|r and read the |cFFFFD100tutorial|r (|cFFFFD100book icon|r at the top of your screen)."
L.POPUP_WELCOME_NAME_FALLBACK  = "Champion"
L.POPUP_WELCOME_GUIDE_BTN      = "Open tutorial"
L.POPUP_UPDATE_FOREVER_1000_TITLE = "Overlord Forever"
L.POPUP_UPDATE_FOREVER_1000_BODY  = "|cFFFFD100A new Overlord battlefield:|r PvP kills earned in the open world on |cFFFFD100Arathi Highlands|r, |cFFFFD100Loch Modan|r, |cFFFFD100Durotar|r, and |cFFFFD100Ashenvale|r are recorded on the Overlord leaderboard.\n\n|cFFFFFFFFRequirements|r\n• Your character must be |cFFFFD100level 60|r.\n• Open world only: instanced raids, dungeons, and battlegrounds remain excluded.\n\nA |cFFFFD100guild outpost|r awaits on each war front."
L.POPUP_BATTLE_REPORT_TITLE     = "Battle Report"
L.POPUP_BATTLE_REPORT_GUILD     = "Dominant guild: %s: |cFFFFD100%d|r kills"
L.POPUP_BATTLE_REPORT_KILLER    = "Top killer: %s: |cFFFFD100%d|r kills"
L.POPUP_BATTLE_REPORT_CAPTURER  = "Top capturer: %s: |cFFFFD100%d|r captures"
L.POPUP_BATTLE_REPORT_NOT_FRONT = "Go to a war front map to view the battle report."
L.POPUP_BATTLE_REPORT_NO_DATA   = "No ranking data for the battle report yet."
L.FEATURED_FRONT_ACTIVITY_TITLE      = "Recent activity (Last 5 min)"
L.FEATURED_FRONT_ACTIVITY_DASH       = "..."
L.FEATURED_FRONT_ACTIVITY_JUST_NOW   = "just now"
L.FEATURED_FRONT_ACTIVITY_MIN_AGO    = "%d min ago"
L.FEATURED_FRONT_ACTIVITY_KILLS      = "%d+ kills"
L.SPOOF_DETECTED        = "Modified addon detected from %s: phantom captures blocked and reverted."

-- === Anti-farming ===
L.FARM_KILL_DETECTED  = "Kill farming suppressed: %s -> %s (%d+ kills in 5 min, stats not counted)."

-- === Export ===
L.EXPORT_CLOSE          = "Close"
L.FOREVER_FEATURE_UNAVAILABLE = "Unavailable on Overlord Forever."
-- poolTag = FR | EU | US | UNKNOWN (pool communaute Overlord / export Check PvP, pas la langue du royaume)
-- Format : poolTag, campaignId, startDate, endDate

-- === Mines / Gold ===
L.MINE_AZURELODE        = "Azurelode Mine"
L.MINE_DARROW           = "Darrow Hill"
L.MINE_ELEMGORGE        = "Elemgorge Mine"
L.MINE_STONESSPLINTER   = "Stonesplinter Mine"
L.MINE_JASPERLODE       = "Jasperlode Mine"
L.GOLD_LABEL            = "Coins"
L.GOLD_COUNTER          = "Coins: %d / %d"
L.GOLD_HEADER_TIP       = "Earn coins inside the marked circles. Hillsbrad Foothills: Azurelode Mine and Darrow Hill. Silverpine Forest: Elemgorge Mine. Loch Modan: Stonesplinter Mine. Elwynn Forest: Jasperlode Mine."
-- GOLD_FULL, GOLD_REINFORCE_*, GOLD_BARRICADE_* : numeriques via ApplyGoldLocaleStrings() (Ressources init)
L.GOLD_NODE_BONUS       = "+%d coins (mining node)"
-- Texte flottant au-dessus du personnage (gain passif dans le cercle mine)
L.GOLD_FCT_GAIN         = "+%d coins"
L.GOLD_NOT_ENOUGH       = "Not enough coins (requires %d)."
L.GOLD_REINFORCE        = "Attack"

-- Guild Keep
L.GUILD_KEEP_STONETALON     = "Sun Rock Retreat"
L.GUILD_KEEP_WETLANDS       = "Menethil Keep"
L.GUILD_KEEP_BADLANDS       = "Angor Fortress"
L.GUILD_KEEP_CROSSROADS     = "The Crossroads"
L.GUILD_KEEP_MULGORE        = "Bloodhoof Village"
L.GUILD_KEEP_SELECT_TITLE   = "Select Keep"
L.GUILD_KEEP_SELECT_AUTO    = "Auto (held by guild)"
L.GUILD_KEEP_NEUTRAL        = "Unclaimed"
L.GUILD_KEEP_CAPTURING      = "Capturing…"
L.GUILD_KEEP_PANEL_HELD     = "Held by %s"
L.GOLD_BARRICADE        = "Reinforce"
L.GOLD_TOOLTIP_COST     = "Cost: %d coins."
L.ENEMY_MINING_HORDE     = "Alert! The Horde is mining: %s!"
L.ENEMY_MINING_ALLIANCE  = "Alert! The Alliance is mining: %s!"
L.MINE_TOOLTIP          = "Coin mine: stand inside the circle to earn coins."
L.MINE_ENTERED          = "You entered %s. Coin generation started."
L.MINE_LEFT             = "You left %s. Coin generation stopped."
L.MINE_STOCK            = "Mine reserves: %d / %d"
L.MINE_DEPLETED         = "%s is depleted. Reserves will refill over time."
L.CATCHUP_PHASE         = "Catch-up experience detected: Overlord is inactive in this phase."
L.CATCHUP_MAP_BANNER    = "Catch-up phase: Overlord inactive"


-- ================================================================
-- FRANCAIS (frFR): Surcharge automatique pour les clients FR
-- ================================================================
if Overlord.IsFrenchLocale() then

L.CAPTURE_ALERT_SUBZONE_IN_REGION = "%s (%s)"

L.ZONE_NAMES = {
    stromgarde = "Donjon de Stromgarde",
    faldir     = "Crique de Faldir",
    witherbark = "Fanecorce",
    goshek     = "Ferme de Go'Shek",
    dabyrie    = "Ferme des Dabyrie",
    refuge     = "Refuge de l'Ornière",
    highperch  = "Hautes-terres occidentales",
    newstead   = "Mur de Thoradin",
    hammerfell = "Trépas-d'Orgrim",
    argorok    = "Cercle de lien occidental",
    loch_alliance_capital = "Thelsamar",
    loch_horde_capital = "Fortin des Mo'grosh",
    loch_valley_of_kings = "Vallée des Rois",
    loch_south_gate_pass = "Passage de la porte sud",
    loch_silver_stream_mine = "Mine du Ru d'argent",
    loch_algaz_post = "Poste d'Algaz",
    loch_farstrider_lodge = "Retraite des Pérégrins",
    loch_ironband = "Excavations de Ironband",
    loch_the_loch = "Le Loch",
    loch_stonewrought_dam = "Barrage de Formepierre",
    durotar_tiragarde_keep = "Donjon de Tiragarde",
    durotar_alliance_fleet = "Combe des Kolkar",
    durotar_senjin_village = "Village de Sen'jin",
    durotar_razor_hill = "Tranchecolline",
    durotar_deadeye_shore = "Rivage d'Œil-Mort",
    durotar_southfury = "Furie-du-sud",
    durotar_spirit_rock = "Vallée des Épreuves",
    durotar_thunder_ridge = "Falaises du Tonnerre",
    durotar_drygulch_ravine = "Ravin asséché",
    durotar_dranosh_blockade = "Abords d’Orgrimmar",
    elwynn_westbrook = "Garnison du Ruisseau de l'Ouest",
    elwynn_goldshire = "Comté de l'Or",
    elwynn_tower_of_azora = "Tour d'Azora",
    elwynn_ridgepoint = "Tour de la Crête",
    elwynn_mirror_lake = "Lac de Cristal",
    elwynn_fargodeep = "Mine de Fondugouffre",
    elwynn_jerods_landing = "Débarcadère de Jerod",
    elwynn_stone_cairn = "Lac du Cairn",
    elwynn_eastvale = "Camp du bûcheron du Val-est",
    elwynn_invasion_camp = "Avancée Blackrock",
    ash_astranaar = "Astranaar",
    ash_iris_lake = "Lac Iris",
    ash_raynewood = "Retraite de Raynebois",
    ash_night_run = "Course nocturne",
    ash_bloodtooth_camp = "Camp Dent-Rouge",
    ash_silverwind = "Refuge de Vent-d'Argent",
    ash_mystral_lake = "Lac Mystral",
    ash_fallen_sky_lake = "Lac Tombeciel",
    ash_dor_danil = "Refuge de Dor'Danil",
    ash_splintertree = "Poste de Bois-Brisé",
}

L.FRONT_ARATHI_NAME = "Hautes-terres d'Arathi"
L.FRONT_LOCH_MODAN_NAME = "Loch Modan"
L.FRONT_DUROTAR_NAME = "Durotar"
L.FRONT_ELWYNN_NAME = "Forêt d'Elwynn"
L.FRONT_ARATHI_DROPDOWN = "Arathi"
L.FRONT_LOCH_MODAN_DROPDOWN = "Loch Modan"
L.FRONT_DUROTAR_DROPDOWN = "Durotar"
L.FRONT_ELWYNN_DROPDOWN = "Elwynn"
L.FRONT_ASHENVALE_NAME = "Orneval"
L.FRONT_ASHENVALE_DROPDOWN = "Orneval"

L.THE_HORDE    = "la Horde"
L.THE_ALLIANCE = "l'Alliance"

L.VICTORY_FACTION_HORDE    = "LA HORDE"
L.VICTORY_FACTION_ALLIANCE = "L'ALLIANCE"

L.DATE_FORMAT = "%d/%m/%Y"

-- Core
L.WEEKLY_RESET    = "Nouvelle semaine ! Campagne réinitialisée selon le calendrier américain de la bêta."
L.MODULE_ERROR    = "Erreur module %s : %s"
L.ADDON_LOADED    = "v%s chargé. |cFFFFFF00/ov help|r pour les commandes."
L.SYNC_LOGIN_WAIT = "Synchronisation des zones en cours... La carte se mettra à jour sous peu."
L.ALL_ZONES_RESET = "Toutes les zones ont été réinitialisées !"
L.FRONT_CAPITAL_RELEASED = "%s : trêve terminée. La conquête reste acquise et la capitale tombée se relève ; les deux capitales sont protégées jusqu'à %s."
L.CAPITAL_PROTECTED_UNTIL = "Protégée jusqu'à %s"
L.CAPITAL_PROTECTED_SHORT = "Jusqu'à %s"

-- Commands
L.HELP_HEADER   = "|cFF00FF00========== Overlord: Commandes ==========|r"
L.HELP_SHOW     = "|cFFFFFF00/ov show|r: Affiche l'interface"
L.HELP_HIDE     = "|cFFFFFF00/ov hide|r: Cache l'interface"
L.HELP_TOGGLE   = "|cFFFFFF00/ov toggle|r: Bascule l'interface"
L.HELP_HUD      = "|cFFFFFF00/ov hud [auto|on|off|toggle]|r : règle le HUD du haut"
L.HUD_SHOWN     = "|cFF00FF00[Overlord]|r HUD du haut activé."
L.HUD_HIDDEN    = "|cFF00FF00[Overlord]|r HUD du haut désactivé."
L.HUD_AUTO      = "|cFF00FF00[Overlord]|r HUD du haut en mode Auto."
L.HELP_STATUS   = "|cFFFFFF00/ov status|r: Affiche l'état de toutes les zones"
L.HELP_ZONES    = "|cFFFFFF00/ov zones|r: Affiche les zones disponibles avec coordonnées"
L.HELP_WHERE    = "|cFFFFFF00/ov where|r: Bascule l'indicateur de zone"
L.HELP_START    = "|cFFFFFF00/ov start <zone>|r: Démarre la capture d'une zone"
L.HELP_LB       = "|cFFFFFF00/ov lb|r: Affiche le classement"
L.HELP_SYNC     = "|cFFFFFF00/ov sync [Joueur-Royaume]|r: Demande la sync (whisper cible ou groupe/raid/communaute)"
L.HELP_DOM      = "|cFFFFFF00/ov dom|r: Debug barre domination (victoires de front, % affichés)"
L.HELP_SCALE    = "|cFFFFFF00/ov scale [0.8-1.2]|r: Échelle du panneau (aussi : Échap > Options > AddOns > Overlord)"
L.DOM_DEBUG_HEADER = "Domination hebdomadaire :"
L.DOM_DEBUG_COUNTS = "A : %d victoires / H : %d victoires | barre : %s / %s"
L.HELP_GUIDE    = "|cFFFFFF00/ov guide|r: Guide visuel rapide"
L.HELP_FOOTER   = "|cFF00FF00=============================================|r"

L.STATUS_HEADER      = "|cFF00FF00========== Overlord: Statut ==========|r"
L.STATUS_IN_PROGRESS = "EN COURS (%d:%02d maintien)"
L.STATUS_AVAILABLE   = "DISPONIBLE"
L.STATUS_LOCKED      = "VERROUILLÉE"
L.STATUS_TOTAL       = "Total : %d/%d zones (%d%%)"
L.STATUS_FOOTER      = "|cFF00FF00=============================================|r"

L.NOT_INITIALIZED  = "L'addon n'est pas encore initialisé."
L.USAGE_START      = "Usage : /ov start <zone>"
L.ZONE_UNKNOWN     = "Zone inconnue : %s"
L.ZONE_NOT_AVAILABLE = "%s n'est pas disponible !"
L.MUST_BE_IN_ZONE  = "Vous devez être dans %s pour lancer la capture ! (%.1f, %.1f)"
L.UNKNOWN_COMMAND  = "Commande inconnue : %s"
L.HELP_HINT        = "Tapez /ov help pour voir les commandes disponibles."
L.POS_RESET        = "Position du panel réinitialisée."

-- UI
L.CONTROL_ZONES     = "ZONES DE CONTRÔLE"
L.ACTIVE_ZONE       = "ZONE ACTIVE"
L.NO_ACTIVE_ZONE    = "Aucune zone active"
L.HOLD_LABEL        = "Maintien"
L.UI_CONTESTED      = "CONTESTÉ"
L.UI_PAUSED         = "EN PAUSE: hors zone, minuteur décroît"
L.UI_IN_PROGRESS    = "EN COURS: maintenez la position"
L.UI_ENEMY_CAPTURING = "ENNEMI CAPTURE: contestez la zone !"
L.UI_COMPLETE       = "TERMINÉ"
L.ACTION_SHORTCUT_LABEL = "Raccourci de barre d’action"
L.ACTION_SHORTCUT_TOOLTIP = "Place l’icône Overlord sur le curseur : cliquez sur un emplacement de barre d’action pour l’y déposer."
L.ACTION_SHORTCUT_COMBAT = "Impossible de créer le raccourci de barre d’action pendant un combat."
L.ACTION_SHORTCUT_FAILED = "Impossible de créer ou prendre le raccourci. Vérifiez que vous êtes hors combat, puis réessayez."
L.UI_SCALE_LABEL    = "Échelle du panneau"
L.UI_SCALE_TOOLTIP  = "Taille du panneau principal et du classement. Tu peux aussi utiliser |cffffffff/ov scale|r."
L.NOTIFICATION_CHAT_LABEL = "Messages Overlord"
L.NOTIFICATION_CHAT_TOOLTIP = "Onglet de discussion où s’affichent les alertes et messages Overlord."
L.NOTIFICATION_CHAT_DEFAULT = "Discussion principale (défaut)"
L.CHAT_TAB_LABEL = "Onglet Overlord"
L.CHAT_TAB_BUTTON = "Créer l’onglet"
L.CHAT_TAB_TOOLTIP = "Crée un onglet de discussion « Overlord » et y envoie les messages Overlord. Déplacez-le, masquez-le ou fermez-le comme n’importe quel onglet."
L.CHAT_TAB_READY = "Les messages Overlord s’affichent maintenant dans cet onglet."
L.CHAT_TAB_FAILED = "Aucun onglet de discussion libre. Fermez-en un, puis réessayez."
L.ACTION_SHORTCUT_BUTTON = "Prendre"
L.SETTINGS_SECTION_GENERAL = "Général"
L.SETTINGS_SECTION_CHAT = "Discussion"
L.SETTINGS_SECTION_MAP = "Carte et minicarte"
L.SETTINGS_SECTION_HUD = "Panneaux à l’écran"
L.UI_FRONT_SELECT = "Front (liste)"
L.UI_FRONT_PICKER_TOOLTIP = "Choisir quelles zones afficher. Le minuteur de capture et le combat restent liés à la carte où vous combattez."
L.UI_FRONT_READONLY_TOOLTIP = "Vous consultez un autre front ou vous n’êtes pas en zone de guerre. Les clics ne lancent pas de capture ; les repères utilisent la carte du front choisi."
L.UI_CAPTURE_READONLY = "Lecture seule : rendez-vous sur ce front en monde ouvert pour capturer depuis cette liste."
L.MAP_OVERLAY_OPACITY_LABEL   = "Opacité des captures (carte)"
L.MAP_OVERLAY_OPACITY_TOOLTIP = "Transparence des cercles de capture sur la |cffffffffcarte du monde|r uniquement. Une valeur plus basse laisse mieux voir le détail de la carte en dessous.\nN’affecte pas la minimap (voir Opacité des captures (minimap)) ni les cercles des mines de coins."
L.MINIMAP_OVERLAY_OPACITY_LABEL   = "Opacité des captures (minimap)"
L.MINIMAP_OVERLAY_OPACITY_TOOLTIP = "Transparence des cercles de capture sur la |cffffffffminimap|r. Une valeur plus basse laisse mieux voir le détail de la carte en dessous.\nN’affecte pas la carte du monde, les icônes de fortin ni les cercles des mines de coins."
L.MAP_ICON_OPACITY_LABEL = "Opacité des icônes (carte)"
L.MAP_ICON_OPACITY_TOOLTIP = "Transparence des icônes de points de capture, forteresses et avant-postes sur la |cffffffffcarte du monde|r. Une valeur basse laisse voir les marqueurs de quête dans les villes. À 0, elles sont masquées."
L.MAP_ICON_SCALE_LABEL = "Taille des icônes (carte)"
L.MAP_ICON_SCALE_TOOLTIP = "Taille des icônes de capitales, points de capture, forteresses et avant-postes sur la |cffffffffcarte du monde|r."
L.MINIMAP_BUTTON_LABEL          = "Bouton minimap"
L.MINIMAP_BUTTON_TOOLTIP        = "Affiche le bouton Overlord autour de la minimap. Activez cette option pour le faire réapparaître ; les gestionnaires de boutons minimap peuvent le ranger dans leur propre menu."
L.MINIMAP_CAPTURE_ZONES_LABEL   = "Icônes de la minimap"
L.MINIMAP_CAPTURE_ZONES_TOOLTIP = "Affiche les icônes Overlord sur la |cffffffffminimap|r : cercles de capture, généraux, mines, forts de guilde et avant-postes. Le survol souris traverse les icônes jusqu'au suivi chasseur et nourriture. Désactivez pour toutes les masquer (la grande carte garde ses propres réglages)."
L.MAP_ZONE_TITLES_LABEL         = "Noms de zones (carte)"
L.MAP_ZONE_TITLES_TOOLTIP       = "Affiche les bandeaux parchment avec le nom des zones de capture et mines de coins sur la |cffffffffcarte du monde|r. Désactivez pour une carte plus lisible si vous connaissez déjà les zones."
L.MAP_PATH_OPACITY_LABEL      = "Opacité des pointillés (carte)"
L.MAP_PATH_OPACITY_TOOLTIP    = "Opacité des |cfffffffflignes pointillées|r entre les zones sur la carte du monde (1 = discret, 3 = très visible)."
L.SETTINGS_TOGGLE_ON          = "Activé"
L.SETTINGS_TOGGLE_OFF         = "Désactivé"
L.AUTO_WAYPOINT_LABEL         = "Repère automatique d'objectif"
L.AUTO_WAYPOINT_TOOLTIP       = "Place le repère Blizzard sur le prochain objectif disponible. Si vous retirez ou remplacez ce repère, Overlord attend le prochain objectif avant de le reposer. Le repère est retiré quand l'objectif n'est plus valide."
L.SHOW_TOP_HUD_LABEL          = "HUD du haut"
L.SHOW_TOP_HUD_TOOLTIP        = "Auto affiche les panneaux utiles près des captures, mines et fortins. Toujours les affiche sur les cartes concernées ; Jamais les masque. L'indicateur d'objectif reste disponible."
L.TOP_HUD_MODE_AUTO           = "Auto"
L.TOP_HUD_MODE_ALWAYS         = "Toujours"
L.TOP_HUD_MODE_NEVER          = "Jamais"
L.SHOW_TUTORIAL_BOOK_LABEL    = "Icône livre tutoriel"
L.SHOW_TUTORIAL_BOOK_TOOLTIP  = "Affiche l'icône livre du tutoriel sur le HUD du haut. Désactivez pour masquer uniquement cette icône tout en gardant les panneaux coins et fortin."
L.SOUND_ENABLED_LABEL         = "Sons Overlord"
L.SOUND_ENABLED_TOOLTIP       = "Coupe tous les sons d'Overlord (alertes, cor de guerre, captures, panneaux, buff coins, musique de duel du général, etc.)."
L.SETTINGS_BUTTON             = "Options"
L.LAYER_JUMPER_BUTTON = "Layer Jumper"
L.NET_HEALTH_TITLE = "Réseau Overlord"
L.NET_HEALTH_OK = "Tout va bien"
L.NET_HEALTH_WARN = "À surveiller"
L.NET_HEALTH_BAD = "Problème"
L.NET_HEALTH_HINT = "Tapez /ov network pour le détail."
L.MW_ALERT = "Most Wanted à proximité : %s (#%d %s, %d kills cette semaine) !"
L.HELP_WANTED = "|cFFFFFF00/ov wanted [on|off]|r: Most Wanted : alerte quand un des 5 meilleurs ennemis est proche"
L.MW_STATE_ON = "Alertes Most Wanted : activées"
L.MW_STATE_OFF = "Alertes Most Wanted : désactivées"
L.LAYER_JUMPER_TOOLTIP = "Changer de layer dans ta zone"
L.HELP_LAYER = "|cFFFFFF00/ov layer [help on|off]|r : Layer Jumper (changer de layer ; être passeur volontaire)"
L.LJ_TITLE = "Layer Jumper"
L.LJ_ZONE_LAYER = "%s - ton layer : %s"
L.LJ_LAYER_UNKNOWN = "inconnu"
L.LJ_LAYER_NAME = "Layer #%s"
L.LJ_HELPERS = "%d passeur(s)"
L.LJ_HERE = "tu es ici"
L.LJ_JOIN = "Rejoindre"
L.LJ_SEARCH = "Rechercher"
L.LJ_RANDOM = "Changer de layer"
L.LJ_RANDOM_TOOLTIP = "Passer sur n'importe quel autre layer de la zone (lance une recherche si besoin)."
L.LJ_CANCEL = "Annuler"
L.LJ_LIST_EMPTY = "Cible un PNJ pour lire ton layer, puis clique sur Rechercher pour lister les layers de la zone."
L.LJ_HELP_MODE = "Aider les autres : %s"
L.LJ_HELP_MODE_AUTO = "activé"
L.LJ_HELP_MODE_OFF = "désactivé"
L.LJ_HELP_MODE_TOOLTIP = "Passeur volontaire (désactivé par défaut). Activé, tu invites automatiquement, sans aucune fenêtre, le joueur Overlord de ta faction qui cherche ton layer ; il quitte le groupe une fois le changement fait. Seulement si tu es seul, hors combat et hors instance."
L.LJ_EXPLAIN = "Un passeur volontaire du layer choisi t'invite dans un groupe. Hors combat, le jeu te déplace sur son layer en quelques secondes, puis tu quittes automatiquement le groupe. Seuls ta zone et ton layer sont partagés, jamais ta position."
L.LJ_STATUS_IDLE = "Cherche des passeurs dans ta zone."
L.LJ_STATUS_SEARCHING = "Recherche de passeurs à %s..."
L.LJ_STATUS_READY = "%d passeur(s) trouvé(s)."
L.LJ_STATUS_NONE = "Aucun passeur volontaire disponible dans cette zone pour l'instant. Réessaie dans un moment ou dans une zone plus peuplée."
L.LJ_STATUS_REQUESTING = "Demande d'invitation à %s..."
L.LJ_STATUS_JOINING = "Invitation acceptée, entrée dans le groupe de %s..."
L.LJ_STATUS_VERIFYING = "Changement de layer... (%ds)"
L.LJ_STATUS_VERIFY_COMBAT = "En combat : le changement attend la fin du combat (%ds)."
L.LJ_STATUS_SUCCESS = "C'est fait : tu es maintenant sur %s."
L.LJ_STATUS_UNCONFIRMED = "Groupe quitté ; le nouveau layer n'a pas pu être confirmé (aucun PNJ en vue)."
L.LJ_STATUS_CROWDED = "Groupe quitté : le passeur a fait entrer d'autres joueurs."
L.LJ_STATUS_FAILED = "Aucun passeur ne t'a invité. Réessaie dans un moment."
L.LJ_STATUS_CANCELLED = "Annulé."
L.LJ_ERR_GROUPED = "Quitte d'abord ton groupe : le passeur doit t'inviter."
L.LJ_ERR_INSTANCE = "Indisponible en instance et en champ de bataille."
L.LJ_ERR_QUEUE = "Indisponible pendant une file de champ de bataille."
L.LJ_ERR_COOLDOWN = "Attends %d s avant une nouvelle recherche."
L.LJ_ERR_SAME_LAYER = "Tu es déjà sur ce layer."
L.LJ_ERR_NO_NETWORK = "Le réseau Overlord n'est pas encore prêt (ni guilde ni canal). Réessaie dans un moment."
L.LJ_ERR_LAYER_UNKNOWN = "Cible d'abord un PNJ : ton layer doit être connu pour passer sur un autre."
L.LJ_GUEST_REMOVED = "%s retiré du groupe (changement de layer terminé)."
L.LJ_LATE_LEAVE = "Groupe de %s quitté : ce saut de layer était annulé."
L.CHECK_PVP_BUTTON = "Exporter"
L.SETTINGS_BUTTON_TOOLTIP     = "Ouvre les options Overlord."
L.SETTINGS_OPEN_UNAVAILABLE   = "Les options ne sont pas disponibles pour le moment. Utilisez Échap, puis Options, puis AddOns."
L.SCALE_CURRENT     = "Échelle du panneau : %.1f (plage de %.1f à %.1f)."
L.SCALE_SET         = "Échelle du panneau : %.1f."
L.ATTACK            = "Attaquer !"
L.NEXT_OBJECTIVE_HEADER   = "Prochain objectif"
L.NEXT_OBJECTIVE_COLLAPSE = "Masquer le prochain objectif"
L.NEXT_OBJECTIVE_NONE = "Aucun objectif disponible"
L.NEXT_OBJECTIVE_NO_FRONT = "Hors d’un front de guerre"
-- Outside a war front: one short line for the player's race (faction fallback).
L.HOME_MOTTOS = {
    Human = "Hurlevent tient bon.",
    Dwarf = "Forgefer ne plie jamais.",
    Gnome = "Gnomeregan renaîtra !",
    NightElf = "Sous le regard d'Elune.",
    Orc = "Lok'tar ogar !",
    Troll = "Les esprits veillent, mon.",
    Scourge = "La Dame noire veille.",
    Tauren = "La Terre-mère guide.",
    Skyborne = "Le chant des vents.",
    Alliance = "Pour l'Alliance !",
    Horde = "Pour la Horde !",
}
L.NEXT_OBJECTIVE_OUTSIDE_FRONT = "Rejoignez un front pour voir votre prochain objectif."
L.NEXT_OBJECTIVE_GO         = "Allez ici: restez dans la zone pour lancer le minuteur."
L.GUIDE_BAR_LABEL           = "Tutoriel"
L.GUIDE_CLOSE               = "Fermer"
L.GUIDE_TITLE               = "Tutoriel"
L.GUIDE_PAGE_INDICATOR      = "Page %d / %d"
L.GUIDE_PREV                = "Précédent"
L.GUIDE_NEXT                = "Suivant"
L.GUIDE_PAGE2_TITLE         = "Captures et ressources"
L.VICTORY_DOMINATION_BONUS  = "Victoire totale: +%d %% de domination hebdomadaire pour votre faction."
L.TOOLTIP_SHIFT_GUIDE       = "Maj + clic gauche : guide rapide"
L.LOCKED            = "Verrouillée"

-- Shard (phasing / identifiant de couche via GUID PNJ)
L.SHARD_TOOLTIP_TITLE          = "ID de shard"
L.SHARD_TOOLTIP_CURRENT        = "Identifiant du shard actuel : %s"
L.SHARD_TOOLTIP_REFERENCE_REALM = "Joueur référent : %s"
L.SHARD_BADGE_REFERENCE       = "via %s"
L.SHARD_TOOLTIP_PLAYERS_HEADER = "Joueurs sur un autre shard :"
L.SHARD_TOOLTIP_ALL_SAME       = "Tous les joueurs synchronisés sont sur le même shard."
L.SHARD_TOOLTIP_UNDETECTED     = "Shard non détecté pour l’instant (aucune vignette, survol de PNJ ou nameplate exploitable)."
L.SHARD_ALERT_TAG              = " #%s"

L.ASSAULT_LAUNCHED    = "Assaut sur %s lancé !"
L.CAPTURE_LAUNCHED    = "Capture de %s lancée !"
L.GO_TO_ZONE          = "Rendez-vous à %s (%.1f, %.1f) pour capturer !"
L.ENEMY_CONTROL_MSG   = "%s est sous contrôle ennemi. Capturez les prérequis d'abord."
L.CAPTURE_BLOCKED_RULES = "%s ne peut pas être capturée maintenant (trêve du front, capitale protégée ou prérequis)."
L.ZONE_IS_LOCKED      = "%s est verrouillée."
L.ALREADY_IN_PROGRESS = "%s déjà en cours..."
L.ZONE_UNDER_CONTROL  = "%s est sous le contrôle de %s."

-- Zones
L.CAPTURE_CANCELLED  = "Capture de %s annulée ! Prérequis perdus."
L.ZONE_NOW_AVAILABLE = "%s est maintenant disponible à la capture !"

-- ZoneControl
L.ENTERED_ZONE       = "Vous êtes entré dans %s ! Capture démarrée !"
L.CAPTURE_NEEDS_PVP = "%s : activez le JcJ (/pvp) pour capturer cet objectif."
L.AUTO_DISMOUNT_CAPTURE_CIRCLE = "Vous volez dans %s: démontage automatique dans %d secondes."
L.AUTO_DISMOUNT_MINE_CIRCLE    = "Vous volez dans le cercle de la mine %s: démontage automatique dans %d secondes."
L.HOLD_TIMER_STARTED = "Minuteur de maintien démarré pour %s (%d:%02d). Restez dans la zone !"
L.CAPTURE_SYNC_WAITING = "Synchronisation initiale en cours : capture de %s temporairement bloquée."
L.ZONE_CONTESTED_OUTNUMBER = "%s est contestée ! Ennemis en surnombre (%d vs %d)."
L.ZONE_CONTESTED_EVEN      = "%s est contestée ! Effectifs à égalité (%d vs %d)."
L.ZONE_SECURED       = "%s sécurisée ! Capture reprend."
L.BACK_IN_ZONE       = "Vous êtes de retour dans %s ! Capture reprend."
L.LEFT_ZONE          = "Vous avez quitté %s ! La progression se perd..."
L.CAPTURE_LOST       = "Capture de %s perdue ! Retournez-y pour recommencer."
L.ENEMY_CAPTURE_REVERSED = "Capture ennemie de %s annulée ! Zone sécurisée."
L.ZONE_CAPTURED_BY   = "%s a été capturée par %s !"
L.TOTAL_VICTORY_MSG  = "   VICTOIRE TOTALE DE %s !   "
L.TOTAL_VICTORY_FRONT_MSG = "   VICTOIRE TOTALE DE %s ! Front : %s   "
-- CombatTracker

-- LeaderboardUI
L.LB_TITLE         = "CLASSEMENT"
L.LB_SEARCH_PLACEHOLDER = "Joueur ou guilde..."
L.LB_SEARCH_EMPTY = "Aucun résultat"
L.LB_SEARCH_WORKING = "Recherche..."
L.LB_BUTTON        = "Classement"
L.LB_BUTTON_TOOLTIP = "Ouvrir le classement kills et captures de la semaine"
L.HOF_BUTTON        = "Hall of Fame"
L.HOF_BUTTON_TOOLTIP = "Ouvrir le Hall of Fame : hommages, exploits et donateurs"
L.DISCORD_BUTTON = "Discord"
L.DISCORD_BUTTON_TOOLTIP = "Rejoindre le serveur Discord"
L.DISCORD_POPUP_TITLE = "Rejoindre le serveur Discord"
L.DISCORD_POPUP_HINT = "Ouvrez Discord dans votre navigateur et collez le lien d'invitation ci-dessous."
L.DISCORD_URL_LABEL = "Lien d'invitation Discord"
L.DISCORD_POPUP_COPY_HINT = "Adresse sélectionnée : copier (Ctrl+C)"
L.HOF_TITLE = "Hall of Fame"
L.HOF_SECTION_EMPTY = "Aucune entrée pour le moment."
L.HOF_CAT_GUILD = "Hommages guilde"
L.HOF_CAT_PLAYER = "Hommages joueurs"
L.HOF_CAT_LIFETIME = "Vos exploits"
L.HOF_PROGRESS_COUNT = "%d / %d"
L.HOF_CAT_ALLIANCE = "Alliance"
L.HOF_CAT_HORDE = "Horde"
L.HOF_CAT_WEEKLY = "Exploits hebdo"
L.HOF_CAT_DONORS = "Donateurs"
L.HOF_DONOR_LINE = "Plus de 100 pièces d'or versées au trésor de guerre"
L.HOF_POINTS_LABEL = "Points de hauts faits des fronts"
L.HOF_RECENT_TITLE = "Hauts faits récents"
L.HOF_PROGRESS_TITLE = "Aperçu de la progression"
L.HOF_PROGRESS_TOTAL = "Hommages obtenus"
L.HOF_SEARCH_NO_RESULTS = "Aucun hommage correspondant."
L.HOF_WEEKLY_PLAYER_RANK_LINE = "Bêta, tueurs de la semaine : rang %d"
L.HOF_WEEKLY_GUILD_RANK_LINE = "Bêta, guildes de la semaine : rang %d"
L.LB_CAMPAIGN_DATE = "Campagne du %s au %s"
L.LB_INFO_ENDS = "Fin de la campagne dans"
L.LB_INFO_RANKED = "Joueurs classés :"
L.LB_INFO_RANKED_VALUE = "|cFF4488FF%s Alliance|r · |cFFFF4444%s Horde|r"
L.LB_INFO_YOU = "Toi :"
L.LB_INFO_UNRANKED = "pas encore classé"
L.LB_INFO_NEXT = "encore %s VH pour passer #%d"
L.LB_INFO_FIRST = "Tu es en tête du classement !"
L.LB_RULESET_LABEL = "Campagne %s"
L.RULESET_NAME_PVP = "JcJ"
L.RULESET_NAME_NORMAL = "Normal"
L.RULESET_NAME_RP = "RP"
L.RULESET_NAME_HARDCORE = "Hardcore"
L.LB_CACHED_REFRESHING = "Classement en mémoire · actualisation…"
L.LB_COL_CLASS     = "Classe"
L.LB_COL_RACE      = "Race"
L.LB_COL_PLAYER    = "Joueur"
L.LB_COL_KILLS     = "VH"
L.LB_TOTAL_FORMAT  = "|cFF4488FFAlliance : %d Kills|r  |cFFFF4444Horde : %d Kills|r"
L.LB_CAPTURES_ALLIANCE = "Alliance: Captures"
L.LB_CAPTURES_HORDE    = "Horde: Captures"
L.LB_CAPTURES_SCROLL_TOOLTIP = "Molette : faire défiler la liste"
L.LB_KILLS_SCROLL_TOOLTIP     = "Molette : faire défiler le classement"
L.LB_ROW_GUILD = "Guilde : %s"
L.LB_ROW_NO_GUILD = "Guilde inconnue"
L.LB_GUILD_TIP_SUMMARY = "%d membres classés, %d kills"
L.LB_GUILD_TIP_MORE = "+ %d autres"
L.LB_GUILD_TIP_TOTAL = "%d kills"
L.LB_COL_GUILD                = "Guilde"
L.LB_COL_KEEP                 = "Fort"
L.LB_GUILD_EMPTY              = "Aucune guilde classée pour l'instant."
L.LB_GUILD_KEEP_EMPTY         = "Aucune guilde ne tient de fortin."
L.LB_COL_OUTPOST              = "Avant-poste"
L.LB_COL_CAPTURES             = "Captures"
L.LB_OUTPOST_EMPTY            = "Aucune capture d'avant-poste pour l'instant."
L.OUTPOST_SHORT               = "Avant-poste"
L.OUTPOST_LOCH_MODAN_NAME     = "Retraite de Katrell"
L.OUTPOST_ARATHI_NAME         = "Tour de Sage"
L.OUTPOST_DUROTAR_NAME        = "Ferme des Tranchegroins"
L.OUTPOST_ELWYNN_NAME         = "Chutes du Tonnerre"
L.OUTPOST_ASHENVALE_NAME      = "Shobek'Aran"
L.OUTPOST_NEUTRAL             = "Non revendiqué"
L.OUTPOST_CAPTURING           = "Capture en cours…"
L.OUTPOST_NO_GUILD            = "Vous devez être dans une guilde pour capturer un avant-poste."
L.OUTPOST_HOLD_STARTED        = "Capture de %s (%d min)…"
L.OUTPOST_CAPTURE_LOST        = "Capture d'avant-poste perdue."
L.OUTPOST_UNDER_ATTACK        = "%s est attaqué !"
L.OUTPOST_CONTESTED_OUTNUMBER = "%s est contesté ! Les ennemis dominent (%d vs %d). La progression recule."
L.OUTPOST_CONTESTED_EVEN      = "%s est contesté ! Forces à égalité (%d vs %d). Progression figée."
L.OUTPOST_INDICATOR_TITLE     = "|cFFFFFF00Capture d'avant-poste|r"
L.OUTPOST_DEFENSE_TITLE       = "|cFFFFFF00Défense d'avant-poste|r"
L.OUTPOST_ON_POINT            = "Vous êtes dans le carré de l'avant-poste."
L.OUTPOST_ASSAULT_READY       = "Assaut possible: tenez le carré %d min."
L.OUTPOST_PANEL_HELD          = "Tenu par %s"
L.OUTPOST_CAPTURE_ALERT_FRIENDLY = "%s est désormais tenu par la guilde %s !"
L.OUTPOST_CAPTURE_ALERT_ENEMY    = "%s capturé par la guilde %s (%s) !"
L.OUTPOST_DEFENDER_UNDER_ATTACK = "%s : votre avant-poste est attaqué (%s) !"
L.OUTPOST_DEFENDER_UNDER_ATTACK_BY = "%s : votre avant-poste est attaqué par la guilde %s (%s) !"
L.OUTPOST_ALLIED_UNDER_ATTACK = "%s : l'avant-poste allié de la guilde %s est attaqué (%s) !"
L.OUTPOST_ENEMY_ASSAULT      = "%s : %s lance un assaut !"
L.OUTPOST_ENEMY_ASSAULT_VS   = "%s : %s assaille %s !"
L.OUTPOST_ALLY_ASSAULT       = "%s : %s a lancé un assaut."
L.OUTPOST_ALLY_ASSAULT_VS    = "%s : %s a lancé un assaut sur %s."

L.POPUP_OK = "Compris"
L.POPUP_WELCOME_TITLE_ALLIANCE = "Pour l'Alliance"
L.POPUP_WELCOME_TITLE_HORDE    = "Pour la Horde"
L.POPUP_WELCOME_BODY           = "Bienvenue sur le champ de bataille, |cFFFFD100%s|r.\n\nRendez-vous sur un |cFFFFD100|Haddon:Overlord:panel|hfront|h|r et parcourez le |cFFFFD100tutoriel|r (|cFFFFD100icône du livre|r en haut de l'écran)."
L.POPUP_WELCOME_NAME_FALLBACK  = "Champion"
L.POPUP_WELCOME_GUIDE_BTN      = "Ouvrir le tutoriel"
L.POPUP_UPDATE_FOREVER_1000_TITLE = "Overlord Forever"
L.POPUP_UPDATE_FOREVER_1000_BODY  = "|cFFFFD100Un nouveau théâtre de guerre Overlord :|r les kills JcJ réalisés en monde ouvert dans les |cFFFFD100Hautes-terres d'Arathi|r, au |cFFFFD100Loch Modan|r, en |cFFFFD100Durotar|r et en |cFFFFD100Orneval|r sont enregistrés dans le classement Overlord.\n\n|cFFFFFFFFConditions|r\n• Votre personnage doit être de |cFFFFD100niveau 60|r.\n• Monde ouvert uniquement : raids, donjons et champs de bataille instanciés restent exclus.\n\nUn |cFFFFD100avant-poste de guilde|r vous attend sur chaque front de guerre."
L.POPUP_BATTLE_REPORT_TITLE     = "Rapport de bataille"
L.POPUP_BATTLE_REPORT_GUILD     = "Guilde dominante : %s: |cFFFFD100%d|r tués"
L.POPUP_BATTLE_REPORT_KILLER    = "Premier tueur : %s: |cFFFFD100%d|r tués"
L.POPUP_BATTLE_REPORT_CAPTURER  = "Premier capturant : %s: |cFFFFD100%d|r captures"
L.POPUP_BATTLE_REPORT_NOT_FRONT = "Rendez-vous sur une carte de front pour afficher le rapport de bataille."
L.POPUP_BATTLE_REPORT_NO_DATA   = "Aucune donnée de classement pour le rapport de bataille."
L.FEATURED_FRONT_ACTIVITY_TITLE      = "Activité récente (5 dernières min)"
L.FEATURED_FRONT_ACTIVITY_DASH       = "..."
L.FEATURED_FRONT_ACTIVITY_JUST_NOW   = "à l'instant"
L.FEATURED_FRONT_ACTIVITY_MIN_AGO    = "il y a %d min"
L.FEATURED_FRONT_ACTIVITY_KILLS      = "%d+ victimes"

L.ZONE_WAYPOINT_BLOCKED = "|cFFFFD100[Overlord]|r Impossible de placer un repère sur cette carte."
L.ZONE_WAYPOINT_FAIL    = "|cFFFFD100[Overlord]|r Échec de création du repère."

-- MapMarkers
L.MAP_AVAILABLE       = "DISPONIBLE"
L.MAP_LOCKED          = "VERROUILLÉE"
L.MAP_NEUTRAL         = "NEUTRE"
L.MAP_SYNC_PENDING    = "SYNC"
L.FRONT_ZONES_HEADER = "Zones de %s :"
L.TOOLTIP_FRIENDLY    = "Alliés : %d/%d"
L.TOOLTIP_ENEMY       = "Ennemis : %d/%d"
L.TOOLTIP_LEFT_CLICK      = "Clic gauche : Panel principal"
L.TOOLTIP_RIGHT_DRAG      = "Clic droit + drag : Déplacer"
L.DISABLED_IN_INSTANCE    = "Overlord est désactivé en instance."
L.MM_NEUTRAL          = "Neutre"
L.ZONE_NEUTRAL        = "Neutre"

-- ZoneIndicator
L.INDICATOR_TITLE = "|cFFFFFF00Zone de capture|r"
L.INDICATOR_CLICK_WAYPOINT = "Clic gauche : placer un repère"
L.IN_THE_ZONE     = "Vous êtes dans la zone !"
L.INDICATOR_DISMOUNT_TO_CAPTURE = "Descendez de votre monture."
L.INDICATOR_ENABLE_PVP = "Activez le JcJ (/pvp)."
L.INDICATOR_STEALTH_TO_CAPTURE   = "Sortez du furtif pour capturer."
L.INDICATOR_HUD_DISABLED         = "Revenez dans la zone de capture."
L.DISTANCE_FORMAT = "Distance : ~%.0f m"
L.COORDS_FORMAT   = "Coords : %.1f, %.1f"

-- Siege (timer capitale)
L.SIEGE_COOLDOWN_LABEL = "Trêve (%s)"
L.MAP_CAPITAL_LABEL = "Capitale"
L.FORCES_PRESENT = "%d %s à proximité"
L.NOT_IN_WARZONE = "Pas dans une zone de guerre"

-- Combat
L.CANNOT_IN_COMBAT   = "Impossible en combat."
L.HONORABLE_KILLS_CONFIRM = "+%d victoires honorables : Total : %d"

-- Contrats manuels (or reel)

-- Domination
L.DOMINATION_LABEL = "Domination des territoires cette semaine"

-- Sync
L.SYNC_CAPTURED_FRIENDLY = "%s capturée par %s !"
L.SYNC_CAPTURED_ENEMY    = "%s prise par %s !"
L.SYNC_CAPTURED_ENEMY_BY = "%s prise par %s (%s) !"
L.ENEMY_CAPTURING        = "%s : attaque par %s !"
L.ENEMY_CAPTURING_BY     = "%s : attaque par %s (%s) !"
L.SYNC_REQUESTED        = "Sync demandée. Vous devriez recevoir l'état à jour sous peu."
L.SYNC_WHISPER_SENT     = "Demande de sync envoyée en whisper addon à %s."
L.COMMUNITY_BTN_JOIN    = "Communauté"
L.COMMUNITY_BTN_TOOLTIP = "Invitation communauté"
L.FACTION_CALL_TOOLTIP_TITLE = "Appeler la faction"
L.FACTION_CALL_BUTTON       = "Appel aux armes"
L.GENERAL_BUTTON            = "Commander"
L.FACTION_CALL_TOOLTIP  = "Sonnez le cor de guerre ! Tous les alliés de votre faction qui ont Overlord reçoivent une alerte de raid avec votre front et votre zone."
L.FACTION_CALL_TOOLTIP_SHARED = "Une fois toutes les 4 heures pour toute la faction : un seul héraut à la fois."
L.FACTION_CALL_TOOLTIP_CD = "Disponible dans %s"
L.FACTION_CALL_COOLDOWN_SHARED = "Appel en recharge: un allié vient d'appeler (%s restant)."
L.FACTION_CALL_SENT     = "Appel envoyé à tous les alliés Overlord de votre faction."
L.FACTION_CALL_RECEIVED = "%s appelle la faction: %s (%s) !"
L.FACTION_CALL_RECEIVED_NO_ZONE = "%s appelle la faction: %s !"
L.FACTION_CALL_RECEIVED_GENERIC = "%s appelle la faction !"
L.GUILD_KILL_ALERT_ENABLED_LABEL = "Alertes de raid de guilde ennemie"
L.GUILD_KILL_ALERT_ENABLED_TOOLTIP = "Prévient dans le chat quand une guilde ennemie fait 20+ victimes avec 5+ membres en 5 minutes."
L.GUILD_KILL_ALERT = "Guilde %s : %d+ kills par %d+ membres%s !"
L.GUILD_KILL_ALERT_FRONT = "Guilde %s : %d+ kills par %d+ membres sur %s%s !"
L.GUILD_KILL_DIAG_HEADER = "Alerte de raid de guilde ennemie : %s, seuil %d kills et %d membres en 5 min."
L.GUILD_KILL_DIAG_EMPTY = "Aucun kill de guilde reçu ces 5 dernières minutes."
L.GUILD_KILL_DIAG_ROW = "%s (%s) : %d kills, %d membres"
L.HELP_GUILD_KILLS = "|cFFFFFF00/ov guildkills [on|off|test]|r : alerte de raid de guilde ennemie"
L.FACTION_CALL_NO_ONLINE  = "Aucun allié de votre faction en ligne dans la communauté."
L.FACTION_CALL_COMBAT     = "Impossible d'appeler la faction en combat verrouillé."
L.FACTION_CALL_NOT_IN_FRONT = "Vous devez être sur un front de guerre actif."
L.FACTION_CALL_TOOLTIP_NOT_IN_FRONT = "Disponible uniquement sur un front de guerre actif."
L.GENERAL_TOOLTIP_TITLE_ALLIANCE = "Général de l'Alliance"
L.GENERAL_TOOLTIP_TITLE_HORDE = "Général de la Horde"
L.GENERAL_TOOLTIP = "Prenez le commandement. Votre icône guide tous les alliés sur la carte de guerre. Un général par bannière."
L.GENERAL_TOOLTIP_RELEASE = "Cliquez à nouveau pour abandonner le commandement."
L.GENERAL_ASSUMED_SELF = "Vous êtes le général Alliance sur |cFFFFD100%s|r. La bannière suit vos pas."
L.GENERAL_ASSUMED_SELF_HORDE = "Vous êtes le général Horde sur |cFFFFD100%s|r. La bannière suit vos pas."
L.GENERAL_RELEASED_SELF = "Vous avez abandonné le commandement de la bannière."
L.GENERAL_SLOT_TAKEN = "Le général |cFFFFD100%s|r dirige déjà la bannière."
L.GENERAL_NOT_LEADER = "Seul le chef de groupe ou de raid peut prendre ce rôle."
L.GENERAL_NOT_ON_FRONT = "Vous devez être sur un front de guerre actif."
L.GENERAL_COMBAT = "Impossible de prendre le commandement en combat verrouillé."
L.GENERAL_INSTANCE = "Le commandement est indisponible en instance."
L.GENERAL_RECEIVED = "%s prend le commandement sur |cFFFFD100%s|r !"
L.GENERAL_MAP_TOOLTIP = "Général : %s"
L.GENERAL_ENEMY_MAP_TOOLTIP = "Général ennemi : %s"
L.GENERAL_FALLEN = "Le général %s est tombé ! Tué par %s."
L.GENERAL_COUNTERPART_SLAIN = "Le général ennemi %s a été abattu par %s !"
L.GENERAL_ENEMY_ASSUMED = "Le général ennemi %s prend le commandement sur |cFFFFD100%s|r !"
L.GENERAL_SHARD_UNKNOWN = "Shard différent ou inconnu."
L.VERSION_OUTDATED      = "Une nouvelle version (%s) est disponible. Mettez à jour !"
L.SPOOF_DETECTED        = "Addon modifié détecté chez %s : captures fantômes bloquées et annulées."

-- Export
L.EXPORT_CLOSE          = "Fermer"
L.FOREVER_FEATURE_UNAVAILABLE = "Indisponible sur Overlord Forever."
-- poolTag = FR | EU | US | UNKNOWN (pool Overlord pour l'export : royaume EU, pas la locale client ; frFR sur Ravencrest = EU)

-- === Anti-farming ===
L.FARM_KILL_DETECTED  = "Farming de kills supprimé : %s -> %s (%d+ kills en 5 min, stats non comptées)."

-- Mines / Or (frFR : aucun mélange avec l'anglais ; noms de zones comme dans le client)
L.MINE_AZURELODE        = "Mine de Veine-d'Azur"
L.MINE_DARROW           = "Colline de Darrow"
L.MINE_ELEMGORGE        = "Mine du Gouffre d'Elem"
L.MINE_STONESSPLINTER   = "Mine de Brisetaille"
L.MINE_JASPERLODE       = "Veine-de-Jaspe"
L.GOLD_LABEL            = "Coins"
L.GOLD_COUNTER          = "Coins : %d / %d"
L.GOLD_HEADER_TIP       = "Gagnez des coins dans les cercles indiqués. Contreforts de Hautebrande : mine de Veine-d'Azur et colline de Darrow. Forêt des Pins-Argentés : mine du Gouffre d'Elem. Loch Modan : mine de Brisetaille. Forêt d'Elwynn : Veine-de-Jaspe."
L.GOLD_NODE_BONUS       = "+%d coins (filon miné)"
L.GOLD_FCT_GAIN         = "+%d coins"
L.GOLD_NOT_ENOUGH       = "Pas assez de coins (%d requis)."
L.GOLD_REINFORCE        = "Attaquer"

-- Fortin de guilde
L.GUILD_KEEP_STONETALON     = "Retraite de Roche-Soleil"
L.GUILD_KEEP_WETLANDS       = "Donjon de Menethil"
L.GUILD_KEEP_BADLANDS       = "Forteresse d'Angor"
L.GUILD_KEEP_CROSSROADS     = "La Croisée"
L.GUILD_KEEP_MULGORE        = "Village de Sabot-de-Sang"
L.GUILD_KEEP_SELECT_TITLE   = "Choisir un fortin"
L.GUILD_KEEP_SELECT_AUTO    = "Auto (tenu par la guilde)"
L.GUILD_KEEP_NEUTRAL        = "Non revendiqué"
L.GUILD_KEEP_CAPTURING      = "Capture en cours…"
L.GUILD_KEEP_PANEL_HELD     = "Tenu par %s"
L.GOLD_BARRICADE        = "Renforcer"
L.GOLD_TOOLTIP_COST     = "Coût : %d coins."
L.ENEMY_MINING_HORDE     = "Alerte ! La Horde mine : %s !"
L.ENEMY_MINING_ALLIANCE  = "Alerte ! L'Alliance mine : %s !"
L.MINE_TOOLTIP          = "Mine de coins: restez dans le cercle pour gagner des coins."
L.MINE_ENTERED          = "Vous entrez dans %s. Gain de coins activé."
L.MINE_LEFT             = "Vous quittez %s. Gain de coins arrêté."
L.MINE_STOCK            = "Réserves de la mine : %d / %d"
L.MINE_DEPLETED         = "%s est épuisée. Les réserves se reconstituent avec le temps."
L.CATCHUP_PHASE         = "Expérience de rattrapage détectée: Overlord est inactif dans cette phase."
L.CATCHUP_MAP_BANNER    = "Phase de rattrapage: Overlord inactif"


-- ================================================================
-- ESPAGNOL (esES / esMX): Surcharge automatique pour les clients ES
-- ================================================================
elseif Overlord.IsSpanishLocale() then

L.CAPTURE_ALERT_SUBZONE_IN_REGION = "%s (%s)"

L.ZONE_NAMES = {
    stromgarde = "Castillo de Stromgarde",
    faldir     = "Cala de Faldir",
    witherbark = "Aldea Secorrojo",
    goshek     = "Granja de Go'Shek",
    dabyrie    = "Granja de Dabyrie",
    refuge     = "Refugio de la Errada",
    highperch  = "Tierras Altas occidentales",
    newstead   = "Muralla de Thoradin",
    hammerfell = "Sentencia",
    argorok    = "Círculo de Vínculo Oeste",
    loch_alliance_capital = "Thelsamar",
    loch_horde_capital = "Fortaleza Mo'grosh",
    loch_valley_of_kings = "Valle de los Reyes",
    loch_south_gate_pass = "Paso de la Puerta Sur",
    loch_silver_stream_mine = "Mina de Arroyoplata",
    loch_algaz_post = "Puesto de Algaz",
    loch_farstrider_lodge = "Avanzada del Errante",
    loch_ironband = "Excavación de Vetaferro",
    loch_the_loch = "El Loch",
    loch_stonewrought_dam = "Presa de Roca Negra",
    durotar_tiragarde_keep = "Fortaleza de Tiragarde",
    durotar_alliance_fleet = "Risco Kolkar",
    durotar_senjin_village = "Aldea Sen'jin",
    durotar_razor_hill = "Cerrotajo",
    durotar_deadeye_shore = "Costa de Ojo Muerto",
    durotar_southfury = "Furia del Sur",
    durotar_spirit_rock = "Valle de los Retos",
    durotar_thunder_ridge = "Cresta del Trueno",
    durotar_drygulch_ravine = "Barranco Seco",
    durotar_dranosh_blockade = "Entrada de Orgrimmar",
    elwynn_westbrook = "Cuartel de Río del Oeste",
    elwynn_goldshire = "Villadorada",
    elwynn_tower_of_azora = "Torre de Azora",
    elwynn_ridgepoint = "Torre de la Cresta",
    elwynn_mirror_lake = "Lago de Cristal",
    elwynn_fargodeep = "Mina de Fondo de Roca",
    elwynn_jerods_landing = "Embarcadero de Jerod",
    elwynn_stone_cairn = "Lago Peñazo",
    elwynn_eastvale = "Aserradero de Eastvale",
    elwynn_invasion_camp = "Avanzada Roca Negra",
    ash_astranaar = "Astranaar",
    ash_iris_lake = "Lago Iris",
    ash_raynewood = "Retiro de Ban'ethil",
    ash_night_run = "Noche Fugaz",
    ash_bloodtooth_camp = "Campamento Dientessangre",
    ash_silverwind = "Refugio Brisa de Plata",
    ash_mystral_lake = "Lago Mystral",
    ash_fallen_sky_lake = "Lago Cielo Estrellado",
    ash_dor_danil = "Túmulo de Dor'Danil",
    ash_splintertree = "Puesto del Hachazo",
}

L.FRONT_ARATHI_NAME = "Tierras Altas de Arathi"
L.FRONT_LOCH_MODAN_NAME = "Loch Modan"
L.FRONT_DUROTAR_NAME = "Durotar"
L.FRONT_ELWYNN_NAME = "Bosque de Elwynn"
L.FRONT_ARATHI_DROPDOWN = "Arathi"
L.FRONT_LOCH_MODAN_DROPDOWN = "Loch Modan"
L.FRONT_DUROTAR_DROPDOWN = "Durotar"
L.FRONT_ELWYNN_DROPDOWN = "Elwynn"
L.FRONT_ASHENVALE_NAME = "Vallefresno"
L.FRONT_ASHENVALE_DROPDOWN = "Vallefresno"

L.THE_HORDE    = "la Horda"
L.THE_ALLIANCE = "la Alianza"

L.VICTORY_FACTION_HORDE    = "LA HORDA"
L.VICTORY_FACTION_ALLIANCE = "LA ALIANZA"

L.DATE_FORMAT = "%d/%m/%Y"

-- Core
L.WEEKLY_RESET    = "¡Nueva semana! Campaña reiniciada según el calendario de la beta de EE. UU."
L.MODULE_ERROR    = "Error del módulo %s: %s"
L.ADDON_LOADED    = "v%s cargado. |cFFFFFF00/ov help|r para ver los comandos."
L.SYNC_LOGIN_WAIT = "Sincronizando datos de zonas... El mapa se actualizará en breve."
L.ALL_ZONES_RESET = "¡Todas las zonas se han reiniciado!"
L.FRONT_CAPITAL_RELEASED = "%s: tregua terminada. La conquista se mantiene y la capital caída se levanta; ambas capitales están protegidas hasta %s."
L.CAPITAL_PROTECTED_UNTIL = "Protegida hasta %s"
L.CAPITAL_PROTECTED_SHORT = "Hasta %s"

-- Commands
L.HELP_HEADER   = "|cFF00FF00========== Overlord: Comandos ==========|r"
L.HELP_SHOW     = "|cFFFFFF00/ov show|r: Mostrar la interfaz"
L.HELP_HIDE     = "|cFFFFFF00/ov hide|r: Ocultar la interfaz"
L.HELP_TOGGLE   = "|cFFFFFF00/ov toggle|r: Alternar la interfaz"
L.HELP_HUD      = "|cFFFFFF00/ov hud [auto|on|off|toggle]|r: Configurar el HUD superior"
L.HUD_SHOWN     = "|cFF00FF00[Overlord]|r HUD superior activado."
L.HUD_HIDDEN    = "|cFF00FF00[Overlord]|r HUD superior desactivado."
L.HUD_AUTO      = "|cFF00FF00[Overlord]|r HUD superior en modo Auto."
L.HELP_STATUS   = "|cFFFFFF00/ov status|r: Mostrar el estado de las zonas"
L.HELP_ZONES    = "|cFFFFFF00/ov zones|r: Mostrar zonas disponibles con coordenadas"
L.HELP_WHERE    = "|cFFFFFF00/ov where|r: Alternar el indicador de zona"
L.HELP_START    = "|cFFFFFF00/ov start <zone>|r: Iniciar la captura de una zona"
L.HELP_LB       = "|cFFFFFF00/ov lb|r: Mostrar la clasificación"
L.HELP_SYNC     = "|cFFFFFF00/ov sync [Jugador-Reino]|r: Pedir sync (susurro objetivo o grupo/raid/comunidad)"
L.HELP_DOM      = "|cFFFFFF00/ov dom|r: Debug barra dominación (segundos, bonus, % mostrados)"
L.HELP_SCALE    = "|cFFFFFF00/ov scale [0.8-1.2]|r: Escala del panel (también: Esc > Opciones > AddOns > Overlord)"
L.DOM_DEBUG_HEADER = "Dominación semanal:"
L.HELP_GUIDE    = "|cFFFFFF00/ov guide|r: Guía visual rápida"
L.HELP_FOOTER   = "|cFF00FF00=============================================|r"

L.STATUS_HEADER      = "|cFF00FF00========== Overlord: Estado ==========|r"
L.STATUS_IN_PROGRESS = "EN CURSO (%d:%02d de mantenimiento)"
L.STATUS_AVAILABLE   = "DISPONIBLE"
L.STATUS_LOCKED      = "BLOQUEADA"
L.STATUS_TOTAL       = "Total: %d/%d zonas (%d%%)"
L.STATUS_FOOTER      = "|cFF00FF00=============================================|r"

L.NOT_INITIALIZED  = "El addon aún no está inicializado."
L.USAGE_START      = "Uso: /ov start <zone>"
L.ZONE_UNKNOWN     = "Zona desconocida: %s"
L.ZONE_NOT_AVAILABLE = "¡%s no está disponible!"
L.MUST_BE_IN_ZONE  = "¡Debes estar en %s para iniciar la captura! (%.1f, %.1f)"
L.UNKNOWN_COMMAND  = "Comando desconocido: %s"
L.HELP_HINT        = "Escribe /ov help para ver los comandos disponibles."
L.POS_RESET        = "Posición del panel reiniciada."

-- UI
L.CONTROL_ZONES     = "ZONAS DE CONTROL"
L.ACTIVE_ZONE       = "ZONA ACTIVA"
L.NO_ACTIVE_ZONE    = "Ninguna zona activa"
L.HOLD_LABEL        = "Mantenimiento"
L.UI_CONTESTED      = "DISPUTADA"
L.UI_PAUSED         = "EN PAUSA: fuera de la zona, el temporizador decae"
L.UI_IN_PROGRESS    = "EN CURSO: mantén la posición"
L.UI_ENEMY_CAPTURING = "ENEMIGO CAPTURANDO: ¡disputa la zona!"
L.UI_COMPLETE       = "COMPLETADO"
L.ACTION_SHORTCUT_LABEL = "Acceso para la barra de acción"
L.ACTION_SHORTCUT_TOOLTIP = "Pone el icono de Overlord en el cursor: haz clic en una casilla de la barra de acción para dejarlo allí."
L.ACTION_SHORTCUT_COMBAT = "No se puede crear el acceso para la barra de acción durante el combate."
L.ACTION_SHORTCUT_FAILED = "No se pudo crear o recoger el acceso. Asegúrate de estar fuera de combate e inténtalo de nuevo."
L.UI_SCALE_LABEL    = "Escala del panel"
L.UI_SCALE_TOOLTIP  = "Tamaño del panel principal y de la clasificación. También puedes usar |cffffffff/ov scale|r."
L.NOTIFICATION_CHAT_LABEL = "Mensajes de Overlord"
L.NOTIFICATION_CHAT_TOOLTIP = "Pestaña de chat donde aparecen las alertas y mensajes de Overlord."
L.NOTIFICATION_CHAT_DEFAULT = "Chat principal (predeterminado)"
L.CHAT_TAB_LABEL = "Pestaña de Overlord"
L.CHAT_TAB_BUTTON = "Crear pestaña"
L.CHAT_TAB_TOOLTIP = "Crea una pestaña de chat llamada Overlord y envía allí los mensajes de Overlord. Muévela, ocúltala o ciérrala como cualquier pestaña."
L.CHAT_TAB_READY = "Los mensajes de Overlord aparecen ahora en esta pestaña."
L.CHAT_TAB_FAILED = "No hay pestañas de chat libres. Cierra una e inténtalo de nuevo."
L.ACTION_SHORTCUT_BUTTON = "Coger"
L.SETTINGS_SECTION_GENERAL = "General"
L.SETTINGS_SECTION_CHAT = "Chat"
L.SETTINGS_SECTION_MAP = "Mapa y minimapa"
L.SETTINGS_SECTION_HUD = "Paneles en pantalla"
L.UI_FRONT_SELECT = "Frente de batalla (lista)"
L.UI_FRONT_PICKER_TOOLTIP = "Elige qué lista de zonas mostrar. Tu temporizador de captura y el combate siguen el mapa donde peleas."
L.UI_FRONT_READONLY_TOOLTIP = "Estás viendo otro frente o no estás en una zona de guerra. Los clics no inician capturas; los waypoints usan el mapa del frente seleccionado."
L.UI_CAPTURE_READONLY = "Solo lectura: ve a este frente en el mundo abierto para capturar desde esta lista."
L.MAP_OVERLAY_OPACITY_LABEL   = "Opacidad de capturas (mapa)"
L.MAP_OVERLAY_OPACITY_TOOLTIP = "Transparencia de los círculos de captura en el |cffffffffmapa del mundo|r solamente. Valores más bajos dejan ver más detalle del mapa debajo.\nNo afecta a la minimapa (ver Opacidad de capturas (minimapa)) ni a los círculos de minas de coins."
L.MINIMAP_OVERLAY_OPACITY_LABEL   = "Opacidad de capturas (minimapa)"
L.MINIMAP_OVERLAY_OPACITY_TOOLTIP = "Transparencia de los círculos de captura en la |cffffffffminimapa|r. Valores más bajos dejan ver más detalle del mapa debajo.\nNo afecta al mapa del mundo, a los iconos de fortín ni a los círculos de minas de coins."
L.MAP_ICON_OPACITY_LABEL = "Opacidad de iconos (mapa)"
L.MAP_ICON_OPACITY_TOOLTIP = "Transparencia de los iconos de puntos de captura, fortalezas y puestos avanzados en el |cffffffffmapa del mundo|r. Un valor bajo deja ver los marcadores de misión en las ciudades. En 0 se ocultan."
L.MAP_ICON_SCALE_LABEL = "Tamaño de iconos (mapa)"
L.MAP_ICON_SCALE_TOOLTIP = "Tamaño de los iconos de capitales, puntos de captura, fortalezas y puestos avanzados en el |cffffffffmapa del mundo|r."
L.MINIMAP_BUTTON_LABEL          = "Botón del minimapa"
L.MINIMAP_BUTTON_TOOLTIP        = "Muestra el botón de Overlord alrededor del minimapa. Actívalo para recuperarlo; los gestores de botones del minimapa pueden guardarlo en su propio menú."
L.MINIMAP_CAPTURE_ZONES_LABEL   = "Iconos del minimapa"
L.MINIMAP_CAPTURE_ZONES_TOOLTIP = "Muestra los iconos de Overlord en el |cffffffffminimapa|r: círculos de captura, generales, minas, fortalezas de hermandad y puestos avanzados. El ratón atraviesa los iconos hasta el rastreo de cazador y comida. Desactiva para ocultarlos todos (el mapa del mundo conserva sus propios ajustes)."
L.MAP_ZONE_TITLES_LABEL         = "Nombres de zonas (mapa)"
L.MAP_ZONE_TITLES_TOOLTIP       = "Muestra los carteles parchment con el nombre de zonas de captura y minas de coins en el |cffffffffmapa del mundo|r. Desactívalo para un mapa más limpio si ya conoces las zonas."
L.MAP_PATH_OPACITY_LABEL      = "Opacidad de rutas (mapa)"
L.MAP_PATH_OPACITY_TOOLTIP    = "Opacidad de las |cfffffffflíneas punteadas|r entre zonas de captura en el mapa del mundo (1 = tenue, 3 = muy visible)."
L.SETTINGS_TOGGLE_ON          = "Activado"
L.SETTINGS_TOGGLE_OFF         = "Desactivado"
L.AUTO_WAYPOINT_LABEL         = "Pin automático de objetivo"
L.AUTO_WAYPOINT_TOOLTIP       = "Coloca el pin de mapa de Blizzard en el próximo objetivo disponible. Si quitas o reemplazas ese pin, Overlord espera a un objetivo nuevo antes de colocarlo otra vez. El pin se retira cuando el objetivo deja de ser válido."
L.SHOW_TOP_HUD_LABEL          = "HUD superior"
L.SHOW_TOP_HUD_TOOLTIP        = "Auto muestra los paneles útiles cerca de capturas, minas y fortalezas. Siempre los muestra en los mapas pertinentes; Nunca los oculta. El indicador de objetivo sigue disponible."
L.TOP_HUD_MODE_AUTO           = "Auto"
L.TOP_HUD_MODE_ALWAYS         = "Siempre"
L.TOP_HUD_MODE_NEVER          = "Nunca"
L.SHOW_TUTORIAL_BOOK_LABEL    = "Icono libro tutorial"
L.SHOW_TUTORIAL_BOOK_TOOLTIP  = "Muestra el icono del libro tutorial en el HUD superior. Desactívalo para ocultar solo ese icono y conservar los paneles de coins y fortaleza."
L.SOUND_ENABLED_LABEL         = "Sonidos de Overlord"
L.SOUND_ENABLED_TOOLTIP       = "Silencia todos los sonidos de Overlord (alertas, cuerno de guerra, capturas, paneles, buff de coins, música de duelo del general, etc.)."
L.SETTINGS_BUTTON             = "Opciones"
L.LAYER_JUMPER_BUTTON = "Layer Jumper"
L.NET_HEALTH_TITLE = "Red de Overlord"
L.NET_HEALTH_OK = "Todo bien"
L.NET_HEALTH_WARN = "A vigilar"
L.NET_HEALTH_BAD = "Problema"
L.NET_HEALTH_HINT = "Escribe /ov network para ver el detalle."
L.MW_ALERT = "¡Most Wanted cerca: %s (#%d %s, %d muertes esta semana)!"
L.HELP_WANTED = "|cFFFFFF00/ov wanted [on|off]|r: Most Wanted: aviso cuando uno de los 5 mejores enemigos está cerca"
L.MW_STATE_ON = "Avisos Most Wanted: activados"
L.MW_STATE_OFF = "Avisos Most Wanted: desactivados"
L.LAYER_JUMPER_TOOLTIP = "Cambiar de capa en tu zona"
L.HELP_LAYER = "|cFFFFFF00/ov layer [help on|off]|r: Layer Jumper (cambiar de capa; ayudar como voluntario)"
L.LJ_TITLE = "Layer Jumper"
L.LJ_ZONE_LAYER = "%s - tu capa: %s"
L.LJ_LAYER_UNKNOWN = "desconocida"
L.LJ_LAYER_NAME = "Capa #%s"
L.LJ_HELPERS = "%d ayudante(s)"
L.LJ_HERE = "estás aquí"
L.LJ_JOIN = "Unirse"
L.LJ_SEARCH = "Buscar"
L.LJ_RANDOM = "Cambiar de capa"
L.LJ_RANDOM_TOOLTIP = "Saltar a cualquier otra capa de esta zona (busca primero si hace falta)."
L.LJ_CANCEL = "Cancelar"
L.LJ_LIST_EMPTY = "Selecciona un PNJ para leer tu capa y pulsa Buscar para ver las capas de esta zona."
L.LJ_HELP_MODE = "Ayudar a otros: %s"
L.LJ_HELP_MODE_AUTO = "activado"
L.LJ_HELP_MODE_OFF = "desactivado"
L.LJ_HELP_MODE_TOOLTIP = "Ayudante voluntario (desactivado por defecto). Activado, invitas automáticamente, sin ventana, al jugador de Overlord de tu facción que busca tu capa; sale del grupo tras el cambio. Solo si estás solo, fuera de combate y de instancias."
L.LJ_EXPLAIN = "Un ayudante voluntario de la capa elegida te invita a un grupo. Fuera de combate, el juego te mueve a su capa en unos segundos y luego sales del grupo automáticamente. Solo se comparten tu zona y tu capa, nunca tu posición."
L.LJ_STATUS_IDLE = "Busca ayudantes en tu zona."
L.LJ_STATUS_SEARCHING = "Buscando ayudantes en %s..."
L.LJ_STATUS_READY = "%d ayudante(s) encontrado(s)."
L.LJ_STATUS_NONE = "No hay ayudantes voluntarios disponibles en esta zona ahora. Inténtalo en un momento o en una zona más poblada."
L.LJ_STATUS_REQUESTING = "Pidiendo invitación a %s..."
L.LJ_STATUS_JOINING = "Invitación aceptada, entrando en el grupo de %s..."
L.LJ_STATUS_VERIFYING = "Cambiando de capa... (%ds)"
L.LJ_STATUS_VERIFY_COMBAT = "En combate: el cambio espera al final del combate (%ds)."
L.LJ_STATUS_SUCCESS = "Hecho: ahora estás en %s."
L.LJ_STATUS_UNCONFIRMED = "Has salido del grupo; no se pudo confirmar la nueva capa (ningún PNJ a la vista)."
L.LJ_STATUS_CROWDED = "Has salido del grupo: el ayudante metió a otros jugadores."
L.LJ_STATUS_FAILED = "Ningún ayudante te invitó. Inténtalo de nuevo en un momento."
L.LJ_STATUS_CANCELLED = "Cancelado."
L.LJ_ERR_GROUPED = "Sal primero de tu grupo: el ayudante debe invitarte."
L.LJ_ERR_INSTANCE = "No disponible en instancias ni campos de batalla."
L.LJ_ERR_QUEUE = "No disponible mientras esperas un campo de batalla."
L.LJ_ERR_COOLDOWN = "Espera %d s antes de buscar de nuevo."
L.LJ_ERR_SAME_LAYER = "Ya estás en esta capa."
L.LJ_ERR_NO_NETWORK = "La red de Overlord aún no está lista (sin hermandad ni canal). Inténtalo en un momento."
L.LJ_ERR_LAYER_UNKNOWN = "Selecciona antes un PNJ: tu capa debe conocerse para saltar a otra."
L.LJ_GUEST_REMOVED = "%s ha salido del grupo (cambio de capa terminado)."
L.LJ_LATE_LEAVE = "Has salido del grupo de %s: ese salto de capa estaba cancelado."
L.CHECK_PVP_BUTTON = "Exportar"
L.SETTINGS_BUTTON_TOOLTIP     = "Abre las opciones de Overlord."
L.SETTINGS_OPEN_UNAVAILABLE   = "Las opciones no están disponibles ahora. Usa Esc, luego Opciones, luego AddOns."
L.SCALE_CURRENT     = "Escala del panel: %.1f (rango de %.1f a %.1f)."
L.SCALE_SET         = "Escala del panel: %.1f."
L.ATTACK            = "¡Atacar!"
L.LOCKED            = "Bloqueada"
L.NEXT_OBJECTIVE_HEADER   = "Próximo objetivo"
L.NEXT_OBJECTIVE_COLLAPSE = "Ocultar próximo objetivo"
L.NEXT_OBJECTIVE_NONE = "Ningún objetivo disponible"
L.NEXT_OBJECTIVE_NO_FRONT = "Fuera de un frente de guerra"
-- Outside a war front: one short line for the player's race (faction fallback).
L.HOME_MOTTOS = {
    Human = "Ventormenta resiste.",
    Dwarf = "Forjaz nunca se rinde.",
    Gnome = "¡Gnomeregan resurgirá!",
    NightElf = "Bajo la mirada de Elune.",
    Orc = "¡Lok'tar ogar!",
    Troll = "Los espíritus vigilan.",
    Scourge = "La Dama Oscura vigila.",
    Tauren = "La Madre Tierra guía.",
    Skyborne = "El canto de los vientos.",
    Alliance = "¡Por la Alianza!",
    Horde = "¡Por la Horda!",
}
L.NEXT_OBJECTIVE_OUTSIDE_FRONT = "Entra en un frente para ver tu próximo objetivo."
L.NEXT_OBJECTIVE_GO         = "Ve aquí: permanece en la zona para iniciar el temporizador de captura."
L.GUIDE_BAR_LABEL           = "Guía"
L.GUIDE_CLOSE               = "Cerrar"
L.GUIDE_TITLE               = "Guía"
L.GUIDE_PAGE_INDICATOR      = "Página %d / %d"
L.GUIDE_PREV                = "Anterior"
L.GUIDE_NEXT                = "Siguiente"
L.GUIDE_PAGE2_TITLE         = "Capturas y recursos"
L.VICTORY_DOMINATION_BONUS  = "Victoria total del frente: +%d %% de dominación semanal para tu facción."
L.TOOLTIP_SHIFT_GUIDE       = "Mayús + clic izquierdo: guía rápida"

-- Shard
L.SHARD_TOOLTIP_TITLE          = "ID de shard"
L.SHARD_TOOLTIP_CURRENT        = "ID de shard actual: %s"
L.SHARD_TOOLTIP_REFERENCE_REALM = "Jugador de referencia: %s"
L.SHARD_BADGE_REFERENCE       = "vía %s"
L.SHARD_TOOLTIP_PLAYERS_HEADER = "Jugadores en otro shard:"
L.SHARD_TOOLTIP_ALL_SAME       = "Todos los jugadores sincronizados están en el mismo shard."
L.SHARD_TOOLTIP_UNDETECTED     = "Shard aún no detectado (sin viñeta, PNJ bajo el cursor o GUID de nameplate disponible)."
L.SHARD_ALERT_TAG              = " #%s"

L.ASSAULT_LAUNCHED    = "¡Asalto a %s iniciado!"
L.CAPTURE_LAUNCHED    = "¡Captura de %s iniciada!"
L.GO_TO_ZONE          = "¡Ve a %s (%.1f, %.1f) para capturar!"
L.ENEMY_CONTROL_MSG   = "%s está bajo control enemigo. Captura primero los prerrequisitos."
L.CAPTURE_BLOCKED_RULES = "%s aún no se puede capturar (tregua del frente, capital protegida o prerrequisitos)."
L.ZONE_IS_LOCKED      = "%s está bloqueada."
L.ALREADY_IN_PROGRESS = "%s ya en curso..."
L.ZONE_UNDER_CONTROL  = "%s está bajo el control de %s."

-- Zones
L.CAPTURE_CANCELLED  = "¡Captura de %s cancelada! Prerrequisitos perdidos."
L.ZONE_NOW_AVAILABLE = "¡%s ya está disponible para capturar!"

-- ZoneControl
L.ENTERED_ZONE       = "¡Has entrado en %s! ¡Captura iniciada!"
L.CAPTURE_NEEDS_PVP = "%s: activa el JcJ (/pvp) para capturar este objetivo."
L.AUTO_DISMOUNT_CAPTURE_CIRCLE = "Estás volando en %s: desmontaje automático en %d segundos."
L.AUTO_DISMOUNT_MINE_CIRCLE    = "Estás volando en el círculo de la mina %s: desmontaje automático en %d segundos."
L.HOLD_TIMER_STARTED = "Temporizador de mantenimiento iniciado para %s (%d:%02d). ¡Permanece en la zona!"
L.CAPTURE_SYNC_WAITING = "Sync inicial pendiente: captura de %s bloqueada temporalmente."
L.ZONE_CONTESTED_OUTNUMBER = "¡%s está disputada! Enemigos en superioridad numérica (%d vs %d)."
L.ZONE_CONTESTED_EVEN      = "¡%s está disputada! Fuerzas en igualdad (%d vs %d)."
L.ZONE_SECURED       = "¡%s asegurada! La captura continúa."
L.BACK_IN_ZONE       = "¡Has vuelto a %s! La captura continúa."
L.LEFT_ZONE          = "¡Has abandonado %s! El progreso decae..."
L.CAPTURE_LOST       = "¡Captura de %s perdida! Vuelve allí para reiniciar."
L.ENEMY_CAPTURE_REVERSED = "¡Captura enemiga de %s revertida! Zona asegurada."
L.ZONE_CAPTURED_BY   = "¡%s ha sido capturada por %s!"
L.TOTAL_VICTORY_MSG  = "   ¡VICTORIA TOTAL DE %s!   "
L.TOTAL_VICTORY_FRONT_MSG = "   ¡VICTORIA TOTAL DE %s! Frente: %s   "

-- LeaderboardUI
L.LB_TITLE         = "CLASIFICACIÓN"
L.LB_SEARCH_PLACEHOLDER = "Jugador o hermandad..."
L.LB_SEARCH_EMPTY = "Sin resultados"
L.LB_SEARCH_WORKING = "Buscando..."
L.LB_BUTTON        = "Clasificación"
L.LB_BUTTON_TOOLTIP = "Abrir la clasificación de eliminaciones y capturas semanal"
L.HOF_BUTTON        = "Salón de la Fama"
L.HOF_BUTTON_TOOLTIP = "Abrir el Salón de la Fama: honores, hazañas y donantes"
L.DISCORD_BUTTON = "Discord"
L.DISCORD_BUTTON_TOOLTIP = "Unirse al servidor Discord"
L.DISCORD_POPUP_TITLE = "Unirse al servidor Discord"
L.DISCORD_POPUP_HINT = "Abre Discord en tu navegador y pega el enlace de invitación abajo."
L.DISCORD_URL_LABEL = "Enlace de invitación de Discord"
L.DISCORD_POPUP_COPY_HINT = "URL seleccionada: copiar (Ctrl+C)"
L.HOF_TITLE = "Salón de la Fama"
L.HOF_SECTION_EMPTY = "Ninguna entrada por ahora."
L.HOF_CAT_GUILD = "Honores de hermandad"
L.HOF_CAT_PLAYER = "Honores de jugadores"
L.HOF_CAT_LIFETIME = "Tus hazañas"
L.HOF_PROGRESS_COUNT = "%d / %d"
L.HOF_CAT_ALLIANCE = "Alianza"
L.HOF_CAT_HORDE = "Horda"
L.HOF_CAT_WEEKLY = "Hazañas semanales"
L.HOF_CAT_DONORS = "Donantes"
L.HOF_DONOR_LINE = "Más de 100 monedas de oro al tesoro de guerra"
L.HOF_POINTS_LABEL = "Puntos de hazañas de frentes"
L.HOF_RECENT_TITLE = "Logros recientes"
L.HOF_PROGRESS_TITLE = "Resumen de progreso"
L.HOF_PROGRESS_TOTAL = "Honores obtenidos"
L.HOF_SEARCH_NO_RESULTS = "Ningún honor coincide."
L.HOF_WEEKLY_PLAYER_RANK_LINE = "Beta, asesinos de la semana: puesto %d"
L.HOF_WEEKLY_GUILD_RANK_LINE = "Beta, hermandades de la semana: puesto %d"
L.LB_CAMPAIGN_DATE = "Campaña del %s al %s"
L.LB_INFO_ENDS = "La campaña termina en"
L.LB_INFO_RANKED = "Jugadores clasificados:"
L.LB_INFO_RANKED_VALUE = "|cFF4488FF%s Alianza|r · |cFFFF4444%s Horda|r"
L.LB_INFO_YOU = "Tú:"
L.LB_INFO_UNRANKED = "aún sin clasificar"
L.LB_INFO_NEXT = "%s MH para pasar al #%d"
L.LB_INFO_FIRST = "¡Lideras la clasificación!"
L.LB_RULESET_LABEL = "Campaña %s"
L.RULESET_NAME_PVP = "JcJ"
L.RULESET_NAME_NORMAL = "Normal"
L.RULESET_NAME_RP = "RP"
L.RULESET_NAME_HARDCORE = "Hardcore"
L.LB_CACHED_REFRESHING = "Clasificación guardada · actualizando…"
L.LB_COL_CLASS     = "Clase"
L.LB_COL_RACE      = "Raza"
L.LB_COL_PLAYER    = "Jugador"
L.LB_COL_KILLS     = "MH"
L.LB_TOTAL_FORMAT  = "|cFF4488FFAlianza: %d muertes|r  |cFFFF4444Horda: %d muertes|r"
L.LB_CAPTURES_ALLIANCE = "Alianza: Capturas"
L.LB_CAPTURES_HORDE    = "Horda: Capturas"
L.LB_CAPTURES_SCROLL_TOOLTIP = "Rueda del ratón para desplazar la lista"
L.LB_KILLS_SCROLL_TOOLTIP     = "Rueda del ratón para desplazar la clasificación"
L.LB_ROW_GUILD = "Hermandad: %s"
L.LB_ROW_NO_GUILD = "Hermandad desconocida"
L.LB_GUILD_TIP_SUMMARY = "%d miembros clasificados, %d muertes"
L.LB_GUILD_TIP_MORE = "+ %d más"
L.LB_GUILD_TIP_TOTAL = "%d muertes"
L.LB_COL_GUILD                = "Hermandad"
L.LB_COL_KEEP                 = "Fortaleza"
L.LB_GUILD_EMPTY              = "Aún no hay hermandades clasificadas."
L.LB_GUILD_KEEP_EMPTY         = "Ninguna hermandad mantiene una fortaleza."
L.LB_COL_OUTPOST              = "Avanzada"
L.LB_COL_CAPTURES             = "Capturas"
L.LB_OUTPOST_EMPTY            = "Aún no hay capturas de avanzadas."
L.OUTPOST_SHORT               = "Avanzada"
L.OUTPOST_LOCH_MODAN_NAME     = "Retiro de Katrell"
L.OUTPOST_ARATHI_NAME         = "Torre de Sage"
L.OUTPOST_DUROTAR_NAME        = "Granja Javaguja"
L.OUTPOST_ELWYNN_NAME         = "Cascadas del Trueno"
L.OUTPOST_ASHENVALE_NAME      = "Shobek'Aran"
L.OUTPOST_NEUTRAL             = "Sin reclamar"
L.OUTPOST_CAPTURING           = "Capturando…"
L.OUTPOST_NO_GUILD            = "Debes estar en una hermandad para capturar una avanzada."
L.OUTPOST_HOLD_STARTED        = "Capturando %s (%d min)…"
L.OUTPOST_CAPTURE_LOST        = "Captura de avanzada perdida."
L.OUTPOST_UNDER_ATTACK        = "¡%s está bajo ataque!"
L.OUTPOST_CONTESTED_OUTNUMBER = "¡%s contestada! Los enemigos dominan (%d vs %d). El progreso retrocede."
L.OUTPOST_CONTESTED_EVEN      = "¡%s contestada! Fuerzas en paridad (%d vs %d). Progreso detenido."
L.OUTPOST_INDICATOR_TITLE     = "|cFFFFFF00Captura de avanzada|r"
L.OUTPOST_DEFENSE_TITLE       = "|cFFFFFF00Defensa de avanzada|r"
L.OUTPOST_ON_POINT            = "Estás en el cuadrado de la avanzada."
L.OUTPOST_ASSAULT_READY       = "Asalto disponible: mantén el cuadrado %d min."
L.OUTPOST_PANEL_HELD          = "Mantenida por %s"
L.OUTPOST_CAPTURE_ALERT_FRIENDLY = "¡%s ahora la mantiene la hermandad %s!"
L.OUTPOST_CAPTURE_ALERT_ENEMY    = "¡%s capturada por la hermandad %s (%s)!"
L.OUTPOST_DEFENDER_UNDER_ATTACK = "¡%s: la avanzada de tu hermandad está bajo ataque (%s)!"
L.OUTPOST_DEFENDER_UNDER_ATTACK_BY = "¡%s: la avanzada de tu hermandad está bajo ataque de la hermandad %s (%s)!"
L.OUTPOST_ALLIED_UNDER_ATTACK = "¡%s: avanzada aliada de la hermandad %s bajo ataque (%s)!"
L.OUTPOST_ENEMY_ASSAULT      = "¡%s: %s lanzó un asalto!"
L.OUTPOST_ENEMY_ASSAULT_VS   = "¡%s: %s asalta a %s!"
L.OUTPOST_ALLY_ASSAULT       = "%s: %s inició un asalto."
L.OUTPOST_ALLY_ASSAULT_VS    = "%s: %s inició un asalto contra %s."

L.POPUP_OK = "Entendido"
L.POPUP_WELCOME_TITLE_ALLIANCE = "Por la Alianza"
L.POPUP_WELCOME_TITLE_HORDE    = "Por la Horda"
L.POPUP_WELCOME_BODY           = "Bienvenido al campo de batalla, |cFFFFD100%s|r.\n\nVe a un |cFFFFD100|Haddon:Overlord:panel|hfrente de guerra|h|r y lee el |cFFFFD100tutorial|r (|cFFFFD100icono del libro|r en la parte superior de la pantalla)."
L.POPUP_WELCOME_NAME_FALLBACK  = "Campeón"
L.POPUP_WELCOME_GUIDE_BTN      = "Abrir tutorial"
L.POPUP_UPDATE_FOREVER_1000_TITLE = "Overlord Forever"
L.POPUP_UPDATE_FOREVER_1000_BODY  = "|cFFFFD100Un nuevo campo de batalla de Overlord:|r las muertes JcJ conseguidas en el mundo abierto de las |cFFFFD100Tierras Altas de Arathi|r, |cFFFFD100Loch Modan|r, |cFFFFD100Durotar|r y |cFFFFD100Vallefresno|r se registran en la clasificación de Overlord.\n\n|cFFFFFFFFRequisitos|r\n• Tu personaje debe ser de |cFFFFD100nivel 60|r.\n• Solo en el mundo abierto: las bandas, mazmorras y campos de batalla instanciados siguen excluidos.\n\nUn |cFFFFD100puesto de avanzada de hermandad|r te espera en cada frente de guerra."
L.POPUP_BATTLE_REPORT_TITLE     = "Informe de batalla"
L.POPUP_BATTLE_REPORT_GUILD     = "Hermandad dominante: %s: |cFFFFD100%d|r muertes"
L.POPUP_BATTLE_REPORT_KILLER    = "Mejor asesino: %s: |cFFFFD100%d|r muertes"
L.POPUP_BATTLE_REPORT_CAPTURER  = "Mejor capturador: %s: |cFFFFD100%d|r capturas"
L.POPUP_BATTLE_REPORT_NOT_FRONT = "Ve al mapa de un frente de guerra para ver el informe de batalla."
L.POPUP_BATTLE_REPORT_NO_DATA   = "Aún no hay datos de clasificación para el informe de batalla."
L.FEATURED_FRONT_ACTIVITY_TITLE      = "Actividad reciente (últimos 5 min)"
L.FEATURED_FRONT_ACTIVITY_DASH       = "..."
L.FEATURED_FRONT_ACTIVITY_JUST_NOW   = "ahora"
L.FEATURED_FRONT_ACTIVITY_MIN_AGO    = "hace %d min"
L.FEATURED_FRONT_ACTIVITY_KILLS      = "%d+ muertes"

L.ZONE_WAYPOINT_BLOCKED = "|cFFFFD100[Overlord]|r No se puede colocar un pin en este mapa."
L.ZONE_WAYPOINT_FAIL    = "|cFFFFD100[Overlord]|r No se pudo crear el pin del mapa."

-- MapMarkers
L.MAP_AVAILABLE       = "DISPONIBLE"
L.MAP_LOCKED          = "BLOQUEADA"
L.MAP_NEUTRAL         = "NEUTRO"
L.MAP_SYNC_PENDING    = "SINCRONIZANDO"
L.FRONT_ZONES_HEADER = "Zonas de %s:"
L.TOOLTIP_FRIENDLY    = "Aliados: %d/%d"
L.TOOLTIP_ENEMY       = "Enemigos: %d/%d"
L.TOOLTIP_LEFT_CLICK      = "Clic izquierdo: panel principal"
L.TOOLTIP_RIGHT_DRAG      = "Clic derecho + arrastrar: mover"
L.DISABLED_IN_INSTANCE    = "Overlord está desactivado en instancias."
L.MM_NEUTRAL          = "Neutral"
L.ZONE_NEUTRAL        = "Neutral"

-- ZoneIndicator
L.INDICATOR_TITLE = "|cFFFFFF00Zona de captura|r"
L.INDICATOR_CLICK_WAYPOINT = "Clic izquierdo: colocar waypoint"
L.IN_THE_ZONE     = "¡Estás en la zona!"
L.INDICATOR_DISMOUNT_TO_CAPTURE = "Desmonta."
L.INDICATOR_ENABLE_PVP = "Activa el JcJ (/pvp)."
L.INDICATOR_STEALTH_TO_CAPTURE   = "Sal del sigilo para capturar."
L.INDICATOR_HUD_DISABLED         = "Vuelve a la zona de captura."
L.DISTANCE_FORMAT = "Distancia: ~%.0f m"
L.COORDS_FORMAT   = "Coordenadas: %.1f, %.1f"

-- Siege
L.SIEGE_COOLDOWN_LABEL = "Tregua (%s)"
L.MAP_CAPITAL_LABEL = "Capital"
L.FORCES_PRESENT = "%d %s cerca"
L.NOT_IN_WARZONE = "No estás en una zona de guerra"

-- Combat
L.CANNOT_IN_COMBAT   = "No se puede abrir en combate."
L.HONORABLE_KILLS_CONFIRM = "+%d victorias honorables: total: %d"

-- Contratos manuales (oro real)

-- Domination
L.DOMINATION_LABEL = "Dominación territorial semanal"

-- Sync
L.SYNC_CAPTURED_FRIENDLY = "¡%s capturada por %s!"
L.SYNC_CAPTURED_ENEMY    = "¡%s tomada por %s!"
L.SYNC_CAPTURED_ENEMY_BY = "¡%s tomada por %s (%s)!"
L.ENEMY_CAPTURING        = "¡%s bajo ataque de %s!"
L.ENEMY_CAPTURING_BY     = "¡%s bajo ataque de %s (%s)!"
L.SYNC_REQUESTED        = "Sync solicitada. Deberías recibir el estado actual en breve."
L.SYNC_WHISPER_SENT     = "Solicitud de sync enviada por susurro addon a %s."
L.COMMUNITY_BTN_JOIN    = "Comunidad"
L.COMMUNITY_BTN_TOOLTIP = "Invitación comunidad"
L.FACTION_CALL_TOOLTIP_TITLE = "Llamar a la facción"
L.FACTION_CALL_BUTTON       = "Cuerno"
L.GENERAL_BUTTON            = "Comandar"
L.FACTION_CALL_TOOLTIP  = "¡Toca el cuerno de guerra! Todos los aliados de tu facción con Overlord reciben un aviso de banda con tu frente y tu zona."
L.FACTION_CALL_TOOLTIP_SHARED = "Una vez cada 4 horas para toda la facción: solo un heraldo a la vez."
L.FACTION_CALL_TOOLTIP_CD = "Disponible en %s"
L.FACTION_CALL_COOLDOWN_SHARED = "Llamada de facción en recarga: un aliado llamó hace poco (%s restante)."
L.FACTION_CALL_SENT     = "Llamada enviada a todos los aliados de tu facción con Overlord."
L.FACTION_CALL_RECEIVED = "¡%s llama a la facción: %s (%s)!"
L.FACTION_CALL_RECEIVED_NO_ZONE = "¡%s llama a la facción: %s!"
L.FACTION_CALL_RECEIVED_GENERIC = "¡%s llama a la facción!"
L.GUILD_KILL_ALERT_ENABLED_LABEL = "Alertas de raid de hermandad enemiga"
L.GUILD_KILL_ALERT_ENABLED_TOOLTIP = "Avisa en el chat cuando una hermandad enemiga consigue 20+ muertes con 5+ miembros en 5 minutos."
L.GUILD_KILL_ALERT = "¡Hermandad %s: %d+ muertes por %d+ miembros%s!"
L.GUILD_KILL_ALERT_FRONT = "¡Hermandad %s: %d+ muertes por %d+ miembros en %s%s!"
L.GUILD_KILL_DIAG_HEADER = "Alerta de raid de hermandad enemiga: %s, umbral %d muertes y %d miembros en 5 min."
L.GUILD_KILL_DIAG_EMPTY = "Ninguna muerte de hermandad recibida en los últimos 5 minutos."
L.GUILD_KILL_DIAG_ROW = "%s (%s): %d muertes, %d miembros"
L.HELP_GUILD_KILLS = "|cFFFFFF00/ov guildkills [on|off|test]|r: alerta de raid de hermandad enemiga"
L.FACTION_CALL_NO_ONLINE  = "No hay aliados de tu facción en línea en la comunidad."
L.FACTION_CALL_COMBAT     = "No se puede llamar a la facción durante el bloqueo de combate."
L.FACTION_CALL_NOT_IN_FRONT = "Debes estar en un frente de guerra activo."
L.FACTION_CALL_TOOLTIP_NOT_IN_FRONT = "Disponible solo en un frente de guerra activo."
L.GENERAL_TOOLTIP_TITLE_ALLIANCE = "General de la Alianza"
L.GENERAL_TOOLTIP_TITLE_HORDE = "General de la Horda"
L.GENERAL_TOOLTIP = "Asume el mando. Tu icono guía a todos los aliados en el mapa de guerra. Un general por bandera."
L.GENERAL_TOOLTIP_RELEASE = "Haz clic de nuevo para ceder el mando."
L.GENERAL_ASSUMED_SELF = "Eres el general de la Alianza en |cFFFFD100%s|r. La bandera sigue tus pasos."
L.GENERAL_ASSUMED_SELF_HORDE = "Eres el general de la Horda en |cFFFFD100%s|r. La bandera sigue tus pasos."
L.GENERAL_RELEASED_SELF = "Has cedido el mando de la bandera."
L.GENERAL_SLOT_TAKEN = "El general |cFFFFD100%s|r ya dirige la bandera."
L.GENERAL_NOT_LEADER = "Solo el líder de grupo o banda puede asumir este rol."
L.GENERAL_NOT_ON_FRONT = "Debes estar en un frente de guerra activo."
L.GENERAL_COMBAT = "No se puede asumir el mando durante el bloqueo de combate."
L.GENERAL_INSTANCE = "El mando no está disponible en instancias."
L.GENERAL_RECEIVED = "¡%s asume el mando en |cFFFFD100%s|r!"
L.GENERAL_MAP_TOOLTIP = "General: %s"
L.GENERAL_ENEMY_MAP_TOOLTIP = "General enemigo: %s"
L.GENERAL_FALLEN = "¡El general %s ha caído! Abatido por %s."
L.GENERAL_COUNTERPART_SLAIN = "¡El general enemigo %s ha sido abatido por %s!"
L.GENERAL_ENEMY_ASSUMED = "¡El general enemigo %s toma el mando en |cFFFFD100%s|r!"
L.GENERAL_SHARD_UNKNOWN = "Shard diferente o desconocido."
L.VERSION_OUTDATED      = "Hay una versión más reciente (%s). ¡Actualiza!"
L.SPOOF_DETECTED        = "Addon modificado detectado de %s: capturas fantasma bloqueadas y revertidas."

-- Anti-farming
L.FARM_KILL_DETECTED  = "Farmeo de muertes suprimido: %s -> %s (%d+ muertes en 5 min, estadísticas no contadas)."

-- Export
L.EXPORT_CLOSE          = "Cerrar"
L.FOREVER_FEATURE_UNAVAILABLE = "No disponible en Overlord Forever."

-- Mines / Gold
L.MINE_AZURELODE        = "Mina de Veta Azur"
L.MINE_DARROW           = "Colina Darrow"
L.MINE_ELEMGORGE        = "Mina de Elemgorge"
L.MINE_STONESSPLINTER   = "Mina Partedura"
L.MINE_JASPERLODE       = "Mina de Jaspe"
L.GOLD_LABEL            = "Coins"
L.GOLD_COUNTER          = "Coins: %d / %d"
L.GOLD_HEADER_TIP       = "Gana coins dentro de los círculos marcados. Laderas de Trabalomas: mina Veta Azur y colina Darrow. Bosque de Argénteos: mina Elemgorge. Loch Modan: mina Partedura. Bosque de Elwynn: mina de Jaspe."
L.GOLD_NODE_BONUS       = "+%d coins (veta minada)"
L.GOLD_FCT_GAIN         = "+%d coins"
L.GOLD_NOT_ENOUGH       = "Coins insuficiente (se requieren %d)."
L.GOLD_REINFORCE        = "Atacar"

-- Guild Keep
L.GUILD_KEEP_STONETALON     = "Refugio Roca del Sol"
L.GUILD_KEEP_WETLANDS       = "Fortaleza de Menethil"
L.GUILD_KEEP_BADLANDS       = "Fortaleza de Angor"
L.GUILD_KEEP_CROSSROADS     = "El Cruce"
L.GUILD_KEEP_MULGORE        = "Poblado Pezuña de Sangre"
L.GUILD_KEEP_SELECT_TITLE   = "Elegir fortaleza"
L.GUILD_KEEP_SELECT_AUTO    = "Auto (mantenida por hermandad)"
L.GUILD_KEEP_NEUTRAL        = "Sin reclamar"
L.GUILD_KEEP_CAPTURING      = "Capturando…"
L.GUILD_KEEP_PANEL_HELD     = "Mantenida por %s"
L.GOLD_BARRICADE        = "Reforzar"
L.GOLD_TOOLTIP_COST     = "Costo: %d coins."
L.ENEMY_MINING_HORDE     = "¡Alerta! ¡La Horda está minando en %s!"
L.ENEMY_MINING_ALLIANCE  = "¡Alerta! ¡La Alianza está minando en %s!"
L.MINE_TOOLTIP          = "Mina de coins: permanece dentro del círculo para ganar coins."
L.MINE_ENTERED          = "Has entrado en %s. Generación de coins iniciada."
L.MINE_LEFT             = "Has abandonado %s. Generación de coins detenida."
L.MINE_STOCK            = "Reservas de la mina: %d / %d"
L.MINE_DEPLETED         = "%s está agotada. Las reservas se repondrán con el tiempo."
L.CATCHUP_PHASE         = "Experiencia de recuperación detectada: Overlord está inactivo en esta fase."
L.CATCHUP_MAP_BANNER    = "Fase de recuperación: Overlord inactivo"


-- ================================================================
-- ALLEMAND (deDE): Surcharge automatique pour les clients DE
-- ================================================================
elseif Overlord.IsGermanLocale() then

L.CAPTURE_ALERT_SUBZONE_IN_REGION = "%s (%s)"

L.ZONE_NAMES = {
    stromgarde = "Burg Stromgarde",
    faldir     = "Faldirs Bucht",
    witherbark = "Dorf der Bleichborken",
    goshek     = "Goscheks Farm",
    dabyrie    = "Dabyries Landgut",
    refuge     = "Die Wegstation",
    highperch  = "Westliches Hochland",
    newstead   = "Thoradins Wall",
    hammerfell = "Hammerfall",
    argorok    = "Kreis der Westlichen Bindung",
    loch_alliance_capital = "Thelsamar",
    loch_horde_capital = "Festung der Mo'grosh",
    loch_valley_of_kings = "Tal der Könige",
    loch_south_gate_pass = "Pass der Südlichen Pforte",
    loch_silver_stream_mine = "Silberbachmine",
    loch_algaz_post = "Algazposten",
    loch_farstrider_lodge = "Jagdhütte der Weltenbezwinger",
    loch_ironband = "Eisenbands Grabungsstätte",
    loch_the_loch = "Der Loch",
    loch_stonewrought_dam = "Steinwerkdamm",
    durotar_tiragarde_keep = "Tiragardes Festung",
    durotar_alliance_fleet = "Kolkarklippe",
    durotar_senjin_village = "Sen'jin",
    durotar_razor_hill = "Klingenhügel",
    durotar_deadeye_shore = "Deadeye-Küste",
    durotar_southfury = "Südstrom",
    durotar_spirit_rock = "Tal der Prüfungen",
    durotar_thunder_ridge = "Donnergrat",
    durotar_drygulch_ravine = "Ausgetrocknete Schlucht",
    durotar_dranosh_blockade = "Zugang nach Orgrimmar",
    elwynn_westbrook = "Garnison von Westbrook",
    elwynn_goldshire = "Goldhain",
    elwynn_tower_of_azora = "Turm von Azora",
    elwynn_ridgepoint = "Kammwachturm",
    elwynn_mirror_lake = "Kristallsee",
    elwynn_fargodeep = "Tiefenfelsmine",
    elwynn_jerods_landing = "Jerods Landeplatz",
    elwynn_stone_cairn = "Steinhügelsee",
    elwynn_eastvale = "Holzfällerlager des Osttals",
    elwynn_invasion_camp = "Schwarzfelsvorstoß",
    ash_astranaar = "Astranaar",
    ash_iris_lake = "Irissee",
    ash_raynewood = "Rajonholz",
    ash_night_run = "Nachtflucht",
    ash_bloodtooth_camp = "Blutreißerzahnlager",
    ash_silverwind = "Silberwindzuflucht",
    ash_mystral_lake = "Mystralsee",
    ash_fallen_sky_lake = "Himmelssturzsee",
    ash_dor_danil = "Grabhügel von Dor'Danil",
    ash_splintertree = "Splitterholzposten",
}

L.FRONT_ARATHI_NAME = "Arathihochland"
L.FRONT_LOCH_MODAN_NAME = "Loch Modan"
L.FRONT_DUROTAR_NAME = "Durotar"
L.FRONT_ELWYNN_NAME = "Wald von Elwynn"
L.FRONT_ARATHI_DROPDOWN = "Arathi"
L.FRONT_LOCH_MODAN_DROPDOWN = "Loch Modan"
L.FRONT_DUROTAR_DROPDOWN = "Durotar"
L.FRONT_ELWYNN_DROPDOWN = "Elwynn"
L.FRONT_ASHENVALE_NAME = "Eschental"
L.FRONT_ASHENVALE_DROPDOWN = "Eschental"

L.THE_HORDE    = "die Horde"
L.THE_ALLIANCE = "die Allianz"

L.VICTORY_FACTION_HORDE    = "DIE HORDE"
L.VICTORY_FACTION_ALLIANCE = "DIE ALLIANZ"

L.DATE_FORMAT = "%d.%m.%Y"

-- Core
L.WEEKLY_RESET    = "Neue Woche! Die Kampagne wurde nach dem US-Beta-Zeitplan zurückgesetzt."
L.MODULE_ERROR    = "Modulfehler %s: %s"
L.ADDON_LOADED    = "v%s geladen. |cFFFFFF00/ov help|r für Befehle."
L.SYNC_LOGIN_WAIT = "Zonendaten werden synchronisiert... Die Karte wird in Kürze aktualisiert."
L.ALL_ZONES_RESET = "Alle Zonen wurden zurückgesetzt!"
L.FRONT_CAPITAL_RELEASED = "%s: Waffenstillstand beendet. Die Eroberung bleibt bestehen und die gefallene Hauptstadt erhebt sich wieder; beide Hauptstädte sind bis %s geschützt."
L.CAPITAL_PROTECTED_UNTIL = "Geschützt bis %s"
L.CAPITAL_PROTECTED_SHORT = "Bis %s"

-- Commands
L.HELP_HEADER   = "|cFF00FF00========== Overlord: Befehle ==========|r"
L.HELP_SHOW     = "|cFFFFFF00/ov show|r: Oberfläche anzeigen"
L.HELP_HIDE     = "|cFFFFFF00/ov hide|r: Oberfläche ausblenden"
L.HELP_TOGGLE   = "|cFFFFFF00/ov toggle|r: Oberfläche umschalten"
L.HELP_HUD      = "|cFFFFFF00/ov hud [auto|on|off|toggle]|r: Oberes HUD einstellen"
L.HUD_SHOWN     = "|cFF00FF00[Overlord]|r Oberes HUD aktiviert."
L.HUD_HIDDEN    = "|cFF00FF00[Overlord]|r Oberes HUD deaktiviert."
L.HUD_AUTO      = "|cFF00FF00[Overlord]|r Oberes HUD auf Auto gestellt."
L.HELP_STATUS   = "|cFFFFFF00/ov status|r: Zonenstatus anzeigen"
L.HELP_ZONES    = "|cFFFFFF00/ov zones|r: Verfügbare Zonen mit Koordinaten"
L.HELP_WHERE    = "|cFFFFFF00/ov where|r: Zonenanzeige umschalten"
L.HELP_START    = "|cFFFFFF00/ov start <zone>|r: Eroberung starten"
L.HELP_LB       = "|cFFFFFF00/ov lb|r: Rangliste anzeigen"
L.HELP_SYNC     = "|cFFFFFF00/ov sync [Spieler-Realm]|r: Sync anfordern (Ziel-Flüstern oder Gruppe/Schlachtzug/Community)"
L.HELP_DOM      = "|cFFFFFF00/ov dom|r: Wöchentliche Dominanz debuggen (Sekunden, Boni, Anzeige %)"
L.HELP_SCALE    = "|cFFFFFF00/ov scale [0.8-1.2]|r: Panel-Skalierung (auch: Esc > Optionen > AddOns > Overlord)"
L.DOM_DEBUG_HEADER = "Wöchentliche Dominanz:"
L.HELP_GUIDE    = "|cFFFFFF00/ov guide|r: Kurzanleitung"
L.HELP_FOOTER   = "|cFF00FF00=============================================|r"

L.STATUS_HEADER      = "|cFF00FF00========== Overlord: Status ==========|r"
L.STATUS_IN_PROGRESS = "IN BEARBEITUNG (%d:%02d Haltezeit)"
L.STATUS_AVAILABLE   = "VERFÜGBAR"
L.STATUS_LOCKED      = "GESPERRT"
L.STATUS_TOTAL       = "Gesamt: %d/%d Zonen (%d%%)"
L.STATUS_FOOTER      = "|cFF00FF00=============================================|r"

L.NOT_INITIALIZED  = "Addon ist noch nicht initialisiert."
L.USAGE_START      = "Verwendung: /ov start <zone>"
L.ZONE_UNKNOWN     = "Unbekannte Zone: %s"
L.ZONE_NOT_AVAILABLE = "%s ist nicht verfügbar!"
L.MUST_BE_IN_ZONE  = "Ihr müsst in %s sein, um die Eroberung zu starten! (%.1f, %.1f)"
L.UNKNOWN_COMMAND  = "Unbekannter Befehl: %s"
L.HELP_HINT        = "Tippt /ov help für verfügbare Befehle."
L.POS_RESET        = "Panelposition wurde zurückgesetzt."

-- UI
L.CONTROL_ZONES     = "KONTROLLZONEN"
L.ACTIVE_ZONE       = "AKTIVE ZONE"
L.NO_ACTIVE_ZONE    = "Keine aktive Zone"
L.HOLD_LABEL        = "Halten"
L.UI_CONTESTED      = "UMKÄMPFT"
L.UI_PAUSED         = "PAUSIERT: außerhalb der Zone, Timer sinkt"
L.UI_IN_PROGRESS    = "IN BEARBEITUNG: Position halten"
L.UI_ENEMY_CAPTURING = "FEIND EROBERT: Zone bekämpfen!"
L.UI_COMPLETE       = "ABGESCHLOSSEN"
L.ACTION_SHORTCUT_LABEL = "Aktionsleisten-Verknüpfung"
L.ACTION_SHORTCUT_TOOLTIP = "Legt das Overlord-Symbol auf den Mauszeiger: Klickt auf einen Aktionsleistenplatz, um es dort abzulegen."
L.ACTION_SHORTCUT_COMBAT = "Die Aktionsleisten-Verknüpfung kann im Kampf nicht erstellt werden."
L.ACTION_SHORTCUT_FAILED = "Verknüpfung konnte nicht erstellt oder aufgenommen werden. Verlasst den Kampf und versucht es erneut."
L.UI_SCALE_LABEL    = "Panel-Skalierung"
L.UI_SCALE_TOOLTIP  = "Größe des Hauptpanels und der Rangliste. Ihr könnt auch |cffffffff/ov scale|r nutzen."
L.NOTIFICATION_CHAT_LABEL = "Overlord-Meldungen"
L.NOTIFICATION_CHAT_TOOLTIP = "Chat-Tab, in dem Overlord-Alarme und -Meldungen erscheinen."
L.NOTIFICATION_CHAT_DEFAULT = "Hauptchat (Standard)"
L.CHAT_TAB_LABEL = "Overlord-Chat-Tab"
L.CHAT_TAB_BUTTON = "Tab erstellen"
L.CHAT_TAB_TOOLTIP = "Erstellt einen Chat-Tab namens Overlord und leitet Overlord-Meldungen dorthin. Verschiebt, versteckt oder schließt ihn wie jeden anderen Tab."
L.CHAT_TAB_READY = "Overlord-Meldungen erscheinen jetzt in diesem Tab."
L.CHAT_TAB_FAILED = "Kein freier Chat-Tab. Schließt einen und versucht es erneut."
L.ACTION_SHORTCUT_BUTTON = "Aufnehmen"
L.SETTINGS_SECTION_GENERAL = "Allgemein"
L.SETTINGS_SECTION_CHAT = "Chat"
L.SETTINGS_SECTION_MAP = "Karte und Minikarte"
L.SETTINGS_SECTION_HUD = "Bildschirmanzeigen"
L.UI_FRONT_SELECT = "Kriegsfront (Liste)"
L.UI_FRONT_PICKER_TOOLTIP = "Welche Zonenliste angezeigt wird. Eroberungstimer und Kampf folgen weiter der Karte, auf der Ihr kämpft."
L.UI_FRONT_READONLY_TOOLTIP = "Ihr seht eine andere Front oder seid nicht in einer Kriegszone. Klicks starten keine Eroberungen; Wegpunkte nutzen die gewählte Frontkarte."
L.UI_CAPTURE_READONLY = "Nur Lesen: geht zu dieser Front in der offenen Welt, um von dieser Liste zu erobern."
L.MAP_OVERLAY_OPACITY_LABEL   = "Deckkraft Eroberungen (Karte)"
L.MAP_OVERLAY_OPACITY_TOOLTIP = "Transparenz der Eroberungskreise nur auf der |cffffffffWeltkarte|r. Niedrigere Werte zeigen mehr Kartendetail.\nBetrifft nicht die Minimap (siehe Deckkraft Eroberungen (Minimap)) oder Coin-Minen-Kreise."
L.MINIMAP_OVERLAY_OPACITY_LABEL   = "Deckkraft Eroberungen (Minimap)"
L.MINIMAP_OVERLAY_OPACITY_TOOLTIP = "Transparenz der Eroberungskreise auf der |cffffffffMinimap|r. Niedrigere Werte zeigen mehr Kartendetail.\nBetrifft nicht die Weltkarte, Gildenfestung-Symbole oder Coin-Minen-Kreise."
L.MAP_ICON_OPACITY_LABEL = "Deckkraft Symbole (Karte)"
L.MAP_ICON_OPACITY_TOOLTIP = "Transparenz der Symbole von Eroberungspunkten, Festungen und Außenposten auf der |cffffffffWeltkarte|r. Niedrige Werte lassen Questmarkierungen in Städten sichtbar. Bei 0 werden sie ausgeblendet."
L.MAP_ICON_SCALE_LABEL = "Symbolgröße (Karte)"
L.MAP_ICON_SCALE_TOOLTIP = "Größe der Symbole von Hauptstädten, Eroberungspunkten, Festungen und Außenposten auf der |cffffffffWeltkarte|r."
L.MINIMAP_BUTTON_LABEL          = "Minimap-Button"
L.MINIMAP_BUTTON_TOOLTIP        = "Zeigt den Overlord-Button an der Minimap. Aktivieren, um ihn wieder einzublenden; Minimap-Button-Manager können ihn in ihrem eigenen Menü sammeln."
L.MINIMAP_CAPTURE_ZONES_LABEL   = "Minimap-Symbole"
L.MINIMAP_CAPTURE_ZONES_TOOLTIP = "Zeigt Overlords Symbole auf der |cffffffffMinimap|r: Eroberungskreise, Generäle, Minen, Gildenfestungen und Außenposten. Der Mauszeiger geht hindurch zu Jäger- und Essens-Spuren. Deaktivieren, um alle auszublenden (die Weltkarte behält ihre eigenen Einstellungen)."
L.MAP_ZONE_TITLES_LABEL         = "Zonennamen (Karte)"
L.MAP_ZONE_TITLES_TOOLTIP       = "Zeigt die Pergament-Namensbanner für Eroberungszonen und Coin-Minen auf der |cffffffffWeltkarte|r. Deaktivieren für eine klarere Karte, wenn Ihr die Gebiete schon kennt."
L.MAP_PATH_OPACITY_LABEL      = "Deckkraft Routen (Karte)"
L.MAP_PATH_OPACITY_TOOLTIP    = "Deckkraft der |cffffffffgestrichelten Linien|r zwischen Eroberungszonen auf der Weltkarte (1 = blass, 3 = sehr sichtbar)."
L.SETTINGS_TOGGLE_ON          = "Aktiviert"
L.SETTINGS_TOGGLE_OFF         = "Deaktiviert"
L.AUTO_WAYPOINT_LABEL         = "Automatische Zielmarkierung"
L.AUTO_WAYPOINT_TOOLTIP       = "Setzt die Blizzard-Kartenmarkierung auf das nächste verfügbare Ziel. Wenn Ihr diese Markierung entfernt oder ersetzt, wartet Overlord bis zum nächsten Ziel, bevor sie erneut gesetzt wird. Die Markierung wird entfernt, wenn das Ziel nicht mehr gültig ist."
L.SHOW_TOP_HUD_LABEL          = "Oberes HUD"
L.SHOW_TOP_HUD_TOOLTIP        = "Auto zeigt passende Panels bei Eroberungen, Minen und Gildenfestungen. Immer zeigt sie auf den betreffenden Karten; Nie blendet sie aus. Die Zielanzeige bleibt verfügbar."
L.TOP_HUD_MODE_AUTO           = "Auto"
L.TOP_HUD_MODE_ALWAYS         = "Immer"
L.TOP_HUD_MODE_NEVER          = "Nie"
L.SHOW_TUTORIAL_BOOK_LABEL    = "Tutorial-Buchsymbol"
L.SHOW_TUTORIAL_BOOK_TOOLTIP  = "Zeigt das Tutorial-Buchsymbol im oberen HUD. Deaktivieren, um nur dieses Symbol auszublenden und Coins- und Gildenfestungs-Panels zu behalten."
L.SOUND_ENABLED_LABEL         = "Overlord-Töne"
L.SOUND_ENABLED_TOOLTIP       = "Schaltet alle Overlord-Töne stumm (Alarme, Kriegshorn, Eroberungen, Panels, Coins-Buff, General-Duellmusik usw.)."
L.SETTINGS_BUTTON             = "Einstellungen"
L.LAYER_JUMPER_BUTTON = "Layer Jumper"
L.NET_HEALTH_TITLE = "Overlord-Netzwerk"
L.NET_HEALTH_OK = "Alles gut"
L.NET_HEALTH_WARN = "Im Auge behalten"
L.NET_HEALTH_BAD = "Problem"
L.NET_HEALTH_HINT = "Gib /ov network für Details ein."
L.MW_ALERT = "Most Wanted in der Nähe: %s (#%d %s, %d Kills diese Woche)!"
L.HELP_WANTED = "|cFFFFFF00/ov wanted [on|off]|r: Most Wanted: Warnung, wenn einer der 5 besten Gegner in der Nähe ist"
L.MW_STATE_ON = "Most-Wanted-Warnungen: an"
L.MW_STATE_OFF = "Most-Wanted-Warnungen: aus"
L.LAYER_JUMPER_TOOLTIP = "Layer in deiner Zone wechseln"
L.HELP_LAYER = "|cFFFFFF00/ov layer [help on|off]|r: Layer Jumper (Layer wechseln; freiwillig helfen)"
L.LJ_TITLE = "Layer Jumper"
L.LJ_ZONE_LAYER = "%s - dein Layer: %s"
L.LJ_LAYER_UNKNOWN = "unbekannt"
L.LJ_LAYER_NAME = "Layer #%s"
L.LJ_HELPERS = "%d Helfer"
L.LJ_HERE = "du bist hier"
L.LJ_JOIN = "Beitreten"
L.LJ_SEARCH = "Suchen"
L.LJ_RANDOM = "Layer wechseln"
L.LJ_RANDOM_TOOLTIP = "Auf irgendeinen anderen Layer dieser Zone wechseln (sucht zuerst, falls nötig)."
L.LJ_CANCEL = "Abbrechen"
L.LJ_LIST_EMPTY = "Visiere einen NPC an, um deinen Layer zu lesen, und klicke dann auf Suchen."
L.LJ_HELP_MODE = "Anderen helfen: %s"
L.LJ_HELP_MODE_AUTO = "an"
L.LJ_HELP_MODE_OFF = "aus"
L.LJ_HELP_MODE_TOOLTIP = "Freiwilliger Helfer (standardmäßig aus). Wenn an, lädst du einen Overlord-Spieler deiner Fraktion, der deinen Layer sucht, automatisch und ohne Fenster ein; er verlässt die Gruppe nach dem Wechsel. Nur wenn du allein bist, außerhalb von Kampf und Instanzen."
L.LJ_EXPLAIN = "Ein freiwilliger Helfer auf dem gewählten Layer lädt dich in eine Gruppe ein. Außerhalb des Kampfes versetzt dich das Spiel in wenigen Sekunden auf seinen Layer, danach verlässt du die Gruppe automatisch. Nur Zone und Layer werden geteilt, nie deine Position."
L.LJ_STATUS_IDLE = "Suche Helfer in deiner Zone."
L.LJ_STATUS_SEARCHING = "Suche Helfer in %s..."
L.LJ_STATUS_READY = "%d Helfer gefunden."
L.LJ_STATUS_NONE = "Gerade kein freiwilliger Helfer in dieser Zone verfügbar. Versuche es gleich noch einmal oder in einer belebteren Zone."
L.LJ_STATUS_REQUESTING = "Bitte %s um eine Einladung..."
L.LJ_STATUS_JOINING = "Einladung angenommen, trete der Gruppe von %s bei..."
L.LJ_STATUS_VERIFYING = "Layerwechsel... (%ds)"
L.LJ_STATUS_VERIFY_COMBAT = "Im Kampf: Der Wechsel wartet auf das Kampfende (%ds)."
L.LJ_STATUS_SUCCESS = "Fertig: Du bist jetzt auf %s."
L.LJ_STATUS_UNCONFIRMED = "Gruppe verlassen; der neue Layer konnte nicht bestätigt werden (kein NPC in Sicht)."
L.LJ_STATUS_CROWDED = "Gruppe verlassen: Der Helfer hat weitere Spieler eingeladen."
L.LJ_STATUS_FAILED = "Kein Helfer hat dich eingeladen. Versuche es gleich noch einmal."
L.LJ_STATUS_CANCELLED = "Abgebrochen."
L.LJ_ERR_GROUPED = "Verlasse zuerst deine Gruppe: Der Helfer muss dich einladen."
L.LJ_ERR_INSTANCE = "In Instanzen und Schlachtfeldern nicht verfügbar."
L.LJ_ERR_QUEUE = "Nicht verfügbar, während du für ein Schlachtfeld angemeldet bist."
L.LJ_ERR_COOLDOWN = "Warte %d s vor der nächsten Suche."
L.LJ_ERR_SAME_LAYER = "Du bist bereits auf diesem Layer."
L.LJ_ERR_NO_NETWORK = "Das Overlord-Netzwerk ist noch nicht bereit (keine Gilde, kein Kanal). Versuche es gleich noch einmal."
L.LJ_ERR_LAYER_UNKNOWN = "Visiere zuerst einen NPC an: Dein Layer muss bekannt sein, um auf einen anderen zu wechseln."
L.LJ_GUEST_REMOVED = "%s aus der Gruppe entfernt (Layerwechsel beendet)."
L.LJ_LATE_LEAVE = "Gruppe von %s verlassen: Dieser Layerwechsel war abgebrochen."
L.CHECK_PVP_BUTTON = "Exportieren"
L.SETTINGS_BUTTON_TOOLTIP     = "Öffnet die Overlord-Einstellungen."
L.SETTINGS_OPEN_UNAVAILABLE   = "Einstellungen sind gerade nicht verfügbar. Esc, dann Optionen, dann AddOns."
L.SCALE_CURRENT     = "Panel-Skalierung: %.1f (Bereich %.1f bis %.1f)."
L.SCALE_SET         = "Panel-Skalierung: %.1f."
L.ATTACK            = "Angreifen!"
L.LOCKED            = "Gesperrt"
L.NEXT_OBJECTIVE_HEADER   = "Nächstes Ziel"
L.NEXT_OBJECTIVE_COLLAPSE = "Nächstes Ziel ausblenden"
L.NEXT_OBJECTIVE_NONE = "Kein Ziel verfügbar"
L.NEXT_OBJECTIVE_NO_FRONT = "Außerhalb einer Kriegsfront"
-- Outside a war front: one short line for the player's race (faction fallback).
L.HOME_MOTTOS = {
    Human = "Sturmwind steht noch.",
    Dwarf = "Eisenschmiede hält stand.",
    Gnome = "Gnomeregan ersteht neu!",
    NightElf = "Unter Elunes Blick.",
    Orc = "Lok'tar ogar!",
    Troll = "Die Geister wachen, Mann.",
    Scourge = "Die Dunkle Fürstin wacht.",
    Tauren = "Die Erdenmutter führt.",
    Skyborne = "Der Gesang der Winde.",
    Alliance = "Für die Allianz!",
    Horde = "Für die Horde!",
}
L.NEXT_OBJECTIVE_OUTSIDE_FRONT = "Betritt eine Kriegsfront, um dein nächstes Ziel zu sehen."
L.NEXT_OBJECTIVE_GO         = "Hierhin: in der Zone bleiben, um den Eroberungstimer zu starten."
L.GUIDE_BAR_LABEL           = "Anleitung"
L.GUIDE_CLOSE               = "Schließen"
L.GUIDE_TITLE               = "Anleitung"
L.GUIDE_PAGE_INDICATOR      = "Seite %d / %d"
L.GUIDE_PREV                = "Zurück"
L.GUIDE_NEXT                = "Weiter"
L.GUIDE_PAGE2_TITLE         = "Eroberungen & Ressourcen"
L.VICTORY_DOMINATION_BONUS  = "Totaler Frontsieg: +%d %% wöchentliche Dominanz für Eure Fraktion."
L.TOOLTIP_SHIFT_GUIDE       = "Umschalt + Linksklick: Kurzanleitung"

-- Shard
L.SHARD_TOOLTIP_TITLE          = "Shard-ID"
L.SHARD_TOOLTIP_CURRENT        = "Aktuelle Shard-ID: %s"
L.SHARD_TOOLTIP_REFERENCE_REALM = "Referenzspieler: %s"
L.SHARD_BADGE_REFERENCE       = "über %s"
L.SHARD_TOOLTIP_PLAYERS_HEADER = "Spieler auf anderem Shard:"
L.SHARD_TOOLTIP_ALL_SAME       = "Alle synchronisierten Spieler sind auf demselben Shard."
L.SHARD_TOOLTIP_UNDETECTED     = "Shard noch nicht erkannt (keine Vignette, Mausover-NPC oder Nameplate-GUID)."
L.SHARD_ALERT_TAG              = " #%s"

L.ASSAULT_LAUNCHED    = "Angriff auf %s gestartet!"
L.CAPTURE_LAUNCHED    = "Eroberung von %s gestartet!"
L.GO_TO_ZONE          = "Geht zu %s (%.1f, %.1f) zum Erobern!"
L.ENEMY_CONTROL_MSG   = "%s ist unter feindlicher Kontrolle. Erobert zuerst die Voraussetzungen."
L.CAPTURE_BLOCKED_RULES = "%s kann noch nicht erobert werden (Front-Waffenstillstand, geschützte Hauptstadt oder Voraussetzungen)."
L.ZONE_IS_LOCKED      = "%s ist gesperrt."
L.ALREADY_IN_PROGRESS = "%s bereits in Bearbeitung..."
L.ZONE_UNDER_CONTROL  = "%s wird durch %s kontrolliert."

-- Zones
L.CAPTURE_CANCELLED  = "Eroberung von %s abgebrochen! Voraussetzungen verloren."
L.ZONE_NOW_AVAILABLE = "%s ist jetzt zur Eroberung verfügbar!"

-- ZoneControl
L.ENTERED_ZONE       = "Ihr habt %s betreten! Eroberung gestartet!"
L.CAPTURE_NEEDS_PVP = "%s: Aktiviert PvP (/pvp), um dieses Ziel zu erobern."
L.AUTO_DISMOUNT_CAPTURE_CIRCLE = "Ihr fliegt in %s: automatisches Absteigen in %d Sekunden."
L.AUTO_DISMOUNT_MINE_CIRCLE    = "Ihr fliegt im Minenkreis %s: automatisches Absteigen in %d Sekunden."
L.HOLD_TIMER_STARTED = "Haltetimer für %s gestartet (%d:%02d). Bleibt in der Zone!"
L.CAPTURE_SYNC_WAITING = "Anfängliche Sync ausstehend: Eroberung von %s vorübergehend blockiert."
L.ZONE_CONTESTED_OUTNUMBER = "%s ist umkämpft! Feinde in Überzahl (%d vs %d)."
L.ZONE_CONTESTED_EVEN      = "%s ist umkämpft! Kräfte ausgeglichen (%d vs %d)."
L.ZONE_SECURED       = "%s gesichert! Eroberung läuft weiter."
L.BACK_IN_ZONE       = "Ihr seid zurück in %s! Eroberung läuft weiter."
L.LEFT_ZONE          = "Ihr habt %s verlassen! Fortschritt sinkt..."
L.CAPTURE_LOST       = "Eroberung von %s verloren! Kehrt dorthin zurück."
L.ENEMY_CAPTURE_REVERSED = "Feindliche Eroberung von %s rückgängig! Zone gesichert."
L.ZONE_CAPTURED_BY   = "%s wurde durch %s erobert!"
L.TOTAL_VICTORY_MSG  = "   TOTALER SIEG: %s!   "
L.TOTAL_VICTORY_FRONT_MSG = "   TOTALER SIEG: %s! Front: %s   "

-- LeaderboardUI
L.LB_TITLE         = "RANGLISTE"
L.LB_SEARCH_PLACEHOLDER = "Spieler oder Gilde..."
L.LB_SEARCH_EMPTY = "Keine Treffer"
L.LB_SEARCH_WORKING = "Suche..."
L.LB_BUTTON        = "Rangliste"
L.LB_BUTTON_TOOLTIP = "Wöchentliche Kill- und Eroberungs-Rangliste öffnen"
L.HOF_BUTTON        = "Ruhmeshalle"
L.HOF_BUTTON_TOOLTIP = "Ruhmeshalle öffnen: Ehrungen, Heldentaten und Spender"
L.DISCORD_BUTTON = "Discord"
L.DISCORD_BUTTON_TOOLTIP = "Discord-Server beitreten"
L.DISCORD_POPUP_TITLE = "Discord-Server beitreten"
L.DISCORD_POPUP_HINT = "Öffne Discord im Browser und füge den Einladungslink unten ein."
L.DISCORD_URL_LABEL = "Discord-Einladungslink"
L.DISCORD_POPUP_COPY_HINT = "URL markiert: kopieren (Strg+C)"
L.HOF_TITLE = "Ruhmeshalle"
L.HOF_SECTION_EMPTY = "Noch keine Einträge."
L.HOF_CAT_GUILD = "Gildenehren"
L.HOF_CAT_PLAYER = "Spielerehren"
L.HOF_CAT_LIFETIME = "Deine Leistungen"
L.HOF_PROGRESS_COUNT = "%d / %d"
L.HOF_CAT_ALLIANCE = "Allianz"
L.HOF_CAT_HORDE = "Horde"
L.HOF_CAT_WEEKLY = "Wochenleistungen"
L.HOF_CAT_DONORS = "Spender"
L.HOF_DONOR_LINE = "Über 100 Gold für die Kriegskasse"
L.HOF_POINTS_LABEL = "Erfolgspunkte der Kriegsfronten"
L.HOF_RECENT_TITLE = "Neueste Erfolge"
L.HOF_PROGRESS_TITLE = "Fortschrittsübersicht"
L.HOF_PROGRESS_TOTAL = "Erhaltene Ehren"
L.HOF_SEARCH_NO_RESULTS = "Keine passenden Ehren."
L.HOF_WEEKLY_PLAYER_RANK_LINE = "Beta, Kämpfer der Woche: Platz %d"
L.HOF_WEEKLY_GUILD_RANK_LINE = "Beta, Gilden der Woche: Platz %d"
L.LB_CAMPAIGN_DATE = "Kampagne %s bis %s"
L.LB_INFO_ENDS = "Kampagne endet in"
L.LB_INFO_RANKED = "Platzierte Spieler:"
L.LB_INFO_RANKED_VALUE = "|cFF4488FF%s Allianz|r · |cFFFF4444%s Horde|r"
L.LB_INFO_YOU = "Du:"
L.LB_INFO_UNRANKED = "noch nicht platziert"
L.LB_INFO_NEXT = "%s ES bis Platz #%d"
L.LB_INFO_FIRST = "Du führst die Rangliste an!"
L.LB_RULESET_LABEL = "%s-Kampagne"
L.RULESET_NAME_PVP = "PvP"
L.RULESET_NAME_NORMAL = "Normal"
L.RULESET_NAME_RP = "RP"
L.RULESET_NAME_HARDCORE = "Hardcore"
L.LB_CACHED_REFRESHING = "Gespeicherte Rangliste · wird aktualisiert…"
L.LB_COL_CLASS     = "Klasse"
L.LB_COL_RACE      = "Volk"
L.LB_COL_PLAYER    = "Spieler"
L.LB_COL_KILLS     = "ES"
L.LB_TOTAL_FORMAT  = "|cFF4488FFAllianz: %d Kills|r  |cFFFF4444Horde: %d Kills|r"
L.LB_CAPTURES_ALLIANCE = "Allianz: Eroberungen"
L.LB_CAPTURES_HORDE    = "Horde: Eroberungen"
L.LB_CAPTURES_SCROLL_TOOLTIP = "Mausrad zum Scrollen der Liste"
L.LB_KILLS_SCROLL_TOOLTIP     = "Mausrad zum Scrollen der Rangliste"
L.LB_ROW_GUILD = "Gilde: %s"
L.LB_ROW_NO_GUILD = "Gilde unbekannt"
L.LB_GUILD_TIP_SUMMARY = "%d platzierte Mitglieder, %d Kills"
L.LB_GUILD_TIP_MORE = "+ %d weitere"
L.LB_GUILD_TIP_TOTAL = "%d Kills"
L.LB_COL_GUILD                = "Gilde"
L.LB_COL_KEEP                 = "Festung"
L.LB_GUILD_EMPTY              = "Noch keine Gilden in der Rangliste."
L.LB_GUILD_KEEP_EMPTY         = "Keine Gilde hält eine Festung."
L.LB_COL_OUTPOST              = "Außenposten"
L.LB_COL_CAPTURES             = "Eroberungen"
L.LB_OUTPOST_EMPTY            = "Noch keine Außenposten-Eroberungen."
L.OUTPOST_SHORT               = "Außenposten"
L.OUTPOST_LOCH_MODAN_NAME     = "Katrells Zuflucht"
L.OUTPOST_ARATHI_NAME         = "Sages Turm"
L.OUTPOST_DUROTAR_NAME        = "Stachelhauerhof"
L.OUTPOST_ELWYNN_NAME         = "Donnerfälle"
L.OUTPOST_ASHENVALE_NAME      = "Shobek'Aran"
L.OUTPOST_NEUTRAL             = "Unbeansprucht"
L.OUTPOST_CAPTURING           = "Eroberung läuft…"
L.OUTPOST_NO_GUILD            = "Ihr müsst in einer Gilde sein, um einen Außenposten zu erobern."
L.OUTPOST_HOLD_STARTED        = "Eroberung von %s (%d Min)…"
L.OUTPOST_CAPTURE_LOST        = "Außenposten-Eroberung verloren."
L.OUTPOST_UNDER_ATTACK        = "%s wird angegriffen!"
L.OUTPOST_CONTESTED_OUTNUMBER = "%s umkämpft! Gegner dominieren (%d vs %d). Fortschritt sinkt."
L.OUTPOST_CONTESTED_EVEN      = "%s umkämpft! Kräfte gleich (%d vs %d). Fortschritt eingefroren."
L.OUTPOST_INDICATOR_TITLE     = "|cFFFFFF00Außenposten-Eroberung|r"
L.OUTPOST_DEFENSE_TITLE       = "|cFFFFFF00Außenposten-Verteidigung|r"
L.OUTPOST_ON_POINT            = "Ihr steht im Außenposten-Feld."
L.OUTPOST_ASSAULT_READY       = "Angriff möglich: Feld %d Min halten."
L.OUTPOST_PANEL_HELD          = "Gehalten von %s"
L.OUTPOST_CAPTURE_ALERT_FRIENDLY = "%s wird jetzt von Gilde %s gehalten!"
L.OUTPOST_CAPTURE_ALERT_ENEMY    = "%s erobert von Gilde %s (%s)!"
L.OUTPOST_DEFENDER_UNDER_ATTACK = "%s: Euer Außenposten wird angegriffen (%s)!"
L.OUTPOST_DEFENDER_UNDER_ATTACK_BY = "%s: Euer Außenposten wird von Gilde %s angegriffen (%s)!"
L.OUTPOST_ALLIED_UNDER_ATTACK = "%s: Verbündeter Außenposten von Gilde %s wird angegriffen (%s)!"
L.OUTPOST_ENEMY_ASSAULT      = "%s: %s greift an!"
L.OUTPOST_ENEMY_ASSAULT_VS   = "%s: %s greift %s an!"
L.OUTPOST_ALLY_ASSAULT       = "%s: %s hat einen Angriff gestartet."
L.OUTPOST_ALLY_ASSAULT_VS    = "%s: %s hat einen Angriff auf %s gestartet."

L.POPUP_OK = "Verstanden"
L.POPUP_WELCOME_TITLE_ALLIANCE = "Für die Allianz"
L.POPUP_WELCOME_TITLE_HORDE    = "Für die Horde"
L.POPUP_WELCOME_BODY           = "Willkommen auf dem Schlachtfeld, |cFFFFD100%s|r.\n\nGeht zu einer |cFFFFD100|Haddon:Overlord:panel|hKriegsfront|h|r und lest die |cFFFFD100Anleitung|r (|cFFFFD100Buch-Symbol|r oben am Bildschirm)."
L.POPUP_WELCOME_NAME_FALLBACK  = "Champion"
L.POPUP_WELCOME_GUIDE_BTN      = "Anleitung öffnen"
L.POPUP_UPDATE_FOREVER_1000_TITLE = "Overlord Forever"
L.POPUP_UPDATE_FOREVER_1000_BODY  = "|cFFFFD100Ein neues Overlord-Schlachtfeld:|r PvP-Kills in der offenen Welt im |cFFFFD100Arathihochland|r, in |cFFFFD100Loch Modan|r, in |cFFFFD100Durotar|r und im |cFFFFD100Eschental|r werden in der Overlord-Rangliste erfasst.\n\n|cFFFFFFFFVoraussetzungen|r\n• Euer Charakter muss |cFFFFD100Stufe 60|r erreicht haben.\n• Nur offene Welt: instanzierte Schlachtzüge, Dungeons und Schlachtfelder bleiben ausgeschlossen.\n\nEin |cFFFFD100Gildenaußenposten|r erwartet Euch an jeder Kriegsfront."
L.POPUP_BATTLE_REPORT_TITLE     = "Schlachtbericht"
L.POPUP_BATTLE_REPORT_GUILD     = "Dominante Gilde: %s: |cFFFFD100%d|r Kills"
L.POPUP_BATTLE_REPORT_KILLER    = "Bester Killer: %s: |cFFFFD100%d|r Kills"
L.POPUP_BATTLE_REPORT_CAPTURER  = "Bester Eroberer: %s: |cFFFFD100%d|r Eroberungen"
L.POPUP_BATTLE_REPORT_NOT_FRONT = "Geht zur Kriegsfrontkarte für den Schlachtbericht."
L.POPUP_BATTLE_REPORT_NO_DATA   = "Noch keine Ranglistendaten für den Schlachtbericht."
L.FEATURED_FRONT_ACTIVITY_TITLE      = "Kürzliche Aktivität (letzte 5 Min.)"
L.FEATURED_FRONT_ACTIVITY_DASH       = "..."
L.FEATURED_FRONT_ACTIVITY_JUST_NOW   = "gerade eben"
L.FEATURED_FRONT_ACTIVITY_MIN_AGO    = "vor %d Min."
L.FEATURED_FRONT_ACTIVITY_KILLS      = "%d+ Kills"

L.ZONE_WAYPOINT_BLOCKED = "|cFFFFD100[Overlord]|r Markierung auf dieser Karte nicht möglich."
L.ZONE_WAYPOINT_FAIL    = "|cFFFFD100[Overlord]|r Kartenmarkierung konnte nicht erstellt werden."

-- MapMarkers
L.MAP_AVAILABLE       = "VERFÜGBAR"
L.MAP_LOCKED          = "GESPERRT"
L.MAP_NEUTRAL         = "NEUTRAL"
L.MAP_SYNC_PENDING    = "SYNC LÄUFT"
L.FRONT_ZONES_HEADER = "Zonen von %s:"
L.TOOLTIP_FRIENDLY    = "Verbündete: %d/%d"
L.TOOLTIP_ENEMY       = "Feinde: %d/%d"
L.TOOLTIP_LEFT_CLICK      = "Linksklick: Hauptpanel"
L.TOOLTIP_RIGHT_DRAG      = "Rechtsklick + ziehen: Verschieben"
L.DISABLED_IN_INSTANCE    = "Overlord ist in Instanzen deaktiviert."
L.MM_NEUTRAL          = "Neutral"
L.ZONE_NEUTRAL        = "Neutral"

-- ZoneIndicator
L.INDICATOR_TITLE = "|cFFFFFF00Eroberungszone|r"
L.INDICATOR_CLICK_WAYPOINT = "Linksklick: Wegpunkt setzen"
L.IN_THE_ZONE     = "Ihr seid in der Zone!"
L.INDICATOR_DISMOUNT_TO_CAPTURE = "Steigt ab."
L.INDICATOR_ENABLE_PVP = "Aktiviert PvP (/pvp)."
L.INDICATOR_STEALTH_TO_CAPTURE   = "Verlasst die Tarnung zum Erobern."
L.INDICATOR_HUD_DISABLED         = "Kehrt zur Eroberungszone zurück."
L.DISTANCE_FORMAT = "Entfernung: ~%.0f m"
L.COORDS_FORMAT   = "Koords: %.1f, %.1f"

-- Siege
L.SIEGE_COOLDOWN_LABEL = "Waffenstillstand (%s)"
L.MAP_CAPITAL_LABEL = "Hauptstadt"
L.FORCES_PRESENT = "%d %s in der Nähe"
L.NOT_IN_WARZONE = "Nicht in einer Kriegszone"

-- Combat
L.CANNOT_IN_COMBAT   = "Im Kampf nicht möglich."
L.HONORABLE_KILLS_CONFIRM = "+%d ehrenhafte Siege: Gesamt: %d"

-- Manuelle Goldverträge

-- Domination
L.DOMINATION_LABEL = "Wöchentliche Gebietsdominanz"

-- Sync
L.SYNC_CAPTURED_FRIENDLY = "%s erobert durch %s!"
L.SYNC_CAPTURED_ENEMY    = "%s eingenommen durch %s!"
L.SYNC_CAPTURED_ENEMY_BY = "%s eingenommen durch %s (%s)!"
L.ENEMY_CAPTURING        = "%s: Angriff durch %s!"
L.ENEMY_CAPTURING_BY     = "%s: Angriff durch %s (%s)!"
L.SYNC_REQUESTED        = "Sync angefordert. Ihr solltet den aktuellen Stand in Kürze erhalten."
L.SYNC_WHISPER_SENT     = "Sync-Anfrage per Addon-Flüstern an %s gesendet."
L.COMMUNITY_BTN_JOIN    = "Community"
L.COMMUNITY_BTN_TOOLTIP = "Community-Einladung"
L.FACTION_CALL_TOOLTIP_TITLE = "Fraktion rufen"
L.FACTION_CALL_BUTTON       = "Kriegshorn"
L.GENERAL_BUTTON            = "Kommando"
L.FACTION_CALL_TOOLTIP  = "Blast ins Kriegshorn! Alle Verbündeten Eurer Fraktion mit Overlord erhalten eine Schlachtzugswarnung mit Eurer Front und Zone."
L.FACTION_CALL_TOOLTIP_SHARED = "Einmal alle 4 Stunden für die ganze Fraktion: nur ein Herold gleichzeitig."
L.FACTION_CALL_TOOLTIP_CD = "Verfügbar in %s"
L.FACTION_CALL_COOLDOWN_SHARED = "Fraktionsruf in Abklingzeit: ein Verbündeter rief kürzlich (%s verbleibend)."
L.FACTION_CALL_SENT     = "Ruf an alle Overlord-Verbündeten Eurer Fraktion gesendet."
L.FACTION_CALL_RECEIVED = "%s ruft die Fraktion: %s (%s)!"
L.FACTION_CALL_RECEIVED_NO_ZONE = "%s ruft die Fraktion: %s!"
L.FACTION_CALL_RECEIVED_GENERIC = "%s ruft die Fraktion!"
L.GUILD_KILL_ALERT_ENABLED_LABEL = "Warnungen vor feindlichen Gildenraids"
L.GUILD_KILL_ALERT_ENABLED_TOOLTIP = "Warnt im Chat, wenn eine feindliche Gilde mit 5+ Mitgliedern in 5 Minuten 20+ Siege erzielt."
L.GUILD_KILL_ALERT = "Gilde %s: %d+ Kills von %d+ Mitgliedern%s!"
L.GUILD_KILL_ALERT_FRONT = "Gilde %s: %d+ Kills von %d+ Mitgliedern in %s%s!"
L.GUILD_KILL_DIAG_HEADER = "Warnung vor feindlichen Gildenraids: %s, Schwelle %d Kills und %d Mitglieder in 5 Min."
L.GUILD_KILL_DIAG_EMPTY = "In den letzten 5 Minuten keine Gilden-Kills empfangen."
L.GUILD_KILL_DIAG_ROW = "%s (%s): %d Kills, %d Mitglieder"
L.HELP_GUILD_KILLS = "|cFFFFFF00/ov guildkills [on|off|test]|r: Warnung vor feindlichen Gildenraids"
L.FACTION_CALL_NO_ONLINE  = "Keine Verbündeten Eurer Fraktion online in der Community."
L.FACTION_CALL_COMBAT     = "Fraktionsruf während Kampfsperre nicht möglich."
L.FACTION_CALL_NOT_IN_FRONT = "Ihr müsst auf einer aktiven Kriegsfront sein."
L.FACTION_CALL_TOOLTIP_NOT_IN_FRONT = "Nur auf aktiver Kriegsfront verfügbar."
L.GENERAL_TOOLTIP_TITLE_ALLIANCE = "General der Allianz"
L.GENERAL_TOOLTIP_TITLE_HORDE = "General der Horde"
L.GENERAL_TOOLTIP = "Übernehmt das Kommando. Euer Icon führt alle Verbündeten auf der Kriegskarte. Ein General pro Banner."
L.GENERAL_TOOLTIP_RELEASE = "Erneut klicken, um das Kommando abzugeben."
L.GENERAL_ASSUMED_SELF = "Ihr seid der Allianz-General auf |cFFFFD100%s|r. Das Banner folgt Euren Schritten."
L.GENERAL_ASSUMED_SELF_HORDE = "Ihr seid der Horde-General auf |cFFFFD100%s|r. Das Banner folgt Euren Schritten."
L.GENERAL_RELEASED_SELF = "Ihr habt das Kommando über das Banner abgegeben."
L.GENERAL_SLOT_TAKEN = "General |cFFFFD100%s|r führt bereits das Banner."
L.GENERAL_NOT_LEADER = "Nur der Gruppen- oder Schlachtzug-Anführer kann diese Rolle übernehmen."
L.GENERAL_NOT_ON_FRONT = "Ihr müsst auf einer aktiven Kriegsfront sein."
L.GENERAL_COMBAT = "Kommando kann während Kampfsperre nicht übernommen werden."
L.GENERAL_INSTANCE = "Kommando in Instanzen nicht verfügbar."
L.GENERAL_RECEIVED = "%s übernimmt das Kommando auf |cFFFFD100%s|r!"
L.GENERAL_MAP_TOOLTIP = "General: %s"
L.GENERAL_ENEMY_MAP_TOOLTIP = "Feindlicher General: %s"
L.GENERAL_FALLEN = "General %s ist gefallen! Getötet von %s."
L.GENERAL_COUNTERPART_SLAIN = "Feindlicher General %s wurde von %s erschlagen!"
L.GENERAL_ENEMY_ASSUMED = "Feindlicher General %s führt das Banner auf |cFFFFD100%s|r!"
L.GENERAL_SHARD_UNKNOWN = "Shard anders oder unbekannt."
L.VERSION_OUTDATED      = "Eine neuere Version (%s) ist verfügbar. Bitte aktualisieren!"
L.SPOOF_DETECTED        = "Modifiziertes Addon von %s erkannt: Scheineroberungen blockiert und zurückgesetzt."

-- Anti-farming
L.FARM_KILL_DETECTED  = "Kill-Farming unterdrückt: %s -> %s (%d+ Kills in 5 Min, Statistik nicht gezählt)."

-- Export
L.EXPORT_CLOSE          = "Schließen"
L.FOREVER_FEATURE_UNAVAILABLE = "Auf Overlord Forever nicht verfügbar."

-- Mines / Gold
L.MINE_AZURELODE        = "Azurmine"
L.MINE_DARROW           = "Darrowhügel"
L.MINE_ELEMGORGE        = "Elemgorge-Mine"
L.MINE_STONESSPLINTER   = "Steinsplittermine"
L.MINE_JASPERLODE       = "Jaspismine"
L.GOLD_LABEL            = "Coins"
L.GOLD_COUNTER          = "Coins: %d / %d"
L.GOLD_HEADER_TIP       = "Verdient Coins in den markierten Kreisen. Vorgebirge des Hügellands: Azurmine und Darrowhügel. Silberwald: Elemgorge. Loch Modan: Steinsplitter. Wald von Elwynn: Jaspismine."
L.GOLD_NODE_BONUS       = "+%d Coins (Abbau)"
L.GOLD_FCT_GAIN         = "+%d coins"
L.GOLD_NOT_ENOUGH       = "Nicht genug Coins (%d nötig)."
L.GOLD_REINFORCE        = "Angriff"

-- Guild Keep
L.GUILD_KEEP_STONETALON     = "Sonnenfelsrückzug"
L.GUILD_KEEP_WETLANDS       = "Burg Menethil"
L.GUILD_KEEP_BADLANDS       = "Festung Angor"
L.GUILD_KEEP_CROSSROADS     = "Das Wegekreuz"
L.GUILD_KEEP_MULGORE        = "Dorf der Bluthufe"
L.GUILD_KEEP_SELECT_TITLE   = "Festung wählen"
L.GUILD_KEEP_SELECT_AUTO    = "Auto (von Gilde gehalten)"
L.GUILD_KEEP_NEUTRAL        = "Unbeansprucht"
L.GUILD_KEEP_CAPTURING      = "Eroberung läuft…"
L.GUILD_KEEP_PANEL_HELD     = "Gehalten von %s"
L.GOLD_BARRICADE        = "Verstärken"
L.GOLD_TOOLTIP_COST     = "Kosten: %d Coins."
L.ENEMY_MINING_HORDE     = "Alarm! Die Horde baut Erz ab: %s!"
L.ENEMY_MINING_ALLIANCE  = "Alarm! Die Allianz baut Erz ab: %s!"
L.MINE_TOOLTIP          = "Coin-Mine: im Kreis bleiben, um Coins zu verdienen."
L.MINE_ENTERED          = "Ihr habt %s betreten. Coin-Erzeugung gestartet."
L.MINE_LEFT             = "Ihr habt %s verlassen. Coin-Erzeugung gestoppt."
L.MINE_STOCK            = "Minenreserven: %d / %d"
L.MINE_DEPLETED         = "%s ist erschöpft. Reserven füllen sich mit der Zeit."
L.CATCHUP_PHASE         = "Aufhol-Erfahrung erkannt: Overlord ist in dieser Phase inaktiv."
L.CATCHUP_MAP_BANNER    = "Aufhol-Phase: Overlord inaktiv"


-- ================================================================
-- ZamestoTV (ruRU)
-- ================================================================
elseif Overlord.IsRussianLocale() then

-- Noms des zones
L.ZONE_NAMES = {
    stromgarde = "Крепость Стромгард",
    faldir     = "Бухта Фальдира",
    witherbark = "Деревня Сухокожих",
    goshek     = "Ферма Го'Шека",
    dabyrie    = "Усадьба Дабири",
    refuge     = "Опорный пункт",
    highperch  = "Западное нагорье",
    newstead   = "Стена Торадина",
    hammerfell = "Павший Молот",
    argorok    = "Круг Западного Связывания",
    loch_alliance_capital = "Телсамар",
    loch_horde_capital = "Оплот Мо'грош",
    loch_valley_of_kings = "Долина Королей",
    loch_south_gate_pass = "Застава Южных Ворот",
    loch_silver_stream_mine = "Рудник Серебряных копей",
    loch_algaz_post = "Станция Алгаз",
    loch_farstrider_lodge = "Приют Странников",
    loch_ironband = "Раскопки Сталекрута",
    loch_the_loch = "Озеро Лок",
    loch_stonewrought_dam = "Каменная плотина",
    durotar_tiragarde_keep = "Крепость Тирагард",
    durotar_alliance_fleet = "Утес Колкар",
    durotar_senjin_village = "Деревня Сен'джин",
    durotar_razor_hill = "Колючий холм",
    durotar_deadeye_shore = "Берег Мертвеца",
    durotar_southfury = "Река Строптивая",
    durotar_spirit_rock = "Долина Испытаний",
    durotar_thunder_ridge = "Громовой хребет",
    durotar_drygulch_ravine = "Суходол",
    durotar_dranosh_blockade = "Подступы к Оргриммару",
    elwynn_westbrook = "Гарнизон Западного ручья",
    elwynn_goldshire = "Златоземье",
    elwynn_tower_of_azora = "Башня Азоры",
    elwynn_ridgepoint = "Дозорная башня",
    elwynn_mirror_lake = "Озеро Хрустальное",
    elwynn_fargodeep = "Элвиннский рудник",
    elwynn_jerods_landing = "Пристань Джерода",
    elwynn_stone_cairn = "Озеро Каменных Столбов",
    elwynn_eastvale = "Лесопилка Восточной долины",
    elwynn_invasion_camp = "Аванпост Черной горы",
    ash_astranaar = "Астранаар",
    ash_iris_lake = "Озеро Ирис",
    ash_raynewood = "Приют в Ночных Лесах",
    ash_night_run = "Ночная Поляна",
    ash_bloodtooth_camp = "Лагерь Кровавого Клыка",
    ash_silverwind = "Приют Серебряного Ветра",
    ash_mystral_lake = "Озеро Мистраль",
    ash_fallen_sky_lake = "Озеро Павшего Неба",
    ash_dor_danil = "Обитель Дор'Данил",
    ash_splintertree = "Застава Расщепленного Дерева",
}

L.FRONT_ARATHI_NAME = "Нагорье Арати"
L.FRONT_LOCH_MODAN_NAME = "Лок Модан"
L.FRONT_DUROTAR_NAME = "Дуротар"
L.FRONT_ELWYNN_NAME = "Элвиннский лес"
-- Libelle court pour le menu front (bouton): mapName reste le nom complet pour alertes / carte.
L.FRONT_ARATHI_DROPDOWN = "Арати"
L.FRONT_LOCH_MODAN_DROPDOWN = "Лок Модан"
L.FRONT_DUROTAR_DROPDOWN = "Дуротар"
L.FRONT_ELWYNN_DROPDOWN = "Элвинн"
L.FRONT_ASHENVALE_NAME = "Ясеневый лес"
L.FRONT_ASHENVALE_DROPDOWN = "Ясеневый лес"
-- Sous-zone puis région du front pour les alertes (ex. « Poste d'Algaz (Loch Modan) »)
L.CAPTURE_ALERT_SUBZONE_IN_REGION = "%s (%s)"

-- Factions (forme narrative pour les messages)
L.THE_HORDE    = "Орда"
L.THE_ALLIANCE = "Альянс"

-- Factions majuscules (victoire totale)
L.VICTORY_FACTION_HORDE    = "ОРДА"
L.VICTORY_FACTION_ALLIANCE = "АЛЬЯНС"

-- Format de date
L.DATE_FORMAT = "%d.%m.%Y"

-- === Core ===
L.WEEKLY_RESET   = "Новая неделя! Кампания сброшена по расписанию американской беты."
L.MODULE_ERROR   = "Ошибка модуля %s: %s"
L.ADDON_LOADED   = "Загружена версия v%s. Введите |cFFFFFF00/ov help|r для просмотра команд."
L.SYNC_LOGIN_WAIT = "Синхронизация данных зон... Карта скоро обновится."
L.ALL_ZONES_RESET = "Все зоны были сброшены!"
L.FRONT_CAPITAL_RELEASED = "%s: перемирие завершено. Завоевания сохраняются, а павшая столица восстаёт; обе столицы защищены до %s."
L.CAPITAL_PROTECTED_UNTIL = "Защищена до %s"
L.CAPITAL_PROTECTED_SHORT = "До %s"


-- === Commands ===
L.HELP_HEADER   = "|cFF00FF00========== Overlord: Команды ==========|r"
L.HELP_SHOW     = "|cFFFFFF00/ov show|r: Показать интерфейс"
L.HELP_HIDE     = "|cFFFFFF00/ov hide|r: Скрыть интерфейс"
L.HELP_TOGGLE   = "|cFFFFFF00/ov toggle|r: Переключить видимость интерфейса"
L.HELP_HUD      = "|cFFFFFF00/ov hud [auto|on|off|toggle]|r: Настроить верхний HUD"
L.HUD_SHOWN     = "|cFF00FF00[Overlord]|r Верхний HUD включён."
L.HUD_HIDDEN    = "|cFF00FF00[Overlord]|r Верхний HUD отключён."
L.HUD_AUTO      = "|cFF00FF00[Overlord]|r Верхний HUD в режиме Авто."
L.HELP_STATUS   = "|cFFFFFF00/ov status|r: Показать статус зон"
L.HELP_ZONES    = "|cFFFFFF00/ov zones|r: Показать доступные зоны с координатами"
L.HELP_WHERE    = "|cFFFFFF00/ov where|r: Переключить индикатор зоны"
L.HELP_START    = "|cFFFFFF00/ov start <зона>|r: Начать захват зоны"
L.HELP_LB       = "|cFFFFFF00/ov lb|r: Показать таблицу лидеров"
L.HELP_SYNC     = "|cFFFFFF00/ov sync [ИмяИгрока-ИгровойМир]|r: Запросить синхронизацию (личные сообщения цели или группа/рейд/сообщество)"
L.HELP_DOM      = "|cFFFFFF00/ov dom|r: Отладка еженедельной шкалы господства (секунды, усиления, % отображения)"
L.HELP_SCALE    = "|cFFFFFF00/ov scale [0.8-1.2]|r: Масштаб панели UI (также: Esc > Параметры > Модификаторы > Overlord)"
L.DOM_DEBUG_HEADER = "Еженедельное господство:"
L.HELP_GUIDE    = "|cFFFFFF00/ov guide|r: Краткое визуальное руководство"
L.HELP_FOOTER   = "|cFF00FF00=============================================|r"

L.STATUS_HEADER      = "|cFF00FF00========== Overlord: Статус ==========|r"
L.STATUS_IN_PROGRESS = "В ПРОЦЕССЕ (удержание %d:%02d)"
L.STATUS_AVAILABLE   = "ДОСТУПНО"
L.STATUS_LOCKED      = "ЗАБЛОКИРОВАНО"
L.STATUS_TOTAL       = "Всего: %d/%d зон (%d%%)"
L.STATUS_FOOTER      = "|cFF00FF00=============================================|r"

L.NOT_INITIALIZED  = "Модификатор еще не инициализирован."
L.USAGE_START      = "Использование: /ov start <зона>"
L.ZONE_UNKNOWN     = "Неизвестная зона: %s"
L.ZONE_NOT_AVAILABLE = "%s недоступна!"
L.MUST_BE_IN_ZONE  = "Вы должны находиться в %s, чтобы начать захват! (%.1f, %.1f)"
L.UNKNOWN_COMMAND  = "Неизвестная команда: %s"
L.HELP_HINT        = "Введите /ov help, чтобы просмотреть доступные команды."
L.POS_RESET        = "Положение панели было сброшено."

-- === UI ===
L.CONTROL_ZONES     = "КОНТРОЛИРУЕМЫЕ ЗОНЫ"
L.ACTIVE_ZONE       = "АКТИВНАЯ ЗОНА"
L.NO_ACTIVE_ZONE    = "Нет активной зоны"
L.HOLD_LABEL        = "Удержание"
L.UI_CONTESTED      = "ОСПАРИВАЕТСЯ"
L.UI_PAUSED         = "ПАУЗА: вне зоны, таймер убывает"
L.UI_IN_PROGRESS    = "В ПРОЦЕССЕ: удерживайте позицию"
L.UI_ENEMY_CAPTURING = "ВРАГ ЗАХВАТЫВАЕТ: оспорьте зону!"
L.UI_COMPLETE       = "ЗАВЕРШЕНО"
L.ACTION_SHORTCUT_LABEL = "Ярлык для панели действий"
L.ACTION_SHORTCUT_TOOLTIP = "Берёт значок Overlord на курсор: щёлкните по ячейке панели команд, чтобы положить его туда."
L.ACTION_SHORTCUT_COMBAT = "Ярлык для панели действий невозможно создать во время боя."
L.ACTION_SHORTCUT_FAILED = "Не удалось создать или подобрать ярлык. Убедитесь, что вы находитесь вне боя, и попробуйте снова."
L.UI_SCALE_LABEL    = "Масштаб панели"
L.UI_SCALE_TOOLTIP  = "Размер главной панели и таблицы лидеров. Вы также можете использовать команду |cffffffff/ov scale|r."
L.NOTIFICATION_CHAT_LABEL = "Сообщения Overlord"
L.NOTIFICATION_CHAT_TOOLTIP = "Вкладка чата, где появляются оповещения и сообщения Overlord."
L.NOTIFICATION_CHAT_DEFAULT = "Основной чат (по умолчанию)"
L.CHAT_TAB_LABEL = "Вкладка Overlord"
L.CHAT_TAB_BUTTON = "Создать вкладку"
L.CHAT_TAB_TOOLTIP = "Создаёт вкладку чата «Overlord» и выводит туда сообщения Overlord. Её можно перемещать, скрывать или закрывать, как любую вкладку."
L.CHAT_TAB_READY = "Сообщения Overlord теперь появляются в этой вкладке."
L.CHAT_TAB_FAILED = "Нет свободных вкладок чата. Закройте одну и попробуйте снова."
L.ACTION_SHORTCUT_BUTTON = "Взять"
L.SETTINGS_SECTION_GENERAL = "Общие"
L.SETTINGS_SECTION_CHAT = "Чат"
L.SETTINGS_SECTION_MAP = "Карта и миникарта"
L.SETTINGS_SECTION_HUD = "Экранные панели"
L.UI_FRONT_SELECT = "Фронт (список)"
L.UI_FRONT_PICKER_TOOLTIP = "Выберите, какой список зон отображать. Ваш таймер захвата и бой всё равно будут привязаны к карте, на которой вы сражаетесь."
L.UI_FRONT_READONLY_TOOLTIP = "Вы просматриваете другой фронт или находитесь вне зоны боевых действий. Клики не запускают захват; путевые точки используют карту выбранного фронта."
L.UI_CAPTURE_READONLY = "Только чтение: чтобы начать захват из этого списка, перейдите на этот фронт в открытом мире."
L.MAP_OVERLAY_OPACITY_LABEL   = "Прозрачность захвата на карте"
L.MAP_OVERLAY_OPACITY_TOOLTIP = "Прозрачность кругов зон захвата только на |cffffffffкарте мира|r. Более низкие значения делают саму карту под ними более заметной.\nНе влияет на мини-карту (см. Прозрачность захвата на мини-карте) или круги золотых рудников."
L.MINIMAP_OVERLAY_OPACITY_LABEL   = "Прозрачность захвата на мини-карте"
L.MINIMAP_OVERLAY_OPACITY_TOOLTIP = "Прозрачность кругов зон захвата на |cffffffffмини-карте|r. Более низкие значения делают саму карту под ними более заметной.\nНе влияет на карту мира, иконки крепостей гильдий или круги золотых рудников."
L.MAP_ICON_OPACITY_LABEL = "Прозрачность значков (карта)"
L.MAP_ICON_OPACITY_TOOLTIP = "Прозрачность значков точек захвата, крепостей и аванпостов на |cffffffffкарте мира|r. Низкое значение оставляет видимыми метки заданий в городах. При 0 значки скрыты."
L.MAP_ICON_SCALE_LABEL = "Размер значков (карта)"
L.MAP_ICON_SCALE_TOOLTIP = "Размер значков столиц, точек захвата, крепостей и аванпостов на |cffffffffкарте мира|r."
L.MINIMAP_BUTTON_LABEL          = "Кнопка мини-карты"
L.MINIMAP_BUTTON_TOOLTIP        = "Показывает кнопку Overlord у мини-карты. Включите, чтобы вернуть её; менеджеры кнопок мини-карты могут переместить её в своё меню."
L.MINIMAP_CAPTURE_ZONES_LABEL   = "Значки на мини-карте"
L.MINIMAP_CAPTURE_ZONES_TOOLTIP = "Показывать значки Overlord на |cffffffffмини-карте|r: круги захвата, генералы, рудники, крепости гильдий и аванпосты. Наведение мыши не мешает видеть точки отслеживания охотников или еды. Отключите, чтобы скрыть их все (карта мира сохраняет свои настройки)."
L.MAP_ZONE_TITLES_LABEL         = "Названия зон на карте"
L.MAP_ZONE_TITLES_TOOLTIP       = "Показывать пергаментные ленты с названиями зон захвата и золотых рудников на |cffffffffкарте мира|r. Отключите для более чистой карты, если вы уже знаете эти области."
L.MAP_PATH_OPACITY_LABEL      = "Прозрачность путей на карте"
L.MAP_PATH_OPACITY_TOOLTIP    = "Прозрачность |cffffffffпунктирных линий|r между зонами захвата на карте мира (1: блеклые, 3: очень заметные)."
L.SETTINGS_TOGGLE_ON          = "Включено"
L.SETTINGS_TOGGLE_OFF         = "Отключено"
L.AUTO_WAYPOINT_LABEL         = "Автоматическая путевая точка"
L.AUTO_WAYPOINT_TOOLTIP       = "Автоматически ставит стандартную булавку Blizzard на следующую доступную цель. Если вы удалите или замените эту булавку, Overlord дождется появления новой цели, прежде чем поставить её снова. Булавка удаляется, когда цель перестает быть актуальной."
L.SHOW_TOP_HUD_LABEL          = "Верхняя панель HUD"
L.SHOW_TOP_HUD_TOOLTIP        = "Авто показывает нужные панели у точек захвата, шахт и крепостей. Всегда показывает их на соответствующих картах; Никогда скрывает. Индикатор цели остаётся доступным."
L.TOP_HUD_MODE_AUTO           = "Авто"
L.TOP_HUD_MODE_ALWAYS         = "Всегда"
L.TOP_HUD_MODE_NEVER          = "Никогда"
L.SHOW_TUTORIAL_BOOK_LABEL    = "Иконка книги обучения"
L.SHOW_TUTORIAL_BOOK_TOOLTIP  = "Показывает иконку книги обучения на верхней панели HUD. Отключите, чтобы скрыть только эту иконку, сохранив панели coins и крепостей гильдий."
L.SOUND_ENABLED_LABEL         = "Звуки Overlord"
L.SOUND_ENABLED_TOOLTIP       = "Отключить все звуки Overlord (оповещения, боевой горн, захваты, панели, эффект coins, фоновая музыка дуэлей и т.д.)."
L.SETTINGS_BUTTON             = "Настройки"
L.LAYER_JUMPER_BUTTON = "Layer Jumper"
L.NET_HEALTH_TITLE = "Сеть Overlord"
L.NET_HEALTH_OK = "Всё в порядке"
L.NET_HEALTH_WARN = "Стоит присмотреться"
L.NET_HEALTH_BAD = "Проблема"
L.NET_HEALTH_HINT = "Введите /ov network для подробностей."
L.MW_ALERT = "Most Wanted рядом: %s (#%d %s, %d убийств за неделю)!"
L.HELP_WANTED = "|cFFFFFF00/ov wanted [on|off]|r: Most Wanted: оповещение, когда рядом один из 5 лучших врагов"
L.MW_STATE_ON = "Оповещения Most Wanted: вкл."
L.MW_STATE_OFF = "Оповещения Most Wanted: выкл."
L.LAYER_JUMPER_TOOLTIP = "Сменить слой в вашей зоне"
L.HELP_LAYER = "|cFFFFFF00/ov layer [help on|off]|r: Layer Jumper (смена слоя; помогать другим добровольно)"
L.LJ_TITLE = "Layer Jumper"
L.LJ_ZONE_LAYER = "%s - ваш слой: %s"
L.LJ_LAYER_UNKNOWN = "неизвестен"
L.LJ_LAYER_NAME = "Слой #%s"
L.LJ_HELPERS = "помощников: %d"
L.LJ_HERE = "вы здесь"
L.LJ_JOIN = "Перейти"
L.LJ_SEARCH = "Поиск"
L.LJ_RANDOM = "Сменить слой"
L.LJ_RANDOM_TOOLTIP = "Перейти на любой другой слой этой зоны (при необходимости сначала поиск)."
L.LJ_CANCEL = "Отмена"
L.LJ_LIST_EMPTY = "Выберите НИП, чтобы узнать свой слой, затем нажмите «Поиск»."
L.LJ_HELP_MODE = "Помогать другим: %s"
L.LJ_HELP_MODE_AUTO = "вкл."
L.LJ_HELP_MODE_OFF = "выкл."
L.LJ_HELP_MODE_TOOLTIP = "Добровольный помощник (по умолчанию выключено). Если включено, вы автоматически, без окон, приглашаете игрока Overlord своей фракции, который ищет ваш слой; после смены слоя он сам выходит из группы. Только если вы одни, вне боя и подземелий."
L.LJ_EXPLAIN = "Добровольный помощник с выбранного слоя приглашает вас в группу. Вне боя игра за несколько секунд переносит вас на его слой, затем вы автоматически выходите из группы. Передаются только зона и слой, но не ваша позиция."
L.LJ_STATUS_IDLE = "Найдите помощников в своей зоне."
L.LJ_STATUS_SEARCHING = "Поиск помощников: %s..."
L.LJ_STATUS_READY = "Найдено помощников: %d."
L.LJ_STATUS_NONE = "Сейчас в этой зоне нет добровольных помощников. Попробуйте чуть позже или в более людной зоне."
L.LJ_STATUS_REQUESTING = "Запрос приглашения у %s..."
L.LJ_STATUS_JOINING = "Приглашение принято, вход в группу %s..."
L.LJ_STATUS_VERIFYING = "Смена слоя... (%d с)"
L.LJ_STATUS_VERIFY_COMBAT = "В бою: смена слоя ждёт окончания боя (%d с)."
L.LJ_STATUS_SUCCESS = "Готово: теперь вы на слое %s."
L.LJ_STATUS_UNCONFIRMED = "Вы вышли из группы; новый слой не подтверждён (рядом нет НИП)."
L.LJ_STATUS_CROWDED = "Вы вышли из группы: помощник пригласил других игроков."
L.LJ_STATUS_FAILED = "Никто из помощников вас не пригласил. Попробуйте чуть позже."
L.LJ_STATUS_CANCELLED = "Отменено."
L.LJ_ERR_GROUPED = "Сначала выйдите из группы: помощник должен вас пригласить."
L.LJ_ERR_INSTANCE = "Недоступно в подземельях и на полях боя."
L.LJ_ERR_QUEUE = "Недоступно, пока вы в очереди на поле боя."
L.LJ_ERR_COOLDOWN = "Подождите %d с перед новым поиском."
L.LJ_ERR_SAME_LAYER = "Вы уже на этом слое."
L.LJ_ERR_NO_NETWORK = "Сеть Overlord ещё не готова (нет гильдии и канала). Попробуйте чуть позже."
L.LJ_ERR_LAYER_UNKNOWN = "Сначала выберите НИП: нужно знать свой слой, чтобы перейти на другой."
L.LJ_GUEST_REMOVED = "%s удалён из группы (смена слоя завершена)."
L.LJ_LATE_LEAVE = "Вы вышли из группы %s: эта смена слоя была отменена."
L.CHECK_PVP_BUTTON = "Экспорт"
L.SETTINGS_BUTTON_TOOLTIP     = "Открыть настройки Overlord."
L.SETTINGS_OPEN_UNAVAILABLE   = "Настройки сейчас недоступны. Используйте Esc > Параметры > Модификаторы."
L.SCALE_CURRENT     = "Масштаб панели: %.1f (диапазон от %.1f до %.1f)."
L.SCALE_SET         = "Масштаб панели изменен на %.1f."
L.ATTACK            = "Атака!"
L.LOCKED            = "Заблокировано"
L.NEXT_OBJECTIVE_HEADER   = "Следующая цель"
L.NEXT_OBJECTIVE_COLLAPSE = "Скрыть следующую цель"
L.NEXT_OBJECTIVE_NONE = "Нет доступной цели"
L.NEXT_OBJECTIVE_NO_FRONT = "Вне военного фронта"
-- Outside a war front: one short line for the player's race (faction fallback).
L.HOME_MOTTOS = {
    Human = "Штормград стоит.",
    Dwarf = "Стальгорн не сдаётся.",
    Gnome = "Гномреган возродится!",
    NightElf = "Под взором Элуны.",
    Orc = "Лок'тар огар!",
    Troll = "Духи следят, мон.",
    Scourge = "Тёмная госпожа следит.",
    Tauren = "Мать-Земля ведёт.",
    Skyborne = "Песнь ветров.",
    Alliance = "За Альянс!",
    Horde = "За Орду!",
}
L.NEXT_OBJECTIVE_OUTSIDE_FRONT = "Отправляйтесь на фронт, чтобы увидеть следующую цель."
L.NEXT_OBJECTIVE_GO         = "Идите сюда: встаньте в зону, чтобы запустить таймер захвата."
L.GUIDE_BAR_LABEL           = "Обучение"
L.GUIDE_CLOSE               = "Закрыть"
L.GUIDE_TITLE               = "Обучение"
L.GUIDE_PAGE_INDICATOR      = "Страница %d / %d"
L.GUIDE_PREV                = "Назад"
L.GUIDE_NEXT                = "Вперед"
L.GUIDE_PAGE2_TITLE         = "Захват и ресурсы"
L.VICTORY_DOMINATION_BONUS  = "Полная победа на фронте: +%d%% к еженедельному господству вашей фракции."
L.TOOLTIP_SHIFT_GUIDE       = "Shift + ЛКМ: Краткое руководство"

-- Shard (phasing / instance layer ID from NPC GUID)
L.SHARD_TOOLTIP_TITLE          = "ID шарда"
L.SHARD_TOOLTIP_CURRENT        = "Текущий ID шарда: %s"
L.SHARD_TOOLTIP_REFERENCE_REALM = "Опорный игрок: %s"
L.SHARD_BADGE_REFERENCE       = "через %s"
L.SHARD_TOOLTIP_PLAYERS_HEADER = "Игроки на другом шарде:"
L.SHARD_TOOLTIP_ALL_SAME       = "Все синхронизированные игроки находятся на одном шарде."
L.SHARD_TOOLTIP_UNDETECTED     = "Шард еще не определен (нет виньетки, NPC под курсором мыши или доступного GUID индикатора здоровья)."
L.SHARD_ALERT_TAG              = " #%s"

L.ASSAULT_LAUNCHED    = "Нападение на %s началось!"
L.CAPTURE_LAUNCHED    = "Захват %s начался!"
L.GO_TO_ZONE          = "Отправляйтесь в %s (%.1f, %.1f) для захвата!"
L.ENEMY_CONTROL_MSG   = "%s находится под контролем врага. Сначала захватите необходимые точки."
L.CAPTURE_BLOCKED_RULES = "%s пока не может быть захвачена (перемирие фронта, защищённая столица или требования)."
L.ZONE_IS_LOCKED      = "%s заблокирована."
L.ALREADY_IN_PROGRESS = "%s уже выполняется..."
L.ZONE_UNDER_CONTROL  = "%s находится под контролем фракции %s."

-- === Zones ===
L.CAPTURE_CANCELLED  = "Захват %s отменен! Требования потеряны."
L.ZONE_NOW_AVAILABLE = "%s теперь доступна для захвата!"

-- === ZoneControl ===
L.ENTERED_ZONE       = "Вы вошли в %s! Захват начался!"
L.CAPTURE_NEEDS_PVP = "%s: включите PvP (/pvp), чтобы захватить эту цель."
L.AUTO_DISMOUNT_CAPTURE_CIRCLE = "Вы летите в %s: автоматическое спешивание через %d секунд."
L.AUTO_DISMOUNT_MINE_CIRCLE    = "Вы летите в кругу шахты %s: автоматическое спешивание через %d секунд."
L.HOLD_TIMER_STARTED = "Таймер удержания запущен для %s (%d:%02d). Оставайтесь в зоне!"
L.CAPTURE_SYNC_WAITING = "Ожидание начальной синхронизации: захват %s временно заблокирован."
L.ZONE_CONTESTED_OUTNUMBER = "%s оспаривается! Врагов больше (%d против %d)."
L.ZONE_CONTESTED_EVEN      = "%s оспаривается! Силы равны (%d против %d)."
L.ZONE_SECURED       = "%s защищена! Захват возобновлен."
L.BACK_IN_ZONE       = "Вы вернулись в %s! Захват возобновлен."
L.LEFT_ZONE          = "Вы покинули %s! Прогресс убывает..."
L.CAPTURE_LOST       = "Захват %s потерян! Вернитесь туда, чтобы возобновить."
L.ENEMY_CAPTURE_REVERSED = "Захват %s врагом отменен! Зона защищена."
L.ZONE_CAPTURED_BY   = "%s захвачена %s!"
L.TOTAL_VICTORY_MSG  = "   ПОЛНАЯ ПОБЕДА: %s!   "
L.TOTAL_VICTORY_FRONT_MSG = "   ПОЛНАЯ ПОБЕДА: %s! Фронт: %s   "
-- === CombatTracker ===

-- === LeaderboardUI ===
L.LB_TITLE         = "ТАБЛИЦА РЕКОРДОВ"
L.LB_SEARCH_PLACEHOLDER = "Игрок или гильдия..."
L.LB_SEARCH_EMPTY = "Нет результатов"
L.LB_SEARCH_WORKING = "Поиск..."
L.LB_BUTTON        = "Таблица рекордов"
L.LB_BUTTON_TOOLTIP = "Открыть еженедельный рейтинг убийств и захватов"
L.HOF_BUTTON        = "Зал славы"
L.HOF_BUTTON_TOOLTIP = "Открыть Зал славы: почести, подвиги и жертвователи"
L.DISCORD_BUTTON = "Discord"
L.DISCORD_BUTTON_TOOLTIP = "Присоединиться к серверу Discord"
L.DISCORD_POPUP_TITLE = "Присоединиться к серверу Discord"
L.DISCORD_POPUP_HINT = "Откройте Discord в браузере и вставьте ссылку-приглашение ниже."
L.DISCORD_URL_LABEL = "Ссылка на Discord"
L.DISCORD_POPUP_COPY_HINT = "URL выбран: скопируйте (Ctrl+C)"
L.HOF_TITLE = "Зал славы"
L.HOF_SECTION_EMPTY = "Записей пока нет."
L.HOF_CAT_GUILD = "Заслуги гильдий"
L.HOF_CAT_PLAYER = "Заслуги игроков"
L.HOF_CAT_LIFETIME = "Ваши подвиги"
L.HOF_PROGRESS_COUNT = "%d / %d"
L.HOF_CAT_ALLIANCE = "Альянс"
L.HOF_CAT_HORDE = "Орда"
L.HOF_CAT_WEEKLY = "Еженедельные подвиги"
L.HOF_CAT_DONORS = "Вкладчики"
L.HOF_DONOR_LINE = "Пожертвовано более 100 золотых в военную казну"
L.HOF_POINTS_LABEL = "Очки достижений фронта"
L.HOF_RECENT_TITLE = "Недавние подвиги"
L.HOF_PROGRESS_TITLE = "Обзор прогресса"
L.HOF_PROGRESS_TOTAL = "Заработано наград"
L.HOF_SEARCH_NO_RESULTS = "Совпадений не найдено."
L.HOF_WEEKLY_PLAYER_RANK_LINE = "Бета, убийцы недели: место %d"
L.HOF_WEEKLY_GUILD_RANK_LINE = "Бета, гильдии недели: место %d"
L.LB_CAMPAIGN_DATE = "Кампания с %s по %s"
L.LB_INFO_ENDS = "Кампания закончится через"
L.LB_INFO_RANKED = "Игроков в рейтинге:"
L.LB_INFO_RANKED_VALUE = "|cFF4488FF%s Альянс|r · |cFFFF4444%s Орда|r"
L.LB_INFO_YOU = "Вы:"
L.LB_INFO_UNRANKED = "пока без места"
L.LB_INFO_NEXT = "ещё %s ПП до #%d"
L.LB_INFO_FIRST = "Вы возглавляете рейтинг!"
L.LB_RULESET_LABEL = "Кампания %s"
L.RULESET_NAME_PVP = "PvP"
L.RULESET_NAME_NORMAL = "Обычный"
L.RULESET_NAME_RP = "RP"
L.RULESET_NAME_HARDCORE = "Hardcore"
L.LB_CACHED_REFRESHING = "Сохранённый рейтинг · обновление…"
L.LB_COL_CLASS     = "Класс"
L.LB_COL_RACE      = "Раса"
L.LB_COL_PLAYER    = "Игрок"
L.LB_COL_KILLS     = "ПП"
L.LB_TOTAL_FORMAT  = "|cFF4488FFАльянс: %d убийств|r  |cFFFF4444Орда: %d убийств|r"
L.LB_CAPTURES_ALLIANCE = "Альянс: Захваты"
L.LB_CAPTURES_HORDE    = "Орда: Захваты"
L.LB_CAPTURES_SCROLL_TOOLTIP = "Колесико мыши: прокрутка списка"
L.LB_KILLS_SCROLL_TOOLTIP     = "Колесико мыши: прокрутка рейтинга"
L.LB_ROW_GUILD = "Гильдия: %s"
L.LB_ROW_NO_GUILD = "Гильдия неизвестна"
L.LB_GUILD_TIP_SUMMARY = "%d участников в рейтинге, %d убийств"
L.LB_GUILD_TIP_MORE = "+ ещё %d"
L.LB_GUILD_TIP_TOTAL = "%d убийств"
L.LB_COL_GUILD                = "Гильдия"
L.LB_COL_KEEP                 = "Крепость"
L.LB_GUILD_EMPTY              = "Рейтинговых гильдий пока нет."
L.LB_GUILD_KEEP_EMPTY         = "Ни одна гильдия пока не удерживает крепость."
L.LB_COL_OUTPOST              = "Аванпост"
L.LB_COL_CAPTURES             = "Захваты"
L.LB_OUTPOST_EMPTY            = "Захватов аванпостов пока не было."
L.OUTPOST_SHORT               = "Аванпост"
L.OUTPOST_LOCH_MODAN_NAME     = "Убежище Katrell"
L.OUTPOST_ARATHI_NAME         = "Башня Sage"
L.OUTPOST_DUROTAR_NAME        = "Ферма Кабана"
L.OUTPOST_ELWYNN_NAME         = "Ревущий водопад"
L.OUTPOST_ASHENVALE_NAME      = "Shobek'Aran"
L.OUTPOST_NEUTRAL             = "Нейтральный"
L.OUTPOST_CAPTURING           = "Захват..."
L.OUTPOST_NO_GUILD            = "Вы должны состоять в гильдии, чтобы захватить аванпост."
L.OUTPOST_HOLD_STARTED        = "Захват %s (%d мин)…"
L.OUTPOST_CAPTURE_LOST        = "Захват аванпоста сорван."
L.OUTPOST_UNDER_ATTACK        = "%s атакован!"
L.OUTPOST_CONTESTED_OUTNUMBER = "%s оспаривается! Врагов больше (%d против %d). Прогресс падает."
L.OUTPOST_CONTESTED_EVEN      = "%s оспаривается! Силы равны (%d против %d). Прогресс заморожен."
L.OUTPOST_INDICATOR_TITLE     = "|cFFFFFF00Захват аванпоста|r"
L.OUTPOST_DEFENSE_TITLE       = "|cFFFFFF00Оборона аванпоста|r"
L.OUTPOST_ON_POINT            = "Вы находитесь на точке аванпоста."
L.OUTPOST_ASSAULT_READY       = "Доступен штурм: удерживайте квадрат в течение %d мин."
L.OUTPOST_PANEL_HELD          = "Удерживает: %s"
L.OUTPOST_CAPTURE_ALERT_FRIENDLY = "%s теперь удерживается гильдией %s!"
L.OUTPOST_CAPTURE_ALERT_ENEMY    = "%s захвачен гильдией %s (%s)!"
L.OUTPOST_DEFENDER_UNDER_ATTACK = "%s: аванпост вашей гильдии атакован (%s)!"
L.OUTPOST_DEFENDER_UNDER_ATTACK_BY = "%s: аванпост вашей гильдии атакован гильдией %s (%s)!"
L.OUTPOST_ALLIED_UNDER_ATTACK = "%s: союзный аванпост гильдии %s атакован (%s)!"
L.OUTPOST_ENEMY_ASSAULT      = "%s: %s идёт на штурм!"
L.OUTPOST_ENEMY_ASSAULT_VS   = "%s: %s штурмует %s!"
L.OUTPOST_ALLY_ASSAULT       = "%s: %s идёт на штурм."
L.OUTPOST_ALLY_ASSAULT_VS    = "%s: %s штурмует %s."

-- Repere carte depuis le panel des zones (UI.lua)
L.ZONE_WAYPOINT_BLOCKED = "|cFFFFD100[Overlord]|r Невозможно установить индикатор на этой карте."
L.ZONE_WAYPOINT_FAIL    = "|cFFFFD100[Overlord]|r Не удалось создать индикатор на карте."

-- === MapMarkers ===
L.MAP_AVAILABLE       = "ДОСТУПНО"
L.MAP_LOCKED          = "ЗАБЛОКИРОВАНО"
L.MAP_NEUTRAL         = "НЕЙТРАЛЬНО"
L.MAP_SYNC_PENDING    = "СИНХРОНИЗАЦИЯ"
L.FRONT_ZONES_HEADER = "Зоны %s:"
L.TOOLTIP_FRIENDLY    = "Союзники: %d/%d"
L.TOOLTIP_ENEMY       = "Враги: %d/%d"
L.TOOLTIP_LEFT_CLICK      = "ЛКМ: Главная панель"
L.TOOLTIP_RIGHT_DRAG      = "ПКМ + перетаскивание: Переместить"
L.DISABLED_IN_INSTANCE    = "Аддон Overlord отключен в подземельях и рейдах."
L.MM_NEUTRAL          = "Нейтрально"
L.ZONE_NEUTRAL        = "Нейтрально"

-- === ZoneIndicator ===
L.INDICATOR_TITLE = "|cFFFFFF00Зона захвата|r"
L.INDICATOR_CLICK_WAYPOINT = "ЛКМ: установить метку"
L.IN_THE_ZONE     = "Вы в зоне!"
L.INDICATOR_DISMOUNT_TO_CAPTURE = "Слезьте с транспорта."
L.INDICATOR_ENABLE_PVP = "Включите PvP (/pvp)."
L.INDICATOR_STEALTH_TO_CAPTURE   = "Выйдите из незаметности для захвата."
L.INDICATOR_HUD_DISABLED         = "Вернитесь в зону захвата."
L.DISTANCE_FORMAT = "Дистанция: ~%.0f ярдов"
L.COORDS_FORMAT   = "Координаты: %.1f, %.1f"

-- === Siege (capital timer) ===
L.SIEGE_COOLDOWN_LABEL = "Перемирие (%s)"
L.MAP_CAPITAL_LABEL = "Столица"
L.FORCES_PRESENT = "%d %s рядом"
L.NOT_IN_WARZONE = "Не в зоне боевых действий"

-- === Combat ===
L.CANNOT_IN_COMBAT   = "Невозможно открыть в бою."
L.HONORABLE_KILLS_CONFIRM = "+%d почётных побед: Всего: %d"

-- === Manual gold bounty ===

-- === Domination ===
L.DOMINATION_LABEL = "Еженедельное господство над территорией"


-- === Sync ===
L.SYNC_CAPTURED_FRIENDLY = "%s захвачен фракцией %s!"
L.SYNC_CAPTURED_ENEMY    = "%s захвачен фракцией %s!"
L.SYNC_CAPTURED_ENEMY_BY = "%s захвачен фракцией %s (%s)!"
L.ENEMY_CAPTURING        = "%s: под атакой фракции %s!"
L.ENEMY_CAPTURING_BY     = "%s: под атакой фракции %s (%s)!"
L.SYNC_REQUESTED        = "Запрошена синхронизация. Вы скоро получите текущее состояние."
L.SYNC_WHISPER_SENT     = "Запрос синхронизации отправлен игроку %s через личные сообщения аддона."
L.COMMUNITY_BTN_JOIN    = "Сообщество"
L.COMMUNITY_BTN_TOOLTIP = "Приглашение в сообщество"
L.FACTION_CALL_TOOLTIP_TITLE = "Призыв фракции"
L.FACTION_CALL_BUTTON       = "К оружию"
L.GENERAL_BUTTON            = "Управление"
L.FACTION_CALL_TOOLTIP  = "Протрубите в военный рог! Все союзники вашей фракции с Overlord получат рейдовое предупреждение с вашим фронтом и зоной."
L.FACTION_CALL_TOOLTIP_SHARED = "Раз в 4 часа на всю фракцию: одновременно может трубить только один вестник."
L.FACTION_CALL_TOOLTIP_CD = "Доступно через %s"
L.FACTION_CALL_COOLDOWN_SHARED = "Призыв фракции восстанавливается: союзник протрубил совсем недавно (осталось %s)."
L.FACTION_CALL_SENT     = "Призыв отправлен всем союзникам вашей фракции с Overlord."
L.FACTION_CALL_RECEIVED = "%s призывает фракцию: %s (%s)!"
L.FACTION_CALL_RECEIVED_NO_ZONE = "%s призывает фракцию: %s!"
L.FACTION_CALL_RECEIVED_GENERIC = "%s призывает фракцию!"
L.GUILD_KILL_ALERT_ENABLED_LABEL = "Оповещения о рейдах вражеских гильдий"
L.GUILD_KILL_ALERT_ENABLED_TOOLTIP = "Предупреждает в чате, когда вражеская гильдия из 5+ игроков совершает 20+ убийств за 5 минут."
L.GUILD_KILL_ALERT = "Гильдия %s: %d+ убийств от %d+ участников%s!"
L.GUILD_KILL_ALERT_FRONT = "Гильдия %s: %d+ убийств от %d+ участников в %s%s!"
L.GUILD_KILL_DIAG_HEADER = "Оповещение о рейдах вражеских гильдий: %s, порог %d убийств и %d участников за 5 мин."
L.GUILD_KILL_DIAG_EMPTY = "За последние 5 минут убийств гильдий не получено."
L.GUILD_KILL_DIAG_ROW = "%s (%s): %d убийств, %d участников"
L.HELP_GUILD_KILLS = "|cFFFFFF00/ov guildkills [on|off|test]|r: оповещение о рейдах вражеских гильдий"
L.FACTION_CALL_NO_ONLINE  = "В сообществе не найдено союзников вашей фракции, находящихся в сети."
L.FACTION_CALL_COMBAT     = "Нельзя призвать фракцию во время боя."
L.FACTION_CALL_NOT_IN_FRONT = "Вы должны находиться на активном фронте боевых действий."
L.FACTION_CALL_TOOLTIP_NOT_IN_FRONT = "Доступно только на активном фронте боевых действий."
L.GENERAL_TOOLTIP_TITLE_ALLIANCE = "Генерал Альянса"
L.GENERAL_TOOLTIP_TITLE_HORDE = "Генерал Орды"
L.GENERAL_TOOLTIP = "Принять командование. Ваша иконка направляет всех союзников на военной карте. Один генерал на знамя."
L.GENERAL_TOOLTIP_RELEASE = "Нажмите еще раз, чтобы сложить полномочия."
L.GENERAL_ASSUMED_SELF = "Вы стали Генералом Альянса на |cFFFFD100%s|r. Знамя следует за вашими шагами."
L.GENERAL_ASSUMED_SELF_HORDE = "Вы стали Генералом Орды на |cFFFFD100%s|r. Знамя следует за вашими шагами."
L.GENERAL_RELEASED_SELF = "Вы сложили полномочия командующего знаменем."
L.GENERAL_SLOT_TAKEN = "Генерал |cFFFFD100%s|r уже ведет знамя."
L.GENERAL_NOT_LEADER = "Эту роль может взять только лидер группы или рейда."
L.GENERAL_NOT_ON_FRONT = "Вы должны находиться на активном фронте боевых действий."
L.GENERAL_COMBAT = "Нельзя принять командование во время боя."
L.GENERAL_INSTANCE = "Командование недоступно внутри подземелий/рейдов."
L.GENERAL_RECEIVED = "%s принимает командование на |cFFFFD100%s|r!"
L.GENERAL_MAP_TOOLTIP = "Генерал: %s"
L.GENERAL_ENEMY_MAP_TOOLTIP = "Вражеский генерал: %s"
L.GENERAL_FALLEN = "Генерал %s пал! Убит игроком %s."
L.GENERAL_COUNTERPART_SLAIN = "Вражеский генерал %s был убит игроком %s!"
L.GENERAL_ENEMY_ASSUMED = "Вражеский генерал %s ведет знамя на |cFFFFD100%s|r!"
L.GENERAL_SHARD_UNKNOWN = "Другая или неизвестная фаза (шард)."
L.VERSION_OUTDATED      = "Доступна более новая версия (%s). Пожалуйста, обновитесь!"
L.POPUP_OK = "Понятно"
L.POPUP_WELCOME_TITLE_ALLIANCE = "За Альянс"
L.POPUP_WELCOME_TITLE_HORDE    = "За Орду"
L.POPUP_WELCOME_BODY           = "Добро пожаловать на поле боя, |cFFFFD100%s|r.\n\nОтправляйтесь на |cFFFFD100|Haddon:Overlord:panel|hфронт боевых действий|h|r и прочитайте |cFFFFD100обучение|r (|cFFFFD100иконка книги|r в верхней части экрана)."
L.POPUP_WELCOME_NAME_FALLBACK  = "Чемпион"
L.POPUP_WELCOME_GUIDE_BTN = "Открыть обучение"
L.POPUP_UPDATE_FOREVER_1000_TITLE = "Overlord Forever"
L.POPUP_UPDATE_FOREVER_1000_BODY  = "|cFFFFD100Новое поле боя Overlord:|r убийства игроков в открытом мире на |cFFFFD100Нагорье Арати|r, в |cFFFFD100Лок Модане|r, в |cFFFFD100Дуротаре|r и в |cFFFFD100Ясеневом лесу|r учитываются в таблице лидеров Overlord.\n\n|cFFFFFFFFТребования|r\n• Уровень персонажа должен быть |cFFFFD10060|r.\n• Только открытый мир: рейды, подземелья и поля боя в отдельных игровых зонах не учитываются.\n\n|cFFFFD100Гильдейский аванпост|r ждет вас на каждом фронте войны."
L.POPUP_BATTLE_REPORT_TITLE     = "Боевой отчет"
L.POPUP_BATTLE_REPORT_GUILD     = "Доминирующая гильдия: %s: |cFFFFD100%d|r убийств(а)"
L.POPUP_BATTLE_REPORT_KILLER    = "Лучший убийца: %s: |cFFFFD100%d|r убийств(а)"
L.POPUP_BATTLE_REPORT_CAPTURER  = "Лучший захватчик: %s: |cFFFFD100%d|r захватов(а)"
L.POPUP_BATTLE_REPORT_NOT_FRONT = "Откройте карту фронта боевых действий, чтобы просмотреть боевой отчет."
L.POPUP_BATTLE_REPORT_NO_DATA   = "Данные для рейтинга боевого отчета еще отсутствуют."
L.FEATURED_FRONT_ACTIVITY_TITLE      = "Недавняя активность (За последние 5 мин)"
L.FEATURED_FRONT_ACTIVITY_DASH       = "..."
L.FEATURED_FRONT_ACTIVITY_JUST_NOW   = "только что"
L.FEATURED_FRONT_ACTIVITY_MIN_AGO    = "%d мин. назад"
L.FEATURED_FRONT_ACTIVITY_KILLS      = "%d+ убийств"
L.SPOOF_DETECTED        = "Обнаружена модифицированная версия аддона у %s: фантомные захваты заблокированы и отменены."

-- === Anti-farming ===
L.FARM_KILL_DETECTED  = "Обнаружен фарм убийств: %s -> %s (%d+ убийств за 5 мин., статистика не засчитана)."

-- === Export ===
L.EXPORT_CLOSE          = "Закрыть"
L.FOREVER_FEATURE_UNAVAILABLE = "Недоступно в Overlord Forever."
-- poolTag = FR | EU | US | UNKNOWN (pool communaute Overlord / export Check PvP, pas la langue du royaume)
-- Format : poolTag, campaignId, startDate, endDate

-- === Mines / Gold ===
L.MINE_AZURELODE        = "Лазуритовый рудник"
L.MINE_DARROW           = "Холм Дарроу"
L.MINE_ELEMGORGE        = "Серебряный рудник"
L.MINE_STONESSPLINTER   = "Рудник Камнедробов"
L.MINE_JASPERLODE       = "Яшмовая шахта"
L.GOLD_LABEL            = "Coins"
L.GOLD_COUNTER          = "Coins: %d / %d"
L.GOLD_HEADER_TIP       = "Получайте coins в отмеченных кругах. Предгорья Хилсбрада: Лазуритовый рудник и холм Дарроу. Серебряный бор: рудник ущелья Элем. Лок Модан: рудник Камнедробов. Элвиннский лес: Яшмовая шахта."
-- GOLD_FULL, GOLD_REINFORCE_*, GOLD_BARRICADE_* : numeriques via ApplyGoldLocaleStrings() (Ressources init)
L.GOLD_NODE_BONUS       = "+%d coins (рудная жила)"
-- Texte flottant au-dessus du personnage (gain passif dans le cercle mine)
L.GOLD_FCT_GAIN         = "+%d coins"
L.GOLD_NOT_ENOUGH       = "Недостаточно coins (требуется %d)."
L.GOLD_REINFORCE        = "Атака"

-- Guild Keep
L.GUILD_KEEP_STONETALON     = "Приют у Солнечного Камня"
L.GUILD_KEEP_WETLANDS       = "Крепость Менетил"
L.GUILD_KEEP_BADLANDS       = "Крепость Ангор"
L.GUILD_KEEP_CROSSROADS     = "Перекресток"
L.GUILD_KEEP_MULGORE        = "Деревня Кровавого Копыта"
L.GUILD_KEEP_SELECT_TITLE   = "Выбрать крепость"
L.GUILD_KEEP_SELECT_AUTO    = "Авто (удерживается гильдией)"
L.GUILD_KEEP_NEUTRAL        = "Нейтрально"
L.GUILD_KEEP_CAPTURING      = "Захват…"
L.GUILD_KEEP_PANEL_HELD     = "Удерживается: %s"
L.GOLD_BARRICADE        = "Укрепить"
L.GOLD_TOOLTIP_COST     = "Стоимость: %d coins."
L.ENEMY_MINING_HORDE     = "Внимание! Орда добывает золото: %s!"
L.ENEMY_MINING_ALLIANCE  = "Внимание! Альянс добывает золото: %s!"
L.MINE_TOOLTIP          = "Рудник coins: стойте внутри круга, чтобы получать coins."
L.MINE_ENTERED          = "Вы вошли в %s. Начат приток coins."
L.MINE_LEFT             = "Вы покинули %s. Приток coins прекращен."
L.MINE_STOCK            = "Запасы рудника: %d / %d"
L.MINE_DEPLETED         = "Запасы в %s исчерпаны. Они восстановятся со временем."
L.CATCHUP_PHASE         = "Обнаружен догоняющий опыт: Overlord неактивен в этой фазе."
L.CATCHUP_MAP_BANNER    = "Фаза догона: Overlord неактивен"


end

-- Textes d'or / renfort : valeurs alignees sur Overlord.RessourcesConstants (defini dans Ressources.lua).
-- Appele en fin de Ressources:Initialize (apres CreateGoldHUD ; tooltips au survol = apres init).
function Overlord.ApplyGoldLocaleStrings()
    local R = Overlord.RessourcesConstants
    local Loc = Overlord.L
    if not R or not Loc then return end
    if Overlord.IsFrenchLocale() then
        Loc.GOLD_FULL = string.format("Coins au maximum (%d/%d).", R.GOLD_MAX, R.GOLD_MAX)
        Loc.GOLD_REINFORCE_TIP = string.format(
            "Coûte %d coins. Votre prochaine capture de zone, capitale, avant-poste ou fortin se termine %d s plus tôt (temps minimum de maintien : %d s).",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION, R.REINFORCE_MIN_HOLD)
        Loc.GOLD_REINFORCE_SPENT = string.format("%d coins dépensés. Votre prochaine capture sera %d s plus courte.",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_ACTIVE = string.format("Attaque prête: votre prochaine capture sera %d s plus courte.", R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_USED = string.format("Attaque utilisée: temps de capture réduit de %d s.", R.REINFORCE_REDUCTION)
        Loc.GOLD_BARRICADE_TIP = string.format(
            "Coûte %d coins. La prochaine fois qu'un ennemi commence une capture sur l'une de vos zones de front, il devra tenir %d s de plus.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_SPENT = string.format("%d coins dépensés. La prochaine capture ennemie sur vos zones durera %d s de plus.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_ACTIVE = string.format("Renfort prêt: la prochaine capture ennemie sur vos zones durera %d s de plus.", R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_USED = string.format("Renfort déclenché: l'ennemi doit tenir %d s de plus.", R.BARRICADE_INCREASE)
    elseif Overlord.IsSpanishLocale() then
        Loc.GOLD_FULL = string.format("Coins al máximo (%d/%d).", R.GOLD_MAX, R.GOLD_MAX)
        Loc.GOLD_REINFORCE_TIP = string.format(
            "Cuesta %d coins. Tu próxima captura de zona, capital, avanzada o fortaleza termina %d s antes (tiempo mínimo de mantenimiento: %d s).",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION, R.REINFORCE_MIN_HOLD)
        Loc.GOLD_REINFORCE_SPENT = string.format("%d coins gastados. Tu próxima captura será %d s más corta.",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_ACTIVE = string.format("Ataque listo: tu próxima captura será %d s más corta.", R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_USED = string.format("Ataque usado: tiempo de captura reducido %d s.", R.REINFORCE_REDUCTION)
        Loc.GOLD_BARRICADE_TIP = string.format(
            "Cuesta %d coins. La próxima vez que un enemigo inicie una captura en una de tus zonas de frente, deberá mantener %d s más.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_SPENT = string.format("%d coins gastados. La próxima captura enemiga en tus zonas durará %d s más.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_ACTIVE = string.format("Refuerzo listo: la próxima captura enemiga en tus zonas durará %d s más.", R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_USED = string.format("Refuerzo activado: el enemigo debe mantener %d s más.", R.BARRICADE_INCREASE)
    elseif Overlord.IsGermanLocale() then
        Loc.GOLD_FULL = string.format("Coin-Maximum erreicht (%d/%d).", R.GOLD_MAX, R.GOLD_MAX)
        Loc.GOLD_REINFORCE_TIP = string.format(
            "Kostet %d Coins. Eure nächste Zonen-, Hauptstadt-, Außenposten- oder Gildenfestungs-Eroberung endet %d s früher (Mindesthaltezeit: %d s).",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION, R.REINFORCE_MIN_HOLD)
        Loc.GOLD_REINFORCE_SPENT = string.format("%d Coins ausgegeben. Nächste Eroberung dauert %d s kürzer.",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_ACTIVE = string.format("Angriff bereit: Eure nächste Eroberung dauert %d s kürzer.", R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_USED = string.format("Angriff eingesetzt: Eroberungszeit um %d s verkürzt.", R.REINFORCE_REDUCTION)
        Loc.GOLD_BARRICADE_TIP = string.format(
            "Kostet %d Coins. Beim nächsten feindlichen Eroberungsstart auf einer Eurer Frontzonen muss der Feind %d s länger halten.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_SPENT = string.format("%d Coins ausgegeben. Nächste feindliche Eroberung auf Euren Zonen dauert %d s länger.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_ACTIVE = string.format("Verstärkung bereit: Nächste feindliche Eroberung auf Euren Zonen dauert %d s länger.", R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_USED = string.format("Verstärkung ausgelöst: Der Feind muss %d s länger halten.", R.BARRICADE_INCREASE)
    elseif Overlord.IsRussianLocale() then
        Loc.GOLD_FULL = string.format("Достигнут максимум coins (%d/%d).", R.GOLD_MAX, R.GOLD_MAX)
        Loc.GOLD_REINFORCE_TIP = string.format(
            "Стоимость: %d coins. Ваш следующий захват зоны, столицы, аванпоста или гильдейской крепости завершится на %d сек раньше (минимальное время удержания: %d сек).",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION, R.REINFORCE_MIN_HOLD)
        Loc.GOLD_REINFORCE_SPENT = string.format("Потрачено %d coins. Следующий захват займет на %d сек меньше времени.",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_ACTIVE = string.format("Атака готова: ваш следующий захват займет на %d сек меньше времени.", R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_USED = string.format("Атака использована: время захвата сокращено на %d сек.", R.REINFORCE_REDUCTION)
        Loc.GOLD_BARRICADE_TIP = string.format(
            "Стоимость: %d coins. При следующем начале вражеского захвата на одной из ваших фронтовых зон противнику придется удерживать её на %d сек дольше.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_SPENT = string.format("Потрачено %d coins. Следующий вражеский захват на ваших зонах займет на %d сек больше времени.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_ACTIVE = string.format("Усиление готово: следующий вражеский захват на ваших зонах займет на %d сек больше времени.", R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_USED = string.format("Усиление сработало: противник должен удерживать зону на %d сек дольше.", R.BARRICADE_INCREASE)
    elseif Overlord.IsPortugueseLocale() then
        Loc.GOLD_FULL = string.format("Limite de coins atingido (%d/%d).", R.GOLD_MAX, R.GOLD_MAX)
        Loc.GOLD_REINFORCE_TIP = string.format(
            "Custa %d coins. Sua próxima captura de ponto, capital, posto ou forte termina %d segundos antes (tempo mínimo: %d s).",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION, R.REINFORCE_MIN_HOLD)
        Loc.GOLD_REINFORCE_SPENT = string.format("%d coins gastos. Sua próxima captura será %d s mais curta.",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_ACTIVE = string.format("Ataque pronto: próxima captura %d s mais curta.", R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_USED = string.format("Ataque usado: captura reduzida em %d s.", R.REINFORCE_REDUCTION)
        Loc.GOLD_BARRICADE_TIP = string.format(
            "Custa %d coins. A próxima captura inimiga de um dos seus pontos exige mais %d segundos.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_SPENT = string.format("%d coins gastos. Próxima captura inimiga demora mais %d s.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_ACTIVE = string.format("Reforço pronto: próxima captura inimiga demora mais %d s.", R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_USED = string.format("Reforço ativado: o inimigo precisa segurar por mais %d s.", R.BARRICADE_INCREASE)
    elseif Overlord.IsChineseLocale() then
        Loc.GOLD_FULL = string.format("Coin 已达上限（%d/%d）。", R.GOLD_MAX, R.GOLD_MAX)
        Loc.GOLD_REINFORCE_TIP = string.format(
            "花费 %d coin。下次占领据点、首府、前哨或公会要塞时缩短 %d 秒（最短需 %d 秒）。",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION, R.REINFORCE_MIN_HOLD)
        Loc.GOLD_REINFORCE_SPENT = string.format("已花费 %d coin。下次占领缩短 %d 秒。",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_ACTIVE = string.format("进攻准备就绪：下次占领缩短 %d 秒。", R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_USED = string.format("进攻已生效：占领时间缩短 %d 秒。", R.REINFORCE_REDUCTION)
        Loc.GOLD_BARRICADE_TIP = string.format(
            "花费 %d coin。敌人下次占领你的一个战线据点时，需额外守住 %d 秒。",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_SPENT = string.format("已花费 %d coin。敌人下次占领需额外 %d 秒。",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_ACTIVE = string.format("增援准备就绪：敌人下次占领需额外 %d 秒。", R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_USED = string.format("增援已生效：敌人需额外守住 %d 秒。", R.BARRICADE_INCREASE)
    else
        Loc.GOLD_FULL = string.format("Coin cap reached (%d/%d).", R.GOLD_MAX, R.GOLD_MAX)
        Loc.GOLD_REINFORCE_TIP = string.format(
            "Costs %d coins. Your next zone, capital, outpost, or Guild Keep capture finishes %d seconds sooner (minimum hold time %d s).",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION, R.REINFORCE_MIN_HOLD)
        Loc.GOLD_REINFORCE_SPENT = string.format("%d coins spent. Next capture will be %d s shorter.",
            R.GOLD_SPEND_COST, R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_ACTIVE = string.format("Attack ready: your next capture will be %d s shorter.", R.REINFORCE_REDUCTION)
        Loc.GOLD_REINFORCE_USED = string.format("Attack used: capture time reduced by %d s.", R.REINFORCE_REDUCTION)
        Loc.GOLD_BARRICADE_TIP = string.format(
            "Costs %d coins. The next time an enemy starts capturing one of your front zones, they must hold %d seconds longer.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_SPENT = string.format("%d coins spent. Next enemy capture on your zones will take %d s longer.",
            R.GOLD_SPEND_COST, R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_ACTIVE = string.format("Reinforce ready: the next enemy capture on your zones will take %d s longer.", R.BARRICADE_INCREASE)
        Loc.GOLD_BARRICADE_USED = string.format("Reinforce triggered: enemy must hold %d s longer.", R.BARRICADE_INCREASE)
    end
end
