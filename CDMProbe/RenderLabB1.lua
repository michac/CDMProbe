-- RenderLabB1 — THE SHIPPED NUMBERS, ON A CLEAN RING.
--
-- Round 1 asked whether the surge is inherent to the idea.  It is not: A2 and A3 both ran
-- steady.  Round 2 walks the distance from A2's steady ring to Renderer.lua's surging one,
-- one difference per panel, against A2 itself as the control.
--
-- This panel changes ONLY the numbers — the shipped period, the shipped echo, the shipped
-- light split — with none of the shipped plumbing.  It also closes round 1's one real
-- confound: A2 ran at 6s/9s and the Renderer runs at 12.0s, so "counter-rotation is fine"
-- was only ever established at A2's periods, not at the shipped one.
--
--   period      12.0s  (SPIN_SECS)
--   echo        LOCKED IN PHASE — same direction, same period (ECHO_SPIN_RATIO 1.0,
--               ECHO_DEGREES -360), which is what shipped after the moiré retune
--   light split base ring 0.45, echo 0.55 (1 - ECHO_LIGHT / ECHO_LIGHT)
--
-- If THIS surges, the cause is the configuration and every panel after it is moot.

local _, ns = ...
ns.RenderLabImpl = ns.RenderLabImpl or {}
ns.RenderLabInfo = ns.RenderLabInfo or {}

local TEX = [[Interface\AddOns\CDMProbe\Media\fx\glow\star_07.tga]]
local R, G, B = 0.30, 1.00, 0.48

local SPIN_SECS = 12.0
local ECHO_LIGHT = 0.55

-- Shared by B2/B3, which are this panel plus exactly one thing.
function ns.RenderLabRing(panel, size, sublevel, alpha, degrees, secs)
  local tex = panel:CreateTexture(nil, "OVERLAY", nil, sublevel)
  tex:SetTexture(TEX)
  tex:SetBlendMode("ADD")
  tex:SetVertexColor(R, G, B, alpha)
  tex:SetSize(size, size)
  tex:SetPoint("CENTER", panel, "CENTER", 0, 0)
  local ag = tex:CreateAnimationGroup()
  local rot = ag:CreateAnimation("Rotation")
  rot:SetDegrees(degrees)
  rot:SetDuration(secs)
  rot:SetOrigin("CENTER", 0, 0)
  rot:SetOrder(1)
  ag:SetLooping("REPEAT")
  ag:Play()
  return tex
end

ns.RenderLabShipped = { SPIN_SECS = SPIN_SECS, ECHO_LIGHT = ECHO_LIGHT, COLOR = { R, G, B } }

ns.RenderLabInfo[2] = "shipped numbers only: both rings 12.0s, SAME direction (echo locked in phase), light split .45/.55. No breathe, no per-draw restate."

ns.RenderLabImpl[2] = function(panel)
  ns.RenderLabRing(panel, 60, 1, ECHO_LIGHT, -360, SPIN_SECS)      -- the echo
  ns.RenderLabRing(panel, 40, 2, 1 - ECHO_LIGHT, -360, SPIN_SECS)  -- the base ring
end
