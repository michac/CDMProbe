-- HudBinds.lua — action-bar scan -> keybind string per spellID (cached).
--
-- Identity chrome, deliberately OUTSIDE the §0.5.8 indicator contract: a keybind
-- is not a rotation signal, it's how you know which icon is which button.
--
-- Cost control (milestones "known risks"): the 180-slot scan is CACHED,
-- DEBOUNCED, and only ever runs OUT OF COMBAT.  Anything that could invalidate
-- it (bindings changed, a slot's contents changed, spec swap, bar page flip)
-- marks the cache dirty and arms a single timer; a rescan landing in combat is
-- deferred to PLAYER_REGEN_ENABLED.  Nothing here runs on a hot path.
--
-- The debounce is not optional — see the comment on `invalidate` below.  v0.6.0
-- shipped without it and burned ~2000 full scans in a single city session.
--
-- Unbound spell -> nil -> blank text.  Never a placeholder (a fake keybind is
-- worse than no keybind).
local ADDON, ns = ...

ns.HudBinds = {}
local B = ns.HudBinds

-- slot range -> binding command prefix.  Slots 13-24 are page 2 of bar 1 and
-- slots 109-180 are the extra pages: they have no bindings of their own, so they
-- are simply absent from this table and resolve to nil.
local SLOT_BARS = {
  { first = 1,   last = 12,  cmd = "ACTIONBUTTON%d" },
  { first = 25,  last = 36,  cmd = "MULTIACTIONBAR3BUTTON%d" },  -- right bar
  { first = 37,  last = 48,  cmd = "MULTIACTIONBAR4BUTTON%d" },  -- right bar 2
  { first = 49,  last = 60,  cmd = "MULTIACTIONBAR2BUTTON%d" },  -- bottom right
  { first = 61,  last = 72,  cmd = "MULTIACTIONBAR1BUTTON%d" },  -- bottom left
  { first = 73,  last = 84,  cmd = "MULTIACTIONBAR5BUTTON%d" },
  { first = 85,  last = 96,  cmd = "MULTIACTIONBAR6BUTTON%d" },
  { first = 97,  last = 108, cmd = "MULTIACTIONBAR7BUTTON%d" },
}

local function bindingCommand(slot)
  for _, bar in ipairs(SLOT_BARS) do
    if slot >= bar.first and slot <= bar.last then
      return string.format(bar.cmd, slot - bar.first + 1)
    end
  end
  return nil
end

-- "SHIFT-BUTTON3" -> "sM3".  Terminal chrome is ~10px in a ~28px column, so the
-- string has to be tiny; modifiers become single lowercase letters.
local KEY_SHORT = {
  ["BUTTON1"] = "M1", ["BUTTON2"] = "M2", ["BUTTON3"] = "M3", ["BUTTON4"] = "M4",
  ["BUTTON5"] = "M5", ["MOUSEWHEELUP"] = "MU", ["MOUSEWHEELDOWN"] = "MD",
  ["NUMPADPLUS"] = "N+", ["NUMPADMINUS"] = "N-", ["NUMPADMULTIPLY"] = "N*",
  ["NUMPADDIVIDE"] = "N/", ["NUMPADDECIMAL"] = "N.",
  ["SPACE"] = "SP", ["ESCAPE"] = "ESC", ["INSERT"] = "INS", ["DELETE"] = "DEL",
  ["HOME"] = "HM", ["END"] = "END", ["PAGEUP"] = "PU", ["PAGEDOWN"] = "PD",
  ["BACKSPACE"] = "BS", ["TAB"] = "TB", ["CAPSLOCK"] = "CL",
}

local function shorten(key)
  if type(key) ~= "string" or key == "" then return nil end
  local mods = ""
  local rest = key
  while true do
    local m, tail = rest:match("^(%u+)%-(.+)$")
    if m == "SHIFT" then mods = mods .. "s"; rest = tail
    elseif m == "CTRL" then mods = mods .. "c"; rest = tail
    elseif m == "ALT" then mods = mods .. "a"; rest = tail
    else break end
  end
  local short = KEY_SHORT[rest]
  if not short then
    short = rest:gsub("^NUMPAD", "N")
    if #short > 3 then short = short:sub(1, 3) end
  end
  return mods .. short
end

-- Cache ------------------------------------------------------------------------
B.map = {}        -- spellID -> short key string
B.dirty = true
B.stats = { slots = 0, bound = 0, scans = 0, deferred = 0, coalesced = 0 }

-- Returns true if the resolved map actually CHANGED.  Callers use that to skip
-- re-attaching chrome across every item when nothing moved, which is the common
-- case: most invalidating events are noise.
local function scan()
  local prev = B.map
  local fresh = {}
  local slots, bound = 0, 0
  for slot = 1, 180 do
    local actionType, id = GetActionInfo(slot)
    local spellID
    if actionType == "spell" then
      spellID = tonumber(id)
    elseif actionType == "macro" then
      spellID = GetMacroSpell and GetMacroSpell(id) or nil
    end
    if spellID then
      slots = slots + 1
      -- First bound slot wins: a spell on several bars keeps the binding of the
      -- lowest-numbered one (bar 1 before the multibars), which is the one the
      -- player thinks of as "the" key.
      if not fresh[spellID] then
        local cmd = bindingCommand(slot)
        local key = cmd and GetBindingKey(cmd)
        local short = key and shorten(key)
        if short then
          fresh[spellID] = short
          bound = bound + 1
        end
      end
    end
  end

  local changed = false
  for k, v in pairs(fresh) do
    if prev[k] ~= v then changed = true break end
  end
  if not changed then
    for k in pairs(prev) do
      if fresh[k] == nil then changed = true break end
    end
  end

  B.map = fresh
  B.stats.slots, B.stats.bound = slots, bound
  B.dirty = false
  B.stats.scans = B.stats.scans + 1
  return changed
end

-- COALESCED rescan (v0.6.1).  v0.6.0 rescanned all 180 slots SYNCHRONOUSLY on
-- every invalidating event and then re-attached chrome to every item — and
-- ACTIONBAR_SLOT_CHANGED fires per-slot, for far more than real binding changes.
-- A single city session logged 2085 scans (~375k GetActionInfo calls), which is
-- exactly the hot-path rescan the design forbids.  Now: an event only marks the
-- cache dirty and arms ONE timer; everything arriving inside the window is
-- swallowed.  Still never scans in combat — if the timer lands during a fight it
-- leaves the cache dirty and PLAYER_REGEN_ENABLED re-arms it.
local DEBOUNCE = 0.5
local scheduled = false

local function runScan()
  scheduled = false
  if not B.dirty then return end
  if InCombatLockdown() then
    B.stats.deferred = B.stats.deferred + 1
    return                       -- stays dirty; PLAYER_REGEN_ENABLED re-arms
  end
  if scan() and ns.Hud and ns.Hud.RefreshKeybinds then
    ns.Hud.RefreshKeybinds()     -- only when the map really moved
  end
end

local function invalidate()
  B.dirty = true
  if scheduled then
    B.stats.coalesced = B.stats.coalesced + 1
    return
  end
  scheduled = true
  C_Timer.After(DEBOUNCE, runScan)
end

B.Invalidate = invalidate

-- The read path: cheap, cache-only.  If the cache is dirty we serve the stale
-- value rather than scanning — the refresh will land out of combat and the
-- chrome re-reads on the next relayout.
function B.Get(spellID)
  -- Never index with a Secret Value (that taints); an unreadable ID is simply
  -- an unbound one as far as the chrome is concerned.
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  local k = B.map[spellID]
  if k then return k end
  -- Fall back to a known alias id (e.g. Imp Lord cast 1276452 ↔ talent 136726):
  -- the bar may hold the other id than the one the CDM tracks.
  local alias = ns.SpecBindAlias and ns.SpecBindAlias[spellID]
  return (alias and B.map[alias]) or nil
end

-- Resolve for an ITEM rather than a bare spellID — the finding-3 fix (v0.7.0).
-- `item:GetSpellID()` prefers the OVERRIDE spell, so while Demonic Art has HoG
-- transformed into Ruination the item reports `434635`, which is on nobody's
-- action bar, and the keybind blanked out mid-rotation.  The action bar holds
-- the BASE spell, so resolve off that first and only fall back to the reported
-- (possibly overridden) ID for items with no base — never the other way round.
function B.GetForItem(item, reportedSpellID)
  local key = B.Get(ns.ItemBaseSpellID and ns.ItemBaseSpellID(item) or nil)
  if key then return key end
  return B.Get(reportedSpellID ~= nil and reportedSpellID or ns.ItemSpellID(item))
end

--------------------------------------------------------------------------------
-- Diagnostic: why does this spell show the key it shows?  (§7.2 items 4/5)
--------------------------------------------------------------------------------
-- A remap that "didn't get picked up" is not diagnosable from the resolved map
-- alone, because the map only records the WINNER.  There are three known ways to
-- lose, and all three are invisible in `B.map`:
--
--   1. FIRST BOUND SLOT WINS.  A spell on two bars keeps the LOWEST slot's key.
--      Remap the copy on your right bar and nothing changes, because bar 1 still
--      answers first.  Shows up here as two rows, one marked <-- used.
--   2. NO BINDABLE COMMAND.  Slots 13-24 and 109-180 are action-bar PAGES with no
--      bindings of their own, so they're absent from SLOT_BARS and resolve to
--      nil.  Shows up as a row with cmd=none.
--   3. MACRO SLOTS.  GetMacroSpell returns nil for conditional/modifier macros,
--      so the slot never maps to a spellID at all and the spell appears here with
--      NO rows whatsoever.
--   4. THE SECONDARY BINDING (found in source, M3e).  GetBindingKey(cmd) returns
--      TWO keys — primary AND secondary — and both scan() and this function only
--      ever took the first.  A player who remapped the SECONDARY binding sees no
--      change and, until now, there was NO ROW THAT SHOWED WHY.  Recorded here as
--      `key2`.  ⚠ This deliberately does NOT change which binding wins: making
--      the loser visible is the diagnosis, changing the winner is a decision that
--      needs the evidence first.
--
-- ONE 180-slot pass builds the whole reverse index (per-spell scans would be
-- 20x that).  Manual command only — this never runs on an event path.
function B.Explain()
  local bySpell = {}
  for slot = 1, 180 do
    local actionType, id = GetActionInfo(slot)
    local spellID, via
    if actionType == "spell" then
      spellID, via = tonumber(id), "spell"
    elseif actionType == "macro" then
      spellID, via = (GetMacroSpell and GetMacroSpell(id) or nil), "macro"
    end
    if spellID then
      local key, key2
      local cmd = bindingCommand(slot)
      if cmd then key, key2 = GetBindingKey(cmd) end
      local list = bySpell[spellID]
      if not list then list = {}; bySpell[spellID] = list end
      list[#list + 1] = { slot = slot, via = via, cmd = cmd,
                          key = key, key2 = key2,
                          short = key and shorten(key) or nil,
                          short2 = key2 and shorten(key2) or nil }
    end
  end
  return bySpell
end

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event)
  -- PLAYER_REGEN_ENABLED is only interesting if a rescan was owed; every other
  -- registered event goes through the same debounce.
  if event == "PLAYER_REGEN_ENABLED" and not B.dirty then return end
  invalidate()
end)

function B.Start()
  ev:RegisterEvent("UPDATE_BINDINGS")
  ev:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
  ev:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
  ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
  ev:RegisterEvent("PLAYER_REGEN_ENABLED")
  -- Scan immediately when we can, so the first chrome attach already has keys;
  -- otherwise arm the debounce and let it land out of combat.
  B.dirty = true
  if InCombatLockdown() then invalidate() else scan() end
end

function B.Stop()
  ev:UnregisterAllEvents()
end
