--[[
    Firearm Cursor - hit-chance lookup.

    The value used here is HandWeapon:getHitChance(), i.e. the firearm's own
    hit-chance value as defined by the game. No custom accuracy formula is
    applied: this module only reads game data and sorts it into buckets so the
    cursor can be coloured.
--]]

FirearmCursor = FirearmCursor or {}

local function isAimedFirearm(item)
    if item == nil then return false end
    if type(instanceof) ~= "function" then return false end

    local ok, isWeapon = pcall(function() return instanceof(item, "HandWeapon") end)
    if not ok or not isWeapon then return false end

    local ok2, aimed = pcall(function() return item:isAimedFirearm() end)
    return ok2 and aimed == true
end

--- The firearm the player is currently holding, or nil for melee / fists.
function FirearmCursor.getFirearmInHands(player)
    if player == nil then return nil end

    local primary = player:getPrimaryHandItem()
    if isAimedFirearm(primary) then return primary end

    local secondary = player:getSecondaryHandItem()
    if isAimedFirearm(secondary) then return secondary end

    return nil
end

--- The game's hit-chance value for the held firearm (0..100), or nil.
function FirearmCursor.getHitChancePercent(player)
    local weapon = FirearmCursor.getFirearmInHands(player)
    if weapon == nil then return nil end

    local ok, chance = pcall(function() return weapon:getHitChance() end)
    if not ok or type(chance) ~= "number" then return nil end

    return chance
end

--- "good" / "mid" / "bad" for a hit-chance value.
function FirearmCursor.getBand(chance)
    if chance == nil then return nil end
    if chance >= FirearmCursor.GOOD_THRESHOLD then return "good" end
    if chance >= FirearmCursor.MID_THRESHOLD then return "mid" end
    return "bad"
end
