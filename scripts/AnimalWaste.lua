-- Animal Waste Production Rate
--
-- Two INDEPENDENT, decoupled multipliers on cow sheds, each a row injected into
-- the vanilla General Settings page and persisted per-savegame:
--   * husbandryProductionRate -- manure / liquid manure OUTPUT only (1/2/3/5/10x)
--   * strawUsageRate          -- straw CONSUMPTION only             (1/5/10/15/20x)
-- The production-rate slider no longer touches straw; the straw slider only
-- burns extra straw and never produces manure. Compatible with Realistic
-- Livestock (both hooks run LAST, after RL's onHourChanged append).

AnimalWaste = {}
AnimalWaste.MOD_NAME = "FS25_AnimalWaste"
AnimalWaste.VERSION  = "1.4.0.0"

-- Current scale factors. Updated by the Settings click callbacks and by
-- loadFromXML. All default to 1x (pass-through) until they fire.
--   multiplier      -- COW manure / liquid manure output
--   strawMultiplier -- straw consumption          (COW ONLY, independent of multiplier)
--   milkMultiplier  -- milk output                (COW ONLY, independent of both)
AnimalWaste.multiplier = 1
AnimalWaste.strawMultiplier = 1
AnimalWaste.milkMultiplier = 1

-- Per-animal-type manure+slurry multipliers (each scales that type's manure AND
-- liquid manure together, independently of cow). Default 1x (pass-through).
--   COW    uses the existing AnimalWaste.multiplier above (unchanged).
--   pigWaste, sheepWaste, horseWaste, chickenWaste  -- one per remaining type.
-- GOAT is a subType of the SHEEP animal TYPE in RL (there is no GOAT type index and
-- the scaled rate is a single per-shed aggregate summing sheep+goat animals), so
-- goats are NOT separable at this layer -- sheepWaste covers sheep AND goats.
AnimalWaste.pigWaste     = 1
AnimalWaste.sheepWaste   = 1   -- covers GOAT too (see note above)
AnimalWaste.horseWaste   = 1
AnimalWaste.chickenWaste = 1

-- Diagnostic logging. The DEBUG-gated lines are the per-shed hourly extra-waste /
-- straw / milk traces.
-- CHECKPOINT 2: OFF for release (kills the hourly per-shed spam). The per-shed
-- DEBUG line is KEPT in place, just gated -- flip this to true to bring the
-- per-animal manure/slurry proof (shed, animalType, multiplier, manureAdded,
-- slurryAdded) back for future diagnosis.
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
        values   = { 1, 2, 3, 5, 10, 20 },
        callback = function(name, newValue)
            AnimalWaste.multiplier = newValue
            log("multiplier set to %sx", tostring(newValue))
        end,
    },
    ["strawUsageRate"] = {
        index    = 3,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => 1x
        values   = { 1, 3, 5, 10, 15, 20 },
        callback = function(name, newValue)
            AnimalWaste.strawMultiplier = newValue
            log("straw usage set to %sx", tostring(newValue))
        end,
    },
    ["milkUsageRate"] = {
        index    = 4,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => 1x
        values   = { 1, 3, 5, 10, 15, 20 },
        callback = function(name, newValue)
            AnimalWaste.milkMultiplier = newValue
            log("milk output set to %sx", tostring(newValue))
        end,
    },
    -- Per-animal manure+slurry sliders. Each drives the matching field consumed by
    -- wasteMultiplierForType (PIG/SHEEP/HORSE/CHICKEN). COW keeps its own slider
    -- (husbandryProductionRate) above -- there is no separate cowWaste. SHEEP covers
    -- goats (goat is a subType of SHEEP, not separable at this layer). Steps
    -- 1/5/10/15/20x like straw/milk.
    ["pigWaste"] = {
        index    = 5,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => 1x
        values   = { 1, 3, 5, 10, 15, 20 },
        callback = function(name, newValue)
            AnimalWaste.pigWaste = newValue
            log("pig waste set to %sx", tostring(newValue))
        end,
    },
    ["sheepWaste"] = {
        index    = 6,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => 1x
        values   = { 1, 3, 5, 10, 15, 20 },
        callback = function(name, newValue)
            AnimalWaste.sheepWaste = newValue   -- covers GOAT too
            log("sheep/goat waste set to %sx", tostring(newValue))
        end,
    },
    ["horseWaste"] = {
        index    = 7,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => 1x
        values   = { 1, 3, 5, 10, 15, 20 },
        callback = function(name, newValue)
            AnimalWaste.horseWaste = newValue
            log("horse waste set to %sx", tostring(newValue))
        end,
    },
    ["chickenWaste"] = {
        index    = 8,
        type     = "MultiTextOption",
        default  = 1,                  -- 1-based: state 1 => values[1] => 1x
        values   = { 1, 3, 5, 10, 15, 20 },
        callback = function(name, newValue)
            AnimalWaste.chickenWaste = newValue
            log("chicken waste set to %sx", tostring(newValue))
        end,
    },
}

