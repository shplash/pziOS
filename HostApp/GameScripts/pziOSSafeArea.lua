-- pziOS: keeps the game's UI inside the screen's safe area (rounded corners, Dynamic Island on phones, home indicator) without changing the game
-- window, so the world still draws edge to edge. The launcher's "UI Margins" setting writes "left top right bottom" (game pixels) to
-- Zomboid/Lua/pzios_ui_margin.txt before the game starts. All zeros = this script does nothing.
--   A. getPlayerScreenLeft/Top/Width/Height (the rectangle most HUD pieces lay themselves out from: button prompts, hotbar, tooltips,
--      dialogs, minimap...) report the rectangle inside the margins, so those pieces move in together.
--   B. Floating UI (anything in UIManager.getUI()) is nudged inside the margins.
--   C. Full-screen menu pages (New Game, spawn map, load, sandbox, credits...) are shrunk and offset, then re-laid out.
--   D. The build number in the bottom-right corner repositions itself every frame, so it is kept inside the margins from its own render.
--   E. Controller prompts (Loot / Interact, A / B) are lined up in two clean columns.
--   F. The engine draws the speed controls (pause / play / fast-forward / wait) at a fixed corner position, so they are replaced by an
--      equivalent bar inside the margins. Not moved: the moodle icons, also engine-drawn at a fixed position.

local margins = nil
local ticks, menuFrames = 0, 0
local failed = false

local function readMargins()
    local reader = getFileReader("pzios_ui_margin.txt", false)
    if not reader then return false end
    local line = reader:readLine()
    reader:close()
    if not line then return false end
    local l, t, r, b = line:match("(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")
    if not l then return false end
    local m = { l = tonumber(l), t = tonumber(t), r = tonumber(r), b = tonumber(b) }
    print(string.format("[pziOS] UI margins left=%d top=%d right=%d bottom=%d", m.l, m.t, m.r, m.b))
    return m
end

local function activeMargins()
    if margins == nil then margins = readMargins() end
    if not margins or (margins.l + margins.t + margins.r + margins.b) <= 0 then return nil end
    return margins
end

-- A. player screen rectangle ---------------------------------------------------------------------------------------------------------
local origLeft, origTop, origWidth, origHeight

local function insetRect(pn)
    local m = activeMargins()
    local l, t, w, h = origLeft(pn), origTop(pn), origWidth(pn), origHeight(pn)
    if not m then return l, t, w, h end
    local core = getCore()
    local W, H = core:getScreenWidth(), core:getScreenHeight()
    local nl, nt = math.max(l, m.l), math.max(t, m.t)
    local nr, nb = math.min(l + w, W - m.r), math.min(t + h, H - m.b)     -- only edges that touch the screen edge move; split-screen seams stay
    if nr <= nl or nb <= nt then return l, t, w, h end
    return nl, nt, nr - nl, nb - nt
end

local function overridePlayerScreen()
    if origLeft or not getPlayerScreenLeft then return end
    origLeft, origTop, origWidth, origHeight = getPlayerScreenLeft, getPlayerScreenTop, getPlayerScreenWidth, getPlayerScreenHeight
    getPlayerScreenLeft = function(pn) local l = insetRect(pn); return l end
    getPlayerScreenTop = function(pn) local _, t = insetRect(pn); return t end
    getPlayerScreenWidth = function(pn) local _, _, w = insetRect(pn); return w end
    getPlayerScreenHeight = function(pn) local _, _, _, h = insetRect(pn); return h end
    print("[pziOS] player screen rectangle now follows the UI margins")
end

-- B. floating UI ------------------------------------------------------------------------------------------------------------------
local function place(ui, x, y)
    local tbl = ui.getTable and ui:getTable()
    if tbl and tbl.setX and tbl.setY then
        tbl:setX(x)
        tbl:setY(y)
    else
        ui:setX(x)
        ui:setY(y)
    end
end

local HUD_COLUMN_DROP = 34   -- extra game pixels the left HUD column (hand slots, inventory, health...) sits below the top margin
local placed = {}      -- ui -> {x, y, fights}: what we last set, to notice elements that put themselves back every frame
local ignored = {}     -- elements that fight the nudge are left alone rather than flickering

