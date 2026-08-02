-- Renderer.lua — Stage 4 of the W4 pipeline: DrawList -> **Renderer** -> pixels.
--
-- WHY THIS EXISTS (docs/architecture.md Stage-4 :352-361, docs/archive/w4-build-plan.md Phase 3).
-- The pipeline is State -> Coach -> Guidance -> Binder -> DrawList -> Renderer.
-- Stages 1-2 (State, Coach) are the DECISION half and are done + golden-tested.
-- This is the DRAW half's terminal stage: given a positioned, token-carrying
-- DrawList it owns a frame/texture pool and turns it into pixels.  It makes NO
-- decisions — it never sees a Guidance, never reads State, never asks the game a
-- question.  The ONE impure line in the draw path is `registry[anchorTo]`: an
-- opaque handle -> frame lookup (live: cooldownID -> CDM item frame; test:
-- "fake1" -> a placeholder square).  Everything else is coords + a style token.
--
-- WHAT A CUE IS NOW (2026-08-02 — the v2 treatment; v1 is archive/cue-treatment-v1.lua):
--   * cue = a black BACKING DISC + a solid DOT + TWO COUNTER-ROTATING RINGS, all coloured
--     by its `emphasis` token and all riding a per-icon CUE LAYER frame (see ensureLayer).
--     ⚠ The ring pair's numbers came from a BLIND EXPERIMENT, not from dialling — see the
--     header at RING_SCALE.  No breathe: that one retired with v1 and has not come back.
--   * ...plus the POP: one short scale on the cue layer, played on BOTH edges (see
--     POP_PEAK).  ⚠ It is WRITTEN FRESH, not recovered from v1 — read the header there
--     before assuming it is the old one wearing new numbers.
--   * keybind = a corner key hint, drawn from the DrawList's OWN `keybinds[]` channel
--     (Phase 3) — identity chrome, independent of whether the icon is cued.  It rides
--     the HOLDER, deliberately NOT the cue layer.
--   * panel = a plain titled list of step rows (state · keybind · label), shown
--     only when the DrawList carries one.
--   * resourceBars = an array of minimal discrete-pip rows, stacked (optional).
--   * NO CRT chrome (bracket / DEMO.SYS / scanlines stay retired).
--
-- THE ONE INJECTED CALLBACK: `cfg.onCueSetChanged(kind)`, fired ONCE per draw on which
-- the CUE SET changed at all (`"new"` if anything was added, else `"gone"`).  The
-- Renderer still calls no game function — the driver hangs the sound off it — and busted
-- can assert the edges directly.  Same idiom as `Coach.New{shardCost=…}` /
-- `Binder.New{keybindFor=…}`.
--
-- TOKEN -> PIXELS IS THE RENDERER'S JOB (guidance-contract.json).  DrawList v1
-- carries the emphasis TOKEN, not resolved RGBA, so colour stays OUT of the Binder
-- (Phase 4 is a pure GEOMETRY merge).  The Renderer resolves token -> colour via a
-- built-in theme, injectable through cfg.  This deliberately supersedes
-- architecture.md's older DrawList sketch (which showed a pre-resolved
-- `color:[r,g,b,a]`); that doc says the Stage-3/4 shape "is revised when the
-- Binder is actually built".
--
-- PURE-ISH FACTORY, like the Coach: Renderer.New(cfg) / __index, theme injectable, no
-- global render state.  The pool + registry live on the instance.
local ADDON, ns = ...

ns.Renderer = {}
local R = ns.Renderer
R.__index = R

--------------------------------------------------------------------------------
-- The default theme — emphasis TOKEN -> RGBA.
--------------------------------------------------------------------------------
-- Emphasis token -> RGBA.  Tokens must be GLANCEABLE — distinct enough to read apart in
-- the icon corner at a flick of the eye.  2026-07-26: LATE read identical to ROTATION as
-- another green-family shade, so it came off green.
-- ⚠ THIS TABLE IS NOT THE LAST WORD ON WHAT A CUE DRAWS.  GLOW_SPEC below may redirect a
-- token's colour, and it does exactly that for LATE — so LATE renders ROTATION's GREEN, not
-- the amber below.  Editing the amber here changes nothing on screen; go to GLOW_SPEC.
local function defaultTheme()
  return {
    ROTATION          = { 0.30, 1.00, 0.48, 1.00 },  -- green:      press now
    -- ROTATION_FALLBACK: hue ON TOP OF motion.  v0.32.17 made the runner-up read by its
    -- ring being STATIC rather than by a dimmer green ("motion, not colour") — that stands;
    -- this ADDS a hue so the backup is separable at a glance without waiting to see whether
    -- the ring turns.  ⚠ Deliberately NOT the shard violet: SOUL_SHARDS pips are
    -- {0.690, 0.420, 1.000}, and a cue in that hue reads as "resource" next to the bar.
    -- This is pushed bluer and deeper (a deep saturated violet), so it separates from BOTH
    -- the pips and ROTATION's green.  The separating channel is GREEN: the pips are a pale
    -- lavender (G .42), this is vivid (G .16).  A first cut at {0.42, 0.36, 1.00} was
    -- rejected — only 0.28 from the pips under the theme's own separation metric, i.e. the
    -- collision this must avoid.
    ROTATION_FALLBACK = { 0.52, 0.16, 0.98, 1.00 },  -- violet:     the runner-up
    LATE              = { 1.00, 0.42, 0.10, 1.00 },  -- amber:      SUPERSEDED for cues —
                                                     -- GLOW_SPEC redirects LATE to ROTATION
    SOON              = { 1.00, 0.86, 0.15, 1.00 },  -- yellow:     anticipation
  }
end

