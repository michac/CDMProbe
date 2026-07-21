-- HudChrome.lua — everything we DRAW.  Never a write to item.Icon.
--
-- The 2026-07-19 aesthetic revision: Blizzard's icons stay native and untouched
-- (art, radial swipe, countdown text, charges, native glow all survive), and all
-- our value-add is terminal chrome AROUND them.  So this module owns:
--
--   * per-item group accent   — §0.5.8.3 #4: hue = GROUP (spec.md §3 colour map),
--                               role = the generator/consumer BATCH TINT
--   * per-item readiness      — §0.5.8.3 #5: LUMINANCE + the one-shot ready settle
--   * per-item proc glow      — §0.5.8.3 #2/#3: our own border pulse overlay
--   * per-item keybind text   — identity chrome, outside the indicator contract
--   * the DEMO.SYS terminal frame — header / rules / side borders / blinking footer
--   * the scanline + vignette overlay
--
-- Two encoding rules from spec.md §3 are load-bearing here:
--   [V2]/[V3]  hue carries GROUP only.  The batch tint therefore rides on
--              SATURATION + edge THICKNESS + alpha, and deliberately leaves
--              LUMINANCE alone — luminance is reserved for readiness (M3b), so
--              the two channels can never fight.
--   [X1]       never colour-alone: edge thickness is a redundant, non-colour
--              signifier of the builder/spender axis.
--
-- COMPOSED ACCENT (v0.7.0).  M3a wrote the edge colours straight out of
-- group+role in Attach(), and HudBinds calls Attach on every keybind change —
-- which would have stomped whatever readiness M3b had just set.  So the accent
-- is now composed from independent fields and there is exactly ONE writer:
--
--   o.identity = { r, g, b, width, alpha }   -- M3a: hue = group, sat = role
--   o.ready    = nil | true | false          -- M3b: luminance.  nil = UNKNOWN
--   recede     = module-level alpha multiplier (board-quiet, §0.5.8.3 #5)
--   H.Apply(o) -- the single writer
--
-- `ready = nil` is load-bearing: at bind time we cannot know whether a cooldown
-- is up without a secret read, so the accent sits at BASE luminance until we
-- observe an edge.  Unknown is a state, not a value to guess.
local ADDON, ns = ...

ns.HudChrome = {}
local H = ns.HudChrome

local TERM_FONT = "Fonts\\ARIALN.TTF"   -- narrow bundled font (closest to mono)
local TERM      = { 0.29, 1.00, 0.48 }  -- terminal bright (frame + header)
local TERM_MID  = { 0.24, 0.82, 0.42 }
local TERM_DIM  = { 0.17, 0.55, 0.30 }
local KEY_COL   = { 0.78, 0.92, 0.80 }  -- keybind text: near-white, reads on any icon

-- Batch tint per POLE (guidance-model §0.5.8.4 `batch_tint`).
--   sat   — saturation multiplier around the colour's own luminance (never a
--           luminance change; see the header note)
--   width — edge thickness in px, the redundant non-colour channel
--   alpha — presence
--
-- v0.10.0 keyed this on ns.SpecPole instead of the old `role` enum.  The old
-- table is the reason the enum had to go: `spender` and `burst` carried
-- IDENTICAL values, so `burst` never encoded anything here — it only smuggled
-- burst-lane membership through the tint field.  Two poles is all this channel
-- ever expressed, so two poles is what it takes now.
local BATCH = {
  consumer  = { sat = 1.35, width = 5, alpha = 1.00 },  -- warm/bright end
  generator = { sat = 0.62, width = 3, alpha = 0.85 },  -- cool/dim end
  utility   = { sat = 0.50, width = 2, alpha = 0.70 },
  proc      = { sat = 1.00, width = 3, alpha = 0.85 },
}

-- Which side of the icon a viewer's dot + row run.  Bracketing the character
-- with two columns means the left-hand one must read leftward, or the chrome
-- collides with the icons instead of framing them.
local SIDE = {
  EssentialCooldownViewer = "RIGHT",
  UtilityCooldownViewer   = "LEFT",
  BuffBarCooldownViewer   = "RIGHT",
  BuffIconCooldownViewer  = "RIGHT",
}
function H.SideFor(viewer) return SIDE[viewer] or "RIGHT" end

