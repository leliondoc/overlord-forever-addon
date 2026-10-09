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
assert(popups.TryShowGuildKeepSiegeReminder == nil, "Retired siege reminder is still installed")

-- A valid saved table still permits unseen announcements.
Overlord.SavedVariablesLoadedAtLogin = true
OverlordDB.config.popupsSeen.welcome_first_install = true
OverlordDB.config.popupsSeen.forever_launch_1_0_0 = true
local shown = {}
popups.ShowDialog = function(self, id, title, body, _, opts)
    shown[#shown + 1] = { id = id, title = title, body = body, opts = opts }
    self:MarkSeen(id)
end
-- The 1.0.17 "communities and Battle.net unavailable" warning is retired:
-- Battle.net bridges carry the other faction's data since 1.3.
assert(popups:TryShowNextLoginAnnouncement() == false, "A retired announcement is still registered")

popups:RegisterLoginAnnouncement({ id = "fixture_once", title = "Once", body = "Body" })
assert(popups:TryShowNextLoginAnnouncement() == true, "Saved one-shot announcement was suppressed")
assert(shown[1].id == "fixture_once")

popups:RegisterLoginAnnouncement({ id = "fixture_daily", daily = true, title = "Daily", body = "Body" })
assert(popups:TryShowNextDailyAnnouncement() == true, "Saved daily announcement was suppressed")
assert(shown[2].id == "fixture_daily")

print("Forever popups: unloaded saves suppress automatic repeats; loaded saves still announce")
