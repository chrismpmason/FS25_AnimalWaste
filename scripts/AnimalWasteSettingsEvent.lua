-- AnimalWasteSettingsEvent
--
-- Multiplayer sync for the AnimalWaste settings. The event carries the 1-based
-- state index of every host-authoritative setting:
--   * husbandryProductionRate - the manure/slurry multiplier
--   * deepLitter               - the Deep Litter ON/OFF toggle
-- These are the same values persisted in animalWaste.xml. Only the host ever
-- changes a setting; this event pushes the current values out to clients so
-- their menu shows the right state:
--   * join sync   - server -> one client, when that client finishes loading
--   * change sync - host   -> all clients, when the host changes any setting
--
-- The simulation (manure / straw scaling, pack accumulation) runs on the server
-- only; this event is purely about getting the displayed values onto clients.
-- Per-shed pack depth is synced separately by AnimalWastePackEvent. Registered
-- with the engine via InitEventClass at the bottom of this file.

AnimalWasteSettingsEvent = {}
local AnimalWasteSettingsEvent_mt = Class(AnimalWasteSettingsEvent, Event)

-- Distinct prefix so MP traffic is easy to grep in the log during testing.
local function logMP(fmt, ...)
    print(("[AnimalWaste MP] " .. fmt):format(...))
end

-- Current 1-based state of a setting, falling back to its default.
local function settingState(name)
    local setting = AnimalWaste ~= nil and AnimalWaste.SETTINGS ~= nil
        and AnimalWaste.SETTINGS[name]
    if setting ~= nil then
        return setting.state or setting.default or 1
    end
    return 1
end


function AnimalWasteSettingsEvent.emptyNew()
    return Event.new(AnimalWasteSettingsEvent_mt)
end


-- rateState:       1-based index into husbandryProductionRate.values.
-- deepLitterState: 1-based index into deepLitter.values (1 = Off, 2 = On).
function AnimalWasteSettingsEvent.new(rateState, deepLitterState)
    local self = AnimalWasteSettingsEvent.emptyNew()
    self.rateState = rateState
    self.deepLitterState = deepLitterState
    return self
end


function AnimalWasteSettingsEvent:writeStream(streamId, connection)
    -- Both are small bounded indices; a UInt8 each keeps the packet tiny.
    streamWriteUInt8(streamId, self.rateState)
    streamWriteUInt8(streamId, self.deepLitterState)
end


function AnimalWasteSettingsEvent:readStream(streamId, connection)
    self.rateState = streamReadUInt8(streamId)
    self.deepLitterState = streamReadUInt8(streamId)
    self:run(connection)
end


-- Runs on the receiving end. Only the server ever sends this event, so in
-- practice this only fires on clients.
function AnimalWasteSettingsEvent:run(connection)
    logMP("client received settings: rateState=%s deepLitterState=%s",
        tostring(self.rateState), tostring(self.deepLitterState))
    AnimalWaste:applySyncedSettings(self.rateState, self.deepLitterState)
end


-- Server -> one client (join sync). Caller must already be the host.
function AnimalWasteSettingsEvent.sendToClient(connection)
    local rateState = settingState("husbandryProductionRate")
    local deepLitterState = settingState("deepLitter")
    logMP("server sending join-sync to client: rateState=%s deepLitterState=%s",
        tostring(rateState), tostring(deepLitterState))
    connection:sendEvent(AnimalWasteSettingsEvent.new(rateState, deepLitterState))
end


-- Host -> all clients (change sync). Caller must already be the host.
-- sendLocalEvent=false: the host has already applied the change locally.
function AnimalWasteSettingsEvent.broadcast()
    local rateState = settingState("husbandryProductionRate")
    local deepLitterState = settingState("deepLitter")
    logMP("host broadcasting settings change: rateState=%s deepLitterState=%s",
        tostring(rateState), tostring(deepLitterState))
    g_server:broadcastEvent(AnimalWasteSettingsEvent.new(rateState, deepLitterState), false)
end


InitEventClass(AnimalWasteSettingsEvent, "AnimalWasteSettingsEvent")
