-- Animal Waste Production Rate
--
-- Scales straw consumption and manure / liquid manure output on cow
-- sheds by a single multiplier (1x / 2x / 3x / 5x / 10x). The choice comes from
-- a row injected into the vanilla General Settings page and persists
-- per-savegame. Compatible with Realistic Livestock.

AnimalWaste = {}
AnimalWaste.MOD_NAME = "FS25_AnimalWaste"
AnimalWaste.VERSION  = "1.2.0.0"

-- Current scale factor. Updated by the Settings click callback and by
-- loadFromXML. Defaults to 1x (pass-through) until either fires.
AnimalWaste.multiplier = 1

-- Deep Litter master toggle. When OFF (the default), the mod behaves exactly as
-- it did before this feature existed: the multiplier is untouched and no pack
-- accumulates. Updated by the setting callback and by loadFromXML / MP sync.
AnimalWaste.deepLitterEnabled = false

-- Pack depths loaded from a savegame before the husbandries exist, keyed by
-- placeable uniqueId. Applied lazily the first time each shed's pack is read
-- (see getPackDepth). Empty on a fresh save.
AnimalWaste.pendingPacks = {}

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
        values   = { 1, 2, 3, 5, 10 },
        callback = function(name, newValue)
            AnimalWaste.multiplier = newValue
            log("multiplier set to %sx", tostring(newValue))
        end,
    },
    ["deepLitter"] = {
        index    = 2,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => false (Off)
        values   = { false, true },
        callback = function(name, newValue)
            AnimalWaste.deepLitterEnabled = newValue and true or false
            log("deep litter %s", AnimalWaste.deepLitterEnabled and "ON" or "OFF")
        end,
    },
}

