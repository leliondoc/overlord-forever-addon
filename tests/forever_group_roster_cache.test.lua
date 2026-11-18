-- 2.6.0: the group's member list (Sync.lua GetGroupMemberNames) is kept 10 s instead of 2: it
-- changes on GROUP_ROSTER_UPDATE (OnGroupChanged resets it), another group size rebuilds it at
-- once, and a member whose name is not readable yet is read again 2 s later.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local s = Overlord.Sync
local clock = 5000
function GetTime() return clock end
local roster = { "Mate One", "Mate Two", "Mate Three" }
function IsInGroup() return true end
function IsInRaid() return false end
function GetNumGroupMembers() return #roster + 1 end
function UnitExists(unit)
    local index = tonumber(tostring(unit):match("^party(%d+)$"))
    return index ~= nil and roster[index] ~= nil
end
function UnitFactionGroup() return "Alliance" end
local realName = Overlord.SafeGetUnitName
Overlord.SafeGetUnitName = function(self, unit, withRealm)
    local index = tonumber(tostring(unit):match("^party(%d+)$"))
    if index then
        local name = roster[index]
        if name == false then return nil end
        return name
    end
    return realName(self, unit, withRealm)
end
s:OnGroupChanged()

assert(s:SenderIsInOurGroup("Mate Two"), "fixture: a member of the group was not seen")
-- Renamed with no event (a stub): the list is kept 10 s.
roster[2] = "Mate Renamed"
clock = clock + 3
assert(s:SenderIsInOurGroup("Mate Two") and not s:SenderIsInOurGroup("Mate Renamed"),
    "the group's list was rebuilt within 10 s with no change of size")
clock = clock + 8
assert(s:SenderIsInOurGroup("Mate Renamed") and not s:SenderIsInOurGroup("Mate Two"),
    "the group's list outlived 10 s")
-- GROUP_ROSTER_UPDATE: seen at once.
roster[2] = "Mate Two"
s:OnGroupChanged()
assert(s:SenderIsInOurGroup("Mate Two"), "a roster event did not rebuild the list")
-- Another size (an event missed): seen at once.
roster[4] = "Mate Four"
assert(s:SenderIsInOurGroup("Mate Four"), "a new member was not seen at once (group size changed)")
-- A name not readable yet (after a loading screen): read again 2 s later.
roster[3] = false
s:OnGroupChanged()
assert(not s:SenderIsInOurGroup("Mate Three"), "fixture: an unreadable name was listed")
roster[3] = "Mate Three"
clock = clock + 2.5
assert(s:SenderIsInOurGroup("Mate Three"), "an unreadable member was not read again 2 s later")
assert(s:GetGroupMemberFaction("Mate Three") == "Alliance", "the member's faction was not kept")
-- Out of an instance (roster events unheard there): a group of the same size is read again.
assert(s:SenderIsInOurGroup("Mate One"), "fixture: the list before the instance")
roster[1] = "Mate Swapped"
clock = clock + 1
pcall(s.Resume, s)
assert(s:SenderIsInOurGroup("Mate Swapped") and not s:SenderIsInOurGroup("Mate One"),
    "the group's list outlived the way out of an instance")
Overlord.SafeGetUnitName = realName

print("Group roster cache: 10 s, rebuilt on a roster event, a size change or an unreadable name")