local function keepWindowsInside(minX, maxX, minY, maxY)
    local uis = UIManager.getUI()
    for i = 0, uis:size() - 1 do
        local ui = uis:get(i)
        if ui and not ignored[ui] and ui:isVisible() then
            local tbl = ui.getTable and ui:getTable()
            local w, h = ui:getWidth(), ui:getHeight()
            -- skip full-screen layers (fades, backdrops, menu roots), anything too big to fit, tiny elements (1x1 canvases such as the
            -- controller prompt draw in absolute coordinates, so moving them shifts everything they draw), and pieces handled elsewhere
            local kind = tbl and tbl.Type
            if w < (maxX - minX) and h < (maxY - minY) and w >= 24 and h >= 24
               and kind ~= "WaterMarkUI" and kind ~= "ISButtonPrompt" and kind ~= "ZomSpeedBar" then
                local x, y = ui:getX(), ui:getY()
                local nx, ny = x, y
                local topY = minY
                -- left HUD column starts lower to clear a Dynamic Island / notch; only when the left margin is big enough to mean one (phones, not iPads)
                if kind == "ISEquippedItem" and minX >= 70 then topY = minY + HUD_COLUMN_DROP end
                if x < minX then nx = minX elseif x + w > maxX then nx = maxX - w end
                if y < topY then ny = topY elseif y + h > maxY then ny = maxY - h end
                if nx ~= x or ny ~= y then
                    local p = placed[ui]
                    if p and (p.x ~= x or p.y ~= y) then       -- we moved it before, it moved itself back: stop fighting it
                        p.fights = p.fights + 1
                        if p.fights >= 2 then ignored[ui] = true end
                    end
                    if not ignored[ui] then
                        place(ui, nx, ny)
                        placed[ui] = { x = nx, y = ny, fights = p and p.fights or 0 }
                    end
                end
            end
        end
    end
end

-- C. full-screen menu pages ---------------------------------------------------------------------------------------------------------
-- MainScreen builds every page at a tiny virtual size, then MainScreen:instantiate / onResolutionChange resize the "1, 1" ones to the
-- whole screen and call recalcSize(). Any page found at full size gets the margins applied the same way, once.
local menuPages = { "soloScreen", "creditsScreen", "loadScreen", "sandOptions", "worldSelect", "mapSpawnSelect",
                    "charCreationProfession", "charCreationMain", "lastStandPlayerSelect" }
local insetPages = {}

local function insetMenuPages(W, H, m)
    local ms = MainScreen and MainScreen.instance
    if not ms then return end
    for _, name in ipairs(menuPages) do
        local ui = ms[name]
        if ui and ui.javaObject and ui:getWidth() >= W - 1 and ui:getHeight() >= H - 1 then
            ui:setWidth(W - m.l - m.r)
            ui:setHeight(H - m.t - m.b)
            ui:setX(m.l)
            ui:setY(m.t)
            if ui.recalcSize then ui:recalcSize() end
            -- the game's own resize (MainScreen.onResolutionChange) also tells each page its new size so it can re-lay out its children, for
            -- example the row of mode cards on the New Game page, which are placed from the page size and are not anchored to its edges
            if ui.onResolutionChange then
                local ok, err = pcall(ui.onResolutionChange, ui, W, H, W - m.l - m.r, H - m.t - m.b)
                if not ok then print("[pziOS] re-layout of " .. name .. " failed: " .. tostring(err)) end
            end
            if not insetPages[name] then
                insetPages[name] = true
                print("[pziOS] inset menu page " .. name)
            end
        end
    end
end

local function hookMainScreen()
    if not MainScreen or MainScreen.pziosHooked then return end
    local original = MainScreen.prerender
    MainScreen.prerender = function(self, ...)
        menuFrames = menuFrames + 1
        if menuFrames % 15 == 0 and not failed then
            local ok, err = pcall(function()
                local m = activeMargins()
                if not m then return end
                local core = getCore()
                local W, H = core:getScreenWidth(), core:getScreenHeight()
                insetMenuPages(W, H, m)
                keepWindowsInside(m.l, W - m.r, m.t, H - m.b)          -- menu extras such as mod panels on the title screen
            end)
            if not ok then failed = true; print("[pziOS] menu margin hook disabled: " .. tostring(err)) end
        end
        return original(self, ...)
    end
    MainScreen.pziosHooked = true
    print("[pziOS] menu pages will follow the UI margins")
end

-- D. build number ---------------------------------------------------------------------------------------------------------------------
-- WaterMarkUI:render() puts the panel back in the screen corner every frame, so a periodic nudge flickers. Adjusting right after its own
-- repositioning keeps the position identical on every frame.
local function hookWatermark()
    if not WaterMarkUI or WaterMarkUI.pziosHooked then return end
    local original = WaterMarkUI.render
    WaterMarkUI.render = function(self, ...)
        original(self, ...)
        local m = activeMargins()
        if m then
            local core = getCore()
            local W, H = core:getScreenWidth(), core:getScreenHeight()
            self:setX(math.min(self:getX(), W - m.r - self:getWidth()))
            self:setY(math.min(self:getY(), H - m.b - self:getHeight()))
        end
    end
    WaterMarkUI.pziosHooked = true
