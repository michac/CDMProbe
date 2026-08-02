local _, ns = ...
ns.RenderLabImpl = ns.RenderLabImpl or {}
ns.RenderLabInfo = ns.RenderLabInfo or {}

ns.RenderLabInfo[3] = "ADD blend, linear spin: inner 40px CW 6s on OVERLAY:1 a=.85, outer 60px CCW 9s on ARTWORK:0 a=.55"

local TEX = [[Interface\AddOns\CDMProbe\Media\fx\glow\star_07.tga]]
local R, G, B = 0.30, 1.00, 0.48

ns.RenderLabImpl[3] = function(panel)
  local function ring(size, layer, sublevel, alpha, degrees, duration)
    local tex = panel:CreateTexture(nil, layer, nil, sublevel)
    tex:SetTexture(TEX)
    tex:SetBlendMode("ADD")
    tex:SetVertexColor(R, G, B, alpha)
    tex:SetSize(size, size)
    tex:SetPoint("CENTER", panel, "CENTER", 0, 0)

    local ag = tex:CreateAnimationGroup()
    local rot = ag:CreateAnimation("Rotation")
    rot:SetDegrees(degrees)
    rot:SetDuration(duration)
    rot:SetOrigin("CENTER", 0, 0)
    rot:SetSmoothing("NONE")
    ag:SetLooping("REPEAT")
    ag:Play()

    return tex
  end

  -- Outer ring: 60px, counter-clockwise, slower, sits behind.
  ring(60, "ARTWORK", 0, 0.55, -360, 9)

  -- Inner ring: 40px, clockwise, faster, sits in front.
  ring(40, "OVERLAY", 1, 0.85, 360, 6)
end
