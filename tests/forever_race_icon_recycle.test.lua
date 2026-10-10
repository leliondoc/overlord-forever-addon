-- Ranking rows are recycled while scrolling: one texture shows a Classic sheet race
-- (a crop of the character-creation sheet), then a race the sheet does not have
-- (Skyborne: a Blizzard atlas). The crop survived on the texture and the atlas was
-- drawn through it: a magnified corner of the portrait (a flat blue disc) instead of
-- the face. Overlord.UI.SetRaceIcon / SetClassicRaceIcon (UIShared.lua).
function CreateFrame() return {} end
C_Texture = { GetAtlasInfo = function(atlas) return atlas == "raceicon-skyborne-male" and {} or nil end }
Overlord = { Sync = { NormalizeRaceFileToken = function(_, race) return race end } }
assert(loadfile("UIShared.lua"))()

-- A texture as the client draws it: a crop set with SetTexCoord stays on the texture
-- and an atlas is drawn inside it.
local function newTexture()
    local texture = { coords = { 0, 1, 0, 1 }, shown = false }
    function texture:SetTexture(file) self.file = file end
    function texture:SetAtlas(atlas)
        self.atlas = atlas
        if atlas ~= nil then self.file = nil; self.fullAtAtlas = self:Full() end
    end
    function texture:SetTexCoord(l, r, t, b) self.coords = { l, r, t, b } end
    function texture:SetVertexColor() end
    function texture:Show() self.shown = true end
    function texture:Hide() self.shown = false end
    function texture:Full()
        return self.coords[1] == 0 and self.coords[2] == 1 and self.coords[3] == 0 and self.coords[4] == 1
    end
    return texture
end

-- 1. First paint of a Skyborne on a fresh texture: the whole atlas region.
local texture = newTexture()
assert(Overlord.UI.SetRaceIcon(texture, "Skyborne", 2), "a Skyborne portrait was not shown")
assert(texture.atlas == "raceicon-skyborne-male" and texture:Full() and texture.shown)

-- 2. The row scrolls to a Classic sheet race: the sheet, cropped, and no atlas left.
assert(Overlord.UI.SetClassicRaceIcon(texture, "NightElf-male"), "a Classic sheet race was not shown")
assert(texture.file and texture.atlas == nil and not texture:Full(), "the Classic sheet icon is not a crop of its sheet")

-- 3. The row scrolls back to the Skyborne: the crop must not stay on the atlas.
assert(Overlord.UI.SetRaceIcon(texture, "Skyborne", 2))
assert(texture.atlas == "raceicon-skyborne-male" and texture.file == nil, "the atlas was not set back")
assert(texture:Full(), "a recycled row kept the Classic crop on an atlas portrait")
-- Before the atlas, not after: a client that writes the region's own coordinates in
-- SetAtlas would show the whole sheet if they were reset afterwards.
assert(texture.fullAtAtlas, "the crop was still on the texture when the atlas was set")

-- 4. An unknown race hides the texture, and the next Classic race shows again.
assert(not Overlord.UI.SetRaceIcon(texture, "Naga", 2) and not texture.shown, "an unknown race stayed visible")
assert(Overlord.UI.SetClassicRaceIcon(texture, "Orc-female") and texture.shown and not texture:Full())
print("Race icon recycle: an atlas portrait is whole after a Classic sheet icon on the same texture")
