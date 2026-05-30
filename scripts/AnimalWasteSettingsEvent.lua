-- AnimalWasteSettingsEvent
--
-- Multiplayer sync for the AnimalWaste production-rate setting. The event
-- carries the 1-based state index of husbandryProductionRate -- the same value
-- persisted in animalWaste.xml. Only the host ever changes the setting; this
-- event pushes the current value out to clients so their menu shows the right
-- number:
--   * join sync   - server -> one client, when that client finishes loading
--   * change sync - host   -> all clients, when the host changes the setting
--
-- The simulation (manure / straw scaling) runs on the server only; this event
-- is purely about getting the displayed value onto clients. Registered with the
-- engine via InitEventClass at the bottom of this file.

AnimalWasteSettingsEvent = {}
local AnimalWasteSettingsEvent_mt = Class(AnimalWasteSettingsEvent, Event)

-- Distinct prefix so MP traffic is easy to grep in the log during testing.
local function logMP(fmt, ...)
    print(("[AnimalWaste MP] " .. fmt):format(...))
end

-- For logging only: turn a state index into its multiplier (1x / 2x / 3x).
local function stateToMultiplier(state)
    local setting = AnimalWaste ~= nil and AnimalWaste.SETTINGS ~= nil
        and AnimalWaste.SETTINGS.husbandryProductionRate
    if setting ~= nil and setting.values ~= nil and setting.values[state] ~= nil then
        return setting.values[state]
    end
    return "?"
end


function AnimalWasteSettingsEvent.emptyNew()
    return Event.new(AnimalWasteSettingsEvent_mt)
end


-- state: 1-based index into husbandryProductionRate.values.
function AnimalWasteSettingsEvent.new(state)
    local self = AnimalWasteSettingsEvent.emptyNew()
    self.state = state
    return self
end


function AnimalWasteSettingsEvent:writeStream(streamId, connection)
    -- Only three states today; a UInt8 is plenty and keeps the packet tiny.
    streamWriteUInt8(streamId, self.state)
end


function AnimalWasteSettingsEvent:readStream(streamId, connection)
    self.state = streamReadUInt8(streamId)
    self:run(connection)
end


-- Runs on the receiving end. Only the server ever sends this event, so in
-- practice this only fires on clients.
function AnimalWasteSettingsEvent:run(connection)
    logMP("client received setting: state=%s (%sx)",
        tostring(self.state), tostring(stateToMultiplier(self.state)))
    AnimalWaste:applySyncedState(self.state)
end


-- Server -> one client (join sync). Caller must already be the host.
function AnimalWasteSettingsEvent.sendToClient(connection, state)
    logMP("server sending join-sync to client: state=%s (%sx)",
        tostring(state), tostring(stateToMultiplier(state)))
    connection:sendEvent(AnimalWasteSettingsEvent.new(state))
end


-- Host -> all clients (change sync). Caller must already be the host.
-- sendLocalEvent=false: the host has already applied the change locally.
function AnimalWasteSettingsEvent.broadcast(state)
    logMP("host broadcasting change to clients: state=%s (%sx)",
        tostring(state), tostring(stateToMultiplier(state)))
    g_server:broadcastEvent(AnimalWasteSettingsEvent.new(state), false)
end


InitEventClass(AnimalWasteSettingsEvent, "AnimalWasteSettingsEvent")