AnimalWaste.settingsInjected      = false
AnimalWaste.extraWasteHookInstalled = false
AnimalWaste.strawBurnHookInstalled  = false
AnimalWaste.milkHookInstalled       = false
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
-- Husbandry animal-type filter
--
-- isCowHusbandry gates the COW-ONLY hooks (straw consumption + milk). The
-- manure/slurry hook uses the per-type path below instead (getHusbandryTypeName +
-- wasteMultiplierForType), so pig/horse/sheep/chicken get their own multiplier.
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

-- Uppercase animal-type NAME of a husbandry ("COW"/"PIG"/"SHEEP"/"HORSE"/"CHICKEN"),
-- resolved from spec_husbandryAnimals.animalTypeIndex via the animal system. Returns
-- nil if unavailable. Note: a sheep/goat barn is animal TYPE "SHEEP" (goat is only a
-- subType), so this returns "SHEEP" for both -- goats cannot be split out here.
local function getHusbandryTypeName(placeable)
    local spec = placeable and placeable.spec_husbandryAnimals
    if spec == nil or spec.animalTypeIndex == nil then return nil end
    local as = g_currentMission and g_currentMission.animalSystem
    if as == nil or as.types == nil then return nil end
    local typ = as.types[spec.animalTypeIndex]
    return typ and typ.name or nil
end

-- Map an animal-type name to its manure+slurry multiplier. COW reuses the existing
-- combined multiplier; the rest use their own per-type field. Returns nil for any
-- type we do not scale (so the hook no-ops on it). SHEEP covers goats.
local function wasteMultiplierForType(typeName)
    if typeName == "COW"     then return AnimalWaste.multiplier
    elseif typeName == "PIG"     then return AnimalWaste.pigWaste
    elseif typeName == "SHEEP"   then return AnimalWaste.sheepWaste
    elseif typeName == "HORSE"   then return AnimalWaste.horseWaste
    elseif typeName == "CHICKEN" then return AnimalWaste.chickenWaste
    end
    return nil
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
-- vanilla foodFactor formula. OUTPUT ONLY: this path no longer consumes any
-- straw -- straw consumption is owned exclusively by the independent strawUsageRate
-- slider (see addExtraStrawBurn). Returns manureAdded.
-- Defensive throughout (feature-detect + pcall).
local function addExtraManure(self, M, timeAdjustment)
    local spec = self.spec_husbandryStraw
    if spec == nil or spec.outputLitersPerHour == nil or spec.outputLitersPerHour <= 0 then
        return 0
    end

    -- Manure top-up: proportional to the refreshed output rate. No straw draw here.
    if spec.outputFillType == nil or self.addHusbandryFillLevelFromTool == nil then
        return 0
    end
    local extraManure = spec.outputLitersPerHour * (M - 1) * timeAdjustment
    if extraManure <= 0 then return 0 end

    local ok = pcall(function()
        self:addHusbandryFillLevelFromTool(self:getOwnerFarmId(), extraManure, spec.outputFillType, nil, nil, nil)
    end)
    return ok and extraManure or 0
