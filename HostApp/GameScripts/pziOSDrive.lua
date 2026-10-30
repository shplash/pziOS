-- pziOS: tells the on-screen overlay when the player is in a vehicle, so it can switch to the driving layout and back on its
-- own. It writes "1" or "0" to pzios_vehicle.txt, and only when that changes.
--
-- The native overlay reads the file (see vehicle_state_file in native/glfw-ios/glfw_ios.m). No file simply means no automatic
-- switching: the DRIVE option in the radial menu, or the DRIVE button, still switches by hand.
--
-- This script is copied into the game's media/lua/client by main.m at every start, like pziOSSafeArea.lua.

local last = nil
local ticks = 0

print("[pziOS] drive script loaded")

local function write(inCar)
    local w = getFileWriter("pzios_vehicle.txt", true, false)
    if not w then return end
    w:write(inCar and "1" or "0")
    w:close()
end

local function update()
    if not getPlayer then return end
    local ok, player = pcall(getPlayer)
    if not ok then return end
    local inCar = player ~= nil and player.getVehicle ~= nil and player:getVehicle() ~= nil
    inCar = inCar and true or false
    if inCar == last then return end
    last = inCar
    pcall(write, inCar)
    print(inCar and "[pziOS] in a vehicle: driving layout" or "[pziOS] on foot: normal layout")
end

local function reset()
    last = nil
    pcall(write, false)          -- the overlay starts on foot
    pcall(update)
end

Events.OnTick.Add(function()
    ticks = ticks + 1
    if ticks % 30 == 0 then pcall(update) end       -- about twice a second
end)
Events.OnGameStart.Add(reset)
Events.OnMainMenuEnter.Add(reset)
