-- AnimalWastePackEvent
--
-- Multiplayer sync for the Deep Litter "pack" (the per-shed accumulation of
-- solid muck). Two directions share one event, distinguished by a kind byte:
--
--   * KIND_SYNC    - server -> client. Pushes a shed's current pack depth so
--                    the client's copy of the husbandry tracks the host. Sent
--                    on join (one client) and whenever the pack changes
--                    (all clients).
--   * KIND_MUCKOUT - client -> server. A muck-out request for one shed. The
--                    simulation is server-authoritative: the client never
--                    mutates the pack or the manure store itself, it only asks
--                    the host to. The host performs the muck-out and then sends
--                    a KIND_SYNC back out.
--
-- The shed is identified over the wire by its network object id; both ends
-- resolve it with NetworkUtil. Registered with the engine via InitEventClass
-- at the bottom of this file.

AnimalWastePackEvent = {}
local AnimalWastePackEvent_mt = Class(AnimalWastePackEvent, Event)

AnimalWastePackEvent.KIND_SYNC    = 0  -- server -> client: pack depth update
AnimalWastePackEvent.KIND_MUCKOUT = 1  -- client -> server: muck-out request

-- Distinct prefix so MP traffic is easy to grep in the log during testing.
local function logMP(fmt, ...)
    print(("[AnimalWaste MP] " .. fmt):format(...))
end


function AnimalWastePackEvent.emptyNew()
    return Event.new(AnimalWastePackEvent_mt)
end


-- kind: one of KIND_SYNC / KIND_MUCKOUT.
-- placeable: the husbandry the event is about.
-- liters: pack depth, only meaningful for KIND_SYNC.
function AnimalWastePackEvent.new(kind, placeable, liters)
    local self = AnimalWastePackEvent.emptyNew()
    self.kind = kind
    self.placeable = placeable
    self.liters = liters or 0
    return self
end


function AnimalWastePackEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.kind)
    streamWriteInt32(streamId, NetworkUtil.getObjectId(self.placeable))
    if self.kind == AnimalWastePackEvent.KIND_SYNC then
        streamWriteFloat32(streamId, self.liters)
    end
end


function AnimalWastePackEvent:readStream(streamId, connection)
    self.kind = streamReadUInt8(streamId)
    local objectId = streamReadInt32(streamId)
    self.placeable = NetworkUtil.getObject(objectId)
    if self.kind == AnimalWastePackEvent.KIND_SYNC then
        self.liters = streamReadFloat32(streamId)
    end
    self:run(connection)
end


-- Runs on the receiving end.
function AnimalWastePackEvent:run(connection)
    if self.placeable == nil then
        -- The object may not be replicated on this peer yet; nothing to do.
        return
    end

    if self.kind == AnimalWastePackEvent.KIND_MUCKOUT then
        -- Received on the SERVER from a client. muckOutShed is server-gated and
        -- broadcasts the resulting (zero) pack value back out to clients itself.
        logMP("server received muck-out request for a shed")
        AnimalWaste.muckOutShed(self.placeable)
    else
        -- Received on a CLIENT from the server: just store the synced depth.
        AnimalWaste.applyPackSync(self.placeable, self.liters)
    end
end


-- Host -> all clients (pack changed). Caller must already be the host.
-- sendLocalEvent=false: the host has already updated its own pack value.
function AnimalWastePackEvent.broadcastPack(placeable, liters)
    if g_server == nil then return end
    g_server:broadcastEvent(
        AnimalWastePackEvent.new(AnimalWastePackEvent.KIND_SYNC, placeable, liters), false)
end


-- Server -> one client (join sync). Caller must already be the host.
function AnimalWastePackEvent.sendPackToClient(connection, placeable, liters)
    connection:sendEvent(
        AnimalWastePackEvent.new(AnimalWastePackEvent.KIND_SYNC, placeable, liters))
end


-- Client -> server (muck-out request). Caller must be an MP client.
function AnimalWastePackEvent.requestMuckOut(placeable)
    if g_client == nil then return end
    logMP("client requesting muck-out from server")
    g_client:getServerConnection():sendEvent(
        AnimalWastePackEvent.new(AnimalWastePackEvent.KIND_MUCKOUT, placeable, 0))
end


InitEventClass(AnimalWastePackEvent, "AnimalWastePackEvent")
