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
--   * resourceBar = a minimal discrete-pip row (optional).
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
-- The five tokens must be GLANCEABLE — distinct enough to read apart in the icon
-- corner at a flick of the eye.  The first cut kept ROTATION/LATE/SEQUENCE all in
-- the green family (LATE a brighter green, SEQUENCE the summon fel-green) and they
-- were indistinguishable in-game (2026-07-26 feedback).  So LATE and SEQUENCE are
-- pulled OFF the green: LATE = hot amber ("overdue, catch up"), SEQUENCE = violet
-- ("look at the panel, not a press").  ROTATION/SOON/JUDGE still match HudChrome's
-- CUE palette (HudChrome.lua:165-167); LATE + SEQUENCE now deliberately diverge for
-- separation — the Renderer owns token->pixels, so this is a local dial-in.
local function defaultTheme()
  return {
    ROTATION          = { 0.30, 1.00, 0.48, 1.00 },  -- green:      press now
    -- ROTATION_FALLBACK (W4 Phase 8): the honest runner-up.  A dimmer, desaturated
    -- green — same hue family as ROTATION but clearly subordinate ("what I'd press
    -- instead").  Never glows (glow stays reserved for the real press, set by the
    -- Binder for ROTATION/LATE only), so a nil-col miss is the only way it vanishes —
    -- which is exactly the bug this entry closes.
    ROTATION_FALLBACK = { 0.20, 0.55, 0.32, 1.00 },  -- dim green:  the runner-up press
    LATE              = { 1.00, 0.42, 0.10, 1.00 },  -- amber:      overdue, catch up
    SOON              = { 1.00, 0.86, 0.15, 1.00 },  -- yellow:     anticipation
    JUDGE             = { 0.27, 0.88, 1.00, 1.00 },  -- cyan:       your-call (retired)
    SEQUENCE          = { 0.64, 0.42, 1.00, 1.00 },  -- violet:     look at the panel (retired)
  }
end

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
  self.glowing    = {}          -- anchorTo -> true while its dot is glowing
  self.pips       = {}          -- 1..N -> pip texture (resource bar pool)
  self.panelWidget = nil        -- { frame, title, rows = {} }, built on first panel
  -- UIPARENT is a sanctioned root token (architecture.md :341); pre-register it so
  -- a hand-authored DrawList can anchor a panel/bar to the screen with no ceremony.
  self.registry.UIPARENT = cfg.uiparent or UIParent
  return self
end