-- Per-emphasis GLOW/RING spec — the source of truth for ring behaviour (token ->
-- pixels lives in the Renderer, per architecture invariant #5).  Supersedes
-- HudGeometry.G.GLOW_EMPHASIS / the `glow` bool.
--   * an entry ⇒ this emphasis draws the RING PAIR (+ a solid circle dot).
--   * `spin` ⇒ whether the rings rotate.  false ⇒ a STATIC pair.
--   * `color` redirects the colour lookup for BOTH circle and rings (LATE -> ROTATION
--     green).  It OVERRIDES the theme entry for that token — see the theme note above.
--   * no entry (IDLE / unknown) ⇒ no circle, no rings (keybind-only if it carries one).
--   * `ringScale` = per-emphasis ring SIZE (defaults to RING_SCALE); `spinMult` = how much
--     FASTER this emphasis turns (defaults to 1). These express DEGREE without a hue.
local GLOW_SPEC = {
  ROTATION          = { spin = true },
  -- LATE is not a different KIND of press -- it is the SAME press, overdue.  So it is the
  -- rotation cue ESCALATED (a bigger ring spinning ~2.5x faster), not a second colour.
  -- WARNING: this deliberately reverses part of the 2026-07-26 dial-in, which pulled LATE
  -- onto hot amber because green SHADES were indistinguishable.  That finding stands -- this
  -- is not a second shade of green, it is the SAME green moving differently.  In play the
  -- amber read as a distinct INSTRUCTION rather than an urgent one, and it collided with
  -- SOON's yellow.  Do not "restore" the amber without re-testing the motion channel first.
  -- ringScale is RELATIVE to GLOW_SCALE by intent (~1.4x), so it moved with it when the
  -- base ring shrank to close the dot/ring gap.  Keep that ratio if either is retuned —
  -- the escalation is "a bigger ring", not "this exact number".
  -- ⚠ THE SPEED ESCALATION IS NOW A MULTIPLIER, NOT AN ABSOLUTE.  It used to be
  -- `spinSecs = 4.8` against a 12.0s base — a ratio wearing an absolute, which is exactly
  -- how it silently stopped meaning "2.5x faster" every time the base period moved.  There
  -- are TWO base periods now (the pair turns at different rates by design), so an absolute
  -- could not express it at all.  `spinMult` scales both.
  -- ringScale stays relative to RING_SCALE by intent (~1.39x).
  -- The escalation is "a bigger ring, turning faster", never these exact numbers.
  LATE              = { spin = true, color = "ROTATION",
                        ringScale = 4.64, spinMult = 2.5 },
  SOON              = { spin = true },
  -- ROTATION_FALLBACK animates like everything else now (2026-07-30 feedback).  History:
  -- v0.32.17 made the runner-up read by its ring being STATIC, because it was a DIMMER
  -- GREEN and motion was the only channel left to separate it from ROTATION.  It has its
  -- own violet since v0.32.36, so HUE carries the distinction and the stillness bought
  -- nothing — it just made the backup look like a dead cue next to the live ones.
  ROTATION_FALLBACK = { spin = true },
}

-- powerType -> RGBA.  SOUL_SHARDS is the soul-violet — the shard colour by construction.
local function defaultPowerColor()
  return {
    SOUL_SHARDS = { 0.690, 0.420, 1.000, 1.00 },
  }
end

-- Empty-pip ring for the resource bar (a state, not a guess).
local EMPTY_PIP = { 0.30, 0.29, 0.36, 0.60 }

-- Keybind-hint text colour — near-white green, reads on any icon.
local KEY_COL = { 0.78, 0.92, 0.80 }

-- State -> row tint for the panel.  A bare colour cue on top of the state word.
local STATE_TINT = {
  done    = { 0.45, 0.55, 0.48, 1.00 },  -- dim green: behind you
  active  = { 0.30, 1.00, 0.48, 1.00 },  -- bright green: the cursor
  pending = { 0.72, 0.72, 0.78, 1.00 },  -- grey: ahead
  blocked = { 1.00, 0.42, 0.35, 1.00 },  -- red: gated
  skipped = { 0.45, 0.44, 0.50, 0.70 },  -- faded: not this pull
}

local WHITE8 = "Interface\\Buttons\\WHITE8X8"

-- The round-disc MASK.  Used by BOTH the cue dot and the backing disc, because the same
-- two shortcuts are ruled out for both — see the dot's creation comment for the measured
-- reasons (`SetMask(path)` does not clip a `SetColorTexture` fill; the round atlas ships
-- a baked outline `SetVertexColor` cannot tint away).
local DOT_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------
function R.New(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, R)
  self.theme      = cfg.theme or defaultTheme()
  self.powerColor = cfg.powerColor or defaultPowerColor()
  self.registry   = {}          -- handle / root token -> frame (the one impure seam)
  self.root       = cfg.root    -- our own overlay parent (panel + pips); created lazily
  self.cueHolders = {}          -- anchorTo -> holder frame parented to the icon (P5d)
  self.cueHolderAnchor = {}     -- anchorTo -> the frame the holder is currently on
  self.cueLayers  = {}          -- anchorTo -> the CUE LAYER frame (see ensureLayer)
  self.cueFrames  = {}          -- anchorTo -> dot texture (diff-by-key pool)
  self.cueKeys    = {}          -- anchorTo -> keybind-hint fontstring (diff-by-key)
  self.cueRingIn   = {}         -- anchorTo -> the INNER ring texture (faster, brighter)
  self.cueRingOut  = {}         -- anchorTo -> the OUTER ring, counter-rotating
  self.cueDiscs   = {}          -- anchorTo -> the black backing disc under both
  self.cuedLast   = {}          -- the PREVIOUS draw's cue-active set: the EDGE input.
                                -- added = active - last, removed = last - active.
  self.leaving    = {}          -- anchorTo -> true while its POP-OUT is still playing.
                                -- The only state the pop adds, and it is what keeps a
                                -- departing cue's art (and its holder) on screen for the
                                -- ~0.18s after it left both active sets.  See R:popCue.
  -- Injected, defaults to nil so the Renderer still never calls a game function.  Fired
  -- ONCE per draw that changed the cue set — see drawCueEdges for why a SWAP is one event.
  self.onCueSetChanged = cfg.onCueSetChanged
  self.glowing    = {}          -- anchorTo -> true while its dot is glowing.  Written
                                -- here, read only by renderer_spec: the one observable
                                -- proof the glow path ran.  Keep it — it is an
                                -- assertion surface, not dead state.
                                -- ⚠ IT TRACKS THE COMMANDED STATE, NOT PIXELS.  It clears
                                -- the instant a cue leaves the DrawList, even though
                                -- `leaving` is still holding that cue's art on screen for
                                -- its pop-out.  Do not conflate the two: one answers "is
                                -- this icon being cued", the other "is it still drawn".
  self.pipRows    = {}          -- barIndex -> { 1..N pip textures } (per-bar pool)
  self.panelWidget = nil        -- { frame, title, rows = {} }, built on first panel
  -- UIPARENT is a sanctioned root token (architecture.md :341); pre-register it so
  -- a hand-authored DrawList can anchor a panel/bar to the screen with no ceremony.
  self.registry.UIPARENT = cfg.uiparent or UIParent
  return self
end

-- Populate the registry.  Live mode maps cooldownID -> CDM item frame; test mode
-- maps "fake1" -> a placeholder square.  Root tokens (UIPARENT) go through the same
-- door — R.New pre-registers UIPARENT, so nothing else has needed to.
function R:Register(handle, frame) self.registry[handle] = frame; return self end

-- The root parents our OWN self-anchored widgets (the panel + the resource pips),
-- NOT the cue decorations.  It sits at MEDIUM — the action-bar strata — so those
-- widgets behave like the rest of the combat UI: above the world, but COVERED by a
-- full-screen panel (the map, the character sheet).  This is the same strata
-- Blizzard's spell-activation glow lives at, which is exactly the behaviour the cue
-- decorations mimic via per-icon holders (see ensureHolder).
function R:ensureRoot()
  if not self.root then
    self.root = CreateFrame("Frame", nil, UIParent)
    self.root:SetAllPoints(UIParent)
    self.root:SetFrameStrata("MEDIUM")
  end
  return self.root
end

-- P5d STRATA FIX — cue decorations ride a per-icon HOLDER frame parented to the CDM
-- icon, NOT the global root.  Two properties fall out of that parenting:
--   * STRATA: the holder inherits the icon's strata, so whatever covers the icon (a
--     full-screen map / character panel) covers the dot too — the old DIALOG root
--     drew the dots on top of EVERYTHING, including those panels (the bug).  This is
--     how Blizzard's own action-button glow behaves.
--   * LEVEL: the holder sits CUE_LEVEL_ABOVE frame-levels over the icon, so its dot
--     draws on top of the icon's own swipe/cooldown CHILD frames within that strata
--     (a texture on the icon itself would render UNDER those child frames).
-- ⚠ CUE_LEVEL_ABOVE is the in-game knob: it must clear the icon's Cooldown swipe
-- level.  Bumped here if a live pass shows the swipe still occluding the dot.
local CUE_LEVEL_ABOVE = 10