end

-- E. controller prompts ----------------------------------------------------------------------------------------------------------------
-- ISButtonPrompt draws the Y / LB prompts 16 px right of the X prompt on the left, and the A prompt 16 px left of the B prompt on the right.
-- This lines each pair up on one edge, with or without margins (the offset is the engine's own). The draw calls are compared by position, so prompts with identical text can't be mixed up.
local PROMPT_SHIFT, PROMPT_GLYPH, PROMPT_PAD = 16, 32, 11

local function hookButtonPrompt()
    if not ISButtonPrompt or ISButtonPrompt.pziosHooked then return end
    local original = ISButtonPrompt.prerender                  -- the prompts are drawn in prerender, not render
    ISButtonPrompt.prerender = function(self, ...)
        local drawTexture, drawText, drawTextRight = self.drawTexture, self.drawText, self.drawTextRight
        local function leftBase() return (self.x1 or 0) + (self.lmargin or 0) end
        local function rightBase() return (self.x2 or 0) + (self.w2 or 0) - (self.rmargin or 0) - PROMPT_GLYPH end
        self.drawTexture = function(s, tex, x, y, ...)
            if tex == s.buttonY or tex == s.buttonLB then
                if x == leftBase() + PROMPT_SHIFT then x = leftBase() end
            elseif tex == s.buttonA then
                if math.abs(x - (rightBase() - PROMPT_SHIFT)) <= 3 then x = x + PROMPT_SHIFT end
            end
            return drawTexture(s, tex, x, y, ...)
        end
        self.drawText = function(s, text, x, y, ...)
            if x == leftBase() + PROMPT_GLYPH + PROMPT_PAD + PROMPT_SHIFT then x = x - PROMPT_SHIFT end
            return drawText(s, text, x, y, ...)
        end
        self.drawTextRight = function(s, text, x, y, ...)
            if x == rightBase() - PROMPT_PAD - PROMPT_SHIFT then x = x + PROMPT_SHIFT end
            return drawTextRight(s, text, x, y, ...)
        end
        local ok, err = pcall(original, self, ...)
        self.drawTexture, self.drawText, self.drawTextRight = nil, nil, nil     -- back to the class methods
        if not ok then error(err, 0) end
    end
    ISButtonPrompt.pziosHooked = true
    print("[pziOS] controller prompts will be aligned")
end

-- F. speed controls ----------------------------------------------------------------------------------------------------------------------
-- The engine draws pause / play / fast-forward / wait at a fixed corner position that can't be moved (moving the element only moves its click
-- areas). So the engine's bar is hidden and this one, built from the same icons and driving the same buttons, is placed inside the margins.
local SPEED_BUTTONS = {
    { icon = "Pause", click = "Pause" },
    { icon = "Play", click = "Play" },
    { icon = "FFwd1", click = "Fast Forward x 1" },
    { icon = "FFwd2", click = "Fast Forward x 2" },
    { icon = "Wait", click = "Wait" },
}
local SPEED_TRUE_MULTIPLIER = { [1] = 2, [5] = 3, [20] = 4, [40] = 5 }   -- game time multiplier -> which button is lit
local speedTextures = {}
local function speedTexture(icon, on)
    local key = icon .. (on and "_On" or "_Off")
    if not speedTextures[key] then speedTextures[key] = getTexture("media/ui/speedControls/" .. key .. ".png") end
    return speedTextures[key]
end

ZomSpeedBar = ISUIElement:derive("ZomSpeedBar")

local CELL_PAD, BAR_HEIGHT = 10, 36

function ZomSpeedBar:new()
    local o = ISUIElement:new(0, 0, 200, BAR_HEIGHT)
    setmetatable(o, self)
    self.__index = self
    local w = 0
    for _, b in ipairs(SPEED_BUTTONS) do w = w + speedTexture(b.icon, false):getWidth() + CELL_PAD * 2 end
    o.width = w
    return o
end

function ZomSpeedBar:activeIndex()
    local sc = UIManager.getSpeedControls()
    if not sc then return 0 end
    if sc:getCurrentGameSpeed() == 0 then return 1 end
    return SPEED_TRUE_MULTIPLIER[getGameTime():getTrueMultiplier()] or 2
end

