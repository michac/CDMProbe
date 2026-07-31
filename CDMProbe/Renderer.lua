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
-- V1 IS BARE-BONES (this session's call):
--   * cue = a solid DOT, coloured by its `emphasis` token.  No bar, no fill
--     fraction, no pulse.
--   * panel = a plain titled list of step rows (state · keybind · label), shown
--     only when the DrawList carries one.
--   * resourceBars = an array of minimal discrete-pip rows, stacked (optional).
--   * NO transient/animation (the phase-edge flash is a later Phase-3 increment)
--     and NO CRT chrome (bracket / glow ring / DEMO.SYS / scanlines stay retired).
--
-- TOKEN -> PIXELS IS THE RENDERER'S JOB (guidance-contract.json).  DrawList v1
-- carries the emphasis TOKEN, not resolved RGBA, so colour stays OUT of the Binder
-- (Phase 4 is a pure GEOMETRY merge).  The Renderer resolves token -> colour via a
-- built-in theme, injectable through cfg.  This deliberately supersedes
-- architecture.md's older DrawList sketch (which showed a pre-resolved
-- `color:[r,g,b,a]`); that doc says the Stage-3/4 shape "is revised when the
-- Binder is actually built".
--
-- PURE-ISH FACTORY, like Coach/HudBoard: Renderer.New(cfg) / __index, theme
-- injectable, no global render state.  The pool + registry live on the instance.
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
--   * an entry ⇒ this emphasis draws a spinning glow RING (+ a solid circle dot).
--   * `spin`/`pulse` ⇒ whether the ring rotates / breathes.  Both false ⇒ a STATIC ring.
--   * `color` redirects the colour lookup for BOTH circle and ring (LATE -> ROTATION
--     green).  It OVERRIDES the theme entry for that token — see the theme note above.
--   * no entry (IDLE / unknown) ⇒ no circle, no ring (keybind-only if it carries one).
--   * `ringScale` / `spinSecs` => per-emphasis ring SIZE and rotation period (both default
--     to GLOW_SCALE / SPIN_SECS).  These express DEGREE without spending a hue.
local GLOW_SPEC = {
  ROTATION          = { spin = true,  pulse = true },
  -- LATE is not a different KIND of press -- it is the SAME press, overdue.  So it is the
  -- rotation cue ESCALATED (a bigger ring spinning ~2.5x faster), not a second colour.
  -- WARNING: this deliberately reverses part of the 2026-07-26 dial-in, which pulled LATE
  -- onto hot amber because green SHADES were indistinguishable.  That finding stands -- this
  -- is not a second shade of green, it is the SAME green moving differently.  In play the
  -- amber read as a distinct INSTRUCTION rather than an urgent one, and it collided with
  -- SOON's yellow.  Do not "restore" the amber without re-testing the motion channel first.
  LATE              = { spin = true,  pulse = true, color = "ROTATION",
                        ringScale = 5.0, spinSecs = 1.6 },
  SOON              = { spin = true,  pulse = true },
  -- No `color` override: the runner-up now resolves its OWN theme entry (violet) instead
  -- of borrowing ROTATION's green.  Still static -- motion remains the primary tell.
  ROTATION_FALLBACK = { spin = false, pulse = false },
}

-- powerType -> RGBA.  SOUL_SHARDS is the soul-violet HudChrome's rail paints a
-- GENERATE edge with (HudChrome.lua:1051) — the shard colour by construction.
local function defaultPowerColor()
  return {
    SOUL_SHARDS = { 0.690, 0.420, 1.000, 1.00 },
  }
end

-- Empty-pip ring for the resource bar (a state, not a guess) — HudChrome RAIL_RING.
local EMPTY_PIP = { 0.30, 0.29, 0.36, 0.60 }

