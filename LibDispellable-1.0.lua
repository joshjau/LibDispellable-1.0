--[[
LibDispellable-1.0 - Test whether the player can really dispell a buff or debuff, given its talents.
Copyright (C) 2009-2013 Adirelle (adirelle@gmail.com)
Now maintained by Joshua James (2023-present)

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice,
      this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice,
      this list of conditions and the following disclaimer in the documentation
      and/or other materials provided with the distribution.
    * Redistribution of a stand alone version is strictly prohibited without
      prior written authorization from the LibDispellable project manager.
    * Neither the name of the LibDispellable authors nor the names of its contributors
      may be used to endorse or promote products derived from this software without
      specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--]]

local MAJOR, MINOR = "LibDispellable-1.0", 32
assert(LibStub, MAJOR.." requires LibStub")
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Version history:
-- MINOR 32: Performance optimizations for high-end systems:
--           - Implemented time-based cache aging with GetTimePreciseSec
--           - Added optimized table recycling to reduce garbage collection
--           - Improved cache management with selective invalidation
--           - Localized frequently used API functions for better performance
-- MINOR 31: Updated to use C_UnitAuras.GetBuffDataByIndex and C_UnitAuras.GetDebuffDataByIndex instead of deprecated UnitBuff and UnitDebuff functions for The War Within (patch 11.1.0)

-- ----------------------------------------------------------------------------
-- Localize frequently used functions for performance
-- ----------------------------------------------------------------------------
local next = next
local wipe = wipe
local pairs = pairs
local type = type

-- WoW API function localization
local UnitCanAttack = UnitCanAttack
local UnitCanAssist = UnitCanAssist
local IsSpellKnown = IsSpellKnown
local CreateFrame = CreateFrame
local UnitClass = UnitClass
local GetTimePreciseSec = GetTimePreciseSec

-- C_UnitAuras API localization
local GetBuffDataByIndex = C_UnitAuras.GetBuffDataByIndex
local GetDebuffDataByIndex = C_UnitAuras.GetDebuffDataByIndex
local GetAuraSlots = C_UnitAuras.GetAuraSlots
local GetAuraDataBySlot = C_UnitAuras.GetAuraDataBySlot

-- AuraUtil API localization
local ForEachAura = AuraUtil.ForEachAura

-- ----------------------------------------------------------------------------
-- Table recycling for garbage collection optimization
-- ----------------------------------------------------------------------------
-- Cache of tables that can be reused to avoid excessive garbage collection
local tableCache = {}
local MAX_CACHE_SIZE = 20  -- Maximum number of tables to keep in the recycle pool

-- Acquires a table from the cache or creates a new one if none are available
-- This significantly reduces garbage collection overhead during aura scanning
local function acquireTable()
    local tbl = next(tableCache)
    if tbl then
        tableCache[tbl] = nil
        return tbl
    else
        return {}
    end
end

-- Returns a table to the cache for future reuse after wiping its contents
-- Only stores up to MAX_CACHE_SIZE tables to prevent memory bloat
local function releaseTable(tbl)
    if type(tbl) ~= "table" then return end
    wipe(tbl)
    local cacheSize = 0
    for _ in pairs(tableCache) do cacheSize = cacheSize + 1 end
    if cacheSize < MAX_CACHE_SIZE then
        tableCache[tbl] = true
    end
end

-- Function call cache for frequently checked dispellable spells
-- Stores results to avoid redundant calculations during rapid aura scanning
lib.dispellableCache = lib.dispellableCache or {}
lib.dispellableCount = 0
local MAX_CACHE_ENTRIES = 500  -- Increased for high-end systems to reduce recalculations

-- Cache for GetDispelType checks to avoid repeated dispel type lookups
-- Significantly improves performance when scanning multiple units with similar auras
local dispelTypeCache = {}
local MAX_DISPEL_TYPE_CACHE = 200