function R:ensureHolder(key, anchor)
  local h = self.cueHolders[key]
  if not h then
    h = CreateFrame("Frame", nil, anchor)
    self.cueHolders[key] = h
  elseif self.cueHolderAnchor[key] ~= anchor then
    h:SetParent(anchor)         -- the icon was repooled to a new frame; ride it
  end
  self.cueHolderAnchor[key] = anchor
  h:SetAllPoints(anchor)
  h:SetFrameLevel((anchor:GetFrameLevel() or 0) + CUE_LEVEL_ABOVE)
  h:Show()
  return h
end

--------------------------------------------------------------------------------
-- The CUE LAYER — one frame per icon, grouping everything a cue draws.
--------------------------------------------------------------------------------
-- WHAT RIDES IT.  dot + both rings + backing disc.  The KEYBIND FONTSTRING DELIBERATELY
-- DOES NOT — it stays on the holder, because it is identity chrome and belongs to the
-- icon rather than to the decision.  renderer_spec pins that.
--
-- ⚠ IT EXISTS FOR THE POP.  A one-shot `Scale` on the cue's TEXTURES would be fought by
-- the draw path re-asserting `SetSize` on them at ~10 Hz, so the pop scales a FRAME that
-- owns them and nothing in the draw path touches that frame's size.  (The frame earns its
-- keep even without the pop — one parent per icon means the cue's four regions are
-- created, parented and re-parented as a unit when a holder is rebuilt — but the pop is
-- why it was built, and the pop is back.)
--
-- ITS RECT IS THE DOT'S RECT, not the icon's — the layer takes the cue entry's geometry,
-- the dot is CENTERed on the layer, and the rings + disc stay CENTERed on the dot.
--
-- ⚠ ITS GEOMETRY IS RE-STAMPED ONLY ON CHANGE.  The cue geometry is constant in practice
-- (G.DOT), so the guard costs nothing and never re-stamps after the first draw.
--
-- FRAME LEVEL = THE HOLDER'S, not above it.  A child frame defaults one level up, which
-- would put the rings' ARTWORK over the keybind's OVERLAY on the holder.  Level-matched,
-- draw layer decides, and the key hint keeps drawing on top of the rings.
function R:ensureLayer(key, holder, c, sz)
  local l = self.cueLayers[key]
  if not l then
    l = CreateFrame("Frame", nil, holder)
    self.cueLayers[key] = l
  elseif l._holder ~= holder then
    l:SetParent(holder)                    -- the holder was rebuilt; ride it...
    l._sz = nil                            -- ...and re-stamp, or the point names the old one
  end
  l._holder = holder
  l:SetFrameLevel(holder:GetFrameLevel())
  local pt   = c.point or "CENTER"
  local rel  = c.relPoint or c.point or "CENTER"
  local dx, dy = c.dx or 0, c.dy or 0
  if l._sz ~= sz or l._pt ~= pt or l._rel ~= rel or l._dx ~= dx or l._dy ~= dy then
    l._sz, l._pt, l._rel, l._dx, l._dy = sz, pt, rel, dx, dy
    l:SetSize(sz, sz)
    l:ClearAllPoints()
    l:SetPoint(pt, holder, rel, dx, dy)    -- the holder IS the icon's rect (SetAllPoints)
  end
  l:Show()
  return l
end

--------------------------------------------------------------------------------
-- THE POP — one short scale on the cue layer, played at BOTH edges.
--------------------------------------------------------------------------------
-- WHY.  A cue arriving is an INSTRUCTION CHANGE, and steady-state art gives the eye
-- nothing to catch it by: the set turns over at cast cadence (120 changes / 504s of real
-- play, 60 % of them SWAPS), so without a transient a swap reads as "the ring was always
-- there".  The pop is that transient, on both halves of the swap.
--
-- ⚠ WRITTEN FRESH, DELIBERATELY NOT RECOVERED.  v1 had a pop too
-- (archive/cue-treatment-v1.lua) and `popPlaying` was the ONE field that differed between
-- the code path which reproduced the old "the spin rubber-bands forever" artefact and the
-- path that did not.  That makes v1's pop a suspect, so none of it was copied: different
-- peak, different structure, and the ordering rules below were re-derived rather than
-- inherited.  Do not "restore" it from the archive.
--
--------------------------------------------------------------------------------
-- ⚠⚠ KNOWN DEFECT, SHIPPED ON PURPOSE (2026-08-02).  THE POP BRINGS THE SPIN
-- ARTEFACT BACK, AND WE ARE KEEPING THE POP ANYWAY UNTIL IT IS UNDERSTOOD.
--------------------------------------------------------------------------------
-- The rings rubber-band while the pop is in.  It is a KNOWN, ACCEPTED trade — the pop is
-- worth more in play than the steady spin is — not something nobody has noticed.  ⚠ Do not
-- "fix" it by deleting the pop; that answer is already known and was rejected.
--
-- TWO FLIGHTS, TWO RESULTS, AND BOTH COST A BUILD — DO NOT RE-DERIVE THEM:
--
--   1. v0.32.76 (POP_PEAK 1.35) — the artefact came back.  v2's pop shares almost nothing
--      with v1's (peak, duration, one animation instead of a pop plus a ghost, ordering,
--      bookkeeping — all different), so this is no longer a suspect off a SavedVariables
--      capture.  It is a REPRODUCTION, in two independent implementations, and what it
--      indicts is the only thing they share: an ANIMATION RUNNING ON AN ANCESTOR FRAME OF
--      THE ROTATING TEXTURES.
--   2. v0.32.77 (POP_PEAK 1.0) — STILL PRESENT.  So it is NOT the visible size change.
--      ⚠ READ THAT PRECISELY: at 1.0 the Scale animation still EXISTS and still PLAYS, it
--      merely interpolates 1 -> 1.  What is eliminated is the MAGNITUDE, not the running
--      animation.  "The ancestor scale did it" is still live and is still the best theory.
--
-- SO THE TWO SURVIVING SUSPECTS, and the experiment that separates them:
--   A. an AnimationGroup PLAYING on an ancestor frame, whatever it animates
--        -> test: keep the departure delay, drive it with C_Timer, create NO group at all
--   B. the departure bookkeeping — `leaving` keeps a SPINNING ring alive past the draw
--      that dropped it, where the pre-pop cull parked it in that same draw
--        -> test: keep the pop, park the rings immediately on departure
-- If A lands, the fix is structural and keeps the pop: scale the DOT on its own child
-- frame, so the rings are simply not in the animated subtree.
--
-- ⚠ AND NOTE WHAT DID *NOT* CATCH ANY OF THIS.  renderer_spec pins that a pop never calls
-- Play() on either ring's Rotation, and that assertion is TRUE and passes — the mechanism
-- is not a restart.  An off-game harness records what a widget was TOLD; this is about
-- what the renderer DOES with a transform, so no source gate in this repo can see it.
-- Adding a test here does not close the question; only a flight does.
--
-- POP_PEAK is the one-number dial: 1.0 disables the visual half while leaving every bit of
-- the bookkeeping intact (that is exactly how flight 2 above was run).  v1 doubled the cue
-- at 2.0x; 1.35x is deliberately gentler.
local POP_PEAK = 1.35
local POP_SECS = 0.18

