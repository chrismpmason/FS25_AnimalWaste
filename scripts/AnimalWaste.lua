-- Animal Waste Production Rate
--
-- Scales straw consumption and manure / liquid manure output on cow
-- sheds by a single multiplier (1x / 2x / 3x). The choice comes from
-- a row injected into the vanilla General Settings page and persists
-- per-savegame. Compatible with Realistic Livestock.

AnimalWaste = {}
AnimalWaste.MOD_NAME = "FS25_AnimalWaste"
AnimalWaste.VERSION  = "0.1.0.2"

-- Current scale factor. Updated by the Settings click callback and by
-- loadFromXML. Defaults to 1x (pass-through) until either fires.
AnimalWaste.multiplier = 1

-- Must be declared before SETTINGS (FS25 has a global `log` with
-- different semantics that the callback closure would otherwise bind to).
local function log(fmt, ...)
    print(("[%s] " .. fmt):format(AnimalWaste.MOD_NAME, ...))
end

AnimalWaste.SETTINGS = {
    ["husbandryProductionRate"] = {
        index    = 1,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => 1x
        values   = { 1, 2, 3 },
        callback = function(name, newValue)
            AnimalWaste.multiplier = newValue
            log("multiplier set to %sx", tostring(newValue))
        end,
    },
}

AnimalWaste.settingsInjected = false
AnimalWaste.hooksInstalled   = false
AnimalWaste.rlPresent        = false
AnimalWaste.rlVersion        = nil
AnimalWaste.rlName           = nil

-- Cached on first use; the animal system isn't populated at mod-load.
AnimalWaste._cowTypeIndex = nil


-- ---------------------------------------------------------------------
-- RL detection (diagnostic only — the hook works identically either way)
-- ---------------------------------------------------------------------

function AnimalWaste:detectRealisticLivestock()
    if g_modManager == nil or g_modManager.getModByName == nil then
        log("RL detection skipped: g_modManager unavailable")
        return
    end

    local mod = g_modManager:getModByName("FS25_RealisticLivestockRM")
    if mod == nil then
        mod = g_modManager:getModByName("FS25_RealisticLivestock")
    end

    if mod ~= nil then
        AnimalWaste.rlPresent = true
        AnimalWaste.rlVersion = mod.version or "unknown"
        AnimalWaste.rlName    = mod.title or mod.modName or "Realistic Livestock"
        log("RealisticLivestock detected: yes, version %s (%s)",
            tostring(AnimalWaste.rlVersion), tostring(AnimalWaste.rlName))
    else
        log("RealisticLivestock detected: no")
    end
end


-- ---------------------------------------------------------------------
-- Cow-husbandry filter
-- ---------------------------------------------------------------------

local function getCowTypeIndex()
    if AnimalWaste._cowTypeIndex ~= nil then
        return AnimalWaste._cowTypeIndex
    end
    local as = g_currentMission and g_currentMission.animalSystem
    if as == nil or as.types == nil then return nil end
    for i, typ in ipairs(as.types) do
        if typ and typ.name == "COW" then
            AnimalWaste._cowTypeIndex = i
            return i
        end
    end
    return nil
end

local function isCowHusbandry(placeable)
    local spec = placeable and placeable.spec_husbandryAnimals
    if spec == nil or spec.animalTypeIndex == nil then return false end
    local cowIdx = getCowTypeIndex()
    if cowIdx == nil then return false end
    return spec.animalTypeIndex == cowIdx
end


-- ---------------------------------------------------------------------
-- Manure / liquid-manure scaling.
--
-- DO NOT hook PlaceableHusbandry*.updateOutput. It is a chained,
-- super-injected specialization method: the base game registers it with
-- SpecializationUtil.registerOverwrittenFunction, and milk, manure, liquid
-- manure and straw are all links in that single chain, each called as
-- fn(self, superFunc, foodFactor, productionFactor, globalProductionFactor).
--
-- Wrapping it with Utils.overwrittenFunction stacks a SECOND super-injection on
-- top of the engine's. The two shift every argument one slot to the right: our
-- wrapper receives the chain's super-function where it expects foodFactor, and
-- the real globalProductionFactor falls off the end into an ignored vararg and
-- arrives down-chain as nil. Manure/slurry survive (they multiply by
-- foodFactor, which still lands correctly); milk is the only spec that
-- multiplies by globalProductionFactor, so milk silently crashed on
-- "mul on number and nil" at PlaceableHusbandryMilk.updateOutput. In the
-- earlier build that crash was hidden inside a pcall, which swallowed it every
-- tick and silently ZEROED milk on cow sheds while manure kept flowing.
--
-- So we stay entirely out of the production chain. We append to the husbandry's
-- onHourChanged event (a plain event listener: appendedFunction runs after the
-- original with the same args and NO super-injection, so nothing can shift).
-- By the time it runs, the vanilla cycle has already produced one hour of milk,
-- manure and slurry. We then top up only the extra (M-1)x of manure and liquid
-- manure straight to storage. We never read, write, or run inside any milk
-- value or the updateOutput chain, so milk is physically untouchable here.
-- ---------------------------------------------------------------------

