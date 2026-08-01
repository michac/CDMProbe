-- HudBinds.lua — action-bar scan -> keybind string per spellID (cached).
--
-- Identity chrome, deliberately OUTSIDE the cue contract: a keybind is not a rotation
-- signal, it's how you know which icon is which button.
--
-- Cost control: the 180-slot scan is CACHED,
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
B.stats = { slots = 0, bound = 0, scans = 0, deferred = 0, coalesced = 0, retried = 0 }

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

-- ⚠ THE LOGIN RACE (v0.32.50).  An EMPTY scan is not an answer, it is a RACE — and until
-- this fence existed it was cached as authoritative and never re-armed, so the whole HUD
-- ran keyless until something happened to touch a bar.  The mechanism:
--
--   * `B.Start` runs from `St.Acquire`, i.e. the moment the HUD is enabled — which on a
--     login auto-enable is early, before the client has populated action slots and
--     bindings.
--   * The invalidating events that WOULD have healed it (`UPDATE_BINDINGS`,
--     `ACTIONBAR_SLOT_CHANGED`) had already fired during load, BEFORE `Start` registered
--     for them.  So `dirty` was cleared over an empty map and nothing ever set it again.
--
-- Measured in the field 2026-07-31: all 17 displayed rows read `key=none`, and MOVING THE
-- CDM in Edit Mode fixed them — because that finally raised a binding event.  A partial
-- scan (bar 1 up, multibars not yet) is the same race caught mid-flight, and produces the
-- more confusing symptom: SOME icons keyed, some not.
--
-- The fence is deliberately narrow: a scan that resolved ZERO bindings keeps `dirty` and
-- re-arms, up to a cap.  Capped because "no bindings at all" is a legitimate state for a
-- fresh character, and an uncapped retry would poll for the length of the session.
local EMPTY_RETRIES = 12         -- ~6 s of cover at the debounce interval; then believe it
local emptyRetries = 0

local function runScan()
  scheduled = false
  if not B.dirty then return end
  if InCombatLockdown() then
    B.stats.deferred = B.stats.deferred + 1
    return                       -- stays dirty; PLAYER_REGEN_ENABLED re-arms
  end
  -- Refresh the cache; the pipeline reads it live off State (State.readCd -> HudBinds.Get)
  -- each tick, so there is nothing to notify.
  scan()
  if B.stats.bound == 0 and emptyRetries < EMPTY_RETRIES then
    emptyRetries = emptyRetries + 1
    B.stats.retried = B.stats.retried + 1
    B.dirty = true               -- the scan does NOT get to say "done" on nothing
    scheduled = true
    C_Timer.After(DEBOUNCE, runScan)
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

-- THE KEYBIND LADDER (roster-state-plan.md §4.1).  Candidate ids in rung order, each
-- tried through B.Get (which owns the secret guard and the SpecBindAlias fallback);
-- FIRST ID WITH A REAL BINDING WINS, otherwise nil.  Live call site: State.Build passes
-- `overrideTooltipSpellID, overrideSpellID, spellID` — rung 3 -> rung 4 -> rung 5.
--
-- ⚠ THIS LADDER IS DELIBERATELY UNLIKE THE OTHER TWO IN THE CODEBASE.  Do not "align" it:
--
--   * NO SPEC FENCES.  ns.DisplayIdentity (Viewers.lua:153-176) gates an override on
--     `declared` / `kind == "button"` / `expect ~= false`, because adopting a wrong
--     IDENTITY mis-keys a whole row.  This ladder asks the ACTION BAR instead: an id that
--     is not on a bar yields nil and falls through, so first-hit-wins is self-correcting.
--     A wrong candidate costs nothing; it simply has no binding to return.
--   * RUNGS 1 AND 2 STAY OUT.  Rung 1 (the live aura instance) and the observed live
--     override are the v0.7.0 Demonic-Art transform fence (Viewers.lua:75-80): the bar
--     slot holds the BASE through a transform, so keying on the transformed id misses.
--     Rung 2 (the elected `linkedSpellID`) was MEASURED ABSENT on 2026-07-31 — 0 of 72
--     rows carried it and `item:GetLinkedSpell()` was nil on every frame — so it is out
--     of the ladder entirely rather than merely unreachable.
--   * NOT THE SAME RUNGS AS `readCharge`, which uses 4 + 5 only (§3.2 — that one mirrors
--     Blizzard's own charge ladder, a different question with a different answer).
--
-- The motivating case is Hellcaller: the row's base is Immolate 348 while the bar holds
-- Wither (arriving as `overrideSpellID`), so base-only resolution left the icon with no
-- key hint at all.
function B.Resolve(...)
  for i = 1, select("#", ...) do
    local k = B.Get((select(i, ...)))
    if k then return k end
  end
  return nil
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
  -- The second half of the login-race fix: this one fires AFTER the bars and bindings are
  -- up, so it heals a cache that was built too early even in the case the retry cap ran
  -- out.  It is also the only registered event that fires on a plain /reload.
  ev:RegisterEvent("PLAYER_ENTERING_WORLD")
  -- Scan immediately when we can, so the first chrome attach already has keys;
  -- otherwise arm the debounce and let it land out of combat.  ⚠ Through `runScan`, NOT
  -- `scan` — this is the call most likely to land in the login race, so it is the one that
  -- most needs the empty-scan retry above.  It used to call `scan()` raw.
  B.dirty = true
  emptyRetries = 0
  if InCombatLockdown() then invalidate() else runScan() end
end