-- ⚠ THE SETTER NAME IS GENUINELY AMBIGUOUS, AND A SILENT MISS IS THE ONE UNACCEPTABLE
-- FAILURE.  Blizzard's generated API doc for the Scale animation carries
-- `SetScaleFrom` / `SetScaleTo` (Blizzard_APIDocumentationGenerated/
-- SimpleAnimScaleAPIDocumentation.lua, build 12.0.7.68887); a great deal of addon code
-- still calls the older `SetFromScale` / `SetToScale`, and the XML attributes are a third
-- spelling again (`fromScaleX`/`toScaleX`) — which is all the KB records, so this is not
-- paranoia.  v1 branched on whichever existed and did NOTHING if neither did, and on
-- screen "the setter was missing" is indistinguishable from "the pop does not help" — the
-- one wrong answer this must not give.  So: take the spelling that exists, and SAY SO if
-- neither does.
local popWarned = false
local function scaleSetters(anim)
  if anim.SetScaleFrom and anim.SetScaleTo then return anim.SetScaleFrom, anim.SetScaleTo end
  if anim.SetFromScale and anim.SetToScale then return anim.SetFromScale, anim.SetToScale end
  if not popWarned then
    popWarned = true
    ns.Print("|cffff4040cue pop disabled|r — this client's Scale animation has neither "
      .. "SetScaleFrom/SetScaleTo nor SetFromScale/SetToScale.  Cues still draw and still "
      .. "clear; they just do not punch on arrival.")
  end
  return nil
end

-- ONE GROUP, TWO SYMMETRIC HALVES: SetOrder(1) grows, SetOrder(2) returns.  ONE TARGET —
-- the layer — so disc, dot and BOTH rings scale together and the draw path never touches
-- what is animating.  Returns nil (once, warned) if this client has no usable setter.
local function buildPop(layer)
  local g = layer:CreateAnimationGroup()
  local up, down = g:CreateAnimation("Scale"), g:CreateAnimation("Scale")
  local setFrom, setTo = scaleSetters(up)
  if not setFrom then return nil end
  setFrom(up, 1, 1)
  setTo(up, POP_PEAK, POP_PEAK)
  setFrom(down, POP_PEAK, POP_PEAK)
  setTo(down, 1, 1)
  for i, a in ipairs({ up, down }) do
    a:SetOrder(i)
    a:SetDuration(POP_SECS / 2)
    a:SetOrigin("CENTER", 0, 0)
  end
  return g
end

-- Built once per layer, on the layer (the layer object is stable per handle — ensureLayer
-- re-parents it rather than rebuilding it).  `_popBuilt` is what stops a client with no
-- usable setter from creating a fresh throwaway group on every draw.
function R:ensurePop(key)
  local layer = self.cueLayers[key]
  if not layer then return nil end
  if not layer._popBuilt then
    layer._popBuilt = true
    local g = buildPop(layer)
    if g then g:SetScript("OnFinished", function() self:onPopFinished(key) end) end
    layer.pop = g
  end
  return layer.pop
end

-- The pop ENDS.  On an arrival that means nothing; on a DEPARTURE it is the moment the
-- cue's art finally leaves the screen.  ⚠ `Stop()` fires this too — see R:popCue.
function R:onPopFinished(key)
  if not self.leaving[key] then return end
  self.leaving[key] = nil
  self:hideCueArt(key)
end

-- ONE ANIMATION, BOTH EDGES — only the ordering around it differs.  On ARRIVAL the cue is
-- already drawn and shown by drawCues, so the pop simply plays.  On DEPARTURE the pop
-- plays FIRST and its OnFinished is what hides the art.
--
-- ⚠ THE ORDER IS LOAD-BEARING.  `Stop()` FIRES OnFinished (the client does, with
-- requested = true, and tests/mock_ns.lua models it), so the flag OnFinished reads has to
-- be settled around the stop and never before it:
--     arrival:   clear `leaving` -> Stop -> Play
--     departure: Stop -> set `leaving` -> Play
-- Set the flag before the stop on departure and a cue that leaves twice in quick
-- succession hides its own art mid-animation.
function R:popCue(key, leaving)
  local g = self:ensurePop(key)
  if not g then
    -- No layer (an unknown emphasis draws nothing), or no usable Scale setter: there is no
    -- animation to wait for, so nothing may be marked as waiting for one — otherwise the
    -- art and its holder would be stranded on screen with no OnFinished ever coming.
    self.leaving[key] = nil
    return
  end
  if leaving then
    g:Stop()
    self.leaving[key] = true
  else
    self.leaving[key] = nil
    g:Stop()
  end
  g:Play()
end

