-- Animal Waste Production Rate
--
-- Scales straw consumption and manure / liquid manure output on cow
-- sheds by a single multiplier (1x / 2x / 3x). The choice comes from
-- a row injected into the vanilla General Settings page and persists
-- per-savegame. Compatible with Realistic Livestock.

AnimalWaste = {}
AnimalWaste.MOD_NAME = "FS25_AnimalWaste"
AnimalWaste.VERSION  = "0.2.0.1"

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
-- Hook wrappers.
--
-- updateOutput is a SHARED chained specialization function: milk, manure,
-- liquid manure, straw and every other husbandry output each register a link
-- and call superFunc to run the next one down the chain. Milk production is
-- therefore just another link reached *through* superFunc -- not something
-- this mod owns.
--
-- The earlier approach scaled our own spec field, then ran the entire chain
-- inside pcall() and threw the result away. The manure/slurry our link emits
-- happens BEFORE it hands control on via superFunc, so that part survived --
-- but the milk link further down the chain did not: any interruption inside
-- that swallowing pcall (a downstream error, or another mod that relies on the
-- call being clean) silently dropped milk. That is exactly why milk fell to
-- zero whenever the multiplier was > 1, yet manure kept flowing.
--
-- The safe approach used below: run the real chain FIRST, completely untouched,
-- so milk and every other output behave exactly as if this mod were absent.
-- Then add only the extra (M-1)x of manure / liquid manure on top, mirroring
-- the base game's own straw->manure and liquid-manure maths. Our scaling can no
-- longer touch the milk link, because it never wraps it.
-- ---------------------------------------------------------------------

local function wrappedStrawUpdateOutput(self, superFunc, foodFactor, productionFactor, globalProductionFactor)
    -- Real chain first: vanilla consumes 1x straw and emits 1x manure here, and
    -- milk + every other output link runs exactly as without this mod.
    local result = superFunc(self, foodFactor, productionFactor, globalProductionFactor)

    local M = AnimalWaste.multiplier or 1
    if self.isServer and M > 1 and isCowHusbandry(self) then
        local spec = self.spec_husbandryStraw
        if spec ~= nil
                and spec.inputLitersPerHour ~= nil and spec.inputLitersPerHour > 0
                and spec.outputLitersPerHour ~= nil and spec.outputLitersPerHour > 0 then
            -- Add the remaining (M-1)x: consume that much more straw and emit the
            -- matching manure, using the same delta/ratio maths as the base game.
            local timeAdjustment = g_currentMission.environment.timeAdjustment
            local extraStraw = spec.inputLitersPerHour * (M - 1) * timeAdjustment
            local consumed = extraStraw - self:removeHusbandryFillLevel(self:getOwnerFarmId(), extraStraw, spec.inputFillType)
            if consumed > 0 then
                local extraManure = foodFactor * spec.outputLitersPerHour * (consumed / extraStraw) * timeAdjustment
                if extraManure > 0 then
                    self:addHusbandryFillLevelFromTool(self:getOwnerFarmId(), extraManure, spec.outputFillType, nil, nil, nil)
                end
            end
            self:updateStrawPlane()
        end
    end

    return result
end


local function wrappedLiquidManureUpdateOutput(self, superFunc, foodFactor, productionFactor, globalProductionFactor)
    -- Real chain first (1x liquid manure + milk + everything else), untouched.
    local result = superFunc(self, foodFactor, productionFactor, globalProductionFactor)

    local M = AnimalWaste.multiplier or 1
    if self.isServer and M > 1 and isCowHusbandry(self) then
        local spec = self.spec_husbandryLiquidManure
        if spec ~= nil and spec.litersPerHour ~= nil and spec.litersPerHour > 0 then
            -- Vanilla emitted foodFactor * litersPerHour * timeAdjustment; add (M-1)x more.
            local extra = foodFactor * spec.litersPerHour * (M - 1) * g_currentMission.environment.timeAdjustment
            if extra > 0 then
                self:addHusbandryFillLevelFromTool(self:getOwnerFarmId(), extra, spec.fillType, nil, nil, nil)
            end
        end
    end

    return result