-- Unit capability cache to avoid repeated UnitCanAttack/UnitCanAssist calls for the same unit
-- Critical for performance when repeatedly checking the same units during combat
local unitCapabilityCache = {}
local MAX_UNIT_CACHE_SIZE = 100

-- Cache for CanDispelWith results to avoid redundant dispel checks
-- Helps when repeatedly checking the same spell ID against the same unit
local canDispelWithCache = {}
local MAX_DISPEL_WITH_CACHE = 100

-- Retrieves cached dispellable information or calculates and caches the result
-- This is a critical performance function used extensively throughout the library
-- @param dispelType The dispel type string (Magic, Curse, etc.)
-- @param spellID The spell ID of the aura
-- @param isBuff Whether the aura is a buff (true) or debuff (false)
-- @return The dispel spell ID or false if none available
local function getCachedDispellable(dispelType, spellID, isBuff)
    -- Create a unique cache key that identifies this specific dispel check
    local key = (isBuff and "B:" or "D:") .. (dispelType or "nil") .. ":" .. (spellID or 0)
    local result = lib.dispellableCache[key]
    if result ~= nil then
        return result
    end
    
    -- Calculate and cache the result if not found
    local actualDispelType = lib:GetDispelType(dispelType, spellID)
    local spell = actualDispelType and lib[isBuff and "buff" or "debuff"][actualDispelType]
    result = spell or false -- Cache even negative results for performance
    
    -- Manage cache size to prevent memory bloat
    if lib.dispellableCount >= MAX_CACHE_ENTRIES then
        wipe(lib.dispellableCache)
        lib.dispellableCount = 0
    end
    
    lib.dispellableCache[key] = result
    lib.dispellableCount = lib.dispellableCount + 1
    return result
end

-- ----------------------------------------------------------------------------
-- Event dispatcher for automatic cache invalidation
-- ----------------------------------------------------------------------------

if not lib.eventFrame then
	lib.eventFrame = CreateFrame("Frame")
	lib.eventFrame:SetScript('OnEvent', function(_, event) 
	    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" or event == "SPELLS_CHANGED" then
	        -- Invalidate all caches when entering/exiting combat or when spells change
	        -- This ensures dispel capabilities are always up-to-date when needed most
	        wipe(lib.dispellableCache or {})
	        lib.dispellableCount = 0
	        wipe(dispelTypeCache)
	        wipe(unitCapabilityCache)
	        wipe(canDispelWithCache)
	    end
	    
	    if event == "SPELLS_CHANGED" then
	        return lib:UpdateSpells()
	    end
	end)
	lib.eventFrame:RegisterEvent('SPELLS_CHANGED')
	lib.eventFrame:RegisterEvent('PLAYER_REGEN_DISABLED') -- Combat start
	lib.eventFrame:RegisterEvent('PLAYER_REGEN_ENABLED')  -- Combat end
end

-- ----------------------------------------------------------------------------
-- Data
-- ----------------------------------------------------------------------------

lib.buff = lib.buff or {}
lib.debuff = lib.debuff or {}
lib.specialIDs = wipe(lib.specialIDs or {})
lib.spells = lib.spells or {}

-- Spells that do not have a dispel type according to Blizzard API
-- but that can be dispelled anyway.
lib.specialIDs[144351] = "Magic" -- Mark of Arrogance (Sha of Pride encounter)

-- Cache cleanup functions with time-based aging system
-- ----------------------------------------------------------------------------

-- Cleans up the dispel type cache using time-based aging
-- Entries older than 10 seconds are removed to maintain cache freshness
-- If the cache grows too large, it will be completely wiped as a fallback
local function cleanDispelTypeCache()
    -- Use time-based cache cleanup
    local currentTime = GetTimePreciseSec()
    local keysToRemove = {}
    
    -- Find entries older than 10 seconds
    for key, timestamp in pairs(dispelTypeCache) do
        if key:find("_time$") and (currentTime - timestamp) > 10.0 then
            -- Find the base key
            local baseKey = key:gsub("_time$", "")
            table.insert(keysToRemove, baseKey)
            table.insert(keysToRemove, key)
        end
    end
    
    -- Remove outdated entries
    for _, key in ipairs(keysToRemove) do
        dispelTypeCache[key] = nil
    end
    
    -- If cache is still too large, do a complete wipe as fallback
    local cacheSize = 0
    for _ in pairs(dispelTypeCache) do cacheSize = cacheSize + 1 end
    if cacheSize > MAX_DISPEL_TYPE_CACHE * 2 then -- account for timestamp entries
        wipe(dispelTypeCache)
    end
