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

--------------------------------------------------------------------------------
-- EXPERIMENTAL FX (`/cdmp rt fx …`) — four candidate treatments, 2026-08-01
--------------------------------------------------------------------------------
-- WHY THESE LIVE HERE AND NOT IN Renderer.lua.  Every one of these is an OPEN
-- QUESTION, not a decision.  Renderer.lua is the pure Stage-4 contract that the live
-- HUD and this rig share (that sharing is the whole reason `/cdmp rt` is trustworthy),
-- so putting an un-dialled effect behind a Renderer cfg knob would fork the thing the
-- two sides agree on.  Instead the FX layer sits ON TOP: it reads the renderer
-- instance's own pools (`cueHolders` / `cueFrames` / `cueGlows`) after `R:Draw` has run
-- and decorates them.  Renderer.lua is UNTOUCHED by this file, so `/cdmp rt states`
-- remains the honest baseline to compare against and the shipped HUD is unaffected.
-- When an effect wins, it gets promoted INTO the Renderer properly (a token, a
-- GLOW_SPEC field, a one-shot channel) — do not ship it from here.
--
-- THE FOUR:
--   1. `bg`     a BLACK BACKING DISC under the dot + ring, big enough to cover both.
--               The contrast hypothesis: the ring is additive over busy icon art, so
--               it washes out; punching a dark hole behind it gives the added light
--               something to read against.  Also the cheapest possible answer to the
--               violet ring's luminance problem (~2.7x dimmer than the green).
--   2. `glow`   TURN THE GLOW UP.  ⚠ SetVertexColor CANNOT exceed 1.0 — you cannot
--               brighten a tint past full.  The only way to add light with an additive
--               texture is to DRAW IT AGAIN, so `glow 2` = "doubling it" literally:
--               a second identical ADD copy stacked on the first.  Copies are created
--               and Play()ed in ONE call so their spins stay in phase (a copy started
--               later would counter-rotate visually and read as mush).
--   3. `pop`    a ONE-SHOT scale: 1x -> peak -> 1x, fast out / slower settle, played on
--               cue APPLICATION.  Its mirror on REMOVAL is `ghost` (below).
--   4. `sound`  a cue SFX, auditioned round-robin off a curated SOUNDKIT list.
--
-- `ghost` is the removal half of #3 and has to be built differently from the
-- application half: `R:Draw` HIDES a dropped cue's dot/glow the instant it leaves the
-- DrawList, so an out-animation on the renderer's own textures would play invisibly.
-- The ghost is therefore an FX-OWNED texture on an FX-OWNED holder that no cull
-- touches — which is also the shape the real feature would need.
local FX = {
  bg      = false,  -- black backing disc on/off
  bgAlpha = 0.75,   -- its opacity
  bgScale = 1.15,   -- diameter relative to the RING's (not the dot's)
  stack   = 1,      -- additive glow copies: 1 = stock, 2 = "doubled"
  pop     = false,  -- one-shot scale on application
  ghost   = false,  -- one-shot scale+fade on removal
  peak    = 2.0,    -- pop/ghost peak scale ("double in size")
  secs    = 0.28,   -- pop duration
  sound   = nil,    -- index into SOUNDS; nil = silent
  holders = {},     -- key -> our own frame (never culled by the Renderer)
  bgs     = {},     -- key -> backing disc
  stacks  = {},     -- key -> { extra glow copies }
  ghosts  = {},     -- key -> ghost texture
  lastOn  = {},     -- key -> true if it carried a cue on the PREVIOUS draw
}
ns._renderTestFX = FX

-- Our own per-icon holder, parented to the ICON (not to the Renderer's holder, which
-- `R:Draw` hides on cull — the ghost has to outlive exactly that).  One frame level
-- BELOW the Renderer's (+10), so the disc and the extra glow copies sit under the real
-- dot while still clearing the icon's own child frames.
local FX_LEVEL_ABOVE = 9

local function fxHolder(key, anchor)
  local h = FX.holders[key]
  if not h then
    h = CreateFrame("Frame", nil, anchor)
    FX.holders[key] = h
  end
  h:SetParent(anchor)
  h:SetAllPoints(anchor)
  h:SetFrameLevel((anchor:GetFrameLevel() or 0) + FX_LEVEL_ABOVE)
  h:Show()
  return h