--------------------------------------------------------------------------------
-- Cue dots (3b)
--------------------------------------------------------------------------------
-- A cue is a solid coloured CIRCLE (a masked fill, see the dot creation) + a
-- spinning glow RING, coloured by its emphasis token and anchored to its handle's
-- frame — a corner treatment INSIDE the icon (the DrawList geometry puts it
-- upper-right; see the fixtures).  Diff-by-key on `anchorTo`: only handles in THIS
-- DrawList are (re)painted; a handle that dropped out is hidden, never destroyed.
--
-- THE DOT AND THE KEY HINT ARE TWO CHANNELS (Phase 3, roster-state-plan §4).  A cue
-- carries an emphasis token and nothing else; the key hint arrives on the DrawList's own
-- `keybinds[]` list and is drawn by R:drawKeybinds.  Until Phase 3 both rode ONE cue entry
-- and an emphasis-less "empty cue" was how a key hint reached an uncued icon — which is
-- why this function used to keep a dotless handle alive on purpose.  It no longer has to:
-- a handle with no emphasis simply is not in `cues`.
--
-- ⚠ `drawCues` RETURNS its active set rather than culling `cueHolders` itself.  Holders
-- are SHARED with the keybind channel, so the cull is a UNION and lives in R:Draw — see
-- the note there.  An unknown/absent emphasis token still draws no circle (never guess a
-- colour) and hides any prior one; that defensive branch stays.
--
-- A CLEAN DISC: a solid fill clipped by a real MaskTexture OBJECT, attached with
-- AddMaskTexture.  Borderless by construction — the shape comes from the mask's alpha,
-- the colour from our own fill.  Two measured API facts rule out the shorter routes:
--   * `SetMask(path)` does NOT clip a `SetColorTexture` fill — that pairing draws a
--     SQUARE (settles the interaction addon-dev/frames-textures-animation.md §5.7 flags
--     as uncited).
--   * the `WhiteCircle-RaidBlips` atlas is genuinely round but ships a BAKED dark
--     outline, and SetVertexColor MULTIPLIES, so black stays black — the border cannot
--     be tinted away and reads as a hard edge against the glow.
-- Shared by the cue dot and the backing disc; the mask must track the fill's rect on
-- every resize or it clips the wrong region, which is what sizeDisc is for.
local function maskedDisc(parent, layer)
  local t = parent:CreateTexture(nil, layer)
  local mask = parent:CreateMaskTexture()
  mask:SetTexture(DOT_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  t:AddMaskTexture(mask)
  t.mask = mask
  return t
end

local function sizeDisc(t, size, rel)
  t:SetSize(size, size)
  t.mask:ClearAllPoints()
  t.mask:SetSize(size, size)
  t.mask:SetPoint("CENTER", t, "CENTER", 0, 0)
  t:ClearAllPoints()
  t:SetPoint("CENTER", rel, "CENTER", 0, 0)
end

-- Park one ring: hidden, stopped, and its play-flag cleared so a re-shown cue re-plays.
local function parkRing(t)
  if not t then return end
  t:Hide()
  t.spin:Stop()
  t._spinOn = nil
end

-- THE ONE PLACE A CUE'S ART LEAVES THE SCREEN.  Two callers and they must not drift:
-- drawCues' region cull (a cue that dropped out with no pop to wait for) and
-- R:onPopFinished (one that had).  ⚠ It deliberately does NOT clear `glowing` — that
-- tracks the COMMANDED state and cleared the moment the cue left the DrawList, which is
-- typically ~0.18s before these pixels do.
function R:hideCueArt(key)
  local dot = self.cueFrames[key]
  if dot then dot:Hide() end
  local disc = self.cueDiscs[key]
  if disc then disc:Hide() end
  parkRing(self.cueRingOut[key])
  parkRing(self.cueRingIn[key])
end

function R:drawCues(cues)
  local active = {}
  for _, c in ipairs(cues or {}) do
    local key = c.anchorTo
    local anchor = key ~= nil and self.registry[key] or nil
    -- Without a resolved icon frame there is nothing to parent a holder to, so nothing
    -- to decorate — skip and let the cull hide any prior decoration for this handle.
    if key ~= nil and anchor then
      active[key] = true
      local holder = self:ensureHolder(key, anchor)
      -- GLOW_SPEC drives the ring, and `gs.color` (LATE only) redirects the colour.
      -- No entry (IDLE / unknown token) ⇒ no circle, no ring.
      local gs       = GLOW_SPEC[c.emphasis]                 -- nil ⇒ no ring
      local colorKey = (gs and gs.color) or c.emphasis
      local col      = self.theme[colorKey]
      local sz = c.size or 12
      if col then
        -- The dot / ring / echo / disc all ride the CUE LAYER, which carries the cue's
        -- geometry; the dot is simply CENTERed on it (see ensureLayer's header).
        local layer = self:ensureLayer(key, holder, c, sz)
        local dot = self.cueFrames[key]
        if not dot then
          dot = maskedDisc(layer, "OVERLAY")
          self.cueFrames[key] = dot
        end
        dot:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
        sizeDisc(dot, sz, layer)
        -- EVERY cue shows the solid circle now; the glow ring (when the emphasis has a
        -- GLOW_SPEC entry) rides a layer BELOW it, so the crisp dot + keybind stay on top.
        dot:SetAlpha(1)
        dot:Show()
        self:setCueRings(key, layer, dot, gs and col or nil, sz, gs)
        -- ARRIVAL: the cue is drawn and shown, so the pop just plays.  Only for a handle
        -- that was NOT on the board last draw — a steady redraw at 10 Hz must not punch,
        -- and `cuedLast` is still the PREVIOUS draw's set here (drawCueEdges rolls it over
        -- after both channel passes).
        if not self.cuedLast[key] then self:popCue(key, false) end
      else
        -- DEFENSIVE: an emphasis token the theme has no entry for draws NOTHING — we never
        -- guess a colour.  Hide any dot/glow this handle had.  (Before Phase 3 this branch
        -- also had to keep the handle alive for a keybind-only cue; that job is gone, but
        -- the "unknown token ⇒ no dot" rule is a contract of its own and stays.)
        if self.cueFrames[key] then self.cueFrames[key]:Hide() end
        self:setCueRings(key, self.cueLayers[key], self.cueFrames[key], nil, sz, nil)
      end
    end
  end
  -- DEPARTURE: a handle that was cued LAST draw and is not cued now.  The pop-out starts
  -- here and its art has to survive the cull below to be seen at all.
  for key in pairs(self.cuedLast) do
    if not active[key] then self:popCue(key, true) end
  end
  -- Dots + both rings + discs cull on the CUE-active set; holders do not (see R:Draw).
  -- One loop over `cueFrames` covers all four pools: they are keyed together by
  -- construction — the dot is created first, and the rings + disc only ever in the same
  -- branch, so a handle with a ring but no dot cannot exist.
  for key in pairs(self.cueFrames) do
    if not active[key] then
      self.glowing[key] = nil                                    -- the COMMANDED state...
      if not self.leaving[key] then self:hideCueArt(key) end     -- ...the pixels can wait
    end
  end
  return active
end

--------------------------------------------------------------------------------
-- Keybind hints — the DrawList's second per-icon channel (Phase 3).
--------------------------------------------------------------------------------
-- A small outlined string pinned inside the icon's upper-left, diagonally opposite the
-- cue dot.  IDENTITY CHROME: it says which icon is which button and carries no rotation
-- meaning, so it is drawn from its own channel with no reference to `cues` at all — an
-- icon can have a key and no dot, a dot and no key, or both, and none of those is a
-- special case any more.  Position comes off the ENTRY (G.KEY, stamped by the Binder),
-- not from literals here, so the `/cdmp rt` fixtures and the live producer agree.
--
-- Reuses `cueHolders` (so both channels ride the same per-icon strata/level fix) and the
-- same pooled `cueKeys` fontstrings, diff-by-key on `anchorTo`.  RETURNS its active set;
-- the holder cull is the union of both channels and lives in R:Draw.
function R:drawKeybinds(list)
  local active = {}
  for _, k in ipairs(list or {}) do
    local key = k.anchorTo
    local anchor = key ~= nil and self.registry[key] or nil
    local text = k.keybind
    if key ~= nil and anchor and type(text) == "string" and text ~= "" then
      active[key] = true
      local holder = self:ensureHolder(key, anchor)
      local fs = self.cueKeys[key]
      if not fs then
        fs = holder:CreateFontString(nil, "OVERLAY")
        ns.SetFont(fs, 14, "OUTLINE")
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(KEY_COL[1], KEY_COL[2], KEY_COL[3], 1)
        self.cueKeys[key] = fs
      end
      fs:SetText(text)
      fs:ClearAllPoints()
      fs:SetPoint(k.point or "TOPLEFT", anchor, k.relPoint or k.point or "TOPLEFT",
                  k.dx or 0, k.dy or 0)
      fs:Show()
    end
  end
  for key, fs in pairs(self.cueKeys) do
    if not active[key] then fs:Hide() end
  end
  return active
end

--------------------------------------------------------------------------------
-- The cue rings — TWO counter-rotating sprites centred on the solid dot.
--------------------------------------------------------------------------------
-- Additive star sprites, tinted to the cue's emphasis hue via SetVertexColor and CENTRED
-- on the solid dot, sized relative to it.  The CONTINUOUS ROTATION is the eye-draw
-- (2026-07-28 feedback: "the movement really helps draw the eye"); a symmetric soft circle
-- cannot show spin, so this sprite's angular detail is what makes the motion read.  They
-- sit a layer BELOW the dot (ARTWORK vs the dot's OVERLAY) so the crisp dot + keybind stay
-- on top, and pool per handle.
--
-- ⚠ THESE NUMBERS ARE NOT A DIAL-IN, THEY ARE AN EXPERIMENTAL RESULT — the whole point is
-- that they were arrived at by someone who could not see this file.  The v1 treatment's
-- spin read as "slows like a rubber band, then races, forever", and six builds of
-- theorising about our own scaffolding produced three wrong answers in a row.  So three
-- subagents, blind to this repository, each implemented "two concentric counter-rotating
-- green rings" from one pinned brief (same sprite, same colour, 40px inner / 60px outer,
-- opposite directions) with periods, blend mode, layers and easing left free.  Two of the
-- three converged on almost exactly what is below, and BOTH RAN STEADY — which cleared the
-- concept, the art and the WoW animation API, and put the fault in v1.
--
-- Round 2 then walked that steady ring toward v1's, one difference per panel, recording
-- every rotation's phase against a uniform spin.  NOTHING surged, including v1's own
-- numbers.  What it showed instead is that v1's pair reads as ONE ring: the echo was
-- LOCKED IN PHASE with the base — same direction, same period, same 8-fold sprite — so the
-- two sat exactly on top of each other.  That was v1's deliberate fix for a moiré (see
-- archive/cue-treatment-v1.lua), and it worked, at the cost of the second ring being
-- invisible.  This pair counter-rotates at DIFFERENT periods so you can see both.
--
-- ⚠ WHY THE MOIRÉ THAT DROVE v1's LOCK IS NOT BACK.  Two n-fold patterns in relative
-- rotation beat at n x their RELATIVE angular velocity; star_07 is 8-fold, and 6s against
-- 9s counter-rotating gives |1/6 + 1/9| x 8 = 2.2 Hz — above flicker fusion, so it reads as
-- texture.  v1's 12.0s-against-30.0s pair sat at 0.93 Hz, squarely in the band the eye
-- TRACKS, and a tracked moiré stalls at each alignment and races between them.  The lock
-- was the right fix for the wrong periods.  ⚠ ANY retune must be checked against the ART's
-- symmetry order, not by eye at one speed: keep the beat well above ~1.5 Hz.
--
-- ⚠ ART, SIZE AND PERIOD ARE ONE DIAL WITH THREE PARTS.  The rate the eye reads is angular
-- velocity x the sprite's rotational symmetry order — how often a spoke passes a fixed
-- point — and star_07 measures 8-fold (dominant k=8, harmonics at k=4/k=16).  Swap the
-- sprite and RING_SCALE and both periods are invalidated together; a spokier sprite needs
-- longer periods in proportion.
local GLOW_ART = "Interface\\AddOns\\CDMProbe\\Media\\fx\\glow\\star_07.tga"

