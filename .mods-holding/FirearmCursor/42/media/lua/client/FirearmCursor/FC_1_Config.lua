--[[
    Firearm Cursor - configuration and small shared helpers.

    Everything in this mod is visual. Nothing here changes accuracy,
    targeting, damage or any weapon behaviour.
--]]

FirearmCursor = FirearmCursor or {}

-- Weapon hit-chance bands (the value comes from HandWeapon:getHitChance(),
-- which is the game's own hit-chance value for the equipped firearm).
FirearmCursor.GOOD_THRESHOLD = 65
FirearmCursor.MID_THRESHOLD = 35

-- Marker geometry, in pixels.
FirearmCursor.MARKER_SIZE = 26
FirearmCursor.MARKER_THICKNESS = 2
FirearmCursor.MARKER_DOT_SIZE = 4

-- Colours: { r, g, b } in 0..1.
FirearmCursor.COLOR_GOOD = { r = 0.18, g = 0.85, b = 0.25 }
FirearmCursor.COLOR_MID = { r = 1.00, g = 0.62, b = 0.10 }
FirearmCursor.COLOR_BAD = { r = 0.95, g = 0.20, b = 0.18 }

--- Read one of this mod's sandbox options.
-- SandboxVars may be missing in some menu states, so never assume it exists.
function FirearmCursor.getSandboxBoolean(key, fallback)
    local page = nil
    if SandboxVars ~= nil then
        page = SandboxVars.FirearmCursor
    end
    if page ~= nil and page[key] ~= nil then
        return page[key] == true
    end
    return fallback
end

--- Colour table for a hit-chance band.
function FirearmCursor.getColorForBand(band)
    if band == "good" then return FirearmCursor.COLOR_GOOD end
    if band == "mid" then return FirearmCursor.COLOR_MID end
    return FirearmCursor.COLOR_BAD
end
