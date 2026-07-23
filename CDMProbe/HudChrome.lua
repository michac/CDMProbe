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

-- ── The CUE BAR = a coloured DROP SHADOW carrying the level (M4.3, M4.4) ──────
-- The actionability mark.  hue/sat/luminance/alpha are all spoken for on the icon,
-- so the level signal is its OWN object.  The mental model (feedback 2026-07-23):
-- a bright light shines on the icons from the LEFT, so each casts a soft DROP
-- SHADOW to the RIGHT (LEFT for Utility, per H.SideFor) — except the shadow is
-- COLOURED by the level.  So it is an icon-shaped soft square, offset toward the
-- cue side, drawn BEHIND the icon (BACKGROUND layer on the item frame) so the
-- icon art sits cleanly on top and only the coloured shadow peeks out.
--
-- The name is the **cue bar** (M4.4), chosen over "AHB" to dodge the keybind-HINT
-- collision.  Two redundant axes carry the level ([X1] — never colour-alone):
--   * COLOUR carries **LEVEL** (the M3b inversion, unchanged).
--   * WIDTH  carries **URGENCY** (M4.4, restored): a fatter bar reads as "press
--     this now" even on a dim monitor or to a colourblind eye where a hue shift
--     alone might not.  CUE_MIN is the floor; ROTATION/LATE widen; a burst
--     emphasis (A3) overrides to the widest bar on the board regardless of level.
--
-- Motion is ALPHA only (a growing shadow overflowed neighbours).
--   NEVER / AVAILABLE (held / overcap / quiet) — no shadow
--   judge-ready (Implosion off CD, gate is a secret) — cyan, steady, min width
--   SOON     — yellow, gentle alpha breathe, min width
--   ROTATION — green, steady, fatter
--   LATE     — green, slow alpha breathe (brighter), fattest — overdue
--   burst    — its level's hue, CUE_BURST width — the widest bar (Tyrant, A3)
--
-- SHAPE (feedback 2026-07-23 v2): NOT a full square (it read misaligned + boxy).
-- It is a THICK vertical BAR pinned to the icon's outer EDGE — only the "1,1→1,0"
-- side of the icon square — spanning the icon's exact height.  Anchored to the
-- icon corners so it lines up by construction, and it fades outward (solid at the
-- edge → soft outward) for the drop-shadow feel.
-- ── M4.6 §4.4 — THE CUE BOX (replaces the M4.3/M4.4 thickness bar) ───────────
-- The working space is now a SQUARE THE SIZE OF THE ICON, sitting beside it.
-- Priority is carried by how much of that box the colour FILLS, bottom-up:
-- max priority fills the whole box, min fills about a quarter.  The box itself
-- is never drawn — only the fill — so an empty box costs no ink.
--
-- WHY THE AXIS CHANGED.  The old bar carried priority in THICKNESS (14 -> 30px)
-- against no reference, so "thicker" was only legible next to another cue.  A
-- fill against a fixed square is self-referencing: one icon alone still tells you
-- how much of its box is lit.  [X1] is preserved — fill height is a non-colour
-- channel, so the signal survives a colourblind or dim-monitor read.
--
-- The keybind hint now sits SQUARE IN THE MIDDLE of that box and is allowed to
-- overlap the fill (player call, §4.4) — the hint keeps its outline, so it stays
-- legible on any fill level.
local CUE_FILL = { JUDGE = 0.25, SOON = 0.45, ROTATION = 0.80, LATE = 1.00 }
local CUE_BURST_FILL = 1.00   -- burst emphasis always fills the box (A3, Tyrant)
-- The row text clears the whole box, since the box is icon-width now.
H.CUE_BOX_PAD = 4
H.ROW_OFFSET = 44

-- c — level hue · a — alpha · pulse — slow alpha breathe period (s); nil = steady.
-- `fill` — fraction of the icon-sized box the colour occupies (§4.4).
local CUE = {
  JUDGE    = { c = { 0.27, 0.88, 1.00 }, a = 0.85,               fill = CUE_FILL.JUDGE },
  SOON     = { c = { 1.00, 0.86, 0.15 }, a = 0.80, pulse = 0.85, fill = CUE_FILL.SOON },
  ROTATION = { c = { 0.30, 1.00, 0.48 }, a = 1.00,               fill = CUE_FILL.ROTATION },
  LATE     = { c = { 0.42, 1.00, 0.58 }, a = 1.00, pulse = 1.3,  fill = CUE_FILL.LATE },
}

-- Level -> word colour, for the DEBUG rows only (non-verbose draws no words).
-- Derived from the cue hues so the word and the cue bar teach each other; keeps
-- the H.DOT_COLORS name HudRow.levelTag already reads.
H.DOT_COLORS = {
  NEVER     = { c = { 0.55, 0.55, 0.60 } },
  AVAILABLE = { c = { 0.29, 1.00, 0.48 } },
  SOON      = { c = CUE.SOON.c },
  ROTATION  = { c = CUE.ROTATION.c },
  LATE      = { c = CUE.LATE.c },
}

