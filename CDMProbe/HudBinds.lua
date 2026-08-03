-- HudBinds.lua — action-bar scan -> keybind string per spellID (cached).
--
-- Identity chrome, deliberately OUTSIDE the cue contract: a keybind is not a rotation
-- signal, it's how you know which icon is which button.
--
-- Cost control: the 180-slot scan is CACHED, DEBOUNCED, and out of combat unless the
-- cache is COLD (see the cold-cache exemption on `runScan` — the fence is a COST rule, and
-- an empty cache has no churn to prevent).  Anything that could invalidate
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
B.stats = { slots = 0, bound = 0, scans = 0, deferred = 0, coalesced = 0,
             retried = 0, cold = 0, settled = 0 }

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
-- swallowed.  A timer landing during a fight leaves the cache dirty and
-- PLAYER_REGEN_ENABLED re-arms it — UNLESS the cache is cold, see runScan.
local DEBOUNCE = 0.5
local scheduled = false

-- An EMPTY scan is not an answer: a scan that resolved ZERO bindings keeps `dirty` and
-- re-arms, up to a cap.  Without this, `scan()` cleared `dirty` over an empty map and the
-- only thing that could ever set it again was a bar/binding event — and on a login
-- auto-enable, `B.Start` (which runs from `St.Acquire`) registers for those events AFTER
-- the client has already fired them during load.  Capped because "no bindings at all" is a
-- legitimate state for a fresh character, and an uncapped retry would poll all session.
--
-- ⚠ PROVENANCE, because the comment here used to overclaim (corrected v0.32.51).  This
-- fence is REASONED, not field-proven.  It was written for the 2026-07-31 report of
-- `key=none` on all 17 displayed rows — but that turned out to be the COMBAT GATE below
-- (`0 scan(s)`: the scan had never run at all, so this fence was never even reached), and
-- so did the earlier partial-keys report, and so did "moving the CDM in Edit Mode fixed
-- it" — you cannot open Edit Mode in combat, so that was simply the first out-of-combat
-- rescan.  Kept anyway because caching an empty scan as authoritative is a real hole on
-- its own, and because the cold-cache exemption below depends on this to keep retrying.
-- But do NOT cite it as the cause of a field symptom: it has never been observed firing.
local EMPTY_RETRIES = 12         -- ~6 s of cover at the debounce interval; then believe it
local emptyRetries = 0

-- The SETTLE cap — see the `changed` branch in runScan.  Smaller than EMPTY_RETRIES because
-- this one confirms an answer we already have rather than waiting for a first one; the
-- steady case uses exactly one of these.  Reset by `invalidate()`, so every real bar/binding
-- event gets a fresh settle budget.
local SETTLE_RETRIES = 6
local settleRetries = 0

-- ⚠ THE COLD-CACHE EXEMPTION (v0.32.51).  The combat fence is a COST rule, NOT a safety
-- one: `GetActionInfo` / `GetBindingKey` are unprotected reads that taint nothing, and the
-- reason for "never in combat" is the v0.6.0 story in the header — ~2000 full scans burned
-- in one city session by rescanning on every ACTIONBAR_SLOT_CHANGED.
--
-- That reasoning does not survive an EMPTY cache.  With nothing cached there is no churn to
-- prevent, and the fence buys nothing while costing everything: the whole HUD runs keyless.
-- THIS IS THE ONE THE FIELD ACTUALLY FOUND, and it explains every symptom in the
-- 2026-07-31 session on its own.  `/cdmp hud status` read `0 bound / 0 slot(s), 0 scan(s),
-- deferred 3x` — a target-dummy session is CONTINUOUS COMBAT, so the scan had never run
-- once and the combat exit it was deferring to was never going to come.  The earlier
-- "only SOME icons have keys" report is the same gate one step milder: a bar or hero-tree
-- swap in combat leaves the cache STALE for exactly the spells whose bar id moved, and it
-- cannot refresh until the fight ends.
--
-- So: a COLD cache scans in combat, a WARM one still defers.  One 180-slot read beats an
-- entire session with no key hints, and the retry cap above bounds it either way.
local function runScan()
  scheduled = false
  if not B.dirty then return end
  local cold = B.stats.bound == 0
  if InCombatLockdown() then
    if not cold then
      B.stats.deferred = B.stats.deferred + 1
      return                     -- stays dirty; PLAYER_REGEN_ENABLED re-arms
    end
    B.stats.cold = B.stats.cold + 1
  end
  -- Refresh the cache; the pipeline reads it live off State (State.readCd -> HudBinds.Get)
  -- each tick, so there is nothing to notify.
  local changed = scan()
  if B.stats.bound == 0 and emptyRetries < EMPTY_RETRIES then
    emptyRetries = emptyRetries + 1
    B.stats.retried = B.stats.retried + 1
    B.dirty = true               -- the scan does NOT get to say "done" on nothing
    scheduled = true
    C_Timer.After(DEBOUNCE, runScan)
  elseif changed and settleRetries < SETTLE_RETRIES then
    -- ⚠ A PARTIAL SCAN IS NOT AN ANSWER EITHER — the field defect of 2026-08-03.
    --
    -- The empty-scan fence above only fires on ZERO bindings, so a scan that resolved MOST
    -- spells but not all of them cleared `dirty` and was cached as authoritative forever.
    -- On a login that is the normal case: the action bars populate over several frames, and
    -- `B.Start` (from `St.Acquire`) registers ACTIONBAR_SLOT_CHANGED *after* the client has
    -- already fired it during load — so the slots that arrive late never invalidate anything
    -- and their spells stay keyless for the whole session.  Reported as exactly that:
    -- "Crusader Strike and Judgment have no key on login; log out and back in and they do."
    --
    -- The generalisation: an EMPTY scan is a special case of a scan that is STILL CHANGING.
    -- So keep rescanning while the answer keeps moving, and stop as soon as two consecutive
    -- scans agree.  `scan()` already returns exactly that signal.
    --
    -- Converges by construction and costs one extra 180-slot read in the steady case: the
    -- first scan after any invalidation always reports `changed` (the map was empty or the
    -- bar really did move), the confirming scan reports unchanged, and the loop ends.  The
    -- cap bounds the pathological case — a player actively dragging bars around — and the
    -- counter resets on the next real event so a genuine change always gets a fresh settle.
    settleRetries = settleRetries + 1
    B.stats.settled = B.stats.settled + 1
    B.dirty = true
    scheduled = true
    C_Timer.After(DEBOUNCE, runScan)
  end
end

local function invalidate()
  B.dirty = true
  -- A real event means the world moved: give the settle loop a fresh budget so a bar swap
  -- late in a session gets the same convergence a login does.
  settleRetries = 0
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
  -- registered event goes through the same debounce.  ⚠ ...with one exception: leaving
  -- combat on a COLD cache is always worth a scan, even when `dirty` was cleared by an
  -- exhausted retry run — otherwise a session that started keyless stays keyless.  The
  -- retry budget resets there too, since combat exit is a genuinely new chance.
  if event == "PLAYER_REGEN_ENABLED" then
    if not B.dirty and B.stats.bound > 0 then return end
    emptyRetries = 0
  end
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
  runScan()                      -- decides for itself: a COLD cache scans even in combat
  if B.dirty and not scheduled then invalidate() end   -- deferred (warm + combat): re-arm
end
