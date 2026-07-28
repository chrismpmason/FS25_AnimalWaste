-- AnimalWasteSettingsEvent
--
-- Multiplayer sync for the AnimalWaste settings. The event carries the 1-based
-- state index of every server-authoritative setting (seven in total):
--   * husbandryProductionRate - the COW manure / liquid manure output multiplier
--   * strawUsageRate           - the straw consumption multiplier (cow-only)
--   * milkUsageRate            - the milk output multiplier        (cow-only)
--   * pigWaste                 - the pig manure / slurry multiplier
--   * sheepWaste               - the sheep+goat manure multiplier
--   * horseWaste               - the horse manure multiplier
--   * chickenWaste             - the chicken manure multiplier
-- These are the same values persisted in animalWaste.xml, and the event now
-- travels in BOTH directions, distinguished by an isRequest flag:
--
--   * SYNC (isRequest=false), server -> client:
--       - join sync   - server -> one client, when that client finishes loading
--       - change sync - server -> all clients, when any value changes
--   * REQUEST (isRequest=true), admin client -> server:
--       - an admin (master user) on a client -- notably the admin on a DEDICATED
--         server, where nobody is the host -- asks the server to change the
--         values. The server re-verifies the sender is a genuine master user
--         before applying, then persists and broadcasts the SYNC back out.
--
-- The simulation (manure / straw / milk scaling) and the savegame live on the
-- server, so the server is always the authority: clients can only request, never
-- apply. Registered with the engine via InitEventClass at the bottom of this file.

AnimalWasteSettingsEvent = {}
local AnimalWasteSettingsEvent_mt = Class(AnimalWasteSettingsEvent, Event)

-- Canonical wire order. writeStream and readStream both iterate THIS list, so the
-- two can never drift out of step, and adding a setting is a one-line change here
-- (plus the SETTINGS entry in AnimalWaste.lua). States travel as a name-keyed
-- table; this list is the only thing that knows about ordering.
local ORDERED_NAMES = {
    "husbandryProductionRate",
    "strawUsageRate",
    "milkUsageRate",
    "pigWaste",
    "sheepWaste",
    "horseWaste",
    "chickenWaste",
}

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


-- Snapshot all seven server-authoritative states as a name-keyed table.
local function currentStates()
    local states = {}
    for _, name in ipairs(ORDERED_NAMES) do
        states[name] = settingState(name)
    end
    return states
end


-- "rate=1 straw=3 milk=1 ..." for the log lines below.
local function describe(states)
    local parts = {}
    for i, name in ipairs(ORDERED_NAMES) do
        parts[i] = ("%s=%s"):format(name, tostring(states ~= nil and states[name] or "nil"))
    end
    return table.concat(parts, " ")
end


function AnimalWasteSettingsEvent.emptyNew()
    return Event.new(AnimalWasteSettingsEvent_mt)
end


-- states:    name-keyed table of 1-based indices, one per ORDERED_NAMES entry.
-- isRequest: true  => admin client -> server change request (server verifies),
--            false => server -> client sync (default).
function AnimalWasteSettingsEvent.new(states, isRequest)
    local self = AnimalWasteSettingsEvent.emptyNew()
    self.states = states or {}
    self.isRequest = isRequest == true
    return self
end


function AnimalWasteSettingsEvent:writeStream(streamId, connection)
    -- All small bounded indices; a UInt8 each keeps the packet tiny. Missing
    -- entries fall back to 1 rather than erroring mid-write and killing the packet.
    for _, name in ipairs(ORDERED_NAMES) do
        streamWriteUInt8(streamId, self.states[name] or 1)
    end
    streamWriteBool(streamId, self.isRequest == true)
end


function AnimalWasteSettingsEvent:readStream(streamId, connection)
    -- Same ORDERED_NAMES loop writeStream used, so the order cannot drift.
    self.states = {}
    for _, name in ipairs(ORDERED_NAMES) do
        self.states[name] = streamReadUInt8(streamId)
    end
    self.isRequest = streamReadBool(streamId)
    self:run(connection)
end


-- Runs on the receiving end.
--   * A REQUEST is received on the SERVER from an admin client: connection points
--     to a client, so connection:getIsServer() is false. The server re-verifies
--     the sender's admin rights before applying.
--   * A SYNC is received on a CLIENT from the server: connection:getIsServer() is
--     true; the client just displays the authoritative values.
function AnimalWasteSettingsEvent:run(connection)
    if self.isRequest then
        if connection:getIsServer() then
            -- A request should only ever arrive on the server; ignore if not.
            return
        end
        logMP("server received change REQUEST from client: %s", describe(self.states))
        AnimalWaste.handleAdminChangeRequest(connection, self.states)
    else
        logMP("client received settings SYNC: %s", describe(self.states))
        AnimalWaste:applySyncedSettings(self.states)
    end
end


-- Server -> one client (join sync). Caller must already be the server.
function AnimalWasteSettingsEvent.sendToClient(connection)
    local states = currentStates()
    logMP("server sending join-sync to client: %s", describe(states))
    connection:sendEvent(AnimalWasteSettingsEvent.new(states, false))
end


-- Server -> all clients (change sync). Caller must already be the server.
-- sendLocalEvent=false: the server has already applied the change locally.
function AnimalWasteSettingsEvent.broadcast()
    local states = currentStates()
    logMP("server broadcasting settings change: %s", describe(states))
    g_server:broadcastEvent(AnimalWasteSettingsEvent.new(states, false), false)
end


-- Admin client -> server (change request). The local control is only enabled for
-- the server or an admin (see AnimalWaste.isSettingEditable), but the SERVER is
-- the real gate: it re-verifies master-user rights in handleAdminChangeRequest
-- before trusting this. Caller must be a client (g_client present).
--
-- The whole snapshot goes over the wire, not just the slider that moved: the
-- client's other six values came from the server's own join/change sync, so
-- echoing them back is idempotent, and it keeps this packet identical in shape to
-- the sync direction.
function AnimalWasteSettingsEvent.sendChangeRequest()
    if g_client == nil then return end
    local states = currentStates()
    logMP("admin client requesting change from server: %s", describe(states))
    g_client:getServerConnection():sendEvent(AnimalWasteSettingsEvent.new(states, true))
end


InitEventClass(AnimalWasteSettingsEvent, "AnimalWasteSettingsEvent")