-- The group-hue BRACKET around each icon.  Turned OFF for the v0.16.2 test: it
-- grew and shrank with the row text width (which is loudest on the LONGEST,
-- i.e. least-actionable, rows) and read as inconsistent chrome.  Flip back to
-- true to restore it.
local SHOW_BRACKET = false
-- Our proc ring, RETIRED in the feedback pass.  Blizzard's own native proc glow
-- already marks a landed proc, and since the dot now lights ROTATION on the same
-- procs (HudScore, incl. the Infernal Bolt transform fix), a second border was
-- redundant chrome.  We keep the glow STATE (SetGlow still records glowOn /
-- strength — read by `hud status` and the verbose row, and by HudState's
-- "board-quiet" recede gate) but draw nothing.  Flip back to true to restore it.
local SHOW_GLOW = false
local BRACKET_PAD = 4

-- THE CRT AESTHETIC IS RETIRED (feedback 2026-07-23).  The scanlines + the green
-- DEMO.SYS terminal frame + phosphor wash were "getting in the way of proper
-- attention management", so both are OFF.  The functional chrome — the coloured
-- drop shadow, the keybind hint, the shard rail, the summary line — stays.  Flip
-- either back to true to restore the CRT look.
local SHOW_SCAN     = false
local SHOW_TERMINAL = false

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
  -- The keybind HINT.  M4.3: moved OFF the tiny icon corner to sit HORIZONTALLY
  -- beside the icon (on the shadow side), bigger and in the sharp mono font, so it
  -- reads as "which key is this" at a glance.  Positioned in anchorKey once the
  -- side is known (Attach); near-white + outline so it stays legible on the shadow.
  o.key = f:CreateFontString(nil, "OVERLAY")
  ns.SetFont(o.key, 14, "OUTLINE")
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
  if SHOW_BRACKET then
    layoutBracket(o)
    layoutEdges(o, id.width + (o.ready == true and READY_WIDEN or 0))
    local a = id.alpha * recede
    for _, t in pairs(o.edges) do
      t:SetColorTexture(r, g, b, a)
      t:Show()
    end
    o.bracket:Show()
  else
    for _, t in pairs(o.edges) do t:Hide() end
  end
  o.key:SetAlpha(recede)
  if o.glow then H.paintGlow(o) end
  if o.cueLevel then H.paintCue(o) end
end

--------------------------------------------------------------------------------
-- The cue bar — §0.5.8.7, the actionability mark (a coloured drop shadow, M4.3/M4.4)
--------------------------------------------------------------------------------
-- A texture on o.frame (our overlay, SetAllPoints(item)).  It lives just OUTSIDE
-- the icon edge, so it never covers the art and needs no behind-the-icon trickery.
local function ensureCue(o, item)
  if o.cue then return o.cue end
  local t = o.frame:CreateTexture(nil, "OVERLAY")
  t:SetTexture("Interface\\Buttons\\WHITE8X8")

  -- ONE alpha breathe group (SOON / LATE).  Region alpha only, so it never fights
  -- the recede baked into the colour alpha.
  local ag = t:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(0.5)
  a:SetToAlpha(1.00)
  ag:SetLooping("BOUNCE")

  t.ag, t.anim = ag, a
  t:Hide()
  o.cue = t
  return t
end

-- Pin the FILL inside an icon-sized box beside the icon.  The box is square and
-- matches the icon's dimensions; the fill grows from its BOTTOM edge upward, so
-- the level reads like a meter.  Anchoring to the icon's own corners is what keeps
-- it aligned by construction (the M4.3 misalignment was a CENTER-offset square
-- guessing the size — do not reintroduce that).
--
-- SIDE stays per-viewer (H.SideFor), not hard-right: the box mirrors to the icon's
-- OUTER edge so it never lands between two icon columns.
local function anchorCue(o)
  local t, item = o.cue, o.item
  if not (t and item) then return end
  local w = (ns.HasMethod(item, "GetWidth") and item:GetWidth()) or 0
  if w <= 0 then w = 28 end               -- pre-layout fallback; re-anchored later
  t:ClearAllPoints()
  -- Bottom-anchored, so SetHeight() in paintCue grows the fill upward.
  if o.side == "LEFT" then
    t:SetPoint("BOTTOMRIGHT", item, "BOTTOMLEFT", 0, 0)
  else
    t:SetPoint("BOTTOMLEFT", item, "BOTTOMRIGHT", 0, 0)
  end
  t:SetWidth(w)
  t.boxW = w
  t.anchoredSide = o.side
end

