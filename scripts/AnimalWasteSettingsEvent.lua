-- AnimalWasteSettingsEvent
--
-- Multiplayer sync for the AnimalWaste settings. The event carries the 1-based
-- state index of every host-authoritative setting (seven in total):
--   * husbandryProductionRate - the COW manure / liquid manure output multiplier
--   * strawUsageRate           - the straw consumption multiplier (cow-only)
--   * milkUsageRate            - the milk output multiplier        (cow-only)
--   * pigWaste                 - the pig manure / slurry multiplier
--   * sheepWaste               - the sheep+goat manure multiplier
--   * horseWaste               - the horse manure multiplier
--   * chickenWaste             - the chicken manure multiplier
-- These are the same values persisted in animalWaste.xml. Only the host ever
-- changes a setting; this event pushes the current values out to clients so
-- their menu shows the right numbers:
--   * join sync   - server -> one client, when that client finishes loading
--   * change sync - host   -> all clients, when the host changes any setting
--
-- The simulation (manure / straw / milk scaling) runs on the server only; this
-- event is purely about getting the displayed values onto clients. Registered with
-- the engine via InitEventClass at the bottom of this file.

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


-- rateState:    1-based index into husbandryProductionRate.values.
-- strawState:   1-based index into strawUsageRate.values.
-- milkState:    1-based index into milkUsageRate.values.
-- pigState:     1-based index into pigWaste.values.
-- sheepState:   1-based index into sheepWaste.values (covers goats).
-- horseState:   1-based index into horseWaste.values.
-- chickenState: 1-based index into chickenWaste.values.
function AnimalWasteSettingsEvent.new(rateState, strawState, milkState,
                                      pigState, sheepState, horseState, chickenState)
    local self = AnimalWasteSettingsEvent.emptyNew()
    self.rateState = rateState
    self.strawState = strawState
    self.milkState = milkState
    self.pigState = pigState
    self.sheepState = sheepState
    self.horseState = horseState
    self.chickenState = chickenState
    return self
end


function AnimalWasteSettingsEvent:writeStream(streamId, connection)
    -- All small bounded indices; a UInt8 each keeps the packet tiny.
    streamWriteUInt8(streamId, self.rateState)
    streamWriteUInt8(streamId, self.strawState)
    streamWriteUInt8(streamId, self.milkState)
    streamWriteUInt8(streamId, self.pigState)
    streamWriteUInt8(streamId, self.sheepState)
    streamWriteUInt8(streamId, self.horseState)
    streamWriteUInt8(streamId, self.chickenState)
end


function AnimalWasteSettingsEvent:readStream(streamId, connection)
    -- Read in the SAME order writeStream wrote: rate, straw, milk, pig, sheep,
    -- horse, chicken.
    self.rateState = streamReadUInt8(streamId)
    self.strawState = streamReadUInt8(streamId)
    self.milkState = streamReadUInt8(streamId)
    self.pigState = streamReadUInt8(streamId)
    self.sheepState = streamReadUInt8(streamId)
    self.horseState = streamReadUInt8(streamId)
    self.chickenState = streamReadUInt8(streamId)
    self:run(connection)
end


-- Runs on the receiving end. Only the server ever sends this event, so in
-- practice this only fires on clients.
function AnimalWasteSettingsEvent:run(connection)
    logMP("client received settings: rate=%s straw=%s milk=%s pig=%s sheep=%s horse=%s chicken=%s",
        tostring(self.rateState), tostring(self.strawState), tostring(self.milkState),
        tostring(self.pigState), tostring(self.sheepState), tostring(self.horseState),
        tostring(self.chickenState))
    AnimalWaste:applySyncedSettings(self.rateState, self.strawState, self.milkState,
        self.pigState, self.sheepState, self.horseState, self.chickenState)
end


-- Snapshot all seven host-authoritative states in the canonical order the
-- constructor / stream expect.
local function currentStates()
    return settingState("husbandryProductionRate"),
           settingState("strawUsageRate"),
           settingState("milkUsageRate"),
           settingState("pigWaste"),
           settingState("sheepWaste"),
           settingState("horseWaste"),
           settingState("chickenWaste")
end


-- Server -> one client (join sync). Caller must already be the host.
function AnimalWasteSettingsEvent.sendToClient(connection)
    local rateState, strawState, milkState, pigState, sheepState, horseState, chickenState = currentStates()
    logMP("server sending join-sync to client: rate=%s straw=%s milk=%s pig=%s sheep=%s horse=%s chicken=%s",
        tostring(rateState), tostring(strawState), tostring(milkState),
        tostring(pigState), tostring(sheepState), tostring(horseState), tostring(chickenState))
    connection:sendEvent(AnimalWasteSettingsEvent.new(rateState, strawState, milkState,
        pigState, sheepState, horseState, chickenState))
end


-- Host -> all clients (change sync). Caller must already be the host.
-- sendLocalEvent=false: the host has already applied the change locally.
function AnimalWasteSettingsEvent.broadcast()
    local rateState, strawState, milkState, pigState, sheepState, horseState, chickenState = currentStates()
    logMP("host broadcasting settings change: rate=%s straw=%s milk=%s pig=%s sheep=%s horse=%s chicken=%s",
        tostring(rateState), tostring(strawState), tostring(milkState),
        tostring(pigState), tostring(sheepState), tostring(horseState), tostring(chickenState))
    g_server:broadcastEvent(AnimalWasteSettingsEvent.new(rateState, strawState, milkState,
        pigState, sheepState, horseState, chickenState), false)
end


InitEventClass(AnimalWasteSettingsEvent, "AnimalWasteSettingsEvent")
