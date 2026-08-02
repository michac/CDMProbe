-- RenderLabB3 — B1 PLUS THE PER-DRAW RESTATE.
--
-- The live HUD does not build a ring and leave it alone.  `R:setDotGlow` runs on EVERY
-- pipeline tick — ~10 Hz — and on every one of them it re-asserts the ring's colour, its
-- anchor (`ClearAllPoints` then `SetPoint`) and its size, on textures whose Rotation
-- animation is already playing.  A2 and A3 anchor once at creation and never touch the
-- texture again.  That is the largest structural difference between a ring that reads
-- steady and the one that does not, and it is the difference NOTHING so far has tested:
-- the SavedVariables capture compared settled FIELD VALUES between two paths and found
-- them byte-identical, which is exactly what you would see if the damage were done by the
-- act of re-asserting a value rather than by the value itself.
--
-- Renderer.lua already guards the one restate it knew was dangerous — `SetDuration` on a
-- playing group restarts it, so the period is re-timed only when it CHANGES.  This panel
-- asks whether the un-guarded restates (SetSize / ClearAllPoints+SetPoint / SetVertexColor)
-- disturb a running Rotation the same way.
--
-- The ticker is deliberately 0.1s, the pipeline's own cadence, not a frame timer: if the
-- artefact needs the restate to fall at an irregular phase against the animation clock,
-- a 10 Hz beat against a 12.0s rotation is the condition that produces it.

local _, ns = ...
ns.RenderLabImpl = ns.RenderLabImpl or {}
ns.RenderLabInfo = ns.RenderLabInfo or {}

local TICK = 0.1

ns.RenderLabInfo[4] = "B1 + THE PER-DRAW RESTATE: a 10Hz ticker re-asserting SetVertexColor / ClearAllPoints+SetPoint / SetSize on both rings, as R:setDotGlow does every tick."

ns.RenderLabImpl[4] = function(panel)
  local S = ns.RenderLabShipped
  local col = S.COLOR
  local echo = ns.RenderLabRing(panel, 60, 1, S.ECHO_LIGHT, -360, S.SPIN_SECS)
  local ring = ns.RenderLabRing(panel, 40, 2, 1 - S.ECHO_LIGHT, -360, S.SPIN_SECS)

  -- Same statements, same order as setDotGlow — including re-anchoring to a CENTER point
  -- that has not moved, which is the whole question: does restating an unchanged anchor
  -- cost a running Rotation anything?
  C_Timer.NewTicker(TICK, function()
    ring:SetVertexColor(col[1], col[2], col[3], 1 - S.ECHO_LIGHT)
    ring:ClearAllPoints()
    ring:SetPoint("CENTER", panel, "CENTER", 0, 0)
    ring:SetSize(40, 40)
    echo:SetVertexColor(col[1], col[2], col[3], S.ECHO_LIGHT)
    echo:SetSize(60, 60)
    echo:ClearAllPoints()
    echo:SetPoint("CENTER", panel, "CENTER", 0, 0)
  end)
end
