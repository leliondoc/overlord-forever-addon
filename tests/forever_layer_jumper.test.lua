-- 2.5.0: the layers of the players heard, and joining one. Two whole modules exchange the real
-- whispers: a request to one named player, an automatic invitation from a volunteer only, an
-- invitation accepted only from the player asked, the proof on our own layer, the group left.
-- Only the game's group, chat and clock are simulated.
local now = 1000
local timers = {}
local clients, byName = {}, {}
local sent = {}

local function advance(seconds)
    local target = now + seconds
    while true do
        table.sort(timers, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.id < b.id end)
        local t = timers[1]
        if not t or t.at > target then break end
        table.remove(timers, 1)
        now = t.at
        t.fn()
    end
    now = target
end
local timerId = 0
local function after(delay, fn)
    timerId = timerId + 1
    timers[#timers + 1] = { at = now + delay, fn = fn, id = timerId }
end

local function fire(client, event, ...)
    client.LJ:OnEvent(event, ...)
end

-- The game's group: a helper invites, the guest accepts, both are a party of two led by the helper.
local function formGroup(leader, guest)
    for _, c in ipairs({ leader, guest }) do
        c.grouped, c.groupSize = true, 2
    end
    leader.leader, guest.leader = true, false
    leader.party, guest.party = guest.name, leader.name
    fire(leader, "GROUP_JOINED"); fire(guest, "GROUP_JOINED")
    -- Out of combat the game moves the guest to the leader's layer a moment later.
    after(2, function()
        if guest.grouped and guest.party == leader.name then
            guest.shard.currentShardID, guest.shard.lastUpdateAt = leader.shard.currentShardID, now
        end
    end)
end
local function breakGroup(a)
    local other = a.party and byName[a.party]
    for _, c in ipairs({ a, other }) do
        if c then
            c.grouped, c.groupSize, c.leader, c.party = false, nil, false, nil
            fire(c, "GROUP_LEFT")
        end
    end
end

local function newClient(name, layer)
    local c = { name = name, grouped = false, combat = false, invites = {}, accepted = 0, left = 0, uninvited = {} }
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.GetTime = function() return now end
    env.time = function() return 1790016000 + math.floor(now) end
    env.strsplit = function(sep, value)
        local out, start = {}, 1
        while true do
            local i = value:find(sep, start, true)
            if not i then out[#out + 1] = value:sub(start); break end
            out[#out + 1] = value:sub(start, i - 1)
            start = i + 1
        end
        return unpack(out)
    end
    env.C_Timer = {
        After = after,
        NewTicker = function(interval, fn)
            local ticker = { cancelled = false }
            local function step()
                if ticker.cancelled then return end
                fn()
                after(interval, step)
            end
            after(interval, step)
            function ticker:Cancel() self.cancelled = true end
            return ticker
        end,
    }
    env.CreateFrame = nil -- no window in this test (the list is checked through BuildRows)
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        SendAddonMessage = function(prefix, msg, chatType, target)
            sent[#sent + 1] = { from = name, prefix = prefix, msg = msg, chatType = chatType, target = target, at = now }
            local to = byName[target]
            -- (An addon whisper never crosses factions.)
            if to and to.faction == c.faction then
                after(0.1, function() to.LJ:OnEvent("CHAT_MSG_ADDON", prefix, msg, chatType, name) end)
            end
            return 0
        end,
    }
    env.UnitName = function(unit)
        if unit == "player" then return name end
        if unit == "party1" then return c.party end
        return nil
    end
    env.UNKNOWNOBJECT = "Unknown"
    env.IsInInstance = function() return c.instance == true end
    env.InCombatLockdown = function() return c.combat end
    env.UnitAffectingCombat = function() return c.combat end
    env.IsInGroup = function() return c.grouped end
    env.IsInRaid = function() return false end
    env.GetNumGroupMembers = function() return c.grouped and (c.groupSize or 2) or 0 end
    env.UnitIsGroupLeader = function() return c.leader == true end
    env.GetMaxBattlefieldID = function() return 0 end
    env.GetBattlefieldStatus = function() return "none" end
    env.AcceptGroup = function()
        c.accepted = c.accepted + 1
        local inviter = c.pendingInviter and byName[c.pendingInviter]
        c.pendingInviter = nil
        if inviter then after(0.5, function() formGroup(inviter, c) end) end
    end
    env.C_PartyInfo = {
        InviteUnit = function(target)
            c.invites[#c.invites + 1] = target
            local to = byName[target]
            if to then
                after(0.3, function()
                    to.pendingInviter = name
                    fire(to, "PARTY_INVITE_REQUEST", name)
                end)
            end
        end,
        LeaveParty = function() c.left = c.left + 1; breakGroup(c) end,
        UninviteUnit = function(target) c.uninvited[#c.uninvited + 1] = target; breakGroup(c) end,
    }
    local notes = {}
    c.notes = notes
    c.shard = { knownShards = {}, peerTail = nil, currentShardID = layer, lastUpdateAt = now }
    function c.shard:GetCurrentShardID() return self.currentShardID end
    function c.shard:Update() return true end
    function c.shard:PartyInviteTargetIsUsable(sender) return sender:sub(1, 5) ~= "BNet-" end
    function c.shard:ResolveKnownShardPlayer(hint) return hint, self.knownShards[hint] end
    c.factions = {}
    env.Overlord = {
        L = { LJ_DECLINED_OFF = "%s does not help with layer changes.", LJ_STATUS_REQUESTING = "Asking %s for an invite...",
            LJ_STATUS_JOINING = "Joining %s's group...", LJ_STATUS_SUCCESS = "Done: you are now on %s." },
        PlayerFaction = "Alliance",
        Shard = c.shard,
        IsShardHelperActive = function() return c.readable ~= false end,
        PrintNotification = function(_, text) notes[#notes + 1] = text end,
        Sync = { GetLivePlayerFaction = function(_, who) return c.factions[who] end },
    }
    env.OverlordDB = { config = {} }
    c.env, c.faction = env, "Alliance"
    setfenv(assert(loadfile("LayerJumper.lua")), env)()
    c.LJ = env.Overlord.LayerJumper
    c.LJ:Initialize()
    clients[#clients + 1] = c
    byName[name] = c
    return c
end

-- Players a client knows the layer of (newest last, as Overlord.Shard links them).
local function know(c, rows)
    c.shard.knownShards, c.shard.peerTail = {}, nil
    local prev
    for _, row in ipairs(rows) do
        c.shard.knownShards[row[1]] = row[2]
        local node = { key = row[1], expiresAt = now + 180, prev = prev }
        prev = node
    end
    c.shard.peerTail = prev
end
local function whispers(from, pattern, to)
    local n = 0
    for _, row in ipairs(sent) do
        if row.from == from.name and row.prefix == "OverlordLJ" and row.chatType == "WHISPER"
            and (not pattern or row.msg:find(pattern)) and (not to or row.target == to.name) then
            n = n + 1
        end
    end
    return n
end

local ann, bob = newClient("Ann Requester", 1201), newClient("Bob Helper", 1305)
know(ann, { { "Bob Helper", 1305 } })

-- 1. Off by default: the player asked answers "off", invites nobody, and the requester is told.
assert(bob.LJ:GetHelpMode() == "off", "helping is off by default")
assert(ann.LJ:Join("Bob Helper", 1305), "the request did not start")
assert(whispers(ann, "^R:2:%w+:1201$", bob) == 1, "the request as written on the wire: " .. tostring(sent[1] and sent[1].msg))
advance(2)
assert(whispers(bob, "^N:%w+:off$", ann) == 1 and #bob.invites == 0, "a helper that is off must refuse and invite nobody")
assert(ann.LJ.state == "idle" and ann.notes[#ann.notes]:find("Bob Helper does not help", 1, true),
    "the requester was not told who refused: " .. tostring(ann.notes[#ann.notes]))

-- 2. A volunteer: invites by itself, the requester accepts only that invitation, changes layer,
--    then leaves the group; the pair is never a trusted group for the sync.
bob.LJ:SetHelpMode("auto")
advance(30)
assert(ann.LJ:Join("Bob Helper", 1305))
advance(0.2)
-- (An invitation from somebody else meanwhile is not accepted.)
ann.LJ:OnEvent("PARTY_INVITE_REQUEST", "Zed Stranger")
assert(ann.accepted == 0, "an invitation from another player was accepted")
advance(1)
assert(#bob.invites == 1 and bob.invites[1] == "Ann Requester", "the volunteer did not invite")
assert(ann.accepted == 1, "the invitation of the player asked was not accepted")
advance(1)
assert(ann.grouped and bob.grouped, "fixture: the group of two")
assert(ann.LJ:IsHopGroup() and bob.LJ:IsHopGroup(), "the group of a jump is not seen as one")
assert(ann.LJ:IsHopPartner("Bob Helper") and bob.LJ:IsHopPartner("Ann Requester"), "the partner of a jump earned group trust")
assert(ann.LJ.state == "verifying", "state after joining: " .. ann.LJ.state)
advance(6)
assert(ann.left == 1 and not ann.grouped and not bob.grouped, "the requester did not leave the group once moved")
assert(ann.LJ.state == "idle" and ann.shard.currentShardID == 1305, "the jump did not end on the helper's layer")
assert(ann.notes[#ann.notes]:find("#1305", 1, true), "the success line names the layer: " .. ann.notes[#ann.notes])
assert(#bob.uninvited == 0 and next(bob.LJ.guests) == nil, "the helper kept a guest")
advance(20)
assert(not ann.LJ:IsHopGroup() and not bob.LJ:IsHopGroup(), "a jump long over still counts as a hop group")
assert(not bob.LJ:IsHopPartner("Ann Requester"), "the partner stayed distrusted for good")

-- 3. Already there, or grouped: nothing is asked.
local before = #sent
know(ann, { { "Bob Helper", 1305 } })
assert(not ann.LJ:Join("Bob Helper", 1305) and #sent == before, "asked for the layer we are on")
ann.shard.currentShardID = 1201
ann.grouped = true
assert(not ann.LJ:Join("Bob Helper", 1305) and #sent == before, "asked while grouped")
ann.grouped = false

-- 4. The helper answers one request per requester every HELPER_PER_SENDER_GAP, and refuses with
--    its reason: in combat, already on the requester's layer, the same requester again too soon.
advance(700)
bob.combat = true
assert(ann.LJ:Join("Bob Helper", 1305))
advance(2)
assert(whispers(bob, "^N:%w+:combat$", ann) == 1 and #bob.invites == 1, "a helper in combat")
bob.combat = false
local refusals = whispers(bob, "^N:", ann)
advance(6)
assert(ann.LJ:Join("Bob Helper", 1305))
advance(14)
assert(whispers(bob, "^N:", ann) == refusals and #bob.invites == 1, "a second request within the gap was answered")
assert(ann.LJ.state == "idle", "an unanswered request did not time out: " .. ann.LJ.state)
advance(30)
ann.shard.currentShardID = 1305
bob.LJ:OnAddonMessage("OverlordLJ", "R:2:abc123:1305", "WHISPER", "Ann Requester")
advance(1)
assert(whispers(bob, "^N:abc123:same$", ann) == 1, "a requester already on our layer")
ann.shard.currentShardID = 1201
-- Malformed, another protocol, another chat type: nothing.
local quiet = #sent
bob.LJ:OnAddonMessage("OverlordLJ", "R:1:abc124:1201", "WHISPER", "Cal Other")
bob.LJ:OnAddonMessage("OverlordLJ", "R:2:abc 125:1201", "WHISPER", "Cal Other")
bob.LJ:OnAddonMessage("OverlordLJ", "R:2:abc126:1201", "GUILD", "Cal Other")
bob.LJ:OnAddonMessage("OverlordLJ", ("R:2:x:"):rep(40), "WHISPER", "Cal Other")
advance(2)
assert(#sent == quiet and #bob.invites == 1, "a malformed request was answered")

-- 5. A player of the other side is never asked: its layer is joined through a player of ours on it.
local cid = newClient("Cid Friend", 2000)
cid.LJ:SetHelpMode("auto")
ann.factions["Rob Enemy"] = "Horde"
advance(700)
know(ann, { { "Rob Enemy", 2000 }, { "Cid Friend", 2000 }, { "Dee Elsewhere", 3000 } })
assert(ann.LJ:Join("Rob Enemy", 2000), "the layer of an enemy capturer could not be asked for")
advance(8)
assert(whispers(ann, "^R:", { name = "Rob Enemy" }) == 0, "a player of the other side was whispered")
assert(#cid.invites == 1 and ann.shard.currentShardID == 2000, "the layer was not joined through our own player on it")
advance(30)
-- An enemy the game does not show but the ranking holds on the other side (the miner or the
-- capturer named in an alert): not asked either.
ann.env.Overlord.Leaderboard = { GetPlayerInfo = function(_, who)
    return who == "Sly Ranked" and { faction = "Horde" } or nil
end }
assert(ann.LJ:IsEnemy("Sly Ranked") and not ann.LJ:IsEnemy("Cid Friend") and not ann.LJ:IsEnemy("Never Seen"),
    "the side of a player read from the ranking")
ann.env.Overlord.Leaderboard = nil
-- Nobody of ours on that layer: said, nothing sent.
know(ann, { { "Rob Enemy", 4000 } })
quiet = #sent
assert(not ann.LJ:Join("Rob Enemy", 4000) and #sent == quiet, "asked with nobody to ask")

-- 6. The list: every known player, by layer then by name, ours last; bounded.
ann.shard.currentShardID = 1201
know(ann, { { "Zoe Late", 1305 }, { "Abe Early", 1305 }, { "Mia Same", 1201 }, { "Kim Far", 900 }, { "BNet-123", 900 } })
local rows, mine = ann.LJ:BuildRows()
assert(mine == 1201 and #rows == 4, "rows listed: " .. #rows)
assert(rows[1].name == "Kim Far" and rows[2].name == "Abe Early" and rows[3].name == "Zoe Late" and rows[4].name == "Mia Same"
    and rows[4].here == true, "order of the list: " .. rows[1].name .. ", " .. rows[2].name .. ", " .. rows[3].name .. ", " .. rows[4].name)
local many = {}
for i = 1, 700 do many[i] = { string.format("Name %03d", i), 5000 + i % 7 } end
know(ann, many)
assert(#ann.LJ:KnownPlayers() <= ann.LJ.LIST_MAX, "the list is not bounded")
-- An entry past its life is not listed.
know(ann, { { "Old One", 1305 } })
ann.shard.peerTail.expiresAt = now - 1
assert(#ann.LJ:KnownPlayers() == 0, "an expired layer was listed")

-- 7. The layer named in a chat alert: a link only where the game hands addon links to addons,
--    a left click asks that player, anything else does nothing.
assert(ann.LJ:ChatLink("Bob Helper", 1305, ", layer #1305") == nil, "a link without the game's link registry")
local dana = newClient("Dana Linker", 1201)
local registered
dana.env.EventRegistry = { RegisterCallback = function(_, event, fn, owner) registered = { event = event, fn = fn, owner = owner } end }
dana.LJ.initialized = nil
dana.LJ:Initialize()
assert(registered and registered.event == "SetItemRef", "the click of an addon link is not listened to")
local link = dana.LJ:ChatLink("Bob Helper", 1305, ", layer #1305")
assert(link == ", |cff71d5ff|Haddon:Overlord:layer:Bob Helper:1305|h[layer #1305]|h|r", "the link: " .. tostring(link))
assert(dana.LJ:ChatLink("Bad|Name", 1305, " layer #1") == nil and dana.LJ:ChatLink("Bob Helper", nil, " layer") == nil,
    "a link for a name or a layer that cannot be one")
-- An alert without a player of ours (a mine, a rampage): the link names nobody.
assert(dana.LJ:ChatLink(nil, 1305, ", layer #1305") == ", |cff71d5ff|Haddon:Overlord:layer::1305|h[layer #1305]|h|r",
    "the link of a layer without a player: " .. tostring(dana.LJ:ChatLink(nil, 1305, ", layer #1305")))
advance(700)
know(dana, { { "Bob Helper", 1305 } })
quiet = #sent
registered.fn(registered.owner, "addon:Overlord:layer:Bob Helper:1305", "[layer #1305]", "RightButton")
registered.fn(registered.owner, "addon:Other:layer:Bob Helper:1305", "x", "LeftButton")
registered.fn(registered.owner, "item:12345", "x", "LeftButton")
registered.fn(registered.owner, "addon:Overlord:layer:Bob Helper:notalayer", "x", "LeftButton")
assert(#sent == quiet, "a click that is not ours asked for a layer")
registered.fn(registered.owner, "addon:Overlord:layer:Bob Helper:1305", "[layer #1305]", "LeftButton")
assert(whispers(dana, "^R:2:%w+:1201$", bob) == 1, "a left click on the layer did not ask its player")
assert(dana.notes[#dana.notes] and dana.notes[#dana.notes]:find("Bob Helper", 1, true), "a click in the chat says nothing")
advance(10)
assert(dana.shard.currentShardID == 1305 and dana.left == 1, "the jump started from the chat did not complete")
-- A click on a link that names nobody asks a player of ours known on that layer.
do
    advance(700)
    local erin = newClient("Erin Linker", 1201)
    erin.env.EventRegistry = { RegisterCallback = function(_, event, fn, owner) registered = { event = event, fn = fn, owner = owner } end }
    erin.LJ.initialized = nil
    erin.LJ:Initialize()
    know(erin, { { "Bob Helper", 1305 } })
    quiet = #sent
    registered.fn(registered.owner, "addon:Overlord:layer::1201", "[layer #1201]", "LeftButton")
    assert(#sent == quiet, "asked for the layer we are on")
    registered.fn(registered.owner, "addon:Overlord:layer::1305", "[layer #1305]", "LeftButton")
    assert(whispers(erin, "^R:2:%w+:1201$", bob) == 1, "a click on a layer without a player asked nobody")
    advance(10)
    assert(erin.shard.currentShardID == 1305, "the jump to a layer without a named player did not complete")
end

-- 8. An instance: nothing is asked, nothing is answered, a jump under way is dropped without
--    touching the group.
advance(700)
ann.instance = true
quiet = #sent
assert(not ann.LJ:Join("Bob Helper", 1305) and #sent == quiet, "asked from an instance")
ann.instance = false
bob.instance = true
bob.env.Overlord.InstanceSuspended = true
bob.LJ:OnAddonMessage("OverlordLJ", "R:2:abc200:1201", "WHISPER", "Eve Asker")
assert(#sent == quiet, "answered from an instance")
bob.instance, bob.env.Overlord.InstanceSuspended = false, nil

-- 9. The wiring: the sync never trusts nor feeds the partner of a jump, the saved choice is no
--    longer wiped at login, the file is loaded, and every text exists in seven languages.
local function read(path) local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text end
local syncLua, relayLua, outpostLua = read("Sync.lua"), read("SyncRelay.lua"), read("SyncOutpost.lua")
assert(syncLua:find("if jumper and jumper%.IsHopPartner and jumper:IsHopPartner%(sender%) then return false end"),
    "SyncSenderIsInOurGroup trusts the partner of a jump")
local _, hopGuards = syncLua:gsub("Overlord%.LayerJumper:IsHopGroup%(%)", "")
assert(hopGuards >= 4, "Sync.lua: hop group guards: " .. hopGuards)
local _, relayGuards = relayLua:gsub("Overlord%.LayerJumper:IsHopGroup%(%)", "")
assert(relayGuards >= 3, "SyncRelay.lua: hop group guards: " .. relayGuards)
assert(outpostLua:find("return not %(jumper and jumper%.IsHopPartner%s+and jumper:IsHopPartner%(sender%)%)")
    or outpostLua:find("return not %(jumper and jumper%.IsHopPartner and jumper:IsHopPartner%(sender%)%)"),
    "the outposts trust the partner of a jump")
assert(read("General.lua"):find("if jumper and jumper%.IsHopGroup and jumper:IsHopGroup%(%) then return false end"),
    "the helper of a jump takes the command role")
local core = read("Core.lua")
assert(core:find("if OverlordDB%.layerHelpEra ~= 250 then%s+OverlordDB%.layerHelpEra = 250%s+OverlordDB%.layerJumperHop = nil"
    .. "%s+if type%(OverlordDB%.config%) == \"table\" then OverlordDB%.config%.layerHelpMode = nil end%s+end"),
    "the saved jump or helper choice is wiped at every login (once only, for a choice older than 2.5.0)")
local _, wipes = core:gsub("layerHelpMode = nil", "")
assert(wipes == 1, "the helper choice is wiped in " .. wipes .. " places")
-- A rampage reads the layer of a player as a number, never from the alert's tag (a link now).
local gka = read("GuildKillAlert.lua")
assert(gka:find("local ok, _, layer = pcall%(shard%.ResolveKnownShardPlayer, shard, playerName, true%)")
    and gka:find('tag = tag:gsub%("|c%%x%%x%%x%%x%%x%%x%%x%%x", ""%):gsub%("|H%.%-|h", ""%)'),
    "a rampage reads its layer from the alert's text, link and colour codes included")
assert(core:find("self%.LayerJumper%.OnInstanceSuspend"), "an instance does not stop the module")
assert(read("Overlord.toc"):find("\nLayerJumper%.lua\r?\n"), "the module is not loaded")
assert(read("Commands.lua"):find('cmd == "layer" or cmd == "layers"', 1, true), "/ov layer is missing")
local keys = { "LJ_HELP_OPTION_LABEL", "LJ_TITLE", "LJ_YOUR_LAYER", "LJ_LIST_EMPTY", "LJ_DECLINED_OFF", "LJ_CLICK_HINT", "LJ_HELP_MODE_TOOLTIP",
    "LJ_JOIN", "LJ_CANCEL", "LJ_HELP_MODE", "LJ_STATUS_REQUESTING", "LJ_STATUS_SUCCESS", "LJ_STATUS_FAILED", "LJ_ERR_GROUPED" }
local counts = {}
for _, path in ipairs({ "Locales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua" }) do
    local text = read(path)
    for _, key in ipairs(keys) do
        local _, n = text:gsub("\nL%." .. key .. " = \"[^\"\n]+\"", "")
        counts[key] = (counts[key] or 0) + n
    end
end
for _, key in ipairs(keys) do assert(counts[key] == 7, key .. " in seven languages: " .. tostring(counts[key])) end
-- The volunteer's choice also sits in the options, off by default, the same setting.
local panel = read("SettingsPanel.lua"):match('var = "Overlord_LayerHelp".-end },')
assert(panel and panel:find("default = false", 1, true) and panel:find('cfg.layerHelpMode == "auto"', 1, true)
    and panel:find('OverlordDB.config.layerHelpMode = value == true and "auto" or "off"', 1, true)
    and panel:find('tooltip = "LJ_HELP_MODE_TOOLTIP"', 1, true), "the options row of the volunteer's choice")
-- The alerts of keeps and outposts name the capturer and its layer when both are known.
local _, tails = outpostLua:gsub("%.%. OutpostCapturerTail%(stAfter%)", "")
assert(tails >= 6, "outpost alerts carrying the capturer's layer: " .. tails)
print("Layer jumper: request to one player, volunteers only, invitation of the player asked, proof, group left, "
    .. "other side never asked, list, chat link, instance, wiring OK")