end

-- Legacy cleanup function for unit capability cache
-- Will be replaced by the time-based system in a future update
local function cleanUnitCapabilityCache()
    local cacheSize = 0
    for _ in pairs(unitCapabilityCache) do cacheSize = cacheSize + 1 end
    if cacheSize > MAX_UNIT_CACHE_SIZE then
        wipe(unitCapabilityCache)
    end
end

-- Cleans up the CanDispelWith cache using time-based aging
-- Entries older than 5 seconds are removed to maintain cache freshness
-- Especially important during combat when dispel capabilities change frequently
local function cleanCanDispelWithCache()
    -- Use time-based cache cleanup
    local currentTime = GetTimePreciseSec()
    local keysToRemove = {}
    
    -- Find entries older than 5 seconds
    for key, timestamp in pairs(canDispelWithCache) do
        if key:find("_time$") and (currentTime - timestamp) > 5.0 then
            -- Find the base key
            local baseKey = key:gsub("_time$", "")
            table.insert(keysToRemove, baseKey)
            table.insert(keysToRemove, key)
        end
    end
    
    -- Remove outdated entries
    for _, key in ipairs(keysToRemove) do
        canDispelWithCache[key] = nil
    end
    
    -- If cache is still too large, do a complete wipe as fallback
    local cacheSize = 0
    for _ in pairs(canDispelWithCache) do cacheSize = cacheSize + 1 end
    if cacheSize > MAX_DISPEL_WITH_CACHE * 2 then -- account for timestamp entries
        wipe(canDispelWithCache)
    end
end

-- ----------------------------------------------------------------------------
-- Detect available dispel skills
-- ----------------------------------------------------------------------------

local function CheckSpell(spellID, pet)
	return IsSpellKnown(spellID, pet) and spellID or nil
end

--- Get the actual dispel mechanism of an aura, including special cases.
-- @name LibDispellable:GetDispelType
-- @param dispelType (string) The dispel mechanism as returned by UnitAura
-- @param spellID (number) The spell ID
-- @return dispelType (string) The actual dispel mechanism
function lib:GetDispelType(dispelType, spellID)
    -- Check cache first
    local cacheKey = (dispelType or "nil") .. "_" .. (spellID or 0)
    local cached = dispelTypeCache[cacheKey]
    local cachedTime = dispelTypeCache[cacheKey .. "_time"]
    local currentTime = GetTimePreciseSec()
    
    -- Cache hit with unexpired entry (10 second cache lifetime)
    if cached ~= nil and cachedTime and (currentTime - cachedTime) < 10.0 then
        return cached ~= "" and cached or nil -- Convert empty string to nil for API consistency
    end
    
    -- Calculate result
    local result
	if spellID and lib.specialIDs[spellID] then
		result = lib.specialIDs[spellID]
	elseif dispelType and dispelType ~= "none" and dispelType ~= "" then
		result = dispelType
	end
	
	-- Cache result (use empty string to cache nil values)
	cleanDispelTypeCache()
	dispelTypeCache[cacheKey] = result or ""
	dispelTypeCache[cacheKey .. "_time"] = currentTime
	
	return result
end

--- Check if an aura can be dispelled by anyone.
-- @name LibDispellable:IsDispellable
-- @param dispelType (string) The dispel mechanism as returned by UnitAura
-- @param spellID (number) The spell ID
-- @return boolean True if the aura can be dispelled in some way
function lib:IsDispellable(dispelType, spellID)
	return self:GetDispelType(dispelType, spellID) ~= nil
