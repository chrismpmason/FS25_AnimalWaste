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

-- Per-hour diagnostic logging. OFF by default so normal play stays quiet (the
-- hourly capture/append traces fire once per shed per in-game hour). Flip to
-- true only when chasing a timing/capture issue. One-off logs (hooks installed,
-- settings saved/loaded, deep litter ON/OFF, muck-out released) ignore this and
-- always print.
AnimalWaste.DEBUG = false

-- ---------------------------------------------------------------------
-- Deep Litter visual (Phase 2): the rising muck mesh.
--
-- A shed opts in by including a node named EXACTLY AW_MUCK_PLANE_NODE in its
-- i3d (authored as a sibling of the vanilla strawPlanes group). We drive that
-- node's local Y from the pack value, mirroring the vanilla strawPlane rise.
-- Both numbers are deliberately exposed here for live tuning.
-- ---------------------------------------------------------------------
AnimalWaste.AW_MUCK_PLANE_NODE  = "AW_muckPlane"  -- exact node name searched per shed
AnimalWaste.AW_MUCK_FULL_PACK   = 20000           -- litres of pack that = full height
AnimalWaste.AW_MUCK_FULL_HEIGHT = 0.10            -- metres risen above rest at full pack

-- Must be declared before SETTINGS (FS25 has a global `log` with
-- different semantics that the callback closure would otherwise bind to).
local function log(fmt, ...)
    print(("[%s] " .. fmt):format(AnimalWaste.MOD_NAME, ...))
end

-- Gated logger for the noisy per-hour traces. No-op unless AnimalWaste.DEBUG.
local function debugLog(fmt, ...)
    if AnimalWaste.DEBUG then
        log("DEBUG " .. fmt, ...)
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

-- Run fn(placeable) for every ANIMAL husbandry (any species), so diagnostics can
-- report a shed even when our cow-detection is what's failing.
local function forEachAnimalHusbandry(fn)
    local ps = g_currentMission and g_currentMission.placeableSystem
    if ps == nil or ps.placeables == nil then return end
    for _, placeable in ipairs(ps.placeables) do
        if placeable.spec_husbandryAnimals ~= nil then
            fn(placeable)
        end
    end
end


-- ---------------------------------------------------------------------
-- Nearest-shed targeting (used by the awAddManure test command)
-- ---------------------------------------------------------------------

-- The local player's world position, whether on foot or in a vehicle. Returns
-- x, y, z or nil if it can't be read (caller then falls back to the first shed).
-- pcall-guarded so an API difference can never crash the console command.
local function getPlayerWorldPosition()
    if g_localPlayer == nil then return nil end

    -- In a vehicle: the player node tracks the seat, so use the vehicle root.
    if g_localPlayer.getCurrentVehicle ~= nil then
        local veh = g_localPlayer:getCurrentVehicle()
        if veh ~= nil and veh.rootNode ~= nil then
            local ok, x, y, z = pcall(getWorldTranslation, veh.rootNode)
            if ok and x ~= nil then return x, y, z end
        end
    end

    if g_localPlayer.getPosition ~= nil then
        local ok, x, y, z = pcall(function() return g_localPlayer:getPosition() end)
        if ok and x ~= nil then return x, y, z end
    end
    return nil
end

-- A placeable's world position via its root node. Returns x, y, z or nil.
local function getPlaceableWorldPosition(placeable)
    local node = placeable.rootNode
    if node == nil and placeable.getRootNode ~= nil then
        node = placeable:getRootNode()
    end
    if node == nil then return nil end
    local ok, x, y, z = pcall(getWorldTranslation, node)
    if ok and x ~= nil then return x, y, z end
    return nil
end

