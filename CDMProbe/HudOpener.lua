-- HudOpener.lua — the pre-pull OPENER, first consumer of HudQueue.  M3c-c2.
--
-- WHAT IT OWNS.  The Demonology opener (ns.SpecOpener): when to ARM it (out of
-- combat — the §0.5.8.2(a) pre-pull affordance), how to ADVANCE it (our own
-- casts, resolved to the BASE identity so a transformed press still matches its
-- step), and when to DISSOLVE it (the first Tyrant window closes, or the script
-- drains).  HudQueue draws; this decides.  M4's burst window is the second
-- consumer and plugs into HudQueue the same way — a sibling of this file.
--
-- INFORM, DON'T INSTRUCT (§0.5.8.7 §0).  The opener is the ONLY instructional
-- widget in the project and is on notice: it shows the SHAPE of the opening as a
-- draining ghost of KEYBINDS (not ability names), never "press this now".  It is
-- DEFAULT OFF for the same reason — opt in with `/cdmp hud opener on`.  It draws
-- as a LEFT-TO-RIGHT strip ABOVE the cooldown panel.
--
-- NO SECRET READS, NO NEW EVENTS.  It advances off casts HudState already
-- watches, and dissolves off the napkin's fixed-60s Tyrant clock read as a plain
-- elapsed-time compare.  HudState/HudCore fire a handful of one-line calls at it;
-- it registers nothing of its own.
local ADDON, ns = ...

ns.HudOpener = {}
local O = ns.HudOpener

-- The Tyrant window the opener hands off to sustain at — ~15s after the Tyrant
-- cast (guidance-model.md §0.5.8.2(a): "the queue dissolves when the first Tyrant
-- window closes").  A plain elapsed-time compare, no secret read.
local TYRANT_WINDOW = 15
-- The opener strip sits ABOVE the panel — clear of the DEMO.SYS terminal header,
-- which hangs at viewer +9 (HudChrome buildTerminal).
local GAP           = 24

O.inst     = nil     -- the HudQueue instance (memoised on the viewer)
O.tyrantAt = nil     -- GetTime() of the Tyrant cast, for the dissolve clock

-- Is the opener enabled?  Any truthy, non-"off" setting counts (the DB stored
-- the legacy "1a" before the variant machinery was scrubbed; it is treated as
-- plain "on").
local function enabled()
  local v = ns.db and ns.db.hud and ns.db.hud.opener
  return v ~= nil and v ~= false and v ~= "off"
end

-- Reverse the live override map.  A cast SUCCEEDS under the OVERRIDE spellID while
-- a Demonic Art is armed (Ruination, not Hand of Gul'dan), but the opener steps
-- are authored with BASE ids — so resolve back, or a transformed press wouldn't
-- match its step.  Reads ns.HudState.override (base -> override); a small scan.
-- (Deliberately the OPPOSITE convention from keybinds, which resolve off the base
-- because the override is on no action bar — same split B1 made for the dot.)
local function baseOfCast(spellID)
  local ov = ns.HudState and ns.HudState.override
  if ov then
    for base, over in pairs(ov) do
      if over == spellID then return base end
    end
  end
  return spellID
end

-- Build a render spec from ns.SpecOpener with each step's KEYBIND resolved (the
-- strip shows keys, not names).  Resolved at ARM time — the opener only arms out
-- of combat, exactly when the keybind cache (HudBinds, OOC-only) is fresh.  An
-- unbound step keeps its name as a fallback (HudQueue does that); an `alt` step
-- prefers the primary spell's key, then the alt's.
local function armSpec()
  local src = ns.SpecOpener
  if not src then return nil end
  local out = { header = src.header, preamble = src.preamble, steps = {} }
  for i, s in ipairs(src.steps or {}) do
    local key = ns.HudBinds and ns.HudBinds.Get(s.spell)
    if not key and s.alt and ns.HudBinds then key = ns.HudBinds.Get(s.alt) end
    local copy = { spell = s.spell, alt = s.alt, label = s.label, key = key,
                   count = s.count, optional = s.optional, note = s.note }
    out.steps[i] = copy
  end
  return out
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- ARM for the coming pull.  Out of combat ONLY (the pre-pull affordance); refuses
-- itself in combat so a rebind or combat-exit call landing mid-fight costs
-- nothing.  Called from rebind()'s tail (login / /reload / zone-in / layout) and
-- on leaving combat (back to PREP for the next pull).
function O.Arm()
  if not enabled() then O.Dissolve() return end
  if InCombatLockdown() then return end
  local viewer = ns.Hud and ns.Hud.IconViewer and ns.Hud.IconViewer()
  if not viewer then return end
  O.inst = ns.HudQueue.Ensure(viewer, "opener", GAP, "horizontal")
  if not O.inst then return end
  O.tyrantAt = nil
  local spec = armSpec()
  if not spec then return end
  O.inst:Arm(spec)
  if ns.HudLog then ns.HudLog.Note("queue", "opener armed") end
end

-- A SUCCEEDED cast.  Advances the queue and, on a Tyrant cast, starts the
-- dissolve clock.  Called from HudState's SUCCEEDED branch.
function O.OnCast(spellID)
  if not O.inst or not O.inst.armed then return end
  local base = baseOfCast(spellID)
  local TYR = ns.SpecIDs and ns.SpecIDs.TYRANT
  if base == TYR then O.tyrantAt = GetTime() end
  if O.inst:Advance(base) then
    if ns.HudLog then
      local info = O.inst:Info()
      ns.HudLog.Note("queue", "advanced " .. (ns.SpellName(base) or tostring(base))
        .. " -> " .. (info.current or "done"))
    end
  end
  if O.inst:IsEmpty() then O.Dissolve() end
end

-- The dissolve clock, checked on S.Recompute's tail (no new ticker) — the first
-- Tyrant window closing is the handoff to sustain.
function O.Tick()
  if not O.inst or not O.inst.armed then return end
  if O.tyrantAt and (GetTime() - O.tyrantAt) >= TYRANT_WINDOW then O.Dissolve() end
end

function O.Dissolve()
  if O.inst and O.inst.armed then
    if ns.HudLog then ns.HudLog.Note("queue", "opener dissolved") end
    O.inst:Dissolve()
  end
  O.tyrantAt = nil
end

-- Leaving combat: we are back in PREP, so re-arm for the next pull.
function O.OnCombatEnd()
  O.Dissolve()
  O.Arm()
end

-- SetHud(false): hide.
function O.Hide()
  O.Dissolve()
end

--------------------------------------------------------------------------------
-- Status (`/cdmp hud status`)
--------------------------------------------------------------------------------
function O.StatusText()
  if not enabled() then return "|cff808080off|r  (|cffffffff/cdmp hud opener on|r to enable)" end
  if O.inst and O.inst.armed then
    local info = O.inst:Info()
    return string.format("|cff88ff88on|r — armed: %s (%d/%d)%s",
      info.current or "?", info.cursor, info.total,
      O.tyrantAt and "  |cffffd100Tyrant window open|r" or "")
  end
  return "|cff88ff88on|r — idle (arms out of combat)"
end
