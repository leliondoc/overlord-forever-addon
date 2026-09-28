-- SR answers used to carry an OP for every strategic site, including neutral sites
-- that never changed state (the five fortresses after the 1.1.4 migration). Those
-- packets carry no information and were a large share of the OP losses.
assert(loadfile("tests/forever_fortress_outpost.test.lua"))()
local op, sync = Overlord.Outpost, Overlord.Sync
local function sitesIn(queue)
    local found = {}
    for _, item in ipairs(queue) do
        assert(item.type == "OP", "Unexpected " .. tostring(item.type) .. " in outpost SR block")
        found[item.data:match("^v%d+:([^:]+):")] = item.data:match("^v%d+:[^:]+:([^:]+):")
    end
    return found
end
-- Reset every site to a known state: all never touched ...
for key in pairs(Overlord.OutpostSites) do
    local st = op:GetState(key)
    st.status, st.ownerGuild, st.ownerFaction = "neutral", "", nil
    st.updatedAt, st.claimedAt, st.holdTimeElapsed, st.expiresAt = 0, 0, 0, 0
end
-- ... except one abandoned (neutral again, dated) and one held.
local abandoned, held = "silverpine", "badlands"
op:GetState(abandoned).updatedAt = 1790017000
local hs = op:GetState(held)
hs.status, hs.ownerGuild, hs.ownerFaction = "held", "Keep Guild", "Alliance"
hs.claimedAt, hs.updatedAt = 1790017500, 1790017500

for _, minimal in ipairs({ true, false }) do
    local queue = {}
    sync:AppendOutpostToSrQueue(queue, minimal)
    local found = sitesIn(queue)
    assert(found[abandoned] == "neutral", "A site that became neutral again was not sent (minimal=" .. tostring(minimal) .. ")")
    assert(found[held] == "held", "A held site was not sent (minimal=" .. tostring(minimal) .. ")")
    for key, status in pairs(found) do
        assert(key == abandoned or key == held,
            "Never-touched neutral site " .. key .. " (" .. status .. ") still sent (minimal=" .. tostring(minimal) .. ")")
    end
end
print("Outpost SR replies: never-touched neutral sites skipped, dated neutral and held sites kept")