-- Keybind-hint text colour — near-white green, reads on any icon (copied from
-- HudChrome KEY_COL, HudChrome.lua:45; keep in lock-step until the cutover).
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
  self.cueFrames  = {}          -- anchorTo -> dot texture (diff-by-key pool)
  self.cueKeys    = {}          -- anchorTo -> keybind-hint fontstring (diff-by-key)
  self.cueGlows   = {}          -- anchorTo -> the dot's glow-halo texture
  self.glowing    = {}          -- anchorTo -> true while its dot is glowing.  Written
                                -- here, read only by renderer_spec: the one observable
                                -- proof the glow path ran.  Keep it — it is an
                                -- assertion surface, not dead state.
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
-- Cue dots (3b)
--------------------------------------------------------------------------------
-- A cue is a solid coloured CIRCLE (a masked fill, see the dot creation) + a
-- spinning glow RING, coloured by its emphasis token and anchored to its handle's
-- frame — a corner treatment INSIDE the icon (the DrawList geometry puts it
-- upper-right; see the fixtures).  Diff-by-key on `anchorTo`: only handles in THIS
-- DrawList are (re)painted; a handle that dropped out is hidden, never destroyed.
--
-- THE DOT AND THE KEY HINT ARE DECOUPLED (P5d).  A cue carries an optional emphasis
-- token AND an optional `keybind` string, and they draw INDEPENDENTLY:
--   * emphasis with a GLOW_SPEC entry -> a coloured circle + its glow ring (motion per
--     the spec); an absent or unknown token draws NO circle (never guess a colour),
--     hiding any prior one.
--   * a `keybind` string -> a hint in the icon's UPPER-LEFT corner, drawn WHENEVER
--     present regardless of emphasis (identity chrome — which button is which).
-- So an EMPTY CUE (keybind, no emphasis) is a key hint with no dot — that is how the
-- Binder puts a keybind on every displayed icon, cued or not.  The handle stays
-- ACTIVE while it carries either, so its key hint isn't culled with the dropouts.
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
        local dot = self.cueFrames[key]
        if not dot then
          dot = holder:CreateTexture(nil, "OVERLAY")
          -- A CLEAN disc: a solid fill clipped by a real MaskTexture OBJECT.
          --
          -- Two cuts got here.  (1) WHITE8X8 + `SetMask(path)` drew a SQUARE — so that
          -- combination demonstrably does not clip, which settles the interaction
          -- addon-dev/frames-textures-animation.md §5.7 flags as uncited: `SetMask(path)`
          -- does NOT survive/apply alongside `SetColorTexture`.  (2) The raid-blip atlas
          -- WhiteCircle-RaidBlips is genuinely round, but ships a baked dark outline (blips
          -- need to read against a map), and that border cannot be tinted away —
          -- SetVertexColor MULTIPLIES, so black stays black — leaving a hard edge against
          -- the glow instead of blending into it.
          --
          -- This is the idiom RingedFrameTemplate actually uses (:103-117): a MaskTexture
          -- created on the parent and attached with AddMaskTexture, not the SetMask
          -- shortcut.  Borderless by construction, since the shape comes from the mask's
          -- alpha and the colour from our own fill.
          local mask = holder:CreateMaskTexture()
          mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
                          "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
          dot:AddMaskTexture(mask)
          dot.mask = mask
          self.cueFrames[key] = dot
        end
        dot:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
        dot:SetSize(sz, sz)
        -- The mask must track the fill's rect or it clips the wrong region.
        dot.mask:ClearAllPoints()
        dot.mask:SetSize(sz, sz)
        dot.mask:SetPoint("CENTER", dot, "CENTER", 0, 0)
        dot:ClearAllPoints()
        dot:SetPoint(c.point or "CENTER", anchor,
                     c.relPoint or c.point or "CENTER", c.dx or 0, c.dy or 0)
        -- EVERY cue shows the solid circle now; the glow ring (when the emphasis has a
        -- GLOW_SPEC entry) rides a layer BELOW it, so the crisp dot + keybind stay on top.
        dot:SetAlpha(1)
        dot:Show()
        self:setDotGlow(key, holder, dot, gs and col or nil, sz,
                        gs and gs.spin, gs and gs.pulse,
                        gs and gs.ringScale, gs and gs.spinSecs)
      else
        -- EMPTY CUE (keybind-only): no emphasis the theme knows -> no dot, no glow.
        -- Hide any dot/glow this handle had, but keep the handle ACTIVE so its keybind
        -- hint (below) survives the end-of-frame cull.
        if self.cueFrames[key] then self.cueFrames[key]:Hide() end
        self:setDotGlow(key, holder, self.cueFrames[key], nil, sz)
      end
      -- The keybind hint draws regardless of emphasis — identity chrome on every button.
      self:drawCueKey(key, holder, anchor, c.keybind)
    end
  end
  for key, h in pairs(self.cueHolders) do
    if not active[key] then h:Hide() end
  end
  for key, dot in pairs(self.cueFrames) do
    if not active[key] then dot:Hide() end
  end
  for key, fs in pairs(self.cueKeys) do
    if not active[key] then fs:Hide() end
  end
  for key, g in pairs(self.cueGlows) do
    if not active[key] then
      g:Hide()
      if g.spin then g.spin:Stop() end
      if g.pulse then g.pulse:Stop() end
      g._spinOn, g._pulseOn = nil, nil   -- so a re-shown glow re-plays each group
      self.glowing[key] = nil
    end
  end