end

function lib:UpdateSpells()
	wipe(self.buff)
	wipe(self.debuff)

	local _, class = UnitClass("player")

	if class == "DEMONHUNTER" then
		self.debuff.Magic = CheckSpell(205604) -- Reverse Magic (PvP)

	elseif class == "DRUID" then
		local cure = CheckSpell(88423) -- Nature's Cure
		local corruption = cure or CheckSpell(2782) -- Remove Corruption
		self.debuff.Magic = cure
		self.debuff.Curse = corruption
		self.debuff.Poison = corruption

	elseif class == "HUNTER" then
		local mendingBandage = CheckSpell(212640) -- Mending Bandage (PvP)
		self.debuff.Disease = mendingBandage
		self.debuff.Poison = mendingBandage

	elseif class == "MAGE" then
		self.buff.Magic = CheckSpell(30449) -- Spellsteal

	elseif class == "MONK" then
		local mwDetox = CheckSpell(115450) -- Detox (Mistweaver)
		local detox = mwDetox or CheckSpell(218164) -- Detox (Brewmaster or Windwalker)
		self.debuff.Magic = mwDetox
		self.debuff.Disease = detox
		self.debuff.Poison = detox

	elseif class == "PALADIN" then
		local cleanse = CheckSpell(4987) -- Cleanse
		local toxins = cleanse or CheckSpell(213644) -- Cleanse Toxins
		self.debuff.Magic = cleanse
		self.debuff.Poison = toxins
		self.debuff.Disease = toxins

	elseif class == "PRIEST" then
		local purify = CheckSpell(527) -- Purify
		local disease = purify or CheckSpell(213634) -- Purify Disease
		self.debuff.Magic = purify
		self.debuff.Disease = disease
		self.buff.Magic = CheckSpell(528) -- Dispel Magic

	elseif class == "SHAMAN" then
		local purify = CheckSpell(77130) -- Purify Spirit
		local cleanse = purify or CheckSpell(51886) -- Cleanse Spirit
		self.debuff.Magic = purify
		self.debuff.Curse = cleanse
		self.buff.Magic = CheckSpell(370) -- Purge

	elseif class == "WARLOCK" then
		self.buff.Magic = CheckSpell(171021, true) -- Torch Magic (Infernal)
		self.debuff.Magic = CheckSpell(89808, true) or CheckSpell(212623) -- Singe Magic (Imp) / (PvP)
	end

	wipe(self.spells)
	if self.buff.Magic then
		self.spells[self.buff.Magic] = 'offensive'
	end
	for dispelType, id in pairs(self.debuff) do
		self.spells[id] = 'defensive'
	end

end

--- Check which player spell can be used to dispel an aura.
-- @name LibDispellable:GetDispelSpell
-- @param dispelType (string) The dispel mechanism as returned by UnitAura
-- @param spellID (number) The spell ID
-- @param isBuff (boolean) True if the spell is a buff, false if it is a debuff.
-- @return number The spell ID of the dispel, or nil if the player cannot dispel it.
function lib:GetDispelSpell(dispelType, spellID, isBuff)
	local result = getCachedDispellable(dispelType, spellID, isBuff)
	return result or nil -- Convert false to nil for API consistency
end

--- Test if the player can dispel the given aura on the given unit.
-- @name LibDispellable:CanDispel
-- @param unit (string) The unit id.
-- @param isBuff (boolean) True if the spell is a buff.
-- @param dispelType (string) The dispel mechanism, as returned by UnitAura.
-- @param spellID (number) The aura spell ID, as returned by UnitAura, used to test enrage effects.
-- @return boolean true if the player knows a spell to dispel the aura.
-- @return number The spell ID of the spell to dispel, or nil.
function lib:CanDispel(unit, isBuff, dispelType, spellID)
	if (isBuff and not UnitCanAttack("player", unit)) or (not isBuff and not UnitCanAssist("player", unit)) then
		return false
	end
	local spell = getCachedDispellable(dispelType, spellID, isBuff)
	return not not spell, spell or nil