end

-- A masked black disc — same construction as the Renderer's dot (a solid fill clipped
-- by a real MaskTexture object), because the same two shortcuts are still ruled out:
-- SetMask(path) does not clip a SetColorTexture fill, and the round atlas ships a baked
-- outline.  See Renderer.lua's dot creation for the measurements.
local function ensureDisc(holder, layer)
  local t = holder:CreateTexture(nil, layer)
  local mask = holder:CreateMaskTexture()
  mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
                  "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
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

-- The Scale animation's setter was renamed across expansions; both spellings are still
-- in the wild.  A wrong name here fails SILENTLY (no error, no motion), which would read
-- as "the pop doesn't help" — the one wrong answer this experiment must not return.
local function setScale(anim, from, to)
  if anim.SetScaleFrom then
    anim:SetScaleFrom(from, from); anim:SetScaleTo(to, to)
  else
    anim:SetFromScale(from, from); anim:SetToScale(to, to)
  end
end

-- ONE-SHOT POP on a region: 1x -> peak -> 1x, no looping.  Fast out (35 %), slower
-- settle (65 %) — a symmetric split reads as a wobble rather than a punch.
-- ⚠ The region may already carry the Renderer's Rotation/Alpha groups (the glow does);
-- these are SEPARATE groups and compose.  If the live pass shows them fighting, the
-- promotion path is to scale an FX frame instead of the texture.
local function playPop(region, peak, secs)
  if not region then return end
  local g = region._fxPop
  if not g then
    g = region:CreateAnimationGroup()
    g._up = g:CreateAnimation("Scale"); g._up:SetOrigin("CENTER", 0, 0); g._up:SetOrder(1)
    g._dn = g:CreateAnimation("Scale"); g._dn:SetOrigin("CENTER", 0, 0); g._dn:SetOrder(2)
    region._fxPop = g
  end
  g:Stop()
  setScale(g._up, 1.0, peak); g._up:SetDuration(secs * 0.35)
  setScale(g._dn, peak, 1.0); g._dn:SetDuration(secs * 0.65)
  g:Play()
end

-- REMOVAL: an FX-owned ghost of the ring that scales up and fades out where the cue
-- just left.  Atlas + hue are read OFF THE OUTGOING GLOW (`GetAtlas`/`GetVertexColor`)
-- rather than restated here, so this can never drift from whatever Renderer.lua's
-- GLOW_ATLAS and theme currently are.
local function playGhost(key, holder, glow, size)
  if not glow then return end
  local t = FX.ghosts[key]
  if not t then
    t = holder:CreateTexture(nil, "ARTWORK")
    t:SetBlendMode("ADD")
    local g = t:CreateAnimationGroup()
    g._s = g:CreateAnimation("Scale"); g._s:SetOrigin("CENTER", 0, 0); g._s:SetOrder(1)
    g._a = g:CreateAnimation("Alpha");  g._a:SetOrder(1)
    g:SetScript("OnFinished", function() t:Hide() end)
    t._g = g
    FX.ghosts[key] = t
  end
  local atlas = glow.GetAtlas and glow:GetAtlas()
  if atlas then t:SetAtlas(atlas) end
  local r, gg, b = glow:GetVertexColor()
  t:SetVertexColor(r or 1, gg or 1, b or 1, 1)
  t:SetSize(size, size)
  t:ClearAllPoints()
  t:SetPoint("CENTER", glow, "CENTER", 0, 0)
  t._g:Stop()
  setScale(t._g._s, 1.0, FX.peak); t._g._s:SetDuration(FX.secs)
  t._g._a:SetFromAlpha(1); t._g._a:SetToAlpha(0); t._g._a:SetDuration(FX.secs)
  t:SetAlpha(1)
  t:Show()
  t._g:Play()
end

