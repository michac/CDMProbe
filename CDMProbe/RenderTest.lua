-- RenderTest.lua — the in-game `/cdmp rt` render-test rig.  IMPURE by construction, and
-- deliberately OUTSIDE Renderer.lua's pure Draw path.
--
-- WHY IT IS ITS OWN FILE.  Renderer.lua is Stage 4 and claims to make NO decisions, touch
-- no game state, and own nothing but a frame pool + a handle registry.  This rig does the
-- opposite on purpose: it CreateFrame()s real placeholder icons, runs a C_Timer ticker,
-- holds module state on `ns._renderTestRig`, and calls straight into Blizzard's
-- ActionButtonSpellAlertManager.  Keeping the two in one file made the pure stage read as
-- impure and buried its seam.  The seam is clean: everything below needs only the `R`
-- class and ns.HudGeometry.
--
-- WHAT IT IS FOR.  It builds real placeholder icon frames, registers them under fake
-- handles, and renders a HAND-AUTHORED DrawList fixture through a real Renderer — the
-- pixel confirmation: dial the visual language in against representative golden states
-- with no game state, no dummy, no RNG, no CDM.  Wired to `/cdmp rt` (registered in
-- Core.lua).
--
-- `ns.RenderTestFixtures` is an explicit export: binder_spec asserts the Binder produces
-- exactly these DrawLists from the matching Guidance, so the fixtures and the live
-- producer agree by construction rather than by copy.
--
-- LOAD ORDER: after Renderer.lua (needs ns.Renderer) and after HudGeometry.lua.
local ADDON, ns = ...

local R = ns.Renderer

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
local cue = G.cue          -- cue(handle, emphasis) -> a positioned cue.  ⚠ NO keybind arg:
                           -- Phase 3 gave keybinds their own channel, so a cue is a decision
                           -- and nothing else.
local kb  = G.keybind      -- kb(handle, key) -> a positioned key hint (the other channel)
local shards = G.resourceBar  -- shards(value, max) -> the centred discrete-pip bar

local FIXTURE_ORDER = { "states", "hand-of-guldan", "opener-midflight", "secrecy-combat" }
local FIXTURES = {
  -- STATES — the canonical reference card: one simulated CDM square per VISIBLE cue
  -- state the live pipeline can put on an icon, captioned, left→right roughly
  -- least→most salient, with the NATIVE proc glow last.  Not a scenario the Coach
  -- would emit as one frame — a palette:
  --   IDLE      keybind hint only, no dot (the "empty board" — tracked, nothing to do)
  --   SOON      anticipation — yellow circle + spinning/pulsing ring
  --   FALLBACK  ROTATION_FALLBACK — the runner-up: VIOLET circle + ring.  It reads as the
  --            backup by HUE; it spins and pulses like every other live cue
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
  -- (Every cue shows its solid circle AND a spinning, pulsing glow ring; only LATE's ring
  -- differs, being bigger and ~2.5x faster.)  Squares carry real spell-icon ART, so the
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
      -- IDLE (fake1) is the channel separation made visible: it appears in `keybinds` and
      -- NOT in `cues`.  Every other square is in both.
      cues = {
        cue("fake2", "SOON"),               -- anticipation: yellow circle + spinning ring
        cue("fake3", "ROTATION_FALLBACK"),  -- runner-up: violet circle + spinning ring
        cue("fake4", "ROTATION"),           -- press now: green circle + spinning ring
        cue("fake5", "LATE"),               -- overdue: amber circle + spinning ring
        cue("fake6", "ROTATION_FALLBACK"),  -- FALLBACK dot + keybind, NATIVE glow on top
        cue("fake7", "ROTATION_FALLBACK"),  -- same, but the glow is RECOLORED (red)
        cue("fake8", "ROTATION_FALLBACK"),  -- same, but the glow is DIMMED (alpha)
      },
      keybinds = {
        kb("fake1", "Q"),                   -- IDLE: key hint only, no dot
        kb("fake2", "E"), kb("fake3", "R"), kb("fake4", "R"), kb("fake5", "E"),
        kb("fake6", "F"), kb("fake7", "F"), kb("fake8", "F"),
      },
    } },
  -- One ROTATION press: HoG is the single call (3 shards, no proc, summons cooling).
  ["hand-of-guldan"] = { icons = 1, drawList = {
    cues = { cue("fake1", "ROTATION") },
    keybinds = { kb("fake1", "R") },
    resourceBars = { shards(3, 5) },
  } },
  -- ROTATION + SOON, no panel (TCT redesign — the opener panel is retired): mid-opener
  -- the burst walk still owes a shard, so Shadow Bolt caps (ROTATION) while Tyrant rides
  -- the SOON anchor.  The one-press cue walk replaced the sequence panel.
  ["opener-midflight"] = { icons = 2, drawList = {
    cues = { cue("fake1", "ROTATION"), cue("fake2", "SOON") },
    keybinds = { kb("fake1", "Q"), kb("fake2", "sQ") },
    resourceBars = { shards(3, 5) },
  } },
  -- ROTATION + SOON with every cd unreadable: Demonbolt presses (Core up via a
  -- readable buff+glow); Tyrant draws SOON off the napkin estimate (anticipation).
  -- fake1 = Demonbolt (its key is "F" in the golden state — matched here so the
  -- fixture equals what the Binder emits from that golden).
  ["secrecy-combat"] = { icons = 2, drawList = {
    cues = { cue("fake1", "ROTATION"), cue("fake2", "SOON") },
    keybinds = { kb("fake1", "F"), kb("fake2", "sQ") },
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
    -- The rig's renderer gets the SHIPPED cue-sound callback, so `rt rotate` auditions
    -- the real edge policy (one play per SWAP, not two).  Resolved here at dispatch time,
    -- not at file scope: HudDriver.lua loads after this file.  It respects
    -- `/cdmp hud sound off` like everything else.
    rig = { container = container, icons = {},
            renderer = R.New({ onCueSetChanged = ns.PlayCueSound }) }
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
    local dl = { cues = { cue("fake" .. i, "ROTATION", tostring(i)) } }
    rig.renderer:Draw(dl)
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
      -- Forget the last cue set BEFORE clearing, so tearing the view down does not
      -- announce itself as a board full of departing cues.  (`SetHud(false)` gets the
      -- same effect from its own `D.on` gate; the rig has no such flag, and reaching
      -- into the renderer's pools is what this file does by construction.)
      ns._renderTestRig.renderer.cuedLast = {}
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