end

-- Extra (S-1)x straw consumption -- the independent strawUsageRate slider. Scales
-- the husbandry's CURRENT per-hour straw draw (spec.inputLitersPerHour, refreshed
-- each hour by RL's onHourChanged append under RL, or vanilla otherwise) and
-- removes that extra straw from the store. Adds NO manure -- consumption only,
-- fully decoupled from the manure/slurry multiplier. removeHusbandryFillLevel
-- clamps at 0, so the store can never go negative. Returns strawConsumed.
-- Defensive throughout (feature-detect + pcall).
local function addExtraStrawBurn(self, S, timeAdjustment)
    local spec = self.spec_husbandryStraw
    if spec == nil or spec.inputLitersPerHour == nil or spec.inputLitersPerHour <= 0 then
        return 0
    end
    if spec.inputFillType == nil or self.removeHusbandryFillLevel == nil then
        return 0
    end

    local extraStraw = spec.inputLitersPerHour * (S - 1) * timeAdjustment
    if extraStraw <= 0 then return 0 end

    local ok, notRemoved = pcall(function()
        return self:removeHusbandryFillLevel(self:getOwnerFarmId(), extraStraw, spec.inputFillType)
    end)
    if not ok or type(notRemoved) ~= "number" then return 0 end

    local strawConsumed = extraStraw - notRemoved
    if strawConsumed > 0 and self.updateStrawPlane ~= nil then
        pcall(function() self:updateStrawPlane() end)
    end
    return strawConsumed
end

-- Appended to PlaceableHusbandry.onHourChanged, installed LAST from loadMap (see
-- installExtraWasteHookLast) so it runs AFTER Realistic Livestock's onHourChanged
-- append has refreshed outputLitersPerHour / litersPerHour for the hour. We then
-- top up the extra (M-1)x of manure and slurry by scaling those refreshed rates.
local function onHourChangedAddExtraWaste(self, currentHour)
    if not self.isServer then return end

    -- PER-ANIMAL-TYPE gate (was isCowHusbandry): resolve this shed's animal type and
    -- pick that type's manure+slurry multiplier. Unsupported type -> nil -> no-op;
    -- 1x -> no-op. Only the manure/slurry hook is widened this way; straw and milk
    -- stay COW-ONLY. Cow behaviour is unchanged (COW -> AnimalWaste.multiplier).
    local typeName = getHusbandryTypeName(self)
    if typeName == nil then return end
    local M = wasteMultiplierForType(typeName)
    if M == nil or M == 1 then return end

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

    -- addExtraManure/addExtraLiquidManure feature-detect their spec and pcall/clamp,
    -- so a type with no manure/slurry deposit path (sheep/goat/chicken on vanilla
    -- barns) returns 0 here -- a safe no-op, no error.
    local manureAdded = addExtraManure(self, M, timeAdjustment)
    local liquidAdded = addExtraLiquidManure(self, M, timeAdjustment)

    -- PROOF (per shed per hour, DEBUG-gated): animal type, the multiplier applied,
    -- the refreshed per-hour rates, and the litres actually added. Pig should scale
    -- manure+slurry; horse manure only; cow unchanged; sheep/goat/chicken no-op to 0.
    debugLog("extra-waste shed=%s type=%s M=%sx foodFactor=%s manureOut/hr=%s slurry/hr=%s -> manureAdded=%.1f slurryAdded=%.1f",
        tostring(self.uniqueId or self), tostring(typeName), tostring(M),
        tostring(husbandrySpec.productionFactor),
        tostring(strawSpec and strawSpec.outputLitersPerHour),
        tostring(liquidSpec and liquidSpec.litersPerHour),
        manureAdded or 0, liquidAdded or 0)
