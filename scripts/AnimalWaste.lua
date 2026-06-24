-- Animal Waste Production Rate
--
-- Scales straw consumption and manure / liquid manure output on cow
-- sheds by a single multiplier (1x / 2x / 3x / 5x / 10x). The choice comes from
-- a row injected into the vanilla General Settings page and persists
-- per-savegame. Compatible with Realistic Livestock.

AnimalWaste = {}
AnimalWaste.MOD_NAME = "FS25_AnimalWaste"
AnimalWaste.VERSION  = "1.1.0.1"

-- Current scale factor. Updated by the Settings click callback and by
-- loadFromXML. Defaults to 1x (pass-through) until either fires.
AnimalWaste.multiplier = 1

-- Diagnostic logging. OFF for normal play; the only DEBUG-gated line is the
-- per-shed hourly extra-waste trace, used when testing the RL-order fix. Flip to
-- true to re-enable it.
AnimalWaste.DEBUG = false

-- Must be declared before SETTINGS (FS25 has a global `log` with
-- different semantics that the callback closure would otherwise bind to).
local function log(fmt, ...)
    print(("[%s] " .. fmt):format(AnimalWaste.MOD_NAME, ...))
end

-- Gated diagnostic logger. No-op unless AnimalWaste.DEBUG.
local function debugLog(fmt, ...)
    if AnimalWaste.DEBUG then
        print(("[%s] DEBUG " .. fmt):format(AnimalWaste.MOD_NAME, ...))
    end
end

AnimalWaste.SETTINGS = {
    ["husbandryProductionRate"] = {
        index    = 1,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => 1x
        values   = { 1, 2, 3, 5, 10 },
        callback = function(name, newValue)
            AnimalWaste.multiplier = newValue
            log("multiplier set to %sx", tostring(newValue))
        end,
    },
}

AnimalWaste.settingsInjected      = false
AnimalWaste.extraWasteHookInstalled = false
AnimalWaste.rlPresent             = false
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
-- multiplies by globalProductionFactor, so milk crashes on
-- "mul on number and nil" at PlaceableHusbandryMilk.updateOutput. That one
-- defect caused every milk failure this mod has had -- silent while the bad
-- call was hidden in a pcall, then a per-frame crash once it was not.
--
-- So we stay entirely out of the production chain. We append to the husbandry's
-- onHourChanged event (a plain event listener: appendedFunction runs after the
-- original with the same args and NO super-injection, so nothing can shift).
-- By the time it runs, the vanilla cycle has already produced one hour of milk,
-- manure and slurry. We then top up only the extra (M-1)x of manure and liquid
-- manure straight to storage. We never read, write, or run inside any milk
-- value or the updateOutput chain, so milk is physically untouchable here.
-- ---------------------------------------------------------------------

-- Extra (M-1)x liquid manure: scale the husbandry's CURRENT per-hour slurry rate
-- (spec.litersPerHour) directly, rather than re-deriving vanilla's
-- foodFactor*litersPerHour. Under Realistic Livestock spec.litersPerHour is RL's
-- sum of per-animal slurry output, refreshed each hour by RL's onHourChanged
-- append -- so as long as we run AFTER RL (see installExtraWasteHookLast),
-- scaling it composes with RL's actual production. Returns litres added.
-- Defensive: feature-detects the API and pcall-guards the write.
local function addExtraLiquidManure(self, M, timeAdjustment)
    local spec = self.spec_husbandryLiquidManure
    if spec == nil or spec.litersPerHour == nil or spec.litersPerHour <= 0 then return 0 end
    if spec.fillType == nil or self.addHusbandryFillLevelFromTool == nil then return 0 end

    local extra = spec.litersPerHour * (M - 1) * timeAdjustment
    if extra <= 0 then return 0 end

    local ok = pcall(function()
        self:addHusbandryFillLevelFromTool(self:getOwnerFarmId(), extra, spec.fillType, nil, nil, nil)
    end)
    return ok and extra or 0
