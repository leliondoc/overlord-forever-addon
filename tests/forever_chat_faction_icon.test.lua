-- Chat alerts start with the faction crest (domination bar logos). The texture
-- path must keep its backslashes: "InterfaceTimer" would draw nothing in game.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local BS = string.char(92)
local function crest(faction)
    return "|TInterface" .. BS .. "Timer" .. BS .. faction .. "-Logo:18:18|t "
end
assert(Overlord:FactionChatIcon("Horde") == crest("Horde"),
    "Horde crest path wrong: " .. Overlord:FactionChatIcon("Horde"))
assert(Overlord:FactionChatIcon("Alliance") == crest("Alliance"))
assert(Overlord:FactionChatIcon(nil) == "" and Overlord:FactionChatIcon("Neutral") == "")
Overlord.PlayerFaction = "Alliance"
assert(Overlord:EnemyFactionChatIcon() == crest("Horde"), "enemy crest not Horde for Alliance")
print("Chat faction crest: exact texture paths")
