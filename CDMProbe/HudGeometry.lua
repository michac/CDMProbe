-- HudGeometry.lua — the SHARED geometry/binding table for the DrawList (W4 Phase 4).
--
-- WHY THIS EXISTS (docs/archive/w4-phase4-binder-plan.md, resolution #4).  Two producers
-- must emit the SAME DrawList geometry: the Binder (live, Guidance -> DrawList) and
-- the Renderer's hand-authored `/cdmp rt` fixtures (the reference the
-- Renderer was dialled in against).  If each carried its own dot-corner / glow rule /
-- panel + bar positions they would drift, and the Phase-4 close-the-loop test
-- (golden Guidance -> Binder -> the exact fixture) would compare two hand-copied
-- constants instead of proving the pipeline.  So the constants AND the tiny builders
-- that stamp them onto a cue / bar / panel live HERE, and BOTH sides call in — they
-- agree by construction, not by vigilance.
--
-- PURE DATA + PURE BUILDERS: no frames, no game reads, no colour (the Renderer owns
-- emphasis -> pixels).  Loaded before Binder.lua and Renderer.lua in the .toc.
local ADDON, ns = ...

ns.HudGeometry = {}
local G = ns.HudGeometry

--------------------------------------------------------------------------------
-- The constants (were the fixture locals DOT + the shards()/panel literals in
-- Renderer.lua).
--------------------------------------------------------------------------------
-- The cue dot rides INSIDE the icon's upper-right corner (3px inset), 12px square.
-- Anchored RELATIVE to its handle's frame, so it ride-alongs the icon for free.
G.DOT = { point = "TOPRIGHT", relPoint = "TOPRIGHT", dx = -3, dy = -3, size = 12 }

-- The keybind hint rides the icon's UPPER-LEFT corner, diagonally opposite the dot.  It
-- lived as a literal in Renderer.lua's drawCueKey until Phase 3 gave keybinds their own
-- DrawList channel; it belongs here for the same reason G.DOT does — both producers (the
-- Binder and the `/cdmp rt` fixtures) must stamp the same numbers.
G.KEY = { point = "TOPLEFT", relPoint = "TOPLEFT", dx = 2, dy = -2 }

-- Our own self-anchored widgets: the sequence panel and the discrete-pip bar.  Cues
-- ride foreign frames; these two we position ourselves against a root token.
G.PANEL = { anchorTo = "UIPARENT", point = "TOP", dx = 0, dy = -200 }
G.BAR   = { anchorTo = "UIPARENT", point = "CENTER", dy = -18, pip = 14, gap = 4, stack = 20 }

--------------------------------------------------------------------------------
-- Builders — stamp the geometry onto one DrawList entry.  The Binder calls these
-- per ability/bar/panel; the Renderer fixtures call the same.
--------------------------------------------------------------------------------
-- One cue entry: corner-dot geometry + emphasis TOKEN (not colour).  `anchorTo` is the
-- opaque handle (live: a cooldownID; test rig: "fake1").  Ring/glow behaviour is now
-- emphasis-derived in the Renderer (GLOW_SPEC), so there is no `glow` bool on the
-- DrawList any more.
--
-- ⚠ A CUE NEVER CARRIES A KEYBIND (Phase 3).  It used to take a third `keybind` arg, and
-- an emphasis-less cue carrying only that was how the key hint rode every button — a
-- display concern travelling through the DECISION channel.  Keybinds are their own
-- DrawList channel now (G.keybind below); the parameter was REMOVED rather than
-- deprecated, because leaving it would preserve exactly the ambiguity that cost us the
-- special case in three files.
-- ⚠ `next` IS A PASS-THROUGH FLAG, NOT GEOMETRY (2026-08-03).  It says "the look-ahead
-- landed back on THIS ability", i.e. press it twice, and the Renderer answers with a small
-- COMPANION DOT beside the main one.  It carries no position of its own: the companion is
-- offset from the cue dot inside the Renderer, so the two can never drift apart.
function G.cue(anchorTo, emphasis, isNext)
  local d = G.DOT
  return {
    anchorTo = anchorTo, point = d.point, relPoint = d.relPoint,
    dx = d.dx, dy = d.dy, size = d.size,
    emphasis = emphasis,
    next = isNext or nil,
  }
end

-- One keybind entry: upper-left corner geometry + the short key string.  Same `anchorTo`
-- handle vocabulary as G.cue, so the Renderer resolves both through one registry — but a
-- SEPARATE channel, because a keybind is identity chrome and not a rotation signal.
function G.keybind(anchorTo, key)
  local k = G.KEY
  return {
    anchorTo = anchorTo, point = k.point, relPoint = k.relPoint,
    dx = k.dx, dy = k.dy,
    keybind = key,
  }
end

-- The discrete-pip resource bar, self-anchored and CENTRED on its anchor: `dx`
-- spans half the pip row so the row is centred (row width = max pips + gaps).  `index`
-- (0-based, default 0) STACKS multiple bars vertically for a multi-power spec — each
-- successive bar drops one `stack` step; a single-bar spec (Demo) passes index 0 and
-- lands at the unchanged dy.
function G.resourceBar(value, max, powerType, index, display)
  local b = G.BAR
  local m = max or 5
  local width = m * b.pip + (m - 1) * b.gap
  return {
    anchorTo = b.anchorTo, point = b.point,
    dx = -width / 2, dy = b.dy - (index or 0) * b.stack,
    value = value, max = m, powerType = powerType or "SOUL_SHARDS",
    display = display or "discrete",   -- routes the Renderer's discrete/continuous path
  }
end

-- The self-anchored sequence panel: position + pass-through title + step rows.
function G.panel(title, steps)
  local p = G.PANEL
  return {
    anchorTo = p.anchorTo, point = p.point, dx = p.dx, dy = p.dy,
    title = title, steps = steps,
  }
end