-- The cow husbandry nearest the player (2D distance, height ignored). Returns
-- nil if the player position is unreadable or no cow shed has a usable position,
-- so the caller can fall back to the first cow shed.
local function findNearestCowHusbandry()
    local px, _, pz = getPlayerWorldPosition()
    if px == nil then return nil end

    local best, bestDist
    forEachAnimalHusbandry(function(placeable)
        if not isCowHusbandry(placeable) then return end
        local hx, _, hz = getPlaceableWorldPosition(placeable)
        if hx == nil then return end
        local dx, dz = hx - px, hz - pz
        local dist = dx * dx + dz * dz  -- squared distance is fine for comparison
        if bestDist == nil or dist < bestDist then
            bestDist, best = dist, placeable
        end
    end)
    return best
end

-- The first cow husbandry in placeable order. Fallback when nearest-targeting
-- can't read a position.
local function firstCowHusbandry()
    local first
    forEachAnimalHusbandry(function(placeable)
        if first == nil and isCowHusbandry(placeable) then
            first = placeable
        end
    end)
    return first
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
-- Returns the litres of manure removed from the store and moved into the pack.
function AnimalWaste.divertManureToPack(placeable)
    local strawSpec = placeable.spec_husbandryStraw
    if strawSpec == nil or strawSpec.outputFillType == nil then return 0 end

    -- removeHusbandryFillLevel returns the portion it could NOT remove, so a
    -- request far larger than any shed can hold makes (request - returned) equal
    -- exactly the manure that was in the store. This is the same function and
    -- return convention the multiplier path already relies on for straw.
    local farmId  = placeable:getOwnerFarmId()
    local REQUEST = 1e9
    local notRemoved = placeable:removeHusbandryFillLevel(farmId, REQUEST, strawSpec.outputFillType)
    if notRemoved == nil then return 0 end

    local removed = REQUEST - notRemoved
    if removed > 0 then
        AnimalWaste.addToPack(placeable, removed)
    end
    return removed
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
    AnimalWaste.updateMuckPlane(placeable)  -- drop the visual back to rest as the pack zeroes
    log("muck-out: released %.0f L of manure from shed", depth)

    if AnimalWaste.isMultiplayerHost() then
        AnimalWastePackEvent.broadcastPack(placeable, 0)
    end
end


-- Client-side: store a pack depth pushed from the server. Display only; the
-- client never simulates the pack.
function AnimalWaste.applyPackSync(placeable, liters)
    setPackDepth(placeable, liters)
    -- Visual is driven on clients too, straight off the synced pack value.
    AnimalWaste.updateMuckPlane(placeable)
end


-- ---------------------------------------------------------------------
-- Deep Litter visual: the rising "AW_muckPlane" mesh.
--
-- Opt-in per shed: a shed animates only if its i3d contains one or more nodes
-- named exactly AnimalWaste.AW_MUCK_PLANE_NODE. Multi-pen sheds (e.g.
-- cowShedScroft4) author one plane per pen; single-pen sheds author one. Sheds
-- with none are completely unaffected -- the lookup caches an empty list so the
-- tree is searched at most once and opted-out sheds cost nothing thereafter. Each
-- node's authored local translation is captured once as its rest ("empty") pose;
-- we then drive only the Y of each from the pack, by the same ratio.
-- ---------------------------------------------------------------------

