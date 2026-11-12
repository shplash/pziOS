--[[
    Firearm Cursor - game setting handling.

    Two independent jobs:

    1. Show the normal isometric cursor instead of the firearm crosshair.
       This uses the vanilla Core option "Show Cursor While Aiming"
       (getOptionShowCursorWhileAiming / setOptionShowCursorWhileAiming),
       documented in the official API (zombie.core.Core), plus the vanilla
       "Show Aim Texture" option for the crosshair graphic.

    2. Optional (mod sandbox option): hide the vanilla firearm hit-chance
       indicator, i.e. the valid-target reticle the game colours while aiming
       (getOptionShowValidTargetReticleTexture /
       setOptionShowValidTargetReticleTexture). Independent of everything else:
       when the toggle is Off the vanilla indicator is never written to.

    3. Optional (mod sandbox option): force the vanilla sandbox option
       "Firearms use damage chance" to Disabled.

       Verified name and values (PZwiki server settings, B42):
           FirearmUseDamageChance = 1   -- Disabled
           FirearmUseDamageChance = 2   -- Zombies only (vanilla default)
           FirearmUseDamageChance = 3   -- All types of target
       Set through SandboxOptions.getInstance():getOptionByName(...)
       :setValue(int) (zombie.SandboxOptions / IntegerConfigOption), with the
       SandboxVars Lua mirror kept in sync as a fallback.
--]]

FirearmCursor = FirearmCursor or {}

FirearmCursor.originalOptions = nil
FirearmCursor.originalDamageChance = nil

local DAMAGE_CHANCE_OPTION = "FirearmUseDamageChance"
local DAMAGE_CHANCE_DISABLED = 1

---------------------------------------------------------------------------
-- 1. Cursor / crosshair display options
---------------------------------------------------------------------------

--- Remember the player's own aim-display settings so they can be put back.
function FirearmCursor.captureOriginalOptions()
    if FirearmCursor.originalOptions ~= nil then return end

    local saved = {}

    local ok1, v1 = pcall(function() return getCore():getOptionShowCursorWhileAiming() end)
    if ok1 then saved.showCursorWhileAiming = v1 end

    local ok2, v2 = pcall(function() return getCore():getOptionShowAimTexture() end)
    if ok2 then saved.showAimTexture = v2 end

    local ok3, v3 = pcall(function() return getCore():getOptionShowValidTargetReticleTexture() end)
    if ok3 then saved.showValidTargetReticleTexture = v3 end

    FirearmCursor.originalOptions = saved
end

--- Keep the normal isometric cursor visible while aiming.
function FirearmCursor.applyVanillaUI()
    FirearmCursor.captureOriginalOptions()

    pcall(function() getCore():setOptionShowCursorWhileAiming(true) end)
    pcall(function() getCore():setOptionShowAimTexture(false) end)

    -- Independent toggle: hide the vanilla hit-chance indicator.
    if FirearmCursor.getSandboxBoolean("DisableVanillaHitChanceIndicator", true) then
        pcall(function() getCore():setOptionShowValidTargetReticleTexture(false) end)
    end
end

--- Put the player's original aim-display settings back.
function FirearmCursor.restoreVanillaUI()
    local saved = FirearmCursor.originalOptions
    if saved == nil then return end

    if saved.showCursorWhileAiming ~= nil then
        local value = saved.showCursorWhileAiming
        pcall(function() getCore():setOptionShowCursorWhileAiming(value) end)
    end

    if saved.showAimTexture ~= nil then
        local value = saved.showAimTexture
        pcall(function() getCore():setOptionShowAimTexture(value) end)
    end

    if saved.showValidTargetReticleTexture ~= nil then
        local value = saved.showValidTargetReticleTexture
        pcall(function() getCore():setOptionShowValidTargetReticleTexture(value) end)
    end

    FirearmCursor.originalOptions = nil
end

---------------------------------------------------------------------------
-- 2. "Firearms use damage chance" sandbox setting
---------------------------------------------------------------------------

local function readDamageChance()
    if SandboxOptions ~= nil and SandboxOptions.getInstance ~= nil then
        local ok, option = pcall(function()
            return SandboxOptions.getInstance():getOptionByName(DAMAGE_CHANCE_OPTION)
        end)
        if ok and option ~= nil and option.getValue ~= nil then
            local ok2, value = pcall(function() return option:getValue() end)
            if ok2 and type(value) == "number" then
                return value
            end
        end
    end

    if SandboxVars ~= nil then
        local mirrored = SandboxVars[DAMAGE_CHANCE_OPTION]
        if type(mirrored) == "number" then
            return mirrored
        end
    end

    return nil
end

local function writeDamageChance(value)
    local applied = false

    if SandboxOptions ~= nil and SandboxOptions.getInstance ~= nil then
        local ok, option = pcall(function()
            return SandboxOptions.getInstance():getOptionByName(DAMAGE_CHANCE_OPTION)
        end)
        if ok and option ~= nil and option.setValue ~= nil then
            local ok2 = pcall(function() option:setValue(value) end)
            if ok2 then applied = true end
        end
    end

    if SandboxVars ~= nil and SandboxVars[DAMAGE_CHANCE_OPTION] ~= nil then
        SandboxVars[DAMAGE_CHANCE_OPTION] = value
        applied = true
    end

    return applied
end

--- Force "Firearms use damage chance" to Disabled, if the mod option is On.
-- Default is OFF: this is a gameplay setting, not a visual one. Turning it on
-- reverts B42 to the legacy chance-to-hit path, which changes how firearms
-- behave (including firing without aiming), so it must be opt-in.
function FirearmCursor.applySandboxOverrides()
    if not FirearmCursor.getSandboxBoolean("DisableFirearmUseDamageChance", false) then
        return
    end

    FirearmCursor.originalDamageChance = readDamageChance()
    writeDamageChance(DAMAGE_CHANCE_DISABLED)
end

--- Put the sandbox value back to what it was when the game started.
function FirearmCursor.restoreSandboxOverrides()
    local original = FirearmCursor.originalDamageChance
    if original == nil then return end

    writeDamageChance(original)
    FirearmCursor.originalDamageChance = nil
end