end

-- Extra (M-1)x manure: scale the husbandry's CURRENT per-hour manure rate
-- (spec.outputLitersPerHour) directly -- RL refreshes this from its per-animal
-- model each hour, so scaling it composes with RL instead of re-deriving the
-- vanilla foodFactor formula. Straw is drawn BEST-EFFORT (so the multiplier still
-- consumes more straw when available) but NEVER gates the manure: running last,
-- vanilla + RL have already consumed this hour's straw, so a straw-gated formula
-- would starve the top-up to zero. Returns manureAdded, strawConsumed.
-- Defensive throughout (feature-detect + pcall).
local function addExtraManure(self, M, timeAdjustment)
    local spec = self.spec_husbandryStraw
    if spec == nil or spec.outputLitersPerHour == nil or spec.outputLitersPerHour <= 0 then
        return 0, 0
    end

    -- Best-effort extra straw draw -- does NOT gate the manure top-up below.
    local strawConsumed = 0
    if spec.inputLitersPerHour ~= nil and spec.inputLitersPerHour > 0
            and spec.inputFillType ~= nil and self.removeHusbandryFillLevel ~= nil then
        local extraStraw = spec.inputLitersPerHour * (M - 1) * timeAdjustment
        if extraStraw > 0 then
            local ok, notRemoved = pcall(function()
                return self:removeHusbandryFillLevel(self:getOwnerFarmId(), extraStraw, spec.inputFillType)
            end)
            if ok and type(notRemoved) == "number" then
                strawConsumed = extraStraw - notRemoved
                if strawConsumed > 0 and self.updateStrawPlane ~= nil then
                    pcall(function() self:updateStrawPlane() end)
                end
            end
        end
    end

    -- Manure top-up: proportional to the refreshed output rate, NOT gated on straw.
    if spec.outputFillType == nil or self.addHusbandryFillLevelFromTool == nil then
        return 0, strawConsumed
    end
    local extraManure = spec.outputLitersPerHour * (M - 1) * timeAdjustment
    if extraManure <= 0 then return 0, strawConsumed end

    local ok = pcall(function()
        self:addHusbandryFillLevelFromTool(self:getOwnerFarmId(), extraManure, spec.outputFillType, nil, nil, nil)
    end)
    return (ok and extraManure or 0), strawConsumed
end

-- Appended to PlaceableHusbandry.onHourChanged, installed LAST from loadMap (see
-- installExtraWasteHookLast) so it runs AFTER Realistic Livestock's onHourChanged
-- append has refreshed outputLitersPerHour / litersPerHour for the hour. We then
-- top up the extra (M-1)x of manure and slurry by scaling those refreshed rates.
local function onHourChangedAddExtraWaste(self, currentHour)
    if not self.isServer then return end

    local M = AnimalWaste.multiplier or 1
    if M == 1 or not isCowHusbandry(self) then return end

    local husbandrySpec = self.spec_husbandry
    if husbandrySpec == nil then return end

    -- IMPORTANT: we no longer GATE on productionFactor. Under Realistic Livestock
    -- it can read 0 even while RL is producing manure (RL drives output
    -- per-animal, not via the vanilla food factor), which would block ALL scaling
    -- -- the "10x has no effect under RL" bug. We scale the husbandry's refreshed
    -- output rates directly instead; productionFactor is still LOGGED for
    -- diagnosis.
    local timeAdjustment = (g_currentMission ~= nil and g_currentMission.environment ~= nil
        and g_currentMission.environment.timeAdjustment) or 1

    local strawSpec  = self.spec_husbandryStraw
    local liquidSpec = self.spec_husbandryLiquidManure

    local manureAdded, strawConsumed = addExtraManure(self, M, timeAdjustment)
    local liquidAdded = addExtraLiquidManure(self, M, timeAdjustment)

    -- One-off diagnostic (per shed per hour, DEBUG-gated): shows where a zero came
    -- from before the reorder and that the top-up is non-zero after it.
    debugLog("extra-waste shed=%s M=%sx foodFactor=%s strawIn/hr=%s manureOut/hr=%s slurry/hr=%s -> strawConsumed=%.1f manureAdded=%.1f slurryAdded=%.1f",
        tostring(self.uniqueId or self), tostring(M),
        tostring(husbandrySpec.productionFactor),
        tostring(strawSpec and strawSpec.inputLitersPerHour),
        tostring(strawSpec and strawSpec.outputLitersPerHour),
        tostring(liquidSpec and liquidSpec.litersPerHour),
        strawConsumed or 0, manureAdded or 0, liquidAdded or 0)