-- Recursively collect EVERY descendant of `node` named exactly `name` into `out`,
-- using only core scene-graph getters (works on any game build).
local function collectChildrenByName(node, name, out)
    if node == nil or node == 0 then return end
    if getName(node) == name then out[#out + 1] = node end
    for i = 0, getNumOfChildren(node) - 1 do
        collectChildrenByName(getChildAt(node, i), name, out)
    end
end

-- Resolve (once per shed) ALL AW_muckPlane nodes and cache them on the husbandry
-- spec as a list of { node, restX, restY, restZ } (each one's authored rest
-- pose). The list is cached even when empty, so the tree is searched at most once
-- and opted-out sheds never retry. Returns the (possibly empty) list.
local function resolveMuckPlanes(placeable)
    local spec = placeable.spec_husbandry
    if spec == nil then return nil end

    if spec.awMuckPlanes == nil then
        local planes = {}
        local root = placeable.rootNode
        if root ~= nil then
            local nodes = {}
            collectChildrenByName(root, AnimalWaste.AW_MUCK_PLANE_NODE, nodes)
            for _, node in ipairs(nodes) do
                local rx, ry, rz = getTranslation(node)
                planes[#planes + 1] = { node = node, restX = rx, restY = ry, restZ = rz }
            end
        end
        spec.awMuckPlanes = planes  -- empty list = searched, none present
        -- One-off diagnostic (once per shed, on first resolve / load): how many
        -- AW_muckPlane nodes did the driver actually find in this placeable?
        log("shed %s: resolved %d muck plane(s)", tostring(placeable.uniqueId or placeable), #planes)
    end

    return spec.awMuckPlanes
end

-- Drive EVERY AW_muckPlane in a shed from its current pack, mirroring the vanilla
-- strawPlane rise: each node rises from its own authored Y by the SAME ratio --
-- newY = restY + clamp(pack / AW_MUCK_FULL_PACK, 0, 1) * AW_MUCK_FULL_HEIGHT --
-- keeping each node's authored X/Z. Visual only, so it runs on the server AND on
-- clients (clients off the synced pack). Fully graceful: a shed with no
-- AW_muckPlane node is a silent no-op. A single-plane shed drives its one node
-- exactly as before. Safe to call as often as needed.
function AnimalWaste.updateMuckPlane(placeable)
    if placeable == nil then return end
    local planes = resolveMuckPlanes(placeable)
    if planes == nil or #planes == 0 then return end  -- opted out -- unaffected

    local fullPack = AnimalWaste.AW_MUCK_FULL_PACK
    local ratio = 0
    if fullPack and fullPack > 0 then
        ratio = getPackDepth(placeable) / fullPack
        if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    end
    local rise = ratio * AnimalWaste.AW_MUCK_FULL_HEIGHT

    for _, p in ipairs(planes) do
        setTranslation(p.node, p.restX, p.restY + rise, p.restZ)
    end
end


-- Diagnostic only: human-readable fill-type name for a fill-type index.
local function fillTypeName(fillType)
    if g_fillTypeManager == nil or fillType == nil then return "?" end
    if g_fillTypeManager.getFillTypeNameByIndex ~= nil then
        local ok, name = pcall(function() return g_fillTypeManager:getFillTypeNameByIndex(fillType) end)
        if ok and name ~= nil then return name end
    end
    return "?"
end

-- Diagnostic only: independently READ the husbandry's manure level (without
-- removing it), to cross-check against what the player sees as loadable manure.
-- Probes likely getters and reports which one (if any) answered. pcall-guarded
-- so an absent / differently-shaped method can never crash the test command.
local function readManureLevel(placeable, fillType)
    if fillType == nil then return nil, "no-filltype" end
    local candidates = { "getHusbandryFillLevel", "getFillLevel" }
    for _, methodName in ipairs(candidates) do
        if placeable[methodName] ~= nil then
            local ok, val = pcall(function() return placeable[methodName](placeable, fillType) end)
            if ok and type(val) == "number" then return val, methodName end
        end
    end
    return nil, "none"
end


-- Per-hour Deep Litter capture for one cow shed. Invoked UNCONDITIONALLY from
-- the (proven-firing) onHourChanged append, so the entry log below proves both
-- that this is reached every hour AND what the toggle reads at simulation time.
-- The ON/OFF gate lives inside, AFTER the log -- nothing above it can hide a
-- run. Caller has already confirmed server + cow husbandry.
function AnimalWaste.deepLitterCaptureTick(self, currentHour)
    -- Per-hour trace (debug-gated): proves this is reached every hour and what
    -- the toggle reads at simulation time.
    debugLog("DL capture tick fired (husbandry=%s, DL=%s)",
        tostring(self.uniqueId or self),
        AnimalWaste.deepLitterEnabled and "on" or "off")

    if AnimalWaste.deepLitterEnabled then
        AnimalWaste.divertManureToPack(self)
    end

    -- Keep the rising-muck visual in step with the pack each hour (server-side;
    -- clients are driven from the synced pack in applyPackSync). Runs regardless
    -- of the toggle so the mesh stays correct, and is a no-op for sheds without
    -- an AW_muckPlane node.
    AnimalWaste.updateMuckPlane(self)
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

    -- Per-hour trace (debug-gated): confirms this vanilla-onHourChanged append
    -- runs for a cow shed. Realistic Livestock also appends to onHourChanged;
    -- load order decides whether this runs before or after RL's production.
    debugLog("onHourChanged append reached (husbandry=%s, M=%s)",
        tostring(self.uniqueId or self), tostring(AnimalWaste.multiplier or 1))

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

    -- Deep Litter capture has MOVED out of this append. Under Realistic Livestock
    -- this function runs BEFORE RL produces the hour's manure (RL appends to
    -- onHourChanged after us, so it runs after us), so sweeping here caught an
    -- empty store -- the exact bug. The capture now rides a SEPARATE append
    -- installed in loadMap (see installPostProductionCapture), which is therefore
    -- LAST in the chain and runs AFTER RL has filled the store.
end


-- Capture tick gated for the post-production append below. Mirrors exactly what
-- awDLTest does on demand, but for one shed per in-game hour.
local function onHourChangedDeepLitterCapture(self, currentHour)
    if not self.isServer then return end
    if not isCowHusbandry(self) then return end
    AnimalWaste.deepLitterCaptureTick(self, currentHour)
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


-- Install the Deep Litter capture as a SEPARATE onHourChanged append, done from
-- loadMap rather than at mod-load. Every mod's source (incl. Realistic Livestock)
-- has finished appending to onHourChanged before any loadMap runs, so appending
-- here puts our capture LAST in the chain -- it runs after the vanilla cycle AND
-- after RL's production, when the hour's manure is actually in the store. Guarded
-- so re-entering loadMap (loading another save in the same session) can't stack
-- duplicate appends.
function AnimalWaste:installPostProductionCapture()
    if AnimalWaste.captureHookInstalled then return end
    if PlaceableHusbandry == nil or PlaceableHusbandry.onHourChanged == nil then
        Logging.error("[%s] PlaceableHusbandry.onHourChanged missing; deep-litter capture not installed",
                      AnimalWaste.MOD_NAME)
        return
    end

    PlaceableHusbandry.onHourChanged = Utils.appendedFunction(
        PlaceableHusbandry.onHourChanged, onHourChangedDeepLitterCapture)

    AnimalWaste.captureHookInstalled = true
    log("deep-litter capture re-anchored: appended to onHourChanged at loadMap (runs LAST, after RL production)")
end


-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function AnimalWaste:loadMap(filename)
    self:detectRealisticLivestock()
    self:loadFromXML()

    -- Re-anchor the hourly capture so it runs AFTER Realistic Livestock's hourly
    -- production (see installPostProductionCapture). Must happen here, not at
    -- mod-load, to land last in the onHourChanged chain.
    self:installPostProductionCapture()

    -- Guaranteed muck-out trigger for testing, independent of the menu button.
    if addConsoleCommand ~= nil then
        addConsoleCommand("awMuckOut", "Deep Litter: muck out all owned cow sheds",
            "consoleMuckOut", AnimalWaste)
        addConsoleCommand("awDLTest", "Deep Litter: run the capture once per shed now and print diagnostics",
            "consoleDLTest", AnimalWaste)
        addConsoleCommand("awAddManure", "Deep Litter test: add [litres] manure (default 20000) to the nearest cow shed",
            "consoleAddManure", AnimalWaste)
        addConsoleCommand("awSetPack", "Deep Litter test: set the nearest cow shed's pack to [litres] (default 20000) and refresh the muck plane now",
            "consoleSetPack", AnimalWaste)
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
-- it is a cow shed. Prefers the husbandry handed to displayCluster (the frame's
-- "now showing this shed" signal), then falls back to frame fields. Returns nil
-- otherwise (the caller then falls back to all sheds).
function AnimalWaste.getSelectedHusbandry()
    local h = AnimalWaste._selectedHusbandry
    if h ~= nil and isCowHusbandry(h) then return h end

    local frame = AnimalWaste._animalsFrame
    if frame ~= nil then
        local candidate = frame.husbandry or frame.currentHusbandry or frame.selectedHusbandry
        if candidate ~= nil and isCowHusbandry(candidate) then
            return candidate
        end
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


-- Return a button-info list = the frame's own buttons plus our "Muck out shed"
-- button appended. Used to OVERRIDE InGameMenuAnimalsFrame:getMenuButtonInfo so
-- our button is re-included every single time the menu rebuilds its bottom bar.
-- That is the fix for the button vanishing: the previous approach pushed the
-- button into the frame's menuButtonInfo on frame-open only, but the animals
-- frame rebuilds that list every time the displayed husbandry changes (each
-- displayCluster), so the one-time button was dropped as the player cycled
-- sheds. Building a fresh list on every getMenuButtonInfo call survives all
-- rebuilds. A fresh copy (never mutating the frame's list) means no duplicates.
function AnimalWaste.withMuckOutButton(frame, info)
    local result = {}
    if info ~= nil then
        for _, b in ipairs(info) do
            if b.awMuckOut then return info end  -- already ours; leave untouched
            result[#result + 1] = b
        end
    end

    if InputAction == nil or InputAction.MENU_EXTRA_2 == nil then
        return info  -- no usable input action; don't add (console command still works)
    end

    result[#result + 1] = {
        awMuckOut   = true,
        profile     = "buttonActivate",
        inputAction = InputAction.MENU_EXTRA_2,
        text        = g_i18n:getText("aw_muckout_button"),
        callback    = function() AnimalWaste.onMuckOutButton() end,
    }
    return result
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


-- Console command: on-demand capture test. Does NOT wait for an hour change.
-- Walks EVERY animal husbandry and, for each, prints one diagnostic line with:
-- shed id, cow-detected?, the Deep Litter flag as read right now, the manure
-- fill type, an independent read-back of the loadable manure level, the litres
-- the capture actually diverted, and the pack value before and after. Server-only
-- (it mutates fill levels). The divert runs regardless of the toggle so the test
-- never depends on the flag or on time passing.
function AnimalWaste:consoleDLTest()
    if not AnimalWaste.isServerSide() then
        return "AnimalWaste: awDLTest must run on the host/server."
    end

    local count = 0
    forEachAnimalHusbandry(function(placeable)
        count = count + 1

        local id        = tostring(placeable.uniqueId or placeable)
        local cow       = isCowHusbandry(placeable)
        local dl        = AnimalWaste.deepLitterEnabled
        local strawSpec = placeable.spec_husbandryStraw
        local fillType  = strawSpec and strawSpec.outputFillType
        local readLevel, readVia = readManureLevel(placeable, fillType)

        local packBefore = getPackDepth(placeable)
        -- Run the capture logic once, for real, on cow sheds only.
        local diverted = cow and AnimalWaste.divertManureToPack(placeable) or 0
        local packAfter = getPackDepth(placeable)

        log("awDLTest shed=%s cow=%s DL=%s manureFT=%s(%s) loadableRead=%s(via %s) diverted=%.1f pack: %.1f -> %.1f",
            id, tostring(cow), tostring(dl),
            tostring(fillType), fillTypeName(fillType),
            tostring(readLevel), tostring(readVia),
            diverted, packBefore, packAfter)
    end)

    if count == 0 then
        return "AnimalWaste: awDLTest found no animal husbandries."
    end
    return string.format("AnimalWaste: awDLTest ran on %d animal shed(s) -- see the log lines above.", count)
end


-- Console command: awAddManure [litres]
-- Seeds loadable MANURE into a cow shed's manure store so the muck-out -> heap
-- flow can be tested on a fresh save. Defaults to 20000 L. Targets the cow shed
-- NEAREST the player; if the player position can't be read it falls back to the
-- first cow shed (and the printed shed id tells you which one got it). The add
-- is clamped to the store's free capacity so it never overfills. Server-only
-- (it mutates fill levels), and uses the same addHusbandryFillLevelFromTool API
-- the muck-out release relies on.
function AnimalWaste:consoleAddManure(litresArg)
    if not AnimalWaste.isServerSide() then
        return "AnimalWaste: awAddManure must run on the host/server."
    end

    local litres = tonumber(litresArg) or 20000
    if litres <= 0 then
        return string.format("AnimalWaste: awAddManure amount must be > 0 (got '%s').", tostring(litresArg))
    end

    -- Prefer the cow shed nearest the player; fall back to the first cow shed.
    local target, how = findNearestCowHusbandry(), "nearest"
    if target == nil then
        target, how = firstCowHusbandry(), "first (nearest-targeting unavailable)"
    end
    if target == nil then
        return "AnimalWaste: awAddManure found no cow husbandry to seed."
    end

    local strawSpec = target.spec_husbandryStraw
    local fillType  = strawSpec and strawSpec.outputFillType
    if fillType == nil then
        return "AnimalWaste: awAddManure -- target cow shed has no manure output fill type."
    end

    local farmId = target:getOwnerFarmId()
    local id     = tostring(target.uniqueId or target)

    -- Capacity (for the print) and free capacity (to clamp the add).
    local capacity, freeCap
    if target.getHusbandryCapacity ~= nil then
        local ok, c = pcall(function() return target:getHusbandryCapacity(fillType, farmId) end)
        if ok then capacity = c end
    end
    if target.getHusbandryFreeCapacity ~= nil then
        local ok, f = pcall(function() return target:getHusbandryFreeCapacity(fillType, farmId) end)
        if ok then freeCap = f end
    end

    local before = select(1, readManureLevel(target, fillType)) or 0

    -- Clamp to free space so we never exceed capacity. If free capacity is
    -- unknown, derive it from capacity - before; if both are unknown, add as-is.
    local room = freeCap
    if room == nil and capacity ~= nil then room = math.max(0, capacity - before) end
    local toAdd = room ~= nil and math.min(litres, room) or litres
    if toAdd < 0 then toAdd = 0 end

    if toAdd > 0 then
        target:addHusbandryFillLevelFromTool(farmId, toAdd, fillType, nil, nil, nil)
    end

    local after  = select(1, readManureLevel(target, fillType)) or (before + toAdd)
    local capStr = capacity ~= nil and string.format("%.0f", capacity) or "?"

    -- One line: shed id, manure before -> after, capacity (plus what/where).
    local line = string.format(
        "AnimalWaste: awAddManure shed=%s manure %.0f -> %.0f, capacity %s (added %.0f of %.0f requested, %s shed).",
        id, before, after, capStr, toAdd, litres, how)
    log("%s", line)
    return line
end


-- Console command: awSetPack [litres]
-- Sets the deep-litter PACK of the nearest cow shed directly to [litres] (default
-- 20000, clamped >= 0), then refreshes the muck plane via the SAME updateMuckPlane
-- the hourly tick uses -- so the plane jumps to the new height instantly, no sleep
-- or hour-change. Syncs the new pack to clients so their visual updates too.
-- Server/host only; dev-only (stripped at final cleanup). Reuses awAddManure's
-- nearest-husbandry targeting.
function AnimalWaste:consoleSetPack(litresArg)
    if not AnimalWaste.isServerSide() then
        return "AnimalWaste: awSetPack must run on the host/server."
    end

    local litres = tonumber(litresArg)
    if litres == nil then litres = 20000 end
    if litres < 0 then litres = 0 end

    -- Same nearest-husbandry targeting as awAddManure.
    local target, how = findNearestCowHusbandry(), "nearest"
    if target == nil then
        target, how = firstCowHusbandry(), "first (nearest-targeting unavailable)"
    end
    if target == nil then
        return "AnimalWaste: awSetPack found no cow husbandry."
    end

    local id     = tostring(target.uniqueId or target)
    local before = getPackDepth(target)

    setPackDepth(target, litres)
    local after = getPackDepth(target)

    -- Jump the visual to the new height now (same path the hourly tick uses).
    AnimalWaste.updateMuckPlane(target)

    -- Sync the new pack to clients so their muck plane updates too.
    if AnimalWaste.isMultiplayerHost() then
        AnimalWastePackEvent.broadcastPack(target, after)
    end

    -- Resulting plane ratio/height (mirrors updateMuckPlane's maths).
    local full   = AnimalWaste.AW_MUCK_FULL_PACK
    local ratio  = (full and full > 0) and math.min(math.max(after / full, 0), 1) or 0
    local height = ratio * AnimalWaste.AW_MUCK_FULL_HEIGHT

    local line = string.format(
        "AnimalWaste: awSetPack shed=%s pack %.0f -> %.0f, plane ratio %.2f (%.2f m of %.2f), %s shed.",
        id, before, after, ratio, height, AnimalWaste.AW_MUCK_FULL_HEIGHT, how)
    log("%s", line)
    return line
end


-- ---------------------------------------------------------------------
-- Top-level wiring
-- ---------------------------------------------------------------------

AnimalWaste:installHooks()

-- Deep Litter visual: set each shed's AW_muckPlane to match its pack once the
-- placeable's nodes are ready. onFinalizePlacement fires per husbandry on both
-- fresh placement and savegame load (server and client), so the rising-muck mesh
-- is correct immediately after a reload. No-op for sheds without the node.
if PlaceableHusbandry ~= nil and PlaceableHusbandry.onFinalizePlacement ~= nil then
    PlaceableHusbandry.onFinalizePlacement = Utils.appendedFunction(
        PlaceableHusbandry.onFinalizePlacement,
        function(self) AnimalWaste.updateMuckPlane(self) end)
end

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

-- Animals menu "Muck out shed" button.
--
-- The bottom-bar buttons are built by InGameMenuAnimalsFrame:getMenuButtonInfo,
-- which the menu re-queries every time it refreshes the bar -- including when the
-- displayed husbandry changes. Overriding it (rather than pushing into the
-- frame's button list once on open) makes our button re-appear on every refresh,
-- so it no longer vanishes as the player cycles between cow sheds.
if InGameMenuAnimalsFrame ~= nil then
    local baseGetMenuButtonInfo = InGameMenuAnimalsFrame.getMenuButtonInfo
    if baseGetMenuButtonInfo ~= nil then
        InGameMenuAnimalsFrame.getMenuButtonInfo = function(self, ...)
            local info = baseGetMenuButtonInfo(self, ...)
            return AnimalWaste.withMuckOutButton(self, info)
        end
    else
        Logging.warning("[%s] InGameMenuAnimalsFrame.getMenuButtonInfo missing; muck-out menu button unavailable (use the awMuckOut console command)",
                        AnimalWaste.MOD_NAME)
    end

    -- Record the frame and force a bar refresh on open.
    if InGameMenuAnimalsFrame.onFrameOpen ~= nil then
        InGameMenuAnimalsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuAnimalsFrame.onFrameOpen,
            function(self)
                AnimalWaste._animalsFrame = self
                if self.setMenuButtonInfoDirty ~= nil then self:setMenuButtonInfoDirty() end
            end)
    end

    -- displayCluster is the "now showing this husbandry" signal. Record which
    -- shed is selected (for muck-out targeting) and refresh the bar so the
    -- override re-adds our button for the newly selected shed.
    if InGameMenuAnimalsFrame.displayCluster ~= nil then
        InGameMenuAnimalsFrame.displayCluster = Utils.appendedFunction(
            InGameMenuAnimalsFrame.displayCluster,
            function(self, animal, husbandry)
                AnimalWaste._animalsFrame = self
                if husbandry ~= nil then AnimalWaste._selectedHusbandry = husbandry end
                if self.setMenuButtonInfoDirty ~= nil then self:setMenuButtonInfoDirty() end
            end)
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
