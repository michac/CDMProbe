-- ARCHIVED 2026-08-02 — THE v1 CUE TREATMENT, retired from Renderer.lua.
--
-- NOT LOADED.  Not in the .toc, never parsed by the game.  Kept as the record of a
-- treatment that took six builds of dialling and one blind three-way experiment to settle,
-- because the REASONING here is worth more than the code: the art-symmetry retune
-- (star_07 is 8-fold, so perceived rate is angular velocity x 8), the moiré analysis that
-- locked the echo in phase, and the light-split argument for adding reach without
-- brightness are all still true and all still apply to whatever replaces this.
--
-- WHY IT WENT.  The ring's spin read as "slows like a rubber band, then races, forever".
-- Three subagents, blind to this repo, implemented the same idea from a pinned brief; two
-- of the three ran STEADY, which cleared the concept, the art and the animation API and
-- put the fault here.  Round 2 then walked the steady implementation toward this one, one
-- difference per panel, and measured every rotation's phase against a uniform spin — and
-- NOTHING surged.  The shipped pair simply reads as ONE ring, because the echo is locked
-- in phase with the base: same direction, same period, same 8-fold sprite.  So the
-- replacement is not a bug fix, it is a decision: two rings you can SEE are two rings,
-- counter-rotating at different periods, which is what the steady implementation did.
--
-- Retired with it: the BREATHE (an Alpha BOUNCE on the ring's own texture, 0.6s
-- half-cycle, never once dialled — the `rt fx` rig shipped no knob for it, so every
-- judgement about "how fast do the cues move" was silently a judgement about rotation
-- PLUS this), the POP (a one-shot Scale on the cue layer) and the GHOST (a scale-and-fade
-- of the departing ring).  The cue layer frame survives as a plain parent; it existed so
-- the pop had something to scale that `setDotGlow` was not re-stamping at 10 Hz.
--
-- ⚠ Recover from git history (v0.32.73) if any of this is ever revived — do not paste it
-- back from here without re-reading why it left.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Press glow — a SPINNING round glow centred on the solid cue dot, in OUR colour.
--------------------------------------------------------------------------------
-- A round ring-glow atlas Blizzard built to spin (services-ring-large-glowspin, the
-- RecruitAFriend claim glow), additive, tinted to the cue's emphasis hue via
-- SetVertexColor and CENTRED on the solid dot, sized relative to the dot.  The
-- CONTINUOUS ROTATION is the eye-draw (2026-07-28 feedback: "the movement really helps
-- draw the eye"); a symmetric soft circle can't show spin, so this ring's angular
-- detail is what makes the motion read.  Two separate looping groups because their
-- loop MODES differ: `spin` (Rotation, REPEAT — a seamless full turn) and `pulse`
-- (Alpha, BOUNCE — a gentle breathe); one group can't do both.  Sits a layer BELOW the
-- dot (ARTWORK vs the dot's OVERLAY) so the crisp dot + keybind stay on top.  Pooled
-- per handle.  Each group is driven independently to match its `spin`/`pulse` flag and
-- tracked per-glow (g._spinOn / g._pulseOn), so a steady redraw doesn't hitch a running
-- animation and a ring with both flags false simply never plays.
--
-- ⚠ THE RING HAS A HOLE, AND IT CANNOT BE FILLED.  Its transparent centre is baked into
-- the art, and there is no tint or blend mode that paints it in (SetVertexColor
-- multiplies — it cannot add alpha where there is none).  The angular detail in that ring
-- is also the only reason the spin READS at all; a symmetric soft blob would rotate
-- invisibly.  So the hole is not a bug to remove, it is the cost of the motion channel —
-- the lever is to make the DOT COVER IT by sizing the ring so its inner edge sits on the
-- dot's rim.  That is what GLOW_SCALE is.
--
-- WE SHIP THE ART (2026-08-01, promoted from `rt fx art 8`).  It was Blizzard's
-- `services-ring-large-glowspin` atlas; it is now a CC0 Kenney sprite we ship, via
-- `SetTexture` on a file path rather than `SetAtlas` on a name.  The reason is not taste:
-- SetVertexColor MULTIPLIES, so a tint can only remove energy the art already has, and
-- that atlas is GOLD — mostly red+green.  Our violet ROTATION_FALLBACK (green channel
-- 0.16) multiplied most of it away, which is a real part of why the fallback read dim.
-- This sprite is white/grey with the shape in ALPHA, so every hue tints at full strength.
-- 128x128, power-of-two.  Licence + provenance: Media/fx/CREDITS.md.
local GLOW_ART = "Interface\\AddOns\\CDMProbe\\Media\\fx\\glow\\star_07.tga"
-- Ring diameter relative to the DOT.  Dialled BY EYE on `/cdmp rt fx` — the number that
-- matters is not the ring's size but the gap between the dot's rim and the ring's inner
-- edge, which must be ZERO so the two read as one object.
--
-- ⚠ GLOW_SCALE IS ART-SPECIFIC AND DOES NOT TRANSFER.  2.3 was dialled against Blizzard's
-- ring, whose spokes start at a different radius; 3.34 (2.3 x 1.45) belongs to star_07 and
-- to nothing else.  Swapping the art and re-dialling this are ONE job, not two.
local GLOW_SCALE = 3.34
-- ⚠ SO IS THE PERIOD, AND FOR A REASON WORTH WRITING DOWN.  The rate the eye reads is not
-- the angular velocity, it is **angular velocity x the sprite's rotational symmetry
-- order** — how often a spoke passes a fixed point.  star_07 measures **8-fold** (an
-- 8-pointed star with alternating long/short spokes: dominant k=8, harmonics at k=4/k=16),
-- where Blizzard's `services-ring-large-glowspin` is a swept gradient with almost no
-- angular structure at all (the twirl sprites beside it measure k=1).  So swapping the art
-- at an unchanged 4.0s tripled the apparent spin — 8 spokes/revolution is a feature every
-- 0.5s — and it read as a strobe rather than a turn.  12.0s puts a spoke back at ~1.5s.
--
-- THE RULE: art, GLOW_SCALE and SPIN_SECS are ONE dial with three parts.  Change the
-- sprite and BOTH numbers are invalidated; a spokier sprite needs a longer period in
-- proportion to its symmetry order.  (`/cdmp rt fx spin <n>` is how to re-dial it.)
local SPIN_SECS  = 12.0   -- one full rotation

-- THE BREATHE.  A SECOND continuous motion on the same texture, and the one nobody has
-- ever dialled: it predates the `rt fx` rig, which shipped no knob for it, so every
-- judgement about "how fast do the cues move" has actually been a judgement about
-- rotation + this, with only the rotation adjustable.  `SetLooping("BOUNCE")` means the
-- FULL cycle is 2 x PULSE_SECS.  ⚠ It multiplies with the ring's vertex alpha, so after
-- the light split the ring breathes between 0.45 x floor and 0.45 — the RATIO is what
-- the eye reads, and the ratio is unchanged by the split.
local PULSE_SECS  = 0.60  -- half-cycle; 1.2s there and back
local PULSE_FLOOR = 0.55  -- dims to this fraction, then back to full

-- THE OUTER ECHO — reach without brightness (`rt fx rays 1.5 @55%`).  A ring cannot be
-- stretched radially: a texture is a quad and tex-coords are rectangular, so there is no
-- transform that lengthens the rays while holding the inner radius.  The reach of a ray is
-- baked into the art.  So the ring is drawn AGAIN, larger — and because additive light
-- STACKS, the light is SPLIT between the two rather than added, so only the REACH grows.
--
-- ⚠ LOCKED IN PHASE WITH THE BASE RING — same direction, same period — AND THE REASON IS
-- THE MOST EXPENSIVE THING LEARNED IN THIS WHOLE ROUND.  It shipped counter-rotating at
-- 2.5x the base period, inherited from the rig's `desync` knob, on the argument that
-- opposed rotation keeps the spokes crossing and makes the extra reach legible as rays.
-- That argument was formed against Blizzard's ring, which is a swept gradient with almost
-- no angular structure.  Against an 8-FOLD sprite it is wrong, and expensively so:
--
--   TWO N-FOLD PATTERNS IN RELATIVE ROTATION PRODUCE A MOIRÉ, and it beats at N x the
--   RELATIVE angular velocity — 8 alignments per relative revolution here.  At the
--   original 4.0s/10.0s that beat sat near 2.8 Hz, above flicker fusion, so it read as
--   texture and nobody questioned it.  Slowing the base to 12.0s (the art-symmetry retune
--   above) dragged the beat down to ~0.93 Hz, straight into the band where the eye TRACKS
--   it — and a tracked moiré stalls at each alignment and races between them.  Reported
--   from the chair as "the spin slows like a rubber band, then speeds up, forever".
--
-- So the slowdown did not CREATE the interference, it made it visible; the interference
-- was there from the first build.  Locked in phase there is no relative motion at all and
-- the pair reads as ONE ring with longer reach — which is the only thing the echo was ever
-- for.  ⚠ Any future value other than 1.0 / -360 reintroduces a beat at 8 x the relative
-- velocity: check it against the ART's symmetry order, not by eye at one speed.
-- (`/cdmp rt fx echo sync <n>` walks it back out if that is ever wanted deliberately.)
local ECHO_SCALE      = 1.5    -- echo diameter, relative to the base ring
local ECHO_LIGHT      = 0.55   -- the echo's share of the light; the base ring keeps 0.45
local ECHO_SPIN_RATIO = 1.0    -- echo period = base period x this.  1.0 = locked, no moiré
local ECHO_DEGREES    = -360   -- ...the SAME way as the base ring.  See above.

-- THE BACKING DISC — contrast, not light.  The rings are additive over busy icon art, so
-- they wash out against it; punching a dark hole behind them gives the added light
-- something to read against.  Sized off the OUTERMOST drawn extent (the echo), not the
-- base ring, so it can never end up smaller than the light it is backing.  ~21px behind a
-- 12px dot at the shipped numbers.
local DISC_ALPHA = 0.75
local DISC_SCALE = 0.35   -- diameter relative to the ECHO's diameter (ring x 1.5)

-- Drive one looping group to match its flag, tracked on the owner so a steady redraw at
-- 10 Hz doesn't restart it.  Both flags false ⇒ the region is shown but never animates.
local function drive(owner, group, want, flag)
  if want and not owner[flag] then group:Play(); owner[flag] = true
  elseif not want and owner[flag] then group:Stop(); owner[flag] = false end
end

function R:setDotGlow(key, layer, dot, col, size, gs)
  local g = self.cueGlows[key]
  if not col then                              -- no glow this frame: hide + park
    if g then
      g:Hide()
      if g.spin then g.spin:Stop() end
      if g.pulse then g.pulse:Stop() end
      g._spinOn, g._pulseOn = nil, nil         -- clear so a re-shown glow re-plays
    end
    local e, d = self.cueEchoes[key], self.cueDiscs[key]
    if e then e:Hide(); e.spin:Stop(); e._spinOn = nil end
    if d then d:Hide() end
    self.glowing[key] = nil
    return
  end
  if not g then
    g = layer:CreateTexture(nil, "ARTWORK")
    g:SetTexture(GLOW_ART)
    g:SetBlendMode("ADD")
    local spinGroup = g:CreateAnimationGroup()  -- continuous rotation (REPEAT)
    local rot = spinGroup:CreateAnimation("Rotation")
    rot:SetDegrees(-360)
    rot:SetDuration(SPIN_SECS)
    rot:SetOrigin("CENTER", 0, 0)
    rot:SetOrder(1)
    g.rot = rot                                 -- kept so the PERIOD can change per emphasis
    spinGroup:SetLooping("REPEAT")
    local pulseGroup = g:CreateAnimationGroup() -- breathe (BOUNCE) — own group
    local a = pulseGroup:CreateAnimation("Alpha")
    a:SetFromAlpha(PULSE_FLOOR)
    a:SetToAlpha(1.00)
    a:SetDuration(PULSE_SECS)
    a:SetOrder(1)
    pulseGroup:SetLooping("BOUNCE")
    g.spin, g.pulse = spinGroup, pulseGroup
    -- Exposed like `g.rot`, so `/cdmp rt fx` can re-time the breathe live.  It could not
    -- before, which is why the first round of dialling never questioned it.
    g.pulseAnim, g.pulseSecs = a, PULSE_SECS
    self.cueGlows[key] = g
  end
  local d     = size or 12
  local ring  = d * ((gs and gs.ringScale) or GLOW_SCALE)
  local secs  = (gs and gs.spinSecs) or SPIN_SECS
  local outer = ring * ECHO_SCALE
  -- THE LIGHT SPLIT.  The base ring gives up its share to the echo, so adding reach does
  -- not add brightness.  Alpha only — the hue is the emphasis colour, untouched.
  g:SetVertexColor(col[1], col[2], col[3], 1 - ECHO_LIGHT)
  g:ClearAllPoints()
  g:SetPoint("CENTER", dot, "CENTER", 0, 0)
  g:SetSize(ring, ring)
  -- Remembered for the GHOST, which outlives the cull that hides this texture and must
  -- not restate the ring's size or hue (that is how the two would drift apart).
  g.ringSize, g.ringCol = ring, col
  -- Re-time the rotation only when it CHANGES: SetDuration on a playing group restarts it,
  -- which would stutter the ring on every redraw at 10 Hz.
  if g._spinSecs ~= secs then
    g._spinSecs = secs
    g.rot:SetDuration(secs)
  end
  g:Show()
  drive(g, g.spin,  gs and gs.spin,  "_spinOn")
  drive(g, g.pulse, gs and gs.pulse, "_pulseOn")

  -- THE BACKING DISC — BACKGROUND, under everything, sized off the echo's extent.
  local disc = self.cueDiscs[key]
  if not disc then
    disc = maskedDisc(layer, "BACKGROUND")
    self.cueDiscs[key] = disc
  end
  disc:SetColorTexture(0, 0, 0, DISC_ALPHA)
  sizeDisc(disc, outer * DISC_SCALE, dot)
  disc:Show()

  -- THE OUTER ECHO — one sub-layer under the base ring, counter-rotating at the ratio.
  local echo = self.cueEchoes[key]
  if not echo then
    echo = layer:CreateTexture(nil, "ARTWORK", nil, -1)
    echo:SetTexture(GLOW_ART)
    echo:SetBlendMode("ADD")
    local sg  = echo:CreateAnimationGroup()
    local rot = sg:CreateAnimation("Rotation")
    rot:SetDegrees(ECHO_DEGREES)
    rot:SetOrigin("CENTER", 0, 0)
    rot:SetOrder(1)
    sg:SetLooping("REPEAT")
    echo.spin, echo.rot = sg, rot
    self.cueEchoes[key] = echo
  end
  echo:SetVertexColor(col[1], col[2], col[3], ECHO_LIGHT)
  echo:SetSize(outer, outer)
  echo:ClearAllPoints()
  echo:SetPoint("CENTER", dot, "CENTER", 0, 0)
  local esecs = secs * ECHO_SPIN_RATIO
  if echo._spinSecs ~= esecs then
    echo._spinSecs = esecs
    echo.rot:SetDuration(esecs)
  end
  echo:Show()
  drive(echo, echo.spin, gs and gs.spin, "_spinOn")

  self.glowing[key] = true
end