-- The keybind hint sits SQUARE IN THE MIDDLE of the cue box (§4.4).  Overlapping
-- the fill is explicitly fine — the hint carries an outline, so it stays readable
-- at any fill level, and centring it means the eye finds the key in the same spot
-- on every icon instead of tracking a bar's outer edge.
local function anchorKey(o)
  local k = o.key
  if not (k and o.item) then return end
  local w = (ns.HasMethod(o.item, "GetWidth") and o.item:GetWidth()) or 28
  if w <= 0 then w = 28 end
  k:ClearAllPoints()
  k:SetJustifyH("CENTER")
  if o.side == "LEFT" then
    k:SetPoint("CENTER", o.item, "LEFT", -w / 2, 0)
  else
    k:SetPoint("CENTER", o.item, "RIGHT", w / 2, 0)
  end
end

-- Repaint at the current level x recede.  Recede is baked into the colour alpha,
-- never the region alpha — region alpha belongs to the breathe.  A horizontal
-- gradient (solid at the icon edge → soft outward) gives the drop-shadow depth;
-- pcall'd, falling back to a flat bar if SetGradient's shape differs on a client.
-- WIDTH (A2/A3): the level's own `w`, unless a burst emphasis overrides it to the
-- widest bar on the board (Tyrant's go-signal is widest even in yellow SOON).
function H.paintCue(o)
  local t = o.cue
  local spec = o.cueLevel and CUE[o.cueLevel]
  if not (t and spec) then return end
  if t.anchoredSide ~= o.side or not t.boxW then anchorCue(o) end
  local item = o.item
  local boxH = (item and ns.HasMethod(item, "GetHeight") and item:GetHeight()) or 0
  if boxH <= 0 then boxH = t.boxW or 28 end
  -- §4.4 — FILL is the priority axis.  Burst emphasis fills the box outright.
  local frac = (o.emphasis == "burst") and CUE_BURST_FILL or (spec.fill or CUE_FILL.JUDGE)
  t:SetHeight(math.max(2, boxH * frac))

  local c = spec.c
  local a = spec.a * recede
  -- ⚠ §4.5a — THE BASE IS THE LEVEL COLOUR, NEVER WHITE.
  -- This used to be `SetColorTexture(1,1,1,1)` with the hue supplied ONLY by the
  -- SetGradient below, inside a pcall whose coloured fallback fired only on a
  -- THROW.  When SetGradient no-ops SILENTLY instead of erroring, `ok` stays true,
  -- the fallback never runs, and every cue renders as the white it was seeded
  -- with — which is exactly what play-test 5 photographed (`lit 2` with three
  -- WHITE bars).  White is not in the cue palette, so it could only ever mean
  -- "this signal is broken", and it was indistinguishable from a real state.
  -- RULE: never initialise a signal surface to a colour outside its own palette.
  -- Painting the flat colour FIRST means a failed gradient degrades to a correct
  -- solid fill; the gradient is now depth only, and pure decoration.
  t:SetColorTexture(c[1], c[2], c[3], a)
  pcall(function()
    local solid = CreateColor(c[1], c[2], c[3], a)
    local soft  = CreateColor(c[1], c[2], c[3], a * 0.45)
    if o.side == "LEFT" then
      t:SetGradient("HORIZONTAL", soft, solid)   -- solid at the icon (right) edge
    else
      t:SetGradient("HORIZONTAL", solid, soft)   -- solid at the icon (left) edge
    end
  end)
end

-- level:      one of the score LEVELS ("NEVER"/"AVAILABLE"/"SOON"/"ROTATION"/
--             "LATE"), or nil to clear the cue bar entirely.
-- judgeReady: true when a judgeable=false ability is otherwise up (Implosion off
--             cooldown) — the one AVAILABLE that lights (cyan "ready, your call").
-- emphasis:   "burst" makes this the WIDEST bar on the board regardless of level
--             (A3, Tyrant only) — hue still carries the level, width carries "this
--             is the burst go-signal".  nil for everything else.
-- NEVER and plain AVAILABLE draw NOTHING; the board only ever cues a call.
function H.SetCue(item, viewer, level, judgeReady, emphasis)
  local o = item and item.__hud
  if not o then return end
  if viewer then o.side = H.SideFor(viewer) end
  o.emphasis = emphasis
  local bkey
  if level == "SOON" then bkey = "SOON"
  elseif level == "ROTATION" then bkey = "ROTATION"
  elseif level == "LATE" then bkey = "LATE"
  elseif level == "AVAILABLE" and judgeReady then bkey = "JUDGE"
  end
  local spec = bkey and CUE[bkey]
  -- The keybind hint is NOT tinted to the level any more (M4.3): it now sits ON the
  -- coloured shadow beside the icon, so it stays high-contrast near-white + outline
  -- for readability rather than matching (and disappearing into) the shadow hue.
  if not spec then
    o.cueLevel = nil
    if o.cue then o.cue.ag:Stop(); o.cue:Hide() end
    return
  end
  local f = ensureCue(o, item)
  local changed = (o.cueLevel ~= bkey)
  o.cueLevel = bkey
  H.paintCue(o)
  if changed then
    f.ag:Stop()
    f:SetAlpha(1)
    if spec.pulse then
      f.anim:SetDuration(spec.pulse)
      f.ag:Play()
    end
  end
  f:Show()
end

-- The palette, exposed READ-ONLY for the cue watchdog (HudCueWatch, M4.6).  The
-- watchdog must compare against the SAME table paintCue paints from — a second
-- copy of the hues would drift and start reporting phantom divergences.
function H.CueColor(level)
  local spec = level and CUE[level]
  return spec and spec.c or nil
end

function H.GetCue(item)
  local o = item and item.__hud
  return o and o.cueLevel or nil
end

--------------------------------------------------------------------------------
-- Cast-start flair on the icon — D (M4.4)
--------------------------------------------------------------------------------
-- A quiet one-shot bloom beside a CASTING ability's icon, on UNIT_SPELLCAST_START.
-- Confirmation the cast is going, never a call — the icon already carries the cue
-- bar + keybind + native swipe, so this is deliberately brief and low-alpha.  It
-- reuses the cue-bar texture plumbing (a pooled OVERLAY texture on o.frame, its
-- own one-shot Alpha group) rather than spinning up new animation machinery.
local function ensureFlash(o)
  if o.castFlash then return o.castFlash end
  local t = o.frame:CreateTexture(nil, "OVERLAY")
  t:SetTexture("Interface\\Buttons\\WHITE8X8")
  t:SetAllPoints(o.frame)
  local ag = t:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(0.28)          -- low-alpha: confirmation, not a call
  a:SetToAlpha(0)
  a:SetDuration(0.45)
  ag:SetScript("OnFinished", function() t:SetAlpha(0) end)
  t.ag = ag
  t:SetAlpha(0)
  o.castFlash = t
  return t
end

-- Fire once per cast start.  Re-fire restarts rather than stacking (the H.Settle
-- discipline).  Tinted to the icon's group hue so it reads as "this" lighting up.
function H.CastFlash(item)
  local o = item and item.__hud
  if not (o and o.attached and o.identity) then return end
  local t = ensureFlash(o)
  local id = o.identity
  t:SetColorTexture(lighten(id.r, 0.5), lighten(id.g, 0.5), lighten(id.b, 0.5), 1)
  t.ag:Stop()
  t:SetAlpha(0.28)
  t:Show()
  t.ag:Play()
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
    o.glowShown = false
    return
  end
  o.glowStrength = tonumber(strength) or 1.0
  o.glowGroup = group or "proc"
  o.glowOn = true
  -- SHOW_GLOW retired: keep the state above (diagnostics + recede gate), draw
  -- nothing.  Hide any ring a previous build left up.
  if not SHOW_GLOW then
    if o.glow then o.glow.ag:Stop(); o.glow:Hide() end
    o.glowShown = false
    return
  end
  local f = ensureGlow(o, item)
  H.paintGlow(o)
  if not o.glowShown then
    f:SetAlpha(GLOW_MIN)
    f:Show()
    f.ag:Stop()
    f.ag:Play()
    o.glowShown = true
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
  anchorKey(o)                        -- beside the icon on the shadow side (M4.3)
  o.frame:Show()
  return key ~= nil
end

function H.Detach(item)
  H.RestoreStacks(item)
  local o = item and item.__hud
  if not o then return end
  o.attached = false            -- ...so no global repaint can bring it back
  H.SetGlow(item, false)
  H.SetCue(item, nil, nil)
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
  if not SHOW_SCAN then if viewer.__hudScan then viewer.__hudScan:Hide() end return end
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
local terminal

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

  -- Every frame texture is recorded with the alpha it was built at, because the
  -- mode tint (M3c-c1 R4) repaints them and SetColorTexture takes the alpha in
  -- the same call — a repaint that forgot it would silently flatten the
  -- header/rule/vrule hierarchy to one weight.
  f.rules = {}
  local function keep(t, a) t.__a = a; f.rules[#f.rules + 1] = t; return t end

  keep(rule(f, viewer, "TOPLEFT", "TOPRIGHT", 4), 0.8)

  local function vrule(pt)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(TERM_MID[1], TERM_MID[2], TERM_MID[3], 0.55)
    t:SetWidth(1)
    t:SetPoint("TOP", viewer, pt == "L" and "TOPLEFT" or "TOPRIGHT", pt == "L" and -2 or 2, 4)
    t:SetPoint("BOTTOM", viewer, pt == "L" and "BOTTOMLEFT" or "BOTTOMRIGHT", pt == "L" and -2 or 2, -4)
    return keep(t, 0.55)
  end
  vrule("L"); vrule("R")

  keep(rule(f, viewer, "BOTTOMLEFT", "BOTTOMRIGHT", -4), 0.8)
  -- The `C:\>_` blinking footer was retired in the M4.1 feedback pass: it was
  -- noise, and its blink ticker was the only recurring timer in the chrome.

  receders[f] = true
  f:SetAlpha(recede)
  viewer.__hudTerm = f
  return f
end

function H.ShowTerminal(viewer)
  if not SHOW_TERMINAL then return end   -- CRT frame retired (M4.3)
  if not viewer then return end
  terminal = buildTerminal(viewer)
  terminal:Show()
end

function H.HideTerminal()
  if terminal then terminal:Hide() end
end

--------------------------------------------------------------------------------
-- The shard rail + the mode chrome — §0.5.8.3 #1, M3c-c1
--------------------------------------------------------------------------------
-- §0.5.2 makes shard-cap the anchor: "if exactly one cue survives every
-- accessibility/mute ceiling, it is shard-cap."  Moment #1, P0 — inaction there
-- is strictly wrong — and it rides our single strongest capability, because Soul
-- Shards are readable AND branchable even in restricted combat.  Until now
-- nothing on the HUD said it: the board judges BUTTONS, and overcap is a
-- statement about the RESOURCE.  This is the first surface for a sentence that
-- isn't about a button.
--
-- ⚠ WHERE MODE IS ALLOWED TO LAND (the §0.5.8.7 §1 budget).  hue = group,
-- saturation = pole, luminance = readiness, alpha = recede — the icon channel
-- budget is FULL, and [V2] forbids conjunction encodings.  The dot exists
-- because that budget ran out.  So §0.5.4 row #6 (the mode indicator) is not
-- demoted, but it may not compete for a channel the dot already won: it lands on
-- the rail's own fill and on the DEMO.SYS terminal frame, both genuinely free
-- surfaces, and NEVER on an icon.  It also carries a redundant glyph + label,
-- because [X1] forbids colour-alone and §0.5.4 asks for the label by name.
--
-- Geometry and the cap animation are PORTED from the M1 prototype
-- (Resource.lua:132-243), which is proven but UIParent-anchored, self-eventing
-- and exports nothing — a reference to port, never to call.  Resource.lua is
-- left alone; it is parked and SetHud already turns it off.
--
-- ⚠ THE CAP EARCON IS NOT HERE.  The M3c-c bullet says "+ earcon", but
-- §0.5.8.3 row #15 (Stretch), §0.5.8.5-D and §0.5.6 ("cap earcon lands in M6")
-- all say otherwise — three committed statements against one.  The flip and the
-- glitter ship silently; audio arrives in M6 WITH its mute + per-event toggles,
-- which is what [A3] actually asks for.  Do not add a PlaySound here.
-- VERTICAL rail (feedback pass): it stands to the LEFT of the icon column,
-- bottom-aligned, centred on the Essential viewer's full height — five DOTS
-- (M4.4) rising bottom-to-top as shards fill.
--
-- FIVE DOTS, not a sliced bar (B, M4.4).  Each shard segment renders as a
-- round-ish DOT (a masked circle where the mask loads, a square fallback), with a
-- generous gap so five read as five discrete dots.  Three explicit states — empty
-- ring / incoming projected-ring / filled disc — via one paintDot().
local RAIL_GAP      = 8     -- gap between shard DOTS (was 3 for the sliced bar)
local RAIL_SEG_W    = 14    -- the rail's WIDTH = the dot diameter (kept slim)
local RAIL_LEFT_GAP = 6     -- gap between the rail's right edge and the icon column
local RAIL_ICONS    = 3     -- fallback span (icons tall) if the viewer can't be measured
local RAIL_DEF_ICON = 34    -- fallback icon pitch if the panel can't be measured
local RAIL_RING_W   = 3     -- ring thickness for the empty/incoming states
local RAIL_SPARKS = 10
-- A circular alpha mask that ships with the client (the retired disc's idiom).
-- pcall-guarded at apply: if it ever fails to load, the dot stays a square, which
-- still reads as five discrete segments given the gap.
local DOT_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
-- [X2] — WCAG's three-flashes-in-one-second guidance.  The prototype's
-- `fireGlitter` fired on EVERY prevCapped transition, so at cap a Hand of
-- Gul'dan (-3) followed by a refill re-fires within a couple of GCDs.  That is a
-- real defect being ported out, not a new restriction.
local GLITTER_REARM = 2.0

-- Triples from Resource.lua:23-28, tuned once already, plus the two states the
-- prototype never had: PREP (§0.5.8.2(a)'s "fourth resting state, NOT
-- GENERATE") and UNKNOWN.
local RAIL_COL = {
  PREP     = { 0.36, 0.66, 0.82 },   -- calm slate-cyan: visibly not GENERATE
  GENERATE = { 0.690, 0.420, 1.000 },-- soul purple
  SPEND    = { 1.000, 0.541, 0.239 },-- orange
  -- M4 — BURST windup (Tyrant coming up, hold/cap).  A MINIMAL entry so the rail
  -- doesn't misrender the new mode as UNKNOWN-grey (which would falsely claim
  -- shards are unreadable); the fuller designed board tint (#10) stays deferred.
  BURST    = { 0.98, 0.68, 0.22 },   -- deep amber: charged, about to unload
  CAP      = { 0.961, 0.773, 0.259 },-- gold
  UNKNOWN  = { 0.50, 0.50, 0.56 },   -- grey: a state, never a guess
}
local RAIL_RING = { 0.30, 0.29, 0.36 }   -- empty dot: a faint placeholder ring
local RAIL_HOLE = { 0.05, 0.05, 0.07 }   -- the dark centre of an empty/incoming ring

local rail
local railStats = { edges = 0, glitters = 0, suppressed = 0, lastGlitter = 0 }
function H.RailStats()
  return { edges = railStats.edges, glitters = railStats.glitters,
           suppressed = railStats.suppressed, rearm = GLITTER_REARM }
end

local function buildSpark(parent)
  local t = parent:CreateTexture(nil, "OVERLAY")
  t:SetSize(4, 4); t:SetColorTexture(1, 1, 1, 1); t:SetAlpha(0)
  local ag = t:CreateAnimationGroup()
  local tr = ag:CreateAnimation("Translation"); tr:SetDuration(0.85); tr:SetSmoothing("OUT")
  local fa = ag:CreateAnimation("Alpha"); fa:SetFromAlpha(1); fa:SetToAlpha(0); fa:SetDuration(0.85)
  ag:SetScript("OnPlay", function() t:SetAlpha(1) end)
  ag:SetScript("OnFinished", function() t:SetAlpha(0) end)
  t.ag, t.tr = ag, tr
  return t
end

-- The pitch (icon-to-icon centre distance) and icon height of the panel, measured
-- from the live item frames so the rail's height tracks whatever the player set in
-- Edit Mode.  Falls back to a sane default if the frames aren't laid out yet.
local function iconMetrics(viewer)
  local iconH, pitch = RAIL_DEF_ICON, RAIL_DEF_ICON
  local items = ns.GetItemFrames and select(1, ns.GetItemFrames(viewer)) or nil
  if items and items[1] and ns.HasMethod(items[1], "GetHeight") then
    iconH = items[1]:GetHeight() or iconH
    pitch = iconH
    if items[2] and ns.HasMethod(items[1], "GetTop") and ns.HasMethod(items[2], "GetTop") then
      local t1, t2 = items[1]:GetTop(), items[2]:GetTop()
      if t1 and t2 and math.abs(t1 - t2) > 1 then pitch = math.abs(t1 - t2) end
    end
  end
  return iconH, pitch
end

-- One dot = two masked-circle textures stacked: a RIM (the outer disc) and a
-- CORE (the smaller inner disc).  A filled dot is rim+core both in the mode hue;
-- an empty/incoming dot is a coloured rim over a DARK core, so it reads as a
-- hollow ring — the same hollow-estimate convention the cue bar and napkin use.
local function makeDisc(seg, sublevel)
  local t = seg:CreateTexture(nil, "ARTWORK", nil, sublevel)
  t:SetTexture("Interface\\Buttons\\WHITE8X8")
  pcall(t.SetMask, t, DOT_MASK)     -- circle where the mask loads; square fallback
  return t
end

local function buildRail(viewer)
  if viewer.__hudRail then return viewer.__hudRail end
  local cap = ns.SHARD_CAP or 5      -- never a literal 5; the spec table owns it

  -- FULL-HEIGHT (M4.1): span the WHOLE icon column, measured off the viewer, so
  -- the rail stands as tall as the stack the player laid out in Edit Mode.  Falls
  -- back to the bottom-RAIL_ICONS estimate ((N-1) pitches + one icon height) when
  -- the viewer isn't laid out yet and GetHeight reads 0.
  local iconH, pitch = iconMetrics(viewer)
  local span = (ns.HasMethod(viewer, "GetHeight") and viewer:GetHeight()) or 0
  if not span or span < 1 then span = (RAIL_ICONS - 1) * pitch + iconH end
  -- Each dot gets an equal SLOT of the span; the round dot is centred in its slot,
  -- so the five dots spread evenly over the Essential viewer's full height.  The
  -- dot itself is clamped roughly square (never wider than the slim rail).
  local segH = (span - (cap - 1) * RAIL_GAP) / cap
  local dotSize = math.max(8, math.min(segH, RAIL_SEG_W))

  local f = CreateFrame("Frame", nil, viewer)
  f:SetFrameLevel((ns.HasMethod(viewer, "GetFrameLevel") and viewer:GetFrameLevel() or 1) + 12)
  f:SetSize(RAIL_SEG_W, span)
  -- To the LEFT of the icon column, bottom-aligned.  Its right edge sits
  -- RAIL_LEFT_GAP left of the viewer's left edge.
  f:SetPoint("BOTTOMRIGHT", viewer, "BOTTOMLEFT", -RAIL_LEFT_GAP, 0)
  -- Never EnableMouse: clicks pass through to the secure item beneath.

  f.segH = segH
  f.dotSize = dotSize
  f.segs = {}
  for i = 1, cap do
    local seg = CreateFrame("Frame", nil, f)
    seg:SetSize(RAIL_SEG_W, segH)
    -- Slot 1 is at the BOTTOM; the stack grows upward.
    seg:SetPoint("BOTTOM", f, "BOTTOM", 0, (i - 1) * (segH + RAIL_GAP))
    -- The dot, centred in the slot.  Rim under core; PaintRail recolours both.
    local rim = makeDisc(seg, 1)
    rim:SetSize(dotSize, dotSize)
    rim:SetPoint("CENTER", seg, "CENTER", 0, 0)
    local core = makeDisc(seg, 2)
    core:SetSize(math.max(2, dotSize - 2 * RAIL_RING_W), math.max(2, dotSize - 2 * RAIL_RING_W))
    core:SetPoint("CENTER", seg, "CENTER", 0, 0)
    seg.rim = rim
    seg.core = core
    f.segs[i] = seg
  end

  -- The redundant mode LABEL ("[.] PREP 3/5") was retired in the M4.1 feedback
  -- pass: unreadable on the narrow column, and the mode still reads via the rail
  -- fill hue + the DEMO.SYS terminal tint (SetTerminalMode).  The shard count
  -- still shows on the HudRow summary line.

  -- ⚠ RECEDE vs. ANIMATION (H.paintCue's header states the rule): recede is
  -- baked into TEXTURE alpha, never frame alpha, because frame alpha belongs to
  -- the animation.  The rail as a whole DOES take frame alpha — it joins the
  -- board's common fate — so the cap flash and sparks live on a SIBLING frame,
  -- not a child: a child would inherit the receded alpha and the P0 cue would
  -- be dimmest exactly when the board was quietest.
  receders[f] = true
  f:SetAlpha(recede)

  local fx = CreateFrame("Frame", nil, viewer)
  fx:SetAllPoints(f)
  fx:SetFrameLevel(f:GetFrameLevel() + 1)
  local flash = fx:CreateTexture(nil, "OVERLAY")
  flash:SetAllPoints(fx)
  flash:SetColorTexture(RAIL_COL.CAP[1], RAIL_COL.CAP[2], RAIL_COL.CAP[3], 0.5)
  flash:SetAlpha(0)
  local fag = flash:CreateAnimationGroup()
  local fa = fag:CreateAnimation("Alpha")
  fa:SetFromAlpha(0.55); fa:SetToAlpha(0); fa:SetDuration(0.7)
  fag:SetScript("OnPlay", function() flash:SetAlpha(0.55) end)
  fag:SetScript("OnFinished", function() flash:SetAlpha(0) end)
  fx.flash, fx.flashAG = flash, fag
  fx.sparks = {}
  for i = 1, RAIL_SPARKS do fx.sparks[i] = buildSpark(fx) end

  f.fx = fx
  f.cap = cap
  f.prevCapped = false
  viewer.__hudRail = f
  return f
end

-- One-shot, throttled.  Stop() before Play() so a re-fire RESTARTS rather than
-- stacking — the same discipline H.Settle uses.
-- Returns whether the glitter actually PLAYED, so the caller can log the
-- difference between an edge, a glitter and a suppression (§7.5 item 5) — the
-- three are distinguishable in the counters but not in time, and the whole
-- question is whether a fast cap -> HoG -> cap re-fires within a couple of GCDs.
local function fireGlitter()
  local f = rail
  if not (f and f.fx) then return false end
  local now = GetTime()
  if (now - (railStats.lastGlitter or 0)) < GLITTER_REARM then
    railStats.suppressed = railStats.suppressed + 1
    return false
  end
  railStats.lastGlitter = now
  railStats.glitters = railStats.glitters + 1
  local fx = f.fx
  fx.flashAG:Stop(); fx.flashAG:Play()
  local w = f:GetWidth()
  for _, s in ipairs(fx.sparks) do
    s:ClearAllPoints()
    s:SetPoint("CENTER", fx, "CENTER", math.random(-w / 2 + 6, w / 2 - 6), math.random(-4, 4))
    s.tr:SetOffset(math.random(-8, 8), math.random(10, 22))
    s.ag:Stop(); s.ag:Play()
  end
  return true
end

--------------------------------------------------------------------------------
-- Mode chrome, surface 2: the DEMO.SYS terminal frame
--------------------------------------------------------------------------------
-- Header, sub, rules, vrules, footer.  It never touches an icon, and the shift
-- is a BLEND toward the mode hue rather than a replacement, so the terminal
-- still reads as the terminal.
local termMode = nil

local function modeTint(base, mode)
  local m = mode and RAIL_COL[mode]
  if not m then return base[1], base[2], base[3] end
  local t = (mode == "CAP") and 0.45 or 0.28
  return base[1] + (m[1] - base[1]) * t,
         base[2] + (m[2] - base[2]) * t,
         base[3] + (m[3] - base[3]) * t
end

local function paintTerminal()
  local f = terminal
  if not f then return end
  if f.header then f.header:SetTextColor(modeTint(TERM, termMode)) end
  if f.sub    then f.sub:SetTextColor(modeTint(TERM_DIM, termMode)) end
  for _, t in ipairs(f.rules or {}) do
    local r, g, b = modeTint(TERM_MID, termMode)
    t:SetColorTexture(r, g, b, t.__a or 0.8)
  end
end

-- nil restores the plain terminal (rail off, or shards unreadable).
function H.SetTerminalMode(mode)
  if mode == termMode then return end
  termMode = mode
  paintTerminal()
end

--------------------------------------------------------------------------------
-- The painter
--------------------------------------------------------------------------------
-- Colour one dot into one of the three explicit states (B, M4.4).  filled = a
-- solid disc in the mode hue; empty = a faint placeholder ring; incoming = a dim
-- mode-hue ring (a shard a live cast will add — the hollow-estimate convention,
-- so "projected" can never be mistaken for "held").  unknown = a grey ring when
-- shards are unreadable — never a blank, because a blank is a CLAIM we can't make.
local function paintDot(seg, state, col)
  local rim, core = seg.rim, seg.core
  if not (rim and core) then return end
  if state == "filled" then
    rim:SetVertexColor(col[1], col[2], col[3], 1)
    core:SetVertexColor(col[1], col[2], col[3], 1)
  elseif state == "incoming" then
    rim:SetVertexColor(col[1], col[2], col[3], 0.55)
    core:SetVertexColor(RAIL_HOLE[1], RAIL_HOLE[2], RAIL_HOLE[3], 1)
  elseif state == "unknown" then
    rim:SetVertexColor(RAIL_COL.UNKNOWN[1], RAIL_COL.UNKNOWN[2], RAIL_COL.UNKNOWN[3], 0.45)
    core:SetVertexColor(RAIL_HOLE[1], RAIL_HOLE[2], RAIL_HOLE[3], 1)
  else -- empty
    rim:SetVertexColor(RAIL_RING[1], RAIL_RING[2], RAIL_RING[3], 0.85)
    core:SetVertexColor(RAIL_HOLE[1], RAIL_HOLE[2], RAIL_HOLE[3], 1)
  end
  rim:Show(); core:Show()
end

-- `info` comes from ns.HudState.RailInfo() — one computation, so the rail's dots
-- and the terminal's tint can never disagree about the mode.
function H.PaintRail(info)
  local f = rail
  if not (f and info) then return end
  local cap    = f.cap
  local mode   = info.mode
  local capped = info.capped and true or false
  -- CAP is a treatment on SPEND, not a fourth mode: [B1] frames it as "act or
  -- waste" — a WARNING, not a trophy.  Overcap is an opportunity-cost loss, and
  -- §3's celebratory framing is explicitly nuanced by that.
  local key = mode and (capped and "CAP" or mode) or "UNKNOWN"
  local col = RAIL_COL[key] or RAIL_COL.UNKNOWN

  local live = info.shards
  local proj = info.projected
  for i = 1, cap do
    local seg = f.segs[i]
    if mode == nil then
      -- UNREADABLE draws explicit UNKNOWN rings, never empty dots.  An empty dot
      -- is a CLAIM — "you have no shards" — and we do not know that.
      paintDot(seg, "unknown", col)
    elseif live and i <= live then
      paintDot(seg, "filled", col)
    elseif info.isProjected and live and proj and proj > live and i > live and i <= proj then
      -- The incoming dot: strictly ABOVE what we hold, and only while a cast in
      -- flight ADDS shards.  A spend-side projection moves the mode, not the dots.
      paintDot(seg, "incoming", col)
    else
      paintDot(seg, "empty", col)
    end
  end

  -- The mode label was retired (M4.1); mode reads via the dot hue + terminal
  -- tint (SetTerminalMode, at the tail).  `col`/`key` still drive the dots above.

  -- The cap EDGE, once.  Counted whether or not the glitter was allowed to play,
  -- so `hud status` can show the throttle doing its job rather than implying the
  -- edge never happened.
  if capped and not f.prevCapped then
    railStats.edges = railStats.edges + 1
    local played = fireGlitter()
    -- M3e — §7.5 item 5 wants the edge, the glitter and the SUPPRESSION told
    -- apart in time, not just counted.  A fast cap -> HoG -> cap must read as two
    -- edges and one suppression.
    if ns.HudLog then
      ns.HudLog.Note("cap", string.format("cap edge (%d/%d) — %s",
        live or -1, cap, played and "glitter" or "SUPPRESSED by the re-arm"))
    end
  end
  f.prevCapped = capped

  H.SetTerminalMode(mode and key or nil)
end

function H.ShowRail(viewer)
  if not viewer then return end
  rail = buildRail(viewer)
  rail:Show()
  rail.fx:Show()
end

function H.HideRail()
  if rail then rail:Hide(); rail.fx:Hide() end
  H.SetTerminalMode(nil)
end
