local _, ns = ...
ns.RenderLabImpl = ns.RenderLabImpl or {}
ns.RenderLabInfo = ns.RenderLabInfo or {}

local TEX = [[Interface\AddOns\CDMProbe\Media\fx\glow\star_07.tga]]
local CR, CG, CB = 0.30, 1.00, 0.48

local cos, sin = math.cos, math.sin
local TAU = math.pi * 2

-- Rotation periods (seconds for a full turn). 52 = 13 * 4.0 = 8 * 6.5, so the
-- accumulator can wrap at 52s with both rings landing exactly on phase 0.
local INNER_PERIOD, OUTER_PERIOD = 4.0, 6.5
local CYCLE = 52.0

-- A "ring" is N copies of the star sprite evenly spaced around a circle of the
-- given radius; rotating the ring means re-placing every sprite each frame.
local function buildRing(parent, count, radius, size, alpha, sublevel)
  local ring = { parent = parent, count = count, radius = radius, sprites = {} }
  for i = 1, count do
    local t = parent:CreateTexture(nil, "OVERLAY", nil, sublevel)
    t:SetTexture(TEX)
    t:SetBlendMode("ADD")
    t:SetVertexColor(CR, CG, CB, alpha)
    t:SetSize(size, size)
    ring.sprites[i] = t
  end
  return ring
end

local function placeRing(ring, phase)
  local step = TAU / ring.count
  local radius, parent = ring.radius, ring.parent
  for i = 1, ring.count do
    local a = phase + (i - 1) * step
    local t = ring.sprites[i]
    t:ClearAllPoints()
    t:SetPoint("CENTER", parent, "CENTER", radius * cos(a), radius * sin(a))
    t:SetRotation(a) -- yaw each sprite with its orbit so the points stay tangential
  end
end

ns.RenderLabInfo[1] =
  "Rings = 8 sprites @ r20 / 12 @ r30 (40px + 60px dia); ADD blend, OVERLAY sublevels 1-2 on a child frame 5 levels above the icon; inner CW 4.0s, outer CCW 6.5s, linear (no easing), OnUpdate orbit wrapping every 52s."

ns.RenderLabImpl[1] = function(panel)
  -- Own child frame: keeps our draw layers from colliding with the panel's icon art.
  local fx = CreateFrame("Frame", nil, panel)
  fx:SetAllPoints(panel)
  fx:SetFrameLevel(panel:GetFrameLevel() + 5)

  local inner = buildRing(fx, 8, 20, 15, 0.90, 1)
  local outer = buildRing(fx, 12, 30, 12, 0.65, 2)

  placeRing(inner, 0)
  placeRing(outer, 0)

  local t = 0
  fx:SetScript("OnUpdate", function(_, elapsed)
    t = (t + elapsed) % CYCLE
    placeRing(inner, -TAU * (t / INNER_PERIOD)) -- clockwise
    placeRing(outer, TAU * (t / OUTER_PERIOD))  -- counter-clockwise
  end)
end
