local _, ns = ...
ns.RenderLabImpl = ns.RenderLabImpl or {}
ns.RenderLabInfo = ns.RenderLabInfo or {}

local RING_TEXTURE = [[Interface\AddOns\CDMProbe\Media\fx\glow\star_07.tga]]

-- Pinned green.
local R, G, B = 0.30, 1.00, 0.48

-- Free choices, all in one place:
--   periods   6s inner / 9s outer (non-harmonic, so the two never re-sync into a
--             single apparent shape)
--   direction inner clockwise (-360), outer counter-clockwise (+360)
--   blend     ADD -- the art is white/grey with the shape in alpha, so ADD makes it
--             read as light over the icon rather than as a decal
--   layer     OVERLAY, sublevel 1 (outer) / 2 (inner) -- above the icon art, and the
--             smaller/brighter ring wins the overlap
--   easing    NONE (linear) -- anything else visibly stutters at the loop seam
local INNER_SIZE, INNER_SUBLAYER, INNER_ALPHA, INNER_PERIOD, INNER_DEGREES = 40, 2, 0.85, 6.0, -360
local OUTER_SIZE, OUTER_SUBLAYER, OUTER_ALPHA, OUTER_PERIOD, OUTER_DEGREES = 60, 1, 0.55, 9.0, 360

-- One ring: a single centred quad that spins about its own centre forever.
-- A Rotation animation is used rather than Texture:SetRotation on an OnUpdate,
-- because SetRotation spins the texture *inside* a fixed quad and shears the
-- corners off a square sprite at 45 degrees, while the animation system rotates
-- the rendered geometry itself. It also runs on the client's animation clock, so
-- it costs no per-frame Lua.
local function CreateRing(panel, size, sublayer, alpha, period, degrees)
  local tex = panel:CreateTexture(nil, "OVERLAY", nil, sublayer)
  tex:SetTexture(RING_TEXTURE)
  tex:SetSize(size, size)
  tex:SetPoint("CENTER", panel, "CENTER", 0, 0)
  tex:SetBlendMode("ADD")
  -- SetVertexColor tints the white/grey art; the shape survives because it lives
  -- in the alpha channel, which the tint does not touch.
  tex:SetVertexColor(R, G, B)
  tex:SetAlpha(alpha)

  local group = tex:CreateAnimationGroup()
  group:SetLooping("REPEAT")

  local rot = group:CreateAnimation("Rotation")
  rot:SetOrder(1)
  rot:SetDuration(period)
  rot:SetDegrees(degrees)
  rot:SetOrigin("CENTER", 0, 0)
  rot:SetSmoothing("NONE")

  group:Play()
end

-- ⚠ ROUND 2 RENUMBERED THIS FROM [2] TO [1] — the ONLY edit made to the file the blind
-- subagent wrote.  It is round 1's steady survivor and now serves as round 2's CONTROL:
-- if this panel ever surges, the run is invalid and nothing else on screen means anything.
ns.RenderLabInfo[1] = "CONTROL (round-1 A2, unchanged): 40px inner CW 6s, 60px outer CCW 9s; ADD, OVERLAY 1/2, linear, alpha .85/.55."

ns.RenderLabImpl[1] = function(panel)
  CreateRing(panel, OUTER_SIZE, OUTER_SUBLAYER, OUTER_ALPHA, OUTER_PERIOD, OUTER_DEGREES)
  CreateRing(panel, INNER_SIZE, INNER_SUBLAYER, INNER_ALPHA, INNER_PERIOD, INNER_DEGREES)
end
