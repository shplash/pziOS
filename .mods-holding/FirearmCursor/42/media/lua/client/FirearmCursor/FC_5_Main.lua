--[[
    Firearm Cursor - event wiring.
--]]

FirearmCursor = FirearmCursor or {}

local function onGameStart()
    -- Re-read the player's current settings for this session, then override.
    FirearmCursor.originalOptions = nil
    FirearmCursor.originalDamageChance = nil

    FirearmCursor.createMarker()
    if FirearmCursor.marker ~= nil and FirearmCursor.marker.setVisible ~= nil then
        FirearmCursor.marker:setVisible(true)
    end

    FirearmCursor.applyVanillaUI()
    FirearmCursor.applySandboxOverrides()
end

local function onGameStop()
    FirearmCursor.restoreVanillaUI()
    FirearmCursor.restoreSandboxOverrides()

    local marker = FirearmCursor.marker
    if marker ~= nil then
        if marker.removeFromUIManager ~= nil then
            marker:removeFromUIManager()
        end
        FirearmCursor.marker = nil
    end
end

Events.OnGameStart.Add(onGameStart)
Events.OnGameStop.Add(onGameStop)

print("[FirearmCursor] loaded - vanilla firearm crosshair replaced by the isometric cursor.")
