-- 1.7.8 memory: one memo for IsForeverCharacterName, HasForeverNameCase and
-- CanonicalForeverName (three independent results packed per name). Every result,
-- in every call order and across a memo reset, equals the uncached computation.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local sync = Overlord.Sync

local names = {
    "Prenom Nom", "Kaín Peraxxis", "Thrall Doomhammer", "Prenom Nom-Royaume", " Prenom  Nom ",
    "Prenom Nom-", "Vol\226\128\153jin Sombrelance", "EMPIRE SUCKS", "eMPIRE Hacks", "Single",
    "Ab Cd Ef", "", string.rep("a", 81) .. " B", "Asm\208\190n Gold", "Zoë Dupré", "O'Neil Brave",
    "Name\0Null", "A B", "Prenom Nom-Royaume-Autre", "Ελένη Παππάς", "Иван Петров", "Nom|cff Bad",
}

-- Uncached reference results (computed with an empty memo before each call).
local function fresh(fn, name)
    sync._nameMemo = nil
    return fn(sync, name)
end
local expected = {}
for i, name in ipairs(names) do
    expected[i] = {
        fresh(sync.IsForeverCharacterName, name),
        fresh(sync.HasForeverNameCase, name),
        fresh(sync.CanonicalForeverName, name),
    }
end

local orders = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }
local fns = { sync.IsForeverCharacterName, sync.HasForeverNameCase, sync.CanonicalForeverName }
for _, order in ipairs(orders) do
    sync._nameMemo = nil
    for pass = 1, 2 do -- second pass reads the memo
        for i, name in ipairs(names) do
            for _, which in ipairs(order) do
                local got = fns[which](sync, name)
                assert(got == expected[i][which], ("memo result differs: fn %d, %q, pass %d: %s vs %s"):format(
                    which, name, pass, tostring(got), tostring(expected[i][which])))
            end
        end
    end
end

-- One slot per name for the three functions.
sync._nameMemo = nil
for _, name in ipairs(names) do
    sync:IsForeverCharacterName(name); sync:HasForeverNameCase(name); sync:CanonicalForeverName(name)
end
local memo = assert(sync._nameMemo, "no memo")
local slots = 0
for _ in pairs(memo.values) do slots = slots + 1 end
assert(slots <= #names + 8, "names took " .. slots .. " slots for " .. #names .. " names")

-- At the limit: a NEW name starts a fresh memo, an update of a known name never does,
-- and results stay exact on both sides of the reset.
memo.n = 32767
local before = memo
assert(sync:HasForeverNameCase("Prenom Nom") == expected[1][2])
assert(sync._nameMemo == before, "an update of a known name reset the memo")
assert(sync:IsForeverCharacterName("Brand Newname") == true)
assert(sync._nameMemo == before and before.n == 32768, "fixture: the last free slot was not used")
assert(sync:CanonicalForeverName("Another Newname") == "Another Newname")
assert(sync._nameMemo ~= before, "a new name past the limit did not start a fresh memo")
for i, name in ipairs(names) do
    for which = 1, 3 do
        assert(fns[which](sync, name) == expected[i][which], "result lost across the memo reset: " .. name)
    end
end
-- A canonical form different from the name survives as a string.
sync._nameMemo = nil
local canon = sync:CanonicalForeverName("Prenom Nom-Royaume")
assert(canon == expected[4][3] and sync:CanonicalForeverName("Prenom Nom-Royaume") == canon,
    "a canonical form other than the name was not kept")

print("Forever name memo: one slot per name, exact in every order and across a reset OK")