end

-- ----------------------------------------------------------------------------
-- Iterators
-- ----------------------------------------------------------------------------

local function noop() end

local function buffIterator(unit, index)
	local result
	repeat
		index = index + 1
		local aura = GetBuffDataByIndex(unit, index)
		if not aura then break end
		
		local spell = getCachedDispellable(aura.dispelName, aura.spellId, true)
		if spell then
			-- Use table recycling for iterator results
			result = acquireTable()
			result[1] = index
			result[2] = spell
			result[3] = aura.name
			result[4] = nil -- was rank
			result[5] = aura.icon
			result[6] = aura.applications
			result[7] = aura.dispelName
			result[8] = aura.duration
			result[9] = aura.expirationTime
			result[10] = aura.sourceUnit
			result[11] = aura.isStealable
			result[12] = nil -- was shouldConsolidate
			result[13] = aura.spellId
			result[14] = aura.canApplyAura
			return unpack(result, 1, 14)
		end
	until not aura
end

local function allBuffIterator(unit, index)
	local result
	repeat
		index = index + 1
		local aura = GetBuffDataByIndex(unit, index)
		if not aura then break end
		
		if lib:IsDispellable(aura.dispelName, aura.spellId) then
			local spell = getCachedDispellable(aura.dispelName, aura.spellId, true)
			-- Use table recycling for iterator results
			result = acquireTable()
			result[1] = index
			result[2] = spell
			result[3] = aura.name
			result[4] = nil -- was rank
			result[5] = aura.icon
			result[6] = aura.applications
			result[7] = aura.dispelName
			result[8] = aura.duration
			result[9] = aura.expirationTime
			result[10] = aura.sourceUnit
			result[11] = aura.isStealable
			result[12] = nil -- was shouldConsolidate
			result[13] = aura.spellId
			result[14] = aura.canApplyAura
			return unpack(result, 1, 14)
		end
	until not aura
end

local function debuffIterator(unit, index)
	local result
	repeat
		index = index + 1
		local aura = GetDebuffDataByIndex(unit, index)
		if not aura then break end
		
		local spell = getCachedDispellable(aura.dispelName, aura.spellId, false)
		if spell then
			-- Use table recycling for iterator results
			result = acquireTable()
			result[1] = index
			result[2] = spell
			result[3] = aura.name
			result[4] = nil -- was rank
			result[5] = aura.icon
			result[6] = aura.applications
			result[7] = aura.dispelName
			result[8] = aura.duration
			result[9] = aura.expirationTime
			result[10] = aura.sourceUnit
			result[11] = aura.isStealable
			result[12] = nil -- was shouldConsolidate
			result[13] = aura.spellId
			result[14] = aura.canApplyAura
			result[15] = aura.isBossAura
			return unpack(result, 1, 15)
		end
	until not aura
end

local function allDebuffIterator(unit, index)
	local result
	repeat
		index = index + 1
		local aura = GetDebuffDataByIndex(unit, index)
		if not aura then break end
		
		if lib:IsDispellable(aura.dispelName, aura.spellId) then
			local spell = getCachedDispellable(aura.dispelName, aura.spellId, false)
			-- Use table recycling for iterator results
			result = acquireTable()
			result[1] = index
			result[2] = spell
			result[3] = aura.name
			result[4] = nil -- was rank
			result[5] = aura.icon
			result[6] = aura.applications
			result[7] = aura.dispelName
			result[8] = aura.duration
			result[9] = aura.expirationTime
			result[10] = aura.sourceUnit
			result[11] = aura.isStealable
			result[12] = nil -- was shouldConsolidate
			result[13] = aura.spellId
			result[14] = aura.canApplyAura
			result[15] = aura.isBossAura
			return unpack(result, 1, 15)
		end
	until not aura
end

-- Unit capability helper functions with intelligent caching
-- ----------------------------------------------------------------------------

