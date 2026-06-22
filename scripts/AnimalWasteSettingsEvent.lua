-- AnimalWasteSettingsEvent
--
-- Multiplayer sync for the AnimalWaste production-rate setting. The event
-- carries the 1-based state index of husbandryProductionRate -- the same value
-- persisted in animalWaste.xml -- plus an isRequest flag distinguishing the two
-- directions it now travels:
--   * SYNC (isRequest=false), server -> client:
--       - join sync   - server -> one client, when that client finishes loading
--       - change sync - server -> all clients, when the value changes
--   * REQUEST (isRequest=true), admin client -> server:
--       - an admin (master user) on a client -- notably the admin on a DEDICATED
--         server, where nobody is the host -- asks the server to change the
--         value. The server re-verifies the sender is a genuine master user
--         before applying, then persists and broadcasts the SYNC back out.
--
-- The simulation (manure / straw scaling) and the savegame live on the server,
-- so the server is always the authority: clients can only request, never apply.
-- Registered with the engine via InitEventClass at the bottom of this file.

AnimalWasteSettingsEvent = {}
local AnimalWasteSettingsEvent_mt = Class(AnimalWasteSettingsEvent, Event)

-- Distinct prefix so MP traffic is easy to grep in the log during testing.
local function logMP(fmt, ...)
    print(("[AnimalWaste MP] " .. fmt):format(...))
end

-- For logging only: turn a state index into its multiplier (1x / 2x / 3x / 5x / 10x).
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


-- state:     1-based index into husbandryProductionRate.values.
-- isRequest: true  => admin client -> server change request (server verifies),
--            false => server -> client sync (default).
function AnimalWasteSettingsEvent.new(state, isRequest)
    local self = AnimalWasteSettingsEvent.emptyNew()
    self.state = state
    self.isRequest = isRequest == true
    return self
end


function AnimalWasteSettingsEvent:writeStream(streamId, connection)
    -- Five states today (1/2/3/5/10x); a UInt8 is plenty and keeps the packet tiny.
    streamWriteUInt8(streamId, self.state)
    streamWriteBool(streamId, self.isRequest == true)
end


function AnimalWasteSettingsEvent:readStream(streamId, connection)
    self.state = streamReadUInt8(streamId)
    self.isRequest = streamReadBool(streamId)
    self:run(connection)
end


-- Runs on the receiving end.
--   * A REQUEST is received on the SERVER from an admin client: connection
--     points to a client, so connection:getIsServer() is false. The server
--     re-verifies the sender's admin rights before applying.
--   * A SYNC is received on a CLIENT from the server: connection:getIsServer()
--     is true; the client just displays the authoritative value.
function AnimalWasteSettingsEvent:run(connection)
    if self.isRequest then
        if connection:getIsServer() then
            -- A request should only ever arrive on the server; ignore if not.
            return
        end
        AnimalWaste.handleAdminChangeRequest(connection, self.state)
    else
        logMP("client received setting: state=%s (%sx)",
            tostring(self.state), tostring(stateToMultiplier(self.state)))
        AnimalWaste:applySyncedState(self.state)
    end
end


-- Server -> one client (join sync). Caller must already be the host.
function AnimalWasteSettingsEvent.sendToClient(connection, state)
    logMP("server sending join-sync to client: state=%s (%sx)",
        tostring(state), tostring(stateToMultiplier(state)))
    connection:sendEvent(AnimalWasteSettingsEvent.new(state))
end


-- Host/server -> all clients (change sync). Caller must already be the server.
-- sendLocalEvent=false: the server has already applied the change locally.
function AnimalWasteSettingsEvent.broadcast(state)
    logMP("server broadcasting change to clients: state=%s (%sx)",
        tostring(state), tostring(stateToMultiplier(state)))
    g_server:broadcastEvent(AnimalWasteSettingsEvent.new(state), false)
end


-- Admin client -> server (change request). The local control is only enabled
-- for the server or an admin (see AnimalWaste.isSettingEditable), but the SERVER
-- is the real gate: it re-verifies master-user rights in handleAdminChangeRequest
-- before trusting this. Caller must be a client (g_client present).
function AnimalWasteSettingsEvent.sendChangeRequest(state)
    if g_client == nil then return end
    logMP("admin client requesting change from server: state=%s (%sx)",
        tostring(state), tostring(stateToMultiplier(state)))
    g_client:getServerConnection():sendEvent(AnimalWasteSettingsEvent.new(state, true))
end


InitEventClass(AnimalWasteSettingsEvent, "AnimalWasteSettingsEvent")