-- ⚠ THE RING HAS A HOLE, AND IT CANNOT BE FILLED.  Its transparent centre is baked into
-- the art, and no tint or blend mode paints it in (SetVertexColor MULTIPLIES — it cannot
-- add alpha where there is none).  The angular detail is also the only reason the spin
-- READS at all; a symmetric soft blob would rotate invisibly.  So the hole is not a bug to
-- remove, it is the cost of the motion channel — the lever is to make the DOT COVER IT by
-- sizing the ring so its inner edge sits on the dot's rim.
local RING_SCALE  = 3.34   -- INNER ring diameter, relative to the dot (12 -> 40px)
local OUTER_SCALE = 1.5    -- OUTER ring diameter, relative to the inner (40 -> 60px)

-- Opposite directions, and deliberately NON-HARMONIC periods so the pair never settles
-- into a fixed relative pose.  Negative = clockwise.
local INNER_SECS,    OUTER_SECS    = 6.0,  9.0
local INNER_DEGREES, OUTER_DEGREES = -360, 360

-- ⚠ NOT A LIGHT SPLIT.  v1 forced ring + echo alpha to sum to 1.0 so that adding reach
-- could not add brightness — correct there, because the two were superimposed and their
-- additive light stacked on the same pixels.  These two are separated in space and in
-- phase, so they are two rings, not one ring drawn twice, and each carries its own weight.
local INNER_ALPHA, OUTER_ALPHA = 0.85, 0.55

