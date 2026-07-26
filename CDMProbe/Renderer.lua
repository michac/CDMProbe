-- Renderer.lua — Stage 4 of the W4 pipeline: DrawList -> **Renderer** -> pixels.
--
-- WHY THIS EXISTS (docs/architecture.md Stage-4 :352-361, w4-build-plan.md Phase 3).
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
-- The four actionability hues are COPIED from HudChrome's `CUE` palette
-- (HudChrome.lua:164-169) so the old live path and the new Renderer never
-- disagree; keep them in lock-step by hand until the cutover retires HudChrome.
-- SEQUENCE (a distinct token — it points the eye at the panel, not at a press) is
-- the summon fel-green from ns.SpecGroups.summon, read live so it tracks the one
-- source of truth for group hues (SpecDemonology.lua:64-73).
local function defaultTheme()
  local g = ns.SpecGroups or {}
  local summon = g.summon or { 0.216, 0.784, 0.435 }
  return {
    ROTATION = { 0.30, 1.00, 0.48, 1.00 },  -- green: press now
    LATE     = { 0.42, 1.00, 0.58, 1.00 },  -- brighter green: overdue
    SOON     = { 1.00, 0.86, 0.15, 1.00 },  -- yellow: anticipation
    JUDGE    = { 0.27, 0.88, 1.00, 1.00 },  -- cyan: your-call
    SEQUENCE = { summon[1], summon[2], summon[3], 1.00 },  -- fel green: see the panel
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
  self.root       = cfg.root    -- our own overlay parent; created lazily
  self.cueFrames  = {}          -- anchorTo -> dot texture (diff-by-key pool)
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

function R:ensureRoot()
  if not self.root then
    self.root = CreateFrame("Frame", nil, UIParent)
    self.root:SetAllPoints(UIParent)
    self.root:SetFrameStrata("HIGH")
  end
  return self.root
end

--------------------------------------------------------------------------------
-- Cue dots (3b)
--------------------------------------------------------------------------------
-- A cue is a solid square, coloured by its emphasis token and anchored to its
-- handle's frame.  Diff-by-key on `anchorTo`: only handles in THIS DrawList are
-- (re)painted; a handle that dropped out is hidden, never destroyed.  An emphasis
-- token the theme doesn't know draws NOTHING (never guess a colour) — an unknown
-- token that had a dot last frame is hidden like any dropout.
function R:drawCues(cues)
  local active = {}
  for _, c in ipairs(cues or {}) do
    local col = self.theme[c.emphasis]
    local key = c.anchorTo
    if col and key ~= nil then
      active[key] = true
      local dot = self.cueFrames[key]
      if not dot then
        dot = self:ensureRoot():CreateTexture(nil, "OVERLAY")
        dot:SetTexture(WHITE8)
        self.cueFrames[key] = dot
      end
      dot:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
      local sz = c.size or 12
      dot:SetSize(sz, sz)
      dot:ClearAllPoints()
      local anchor = self.registry[key]
      if anchor then
        dot:SetPoint(c.point or "CENTER", anchor,
                     c.relPoint or c.point or "CENTER", c.dx or 0, c.dy or 0)
      end
      dot:Show()
    end
  end
  for key, dot in pairs(self.cueFrames) do
    if not active[key] then dot:Hide() end
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
local PIP_SIZE, PIP_GAP = 14, 4

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
-- golden state (corpus/goldens/<name>/guidance.json).  The Guidance keys cues by
-- cooldownID; mapping those to fake icon handles fake1..fakeN is exactly the
-- Binder's Phase-4 job, done by hand here for the test.  `icons` = how many
-- placeholder squares the row needs.
local DOT = { point = "TOP", relPoint = "BOTTOM", dy = -6, size = 16 }
local function cue(handle, emphasis)
  return { anchorTo = handle, point = DOT.point, relPoint = DOT.relPoint,
           dy = DOT.dy, size = DOT.size, emphasis = emphasis }
end
local function shards(value, max)
  return { anchorTo = "UIPARENT", point = "CENTER",
           dx = -((max or 5) * 18 - 4) / 2, dy = -18,
           value = value, max = max or 5, powerType = "SOUL_SHARDS" }
end

local FIXTURE_ORDER = { "hand-of-guldan", "burst-hold", "opener-midflight", "secrecy-combat" }
local FIXTURES = {
  -- One ROTATION press: HoG is the single call (3 shards, no proc, summons cooling).
  ["hand-of-guldan"] = { icons = 1, drawList = {
    cues = { cue("fake1", "ROTATION") },
    resourceBar = shards(3, 5),
  } },
  -- ROTATION + two JUDGE: HoG presses now; Dreadstalkers + Implosion are your-call
  -- "stage for the Tyrant window or press" (JUDGE coexists with the one ROTATION).
  ["burst-hold"] = { icons = 3, drawList = {
    cues = { cue("fake1", "ROTATION"), cue("fake2", "JUDGE"), cue("fake3", "JUDGE") },
    resourceBar = shards(3, 5),
  } },
  -- SEQUENCE dot + panel: the OPENER plan carries the guidance; the one cue is an
  -- attention-redirect to the panel (Tyrant is the step), NOT a ROTATION press.
  ["opener-midflight"] = { icons = 1, drawList = {
    cues = { cue("fake1", "SEQUENCE") },
    panel = {
      anchorTo = "UIPARENT", point = "TOP", dx = 0, dy = -200, title = "OPENER",
      steps = {
        { label = "Dreadstalkers",         keybind = "E",  state = "done" },
        { label = "Grimoire: Imp Lord",    keybind = "sE", state = "done" },
        { label = "Summon Demonic Tyrant", keybind = "sQ", state = "active" },
        { label = "Hand of Gul'dan",       keybind = "R",  state = "pending" },
        { label = "Hand of Gul'dan",       keybind = "R",  state = "blocked" },
        { label = "Implosion",             keybind = "1",  state = "skipped" },
      },
    },
    resourceBar = shards(3, 5),
  } },
  -- ROTATION + SOON with every cd unreadable: Demonbolt presses (Core up via a
  -- readable buff+glow); Tyrant draws SOON off the napkin estimate (anticipation).
  ["secrecy-combat"] = { icons = 2, drawList = {
    cues = { cue("fake1", "ROTATION"), cue("fake2", "SOON") },
    resourceBar = shards(2, 5),
  } },
}

ns.RenderTestFixtures = FIXTURES   -- exported so a spec / tool can read them

-- Build (or reuse) the placeholder icon row + a persistent test Renderer.  Icons
-- are bordered dark squares — the DOT is the star of each screenshot.
local function buildRig(n)
  local rig = ns._renderTestRig
  if not rig then
    local container = CreateFrame("Frame", "CDMProbeRenderTest", UIParent)
    container:SetSize(480, 220)
    container:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    container:SetFrameStrata("HIGH")
    rig = { container = container, icons = {}, renderer = R.New() }
    ns._renderTestRig = rig
  end
  local SIZE, GAP = 48, 12
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
      fill:SetColorTexture(0.12, 0.13, 0.16, 1)
      rig.icons[i] = icon
    end
    icon:ClearAllPoints()
    icon:SetPoint("LEFT", rig.container, "CENTER", -total / 2 + (i - 1) * (SIZE + GAP), 0)
    icon:Show()
    rig.renderer:Register("fake" .. i, icon)
  end
  for i = n + 1, #rig.icons do rig.icons[i]:Hide() end
  return rig
end

-- `/cdmp rendertest [<name>|off|list]` — render a fixture; bare = the first one.
function ns.RenderTest(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if arg == "off" then
    if ns._renderTestRig then
      ns._renderTestRig.renderer:Draw({})   -- clear every dot / panel / pip
      ns._renderTestRig.container:Hide()
    end
    ns.Print("rendertest: off")
    return
  end
  if arg == "list" then
    ns.Heading("rendertest fixtures")
    for _, name in ipairs(FIXTURE_ORDER) do ns.Printf("  |cff88ff88%s|r", name) end
    ns.Print("usage: |cffffffff/cdmp rendertest <name>|r | off")
    return
  end
  if arg == "" then arg = FIXTURE_ORDER[1] end
  local fx = FIXTURES[arg]
  if not fx then
    ns.Printf("unknown fixture '%s' — try |cffffffff/cdmp rendertest list|r", arg)
    return
  end
  local rig = buildRig(fx.icons)
  rig.container:Show()
  rig.renderer:Draw(fx.drawList)
  ns.Printf("rendertest: |cffffffff%s|r (%d icon%s) — |cffffffff/cdmp rendertest off|r to clear",
    arg, fx.icons, fx.icons == 1 and "" or "s")
end