--------------------------------------------------------------------------------
-- ============================ TUNING (one edit site) ========================
--------------------------------------------------------------------------------
-- LOUD PASS (v0.7.2).  The first in-game look at M3b found every state signal
-- too subtle to read at a glance, so these were deliberately cranked well past
-- where they'll probably settle.  The instruction was "crank them up so I see
-- them, tone them down later" — so treat these as a starting point for tuning,
-- NOT as considered final values.  They all live here, and only here, so that
-- toning down is one edit rather than a scavenger hunt through the module.
--
-- Everything below is OUR chrome only.  However loud these get, nothing here
-- ever touches Blizzard's icon art, swipe, countdown or charge text.
local READY_LIFT   = 0.75   -- ready -> toward white   (was 0.38)
local READY_WIDEN  = 2      -- ...and THICKEN the edge: the [X1] non-colour cue
local COOL_DROP    = 0.65   -- on-cooldown -> toward black (was 0.45)
local RECEDE_MIN   = 0.25   -- board-quiet alpha floor (was 0.45)

local SETTLE_TIME  = 0.55   -- one-shot ready flash, seconds (was 0.40)
local SETTLE_ALPHA = 0.85   -- ...and its peak alpha       (was 0.38)
local SETTLE_LIFT  = 0.75   -- ...how far toward white     (was 0.55)

local GLOW_INSET   = 4      -- how far outside the icon the proc ring sits (was 2)
local GLOW_WIDTH   = 5      -- proc ring thickness                         (was 2)
local GLOW_ALPHA   = 1.00   -- proc ring peak alpha                        (was 0.90)
local GLOW_MIN     = 0.55   -- pulse trough (higher = less blinky)         (was 0.40)
local GLOW_MAX     = 1.00
local GLOW_PERIOD  = 0.55

local STACK_SIZE   = 30     -- Wild Imp count: the one AoE readout (§0.5.8.3 #17)
                            -- 22 -> 30 (§7.2 item 3): it is the sole v1 assist
                            -- for Demo's central AoE decision and has to beat the
                            -- icon art it sits on.
local STACK_COL    = { 1.00, 0.86, 0.35 }   -- bright gold; must beat the icon art

-- ── The DOT (M3c-a, §0.5.8.7) ────────────────────────────────────────────────
-- A NEW OBJECT, which is the whole point: hue is spoken for (group), saturation
-- is spoken for (pole), luminance is spoken for (readiness), alpha is spoken for
-- (recede).  There was no free channel left, so actionability gets its own mark.
--
-- COLOUR HERE CARRIES **LEVEL**, NOT GROUP.  Group is already on the bracket;
-- level is the information.  That inversion is deliberate and is the single
-- biggest departure from M3b.
local DOT_GAP   = 8         -- icon edge -> dot
local DOT_BOX   = 16        -- the dot frame's box (the disc sizes inside it)
local ROW_GAP   = 6         -- dot -> text
H.ROW_OFFSET    = DOT_GAP + DOT_BOX + ROW_GAP   -- where HudRow anchors its text

-- size   — disc diameter
-- hollow — draw as a RING (the §0.5.8.7 confidence marker: hollow = estimate or
--          "you may, we're not calling it"; solid = an observed, asserted state)
-- pulse  — bounce period in seconds, or nil for no motion at all
local DOT = {
  NEVER     = { c = { 0.32, 0.50, 0.38 }, a = 0.45, size = 7,  hollow = false },
  -- SOON is the anticipation TREATMENT on NEVER.  Hollow on purpose: this is an
  -- estimate, not an observation, and an estimate must never look confident.
  SOON      = { c = { 0.40, 0.92, 0.52 }, a = 0.85, size = 12, hollow = true,  pulse = 0.90 },
  AVAILABLE = { c = { 0.29, 1.00, 0.48 }, a = 0.70, size = 13, hollow = true  },
  ROTATION  = { c = { 0.62, 1.00, 0.66 }, a = 1.00, size = 15, hollow = false, pulse = 0.55 },
  LATE      = { c = { 1.00, 0.72, 0.20 }, a = 1.00, size = 16, hollow = false, pulse = 0.32 },
}
H.DOT_COLORS = DOT
local DOT_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local BRACKET_PAD = 4

-- Push a colour toward/away from its own grey, holding luminance constant.
local function saturate(r, g, b, mul)
  local y = 0.299 * r + 0.587 * g + 0.114 * b
  local function ch(c) return math.max(0, math.min(1, y + (c - y) * mul)) end
  return ch(r), ch(g), ch(b)
end

--------------------------------------------------------------------------------
-- Per-item chrome
--------------------------------------------------------------------------------

-- A child frame ABOVE item.Cooldown holds our chrome, so accents and keybind
-- text aren't dimmed under the radial swipe.  (The frame-level trick is the one
-- proven in M1 — CRT.lua:96-106.)  Built once per item frame, reused thereafter.
local function ensure(item)
  if item.__hud then return item.__hud end
  local lvl = (ns.HasMethod(item, "GetFrameLevel") and item:GetFrameLevel() or 1) + 5
  if item.Cooldown and ns.HasMethod(item.Cooldown, "GetFrameLevel") then
    lvl = math.max(lvl, item.Cooldown:GetFrameLevel() + 2)
  end
  local f = CreateFrame("Frame", nil, item)
  f:SetAllPoints(item)
  f:SetFrameLevel(lvl)

  -- THE BRACKET (M3c-a).  The accent used to be four edges on `f`, which is
  -- SetAllPoints(item) — i.e. a border drawn ON Blizzard's icon art, which was
  -- the original legibility complaint.  It now spans ICON + DOT + TEXT, so group
  -- hue still carries identity but FRAMES the row instead of fighting the art.
  -- Its width comes from the row's GetStringWidth() via H.SetBracketExtent; it
  -- starts at icon-width and only grows once there is real text to measure.
  local b = CreateFrame("Frame", nil, item)
  b:SetFrameLevel(lvl)

  local o = { frame = f, bracket = b, item = item, edges = {},
              side = "RIGHT", rowExtent = 0 }
  -- Four edge textures forming the group accent border.
  for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    o.edges[side] = b:CreateTexture(nil, "OVERLAY")
  end
  o.key = f:CreateFontString(nil, "OVERLAY")
  o.key:SetFont(TERM_FONT, 10, "OUTLINE")
  o.key:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  o.key:SetTextColor(KEY_COL[1], KEY_COL[2], KEY_COL[3])

  item.__hud = o
  return o