function ZomSpeedBar:prerender()
    self:drawRect(0, 0, self.width, self.height, 0.55, 0, 0, 0)
    local active, x = self:activeIndex(), 0
    for i, b in ipairs(SPEED_BUTTONS) do
        local tex = speedTexture(b.icon, i == active)
        self:drawTexture(tex, x + CELL_PAD, (self.height - tex:getHeight()) / 2, 1, 1, 1, 1)
        x = x + tex:getWidth() + CELL_PAD * 2
    end
end

function ZomSpeedBar:buttonAt(px)
    local x = 0
    for i, b in ipairs(SPEED_BUTTONS) do
        x = x + speedTexture(b.icon, false):getWidth() + CELL_PAD * 2
        if px < x then return i end
    end
    return nil
end

function ZomSpeedBar:onMouseDown(x, y) return true end
function ZomSpeedBar:onMouseUp(x, y)
    local i = self:buttonAt(x)
    local sc = UIManager.getSpeedControls()
    if i and sc then sc:ButtonClicked(SPEED_BUTTONS[i].click) end
    return true
end

local speedBar = nil
local function keepSpeedBar(m, W, H)
    local sc = UIManager.getSpeedControls and UIManager.getSpeedControls()
    if not sc or isClient() then return end                      -- multiplayer keeps the engine's own clock-only bar
    if not speedBar then
        speedBar = ZomSpeedBar:new()
        speedBar:initialise()
        speedBar:instantiate()
        speedBar:addToUIManager()
        print("[pziOS] speed controls replaced by a bar inside the margins")
    end
    if sc:isVisible() then sc:setVisible(false) end              -- hide the fixed engine bar
    local x, y = W - m.r - speedBar.width, m.t
    if speedBar:getX() ~= x or speedBar:getY() ~= y then speedBar:setX(x); speedBar:setY(y) end
    if not speedBar:getIsVisible() then speedBar:setVisible(true) end
end

Events.OnGameStart.Add(function() speedBar = nil end)           -- a new session starts with a fresh UI list

local function update()
    if failed then return end
    ticks = ticks + 1
    local m = activeMargins()
    if not m then return end
    local core = getCore()
    local W, H = core:getScreenWidth(), core:getScreenHeight()
    if ticks % 6 == 0 then keepWindowsInside(m.l, W - m.r, m.t, H - m.b) end
    keepSpeedBar(m, W, H)
end

Events.OnTick.Add(function()
    local ok, err = pcall(update)
    if not ok then
        failed = true                               -- never spam errors or break the game over a cosmetic feature
        print("[pziOS] UI margin script disabled: " .. tostring(err))
    end
end)

local function install()
    pcall(overridePlayerScreen)
    pcall(hookMainScreen)
    pcall(hookWatermark)
    pcall(hookButtonPrompt)
end
install()                                          -- classes may already exist when this file loads...
Events.OnGameBoot.Add(install)                     -- ...and are certain to exist by now, before any menu is built
Events.OnMainMenuEnter.Add(install)


-- -------------------------------------------------------------------------------------------------------------------------
-- Vehicle state for the on-screen overlay: it switches between the on-foot and the driving touch layout. This is kept here
-- as well as in pziOSDrive.lua, because at least one of the two always loads, and it runs whatever the margins are (Off
-- included). The overlay reads pzios_vehicle.txt and also watches for these printed lines in jvm.log.
do
    local vehicleLast = nil
    local vehicleTicks = 0
    local function vehicleWrite(inCar)
        local w = getFileWriter("pzios_vehicle.txt", true, false)
        if not w then return end
        w:write(inCar and "1" or "0")
        w:close()
    end
    pcall(function()      -- tells the app's log that the Lua side is alive, even before a vehicle is entered
        local r = getFileWriter("pzios_drive_ready.txt", true, false)
        if r then r:write("1"); r:close() end
    end)
    local function vehicleUpdate()
        if not getPlayer then return end
        local ok, p = pcall(getPlayer)
        if not ok or p == nil then return end
        local inCar = p.getVehicle ~= nil and p:getVehicle() ~= nil
        inCar = inCar and true or false
        if inCar == vehicleLast then return end
        vehicleLast = inCar
        pcall(vehicleWrite, inCar)
        print(inCar and "[pziOS] in a vehicle: driving layout" or "[pziOS] on foot: normal layout")
    end
    Events.OnTick.Add(function()
        vehicleTicks = vehicleTicks + 1
        if vehicleTicks % 30 == 0 then pcall(vehicleUpdate) end
    end)
    Events.OnGameStart.Add(function()
        vehicleLast = nil
        pcall(vehicleWrite, false)
        pcall(vehicleUpdate)
    end)
    print("[pziOS] vehicle state reporting on")
end