-- Curated audition list.  Resolved through SOUNDKIT BY NAME at call time and skipped if
-- absent — a hardcoded numeric id that shifted between builds would play the wrong
-- sound (or nothing) with no way to tell which.  `rt fx sound list` reports what resolved.
local SOUNDS = {
  { "UI_POWER_AURA_GENERIC",          "power-aura ping (the classic proc ding)" },
  { "IG_MAINMENU_OPTION_CHECKBOX_ON", "checkbox tick (dry, very short)" },
  { "IG_QUEST_LIST_SELECT",           "quest-list select (soft click)" },
  { "UI_TOYBOX_TAB",                  "toybox tab (woody tap)" },
  { "UI_TRANSMOG_ITEM_CLICK",         "transmog click (crisp)" },
  { "UI_AUTO_QUEST_COMPLETE",         "auto-quest complete (chime)" },
  { "MAP_PING",                       "map ping (locator blip)" },
  { "GS_TITLE_OPTION_OK",             "title-screen OK (thunk)" },
  { "UI_RAID_BOSS_WHISPER_WARNING",   "boss whisper (attention-grabber)" },
}

local function soundID(i)
  local e = SOUNDS[i]
  return e and SOUNDKIT and SOUNDKIT[e[1]] or nil
end

-- "Master" rather than "SFX" on purpose: a rotation cue must not vanish because the
-- player turned effects down to hear the boss.
local function playCueSound()
  local id = FX.sound and soundID(FX.sound)
  if id then PlaySound(id, "Master") end
end

-- Decorate whatever `R:Draw` just drew.  `activeKeys` = the handles carrying a cue this
-- frame; everything else gets its FX hidden and (if it just dropped) a ghost.
-- `newOnly` limits the pop + sound to RISING EDGES, so a static fixture redraw doesn't
-- re-trigger and `rotate` fires exactly once per hop.
local function applyFX(renderer, activeKeys, newOnly)
  local fired = false
  for key in pairs(activeKeys) do
    local anchor = renderer.registry[key]
    local dot    = renderer.cueFrames[key]
    local glow   = renderer.cueGlows[key]
    if anchor and dot then
      local holder = fxHolder(key, anchor)
      local ring   = (glow and glow:GetWidth() or 0)
      if ring <= 0 then ring = dot:GetWidth() * 2.3 end
      -- 1. BACKING DISC
      local bg = FX.bgs[key]
      if FX.bg then
        if not bg then bg = ensureDisc(holder, "BACKGROUND"); FX.bgs[key] = bg end
        bg:SetColorTexture(0, 0, 0, FX.bgAlpha)
        sizeDisc(bg, ring * FX.bgScale, dot)
        bg:Show()
      elseif bg then
        bg:Hide()
      end
      -- 2. GLOW STACK — extra additive copies of the live ring, in phase.
      local copies = FX.stacks[key] or {}
      FX.stacks[key] = copies
      local want = math.max(0, FX.stack - 1)
      for i = 1, want do
        local c = copies[i]
        if not c then
          c = holder:CreateTexture(nil, "ARTWORK")
          c:SetBlendMode("ADD")
          local sg = c:CreateAnimationGroup()
          local rot = sg:CreateAnimation("Rotation")
          rot:SetDegrees(-360); rot:SetDuration(4.0); rot:SetOrigin("CENTER", 0, 0); rot:SetOrder(1)
          sg:SetLooping("REPEAT")
          c._spin = sg
          copies[i] = c
        end
        if glow then
          local atlas = glow.GetAtlas and glow:GetAtlas()
          if atlas then c:SetAtlas(atlas) end
          local r, g2, b = glow:GetVertexColor()
          c:SetVertexColor(r or 1, g2 or 1, b or 1, 1)
          c:SetSize(ring, ring)
          c:ClearAllPoints()
          c:SetPoint("CENTER", glow, "CENTER", 0, 0)
          c:Show()
          if not c._spinOn then c._spin:Play(); c._spinOn = true end
        end
      end
      for i = want + 1, #copies do copies[i]:Hide() end
      -- 3 + 4. POP + SOUND, rising edge only.
      local rising = not (newOnly and FX.lastOn[key])
      if rising then
        if FX.pop then
          playPop(dot, FX.peak, FX.secs)
          playPop(glow, FX.peak, FX.secs)
          if FX.bg and bg then playPop(bg, FX.peak, FX.secs) end
          for i = 1, want do playPop(copies[i], FX.peak, FX.secs) end
        end
        if not fired then playCueSound(); fired = true end
      end
    end
  end
  -- Dropped handles: hide our chrome, and play the removal ghost.
  for key in pairs(FX.lastOn) do
    if not activeKeys[key] then
      if FX.bgs[key] then FX.bgs[key]:Hide() end
      for _, c in ipairs(FX.stacks[key] or {}) do c:Hide() end
      if FX.ghost then
        local anchor = renderer.registry[key]
        local glow   = renderer.cueGlows[key]
        if anchor and glow then
          playGhost(key, fxHolder(key, anchor), glow, glow:GetWidth())
        end
      end
    end
  end
  FX.lastOn = {}
  for key in pairs(activeKeys) do FX.lastOn[key] = true end