end

-- Position the bracket around icon + dot + text.  `rowExtent` is 0 until the row
-- has measured itself, so the first frame is just an icon border and it GROWS —
-- never a wrong width from a FontString that has no text or no font yet, which
-- is the documented order-of-attach risk.
local function layoutBracket(o)
  local b, item = o.bracket, o.item
  if not (b and item) then return end
  local extra = (o.rowExtent or 0) + BRACKET_PAD
  b:ClearAllPoints()
  if o.side == "LEFT" then
    b:SetPoint("TOPRIGHT", item, "TOPRIGHT", BRACKET_PAD, BRACKET_PAD)
    b:SetPoint("BOTTOMLEFT", item, "BOTTOMLEFT", -extra, -BRACKET_PAD)
  else
    b:SetPoint("TOPLEFT", item, "TOPLEFT", -BRACKET_PAD, BRACKET_PAD)
    b:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", extra, -BRACKET_PAD)
  end
end

local function layoutEdges(o, w)
  local e, b = o.edges, o.bracket
  e.TOP:ClearAllPoints()
  e.TOP:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  e.TOP:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
  e.TOP:SetHeight(w)
  e.BOTTOM:ClearAllPoints()
  e.BOTTOM:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
  e.BOTTOM:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
  e.BOTTOM:SetHeight(w)
  e.LEFT:ClearAllPoints()
  e.LEFT:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  e.LEFT:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
  e.LEFT:SetWidth(w)
  e.RIGHT:ClearAllPoints()
  e.RIGHT:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
  e.RIGHT:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
  e.RIGHT:SetWidth(w)
end

--------------------------------------------------------------------------------
-- The composed accent: identity (hue+sat) x readiness (luminance) x recede (alpha)
--------------------------------------------------------------------------------

-- Luminance shift for readiness lives in the TUNING block at the top.  It is
-- deliberately a pure lighten/darken so the hue the group encodes survives the
-- shift — the two channels never fight ([V2]).
local recede = 1.0
-- Weak keys: chrome objects hang off pooled item frames we don't own.
local chromes = setmetatable({}, { __mode = "k" })
-- Whole frames that follow the recede as a unit — the terminal frame and the
-- scanline overlay.  v0.7.0 receded only the per-item accents and keybind text,
-- which on a 1-2px border is very nearly invisible; the surrounding chrome is
-- just as much "ours" and dimming it together is what makes the board actually
-- read as quiet.  Blizzard's icons are still never touched.
local receders = setmetatable({}, { __mode = "k" })

local function lighten(c, t) return c + (1 - c) * t end
local function darken(c, t)  return c * (1 - t) end

local function readyShift(r, g, b, ready)
  if ready == true then
    return lighten(r, READY_LIFT), lighten(g, READY_LIFT), lighten(b, READY_LIFT)
  elseif ready == false then
    return darken(r, COOL_DROP), darken(g, COOL_DROP), darken(b, COOL_DROP)
  end
  return r, g, b            -- UNKNOWN: base luminance.  Never a guess.
end

