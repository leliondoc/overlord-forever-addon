-- Local presentation only: never reads authoritative scores or calls the network.
Overlord = Overlord or {}
Overlord.LeaderboardSearch = {}
local Search = Overlord.LeaderboardSearch
local EMPTY = {}
local FIELDS = { "sortedKills", "sortedGuilds", "sortedGuildKeeps", "sortedOutposts" }
local MAX_ROWS_PER_SLICE, SLICE_MS = 256, 0.4

-- Lua 5.1 lowercases ASCII only for UTF-8 strings. Fold the two-byte letters
-- used by player/guild names without changing accents or stored identities.
-- The common ASCII query path below never calls this per entry.
local function FoldName(text)
    local value = tostring(text or "")
    if not string.find(value, "[\128-\255]") then return string.lower(value) end
    -- Some Lua/C locales lowercase individual UTF-8 bytes into invalid text.
    -- Fold only explicit ASCII letters before the UTF-8 pairs below.
    local lowered = string.gsub(value, "[A-Z]", string.lower)
    return (string.gsub(lowered, "[\194-\223][\128-\191]", function(pair)
        local lead, tail = string.byte(pair, 1, 2)
        if lead == 195 and ((tail >= 128 and tail <= 150) or (tail >= 152 and tail <= 158)) then
            return string.char(195, tail + 32) -- À-Ö and Ø-Þ
        end
        if lead == 208 then
            if tail >= 128 and tail <= 143 then return string.char(209, tail + 16) end -- Ѐ-Џ
            if tail >= 144 and tail <= 159 then return string.char(208, tail + 32) end -- А-П
            if tail >= 160 and tail <= 175 then return string.char(209, tail - 32) end -- Р-Я
        end
        if pair == "\197\184" then return "\195\191" end -- Ÿ -> ÿ
        if pair == "\197\146" then return "\197\147" end -- Œ -> œ
        if pair == "\210\144" then return "\210\145" end -- Ґ -> ґ
        return pair
    end))
end

function Search:Normalize(text)
    return (FoldName(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sameSource(a, b)
    if not a or not b then return false end
    for _, field in ipairs(FIELDS) do
        if a[field] ~= b[field] then return false end
    end
    return a.byFaction == b.byFaction and a.meta == b.meta and a.locale == b.locale
        and a.duplicateShortNames == b.duplicateShortNames
end

function Search:New(isVisible, publish)
    return setmetatable({ isVisible = isVisible, publish = publish }, { __index = self })
end

function Search:Cancel()
    if self.timer then self.timer:Cancel(); self.timer = nil end
    self.job = nil
end

-- Returns a cached result immediately, otherwise publishes one atomic view later.
-- Only one cancellable timer exists, including during rapid typing or sync bursts.
function Search:Request(source, text, delay)
    local query = self:Normalize(text)
    if query == "" then
        self:Cancel()
        self.result, self.source, self.query = nil, nil, nil
        return source
    end
    if self.query == query and sameSource(self.source, source) then
        self:Cancel()
        return self.result
    end
    if self.job and self.job.query == query and sameSource(self.job.source, source) then return end
    self:Cancel()
    if not self.isVisible() then return end
    -- Snapshot references: Refresh reuses its source-view table, but lists are immutable.
    local snapshot = {}
    for key, value in pairs(source) do snapshot[key] = value end
    local result = { byFaction = {}, ranks = {}, meta = source.meta,
        locale = source.locale, duplicateShortNames = source.duplicateShortNames }
    local lists = {}
    for _, field in ipairs(FIELDS) do
        result[field], result.ranks[field] = {}, {}
        lists[#lists + 1] = { source[field] or EMPTY, result[field], result.ranks[field],
            field == "sortedKills" and "name" or "guild" }
    end
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        result.byFaction[faction], result.ranks[faction] = {}, {}
        lists[#lists + 1] = { (source.byFaction or EMPTY)[faction] or EMPTY,
            result.byFaction[faction], result.ranks[faction], "name" }
    end
    local job = { source = snapshot, query = query, list = 1, row = 1,
        unicode = string.find(query, "[\128-\255]") ~= nil }
    self.job = job
    local function step()
        self.timer = nil
        if self.job ~= job or not self.isVisible() then self:Cancel(); return end
        local started = debugprofilestop and debugprofilestop()
        local visited = 0
        while job.list <= #lists and visited < MAX_ROWS_PER_SLICE do
            local list = lists[job.list]
            local entry = list[1][job.row]
            if not entry then
                job.list, job.row = job.list + 1, 1
            else
                -- Literal substring: %, [, etc. are never Lua patterns.
                local name = tostring(entry[list[4]] or "")
                local haystack = job.unicode and FoldName(name) or string.lower(name)
                if string.find(haystack, query, 1, true) then
                    local index = #list[2] + 1
                    list[2][index], list[3][index] = entry, job.row
                end
                job.row, visited = job.row + 1, visited + 1
                if started and visited % 32 == 0 and debugprofilestop() - started >= SLICE_MS then break end
            end
        end
        if job.list <= #lists then
            self.timer = C_Timer.NewTimer(0.01, step)
        else
            self.job = nil
            self.source, self.query, self.result = snapshot, query, result
            self.publish(result)
        end
    end
    self.timer = C_Timer.NewTimer(delay or 0.18, step)
end