-- Extra (M-1)x liquid manure, mirroring vanilla's foodFactor * litersPerHour.
local function addExtraLiquidManure(self, M, foodFactor, timeAdjustment)
    local spec = self.spec_husbandryLiquidManure
    if spec == nil or spec.litersPerHour == nil or spec.litersPerHour <= 0 then return end

    local extra = foodFactor * spec.litersPerHour * (M - 1) * timeAdjustment
    if extra > 0 then
        self:addHusbandryFillLevelFromTool(self:getOwnerFarmId(), extra, spec.fillType, nil, nil, nil)
    end
end

-- Extra (M-1)x straw consumption + matching manure, mirroring vanilla's
-- straw->manure delta maths for the extra portion only.
local function addExtraManure(self, M, foodFactor, timeAdjustment)
    local spec = self.spec_husbandryStraw
    if spec == nil
            or spec.inputLitersPerHour == nil or spec.inputLitersPerHour <= 0
            or spec.outputLitersPerHour == nil or spec.outputLitersPerHour <= 0 then
        return
    end

    local extraStraw = spec.inputLitersPerHour * (M - 1) * timeAdjustment
    if extraStraw <= 0 then return end

    local consumed = extraStraw - self:removeHusbandryFillLevel(self:getOwnerFarmId(), extraStraw, spec.inputFillType)
    if consumed > 0 then
        local extraManure = foodFactor * spec.outputLitersPerHour * (consumed / extraStraw) * timeAdjustment
        if extraManure > 0 then
            self:addHusbandryFillLevelFromTool(self:getOwnerFarmId(), extraManure, spec.outputFillType, nil, nil, nil)
        end
        self:updateStrawPlane()
    end
end

-- Appended to PlaceableHusbandry.onHourChanged. Runs once per in-game hour,
-- AFTER the base cycle has produced its 1x of everything (milk included).
local function onHourChangedAddExtraWaste(self, currentHour)
    if not self.isServer then return end

    local M = AnimalWaste.multiplier or 1
    if M == 1 or not isCowHusbandry(self) then return end

    local husbandrySpec = self.spec_husbandry
    if husbandrySpec == nil then return end

    -- The base updateProduction stored this hour's foodFactor here; it is the
    -- same value vanilla used to size the 1x manure/slurry we are scaling.
    local foodFactor = husbandrySpec.productionFactor
    if foodFactor == nil or foodFactor <= 0 then return end

    local timeAdjustment = g_currentMission.environment.timeAdjustment

    addExtraManure(self, M, foodFactor, timeAdjustment)
    addExtraLiquidManure(self, M, foodFactor, timeAdjustment)
end


function AnimalWaste:installHooks()
    if PlaceableHusbandry == nil or PlaceableHusbandry.onHourChanged == nil then
        Logging.error("[%s] PlaceableHusbandry.onHourChanged missing; mod will not scale manure/slurry",
                      AnimalWaste.MOD_NAME)
        return false
    end

    -- Append (never overwrite) so we run after the untouched production cycle
    -- and never become a super-injected link in any husbandry chain.
    PlaceableHusbandry.onHourChanged = Utils.appendedFunction(
        PlaceableHusbandry.onHourChanged, onHourChangedAddExtraWaste)

    AnimalWaste.hooksInstalled = true
    log("hooks installed (onHourChanged extra-waste append)")
    return true
end


-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function AnimalWaste:loadMap(filename)
    self:detectRealisticLivestock()
    self:loadFromXML()
    log("v%s loaded, multiplier=%sx", AnimalWaste.VERSION, tostring(AnimalWaste.multiplier))
end


-- ---------------------------------------------------------------------
-- Persistence: {savegameDirectory}/animalWaste.xml
-- Schema: <animalWaste version="1"><husbandryProductionRate state="N"/></animalWaste>
-- N is the 1-based index into values[], not the value itself.
-- ---------------------------------------------------------------------

function AnimalWaste:getSaveXMLPath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then return nil end
    local dir = g_currentMission.missionInfo.savegameDirectory
    if dir == nil then return nil end
    return dir .. "/animalWaste.xml"
end


function AnimalWaste:saveToXML()
    local path = self:getSaveXMLPath()
    if path == nil then return end

    local xml = createXMLFile("animalWasteSave", path, "animalWaste")
    if xml == nil or xml == 0 then
        Logging.warning("[%s] could not create save XML at %s", AnimalWaste.MOD_NAME, tostring(path))
        return
    end

    setXMLInt(xml, "animalWaste#version", 1)
    for name, setting in pairs(AnimalWaste.SETTINGS) do
        setXMLInt(xml, "animalWaste." .. name .. "#state", setting.state or setting.default)
    end

    saveXMLFile(xml)
    delete(xml)
    log("settings saved to %s", path)