end

-- The keybind hint: a small outlined string pinned to the icon's upper-left.
-- Drawn only when the cue carries a non-empty `keybind` AND its handle resolves to
-- a frame; otherwise any prior hint for that handle is hidden.
function R:drawCueKey(key, holder, anchor, keybind)
  local fs = self.cueKeys[key]
  if not (keybind and keybind ~= "" and anchor) then
    if fs then fs:Hide() end
    return
  end
  if not fs then
    fs = holder:CreateFontString(nil, "OVERLAY")
    ns.SetFont(fs, 14, "OUTLINE")
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(KEY_COL[1], KEY_COL[2], KEY_COL[3], 1)
    self.cueKeys[key] = fs
  end
  fs:SetText(keybind)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", anchor, "TOPLEFT", 2, -2)
  fs:Show()
end

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
-- animation and a STATIC ring (both flags false — the runner-up) simply never plays.
local GLOW_ATLAS = "services-ring-large-glowspin"   -- round ring glow, built to spin
local GLOW_SCALE = 3.6    -- relative to the DOT (the solid box it's centred on)
local SPIN_SECS  = 4.0    -- one full rotation

function R:setDotGlow(key, holder, dot, col, size, spin, pulse, ringScale, spinSecs)
  local g = self.cueGlows[key]
  if not col then                              -- no glow this frame: hide + park
    if g then
      g:Hide()
      if g.spin then g.spin:Stop() end
      if g.pulse then g.pulse:Stop() end
      g._spinOn, g._pulseOn = nil, nil         -- clear so a re-shown glow re-plays
    end
    self.glowing[key] = nil
    return
  end
  if not g then
    g = holder:CreateTexture(nil, "ARTWORK")
    g:SetAtlas(GLOW_ATLAS)
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
    a:SetFromAlpha(0.55)
    a:SetToAlpha(1.00)
    a:SetDuration(0.60)
    a:SetOrder(1)
    pulseGroup:SetLooping("BOUNCE")
    g.spin, g.pulse = spinGroup, pulseGroup
    self.cueGlows[key] = g
  end
  g:SetVertexColor(col[1], col[2], col[3], 1)
  g:ClearAllPoints()
  g:SetPoint("CENTER", dot, "CENTER", 0, 0)
  local d = size or 12
  local scale = ringScale or GLOW_SCALE
  g:SetSize(d * scale, d * scale)
  -- Re-time the rotation only when it CHANGES: SetDuration on a playing group restarts it,
  -- which would stutter the ring on every redraw at 10 Hz.
  local secs = spinSecs or SPIN_SECS
  if g._spinSecs ~= secs then
    g._spinSecs = secs
    g.rot:SetDuration(secs)
  end
  g:Show()
  -- Drive each group to match its flag, tracked per-glow so a steady redraw doesn't
  -- restart it.  Static FALLBACK (both false) ⇒ the ring is shown but never animates.
  local function drive(group, want, flag)
    if want and not g[flag] then group:Play(); g[flag] = true
    elseif not want and g[flag] then group:Stop(); g[flag] = false end
  end
  drive(g.spin,  spin,  "_spinOn")
  drive(g.pulse, pulse, "_pulseOn")
  self.glowing[key] = true
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
function R:Draw(drawList)
  drawList = drawList or {}
  self:drawCues(drawList.cues)
  self:drawPanel(drawList.panel)
  self:drawResources(drawList.resourceBars)
  return self
end

--------------------------------------------------------------------------------
-- In-game TEST MODE (Phase 3e) — the IMPURE driver, deliberately outside the pure
-- Draw path above.  It builds real placeholder icon frames, registers them under
-- fake handles, and renders a HAND-AUTHORED DrawList fixture through a Renderer.
-- No game decisions — just placeholder frames + fixtures + Renderer, the exact
-- shape Phase 4's Binder will one day produce.  Wired to `/cdmp rt`
-- (registered in Core.lua).  This is Phase 3's pixel confirmation: dial the visual
-- language in against representative golden states before the producer exists.
--------------------------------------------------------------------------------

-- Hand-authored DrawList fixtures, each mapped BY HAND from a representative
-- Guidance shape (originally the golden corpus, retired W4 Phase 8; these fixtures are
-- now self-contained here and mirrored inline by binder_spec).  The Guidance keys cues by
-- cooldownID; mapping those to fake icon handles fake1..fakeN is exactly the
-- Binder's Phase-4 job, done by hand here for the test.  `icons` = how many
-- placeholder squares the row needs.
-- The cue dot rides INSIDE the icon's upper-right corner; the keybind hint rides the
-- upper-left.  The geometry (dot corner/size, glow rule, panel + bar positions) lives
-- in the SHARED ns.HudGeometry table — the Binder stamps the exact same shapes in
-- Phase 4, so these fixtures and the live producer agree by construction, not copy.
local G = ns.HudGeometry
local cue = G.cue          -- cue(handle, emphasis, keybind) -> a positioned cue
local shards = G.resourceBar  -- shards(value, max) -> the centred discrete-pip bar

local FIXTURE_ORDER = { "states", "hand-of-guldan", "opener-midflight", "secrecy-combat" }
local FIXTURES = {
  -- STATES — the canonical reference card: one simulated CDM square per VISIBLE cue
  -- state the live pipeline can put on an icon, captioned, left→right roughly
  -- least→most salient, with the NATIVE proc glow last.  Not a scenario the Coach
  -- would emit as one frame — a palette:
  --   IDLE      keybind hint only, no dot (the "empty board" — tracked, nothing to do)
  --   SOON      anticipation — yellow circle + spinning/pulsing ring
  --   FALLBACK  ROTATION_FALLBACK — the runner-up: VIOLET circle + STATIC ring (backup
  --            reads by BOTH hue and lack of motion)
  --   ROTATION  press now — green circle + spinning/pulsing ring
  --   LATE      overdue — ROTATION green, ESCALATED ring (bigger, ~2.5x faster)
  --   GLOW      a FALLBACK dot + keybind UNDER Blizzard's NATIVE (gold) spell-
  --            activation overlay (applied post-Draw, below) — the exact conflict
  --            the "subdue the proc glow" backlog item is about: the native glow
  --            stomping OUR chrome.  Pairs with the plain FALLBACK square (fake3).
  --   GLOW·RED  the SAME native overlay, RECOLORED via SetVertexColor on its flipbook
  --            textures — proof the borrowed glow is tintable, i.e. the backlog item
  --            could RECOLOR (to a tamer hue) rather than fully replace it.
  --   GLOW·DIM  the native gold overlay DIMMED via frame alpha — proof it can be
  --            de-emphasized by turning it down, the other subdue lever.
  -- (Every cue now shows its solid circle AND a glow ring; ROTATION/LATE/SOON spin +
  -- pulse, FALLBACK's ring is static.)  Squares carry real spell-icon ART (buildRig), so the
  -- chrome is judged against a busy icon like the live CDM, not a flat fill.
  ["states"] = { icons = 8,
    captions = { "IDLE", "SOON", "FALLBACK", "ROTATION", "LATE", "GLOW", "GLOW·RED", "GLOW·DIM" },
    -- Each proc-glow entry is { index, color?, alpha? }: no color = native gold; a
    -- color = SetVertexColor tint (multiplicative); alpha = dim via the alert frame.
    procGlow = {
      { index = 6 },
      { index = 7, color = { 1.00, 0.25, 0.20 } },
      { index = 8, alpha = 0.35 },
    },
    drawList = {
      cues = {
        cue("fake1", nil, "Q"),                  -- IDLE: keybind only, no dot
        cue("fake2", "SOON", "E"),               -- anticipation: yellow circle + spinning ring
        cue("fake3", "ROTATION_FALLBACK", "R"),  -- runner-up: green circle + STATIC ring
        cue("fake4", "ROTATION", "R"),           -- press now: green circle + spinning ring
        cue("fake5", "LATE", "E"),               -- overdue: amber circle + spinning ring
        cue("fake6", "ROTATION_FALLBACK", "F"),  -- FALLBACK dot + keybind, NATIVE glow on top
        cue("fake7", "ROTATION_FALLBACK", "F"),  -- same, but the glow is RECOLORED (red)
        cue("fake8", "ROTATION_FALLBACK", "F"),  -- same, but the glow is DIMMED (alpha)
      },
    } },
  -- One ROTATION press: HoG is the single call (3 shards, no proc, summons cooling).
  ["hand-of-guldan"] = { icons = 1, drawList = {
    cues = { cue("fake1", "ROTATION", "R") },
    resourceBars = { shards(3, 5) },
  } },
  -- ROTATION + SOON, no panel (TCT redesign — the opener panel is retired): mid-opener
  -- the burst walk still owes a shard, so Shadow Bolt caps (ROTATION) while Tyrant rides
  -- the SOON anchor.  The one-press cue walk replaced the sequence panel.
  ["opener-midflight"] = { icons = 2, drawList = {
    cues = { cue("fake1", "ROTATION", "Q"), cue("fake2", "SOON", "sQ") },
    resourceBars = { shards(3, 5) },
  } },
  -- ROTATION + SOON with every cd unreadable: Demonbolt presses (Core up via a
  -- readable buff+glow); Tyrant draws SOON off the napkin estimate (anticipation).
  -- fake1 = Demonbolt (its key is "F" in the golden state — matched here so the
  -- fixture equals what the Binder emits from that golden).
  ["secrecy-combat"] = { icons = 2, drawList = {
    cues = { cue("fake1", "ROTATION", "F"), cue("fake2", "SOON", "sQ") },
    resourceBars = { shards(2, 5) },
  } },
}

ns.RenderTestFixtures = FIXTURES   -- exported so a spec / tool can read them

-- Real spell-icon art for the placeholder squares, so the chrome (dots / glow /
-- keybind) is judged against a BUSY icon like the live CDM rather than a flat fill —
-- a dark uniform block reads the chrome too kindly.  Long-standing Warlock spellIDs
-- (texture resolves regardless of known/spec); `C_Spell.GetSpellTexture` falls back
-- to nil for any dud, and buildRig falls back to the old dark fill then.  Cycled by
-- icon index, so any icon count gets varied art.
local DEMO_ICON_SPELLS = { 105174, 686, 30146, 1122, 5740, 172 }
local ICON_DARK = { 0.12, 0.13, 0.16, 1 }  -- fallback fill when a texture won't resolve

-- Build (or reuse) the placeholder icon row + a persistent test Renderer.  Icons
-- carry real spell art (above) so the DOT/glow/keybind read as they would over a
-- live CDM icon.  An optional `captions` list labels each icon underneath.
local function buildRig(n, captions)
  local rig = ns._renderTestRig
  if not rig then
    local container = CreateFrame("Frame", "CDMProbeRenderTest", UIParent)
    container:SetSize(640, 220)
    container:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    container:SetFrameStrata("HIGH")
    rig = { container = container, icons = {}, renderer = R.New() }
    ns._renderTestRig = rig
  end
  local SIZE, GAP = 48, 22
  local total = n * SIZE + (n - 1) * GAP
  for i = 1, n do
    local icon = rig.icons[i]
    if not icon then
      icon = CreateFrame("Frame", nil, rig.container)
      icon:SetSize(SIZE, SIZE)
      local edge = icon:CreateTexture(nil, "BORDER")
      edge:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
      edge:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
      edge:SetColorTexture(0.40, 0.40, 0.46, 1)
      local fill = icon:CreateTexture(nil, "ARTWORK")
      fill:SetAllPoints(icon)
      local spellID = DEMO_ICON_SPELLS[((i - 1) % #DEMO_ICON_SPELLS) + 1]
      local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
      if tex then
        fill:SetTexture(tex)
        fill:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the stock icon border
      else
        fill:SetColorTexture(ICON_DARK[1], ICON_DARK[2], ICON_DARK[3], ICON_DARK[4])
      end
      icon._caption = icon:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      icon._caption:SetPoint("TOP", icon, "BOTTOM", 0, -4)
      rig.icons[i] = icon
    end
    icon:ClearAllPoints()
    icon:SetPoint("LEFT", rig.container, "CENTER", -total / 2 + (i - 1) * (SIZE + GAP), 0)
    icon:Show()
    if captions and captions[i] then
      icon._caption:SetText(captions[i]); icon._caption:Show()
    else
      icon._caption:Hide()
    end
    rig.renderer:Register("fake" .. i, icon)
  end
  for i = n + 1, #rig.icons do rig.icons[i]:Hide() end
  return rig
end

-- PROC GLOW (native) — Blizzard's OWN spell-activation overlay, applied to a
-- placeholder square exactly the way the Cooldown Manager applies it to a real proc'd
-- icon: `ActionButtonSpellAlertManager:ShowAlert(item)` (CooldownViewer.lua:1130).
-- Our placeholder has no `.action`/`.bar`, so the manager takes the plain Default
-- path (no AssistedCombat downgrade) and creates `icon.SpellActivationAlert` from
-- ActionButtonSpellAlertTemplate at 1.4x — the identical glow, on our dummy.  This is
-- the glow the "subdue the proc glow" backlog item is about; previewing it here needs
-- no live proc.  Impure by construction (a Blizzard global + a frame outside the
-- DrawList), so it lives here and NEVER in R:Draw.
-- RECOLOR the borrowed glow.  The alert is three atlas FLIPBOOK textures
-- (ProcStartFlipbook / ProcLoopFlipbook — gold by art — + the hidden ProcAltGlow),
-- so SetVertexColor MULTIPLIES the art toward a hue: it recolors without touching
-- the animation.  `color = nil` resets to native gold.  Multiplicative, so it tints
-- cleanly toward red/green/warm hues the gold art has energy in; pure blue goes dim.
-- This is the cheap end of the "subdue the proc glow" item — recolor, not replace.
local GLOW_REGIONS = { "ProcStartFlipbook", "ProcLoopFlipbook", "ProcAltGlow" }
local function tintAlert(icon, color)
  local alert = icon and icon.SpellActivationAlert
  if not alert then return end
  local r, g, b = 1, 1, 1
  if color then r, g, b = color[1], color[2], color[3] end
  for _, key in ipairs(GLOW_REGIONS) do
    if alert[key] then alert[key]:SetVertexColor(r, g, b) end
  end
end

local function clearProcGlow()
  local rig = ns._renderTestRig
  if not (rig and ActionButtonSpellAlertManager) then return end
  for _, icon in ipairs(rig.icons) do
    if ActionButtonSpellAlertManager:HasAlert(icon) then
      ActionButtonSpellAlertManager:HideAlert(icon)
    end
    tintAlert(icon, nil)   -- reset to native gold so a later glow isn't stuck tinted
    if icon.SpellActivationAlert then icon.SpellActivationAlert:SetAlpha(1) end
  end
end

-- `specs` = list of { index, color?, alpha? }: no color = Blizzard's native gold, a
-- color recolors that square's glow (tintAlert); `alpha` DIMS it — set on the alert
-- FRAME, which multiplies the whole glow WITHOUT fighting the proc animation (that
-- animates the child textures' alpha, not the frame's).  This is the de-emphasis lever
-- for the "subdue the proc glow" backlog item.  ShowAlert creates icon.SpellActivationAlert
-- synchronously, so tint + alpha land on an existing frame.
local function applyProcGlow(rig, specs)
  if not (specs and ActionButtonSpellAlertManager) then return end
  for _, spec in ipairs(specs) do
    local icon = rig.icons[spec.index]
    if icon then
      ActionButtonSpellAlertManager:ShowAlert(icon)
      tintAlert(icon, spec.color)
      if icon.SpellActivationAlert then
        icon.SpellActivationAlert:SetAlpha(spec.alpha or 1)
      end
    end
  end
end

-- ROTATE — a live demo: 5 CDM panels, one press cue hopping between them on a
-- timer.  Shows the diff-by-key movement (the old handle's dot + glow drop as the
-- new one lights) and the glow tracking the dot across icons.  A C_Timer ticker,
-- so it needs stopping when the view changes or clears (unlike the static fixtures).
local ROTATE_ICONS, ROTATE_INTERVAL = 5, 0.8

local function stopRotate()
  if ns._renderTestTicker then
    ns._renderTestTicker:Cancel()
    ns._renderTestTicker = nil
  end
end

local function startRotate()
  stopRotate()
  local rig = buildRig(ROTATE_ICONS)
  rig.container:Show()
  local i = 0
  local function step()
    i = (i % ROTATE_ICONS) + 1
    rig.renderer:Draw({ cues = { cue("fake" .. i, "ROTATION", tostring(i)) } })
  end
  step()                                     -- light the first one immediately
  ns._renderTestTicker = C_Timer.NewTicker(ROTATE_INTERVAL, step)
end

-- `/cdmp rt [<name>|rotate|off|list]` — render a fixture; bare = the first one
-- (`states`, the reference card).
function ns.RenderTest(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if arg == "list" then
    ns.Heading("rt — render-test views")
    ns.Print("  |cff88ff88states|r — every cue state + the native proc glow, gold & recolored (default)")
    for _, name in ipairs(FIXTURE_ORDER) do
      if name ~= "states" then ns.Printf("  |cff88ff88%s|r", name) end
    end
    ns.Print("  |cff88ff88rotate|r — one cue hopping across 5 panels (live)")
    ns.Print("usage: |cffffffff/cdmp rt <name>|r | rotate | off")
    return
  end
  stopRotate()                               -- any view change cancels a live rotate
  clearProcGlow()                            -- ...and drops any native proc glow
  if arg == "off" then
    if ns._renderTestRig then
      ns._renderTestRig.renderer:Draw({})    -- clear every dot / panel / pip
      ns._renderTestRig.container:Hide()
    end
    ns.Print("rt: off")
    return
  end
  if arg == "rotate" then
    startRotate()
    ns.Printf("rt: |cffffffffrotate|r (5 panels, %.1fs) — |cffffffff/cdmp rt off|r to stop",
      ROTATE_INTERVAL)
    return
  end
  if arg == "" then arg = FIXTURE_ORDER[1] end
  local fx = FIXTURES[arg]
  if not fx then
    ns.Printf("unknown view '%s' — try |cffffffff/cdmp rt list|r", arg)
    return
  end
  local rig = buildRig(fx.icons, fx.captions)
  rig.container:Show()
  rig.renderer:Draw(fx.drawList)
  applyProcGlow(rig, fx.procGlow)            -- native glow on top (impure; post-Draw)
  ns.Printf("rt: |cffffffff%s|r (%d icon%s) — |cffffffff/cdmp rt off|r to clear",
    arg, fx.icons, fx.icons == 1 and "" or "s")
end