-- Checks if the player can attack the specified unit with cached results
-- Uses time-based caching to significantly reduce API calls
-- @param unit The unit ID to check
-- @return boolean True if the player can attack the unit
local function canPlayerAttackUnit(unit)
    if not unit then return false end
    
    local result = unitCapabilityCache["attack_" .. unit]
    if result == nil then
        result = UnitCanAttack("player", unit)
        cleanUnitCapabilityCache()
        unitCapabilityCache["attack_" .. unit] = result
        -- Add timestamp for cache aging
        unitCapabilityCache["attack_" .. unit .. "_time"] = GetTimePreciseSec()
    end
    return result
end

-- Checks if the player can assist the specified unit with cached results
-- Uses time-based caching to significantly reduce API calls
-- @param unit The unit ID to check
-- @return boolean True if the player can assist the unit
local function canPlayerAssistUnit(unit)
    if not unit then return false end
    
    local result = unitCapabilityCache["assist_" .. unit]
    if result == nil then
        result = UnitCanAssist("player", unit)
        cleanUnitCapabilityCache()
        unitCapabilityCache["assist_" .. unit] = result
        -- Add timestamp for cache aging
        unitCapabilityCache["assist_" .. unit .. "_time"] = GetTimePreciseSec()
    end
    return result
end

-- Iterator wrapper to handle table recycling
-- Ensures tables used for iterator results are properly recycled
-- This is critical for performance during rapid aura scanning
-- @param iterator The iterator function
-- @param unit The unit ID to iterate on
-- @param index The current index
-- @return The unpacked values from the iterator
local function iteratorWrapper(iterator, unit, index)
    local values = {iterator(unit, index)}
    if values[1] then
        local result = values
        -- Schedule table for recycling on next frame
        lib.pendingRelease = lib.pendingRelease or {}
        table.insert(lib.pendingRelease, result)
        return unpack(values)
    end
end

-- Optimized time-based cache cleaning system
-- Removes entries older than the specified maximum age
-- More efficient than wiping the entire cache as it preserves recent entries
-- @param cache The cache table to clean
-- @param maxAge Maximum age in seconds for entries to remain valid
local function cleanCachesByTime(cache, maxAge)
    local currentTime = GetTimePreciseSec()
    local keysToRemove = {}
    
    -- Find entries older than maxAge
    for key, timestamp in pairs(cache) do
        if key:find("_time$") and (currentTime - timestamp) > maxAge then
            -- Find the base key
            local baseKey = key:gsub("_time$", "")
            table.insert(keysToRemove, baseKey)
            table.insert(keysToRemove, key)
        end
    end
    
    -- Remove outdated entries
    for _, key in ipairs(keysToRemove) do
        cache[key] = nil
    end
    
    -- If cache is still too large, do a complete wipe as fallback
    local cacheSize = 0
    for _ in pairs(cache) do cacheSize = cacheSize + 1 end
    if cacheSize > MAX_UNIT_CACHE_SIZE * 2 then -- account for timestamp entries
        wipe(cache)
    end
end

-- Initialize the frame for table recycling if needed
-- This provides a timer-based approach to safely release tables
-- after they're no longer being used by iterator consumers
if not lib.recycleFrame then
    lib.recycleFrame = CreateFrame("Frame")
    lib.pendingRelease = {}
    lib.recycleFrame:SetScript("OnUpdate", function()
        if #lib.pendingRelease > 0 then
            for i=#lib.pendingRelease, 1, -1 do
                releaseTable(lib.pendingRelease[i])
                table.remove(lib.pendingRelease, i)
            end
        end
    end)
end

