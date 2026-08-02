-- RenderLabB2 — B1 PLUS THE BREATHE.
--
-- Renderer.lua puts a SECOND animation group on the base ring's own texture: an Alpha
-- BOUNCE from 0.55 to 1.00 over 0.60s, so the full cycle is 1.2s.  Neither A2 nor A3 has
-- anything like it, and Renderer.lua's own comment concedes it "predates the `rt fx` rig,
-- which shipped no knob for it, so every judgement about how fast the cues move has
-- actually been a judgement about rotation + this, with only the rotation adjustable."
--
-- WHY IT IS A CANDIDATE FOR A SURGE THAT LOOKS LIKE A SPEED CHANGE, despite touching only
-- brightness: the eye does not read a spoked ring's rate off angular velocity, it reads it
-- off SPOKE PASSAGES — 8-fold art at 12.0s presents a feature every 1.5s.  A brightness
-- cycle at 1.2s beside a feature cycle at 1.5s is two near-equal rhythms, and near-equal
-- rhythms beat: |1/1.2 - 1/1.5| = 0.167 Hz, a ~6s envelope.  "Slows, then speeds up, then
-- slows, repeating forever" is what a 6s envelope on a tracked motion looks like.  That is
-- a hypothesis, not a finding — this panel is how it gets falsified.

local _, ns = ...
ns.RenderLabImpl = ns.RenderLabImpl or {}
ns.RenderLabInfo = ns.RenderLabInfo or {}

local PULSE_SECS = 0.60
local PULSE_FLOOR = 0.55

ns.RenderLabInfo[3] = "B1 + THE BREATHE: a 2nd group on the base ring's texture, Alpha .55->1.0 over 0.60s, BOUNCE (1.2s cycle)."

ns.RenderLabImpl[3] = function(panel)
  local S = ns.RenderLabShipped
  ns.RenderLabRing(panel, 60, 1, S.ECHO_LIGHT, -360, S.SPIN_SECS)
  local ring = ns.RenderLabRing(panel, 40, 2, 1 - S.ECHO_LIGHT, -360, S.SPIN_SECS)

  -- Its OWN group, on the same texture, exactly as Renderer.lua builds it.  Multiplies
  -- with the vertex alpha, so the ring breathes between 0.45 x floor and 0.45.
  local pulse = ring:CreateAnimationGroup()
  local a = pulse:CreateAnimation("Alpha")
  a:SetFromAlpha(PULSE_FLOOR)
  a:SetToAlpha(1.00)
  a:SetDuration(PULSE_SECS)
  a:SetOrder(1)
  pulse:SetLooping("BOUNCE")
  pulse:Play()
end
