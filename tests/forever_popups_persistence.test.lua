-- Automatic announcements need a loaded save to distinguish unseen from lost state.
Overlord = {
    L = {},
    IsInitialized = true,
    InstanceSuspended = false,
    SavedVariablesLoadedAtLogin = false,
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
popups.ShowDialog = function(_, id) shown[#shown + 1] = id end
popups:RegisterLoginAnnouncement({ id = "fixture_once", title = "Once", body = "Body" })
assert(popups:TryShowNextLoginAnnouncement() == true, "Saved one-shot announcement was suppressed")
assert(shown[1] == "fixture_once")

popups:RegisterLoginAnnouncement({ id = "fixture_daily", daily = true, title = "Daily", body = "Body" })
assert(popups:TryShowNextDailyAnnouncement() == true, "Saved daily announcement was suppressed")
assert(shown[2] == "fixture_daily")

print("Forever popups: unloaded saves suppress automatic repeats; loaded saves still announce")