--- Iterate through unit (de)buffs that can be dispelled by the player.
-- @name LibDispellable:IterateDispellableAuras
-- @param unit (string) The unit to scan.
-- @param buffs (boolean) true to test buffs instead of debuffs (offensive dispel).
-- @param allDispellable (boolean) Include auras that can be dispelled even if the player cannot.
-- @return A triplet usable in the "in" part of a for ... in ... do loop.
-- @usage
--   for index, spellID, name, _, icon, applications, dispelType, duration, expirationTime, sourceUnit, isStealable, _, auraspellID, canApplyAura, isBossAura in LibDispellable:IterateDispellableAuras("target", true) do
--     print("Can dispel", name, "on target using", GetSpellInfo(spellID))
--   end
function lib:IterateDispellableAuras(unit, buffs, allDispellable)
    -- Perform optimized time-based cache cleanup
    cleanCachesByTime(unitCapabilityCache, 3.0) -- 3 seconds cache lifetime
    
	if buffs and canPlayerAttackUnit(unit) and (allDispellable or next(self.buff)) then
		local iterator = allDispellable and allBuffIterator or buffIterator
		return iteratorWrapper, iterator, unit, 0
	elseif not buffs and canPlayerAssistUnit(unit) and (allDispellable or next(self.debuff)) then
		local iterator = allDispellable and allDebuffIterator or debuffIterator
		return iteratorWrapper, iterator, unit, 0
	else
		return noop
	end
end

--- Test if the given spell can be used to dispel something on the given unit.
-- @name LibDispellable:CanDispelWith
-- @param unit (string) The unit to check.
-- @param spellID (number) The spell to use.
-- @return true if the
-- @usage
--   if LibDispellable:CanDispelWith('focus', 4987) then
--     -- Tell the user that Cleanse (id 4987) could be used to dispel something from the focus
--   end
function lib:CanDispelWith(unit, spellID)
    -- Use cached result if available
    local cacheKey = unit .. "_" .. spellID
    local cachedResult = canDispelWithCache[cacheKey]
    local cachedTime = canDispelWithCache[cacheKey .. "_time"]
    local currentTime = GetTimePreciseSec()
    
    -- Cache hit with unexpired entry (3 second cache lifetime)
    if cachedResult ~= nil and cachedTime and (currentTime - cachedTime) < 3.0 then
        return cachedResult
    end
    
    -- Check if we can dispel with this spell
    local isOffensive = self.spells[spellID] == 'offensive'
    local result = false
    
	for index, spell in self:IterateDispellableAuras(unit, isOffensive) do
		if spell == spellID then
			result = true
			break
		end
	end
	
	-- Cache the result with timestamp
	cleanCanDispelWithCache()
	canDispelWithCache[cacheKey] = result
	canDispelWithCache[cacheKey .. "_time"] = currentTime
	
	return result
end

--- Test if player can dispel anything.
-- @name LibDispellable:HasDispel
-- @return boolean true if the player has any spell that can be used to dispel something.
function lib:HasDispel()
	return next(self.spells)
end

--- Get an iterator of the dispel spells.
-- @name LibDispellable:IterateDispelSpells
-- @return a (iterator, data, index) triplet usable in for .. in loops.
--  Each iteration returns a spell id and the general dispel type: "offensive" or "debuff"
function lib:IterateDispelSpells()
	return next, self.spells, nil
end

-- Function to manually clear all caches (can be called by addons in specific situations)
-- Performs a complete reset of all caching systems
-- Use this for critical scenarios or when cache invalidation is absolutely necessary
-- For example: talent changes, spec switches, or addon initialization
function lib:InvalidateCaches()
    wipe(lib.dispellableCache or {})
    lib.dispellableCount = 0
    
    -- Clear all caches including timestamp entries
    wipe(dispelTypeCache)
    wipe(unitCapabilityCache)
    wipe(canDispelWithCache)
    
    -- Also clean up any pending table releases
    if lib.pendingRelease then
        for i = #lib.pendingRelease, 1, -1 do
            releaseTable(lib.pendingRelease[i])
            table.remove(lib.pendingRelease, i)
        end
    end
    
    -- Clear table cache in case of memory pressure
    tableCache = {}
end

-- Initialization
if IsLoggedIn() then
	lib:UpdateSpells()
end


