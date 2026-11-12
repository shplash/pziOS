--[[
    Firearm Cursor - the coloured target marker.

    The marker is drawn at the square the game says the player is aiming at
    (IsoGameCharacter:getAttackTargetSquare()), so it follows mouse aiming and
    controller aiming alike. It is drawn directly on the screen through an
    overlay ISUIElement, so it sits above the world and does not touch any game
    object.

    The vanilla isometric cursor itself is shown by the vanilla option
    "Show Cursor While Aiming" (see FC_4_GameSettings.lua); this overlay only adds
    the coloured feedback on top of it.

    The ISUIElement subclass is built lazily (in createMarker) because mod files
    are loaded in path order and ISUIElement may not be defined yet when this
    file is read.
--]]

FirearmCursor = FirearmCursor or {}

FirearmCursor.markerClass = nil

local function buildMarkerClass()
    local Marker = ISUIElement:derive("FirearmCursorMarker")

    function Marker:new()
        local o = ISUIElement:new(0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
        setmetatable(o, self)
        self.__index = self

        if o.setWantMouseEvents ~= nil then
            o:setWantMouseEvents(false)
        end
        if o.setAlwaysOnTop ~= nil then
            o:setAlwaysOnTop(true)
        end

        return o
    end

    function Marker:onResolutionChange()
        self:setWidth(getCore():getScreenWidth())
        self:setHeight(getCore():getScreenHeight())
    end

    -- Some builds use the other spelling.
    Marker.onResolutionChanged = Marker.onResolutionChange

    --- Only draw while a firearm is actually being aimed.
    function Marker:render()
        local player = getPlayer()
        if player == nil then return end

        local okAim, aimingFirearm = pcall(function() return player:isAimingFirearmEquipped() end)
        if not okAim or aimingFirearm ~= true then return end

        local okAiming, aiming = pcall(function() return player:isAiming() end)
        if not okAiming or aiming ~= true then return end

        if not FirearmCursor.getSandboxBoolean("ShowTargetMarker", true) then return end

        local square = nil
        local okSquare, sq = pcall(function() return player:getAttackTargetSquare() end)
        if okSquare then square = sq end
        if square == nil then return end

        -- Don't draw on the player's own square: in aiming mode the engine can
        -- report the tile you're standing on, which looks like a stray marker
        -- at your feet.
        local here = nil
        local okHere, hereSquare = pcall(function() return player:getCurrentSquare() end)
        if okHere then here = hereSquare end

        if here ~= nil
            and square:getX() == here:getX()
            and square:getY() == here:getY()
            and square:getZ() == here:getZ() then
            return
        end

        local chance = FirearmCursor.getHitChancePercent(player)
        local band = FirearmCursor.getBand(chance)
        if band == nil then return end

        if type(isoToScreenX) ~= "function" or type(isoToScreenY) ~= "function" then return end

        -- Centre of the target square rather than its top corner.
        local wx = square:getX() + 0.5
        local wy = square:getY() + 0.5
        local wz = square:getZ()

        local okX, screenX = pcall(function() return isoToScreenX(0, wx, wy, wz) end)
        local okY, screenY = pcall(function() return isoToScreenY(0, wx, wy, wz) end)
        if not okX or not okY or screenX == nil or screenY == nil then return end

        local col = FirearmCursor.getColorForBand(band)

        local size = FirearmCursor.MARKER_SIZE
        local thickness = FirearmCursor.MARKER_THICKNESS
        local dot = FirearmCursor.MARKER_DOT_SIZE

        local left = screenX - size / 2
        local top = screenY - size / 2

        -- Square outline.
        self:drawRect(left, top, size, thickness, 0.90, col.r, col.g, col.b)
        self:drawRect(left, top + size - thickness, size, thickness, 0.90, col.r, col.g, col.b)
        self:drawRect(left, top, thickness, size, 0.90, col.r, col.g, col.b)
        self:drawRect(left + size - thickness, top, thickness, size, 0.90, col.r, col.g, col.b)

        -- Centre dot.
        self:drawRect(screenX - dot / 2, screenY - dot / 2, dot, dot, 0.95, col.r, col.g, col.b)
    end

    return Marker
end

--- Create the overlay element once and keep it in FirearmCursor.marker.
function FirearmCursor.createMarker()
    if FirearmCursor.marker ~= nil then return FirearmCursor.marker end
    if ISUIElement == nil then return nil end

    if FirearmCursor.markerClass == nil then
        FirearmCursor.markerClass = buildMarkerClass()
    end

    local marker = FirearmCursor.markerClass:new()

    if marker.initialise ~= nil then
        marker:initialise()
    end
    marker:addToUIManager()
    marker:setVisible(true)

    FirearmCursor.marker = marker
    return marker
end