-- The ONE writer.  Everything else sets a field and calls this.
function H.Apply(o)
  local id = o.identity
  if not id then return end
  -- Apply() Show()s things, and it is reachable from GLOBAL paths (SetRecede
  -- walks every chrome object ever created; so does the row's collapse).  Item
  -- frames are POOLED, so that set outlives any one layout — without this gate a
  -- global repaint would re-show chrome on items the registry has already
  -- released, and `hud off` only Detach()es what's currently bound.  Detached
  -- chrome stays detached until something re-Attaches it.
  if not o.attached then return end
  local r, g, b = readyShift(id.r, id.g, id.b, o.ready)
  -- Readiness is carried on THREE channels, not just luminance: brighter, and
  -- thicker ([X1] — never colour-alone, and thickness survives colourblindness
  -- and a dim monitor where a luminance lift alone might not).
  layoutBracket(o)
  layoutEdges(o, id.width + (o.ready == true and READY_WIDEN or 0))
  local a = id.alpha * recede
  for _, t in pairs(o.edges) do
    t:SetColorTexture(r, g, b, a)
    t:Show()
  end
  o.bracket:Show()
  o.key:SetAlpha(recede)
  if o.glow then H.paintGlow(o) end
  if o.dotLevel then H.paintDot(o) end
end

--------------------------------------------------------------------------------
-- The dot — §0.5.8.7, the actionability mark
--------------------------------------------------------------------------------
-- Circular via WHITE8X8 + a TempPortraitAlphaMask MaskTexture, falling back to a
-- plain square if the mask fails — the same defensive idiom as HudRow's
-- applyFont.  A square dot is a cosmetic loss; a Lua error in a per-item paint
-- path is the HUD going dark, so this never gets to throw.
local function ensureDot(o, item)
  if o.dot then return o.dot end
  local f = CreateFrame("Frame", nil, item)
  f:SetSize(DOT_BOX, DOT_BOX)
  f:SetFrameLevel(o.frame:GetFrameLevel() + 3)

  local outer = f:CreateTexture(nil, "OVERLAY")
  outer:SetPoint("CENTER")
  outer:SetTexture("Interface\\Buttons\\WHITE8X8")
  -- The inner disc is what turns a solid dot into a RING: it punches a dark hole
  -- rather than being a second colour, so the ring reads at any size.
  local inner = f:CreateTexture(nil, "OVERLAY", nil, 1)
  inner:SetPoint("CENTER")
  inner:SetTexture("Interface\\Buttons\\WHITE8X8")

  f.round = pcall(function()
    for _, t in ipairs({ outer, inner }) do
      local m = f:CreateMaskTexture()
      m:SetTexture(DOT_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      m:SetAllPoints(t)
      t:AddMaskTexture(m)
    end
  end)

  local ag = f:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(0.40)
  a:SetToAlpha(1.00)
  ag:SetLooping("BOUNCE")
  f.ag, f.anim = ag, a
  f.outer, f.inner = outer, inner
  f:Hide()
  o.dot = f
  return f
end

local function anchorDot(o)
  local f = o.dot
  if not f then return end
  f:ClearAllPoints()
  if o.side == "LEFT" then
    f:SetPoint("RIGHT", o.item, "LEFT", -DOT_GAP, 0)
  else
    f:SetPoint("LEFT", o.item, "RIGHT", DOT_GAP, 0)
  end
  f.anchoredSide = o.side
end

-- Repaint at the current level x recede.  Recede is baked into the TEXTURE
-- alpha, never the frame alpha — the frame's alpha belongs to the pulse, and
-- letting the two share a channel is how a receding board would kill the motion.
function H.paintDot(o)
  local f = o.dot
  local spec = DOT[o.dotLevel]
  if not (f and spec) then return end
  if f.anchoredSide ~= o.side then anchorDot(o) end
  local a = spec.a * recede
  f.outer:SetSize(spec.size, spec.size)
  f.outer:SetColorTexture(spec.c[1], spec.c[2], spec.c[3], a)
  if spec.hollow then
    local inner = math.max(2, spec.size - 5)
    f.inner:SetSize(inner, inner)
    f.inner:SetColorTexture(0.02, 0.05, 0.03, a)
    f.inner:Show()
  else
    f.inner:Hide()
  end
end

-- level: one of the DOT keys, or nil to clear the dot entirely.
function H.SetDot(item, viewer, level)
  local o = item and item.__hud
  if not o then return end
  if viewer then o.side = H.SideFor(viewer) end
  if not (level and DOT[level]) then
    o.dotLevel = nil
    if o.dot then o.dot.ag:Stop(); o.dot:Hide() end
    return
  end
  local f = ensureDot(o, item)
  local changed = (o.dotLevel ~= level)
  o.dotLevel = level
  H.paintDot(o)
  if changed then
    local spec = DOT[level]
    f.ag:Stop()
    if spec.pulse then
      f.anim:SetDuration(spec.pulse)
      f:SetAlpha(1)
      f.ag:Play()
    else
      f:SetAlpha(1)
    end
  end
  f:Show()
end

function H.GetDot(item)
  local o = item and item.__hud
  return o and o.dotLevel or nil
end

-- The row reports how wide its text came out, and the bracket grows to include
-- it.  Called AFTER SetText, which is the only point GetStringWidth is valid.
function H.SetBracketExtent(item, textWidth)
  local o = item and item.__hud
  if not o then return end
  local extent = (textWidth and textWidth > 0) and (H.ROW_OFFSET + textWidth) or 0
  if o.rowExtent == extent then return end
  o.rowExtent = extent
  if o.identity then H.Apply(o) end
end

-- Readiness.  `ready` is tri-state; passing nil resets to UNKNOWN.
function H.SetReady(item, ready)
  local o = item and item.__hud
  if not o then return end
  o.ready = ready
  H.Apply(o)
end

-- Tri-state: true / false / nil.  NOT `o and o.ready or nil` — that collapses a
-- genuine `false` (on cooldown) into `nil` (unknown), which is exactly the
-- distinction this milestone exists to keep.
function H.GetReady(item)
  local o = item and item.__hud
  if not o then return nil end
  return o.ready
end

-- Board-quiet recede.  Global (the whole board dims together — common fate),
-- and it only ever touches OUR chrome; Blizzard's icons are never faded.
function H.SetRecede(mult)
  mult = math.max(RECEDE_MIN, math.min(1.0, tonumber(mult) or 1.0))
  if mult == recede then return end
  recede = mult
  for o in pairs(chromes) do H.Apply(o) end
  for f in pairs(receders) do f:SetAlpha(mult) end
end

function H.GetRecede() return recede end
H.RECEDE_MIN = RECEDE_MIN

--------------------------------------------------------------------------------
-- Ready settle — [V4], the one place motion is allowed
--------------------------------------------------------------------------------
-- A one-shot alpha fade on a dedicated overlay, ~0.4 s, then steady bright.  An
-- AnimationGroup, never an OnUpdate: the engine drives it and it costs nothing
-- once finished.
local function ensureSettle(o)
  if o.settle then return o.settle end
  local f = CreateFrame("Frame", nil, o.frame)
  f:SetAllPoints(o.frame)
  f:SetFrameLevel(o.frame:GetFrameLevel() + 1)
  local t = f:CreateTexture(nil, "OVERLAY")
  t:SetAllPoints(f)
  f.tex = t
  local ag = f:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetDuration(SETTLE_TIME)
  a:SetFromAlpha(1)
  a:SetToAlpha(0)
  ag:SetScript("OnFinished", function() f:Hide() end)
  f.ag = ag
  f:Hide()
  o.settle = f
  return f
end

-- Fire exactly once per observed ready edge; a re-fire restarts rather than
-- stacking, so a rapid re-trigger can never leave a latched-on wash.
function H.Settle(item)
  local o = item and item.__hud
  if not o or not o.identity then return end
  local f = ensureSettle(o)
  local id = o.identity
  f.tex:SetColorTexture(lighten(id.r, SETTLE_LIFT), lighten(id.g, SETTLE_LIFT),
                        lighten(id.b, SETTLE_LIFT), SETTLE_ALPHA)
  f.ag:Stop()
  f:SetAlpha(1)
  f:Show()
  f.ag:Play()
end

--------------------------------------------------------------------------------
-- Proc glow — §0.5.8.3 #2 / #3
--------------------------------------------------------------------------------
-- OURS, not LibCustomGlow (no new dependency) and not Blizzard's
-- spell-activation overlay — which stays untouched underneath, so a native proc
-- glow and ours can coexist rather than one hiding the other.  A terminal-
-- aesthetic border pulse: a thicker second border just outside the accent.
local function ensureGlow(o, item)
  if o.glow then return o.glow end
  local f = CreateFrame("Frame", nil, item)
  f:SetPoint("TOPLEFT", item, "TOPLEFT", -GLOW_INSET, GLOW_INSET)
  f:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", GLOW_INSET, -GLOW_INSET)
  f:SetFrameLevel(o.frame:GetFrameLevel() + 2)
  f.edges = {}
  for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    f.edges[side] = f:CreateTexture(nil, "OVERLAY")
  end
  local ag = f:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetDuration(GLOW_PERIOD)
  a:SetFromAlpha(GLOW_MIN)
  a:SetToAlpha(GLOW_MAX)
  ag:SetLooping("BOUNCE")
  f.ag = ag
  f:Hide()
  o.glow = f
  o.glowStrength = 1.0
  return f
end

-- Repaint the glow border at the current strength x recede.  Strength is the
-- §0.5.8.4 softening knob: a Core proc at >=4 shards would overcap, so the glow
-- SOFTENS rather than clearing — the cap cue outranks it but the proc is real.
function H.paintGlow(o)
  local f = o.glow
  if not f then return end
  local c = ns.SpecGroups[o.glowGroup or "proc"] or ns.SpecGroups.proc
  local a = GLOW_ALPHA * (o.glowStrength or 1.0) * recede
  local e = f.edges
  e.TOP:ClearAllPoints()
  e.TOP:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  e.TOP:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  e.TOP:SetHeight(GLOW_WIDTH)
  e.BOTTOM:ClearAllPoints()
  e.BOTTOM:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  e.BOTTOM:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  e.BOTTOM:SetHeight(GLOW_WIDTH)
  e.LEFT:ClearAllPoints()
  e.LEFT:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  e.LEFT:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  e.LEFT:SetWidth(GLOW_WIDTH)
  e.RIGHT:ClearAllPoints()
  e.RIGHT:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  e.RIGHT:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  e.RIGHT:SetWidth(GLOW_WIDTH)
  for _, t in pairs(e) do
    t:SetColorTexture(c[1], c[2], c[3], a)
    t:Show()
  end
end

-- on=false clears; strength scales it (1.0 = full, ~0.45 = softened).
function H.SetGlow(item, on, strength, group)
  local o = item and item.__hud
  if not o then return end
  if not on then
    if o.glow then o.glow.ag:Stop(); o.glow:Hide() end
    o.glowOn = false
    return
  end
  local f = ensureGlow(o, item)
  o.glowStrength = tonumber(strength) or 1.0
  o.glowGroup = group or "proc"
  H.paintGlow(o)
  if not o.glowOn then
    f:SetAlpha(GLOW_MIN)
    f:Show()
    f.ag:Stop()
    f.ag:Play()
    o.glowOn = true
  end
end

-- Current glow strength (1.0 full, <1 softened by the shard gate), or nil.
function H.GlowStrength(item)
  local o = item and item.__hud
  return (o and o.glowOn) and (o.glowStrength or 1.0) or nil
end

function H.IsGlowing(item)
  local o = item and item.__hud
  return (o and o.glowOn) and true or false
end

--------------------------------------------------------------------------------
-- Stack-count emphasis — §0.5.8.3 #17, the one AoE readout
--------------------------------------------------------------------------------
-- Demo's whole AoE loop hinges on one call: >=6 Wild Imps -> Implosion.  The
-- count is DISPLAYED by Blizzard but is a Secret Value we cannot read, so we
-- cannot compute ">=6" or rank Implosion against Hand of Gul'dan (§0.5.5).  What
-- we CAN do is make Blizzard's own number impossible to miss and print the gate
-- beside it, leaving the judgement where it belongs — with the player.
--
-- THE LAYOUT TRICK.  We can't read the number, so we can't know how wide it is,
-- so nothing may be positioned relative to its extent.  Instead the count is
-- right-justified to a fixed junction point and our static "/6" grows rightward
-- from that SAME point — so the pair stays glued whether it reads 1 or 12.
local stacked = setmetatable({}, { __mode = "k" })

function H.EmphasizeStacks(item, suffix)
  local fs = item and item.Applications
  if not fs or not ns.HasMethod(fs, "SetFont") then return false end
  local o = ensure(item)
  if not stacked[item] then
    -- Remember Blizzard's own styling so `hud off` really is pixel-clean.
    local font, size, flags = fs:GetFont()
    local p, rel, relP, x, y = fs:GetPoint()
    stacked[item] = { font = font, size = size, flags = flags,
                      p = p, rel = rel, relP = relP, x = x, y = y }
  end
  local st = stacked[item]
  local JX, JY = -14, 2                     -- the junction point, icon-relative
  -- BOTH fontstrings take the SAME font, and they change together or not at all
  -- (§7.2 item 3).  Until now both read Blizzard's saved `st.font`, so they
  -- matched by accident rather than by rule — swap one and you get a mismatched
  -- "4/6".  ns.SetFont carries the load-failure fallback the old unguarded call
  -- lacked; `st` still holds Blizzard's original triple so RestoreStacks keeps
  -- `hud off` pixel-clean.  Monospace is a real win here beyond consistency: a
  -- fixed-width digit stops the count jittering horizontally as imps come and go.
  pcall(function()
    ns.SetFont(fs, STACK_SIZE, "OUTLINE")
    fs:ClearAllPoints()
    fs:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", JX, JY)
    fs:SetJustifyH("RIGHT")
  end)
  if not o.stackSuffix then
    o.stackSuffix = o.frame:CreateFontString(nil, "OVERLAY")
  end
  ns.SetFont(o.stackSuffix, STACK_SIZE, "OUTLINE")
  o.stackSuffix:ClearAllPoints()
  o.stackSuffix:SetPoint("BOTTOMLEFT", item, "BOTTOMRIGHT", JX, JY)
  o.stackSuffix:SetJustifyH("LEFT")
  o.stackSuffix:SetTextColor(STACK_COL[1], STACK_COL[2], STACK_COL[3])
  o.stackSuffix:SetText(suffix or "")
  o.stackSuffix:Show()
  o.frame:Show()
  return true
end

function H.RestoreStacks(item)
  local st, fs = stacked[item], item and item.Applications
  if st and fs then
    pcall(function()
      fs:SetFont(st.font, st.size, st.flags)
      fs:ClearAllPoints()
      if st.p then fs:SetPoint(st.p, st.rel, st.relP, st.x, st.y) end
    end)
  end
  local o = item and item.__hud
  if o and o.stackSuffix then o.stackSuffix:Hide() end
end

--------------------------------------------------------------------------------
-- Attach / detach
--------------------------------------------------------------------------------

-- Attach (or refresh) the chrome for one item.  Returns true if a keybind text
-- was resolved, so HudCore can report hits/misses in `hud status`.
--
-- Sets IDENTITY only, then Apply()s — so readiness and glow survive a re-attach
-- (a relayout, or HudBinds' keybind refresh).  That is the whole point of the
-- composed accent.
function H.Attach(item, spellID, viewer)
  local o = ensure(item)
  chromes[o] = true
  o.attached = true
  if viewer then o.side = H.SideFor(viewer) end
  local info = ns.SpecInfo(spellID)
  local batch = BATCH[ns.SpecPole(info)] or BATCH.utility
  local r, g, b = ns.SpecColor(spellID)
  r, g, b = saturate(r, g, b, batch.sat)
  o.identity = { r = r, g = g, b = b, width = batch.width, alpha = batch.alpha }
  H.Apply(o)

  -- Keybind off the BASE spell: while Demonic Art has the button transformed,
  -- item:GetSpellID() reports the override, which is on no action bar (v0.7.0).
  local key = ns.HudBinds.GetForItem(item, spellID)
  o.key:SetText(key or "")           -- unbound -> blank, never a placeholder
  o.frame:Show()
  return key ~= nil
end

function H.Detach(item)
  H.RestoreStacks(item)
  local o = item and item.__hud
  if not o then return end
  o.attached = false            -- ...so no global repaint can bring it back
  H.SetGlow(item, false)
  H.SetDot(item, nil, nil)
  if o.settle then o.settle.ag:Stop(); o.settle:Hide() end
  o.ready = nil                       -- next enable starts at UNKNOWN, not stale
  o.rowExtent = 0                     -- ...and so does the bracket width
  if o.bracket then o.bracket:Hide() end
  o.frame:Hide()
end

--------------------------------------------------------------------------------
-- Scanline + vignette overlay
--------------------------------------------------------------------------------
-- Perf cleanup (b), notes.md §9.  M1 grew the texture pool on every reflow.  The
-- plan's preferred fix was ONE tiled texture, which needs a bundled power-of-two
-- scanline art file; we took the named fallback instead — a FIXED pool allocated
-- lazily up to a hard cap and only ever re-anchored afterwards.  Allocations are
-- O(1) amortised (they stop entirely once the tallest viewer has been seen) and
-- there is no binary art file whose load we cannot verify from here.
local SCAN_STEP, SCAN_MAX = 3, 128       -- a line every 3px, up to 384px of column

local function ensureScan(viewer)
  if viewer.__hudScan then return viewer.__hudScan end
  local f = CreateFrame("Frame", nil, viewer)
  f:SetAllPoints(viewer)
  f:SetFrameLevel((ns.HasMethod(viewer, "GetFrameLevel") and viewer:GetFrameLevel() or 1) + 10)
  -- Never EnableMouse: clicks pass through to the secure item beneath.
  local glow = f:CreateTexture(nil, "BACKGROUND")     -- faint phosphor wash
  glow:SetAllPoints(f)
  glow:SetColorTexture(TERM[1], TERM[2], TERM[3], 0.05)
  f.lines = {}
  receders[f] = true
  f:SetAlpha(recede)
  viewer.__hudScan = f
  return f
end

function H.FlowScan(viewer)
  local f = ensureScan(viewer)
  local h = math.floor((ns.HasMethod(viewer, "GetHeight") and viewer:GetHeight()) or 0)
  local n = math.max(0, math.min(SCAN_MAX, math.floor(h / SCAN_STEP)))
  for i = 1, n do
    local ln = f.lines[i]
    if not ln then
      ln = f:CreateTexture(nil, "OVERLAY")
      ln:SetColorTexture(0, 0, 0, 0.22)
      ln:SetHeight(1)
      f.lines[i] = ln
    end
    ln:ClearAllPoints()
    ln:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(i - 1) * SCAN_STEP)
    ln:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -(i - 1) * SCAN_STEP)
    ln:Show()
  end
  for i = n + 1, #f.lines do f.lines[i]:Hide() end
  f:Show()
  return #f.lines
end

function H.HideScan(viewer)
  if viewer.__hudScan then viewer.__hudScan:Hide() end
end

--------------------------------------------------------------------------------
-- DEMO.SYS terminal frame
--------------------------------------------------------------------------------
-- Ported from the M1 prototype (CRT.lua:193-259).  Keep the COMPACT
-- single-centre-anchor labels: notes.md §9 — a wide banner anchored with two
-- horizontal points fixes its width to the ~28px column and clips.
local terminal, blinkTicker

local function rule(parent, anchorTo, ptA, ptB, offY)
  local t = parent:CreateTexture(nil, "OVERLAY")
  t:SetColorTexture(TERM_MID[1], TERM_MID[2], TERM_MID[3], 0.8)
  t:SetHeight(1)
  t:SetPoint("TOPLEFT", anchorTo, ptA, 0, offY)
  t:SetPoint("TOPRIGHT", anchorTo, ptB, 0, offY)
  return t
end

local function buildTerminal(viewer)
  if viewer.__hudTerm then return viewer.__hudTerm end
  local f = CreateFrame("Frame", nil, viewer)
  f:SetAllPoints(viewer)
  f:SetFrameLevel((ns.HasMethod(viewer, "GetFrameLevel") and viewer:GetFrameLevel() or 1) + 12)

  local hd = f:CreateFontString(nil, "OVERLAY")
  hd:SetFont(TERM_FONT, 11, "OUTLINE")
  hd:SetPoint("BOTTOM", viewer, "TOP", 0, 9)
  hd:SetJustifyH("CENTER")
  hd:SetTextColor(TERM[1], TERM[2], TERM[3])
  hd:SetText("DEMO.SYS")
  f.header = hd

  local sub = f:CreateFontString(nil, "OVERLAY")
  sub:SetFont(TERM_FONT, 8, "OUTLINE")
  sub:SetPoint("TOP", hd, "BOTTOM", 0, -1)
  sub:SetJustifyH("CENTER")
  sub:SetTextColor(TERM_DIM[1], TERM_DIM[2], TERM_DIM[3])
  sub:SetText("v" .. tostring(ns.version))
  f.sub = sub

  rule(f, viewer, "TOPLEFT", "TOPRIGHT", 4)

  local function vrule(pt)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(TERM_MID[1], TERM_MID[2], TERM_MID[3], 0.55)
    t:SetWidth(1)
    t:SetPoint("TOP", viewer, pt == "L" and "TOPLEFT" or "TOPRIGHT", pt == "L" and -2 or 2, 4)
    t:SetPoint("BOTTOM", viewer, pt == "L" and "BOTTOMLEFT" or "BOTTOMRIGHT", pt == "L" and -2 or 2, -4)
  end
  vrule("L"); vrule("R")

  rule(f, viewer, "BOTTOMLEFT", "BOTTOMRIGHT", -4)
  local ft = f:CreateFontString(nil, "OVERLAY")
  ft:SetFont(TERM_FONT, 10, "OUTLINE")
  ft:SetPoint("TOP", viewer, "BOTTOM", 0, -6)
  ft:SetJustifyH("CENTER")
  ft:SetTextColor(TERM_MID[1], TERM_MID[2], TERM_MID[3])
  ft:SetText("C:\\>_")
  f.footer = ft
  f.cursorOn = true

  receders[f] = true
  f:SetAlpha(recede)
  viewer.__hudTerm = f
  return f
end

local function setBlink(on)
  if on then
    if blinkTicker then return end
    blinkTicker = C_Timer.NewTicker(0.53, function()
      if not terminal or not terminal.footer then return end
      terminal.cursorOn = not terminal.cursorOn
      terminal.footer:SetText("C:\\>" .. (terminal.cursorOn and "_" or " "))
    end)
  elseif blinkTicker then
    blinkTicker:Cancel(); blinkTicker = nil
  end
end

function H.ShowTerminal(viewer)
  if not viewer then return end
  terminal = buildTerminal(viewer)
  terminal:Show()
  setBlink(true)
end

function H.HideTerminal()
  setBlink(false)
  if terminal then terminal:Hide() end
end
