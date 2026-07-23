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

-- D2 (M4.1) — the BURN window.  The mode leaves BURST the INSTANT Tyrant is cast
-- (Tyrant -> 60s CD), but the burn — HoG HoG -> cores -> Implosion — is the ~18s
-- AFTER the cast (Tyrant's active duration).  So the pane's lifecycle is decoupled
-- from the mode: once Tyrant is pressed the pane keeps walking for BURN_WINDOW,
-- capped by drain / this clock / combat-end.  A new drifting clock, but it only
-- ever holds the pane UP slightly long (the safe direction).
local BURN_WINDOW = 18
-- WINDUP backstop: while armed but BEFORE Tyrant is pressed, cap the arm so a mode
-- that lingers BURST without a Tyrant cast doesn't leave the pane up forever.
local WINDUP_MAX = 20

B.active       = false  -- does the pane currently hold OUR (burst) arm?
B.openedAt     = nil    -- GetTime() the window armed, for the windup backstop
B.burning      = false  -- has Tyrant been cast?  (the burn is running)
B.tyrantCastAt = nil    -- GetTime() of the Tyrant cast, for the burn clock

-- Gated behind the same opt-in as the opener: the sequence helper is one
-- instructional feature with two use-cases, and it is on notice (§0.5.8.7 §0), so
-- both halves share the single `/cdmp hud opener on` switch.
local function enabled()
  local v = ns.db and ns.db.hud and ns.db.hud.opener
  return v ~= nil and v ~= false and v ~= "off"
end

-- E (M4.4) — is this base one of the BURST sequence steps (or a burst-aligned
-- summon)?  Scopes the floating reward text so it stays a burst celebration, not
-- a running combat log.  Built lazily from ns.SpecBurst.steps once.
local burstStepSet
local function isBurstStep(spellID)
  if type(spellID) ~= "number" then return false end
  if not burstStepSet then
    burstStepSet = {}
    for _, s in ipairs((ns.SpecBurst and ns.SpecBurst.steps) or {}) do
      if s.spell then burstStepSet[s.spell] = true end
      if s.alt then burstStepSet[s.alt] = true end
    end
  end
  if burstStepSet[spellID] then return true end
  return ns.SpecInfo(spellID).burstAlign and true or false
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
  -- D1 (M4.1) — BURST may not preempt an unfinished OPENER.  The opener's first
  -- Tyrant window IS the first burst window; it dissolves on its own tyrantAt clock
  -- / drain, after which the mode won't re-enter BURST until the NEXT Tyrant (60s),
  -- and burst arms that window normally.  Returning here (not setting B.active)
  -- means OnMode simply retries each mode paint until the opener lets go — cheap.
  if ns.HudPane.OwnedBy("opener") then return end
  local spec = armSpec()
  if not spec then return end
  B.active       = true
  B.openedAt     = GetTime()
  B.burning      = false
  B.tyrantCastAt = nil
  -- Primed (start-on-first-key) via HudPane, tagged "burst" so the opener can't
  -- advance it and the strip waits for the actual first summon to begin draining.
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
    -- D2 — the mode correctly leaves BURST for SPEND at the Tyrant cast (post-cast
    -- you DUMP; the capping rule releasing HoG is right), but the PANE must keep
    -- walking the burn.  Do NOT dissolve while burning and inside BURN_WINDOW;
    -- B.Tick closes it on drain / clock / combat-end.
    if B.burning and B.tyrantCastAt and (GetTime() - B.tyrantCastAt) < BURN_WINDOW then
      return
    end
    B.Dissolve()
  end
end

-- A SUCCEEDED cast.  Advances the strip if we own it.  Called from HudState's
-- SUCCEEDED branch, beside the opener's OnCast.
function B.OnCast(spellID)
  if not (ns.HudPane and ns.HudPane.OwnedBy("burst")) then return end
  local base = baseOfCast(spellID)
  -- D2 — a Tyrant press OPENS THE BURN.  Mark it here so OnMode(≠BURST), which
  -- fires a beat later when the cast spends shards and the mode flips to SPEND,
  -- does not dissolve the pane out from under the burn.
  local TYR = ns.SpecIDs and ns.SpecIDs.TYRANT
  if base == TYR then
    B.burning      = true
    B.tyrantCastAt = GetTime()
  end
  -- E (M4.4) — reward text over the character for landing a burst-window press.
  -- Scoped to burst steps so it stays a celebration; Tyrant reads loudest (A3).
  if ns.HudFloat and isBurstStep(base) then
    ns.HudFloat.Say(ns.SpellName(base) or tostring(base), { loud = base == TYR })
  end
  if ns.HudPane.Advance(base) and ns.HudLog then
    local info = ns.HudPane.Info()
    ns.HudLog.Note("queue", "burst advanced " .. (ns.SpellName(base) or tostring(base))
      .. " -> " .. (info.current or "done"))
  end
  if ns.HudPane.IsEmpty() then B.Dissolve() end
end

-- C2 (M4.4) — a cast STARTED.  If we own the pane, shimmer the current step (the
-- start-side sibling of OnCast).  Resolves the override back to base like OnCast.
function B.OnCastStart(spellID)
  if not (ns.HudPane and ns.HudPane.OwnedBy("burst")) then return end
  ns.HudPane.CastStart(baseOfCast(spellID))
end

-- The dissolve clocks + prereqs refresh, on S.Recompute's tail (no new ticker).
-- Two phases: while BURNING (Tyrant cast) the burn clock runs; before that, the
-- windup backstop caps an arm whose Tyrant never comes.
function B.Tick()
  if not (ns.HudPane and ns.HudPane.OwnedBy("burst")) then return end
  ns.HudPane.RefreshPrereqs()
  local now = GetTime()
  if B.burning then
    if B.tyrantCastAt and (now - B.tyrantCastAt) >= BURN_WINDOW then B.Dissolve() end
  elseif B.openedAt and (now - B.openedAt) >= WINDUP_MAX then
    B.Dissolve()
  end
end

function B.Dissolve()
  if ns.HudPane and ns.HudPane.OwnedBy("burst") then
    if ns.HudLog then ns.HudLog.Note("queue", "burst dissolved") end
    ns.HudPane.Dissolve("burst")
  end
  B.active       = false
  B.openedAt     = nil
  B.burning      = false
  B.tyrantCastAt = nil
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