-- Settings sorted by their `index`, so the injected rows always appear in a
-- stable order (production rate first, Deep Litter next to it) regardless of
-- pairs() iteration order.
function AnimalWaste.orderedSettings()
    local list = {}
    for name, setting in pairs(AnimalWaste.SETTINGS) do
        list[#list + 1] = { name = name, setting = setting }
    end
    table.sort(list, function(a, b)
        return (a.setting.index or 99) < (b.setting.index or 99)
    end)
    return list
end

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

-- Run fn(placeable) for every cow husbandry currently in the mission.
local function forEachCowHusbandry(fn)
    local ps = g_currentMission and g_currentMission.placeableSystem
    if ps == nil or ps.placeables == nil then return end
    for _, placeable in ipairs(ps.placeables) do
        if isCowHusbandry(placeable) then
            fn(placeable)
        end
    end
end


-- ---------------------------------------------------------------------
-- Deep Litter pack store
--
-- The "pack" is the accumulated solid muck for one shed. It lives on the
-- husbandry itself (spec_husbandry.awPackDepth, in liters) so it travels with
-- the placeable; persistence keys it by the placeable's stable uniqueId.
-- ---------------------------------------------------------------------

-- Current pack depth for a shed (liters). On first access it lazily restores
-- any value loaded from the savegame (pendingPacks, keyed by uniqueId), so a
-- shed that has never been touched this session still round-trips its pack.
local function getPackDepth(placeable)
    local spec = placeable.spec_husbandry
    if spec == nil then return 0 end
    if spec.awPackDepth == nil then
        local uid = placeable.uniqueId
        spec.awPackDepth = (uid ~= nil and AnimalWaste.pendingPacks[uid]) or 0
    end
    return spec.awPackDepth
end

local function setPackDepth(placeable, liters)
    local spec = placeable.spec_husbandry
    if spec == nil then return end
    spec.awPackDepth = math.max(0, liters)
end


-- Add muck to a shed's pack and (on the MP host) sync the new depth to clients.
function AnimalWaste.addToPack(placeable, liters)
    if liters <= 0 then return end
    local newDepth = getPackDepth(placeable) + liters
    setPackDepth(placeable, newDepth)
    if AnimalWaste.isMultiplayerHost() then
        AnimalWastePackEvent.broadcastPack(placeable, newDepth)
    end
end


-- Server-side: pull ALL solid manure currently sitting in the shed's manure
-- store and move it into the pack. Slurry (liquid manure) is never touched, so
-- it keeps flowing to its store normally. Called once per in-game hour from the
-- onHourChanged append while Deep Litter is ON, after the hour's production has
-- landed -- so it sweeps up both the vanilla 1x and the multiplier's extra,
-- with no double counting (the store is left at zero for manure).
function AnimalWaste.divertManureToPack(placeable)
    local strawSpec = placeable.spec_husbandryStraw
    if strawSpec == nil or strawSpec.outputFillType == nil then return end

    -- removeHusbandryFillLevel returns the portion it could NOT remove, so a
    -- request far larger than any shed can hold makes (request - returned) equal
    -- exactly the manure that was in the store. This is the same function and
    -- return convention the multiplier path already relies on for straw.
    local farmId  = placeable:getOwnerFarmId()
    local REQUEST = 1e9
    local notRemoved = placeable:removeHusbandryFillLevel(farmId, REQUEST, strawSpec.outputFillType)
    if notRemoved == nil then return end

    local removed = REQUEST - notRemoved
    if removed > 0 then
        AnimalWaste.addToPack(placeable, removed)
    end
end


-- Server-side: release the whole pack as loadable solid manure (credited to the
-- shed's manure store) and reset the pack to zero. Safe to call on an empty
-- pack (no-op). In MP the resulting store change replicates via the base game,
-- and the zeroed pack is broadcast to clients.
function AnimalWaste.muckOutShed(placeable)
    if not AnimalWaste.isServerSide() then return end
    if not isCowHusbandry(placeable) then return end

    local strawSpec = placeable.spec_husbandryStraw
    if strawSpec == nil or strawSpec.outputFillType == nil then return end

    local depth = getPackDepth(placeable)
    if depth <= 0 then
        log("muck-out: pack already empty, nothing to release")
        return
    end

    placeable:addHusbandryFillLevelFromTool(
        placeable:getOwnerFarmId(), depth, strawSpec.outputFillType, nil, nil, nil)
    setPackDepth(placeable, 0)
    log("muck-out: released %.0f L of manure from shed", depth)

    if AnimalWaste.isMultiplayerHost() then
        AnimalWastePackEvent.broadcastPack(placeable, 0)
    end
end


-- Client-side: store a pack depth pushed from the server. Display only; the
-- client never simulates the pack.
function AnimalWaste.applyPackSync(placeable, liters)
    setPackDepth(placeable, liters)
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
    if not isCowHusbandry(self) then return end

    local husbandrySpec = self.spec_husbandry
    if husbandrySpec == nil then return end

    local M = AnimalWaste.multiplier or 1
    -- The base updateProduction stored this hour's foodFactor here; it is the
    -- same value vanilla used to size the 1x manure/slurry we are scaling.
    local foodFactor = husbandrySpec.productionFactor
    local timeAdjustment = g_currentMission.environment.timeAdjustment

    -- Multiplier path (unchanged): top up the extra (M-1)x of manure and slurry
    -- straight to storage. Only runs above 1x and only with real production this
    -- hour -- exactly as before this feature existed.
    if M > 1 and foodFactor ~= nil and foodFactor > 0 then
        addExtraManure(self, M, foodFactor, timeAdjustment)
        addExtraLiquidManure(self, M, foodFactor, timeAdjustment)
    end

    -- Deep Litter path: while ON, divert the shed's solid manure (the vanilla 1x
    -- plus any multiplier extra just added above) into the per-shed pack instead
    -- of leaving it as loadable manure. Slurry is untouched and flows normally.
    -- Independent of M, so the pack accumulates at 1x too. No-op when OFF, which
    -- is the default -- so OFF behaviour is identical to the live mod.
    if AnimalWaste.deepLitterEnabled then
        AnimalWaste.divertManureToPack(self)
    end
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

    -- Guaranteed muck-out trigger for testing, independent of the menu button.
    if addConsoleCommand ~= nil then
        addConsoleCommand("awMuckOut", "Deep Litter: muck out all owned cow sheds",
            "consoleMuckOut", AnimalWaste)
    end

    log("v%s loaded, multiplier=%sx, deep litter %s", AnimalWaste.VERSION,
        tostring(AnimalWaste.multiplier), AnimalWaste.deepLitterEnabled and "ON" or "OFF")
end


-- ---------------------------------------------------------------------
-- Persistence: {savegameDirectory}/animalWaste.xml
-- Schema (version 2):
--   <animalWaste version="2">
--     <husbandryProductionRate state="N"/>   N = 1-based index into values[]
--     <deepLitter state="N"/>                N = 1 (Off) or 2 (On)
--     <packs>
--       <pack uniqueId="..." liters="123.4"/>   per cow shed with a pack
--     </packs>
--   </animalWaste>
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

    setXMLInt(xml, "animalWaste#version", 2)
    for name, setting in pairs(AnimalWaste.SETTINGS) do
        setXMLInt(xml, "animalWaste." .. name .. "#state", setting.state or setting.default)
    end

    -- Per-shed Deep Litter packs, keyed by the placeable's stable uniqueId.
    local i = 0
    forEachCowHusbandry(function(placeable)
        local uid = placeable.uniqueId
        local depth = getPackDepth(placeable)
        if uid ~= nil and depth ~= nil and depth > 0 then
            local key = string.format("animalWaste.packs.pack(%d)", i)
            setXMLString(xml, key .. "#uniqueId", uid)
            setXMLFloat(xml, key .. "#liters", depth)
            i = i + 1
        end
    end)

    saveXMLFile(xml)
    delete(xml)
    log("settings saved to %s (%d pack(s))", path, i)
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

    -- Per-shed packs are stashed by uniqueId and applied lazily once the
    -- husbandries exist (see getPackDepth) -- placeables are not yet loaded here.
    AnimalWaste.pendingPacks = {}
    local i, restored = 0, 0
    while true do
        local key = string.format("animalWaste.packs.pack(%d)", i)
        if not hasXMLProperty(xml, key) then break end
        local uid = getXMLString(xml, key .. "#uniqueId")
        local liters = getXMLFloat(xml, key .. "#liters")
        if uid ~= nil and liters ~= nil then
            AnimalWaste.pendingPacks[uid] = liters
            restored = restored + 1
        end
        i = i + 1
    end

    delete(xml)
    log("settings loaded from %s (%d pack(s) pending restore)", path, restored)
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

    for _, entry in ipairs(AnimalWaste.orderedSettings()) do
        local name, setting = entry.name, entry.setting
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
    -- their menus track ours. The event carries every setting's current state, so
    -- a change to either the multiplier or the Deep Litter toggle syncs both. The
    -- host gate makes this a no-op in SP and on clients (clients are read-only).
    if AnimalWaste.isMultiplayerHost() then
        AnimalWasteSettingsEvent.broadcast()
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


-- True wherever the simulation runs: single-player, or the server in MP (host or
-- dedicated). The pack and muck-out are server-authoritative, so all mutation is
-- gated on this; a client routes its intent through an event instead.
function AnimalWaste.isServerSide()
    return g_currentMission ~= nil
        and g_currentMission.getIsServer ~= nil
        and g_currentMission:getIsServer()
end


-- Apply one setting's synced state and refresh its menu row, if built.
local function applyOneSyncedSetting(name, state)
    local setting = AnimalWaste.SETTINGS[name]
    if setting == nil then return end
    if state == nil or state < 1 or state > #setting.values then return end

    setting.state = state
    if setting.callback then
        setting.callback(name, setting.values[state])  -- updates multiplier / toggle
    end
    -- setState without forceEvent does not re-fire onSettingChanged, so there is
    -- no echo loop back to the host.
    if setting.element ~= nil then
        setting.element:setState(state)
    end
end


-- Client-side: apply states pushed from the server. Clients never re-broadcast.
function AnimalWaste:applySyncedSettings(rateState, deepLitterState)
    applyOneSyncedSetting("husbandryProductionRate", rateState)
    applyOneSyncedSetting("deepLitter", deepLitterState)
    log("settings synced: %sx, deep litter %s",
        tostring(AnimalWaste.multiplier),
        AnimalWaste.deepLitterEnabled and "ON" or "OFF")
end


-- ---------------------------------------------------------------------
-- Muck-out trigger (animals menu button + console command)
-- ---------------------------------------------------------------------

-- Perform (server) or request (client) a muck-out for one shed.
function AnimalWaste.requestMuckOut(placeable)
    if placeable == nil then return end
    if AnimalWaste.isServerSide() then
        AnimalWaste.muckOutShed(placeable)
    else
        AnimalWastePackEvent.requestMuckOut(placeable)
    end
end


-- The husbandry currently shown in the animals menu, if we can determine it and
-- it is a cow shed. Returns nil otherwise (the caller falls back to all sheds).
function AnimalWaste.getSelectedHusbandry()
    local frame = AnimalWaste._animalsFrame
    if frame == nil then return nil end
    local candidate = frame.husbandry or frame.currentHusbandry or frame.selectedHusbandry
    if candidate ~= nil and isCowHusbandry(candidate) then
        return candidate
    end
    return nil
end


-- Animals-menu "Muck out shed" button. Mucks out the shed currently in view if
-- we can identify it; otherwise every cow shed the farm owns (Phase 1 -- per-shed
-- targeting from inside the pen arrives with the in-shed trigger later).
function AnimalWaste.onMuckOutButton()
    local target = AnimalWaste.getSelectedHusbandry()
    if target ~= nil then
        AnimalWaste.requestMuckOut(target)
        return
    end
    forEachCowHusbandry(function(placeable)
        AnimalWaste.requestMuckOut(placeable)
    end)
end


-- Add the "Muck out shed" button to the animals menu. Written defensively: if
-- the frame's button API is not shaped as expected on this game build it logs
-- and bows out rather than risking a menu crash. Reuse the console command
-- (awMuckOut) as a guaranteed alternative trigger.
function AnimalWaste.installAnimalsMenuButton(frame)
    if frame == nil then return end
    if frame.menuButtonInfo == nil or frame.setMenuButtonInfoDirty == nil then
        return  -- unexpected frame shape; console command still works
    end
    if InputAction == nil or InputAction.MENU_EXTRA_2 == nil then return end

    -- Skip if our button is already in the current list. Tagging and scanning
    -- (rather than a per-frame flag) stays correct whether the frame rebuilds its
    -- button list on each open or keeps it -- no duplicates, never disappears.
    for _, info in ipairs(frame.menuButtonInfo) do
        if info.awMuckOut then return end
    end

    table.insert(frame.menuButtonInfo, {
        awMuckOut   = true,
        profile     = "buttonActivate",
        inputAction = InputAction.MENU_EXTRA_2,
        text        = g_i18n:getText("aw_muckout_button"),
        callback    = function() AnimalWaste.onMuckOutButton() end,
    })
    frame:setMenuButtonInfoDirty()
end


-- Console command: muck out every cow shed the farm owns. Server-only (mirrors
-- the server-authoritative button path); a reliable test trigger regardless of
-- the menu-button hook.
function AnimalWaste:consoleMuckOut()
    if not AnimalWaste.isServerSide() then
        return "AnimalWaste: muck-out must run on the host/server."
    end
    local sheds, released = 0, 0
    forEachCowHusbandry(function(placeable)
        local before = getPackDepth(placeable)
        AnimalWaste.muckOutShed(placeable)
        released = released + before
        sheds = sheds + 1
    end)
    return string.format("AnimalWaste: mucked out %d cow shed(s), released %.0f L of manure.",
        sheds, released)
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

-- Animals menu: add the "Muck out shed" button each time the frame opens.
-- appendedFunction runs after the frame has built its own buttons, so we just
-- append ours. Guarded inside installAnimalsMenuButton against API differences.
if InGameMenuAnimalsFrame ~= nil and InGameMenuAnimalsFrame.onFrameOpen ~= nil then
    InGameMenuAnimalsFrame.onFrameOpen = Utils.appendedFunction(
        InGameMenuAnimalsFrame.onFrameOpen,
        function(self)
            AnimalWaste._animalsFrame = self
            AnimalWaste.installAnimalsMenuButton(self)
        end)
else
    Logging.warning("[%s] InGameMenuAnimalsFrame.onFrameOpen missing; muck-out menu button unavailable (use the awMuckOut console command)",
                    AnimalWaste.MOD_NAME)
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
            -- Push both settings, then the current pack depth of every cow shed,
            -- so the joining client's menu and pack values match the host.
            AnimalWasteSettingsEvent.sendToClient(connection)
            forEachCowHusbandry(function(placeable)
                AnimalWastePackEvent.sendPackToClient(connection, placeable, getPackDepth(placeable))
            end)
        end)
else
    Logging.error("[%s] FSBaseMission.onConnectionFinishedLoading missing; MP join-sync disabled",
                  AnimalWaste.MOD_NAME)
end

addModEventListener(AnimalWaste)