end


-- Appended to PlaceableHusbandry.onHourChanged, installed LAST from loadMap (see
-- installStrawBurnHookLast) so it runs AFTER Realistic Livestock's onHourChanged
-- append has refreshed inputLitersPerHour for the hour. Burns the extra (S-1)x of
-- straw the strawUsageRate slider asks for. Independent of the manure multiplier:
-- gated only on its own multiplier S, so straw scaling works even at 1x manure.
local function onHourChangedAddExtraStrawBurn(self, currentHour)
    if not self.isServer then return end

    local S = AnimalWaste.strawMultiplier or 1
    if S == 1 or not isCowHusbandry(self) then return end

    local timeAdjustment = (g_currentMission ~= nil and g_currentMission.environment ~= nil
        and g_currentMission.environment.timeAdjustment) or 1

    local strawConsumed = addExtraStrawBurn(self, S, timeAdjustment)

    local strawSpec = self.spec_husbandryStraw
    debugLog("straw-burn shed=%s S=%sx strawIn/hr=%s -> strawConsumed=%.1f",
        tostring(self.uniqueId or self), tostring(S),
        tostring(strawSpec and strawSpec.inputLitersPerHour),
        strawConsumed or 0)
end


-- Extra (M-1)x milk -- the independent milkUsageRate multiplier. Mirrors vanilla's
-- PlaceableHusbandryMilk.updateOutput maths EXACTLY:
--     liters = productionFactor * globalProductionFactor * litersPerHour[ft] * timeAdjustment
-- and deposits only the extra (M-1)x. Iterates spec_husbandryMilk.fillTypes (a shed
-- can output more than one milk fill type) and uses the SAME per-fill-type
-- spec.litersPerHour[ft] vanilla reads. Under Realistic Livestock that rate is RL's
-- refreshed per-animal milk output, so scaling it composes with RL as long as we run
-- LAST (see installMilkHookLast).
--
-- We deposit through self:addHusbandryFillLevelFromTool -- the identical call vanilla
-- uses for the base milk -- so RDM (Realistic Milking Time), which OVERWRITES that
-- function to buffer FillType.MILK and flush it at 6am/6pm, buffers our extra on the
-- same schedule. We NEVER touch the updateOutput chain (that is the "mul on number
-- and nil" globalProductionFactor crash); this is a plain deposit from an
-- onHourChanged append. Returns total extra litres added across all milk fill types.
-- Defensive: feature-detects the API, guards the two production factors, pcall-guards
-- the write. productionFactor<=0 / globalProductionFactor<=0 mean no base milk this
-- hour, so nothing to scale -- this guard is milk-local (inside the milk maths), NOT
-- the top-level foodFactor gate that would block manure/straw under RL.
local function addExtraMilk(self, M, productionFactor, globalProductionFactor, timeAdjustment)
    local spec = self.spec_husbandryMilk
    if spec == nil or not spec.hasMilkProduction then return 0 end
    if spec.fillTypes == nil or spec.litersPerHour == nil then return 0 end
    if self.addHusbandryFillLevelFromTool == nil then return 0 end
    if productionFactor == nil or productionFactor <= 0 then return 0 end
    if globalProductionFactor == nil or globalProductionFactor <= 0 then return 0 end

    local totalAdded = 0
    for _, fillTypeIndex in ipairs(spec.fillTypes) do
        local litersPerHour = spec.litersPerHour[fillTypeIndex]
        if litersPerHour ~= nil and litersPerHour > 0 then
            local extra = productionFactor * globalProductionFactor * litersPerHour * (M - 1) * timeAdjustment
            if extra > 0 then
                local ok = pcall(function()
                    self:addHusbandryFillLevelFromTool(self:getOwnerFarmId(), extra, fillTypeIndex, nil, nil, nil)
                end)
                if ok then
                    totalAdded = totalAdded + extra
                    debugLog("  milk fillType=%s litersPerHour=%s -> extra=%.2f",
                        tostring(fillTypeIndex), tostring(litersPerHour), extra)
                end
            end
        end
    end
    return totalAdded
end

-- Appended to PlaceableHusbandry.onHourChanged, installed LAST from loadMap (see
-- installMilkHookLast) so it runs AFTER Realistic Livestock's onHourChanged append
-- has refreshed spec_husbandryMilk.litersPerHour for the hour. Tops up the extra
-- (M-1)x milk the milkUsageRate multiplier asks for. Independent of the manure and
-- straw multipliers: gated only on its own multiplier M.
local function onHourChangedAddExtraMilk(self, currentHour)
    if not self.isServer then return end

    local M = AnimalWaste.milkMultiplier or 1
    if M == 1 or not isCowHusbandry(self) then return end

    local husbandrySpec = self.spec_husbandry
    if husbandrySpec == nil then return end

    -- Milk mirrors vanilla PlaceableHusbandryMilk.updateOutput, which multiplies by
    -- productionFactor AND globalProductionFactor. Read BOTH locally. We do NOT gate
    -- the hook on productionFactor<=0 (the guard lives inside addExtraMilk, milk-local
    -- only). These two factors are the whole open risk under RL: the DEBUG line below
    -- prints them so an in-game RL test can confirm they are NON-ZERO (else milk would
    -- silently not scale).
    local productionFactor = husbandrySpec.productionFactor
    local globalProductionFactor = husbandrySpec.globalProductionFactor

    local timeAdjustment = (g_currentMission ~= nil and g_currentMission.environment ~= nil
        and g_currentMission.environment.timeAdjustment) or 1

    local milkAdded = addExtraMilk(self, M, productionFactor, globalProductionFactor, timeAdjustment)

    -- PROOF (per shed per hour, DEBUG-gated): the per-fillType litersPerHour/extra
    -- lines come from addExtraMilk above; this summary line carries the two RL-risk
    -- factors and the total milk added.
    debugLog("extra-milk shed=%s M=%sx productionFactor=%s globalProductionFactor=%s -> milkAdded=%.2f",
        tostring(self.uniqueId or self), tostring(M),
        tostring(productionFactor), tostring(globalProductionFactor),
        milkAdded or 0)
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


-- Install the straw-burn append from loadMap (NOT at mod-load), same reasoning as
-- installExtraWasteHookLast: appending HERE lands us LAST in the onHourChanged
-- chain, after Realistic Livestock's append has refreshed inputLitersPerHour for
-- the hour, so the strawUsageRate slider scales RL's actual straw rate rather than
-- a stale/zero value. Still an append, never an overwrite. Independent of the
-- extra-waste hook so the two multipliers stay fully decoupled.
function AnimalWaste:installStrawBurnHookLast()
    if AnimalWaste.strawBurnHookInstalled then return end
    if PlaceableHusbandry == nil or PlaceableHusbandry.onHourChanged == nil then
        Logging.error("[%s] PlaceableHusbandry.onHourChanged missing; mod will not scale straw usage",
                      AnimalWaste.MOD_NAME)
        return
    end

    PlaceableHusbandry.onHourChanged = Utils.appendedFunction(
        PlaceableHusbandry.onHourChanged, onHourChangedAddExtraStrawBurn)

    AnimalWaste.strawBurnHookInstalled = true
    log("straw-burn hook installed LAST at loadMap (runs after RL's onHourChanged append)")
end


-- Install the milk-scaling append from loadMap (NOT at mod-load), same reasoning as
-- installExtraWasteHookLast/installStrawBurnHookLast: appending HERE lands us LAST in
-- the onHourChanged chain, after Realistic Livestock's append has refreshed
-- spec_husbandryMilk.litersPerHour for the hour, so milkUsageRate scales RL's actual
-- per-animal milk output rather than a stale/zero value. Still an append, never an
-- overwrite -- we never become a super-injected link in the updateOutput chain (that
-- is the "mul on number and nil" crash). Independent of the other two hooks.
function AnimalWaste:installMilkHookLast()
    if AnimalWaste.milkHookInstalled then return end
    if PlaceableHusbandry == nil or PlaceableHusbandry.onHourChanged == nil then
        Logging.error("[%s] PlaceableHusbandry.onHourChanged missing; mod will not scale milk",
                      AnimalWaste.MOD_NAME)
        return
    end

    PlaceableHusbandry.onHourChanged = Utils.appendedFunction(
        PlaceableHusbandry.onHourChanged, onHourChangedAddExtraMilk)

    AnimalWaste.milkHookInstalled = true
    log("milk hook installed LAST at loadMap (runs after RL's onHourChanged append)")
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
    self:installStrawBurnHookLast()
    self:installMilkHookLast()

    log("v%s loaded, cow=%sx, pig=%sx, sheep/goat=%sx, horse=%sx, chicken=%sx (straw=%sx, milk=%sx; cow-only)",
        AnimalWaste.VERSION, tostring(AnimalWaste.multiplier), tostring(AnimalWaste.pigWaste),
        tostring(AnimalWaste.sheepWaste), tostring(AnimalWaste.horseWaste), tostring(AnimalWaste.chickenWaste),
        tostring(AnimalWaste.strawMultiplier), tostring(AnimalWaste.milkMultiplier))
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
    -- their menus track ours. The event carries every host-authoritative setting,
    -- so one broadcast syncs all seven sliders. Every entry in SETTINGS is
    -- host-authoritative, so membership is the gate. Only the host changes the
    -- setting (client lock is a later task); the host gate makes this a no-op in SP
    -- and on clients.
    if AnimalWaste.SETTINGS[name] ~= nil and AnimalWaste.isMultiplayerHost() then
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


-- Apply one setting's synced state and refresh its menu row, if built. Runs the
-- setting's own callback (so multiplier / strawMultiplier track), and setState
-- without forceEvent does not re-fire onSettingChanged -- so there is no echo
-- loop back to the host.
local function applyOneSyncedSetting(name, state)
    local setting = AnimalWaste.SETTINGS[name]
    if setting == nil then return end
    if state == nil or state < 1 or state > #setting.values then return end

    setting.state = state
    if setting.callback then
        setting.callback(name, setting.values[state])
    end
    if setting.element ~= nil then
        setting.element:setState(state)
    end
end

-- Client-side: apply states pushed from the server. Clients never re-broadcast.
function AnimalWaste:applySyncedSettings(rateState, strawState, milkState,
                                        pigState, sheepState, horseState, chickenState)
    applyOneSyncedSetting("husbandryProductionRate", rateState)
    applyOneSyncedSetting("strawUsageRate", strawState)
    applyOneSyncedSetting("milkUsageRate", milkState)
    applyOneSyncedSetting("pigWaste", pigState)
    applyOneSyncedSetting("sheepWaste", sheepState)
    applyOneSyncedSetting("horseWaste", horseState)
    applyOneSyncedSetting("chickenWaste", chickenState)
    log("settings synced: cow=%sx manure, straw=%sx, milk=%sx; pig=%sx, sheep/goat=%sx, horse=%sx, chicken=%sx",
        tostring(AnimalWaste.multiplier), tostring(AnimalWaste.strawMultiplier),
        tostring(AnimalWaste.milkMultiplier), tostring(AnimalWaste.pigWaste),
        tostring(AnimalWaste.sheepWaste), tostring(AnimalWaste.horseWaste),
        tostring(AnimalWaste.chickenWaste))
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
            AnimalWasteSettingsEvent.sendToClient(connection)
        end)
else
    Logging.error("[%s] FSBaseMission.onConnectionFinishedLoading missing; MP join-sync disabled",
                  AnimalWaste.MOD_NAME)
end

addModEventListener(AnimalWaste)