end

local function clearFX()
  for _, t in pairs(FX.bgs) do t:Hide() end
  for _, list in pairs(FX.stacks) do for _, c in ipairs(list) do c:Hide() end end
  for _, t in pairs(FX.ghosts) do t:Hide() end
  FX.lastOn = {}
end

-- Which handles a DrawList cues — the same set R:drawCues considers active, recomputed
-- here rather than returned, so the Renderer needs no FX-shaped hole in its API.
local function cuedKeys(drawList, renderer)
  local set = {}
  for _, c in ipairs((drawList and drawList.cues) or {}) do
    if c.anchorTo ~= nil and renderer.registry[c.anchorTo] then set[c.anchorTo] = true end
  end
  return set
end

local function fxStatus()
  ns.Heading("rt fx — experimental cue treatments")
  ns.Printf("  bg    |cffffffff%s|r  (alpha %.2f, %.2fx the ring)",
    FX.bg and "|cff88ff88on|r" or "off", FX.bgAlpha, FX.bgScale)
  ns.Printf("  glow  |cffffffffx%d|r  (%d additive cop%s stacked on the live ring)",
    FX.stack, FX.stack - 1, FX.stack == 2 and "y" or "ies")
  ns.Printf("  pop   |cffffffff%s|r  ghost |cffffffff%s|r  (peak %.1fx over %.2fs)",
    FX.pop and "on" or "off", FX.ghost and "on" or "off", FX.peak, FX.secs)
  local s = FX.sound and SOUNDS[FX.sound]
  ns.Printf("  sound |cffffffff%s|r", s and (s[1] .. " — " .. s[2]) or "off")
end

--------------------------------------------------------------------------------
-- ROTATE — a live demo: 5 CDM panels, one press cue hopping between them on a
-- timer.  Shows the diff-by-key movement (the old handle's dot + glow drop as the
-- new one lights) and the glow tracking the dot across icons.  A C_Timer ticker,
-- so it needs stopping when the view changes or clears (unlike the static fixtures).
-- It is ALSO the FX test bed: a hop is one application + one removal per tick, which is
-- the only thing that exercises `pop` / `ghost` / `sound` the way live play would.
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
    -- newOnly = true: the hop is a genuine rising edge, so pop + sound fire once per
    -- tick rather than once per redraw.
    applyFX(rig.renderer, cuedKeys(dl, rig.renderer), true)
  end
  step()                                     -- light the first one immediately
  ns._renderTestTicker = C_Timer.NewTicker(ROTATE_INTERVAL, step)
end

-- `/cdmp rt fx <knob> …` — set an experimental knob, then REDRAW the fx view so the
-- change is on screen immediately (a knob you have to re-render by hand gets dialled by
-- guesswork).  Returns true if it handled the input.
local drawFxView   -- forward decl: the knobs redraw, the view applies the knobs