end


function AnimalWaste:installHooks()
    if PlaceableHusbandryStraw == nil or PlaceableHusbandryStraw.updateOutput == nil then
        Logging.error("[%s] PlaceableHusbandryStraw.updateOutput missing; mod will not scale straw/manure",
                      AnimalWaste.MOD_NAME)
        return false
    end
    if PlaceableHusbandryLiquidManure == nil or PlaceableHusbandryLiquidManure.updateOutput == nil then
        Logging.error("[%s] PlaceableHusbandryLiquidManure.updateOutput missing; mod will not scale liquid manure",
                      AnimalWaste.MOD_NAME)
        return false
    end

    PlaceableHusbandryStraw.updateOutput = Utils.overwrittenFunction(
        PlaceableHusbandryStraw.updateOutput, wrappedStrawUpdateOutput)

    PlaceableHusbandryLiquidManure.updateOutput = Utils.overwrittenFunction(
        PlaceableHusbandryLiquidManure.updateOutput, wrappedLiquidManureUpdateOutput)

    AnimalWaste.hooksInstalled = true
    log("hooks installed")
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

    -- Multiplayer: if we're the host, push the change out to all clients so
    -- their menus track ours. Only the host changes the setting (client lock is
    -- a later task); the host gate makes this a no-op in SP and on clients.
    if name == "husbandryProductionRate" and AnimalWaste.isMultiplayerHost() then
        AnimalWasteSettingsEvent.broadcast(state)
    end
end


-- ---------------------------------------------------------------------
-- Multiplayer value sync (server <-> client). Simulation stays server-side;
-- this only keeps the client's displayed value in step with the host.
-- ---------------------------------------------------------------------

-- True only on the hosting server of a multiplayer session. False in
-- single-player and on clients -- gates all outbound event traffic.
function AnimalWaste.isMultiplayerHost()
    return g_currentMission ~= nil
        and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer
        and g_currentMission.getIsServer ~= nil
        and g_currentMission:getIsServer()
end


-- Client-side: apply a state pushed from the server and refresh the menu row
-- if it has been built. Does not re-broadcast (clients never send), and
-- setState without forceEvent does not re-fire onSettingChanged -- so there is
-- no echo loop back to the host.
function AnimalWaste:applySyncedState(state)
    local setting = AnimalWaste.SETTINGS.husbandryProductionRate
    if setting == nil then return end
    if state == nil or state < 1 or state > #setting.values then return end

    setting.state = state
    AnimalWaste.multiplier = setting.values[state]

    if setting.element ~= nil then
        setting.element:setState(state)
    end

    log("multiplier synced to %sx (state %s)", tostring(AnimalWaste.multiplier), tostring(state))
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

-- Multiplayer join sync: when a client finishes loading on the server, push the
-- current setting to just that client so its menu opens on the right number.
-- onConnectionFinishedLoading is the server-side per-client "ready" hook.
if FSBaseMission ~= nil and FSBaseMission.onConnectionFinishedLoading ~= nil then
    FSBaseMission.onConnectionFinishedLoading = Utils.appendedFunction(
        FSBaseMission.onConnectionFinishedLoading,
        function(mission, connection)
            if not AnimalWaste.isMultiplayerHost() then return end
            local setting = AnimalWaste.SETTINGS.husbandryProductionRate
            local state = (setting and (setting.state or setting.default)) or 1
            AnimalWasteSettingsEvent.sendToClient(connection, state)
        end)
else
    Logging.error("[%s] FSBaseMission.onConnectionFinishedLoading missing; MP join-sync disabled",
                  AnimalWaste.MOD_NAME)
end

addModEventListener(AnimalWaste)
