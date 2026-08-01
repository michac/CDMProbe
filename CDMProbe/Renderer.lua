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
--   * keybind = a corner key hint, drawn from the DrawList's OWN `keybinds[]` channel
--     (Phase 3) — identity chrome, independent of whether the icon is cued.
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
  -- ringScale is RELATIVE to GLOW_SCALE by intent (~1.4x), so it moved with it when the
  -- base ring shrank to close the dot/ring gap.  Keep that ratio if either is retuned —
  -- the escalation is "a bigger ring", not "this exact number".
  LATE              = { spin = true,  pulse = true, color = "ROTATION",
                        ringScale = 3.2, spinSecs = 1.6 },
  SOON              = { spin = true,  pulse = true },
  -- ROTATION_FALLBACK animates like everything else now (2026-07-30 feedback).  History:
  -- v0.32.17 made the runner-up read by its ring being STATIC, because it was a DIMMER
  -- GREEN and motion was the only channel left to separate it from ROTATION.  It has its
  -- own violet since v0.32.36, so HUE carries the distinction and the stillness bought
  -- nothing — it just made the backup look like a dead cue next to the live ones.
  ROTATION_FALLBACK = { spin = true,  pulse = true },
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
          -- A CLEAN disc: a solid fill clipped by a real MaskTexture OBJECT, attached
          -- with AddMaskTexture.  Borderless by construction — the shape comes from the
          -- mask's alpha, the colour from our own fill.  Two measured API facts rule out
          -- the shorter routes:
          --   * `SetMask(path)` does NOT clip a `SetColorTexture` fill — that pairing
          --     draws a SQUARE (settles the interaction addon-dev/frames-textures-
          --     animation.md §5.7 flags as uncited).
          --   * the `WhiteCircle-RaidBlips` atlas is genuinely round but ships a BAKED
          --     dark outline, and SetVertexColor MULTIPLIES, so black stays black — the
          --     border cannot be tinted away and reads as a hard edge against the glow.
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
        -- DEFENSIVE: an emphasis token the theme has no entry for draws NOTHING — we never
        -- guess a colour.  Hide any dot/glow this handle had.  (Before Phase 3 this branch
        -- also had to keep the handle alive for a keybind-only cue; that job is gone, but
        -- the "unknown token ⇒ no dot" rule is a contract of its own and stays.)
        if self.cueFrames[key] then self.cueFrames[key]:Hide() end
        self:setDotGlow(key, holder, self.cueFrames[key], nil, sz)
      end
    end
  end
  -- Dots + glows cull on the CUE-active set; holders do not (see R:Draw).
  for key, dot in pairs(self.cueFrames) do
    if not active[key] then dot:Hide() end
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
-- ⚠ THE ATLAS HAS A HOLE, AND IT CANNOT BE FILLED.  `services-ring-large-glowspin` is a
-- RING: its transparent centre is baked into the art, and there is no tint or blend mode
-- that paints it in (SetVertexColor multiplies — it cannot add alpha where there is none).
-- The angular detail in that ring is also the only reason the spin READS at all; a
-- symmetric soft blob would rotate invisibly.  So the hole is not a bug to remove, it is
-- the cost of the motion channel — the lever is to make the DOT COVER IT by shrinking the
-- ring until its inner edge sits on the dot's rim.  That is what GLOW_SCALE is:
local GLOW_ATLAS = "services-ring-large-glowspin"   -- round ring glow, built to spin
-- Ring diameter relative to the DOT.  Dialled BY EYE on `/cdmp rt states` — the number
-- that matters is not the ring's size but the gap between the dot's rim and the ring's
-- inner edge, which must be ZERO so the two read as one object.  3.6 left a visible
-- annulus of empty icon between them (2026-07-30 feedback); 2.3 closes it.  Raise this
-- and the halo detaches into a separate floating ring again.
local GLOW_SCALE = 2.3
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
-- ⚠ THE HOLDER CULL IS A UNION, AND IT HAS TO BE.  `cueHolders` is shared by the cue and
-- keybind channels (one holder per icon, carrying both decorations), so culling it inside
-- either pass would hide the other channel's decoration every frame: an uncued icon's key
-- hint would be parented to a hidden holder, and a keyless cued icon's dot likewise.  Each
-- pass therefore returns its own active set and the holder cull happens HERE, over both.
-- Dots/glows still cull on cue-active and key fontstrings on keybind-active — those pools
-- are single-channel.  renderer_spec pins both directions of the independence.
function R:Draw(drawList)
  drawList = drawList or {}
  local cued = self:drawCues(drawList.cues)
  local keyed = self:drawKeybinds(drawList.keybinds)
  for key, h in pairs(self.cueHolders) do
    if not (cued[key] or keyed[key]) then h:Hide() end
  end
  self:drawPanel(drawList.panel)
  self:drawResources(drawList.resourceBars)
  return self
end
