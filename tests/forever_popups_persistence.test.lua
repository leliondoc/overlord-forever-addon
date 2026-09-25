-- Automatic announcements need a loaded save to distinguish unseen from lost state.
Overlord = {
    L = {},
    IsInitialized = true,
    InstanceSuspended = false,
    SavedVariablesLoadedAtLogin = false,
    UI = { COMMUNITY_JOIN_AVAILABLE = false },
}
OverlordDB = { config = { popupsSeen = {}, popupsDailyShown = {} } }
time = os.time
date = os.date
assert(loadfile("Popups.lua"))()

local popups = Overlord.Popups
assert(popups:TryShowNextLoginAnnouncement() == false, "Welcome popup returned with an unloaded save")
assert(popups:TryShowNextDailyAnnouncement() == false, "Daily popup returned with an unloaded save")
assert(popups:TryShowFeaturedFrontOnLogin() == false, "Featured front returned with an unloaded save")
assert(popups:TryShowGuildKeepSiegeReminder() == false, "Siege reminder returned with an unloaded save")

-- A valid saved table still permits unseen announcements.
Overlord.SavedVariablesLoadedAtLogin = true
OverlordDB.config.popupsSeen.welcome_first_install = true
OverlordDB.config.popupsSeen.forever_launch_1_0_0 = true
local shown = {}
popups.ShowDialog = function(self, id, title, body, _, opts)
    shown[#shown + 1] = { id = id, title = title, body = body, opts = opts }
    self:MarkSeen(id)
end
Overlord.L.FOREVER_NETWORK_NOTICE_TITLE = "Please read this"
Overlord.L.FOREVER_NETWORK_NOTICE_BODY = "Communities and Battle.net are temporarily unavailable."
assert(popups:TryShowNextLoginAnnouncement() == true, "Network warning was not prioritized")
assert(shown[1].id == "forever_community_bnet_notice_1_0_17"
    and shown[1].opts.showWarningIcon == true, "Warning missed its yellow alert presentation")
assert(popups:HasSeen(shown[1].id), "Network notice was not marked seen")
assert(popups:TryShowNextLoginAnnouncement() == false, "Network notice repeated after being seen")

popups:RegisterLoginAnnouncement({ id = "fixture_once", title = "Once", body = "Body" })
assert(popups:TryShowNextLoginAnnouncement() == true, "Saved one-shot announcement was suppressed")
assert(shown[2].id == "fixture_once")

popups:RegisterLoginAnnouncement({ id = "fixture_daily", daily = true, title = "Daily", body = "Body" })
assert(popups:TryShowNextDailyAnnouncement() == true, "Saved daily announcement was suppressed")
assert(shown[3].id == "fixture_daily")

print("Forever popups: unloaded saves suppress automatic repeats; loaded saves still announce")