-- Populate the registry.  Live mode maps cooldownID -> CDM item frame; test mode
-- maps "fake1" -> a placeholder square.  :Root is the same door, named for intent
-- when the key is a root token rather than an ability handle.
function R:Register(handle, frame) self.registry[handle] = frame; return self end
function R:Root(token, frame)      self.registry[token] = frame; return self end

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
-- A cue is a solid square, coloured by its emphasis token and anchored to its
-- handle's frame — a corner treatment INSIDE the icon (the DrawList geometry puts
-- it upper-right; see the fixtures).  Diff-by-key on `anchorTo`: only handles in
-- THIS DrawList are (re)painted; a handle that dropped out is hidden, never
-- destroyed.
--
-- THE DOT AND THE KEY HINT ARE DECOUPLED (P5d).  A cue carries an optional emphasis
-- token AND an optional `keybind` string, and they draw INDEPENDENTLY:
--   * emphasis the theme knows -> a coloured dot (+ glow if flagged); an absent or
--     unknown token draws NO dot (never guess a colour), hiding any prior one.
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
      local col = self.theme[c.emphasis]
      local sz = c.size or 12
      if col then
        local dot = self.cueFrames[key]
        if not dot then
          dot = holder:CreateTexture(nil, "OVERLAY")
          dot:SetTexture(WHITE8)
          self.cueFrames[key] = dot
        end
        dot:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
        dot:SetSize(sz, sz)
        dot:ClearAllPoints()
        dot:SetPoint(c.point or "CENTER", anchor,
                     c.relPoint or c.point or "CENTER", c.dx or 0, c.dy or 0)
        dot:Show()
        self:setDotGlow(key, holder, dot, c.glow and col or nil, sz)
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
      if g.ag then g.ag:Stop() end
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
-- Proc glow — the DOT itself glows, like Demonic Core lighting up Demonbolt, but
-- scoped to the little cue rather than the whole icon.
--------------------------------------------------------------------------------
-- A soft additive halo, tinted to the dot's own emphasis hue, sized ~2.4x the dot
-- and centred on it (so it rides the dot into the icon corner), breathing on a
-- looping alpha bounce.  Sits a layer BELOW the dot (ARTWORK vs the dot's OVERLAY)
-- so the crisp dot stays on top of its own glow.  Pooled per handle like the dot.
-- Idempotent: the breathe only (re)starts on the not-glowing -> glowing edge, so a
-- steady cue redraw (a colour/size change) doesn't hitch the animation.
local GLOW_TEX   = "Interface\\Buttons\\UI-ActionButton-Border"  -- soft rounded halo
-- ~4.5x the dot => the halo blooms PAST the icon edges (deliberately, 2026-07-26
-- feedback: "more prominent, even if it overlaps the edges").  Paired with a high
-- alpha floor so it's always visibly lit, breathing brighter on the bounce.
local GLOW_SCALE = 4.5

function R:setDotGlow(key, holder, dot, col, size)
  local g = self.cueGlows[key]
  if not col then                              -- no glow this frame: hide + park
    if g then g:Hide(); if g.ag then g.ag:Stop() end end
    self.glowing[key] = nil
    return
  end
  local was = self.glowing[key]
  if not g then
    g = holder:CreateTexture(nil, "ARTWORK")
    g:SetTexture(GLOW_TEX)
    g:SetBlendMode("ADD")
    local ag = g:CreateAnimationGroup()
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(0.45)
    a:SetToAlpha(1.00)
    a:SetDuration(0.50)
    a:SetOrder(1)
    ag:SetLooping("BOUNCE")
    g.ag = ag
    self.cueGlows[key] = g
  end
  g:SetVertexColor(col[1], col[2], col[3], 1)
  g:ClearAllPoints()
  g:SetPoint("CENTER", dot, "CENTER", 0, 0)
  g:SetSize(size * GLOW_SCALE, size * GLOW_SCALE)
  g:Show()
  if not was and g.ag then g.ag:Play() end
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

-- `max` pips in a row; the first `value` filled with the powerType colour, the
-- rest a faint empty ring.  Pooled + surplus hidden like the cue dots.
function R:drawResource(bar)
  if not bar then
    for _, pip in ipairs(self.pips) do pip:Hide() end
    return
  end
  local col = self.powerColor[bar.powerType] or self.powerColor.SOUL_SHARDS
  local anchor = self.registry[bar.anchorTo] or self.registry.UIPARENT
  local max, value = bar.max or 0, bar.value or 0
  for i = 1, max do
    local pip = self.pips[i]
    if not pip then
      pip = self:ensureRoot():CreateTexture(nil, "OVERLAY")
      pip:SetTexture(WHITE8)
      self.pips[i] = pip
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
  for i = max + 1, #self.pips do self.pips[i]:Hide() end
end

--------------------------------------------------------------------------------
-- The one entry point
--------------------------------------------------------------------------------
function R:Draw(drawList)
  drawList = drawList or {}
  self:drawCues(drawList.cues)
  self:drawPanel(drawList.panel)
  self:drawResource(drawList.resourceBar)
  return self
end

--------------------------------------------------------------------------------
-- In-game TEST MODE (Phase 3e) — the IMPURE driver, deliberately outside the pure
-- Draw path above.  It builds real placeholder icon frames, registers them under
-- fake handles, and renders a HAND-AUTHORED DrawList fixture through a Renderer.
-- No game decisions — just placeholder frames + fixtures + Renderer, the exact
-- shape Phase 4's Binder will one day produce.  Wired to `/cdmp rendertest`
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

local FIXTURE_ORDER = { "states", "inventory", "hand-of-guldan", "burst-hold", "opener-midflight", "secrecy-combat" }
local FIXTURES = {
  -- STATES — the canonical reference card: one simulated CDM square per VISIBLE cue
  -- state the live pipeline can put on an icon, captioned, left→right roughly
  -- least→most salient, with the NATIVE proc glow last.  Not a scenario the Coach
  -- would emit as one frame — a palette:
  --   IDLE      keybind hint only, no dot (the "empty board" — tracked, nothing to do)
  --   SOON      anticipation, plain dot (not a press)
  --   FALLBACK  ROTATION_FALLBACK — the honest runner-up, plain dot
  --   ROTATION  press now — dot + our own breathing dot-glow
  --   LATE      overdue — dot + our own dot-glow
  --   FB+GLOW   a FALLBACK dot + keybind UNDER Blizzard's NATIVE spell-activation
  --            overlay (applied post-Draw, below) — the exact conflict the "subdue
  --            the proc glow" backlog item is about: the native glow stomping OUR
  --            chrome.  Pairs with the plain FALLBACK square (fake3) as the A/B.
  -- Squares carry real spell-icon ART (buildRig), so the chrome is judged against a
  -- busy icon like the live CDM, not a flat fill.
  -- (Supersedes `inventory` as the default: that card still lists the RETIRED
  -- JUDGE/SEQUENCE tokens; this one is the live SOON|ROTATION|ROTATION_FALLBACK|LATE
  -- set plus the idle + native-glow states.)
  ["states"] = { icons = 6,
    captions = { "IDLE", "SOON", "FALLBACK", "ROTATION", "LATE", "FB+GLOW" },
    procGlow = { 6 },   -- icon indices to paint Blizzard's native glow onto (post-Draw)
    drawList = {
      cues = {
        cue("fake1", nil, "Q"),                  -- IDLE: keybind only, no dot
        cue("fake2", "SOON", "E"),               -- anticipation, no glow
        cue("fake3", "ROTATION_FALLBACK", "R"),  -- runner-up, no glow
        cue("fake4", "ROTATION", "R"),           -- press now, glows (our dot-glow)
        cue("fake5", "LATE", "E"),               -- overdue, glows
        cue("fake6", "ROTATION_FALLBACK", "F"),  -- FALLBACK dot + keybind, native glow on top
      },
    } },
  -- INVENTORY — not a scenario: one dot of EVERY emphasis token side by side, each
  -- captioned, so the whole palette (and which tokens glow) reads at a glance.  The
  -- reference card for the visual language, not a state the Coach would produce.
  ["inventory"] = { icons = 5,
    captions = { "ROTATION", "LATE", "SOON", "JUDGE", "SEQUENCE" },
    drawList = {
      cues = {
        cue("fake1", "ROTATION", "R"), cue("fake2", "LATE", "R"),
        cue("fake3", "SOON", "E"),     cue("fake4", "JUDGE", "1"),
        cue("fake5", "SEQUENCE", "sQ"),
      },
    } },
  -- One ROTATION press: HoG is the single call (3 shards, no proc, summons cooling).
  ["hand-of-guldan"] = { icons = 1, drawList = {
    cues = { cue("fake1", "ROTATION", "R") },
    resourceBar = shards(3, 5),
  } },
  -- LATE + JUDGE (TCT redesign): not TCT (Tyrant far) so it's STEADY — an overdue
  -- Dreadstalkers presses (LATE, glows), Implosion is your-call (JUDGE).  No HoG dot.
  ["burst-hold"] = { icons = 3, drawList = {
    cues = { cue("fake2", "LATE", "E"), cue("fake3", "JUDGE", "1") },
    resourceBar = shards(3, 5),
  } },
  -- ROTATION + SOON, no panel (TCT redesign — the opener panel is retired): mid-opener
  -- the burst walk still owes a shard, so Shadow Bolt caps (ROTATION) while Tyrant rides
  -- the SOON anchor.  The one-press cue walk replaced the sequence panel.
  ["opener-midflight"] = { icons = 2, drawList = {
    cues = { cue("fake1", "ROTATION", "Q"), cue("fake2", "SOON", "sQ") },
    resourceBar = shards(3, 5),
  } },
  -- ROTATION + SOON with every cd unreadable: Demonbolt presses (Core up via a
  -- readable buff+glow); Tyrant draws SOON off the napkin estimate (anticipation).
  -- fake1 = Demonbolt (its key is "F" in the golden state — matched here so the
  -- fixture equals what the Binder emits from that golden).
  ["secrecy-combat"] = { icons = 2, drawList = {
    cues = { cue("fake1", "ROTATION", "F"), cue("fake2", "SOON", "sQ") },
    resourceBar = shards(2, 5),
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
    container:SetSize(560, 220)
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
local function clearProcGlow()
  local rig = ns._renderTestRig
  if not (rig and ActionButtonSpellAlertManager) then return end
  for _, icon in ipairs(rig.icons) do
    if ActionButtonSpellAlertManager:HasAlert(icon) then
      ActionButtonSpellAlertManager:HideAlert(icon)
    end
  end
end

local function applyProcGlow(rig, indices)
  if not (indices and ActionButtonSpellAlertManager) then return end
  for _, i in ipairs(indices) do
    local icon = rig.icons[i]
    if icon then ActionButtonSpellAlertManager:ShowAlert(icon) end
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

-- `/cdmp rendertest [<name>|inventory|rotate|off|list]` — render a fixture; bare =
-- the first one (the inventory reference card).
function ns.RenderTest(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if arg == "list" then
    ns.Heading("rendertest views")
    ns.Print("  |cff88ff88states|r — every cue state + the native proc glow (default)")
    for _, name in ipairs(FIXTURE_ORDER) do
      if name ~= "states" then ns.Printf("  |cff88ff88%s|r", name) end
    end
    ns.Print("  |cff88ff88rotate|r — one cue hopping across 5 panels (live)")
    ns.Print("usage: |cffffffff/cdmp rendertest <name>|r | rotate | off")
    return
  end
  stopRotate()                               -- any view change cancels a live rotate
  clearProcGlow()                            -- ...and drops any native proc glow
  if arg == "off" then
    if ns._renderTestRig then
      ns._renderTestRig.renderer:Draw({})    -- clear every dot / panel / pip
      ns._renderTestRig.container:Hide()
    end
    ns.Print("rendertest: off")
    return
  end
  if arg == "rotate" then
    startRotate()
    ns.Printf("rendertest: |cffffffffrotate|r (5 panels, %.1fs) — |cffffffff/cdmp rendertest off|r to stop",
      ROTATE_INTERVAL)
    return
  end
  if arg == "" then arg = FIXTURE_ORDER[1] end
  local fx = FIXTURES[arg]
  if not fx then
    ns.Printf("unknown view '%s' — try |cffffffff/cdmp rendertest list|r", arg)
    return
  end
  local rig = buildRig(fx.icons, fx.captions)
  rig.container:Show()
  rig.renderer:Draw(fx.drawList)
  applyProcGlow(rig, fx.procGlow)            -- native glow on top (impure; post-Draw)
  ns.Printf("rendertest: |cffffffff%s|r (%d icon%s) — |cffffffff/cdmp rendertest off|r to clear",
    arg, fx.icons, fx.icons == 1 and "" or "s")
end