-- THE BACKING DISC — contrast, not light.  The rings are additive over busy icon art, so
-- they wash out against it; punching a dark hole behind them gives the added light
-- something to read against.  Sized off the OUTERMOST drawn extent, so it can never end up
-- smaller than the light it is backing.  ~21px behind a 12px dot at the shipped numbers.
local DISC_ALPHA = 0.75
local DISC_SCALE = 0.35   -- diameter relative to the OUTER ring's diameter

-- Drive one looping group to match its flag, tracked on the owner so a steady redraw at
-- 10 Hz doesn't restart it.  Flag false ⇒ the region is shown but never animates.
local function drive(owner, group, want, flag)
  if want and not owner[flag] then group:Play(); owner[flag] = true
  elseif not want and owner[flag] then group:Stop(); owner[flag] = false end
end

local function ensureRing(layer, sublevel, degrees, secs)
  local t = layer:CreateTexture(nil, "ARTWORK", nil, sublevel)
  t:SetTexture(GLOW_ART)
  t:SetBlendMode("ADD")
  local g = t:CreateAnimationGroup()
  local rot = g:CreateAnimation("Rotation")
  rot:SetDegrees(degrees)
  rot:SetDuration(secs)
  rot:SetOrigin("CENTER", 0, 0)
  rot:SetOrder(1)
  g:SetLooping("REPEAT")
  t.spin, t.rot, t._secs = g, rot, secs
  return t
end

function R:setCueRings(key, layer, dot, col, size, gs)
  local inner, outer = self.cueRingIn[key], self.cueRingOut[key]
  if not col then                              -- no rings this frame: hide + park
    parkRing(inner)
    parkRing(outer)
    local d = self.cueDiscs[key]
    if d then d:Hide() end
    self.glowing[key] = nil
    return
  end
  if not inner then
    inner = ensureRing(layer, 0, INNER_DEGREES, INNER_SECS)
    self.cueRingIn[key] = inner
  end
  if not outer then
    -- One sub-layer under the inner ring, so the brighter, faster one reads on top.
    outer = ensureRing(layer, -1, OUTER_DEGREES, OUTER_SECS)
    self.cueRingOut[key] = outer
  end

  local d     = size or 12
  local ring  = d * ((gs and gs.ringScale) or RING_SCALE)
  local out   = ring * OUTER_SCALE
  local mult  = (gs and gs.spinMult) or 1

  -- ⚠ GEOMETRY IS STATED ONCE, NOT PER DRAW.  v1 re-asserted size, anchor and colour on
  -- every pipeline tick (~10 Hz) on textures whose Rotation was already playing.  Round 2
  -- built a panel specifically to test whether that restate disturbs a running animation
  -- and MEASURED that it does not — so this guard is not a bug fix, it is just not doing
  -- work that provably buys nothing.  The cue geometry is constant in practice.
  if inner._ring ~= ring then
    inner._ring = ring
    inner:SetSize(ring, ring)
    inner:ClearAllPoints()
    inner:SetPoint("CENTER", dot, "CENTER", 0, 0)
  end
  if outer._ring ~= out then
    outer._ring = out
    outer:SetSize(out, out)
    outer:ClearAllPoints()
    outer:SetPoint("CENTER", dot, "CENTER", 0, 0)
  end
  inner:SetVertexColor(col[1], col[2], col[3], INNER_ALPHA)
  outer:SetVertexColor(col[1], col[2], col[3], OUTER_ALPHA)

  -- Re-time only when the RATE CHANGES: SetDuration on a playing group restarts it, which
  -- would hitch the ring on every redraw at 10 Hz.
  for t, base in pairs({ [inner] = INNER_SECS, [outer] = OUTER_SECS }) do
    local secs = base / mult
    if t._secs ~= secs then
      t._secs = secs
      t.rot:SetDuration(secs)
    end
  end

  inner:Show()
  outer:Show()
  drive(inner, inner.spin, gs and gs.spin, "_spinOn")
  drive(outer, outer.spin, gs and gs.spin, "_spinOn")

  -- THE BACKING DISC — BACKGROUND, under everything, sized off the outer ring's extent.
  local disc = self.cueDiscs[key]
  if not disc then
    disc = maskedDisc(layer, "BACKGROUND")
    self.cueDiscs[key] = disc
  end
  disc:SetColorTexture(0, 0, 0, DISC_ALPHA)
  sizeDisc(disc, out * DISC_SCALE, dot)
  disc:Show()

  self.glowing[key] = true
end

--------------------------------------------------------------------------------
-- THE TWO EDGES — a cue arriving / leaving.  Measured, not assumed.
--------------------------------------------------------------------------------
-- Off 504s of real play (raw/cdmp-decision.log, 5 sessions), diffing the DrawList block
-- per tick: the cue set changes 120 times — one every ~4s, median gap 1.5-2.2s (a GCD).
-- 60 % of those are a SWAP (one handle out, another in, same tick); 23 are a pure add,
-- 25 a pure remove; the board never once went empty.  Two DIFFERENT edges fall out:
--
--   * THE POP is PER HANDLE and purely visual.  Simultaneous ones are fine — they are on
--     different icons, and a swap is exactly that: one popping out while another pops in.
--   * `onCueSetChanged` is PER SET CHANGE.  A swap is ONE event, not a remove plus an
--     add: firing per handle would double every swap (overlapping sounds), and it would
--     be wrong besides — a cue that MOVED was not removed.  So: one call, `"new"` if
--     anything was added, else `"gone"`.  That is exactly 120 calls in those 504s.
--
-- ⚠ `"gone"` IS RARE BY CONSTRUCTION and that is correct.  The board never emptied in
-- 504s of pulls, so a pure-remove edge is mostly an end-of-pull event.  Do not "fix" it
-- by firing it on swaps.
-- ⚠ v1's GHOST — a scale-and-fade of the departing ring, on its own texture — is archived
-- and did NOT come back.  The v2 departure is the same pop played on the way out, so there
-- is one animation and one set of ordering rules rather than two of each.
--
-- The SET-level callback below is unchanged by any of that: it was never visual.

-- Diff this draw's cue-active set against the last one and fire the SET-level callback at
-- most once.  Called from R:Draw between the two channel passes and the holder cull.
function R:drawCueEdges(active)
  local last = self.cuedLast
  local added, removed = false, false
  for key in pairs(active) do
    if not last[key] then added = true end
  end
  for key in pairs(last) do
    if not active[key] then removed = true end
  end
  self.cuedLast = active
  if (added or removed) and self.onCueSetChanged then
    self.onCueSetChanged(added and "new" or "gone")
  end