local function fxCommand(words)
  local verb, a1 = words[2], words[3]
  if verb == nil or verb == "status" then
    fxStatus()
    if verb == nil then drawFxView() end
    return true
  end
  if verb == "bg" then
    if a1 then FX.bgAlpha = tonumber(a1) or FX.bgAlpha; FX.bg = FX.bgAlpha > 0
    else FX.bg = not FX.bg end
  elseif verb == "glow" then
    FX.stack = math.max(1, math.min(4, math.floor(tonumber(a1 or "") or (FX.stack + 1))))
    if not a1 and FX.stack >= 4 then FX.stack = 1 end   -- bare `glow` cycles 1..4
  elseif verb == "pop" then
    if a1 then FX.peak = tonumber(a1) or FX.peak; FX.pop = true else FX.pop = not FX.pop end
  elseif verb == "ghost" then
    FX.ghost = not FX.ghost
  elseif verb == "sound" then
    if a1 == "off" then
      FX.sound = nil
    elseif a1 == "list" then
      ns.Heading("rt fx sound — the audition list")
      for i, e in ipairs(SOUNDS) do
        local id = soundID(i)
        ns.Printf("  %d. |cffffffff%s|r — %s %s", i, e[1], e[2],
          id and ("|cff88ff88[" .. id .. "]|r") or "|cffff4040[absent]|r")
      end
      ns.Print("usage: |cffffffff/cdmp rt fx sound|r (next) | <n> | off | list")
      return true
    elseif tonumber(a1) then
      FX.sound = math.max(1, math.min(#SOUNDS, math.floor(tonumber(a1))))
    else
      FX.sound = (FX.sound or 0) % #SOUNDS + 1          -- bare `sound` = audition the next
    end
    local e = FX.sound and SOUNDS[FX.sound]
    if e and not soundID(FX.sound) then
      ns.Printf("|cffff4040%s is not in SOUNDKIT on this build|r — try another", e[1])
    end
    playCueSound()                                       -- hear it right now
    ns.Printf("rt fx sound: |cffffffff%s|r",
      e and (FX.sound .. ". " .. e[1] .. " — " .. e[2]) or "off")
    return true
  else
    ns.Heading("rt fx — experimental cue treatments")
    ns.Print("  |cff88ff88bg|r [alpha]     black backing disc under dot + ring (contrast)")
    ns.Print("  |cff88ff88glow|r [1-4]     additive ring copies — 2 = literally doubled")
    ns.Print("  |cff88ff88pop|r [peak]     one-shot scale on cue APPLICATION")
    ns.Print("  |cff88ff88ghost|r          one-shot scale+fade on cue REMOVAL")
    ns.Print("  |cff88ff88sound|r [n|off|list]  audition a cue SFX (bare = next)")
    ns.Print("  |cff88ff88status|r         print the current settings")
    ns.Print("pop/ghost/sound need a rising edge — watch them on |cffffffff/cdmp rt rotate|r")
    return true
  end
  fxStatus()
  drawFxView()
  return true
end

-- The `fx` VIEW: the same `states` palette, redrawn with the FX layer on top.  Sharing
-- the fixture is the point — `/cdmp rt states` is then a pixel-exact A/B baseline for
-- whatever the knobs are currently doing.  Every knob DEFAULTS OFF, so a first
-- `/cdmp rt fx` is deliberately identical to `/cdmp rt states`: each effect has to be
-- turned on one at a time or you cannot tell which one bought the improvement.
drawFxView = function()
  local base = FIXTURES["states"]
  local rig = buildRig(base.icons, base.captions)
  rig.container:Show()
  rig.renderer:Draw(base.drawList)
  applyProcGlow(rig, base.procGlow)
  -- newOnly = false: a static view has no rising edge, so re-running the command is how
  -- you replay the pop.
  applyFX(rig.renderer, cuedKeys(base.drawList, rig.renderer), false)
end

-- `/cdmp rt [<name>|fx|rotate|off|list]` — render a fixture; bare = the first one
-- (`states`, the reference card).
function ns.RenderTest(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  local words = {}
  for w in arg:gmatch("%S+") do words[#words + 1] = w end
  if arg == "list" then
    ns.Heading("rt — render-test views")
    ns.Print("  |cff88ff88states|r — every cue state + the native proc glow, gold & recolored (default)")
    for _, name in ipairs(FIXTURE_ORDER) do
      if name ~= "states" then ns.Printf("  |cff88ff88%s|r", name) end
    end
    ns.Print("  |cff88ff88rotate|r — one cue hopping across 5 panels (live)")
    ns.Print("  |cff88ff88fx|r — the states card + the EXPERIMENTAL treatments (`rt fx` for knobs)")
    ns.Print("usage: |cffffffff/cdmp rt <name>|r | fx | rotate | off")
    return
  end
  stopRotate()                               -- any view change cancels a live rotate
  clearProcGlow()                            -- ...and drops any native proc glow
  if words[1] == "fx" then return fxCommand(words) end
  clearFX()                                  -- ...and any experimental chrome
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