end


-- Install the extra-waste append from loadMap (NOT at mod-load), guarded against
-- re-entry. Every mod's source -- including Realistic Livestock -- has finished
-- appending to PlaceableHusbandry.onHourChanged before any loadMap runs, so
-- appending HERE lands us LAST in the chain: we run after the vanilla cycle AND
-- after RL's onHourChanged append has refreshed outputLitersPerHour/litersPerHour
-- for the hour. (Appending at mod-load could land us BEFORE RL's append, reading
-- ~0 and scaling nothing -- the "10x has no effect under RL" bug this fixes.)
-- Still an append, never an overwrite, so we never become a super-injected link
-- in any husbandry chain and never clobber RL.
function AnimalWaste:installExtraWasteHookLast()
    if AnimalWaste.extraWasteHookInstalled then return end
    if PlaceableHusbandry == nil or PlaceableHusbandry.onHourChanged == nil then
        Logging.error("[%s] PlaceableHusbandry.onHourChanged missing; mod will not scale manure/slurry",
                      AnimalWaste.MOD_NAME)
        return
    end

    PlaceableHusbandry.onHourChanged = Utils.appendedFunction(
        PlaceableHusbandry.onHourChanged, onHourChangedAddExtraWaste)

    AnimalWaste.extraWasteHookInstalled = true
    log("extra-waste hook installed LAST at loadMap (runs after RL's onHourChanged append)")
end


-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function AnimalWaste:loadMap(filename)
    self:detectRealisticLivestock()
    self:loadFromXML()

    -- Install the extra-waste scaling hook HERE (not at mod-load) so it lands LAST
    -- in the onHourChanged chain, after Realistic Livestock's append -- see
    -- installExtraWasteHookLast. This is the core of the RL-order fix.
    self:installExtraWasteHookLast()

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

    -- Editable on single-player and on the MP host; read-only on an MP client.
    local canEdit = AnimalWaste.isSettingEditable()

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

        -- The vanilla game-settings row we cloned is host-authoritative: the base
        -- game hides/disables it for non-master clients, and the clone inherits
        -- that state -- which is why a client saw the section title but no control.
        -- Override it explicitly so the control is ALWAYS visible, and editable
        -- only where a change is safe (single-player or the MP host). On a client
        -- it stays visible but disabled (read-only), showing the synced value.
        row:setVisible(true)
        if setting.element ~= nil then
            setting.element:setVisible(true)
            setting.element:setDisabled(not canEdit)
        end
    end

    AnimalWaste.settingsInjected = true
    log("settings injected (host=%s)", tostring(canEdit))
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


-- True where it is safe to CHANGE the setting: single-player, or the MP host.
-- False on an MP client -- the setting is host-authoritative, so a client edit
-- would not broadcast and would desync the session. The client still SEES the
-- control (read-only); only its interactivity is gated here.
function AnimalWaste.isSettingEditable()
    if g_currentMission == nil then return true end
    local dyn = g_currentMission.missionDynamicInfo
    if dyn == nil or not dyn.isMultiplayer then return true end  -- single-player
    return g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer()
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

-- NOTE: the extra-waste onHourChanged append is installed from loadMap
-- (installExtraWasteHookLast), NOT here at mod-load, so it lands last in the
-- chain after Realistic Livestock's append.

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
