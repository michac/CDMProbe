-- HudBurst.lua — the BURST WINDOW, the sequence pane's SECOND consumer.  M4.
--
-- The sibling of HudOpener, and the payoff of factoring the sequence out.  Where
-- the opener arms the pane OUT of combat for the pull, this arms the SAME pane IN
-- combat when the engine flips to BURST mode (Tyrant coming up + the board
-- staged, HudState.Mode), showing the burn order for the window.  It is DATA + A
-- TRIGGER, not new machinery: HudPane draws, HudState decides the mode, this
-- turns that transition into an arm/dissolve.
--
-- OWNERSHIP.  The pane is shared, so this only ever touches its OWN arm (tagged
-- "burst").  If the opener still owned the pane when the window opened, B.Arm
-- re-arms it as "burst" and the opener's ownership check quietly stops it — one
-- pane, re-armed, never two.
--
-- SAME FENCES AS THE OPENER.  No secret reads, no events of its own: it advances
-- off the casts HudState already watches and dissolves off a plain elapsed-time
-- clock plus the mode leaving BURST.  BEST-GUESS by construction (the BURST mode
-- rides the napkin's §7.3 Tyrant clock); safe because the mode's capping rule
-- only ever HOLDS a press, and the strip only ever DESCRIBES the window.
local ADDON, ns = ...

ns.HudBurst = {}
local B = ns.HudBurst

-- Backstop dissolve: the mode leaving BURST closes the window normally, but if it
-- somehow lingers, this caps the arm at ~15s (mirrors HudOpener's TYRANT_WINDOW).
local BURST_WINDOW = 15

B.active   = false   -- does the pane currently hold OUR (burst) arm?
B.openedAt = nil     -- GetTime() the window opened, for the backstop clock

-- Gated behind the same opt-in as the opener: the sequence helper is one
-- instructional feature with two use-cases, and it is on notice (§0.5.8.7 §0), so
-- both halves share the single `/cdmp hud opener on` switch.
local function enabled()
  local v = ns.db and ns.db.hud and ns.db.hud.opener
  return v ~= nil and v ~= false and v ~= "off"
end

-- Resolve an override spellID back to its BASE, so a transformed press (Ruination
-- for HoG, Infernal Bolt for SB) still matches its authored step.  Same reverse
-- scan the opener uses.
local function baseOfCast(spellID)
  local ov = ns.HudState and ns.HudState.override
  if ov then
    for base, over in pairs(ov) do
      if over == spellID then return base end
    end
  end
  return spellID
end

-- Build the render spec from ns.SpecBurst with each step's KEYBIND resolved (the
-- strip shows keys, not names) — same shape as HudOpener.armSpec.  Resolved at
-- ARM time; an unbound step keeps its name as a fallback (HudPane/HudQueue do that).
local function armSpec()
  local src = ns.SpecBurst
  if not src then return nil end
  local out = { header = src.header, preamble = src.preamble,
                prereqs = src.prereqs, steps = {} }
  for i, s in ipairs(src.steps or {}) do
    local key = ns.HudBinds and ns.HudBinds.Get(s.spell)
    if not key and s.alt and ns.HudBinds then key = ns.HudBinds.Get(s.alt) end
    out.steps[i] = { spell = s.spell, alt = s.alt, label = s.label, key = key,
                     count = s.count, optional = s.optional, note = s.note }
  end
  return out
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
function B.Arm()
  if not ns.HudPane then return end
  local spec = armSpec()
  if not spec then return end
  B.active   = true
  B.openedAt = GetTime()
  -- Primed (start-on-first-key) via HudPane, tagged "burst" so the opener can't
  -- advance it and the strip waits for the actual Tyrant press to begin draining.
  ns.HudPane.Arm(spec, spec.prereqs, "burst")
  if ns.HudLog then ns.HudLog.Note("queue", "burst armed") end
end

-- Driven off the MODE, from S.PaintRail's tail.  Arms on entering BURST, dissolves
-- on leaving it.  In-combat only (BURST is an in-combat mode); the opener owns the
-- out-of-combat pane.
function B.OnMode(mode)
  if not enabled() then if B.active then B.Dissolve() end return end
  if not InCombatLockdown() then return end
  local isBurst = (mode == "BURST")
  if isBurst and not B.active then
    B.Arm()
  elseif not isBurst and B.active then
    B.Dissolve()
  end
end

-- A SUCCEEDED cast.  Advances the strip if we own it.  Called from HudState's
-- SUCCEEDED branch, beside the opener's OnCast.
function B.OnCast(spellID)
  if not (ns.HudPane and ns.HudPane.OwnedBy("burst")) then return end
  local base = baseOfCast(spellID)
  if ns.HudPane.Advance(base) and ns.HudLog then
    local info = ns.HudPane.Info()
    ns.HudLog.Note("queue", "burst advanced " .. (ns.SpellName(base) or tostring(base))
      .. " -> " .. (info.current or "done"))
  end
  if ns.HudPane.IsEmpty() then B.Dissolve() end
end

-- The backstop clock + prereqs refresh, on S.Recompute's tail (no new ticker).
function B.Tick()
  if not (ns.HudPane and ns.HudPane.OwnedBy("burst")) then return end
  ns.HudPane.RefreshPrereqs()
  if B.openedAt and (GetTime() - B.openedAt) >= BURST_WINDOW then B.Dissolve() end
end

function B.Dissolve()
  if ns.HudPane and ns.HudPane.OwnedBy("burst") then
    if ns.HudLog then ns.HudLog.Note("queue", "burst dissolved") end
    ns.HudPane.Dissolve("burst")
  end
  B.active   = false
  B.openedAt = nil
end

-- Leaving combat / SetHud(false): the window is closed.
function B.OnCombatEnd() B.Dissolve() end
function B.Hide() B.Dissolve() end

--------------------------------------------------------------------------------
-- Status (`/cdmp hud status`)
--------------------------------------------------------------------------------
function B.StatusText()
  if not enabled() then return "|cff808080off|r  (shares |cffffffff/cdmp hud opener on|r)" end
  if ns.HudPane and ns.HudPane.OwnedBy("burst") then
    local info = ns.HudPane.Info()
    return string.format("|cff88ff88on|r — window open: %s (%d/%d)%s",
      info.current or "?", info.cursor or 0, info.total or 0,
      info.primed and "  |cffffd100primed|r" or "")
  end
  return "|cff88ff88on|r — idle (arms when the mode flips BURST)"
end
