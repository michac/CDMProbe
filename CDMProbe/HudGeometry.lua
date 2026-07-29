-- HudGeometry.lua — the SHARED geometry/binding table for the DrawList (W4 Phase 4).
--
-- WHY THIS EXISTS (docs/archive/w4-phase4-binder-plan.md, resolution #4).  Two producers
-- must emit the SAME DrawList geometry: the Binder (live, Guidance -> DrawList) and
-- the Renderer's hand-authored `/cdmp rendertest` fixtures (the reference the
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
-- The constants (were the fixture locals DOT / GLOW_EMPHASIS + the shards()/panel
-- literals in Renderer.lua).
--------------------------------------------------------------------------------
-- The cue dot rides INSIDE the icon's upper-right corner (3px inset), 12px square.
-- Anchored RELATIVE to its handle's frame, so it ride-alongs the icon for free.
G.DOT = { point = "TOPRIGHT", relPoint = "TOPRIGHT", dx = -3, dy = -3, size = 12 }

-- The PRESS-level emphases glow like a proc; the softer signals (SOON/JUDGE/
-- SEQUENCE) stay plain corner dots, so the glow keeps meaning "press this now".
G.GLOW_EMPHASIS = { ROTATION = true, LATE = true }

-- Our own self-anchored widgets: the sequence panel and the discrete-pip bar.  Cues
-- ride foreign frames; these two we position ourselves against a root token.
G.PANEL = { anchorTo = "UIPARENT", point = "TOP", dx = 0, dy = -200 }
G.BAR   = { anchorTo = "UIPARENT", point = "CENTER", dy = -18, pip = 14, gap = 4 }

--------------------------------------------------------------------------------
-- Builders — stamp the geometry onto one DrawList entry.  The Binder calls these
-- per ability/bar/panel; the Renderer fixtures call the same.
--------------------------------------------------------------------------------
-- Whether a cue of this emphasis glows.  Returns nil (not false) when it doesn't,
-- so an absent `glow` key and `glow = nil` compare equal.
function G.glowFor(emphasis) return G.GLOW_EMPHASIS[emphasis] or nil end

-- One cue entry: corner-dot geometry + emphasis TOKEN (not colour) + optional
-- keybind string + the glow flag.  `anchorTo` is the opaque handle (live: a
-- cooldownID; test rig: "fake1").
function G.cue(anchorTo, emphasis, keybind)
  local d = G.DOT
  return {
    anchorTo = anchorTo, point = d.point, relPoint = d.relPoint,
    dx = d.dx, dy = d.dy, size = d.size,
    emphasis = emphasis, keybind = keybind, glow = G.glowFor(emphasis),
  }
end

-- The discrete-pip resource bar, self-anchored and CENTRED on its anchor: `dx`
-- spans half the pip row so the row is centred (row width = max pips + gaps).
function G.resourceBar(value, max, powerType)
  local b = G.BAR
  local m = max or 5
  local width = m * b.pip + (m - 1) * b.gap
  return {
    anchorTo = b.anchorTo, point = b.point,
    dx = -width / 2, dy = b.dy,
    value = value, max = m, powerType = powerType or "SOUL_SHARDS",
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