end

--------------------------------------------------------------------------------
-- Sequence panel (3c)
--------------------------------------------------------------------------------
local ROW_H, ROW_GAP, TITLE_H, PANEL_PAD, PANEL_W = 16, 2, 18, 8, 220

function R:ensurePanel()
  if self.panelWidget then return self.panelWidget end
  local f = CreateFrame("Frame", nil, self:ensureRoot())
  f:SetWidth(PANEL_W)
  f:SetFrameStrata("HIGH")
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", f, "TOP", 0, -PANEL_PAD)
  title:SetJustifyH("CENTER")
  self.panelWidget = { frame = f, title = title, rows = {} }
  return self.panelWidget
end

-- A bare list: title + one FontString per step, "<state>  <keybind>  <label>",
-- tinted by state.  Shown only when the DrawList carries a panel; rows are pooled
-- and the surplus hidden, so the widget never churns.
function R:drawPanel(panel)
  if not panel then
    if self.panelWidget then self.panelWidget.frame:Hide() end
    return
  end
  local p = self:ensurePanel()
  local anchor = self.registry[panel.anchorTo] or self.registry.UIPARENT
  p.frame:ClearAllPoints()
  p.frame:SetPoint(panel.point or "TOP", anchor, panel.point or "TOP",
                   panel.dx or 0, panel.dy or 0)
  p.title:SetText(panel.title or "")

  local steps = panel.steps or {}
  for i, step in ipairs(steps) do
    local row = p.rows[i]
    if not row then
      row = p.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row:SetJustifyH("LEFT")
      row:SetPoint("TOPLEFT", p.frame, "TOPLEFT",
                   PANEL_PAD, -(TITLE_H + PANEL_PAD + (i - 1) * (ROW_H + ROW_GAP)))
      p.rows[i] = row
    end
    row:SetText(string.format("%s  %s  %s",
      step.state or "", step.keybind or "", step.label or ""))
    local tint = STATE_TINT[step.state] or STATE_TINT.pending
    row:SetTextColor(tint[1], tint[2], tint[3], tint[4] or 1)
    row:Show()
  end
  for i = #steps + 1, #p.rows do p.rows[i]:Hide() end

  p.frame:SetHeight(TITLE_H + PANEL_PAD * 2 + #steps * (ROW_H + ROW_GAP))
  p.frame:Show()
end

--------------------------------------------------------------------------------
-- Resource bar (3d, optional/minimal)
--------------------------------------------------------------------------------
-- Pip size + gap come from the SHARED geometry table so the layout here and the
-- fixture's centring dx (G.resourceBar) can't drift (W4 Phase 4).
local PIP_SIZE, PIP_GAP = ns.HudGeometry.BAR.pip, ns.HudGeometry.BAR.gap

-- One bar's pip row (barIndex-keyed pool, so bar 2's pips don't stomp bar 1's): `max`
-- pips, the first `value` filled with the powerType colour, the rest a faint empty ring.
-- ONLY the discrete path is implemented; a `continuous` bar draws nothing (no live
-- consumer) — continuous fill: Phase-when-needed.
function R:drawResourceRow(barIndex, bar)
  local row = self.pipRows[barIndex]
  if not row then row = {}; self.pipRows[barIndex] = row end
  if bar.display == "continuous" then
    -- continuous fill: Phase-when-needed — the contract carries the enum, no pixel path yet.
    for _, pip in ipairs(row) do pip:Hide() end
    return
  end
  local col = self.powerColor[bar.powerType] or self.powerColor.SOUL_SHARDS
  local anchor = self.registry[bar.anchorTo] or self.registry.UIPARENT
  local max, value = bar.max or 0, bar.value or 0
  for i = 1, max do
    local pip = row[i]
    if not pip then
      pip = self:ensureRoot():CreateTexture(nil, "OVERLAY")
      pip:SetTexture(WHITE8)
      row[i] = pip
    end
    pip:SetSize(PIP_SIZE, PIP_SIZE)
    pip:ClearAllPoints()
    pip:SetPoint(bar.point or "CENTER", anchor, bar.point or "CENTER",
                 (bar.dx or 0) + (i - 1) * (PIP_SIZE + PIP_GAP), bar.dy or 0)
    if i <= value then
      pip:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    else
      pip:SetColorTexture(EMPTY_PIP[1], EMPTY_PIP[2], EMPTY_PIP[3], EMPTY_PIP[4])
    end
    pip:Show()
  end
  for i = max + 1, #row do row[i]:Hide() end
end

-- Draw N stacked meters (multi-spec Phase 3).  Each bar owns its own pip-row pool; rows
-- beyond the current bar count are hidden (a spec that shed a bar, or the no-bars case).
function R:drawResources(bars)
  bars = bars or {}
  for i, bar in ipairs(bars) do self:drawResourceRow(i, bar) end
  for i = #bars + 1, #self.pipRows do
    for _, pip in ipairs(self.pipRows[i]) do pip:Hide() end
  end
end

--------------------------------------------------------------------------------
-- The one entry point
--------------------------------------------------------------------------------
-- ⚠ THE HOLDER CULL IS A UNION, AND IT HAS TO BE.  `cueHolders` is shared by the cue and
-- keybind channels (one holder per icon, carrying both decorations), so culling it inside
-- either pass would hide the other channel's decoration every frame: an uncued icon's key
-- hint would be parented to a hidden holder, and a keyless cued icon's dot likewise.  Each
-- pass therefore returns its own active set and the holder cull happens HERE, over both.
-- Dots/rings still cull on cue-active and key fontstrings on keybind-active — those pools
-- are single-channel.  renderer_spec pins both directions of the independence.
--
-- ⚠ IT HAS A THIRD TERM, `leaving`, AND THAT TERM IS NOT OPTIONAL.  A departing handle
-- leaves BOTH active sets in the very draw that starts its pop-out, so a two-term union
-- would hide the holder in that same draw and the pop would play invisibly under it.  The
-- term went away with v1's ghost and came straight back with the v2 pop-out — the coupling
-- is a property of having any departure animation at all, not of a particular one.
function R:Draw(drawList)
  drawList = drawList or {}
  local cued = self:drawCues(drawList.cues)
  local keyed = self:drawKeybinds(drawList.keybinds)
  self:drawCueEdges(cued)
  for key, h in pairs(self.cueHolders) do
    if not (cued[key] or keyed[key] or self.leaving[key]) then h:Hide() end
  end
  self:drawPanel(drawList.panel)
  self:drawResources(drawList.resourceBars)
  return self
end