end


function AnimalWaste:loadFromXML()
    local path = self:getSaveXMLPath()
    if path == nil then return end
    if not fileExists(path) then
        log("no saved settings at %s (first run on this savegame; using defaults)", path)
        return
    end

    local xml = loadXMLFile("animalWasteLoad", path)
    if xml == nil or xml == 0 then
        Logging.warning("[%s] could not read save XML at %s", AnimalWaste.MOD_NAME, tostring(path))
        return
    end

    for name, setting in pairs(AnimalWaste.SETTINGS) do
        local state = getXMLInt(xml, "animalWaste." .. name .. "#state")
        if state ~= nil and state >= 1 and state <= #setting.values then
            setting.state = state
            if setting.callback then
                setting.callback(name, setting.values[state])
            end
        end
    end

    delete(xml)
    log("settings loaded from %s", path)
end


-- ---------------------------------------------------------------------
-- Settings UI: clone a vanilla MultiTextOption row and repurpose it
-- ---------------------------------------------------------------------

function AnimalWaste.initSettings()
    if AnimalWaste.settingsInjected then return end

    local settingsPage = g_inGameMenu and g_inGameMenu.pageSettings
    if settingsPage == nil then return end
    local scrollPanel = settingsPage.gameSettingsLayout
    if scrollPanel == nil then return end

    local sectionHeader, multiOptionElement
    for _, element in pairs(scrollPanel.elements) do
        if element.name == "sectionHeader" and sectionHeader == nil then
            sectionHeader = element:clone(scrollPanel)
        end
        if element.typeName == "Bitmap"
                and element.elements ~= nil
                and element.elements[1] ~= nil
                and element.elements[1].typeName == "MultiTextOption"
                and multiOptionElement == nil then
            multiOptionElement = element
        end
        if sectionHeader ~= nil and multiOptionElement ~= nil then break end
    end

    if sectionHeader == nil or multiOptionElement == nil then
        Logging.warning("[%s] could not find sectionHeader / MultiTextOption templates; settings UI skipped",
                        AnimalWaste.MOD_NAME)
        return
    end

    sectionHeader:setText(g_i18n:getText("aw_settings"))

    for name, setting in pairs(AnimalWaste.SETTINGS) do
        setting.state = setting.state or setting.default
        local row = multiOptionElement:clone(scrollPanel)
        row.id = nil

        local prefix = "aw_settings_" .. name .. "_"
        for _, element in pairs(row.elements) do
            if element.typeName == "Text" then
                element:setText(g_i18n:getText(prefix .. "label"))
                element.id = nil
            end
            if element.typeName == setting.type then
                local texts = {}
                for i = 1, #setting.values do
                    texts[i] = g_i18n:getText(prefix .. "texts_" .. i)
                end
                element:setTexts(texts)
                element:setState(setting.state)
                if element.elements ~= nil and element.elements[1] ~= nil then
                    element.elements[1]:setText(g_i18n:getText(prefix .. "tooltip"))
                end
                element.id = "aws_" .. name
                element.onClickCallback = AnimalWaste.onSettingChanged
                setting.element = element
            end
        end
    end

    AnimalWaste.settingsInjected = true
    log("settings UI injected")
end


function AnimalWaste.onSettingChanged(_, state, button)
    if button == nil then button = state end
    if button == nil or button.id == nil then return end
    if not string.contains(button.id, "aws_") then return end

    local name = string.sub(button.id, 5)
    local setting = AnimalWaste.SETTINGS[name]
    if setting == nil then return end

    setting.state = state
    if setting.callback then setting.callback(name, setting.values[state]) end
end


-- ---------------------------------------------------------------------
-- Top-level wiring
-- ---------------------------------------------------------------------

AnimalWaste:installHooks()

if InGameMenuSettingsFrame ~= nil then
    if InGameMenuSettingsFrame.onFrameOpen ~= nil then
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameOpen,
            function(self) AnimalWaste.initSettings() end)
    else
        Logging.error("[%s] InGameMenuSettingsFrame.onFrameOpen missing; settings UI cannot install",
                      AnimalWaste.MOD_NAME)
    end

    if InGameMenuSettingsFrame.onFrameClose ~= nil then
        InGameMenuSettingsFrame.onFrameClose = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameClose,
            function(self) AnimalWaste:saveToXML() end)
    end
end

-- Belt-and-braces save on game-save (catches quit paths that skip onFrameClose).
if FSBaseMission ~= nil and FSBaseMission.saveSavegame ~= nil then
    FSBaseMission.saveSavegame = Utils.appendedFunction(
        FSBaseMission.saveSavegame,
        function(self) AnimalWaste:saveToXML() end)
end

addModEventListener(AnimalWaste)
