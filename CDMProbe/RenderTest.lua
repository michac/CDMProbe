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
  -- ⚠ MEASURED AGAINST THE RING'S TEXTURE BOUNDS, WHICH IS WHY IT LOOKS TOO BIG.
  -- 1.0 = the full quad the ring atlas is drawn into.  But `services-ring-large-glowspin`
  -- does not fill its own quad: the art has transparent padding and its rays fade out well
  -- before the edge, so a disc sized to the QUAD is visibly larger than the light it is
  -- backing.  The first cut compounded that by adding another 15 %.  There is no API that
  -- reports where the art's visible energy actually ends, so this is an eyeball constant —
  -- `bg size <n>` is the dial, and going BELOW 1.0 is expected, not a mistake.
  bgScale = 0.85,   -- diameter relative to the ring's TEXTURE BOUNDS
  -- RAYS WITHOUT BRIGHTNESS (`rays <n>`).  An OUTER ECHO of the same ring at n x the
  -- diameter, drawn additively like the base one — so the ray structure reads as extending
  -- further out.  ⚠ Additive light STACKS, so a naive echo just makes it brighter, which is
  -- exactly what was asked against.  The alpha of both the base and the echo is therefore
  -- split (see echoAlpha) so total added light stays roughly flat and only the REACH grows.
  -- Multipliers on the Renderer's per-emphasis ring size / spin period.  See the long
  -- note at their use site: LATE already runs 1.4x bigger and 2.5x faster than every other
  -- emphasis, which is why one sprite can look right there and flat everywhere else.
  scale     = 1.0,  -- ring diameter multiplier (base GLOW_SCALE is 2.3)
  spinMul   = 1.0,  -- spin PERIOD multiplier; <1 = faster (base SPIN_SECS is 4.0)
  rays      = 1.0,  -- echo diameter multiplier; 1.0 = no echo
  raysAlpha = 0.55, -- the echo's share of the light
  art       = nil,  -- index into GLOW_ART; nil = whatever Renderer.lua's GLOW_ATLAS is
  stack   = 1,      -- additive glow copies: 1 = stock, 2 = "doubled"
  pop     = false,  -- one-shot scale on application
  ghost   = false,  -- one-shot scale+fade on removal
  peak    = 2.0,    -- pop/ghost peak scale ("double in size")
  secs    = 0.28,   -- pop duration
  sound   = nil,    -- index into SOUNDS (the stepper's position); nil = not from the list
  soundID = nil,    -- the numeric SoundKit id actually played; nil + no file = silent
  soundFile = nil,  -- ...or a file path, played with PlaySoundFile instead
  soundLabel = nil, -- what `status` should call it
  channel = 1,      -- index into SOUND_CHANNELS; the closest thing to a volume dial
  sweep   = 0,      -- position in LOUD_UI while auditioning the loud pool
  -- ONE PLAY IS NOT AUDITIONABLE.  In the world there is always ambient noise, so a
  -- single short UI blip cannot be picked out of it — you hear "something happened", not
  -- WHAT happened.  A short burst of the SAME sound is distinctive in a way one hit is
  -- not: the rhythm is the signature, and it survives a noisy background.  Hence 3 by
  -- default, which is an audition setting -- a shipped cue would use 1.
  rep     = 3,      -- plays per audition
  repGap  = 0.22,   -- seconds between them
  loop    = false,  -- keep replaying until told to stop (listen against live ambience)
  holders = {},     -- key -> our own frame (never culled by the Renderer)
  bgs     = {},     -- key -> backing disc
  stacks  = {},     -- key -> { extra glow copies }
  echoes  = {},     -- key -> the outer ray-echo texture
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

-- CANDIDATE GLOW ATLASES — the OTHER answer to "longer rays".  You cannot stretch a ring
-- radially: a texture is a quad and tex-coords are rectangular, so there is no transform
-- that lengthens the rays while holding the inner radius (sampling a sub-rect just
-- magnifies the hole).  The reach of a ray is baked into the ART.  So either echo the ring
-- outward (`rays`) or draw DIFFERENT art — this is the list for the second option.
--
-- ⚠ SAME CAVEAT AS THE SOUND LIST: these names are written from knowledge of the atlas
-- set, NOT verified against this build.  `C_Texture.GetAtlasInfo` returns nil for a name
-- that does not exist, so `atlas list` validates them in-game and reports each as
-- present/absent — the same resolve-and-report-absent shape the sound list uses, for the
-- same reason (a silently-wrong atlas would just show nothing and read as "no improvement").
local MEDIA = "Interface\\AddOns\\CDMProbe\\Media\\fx\\"

-- GLOW_ART — every candidate ring, Blizzard's and ours, behind ONE index.  Two kinds:
--   `atlas`  a Blizzard atlas name  -> SetAtlas.  Free, but we take the art as it is.
--   `file`   a TGA we ship          -> SetTexture.  See Media/fx/CREDITS.md.
--
-- WHY SHIPPING OUR OWN IS THE STRONGER ANSWER, not merely another option.  SetVertexColor
-- MULTIPLIES, so a tint can only ever remove energy the art already has.  Blizzard's
-- `services-ring-large-glowspin` is GOLD — mostly red+green — so our violet
-- ROTATION_FALLBACK (green channel 0.16) multiplies most of it away, which is a real part
-- of why the fallback reads dim.  The Kenney sprites are WHITE/GREY with the shape carried
-- in alpha, so every hue tints at full strength.  That is a property no amount of dialling
-- the Blizzard atlas can buy.
local GLOW_ART = {
  -- Blizzard atlases — names written from knowledge of the atlas set, NOT verified against
  -- this build.  `C_Texture.GetAtlasInfo` validates them, so `art list` reports each
  -- present/absent rather than letting a typo read as "that one looks bad".
  { kind = "atlas", id = "services-ring-large-glowspin", label = "Blizz ring (Renderer's stock)" },
  { kind = "atlas", id = "services-ring-small-glowspin", label = "Blizz ring, tighter" },
  { kind = "atlas", id = "ChallengeMode-RingGlow",       label = "Blizz M+ keystone ring" },
  { kind = "atlas", id = "Artifacts-StarGlow",           label = "Blizz star burst" },
  -- Ours (CC0, Kenney).  These EXIST by construction — they are in the addon folder.
  { kind = "file",  id = MEDIA .. "glow\\twirl_01.tga",  label = "Kenney twirl 01 — spiral" },
  { kind = "file",  id = MEDIA .. "glow\\twirl_03.tga",  label = "Kenney twirl 03 — dense spiral" },
  { kind = "file",  id = MEDIA .. "glow\\star_04.tga",   label = "Kenney star 04 — LONG spokes" },
  { kind = "file",  id = MEDIA .. "glow\\star_07.tga",   label = "Kenney star 07 — long, sparse" },
  { kind = "file",  id = MEDIA .. "glow\\star_09.tga",   label = "Kenney star 09 — many spokes" },
  { kind = "file",  id = MEDIA .. "glow\\flare_01.tga",  label = "Kenney flare 01 — cross flare" },
  { kind = "file",  id = MEDIA .. "glow\\magic_05.tga",  label = "Kenney magic 05 — ring + rays" },
  { kind = "file",  id = MEDIA .. "glow\\light_01.tga",  label = "Kenney light 01 — soft (control)" },
}

-- nil = "cannot check" (a file, or no atlas API), true/false for an atlas we probed.
local function artExists(e)
  if not e then return nil end
  if e.kind == "file" then return nil end
  if not (C_Texture and C_Texture.GetAtlasInfo) then return nil end
  return C_Texture.GetAtlasInfo(e.id) ~= nil
end

local function applyArt(tex, i)
  local e = GLOW_ART[i]
  if not (tex and e) then return false end
  if e.kind == "file" then tex:SetTexture(e.id) else tex:SetAtlas(e.id) end
  return true
end

-- Dress a COPY (stack / echo / ghost) in the same art as the base ring.  Handles both
-- kinds: with no override we mirror whatever the Renderer put there, which may now be a
-- file — so GetAtlas alone is not enough and GetTexture is the fallback read.
local function mirrorArt(dst, src)
  if FX.art then applyArt(dst, FX.art); return end
  local a = src and src.GetAtlas and src:GetAtlas()
  if a then dst:SetAtlas(a); return end
  local t = src and src.GetTexture and src:GetTexture()
  if t then dst:SetTexture(t) end
end

-- Split the light between the base ring and its echo so adding REACH does not add
-- BRIGHTNESS.  With no echo the base keeps all of it.
local function echoAlpha()
  if FX.rays <= 1.0 then return 1.0, 0 end
  return 1.0 - FX.raysAlpha, FX.raysAlpha
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
  mirrorArt(t, glow)
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

-- ⚠ THE LIST IS A STARTING POINT, NOT A VERIFIED SET.  These names were written from
-- memory of the WoW API; only `MAP_PING` is corroborated against Blizzard source
-- (knowledge/addon-dev/api-events-and-discovery.md:366 ->
-- Blizzard_Minimap/Mainline/Minimap.lua:150).  They CANNOT be verified offline: the
-- `SoundKit` DB2 carries 333,671 ids and NO name column, and there is no `SoundKitName`
-- table at all — the names exist only in FrameXML's hand-maintained constants file.  So
-- resolution happens through SOUNDKIT BY NAME at call time and reports `[absent]` when a
-- name is not there; `rt fx sound list` in-game IS the verification step.
--
-- AND THE LIST IS NOT THE LIMIT.  `sound id <n>` reaches any of those 333,671 kits
-- directly (SOUNDKIT is just named constants over a small slice of that space), and
-- `sound file <path>` plays any sound file — including one we ship ourselves, the way
-- Media/JetBrainsMono.ttf is already shipped.
-- OUR OWN FILES COME FIRST, deliberately.  They are the answer to "too subtle": Kenney
-- normalises that pack's volume, and since WoW has NO volume API (below), a file that is
-- already loud is the only real gain control there is.  They are also the only entries
-- here that are VERIFIED — a shipped file exists by construction, whereas every SOUNDKIT
-- name below is a guess that may resolve to nothing.  See Media/fx/CREDITS.md.
local SOUNDS = {
  { kind = "file", id = MEDIA .. "sfx\\confirmation_001.ogg", label = "Kenney confirm 01 — the 'activated!' pick" },
  { kind = "file", id = MEDIA .. "sfx\\confirmation_002.ogg", label = "Kenney confirm 02 — brighter" },
  { kind = "file", id = MEDIA .. "sfx\\confirmation_003.ogg", label = "Kenney confirm 03 — two-tone" },
  { kind = "file", id = MEDIA .. "sfx\\confirmation_004.ogg", label = "Kenney confirm 04 — longest" },
  { kind = "file", id = MEDIA .. "sfx\\bong_001.ogg",         label = "Kenney bong — soft mallet" },
  { kind = "file", id = MEDIA .. "sfx\\select_001.ogg",       label = "Kenney select 01 — dry blip" },
  { kind = "file", id = MEDIA .. "sfx\\select_004.ogg",       label = "Kenney select 04 — sharper" },
  { kind = "file", id = MEDIA .. "sfx\\question_001.ogg",     label = "Kenney question — rising" },
  { kind = "kit",  id = "UI_POWER_AURA_GENERIC",          label = "power-aura ping (the classic proc ding)" },
  { kind = "kit",  id = "IG_MAINMENU_OPTION_CHECKBOX_ON", label = "checkbox tick (dry, very short)" },
  { kind = "kit",  id = "IG_QUEST_LIST_SELECT",           label = "quest-list select (soft click)" },
  { kind = "kit",  id = "UI_TOYBOX_TAB",                  label = "toybox tab (woody tap)" },
  { kind = "kit",  id = "UI_TRANSMOG_ITEM_CLICK",         label = "transmog click (crisp)" },
  { kind = "kit",  id = "UI_AUTO_QUEST_COMPLETE",         label = "auto-quest complete (chime)" },
  { kind = "kit",  id = "MAP_PING",                       label = "map ping (locator blip)" },
  { kind = "kit",  id = "GS_TITLE_OPTION_OK",             label = "title-screen OK (thunk)" },
  { kind = "kit",  id = "UI_RAID_BOSS_WHISPER_WARNING",   label = "boss whisper (attention-grabber)" },
}

-- -> (kitID, filePath).  Exactly one is non-nil for a resolvable entry; BOTH nil means a
-- SOUNDKIT name that is not on this build, which is a reportable state, not a crash.
local function soundSrc(i)
  local e = SOUNDS[i]
  if not e then return nil, nil end
  if e.kind == "file" then return nil, e.id end
  return (SOUNDKIT and SOUNDKIT[e.id]) or nil, nil
end

local function soundLabel(i)
  local e = SOUNDS[i]
  return e and string.format("%d. %s", i, e.label) or "off"
end

-- ⚠ THERE IS NO VOLUME PARAMETER.  `PlaySound(kitID, channel, forceNoDuplicates,
-- runFinishCallback)` and `PlaySoundFile(fileOrID, channel)` are the whole surface — an
-- addon cannot scale one sound's amplitude.  So "too subtle" has exactly three honest
-- answers, and this table plus the `channel` knob are two of them:
--
--   1. CHANNEL.  Each channel is governed by its own volume slider, so the lever is
--      picking one the player keeps up.  "Master" is the default here because it answers
--      only to master volume — the slider least likely to be turned down — but Dialog is
--      worth trying, since many players keep it high for quest VO.
--   2. A LOUDER KIT (this table).
--   3. SHIP OUR OWN FILE and normalise it hot.  The only route with real gain control,
--      and the one a shipped feature should take — `sound file <path>` already plays it,
--      and Media/ already ships the JetBrains font, so the path pattern is proven.
--
-- Deliberately NOT a fourth option: driving Sound_MasterVolume / Sound_SFXVolume by CVar.
-- It would change the player's global settings for every sound in the game, and restoring
-- it races the async playback.  Not acceptable in a shipped cue, so not offered as a dial.
--
-- LOUD_UI — the 235 SoundKit ids that are BOTH SoundType 2 (UI) AND VolumeFloat 1.0, the
-- maximum authored volume, mined from the live `SoundKit` DB2 (12.0.7, wago.tools ->
-- raw/wago/SoundKit.csv; most kits sit at 0.8).  VolumeFloat is not readable from Lua, so
-- this pool cannot be computed in-game — it is precomputed data, and that provenance is
-- the point: every id here is VERIFIED TO EXIST at max volume, unlike the SOUNDS names
-- above, which are guesses.  What each one SOUNDS like is still unknown; `sound sweep`
-- is how you find out, one keystroke per id.
local SOUND_CHANNELS = { "Master", "SFX", "Dialog", "Ambience", "Music" }
local LOUD_UI = {
  62, 63, 65, 67, 68, 69, 72, 73, 75, 76, 77, 78,
  79, 92, 93, 95, 96, 98, 99, 100, 101, 102, 103, 104,
  105, 106, 121, 122, 123, 600, 602, 618, 619, 624, 688, 689,
  1519, 3081, 3407, 4140, 4141, 4142, 4143, 4144, 4145, 4146, 4147, 8960,
  20682, 20683, 31750, 33338, 34039, 34090, 34092, 34094, 37656, 37676, 38322, 38323,
  38352, 38600, 39516, 39517, 39672, 39673, 43936, 50111, 51401, 71946, 74438, 89740,
  89745, 89878, 89880, 89881, 113811, 113812, 113813, 114779, 114780, 118563, 119143, 129053,
  137388, 138462, 145770, 148843, 148949, 161480, 161482, 161483, 161484, 161548, 161626, 161627,
  161628, 161629, 161632, 161634, 161635, 161636, 161637, 161638, 161639, 161662, 161693, 161736,
  161738, 161761, 161769, 161770, 161781, 161782, 161783, 161784, 161785, 161786, 161787, 161789,
  161790, 161862, 161886, 161889, 161890, 161891, 161892, 161895, 161903, 161904, 161905, 161906,
  161907, 161908, 161909, 161910, 161914, 161915, 161920, 161932, 162016, 162017, 162018, 162019,
  162020, 162045, 162046, 162049, 162054, 162095, 162096, 162097, 162101, 162102, 162105, 162133,
  162134, 162136, 162137, 162138, 162139, 162744, 162745, 162746, 162749, 162786, 162787, 162788,
  162789, 162842, 162845, 162846, 162848, 162849, 166317, 166318, 166339, 166342, 166523, 167144,
  167145, 167148, 167149, 168216, 168711, 169304, 170271, 170833, 171876, 171877, 171878, 171904,
  173477, 173579, 173584, 177781, 182865, 191353, 191354, 194683, 196240, 210036, 216079, 217032,
  217036, 217039, 217041, 219575, 219930, 232474, 232768, 232769, 237252, 237995, 254765, 258819,
  277765, 286126, 286127, 287233, 287347, 292692, 292693, 293831, 309134, 311462, 317877, 323116,
  325765, 326551, 331151, 331630, 333050, 359673, 361444,
}

-- "Master" rather than "SFX" on purpose: a rotation cue must not vanish because the
-- player turned effects down to hear the boss.
--
-- ⚠ RETURNS `willPlay` — AND THAT IS THE WHOLE POINT.  Both PlaySound and PlaySoundFile
-- hand back (willPlay, soundHandle), so "I hear nothing" has a machine answer instead of
-- a guess: nothing selected / name not in SOUNDKIT / the client refused the request /
-- it played and the problem is elsewhere (volume, channel, muted).  Reported by
-- `sound test`.  Silence with no readout is the failure mode this experiment cannot
-- afford, because every one of those four causes looks identical from the chair.
local function playCueSound()
  local ch = SOUND_CHANNELS[FX.channel] or "Master"
  if FX.soundFile then return PlaySoundFile(FX.soundFile, ch) end
  if FX.soundID then return PlaySound(FX.soundID, ch) end
  return nil
end

-- Point the cue sound at a list entry / a raw kit id / a file, and label it for `status`.
-- Defined up here because the audition panel's sweepTo calls it — keep it above that.
local function selectSound(idx, id, file, label)
  FX.sound, FX.soundID, FX.soundFile, FX.soundLabel = idx, id, file, label
end

-- A BURST of the current sound: `rep` plays spaced `repGap` apart.  Returns the FIRST
-- play's willPlay so callers keep their diagnostic signal.  C_Timer.After rather than a
-- ticker — a burst is finite and must not need cancelling.
local function playCueBurst()
  local willPlay = playCueSound()
  for i = 2, FX.rep do
    C_Timer.After((i - 1) * FX.repGap, playCueSound)
  end
  return willPlay
end

-- LOOP — replay the burst on a ticker, so you can sit in the world and pick the sound out
-- of whatever is going on around you rather than judging it from one pass.  Cancelled by
-- any view change (`rt off`, another fixture) as well as by toggling it off, because a
-- sound still firing after you cleared the render test is the rig outliving its view.
local function stopSoundLoop()
  if ns._renderTestSoundTicker then
    ns._renderTestSoundTicker:Cancel()
    ns._renderTestSoundTicker = nil
  end
  FX.loop = false
end

local function startSoundLoop()
  stopSoundLoop()
  FX.loop = true
  local period = math.max(1.0, FX.rep * FX.repGap + 0.9)
  playCueBurst()
  ns._renderTestSoundTicker = C_Timer.NewTicker(period, playCueBurst)
end

--------------------------------------------------------------------------------
-- The AUDITION PANEL — 235 candidates is a CLICKING job, not a typing one.
--------------------------------------------------------------------------------
-- `/cdmp rt fx sound sweep` is 24 characters to advance ONE step through a 235-entry
-- pool.  That is not a usable audition loop however good the pool is: the interaction
-- cost swamps the thing being tested, and you end up judging "can I face another one"
-- rather than "does this cut through".  So the pool gets a mouse — prev / replay / next /
-- loop as buttons, with the id and position on screen.  The slash verbs all still work;
-- this just makes the common one free.
-- EVERY knob is a button, not just the sound.  The sound sweep proved the point in the
-- small — `/cdmp rt fx sound sweep` is 24 characters to advance ONE of 235 candidates, so
-- the interaction cost swamped the judgement — but the same is true of `bg size 0.7` and
-- `rays 1.5` and `art 7`.  A visual experiment you drive by typing is one you stop running
-- before you have found the answer.  So: one draggable panel, a row per knob, live values,
-- and every click redraws the view immediately.  The slash verbs all still work and both
-- routes share the SAME setters, so they cannot drift.
local PANEL_W, ROW_H2, BTN_H = 348, 24, 20
local sweepTo       -- fwd: buttons drive it
local drawFxView    -- fwd: every click redraws the view (defined with the fx view below)

local function updatePanel()
  local p = ns._renderTestFxPanel
  if not p then return end
  p.bgVal:SetText(FX.bg and string.format("|cff88ff88on|r  a%.2f s%.2f", FX.bgAlpha, FX.bgScale)
                        or "|cff808080off|r")
  p.glowVal:SetText(string.format("|cffffffffx%d|r", FX.stack))
  p.ringVal:SetText(string.format("size |cffffffff%.2fx|r  spin |cffffffff%.2fx|r%s",
    FX.scale, FX.spinMul,
    (FX.scale == 1.0 and FX.spinMul == 1.0) and "  |cff808080(stock)|r" or ""))
  p.raysVal:SetText(FX.rays > 1.0 and string.format("|cffffffff%.2fx|r @%.0f%%",
                      FX.rays, FX.raysAlpha * 100) or "|cff808080off|r")
  local ae = FX.art and GLOW_ART[FX.art]
  p.artVal:SetText(ae and ("|cffffffff" .. FX.art .. ".|r " .. ae.label) or "|cff808080stock|r")
  p.popVal:SetText(string.format("%s   ghost %s",
    FX.pop and "|cff88ff88on|r" or "|cff808080off|r",
    FX.ghost and "|cff88ff88on|r" or "|cff808080off|r"))
  p.sndVal:SetText(FX.soundLabel and ("|cffffffff" .. FX.soundLabel .. "|r")
                                  or "|cffff8080off|r")
  p.sweepVal:SetText(string.format("%s  |cff88ff88%s|r  x%d  %s",
    SOUND_CHANNELS[FX.channel] or "Master",
    FX.sweep > 0 and (FX.sweep .. "/" .. #LOUD_UI) or "-", FX.rep,
    FX.loop and "|cff88ff88LOOP|r" or ""))
  p.loopBtn:SetText(FX.loop and "stop" or "loop")
end

-- Apply a change, refresh the readout, and REDRAW so the eye sees it at once.  Every
-- button goes through this; a knob you have to re-render by hand gets dialled by guesswork.
local function bump(fn)
  return function()
    fn()
    updatePanel()
    if drawFxView then drawFxView() end
  end
end

local function ensureFxPanel()
  local p = ns._renderTestFxPanel
  if p then return p end
  local rows = 8
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetSize(PANEL_W, 34 + rows * ROW_H2 + 30)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, -190)
  f:SetFrameStrata("DIALOG")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  bg:SetColorTexture(0.04, 0.05, 0.06, 0.93)
  local edge = f:CreateTexture(nil, "BORDER")
  edge:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
  edge:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1, -1)
  edge:SetColorTexture(0.30, 1.00, 0.48, 0.55)

  local title = f:CreateFontString(nil, "OVERLAY")
  ns.SetFont(title, 13, "OUTLINE")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -9)
  title:SetText("|cff88ff88rt fx|r — experiment panel  |cff808080(drag to move)|r")

  local function btn(label, w, x, y, onClick)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(w, BTN_H)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
  end
  local function label(text, y)
    local fs = f:CreateFontString(nil, "OVERLAY")
    ns.SetFont(fs, 11, "")
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y - 4)
    fs:SetText(text)
    return fs
  end
  local function value(y)
    local fs = f:CreateFontString(nil, "OVERLAY")
    ns.SetFont(fs, 11, "")
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", 196, y - 4)
    fs:SetWidth(PANEL_W - 204)
    fs:SetJustifyH("LEFT")
    return fs
  end

  local y = -32
  -- bg
  label("bg", y); btn("on/off", 46, 40, y, bump(function() FX.bg = not FX.bg end))
  btn("-", 24, 90, y, bump(function() FX.bgScale = math.max(0.3, FX.bgScale - 0.05); FX.bg = true end))
  btn("+", 24, 116, y, bump(function() FX.bgScale = math.min(2.5, FX.bgScale + 0.05); FX.bg = true end))
  btn("a", 24, 146, y, bump(function()
    FX.bgAlpha = FX.bgAlpha >= 1.0 and 0.25 or math.min(1.0, FX.bgAlpha + 0.25); FX.bg = true
  end))
  local bgVal = value(y)
  -- glow (brightness)
  y = y - ROW_H2
  label("glow", y)
  btn("-", 24, 40, y, bump(function() FX.stack = math.max(1, FX.stack - 1) end))
  btn("+", 24, 66, y, bump(function() FX.stack = math.min(4, FX.stack + 1) end))
  local glowVal = value(y)
  -- ring size + spin speed (the LATE-vs-rest lever)
  y = y - ROW_H2
  label("ring", y)
  btn("-", 24, 40, y, bump(function() FX.scale = math.max(0.5, FX.scale - 0.15) end))
  btn("+", 24, 66, y, bump(function() FX.scale = math.min(3.0, FX.scale + 0.15) end))
  btn("slow", 40, 96, y, bump(function() FX.spinMul = math.min(3.0, FX.spinMul + 0.25) end))
  btn("fast", 40, 140, y, bump(function() FX.spinMul = math.max(0.2, FX.spinMul - 0.25) end))
  local ringVal = value(y)
  -- rays (reach)
  y = y - ROW_H2
  label("rays", y)
  btn("-", 24, 40, y, bump(function() FX.rays = math.max(1.0, FX.rays - 0.25) end))
  btn("+", 24, 66, y, bump(function() FX.rays = math.min(4.0, FX.rays + 0.25) end))
  btn("a", 24, 96, y, bump(function()
    FX.raysAlpha = FX.raysAlpha >= 0.8 and 0.2 or FX.raysAlpha + 0.15
  end))
  local raysVal = value(y)
  -- art
  y = y - ROW_H2
  label("art", y)
  btn("<", 24, 40, y, bump(function()
    FX.art = ((FX.art or 1) - 2) % #GLOW_ART + 1
  end))
  btn(">", 24, 66, y, bump(function() FX.art = (FX.art or 0) % #GLOW_ART + 1 end))
  btn("stock", 46, 96, y, bump(function() FX.art = nil end))
  local artVal = value(y)
  -- pop / ghost
  y = y - ROW_H2
  label("pop", y)
  btn("pop", 40, 40, y, bump(function() FX.pop = not FX.pop end))
  btn("ghost", 46, 84, y, bump(function() FX.ghost = not FX.ghost end))
  btn("peak", 40, 134, y, bump(function()
    FX.peak = FX.peak >= 3.0 and 1.5 or FX.peak + 0.5; FX.pop = true
  end))
  local popVal = value(y)
  -- sound: the curated list (ours first)
  y = y - ROW_H2
  label("sound", y)
  btn("<", 24, 40, y, function()
    local i = ((FX.sound or 1) - 2) % #SOUNDS + 1
    local kit, file = soundSrc(i); selectSound(i, kit, file, soundLabel(i))
    playCueBurst(); updatePanel()
  end)
  btn("play", 40, 66, y, function() playCueBurst(); updatePanel() end)
  btn(">", 24, 110, y, function()
    local i = (FX.sound or 0) % #SOUNDS + 1
    local kit, file = soundSrc(i); selectSound(i, kit, file, soundLabel(i))
    playCueBurst(); updatePanel()
  end)
  local loopBtn = btn("loop", 40, 140, y, function()
    if FX.loop then stopSoundLoop() else startSoundLoop() end
    updatePanel()
  end)
  local sndVal = value(y)
  -- sweep the raw loud pool + channel
  y = y - ROW_H2
  label("sweep", y)
  btn("<", 24, 40, y, function() sweepTo(FX.sweep - 1) end)
  btn(">", 24, 66, y, function() sweepTo(FX.sweep + 1) end)
  btn("chan", 40, 96, y, function()
    FX.channel = FX.channel % #SOUND_CHANNELS + 1; playCueBurst(); updatePanel()
  end)
  btn("x3", 26, 140, y, function()
    FX.rep = FX.rep >= 5 and 1 or FX.rep + 2; playCueBurst(); updatePanel()
  end)
  local sweepVal = value(y)
  -- footer
  y = y - ROW_H2 - 4
  btn("reset all", 70, 10, y, bump(function()
    FX.bg, FX.bgAlpha, FX.bgScale = false, 0.75, 0.85
    FX.stack, FX.rays, FX.raysAlpha, FX.art = 1, 1.0, 0.55, nil
    FX.scale, FX.spinMul = 1.0, 1.0
    FX.pop, FX.ghost, FX.peak = false, false, 2.0
    stopSoundLoop(); selectSound(nil, nil, nil, nil)
  end))
  btn("close", 60, 86, y, function() stopSoundLoop(); f:Hide() end)

  p = { frame = f, bgVal = bgVal, glowVal = glowVal, ringVal = ringVal,
        raysVal = raysVal, artVal = artVal,
        popVal = popVal, sndVal = sndVal, sweepVal = sweepVal, loopBtn = loopBtn }
  ns._renderTestFxPanel = p
  return p
end

-- Move to an absolute LOUD_UI position (wrapping), select it, play it, refresh.  THE ONE
-- DOOR for advancing the raw pool: the slash verb and both buttons route through it.
sweepTo = function(pos)
  FX.sweep = ((pos - 1) % #LOUD_UI) + 1
  local id = LOUD_UI[FX.sweep]
  selectSound(nil, id, nil, string.format("SoundKit id %d (loud pool %d/%d)",
    id, FX.sweep, #LOUD_UI))
  local willPlay
  if FX.loop then startSoundLoop()          -- re-arms on the NEW sound, and plays it
  else willPlay = playCueBurst() end
  updatePanel()
  return id, willPlay
end

-- The `I hear nothing` decision tree, answered in one line each.
local function soundDiagnose()
  ns.Heading("rt fx sound — diagnosis")
  ns.Printf("  SOUNDKIT table   %s",
    SOUNDKIT and "|cff88ff88present|r" or "|cffff4040MISSING (nothing by name can work)|r")
  if not (FX.soundID or FX.soundFile) then
    ns.Print("  selection        |cffff4040NONE — the sound knob defaults OFF|r")
    ns.Print("  |cffffffff=> run /cdmp rt fx sound|r to pick one.  This is the usual answer.")
    return
  end
  ns.Printf("  selection        |cffffffff%s|r", FX.soundLabel or "?")
  if FX.sound and not (FX.soundID or FX.soundFile) then
    ns.Printf("  resolve          |cffff4040'%s' is NOT in SOUNDKIT on this build|r",
      SOUNDS[FX.sound].id)
    ns.Print("  |cffffffff=> try another, or /cdmp rt fx sound id <kitID>|r")
    return
  end
  local willPlay = playCueSound()
  if willPlay == nil then
    ns.Print("  request          |cffff4040the API returned nothing|r")
  elseif willPlay then
    ns.Print("  request          |cff88ff88accepted (willPlay=true) — the client IS playing it|r")
    ns.Print("  |cffffffff=> if you still hear nothing it is volume/mute, not the addon|r")
  else
    ns.Print("  request          |cffff4040REFUSED (willPlay=false) — bad id for this build|r")
    ns.Print("  |cffffffff=> try a different id|r")
  end
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
      -- RING SIZE + SPIN SPEED, as MULTIPLIERS on whatever the Renderer chose.
      --
      -- ⚠ THIS IS WHY ONE ART LOOKS RIGHT ON LATE AND WRONG EVERYWHERE ELSE.  LATE is the
      -- only emphasis carrying per-token overrides (GLOW_SPEC.LATE: ringScale 3.2 vs the
      -- base GLOW_SCALE 2.3, spinSecs 1.6 vs SPIN_SECS 4.0) — so it draws every ring ~1.4x
      -- bigger and spinning 2.5x faster than ROTATION/SOON/FALLBACK do.  Spoked art needs
      -- BOTH: radius, because a spoke's length is what makes it a ray rather than a bump,
      -- and angular speed, because spokes are what let rotation read at all.  At the base
      -- 2.3/4.0 the same sprite is shorter-spoked and turning lazily, and reads as a smudge.
      --
      -- MULTIPLIERS, not absolutes, deliberately: LATE's escalation is a RATIO to the base
      -- (Renderer.lua: "the escalation is 'a bigger ring', not this exact number"), so
      -- scaling both together preserves it.  Dial the base up until ROTATION reads, then
      -- promote the number to GLOW_SCALE / SPIN_SECS rather than shipping it from here.
      --
      -- And note GLOW_SCALE is ART-SPECIFIC: 2.3 was dialled against
      -- services-ring-large-glowspin to close the gap between the dot's rim and THAT
      -- ring's inner edge.  A sprite whose spokes start at a different radius invalidates
      -- the number, so swapping art and re-dialling scale are one job, not two.
      if glow and FX.scale ~= 1.0 then
        ring = ring * FX.scale
        glow:SetSize(ring, ring)
      end
      if glow and glow.rot and glow._spinSecs and FX.spinMul ~= 1.0 then
        -- Re-time only on CHANGE: SetDuration on a playing group restarts it, which would
        -- stutter the ring on every redraw.  Tracked against the PRODUCT, so a per-emphasis
        -- change upstream (LATE's 1.6) re-applies correctly.
        local want = glow._spinSecs * FX.spinMul
        if glow._fxSpin ~= want then
          glow._fxSpin = want
          glow.rot:SetDuration(want)
        end
      end
      local baseA, echoA = echoAlpha()
      local r, g2, b = 1, 1, 1
      if glow then r, g2, b = glow:GetVertexColor() end
      r, g2, b = r or 1, g2 or 1, b or 1
      -- ATLAS OVERRIDE + light split are applied to the RENDERER'S OWN ring.  That is the
      -- one place this layer writes back into the renderer's pool rather than decorating
      -- around it — unavoidable, since "same ring, different art / dimmer" is the
      -- experiment.  `R:Draw` re-asserts atlas-independent state (size, colour, points)
      -- every draw but never re-sets the atlas after creation, so the override sticks;
      -- the alpha DOES get reset to 1 by the renderer's SetVertexColor, which is why it is
      -- re-applied here on every pass rather than once.
      if glow then
        if FX.art then applyArt(glow, FX.art) end
        glow:SetVertexColor(r, g2, b, baseA)
      end
      -- 1. BACKING DISC.  Sized off the ring's OUTERMOST drawn extent (the echo, when one
      -- is on), not off the base ring — otherwise turning `rays` up leaves the echo
      -- hanging off an undersized disc.
      local outer = ring * math.max(1.0, FX.rays)
      local bg = FX.bgs[key]
      if FX.bg then
        if not bg then bg = ensureDisc(holder, "BACKGROUND"); FX.bgs[key] = bg end
        bg:SetColorTexture(0, 0, 0, FX.bgAlpha)
        sizeDisc(bg, outer * FX.bgScale, dot)
        bg:Show()
      elseif bg then
        bg:Hide()
      end
      -- 1b. RAY ECHO — the same ring, larger and dimmer, so the rays REACH further without
      -- the pair adding light.  Counter-rotating on purpose: two copies of one ring turning
      -- together read as a single thicker ring, whereas opposed rotation keeps the spokes
      -- crossing and is what makes the extra reach legible as rays.
      local echo = FX.echoes[key]
      if FX.rays > 1.0 and glow then
        if not echo then
          echo = holder:CreateTexture(nil, "ARTWORK")
          echo:SetBlendMode("ADD")
          local sg = echo:CreateAnimationGroup()
          local rot = sg:CreateAnimation("Rotation")
          rot:SetDegrees(360); rot:SetDuration(6.0); rot:SetOrigin("CENTER", 0, 0); rot:SetOrder(1)
          sg:SetLooping("REPEAT")
          echo._spin = sg
          FX.echoes[key] = echo
        end
        mirrorArt(echo, glow)
        echo:SetVertexColor(r, g2, b, echoA)
        echo:SetSize(outer, outer)
        echo:ClearAllPoints()
        echo:SetPoint("CENTER", glow, "CENTER", 0, 0)
        echo:Show()
        if not echo._spinOn then echo._spin:Play(); echo._spinOn = true end
      elseif echo then
        echo:Hide()
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
          mirrorArt(c, glow)
          -- Full alpha, unlike the echo: `glow <n>` IS the brightness knob, so its copies
          -- are supposed to stack light.  `rays` is the reach knob and compensates.
          c:SetVertexColor(r, g2, b, 1)
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
      if FX.echoes[key] then FX.echoes[key]:Hide() end
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
  for _, t in pairs(FX.echoes) do t:Hide() end
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
  ns.Printf("  bg    |cffffffff%s|r  (alpha %.2f, size %.2fx the ring's texture bounds)",
    FX.bg and "|cff88ff88on|r" or "off", FX.bgAlpha, FX.bgScale)
  ns.Printf("  glow  |cffffffffx%d|r  (%d additive cop%s — this is the BRIGHTNESS knob)",
    FX.stack, FX.stack - 1, FX.stack == 2 and "y" or "ies")
  ns.Printf("  ring  |cffffffff%.2fx|r size, spin |cffffffff%.2fx|r period  "
    .. "(LATE is already 1.4x / 2.5x faster than the rest)", FX.scale, FX.spinMul)
  ns.Printf("  rays  |cffffffff%.2fx|r (%s — this is the REACH knob, light-compensated)",
    FX.rays, FX.rays > 1.0 and string.format("echo at %.0f%% of the light", FX.raysAlpha * 100)
                            or "no echo")
  local ae = FX.art and GLOW_ART[FX.art]
  ns.Printf("  art   |cffffffff%s|r", ae and (FX.art .. ". " .. ae.label)
    or "(Renderer.lua's GLOW_ATLAS)")
  ns.Printf("  pop   |cffffffff%s|r  ghost |cffffffff%s|r  (peak %.1fx over %.2fs)",
    FX.pop and "on" or "off", FX.ghost and "on" or "off", FX.peak, FX.secs)
  ns.Printf("  sound |cffffffff%s|r  (channel %s)%s", FX.soundLabel or "off",
    SOUND_CHANNELS[FX.channel] or "Master",
    (FX.soundID or FX.soundFile) and ""
      or "  |cffff8080<- OFF BY DEFAULT; `rt fx sound` picks one|r")
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
local function fxCommand(words)
  local verb, a1 = words[2], words[3]
  if verb == nil or verb == "status" then
    fxStatus()
    if verb == nil then
      -- Bare `rt fx` opens the panel AND draws.  The panel is the intended way to run
      -- this experiment; the verbs are the fallback, not the front door.
      ensureFxPanel().frame:Show()
      drawFxView()
      updatePanel()
    end
    return true
  end
  if verb == "bg" then
    -- `bg` toggles; `bg <alpha>` keeps the old one-arg spelling; `bg size <n>` is the
    -- dial the first cut was missing — the disc was 1.15x the ring's quad with no way to
    -- shrink it short of an edit.
    if a1 == "size" then
      FX.bgScale = tonumber(words[4]) or FX.bgScale; FX.bg = true
    elseif a1 == "alpha" then
      FX.bgAlpha = tonumber(words[4]) or FX.bgAlpha; FX.bg = FX.bgAlpha > 0
    elseif a1 then
      FX.bgAlpha = tonumber(a1) or FX.bgAlpha; FX.bg = FX.bgAlpha > 0
    else
      FX.bg = not FX.bg
    end
  elseif verb == "scale" or verb == "ring" then
    FX.scale = math.max(0.5, math.min(3.0, tonumber(a1 or "") or (FX.scale + 0.15)))
    if words[4] then FX.spinMul = tonumber(words[4]) or FX.spinMul end
  elseif verb == "spin" then
    FX.spinMul = math.max(0.2, math.min(3.0, tonumber(a1 or "") or (FX.spinMul - 0.25)))
  elseif verb == "rays" then
    -- REACH, not brightness.  `rays 1` turns the echo off.
    FX.rays = math.max(1.0, math.min(4.0, tonumber(a1 or "") or (FX.rays + 0.25)))
    if not a1 and FX.rays >= 4.0 then FX.rays = 1.0 end     -- bare `rays` cycles
    if words[4] then FX.raysAlpha = tonumber(words[4]) or FX.raysAlpha end
  elseif verb == "atlas" or verb == "art" then
    if a1 == "list" then
      ns.Heading("rt fx art — candidate ring art")
      for i, e in ipairs(GLOW_ART) do
        local ok = artExists(e)
        ns.Printf("  %d. |cffffffff%s|r %s", i, e.label,
          e.kind == "file" and "|cff88ff88[ours, CC0]|r"
            or (ok == nil and "|cff808080[cannot check]|r"
                or (ok and "|cff88ff88[present]|r" or "|cffff4040[absent]|r")))
      end
      ns.Print("usage: |cffffffff/cdmp rt fx art|r (next) | <n> | reset | list")
      return true
    elseif a1 == "reset" then
      FX.art = nil
    elseif tonumber(a1) then
      FX.art = math.max(1, math.min(#GLOW_ART, math.floor(tonumber(a1))))
    else
      FX.art = (FX.art or 0) % #GLOW_ART + 1
    end
    local e = FX.art and GLOW_ART[FX.art]
    if e and artExists(e) == false then
      ns.Printf("|cffff4040'%s' is not an atlas on this build|r — the ring will draw "
        .. "NOTHING; try another or |cffffffffart reset|r", e.id)
    end
  elseif verb == "glow" then
    FX.stack = math.max(1, math.min(4, math.floor(tonumber(a1 or "") or (FX.stack + 1))))
    if not a1 and FX.stack >= 4 then FX.stack = 1 end   -- bare `glow` cycles 1..4
  elseif verb == "pop" then
    if a1 then FX.peak = tonumber(a1) or FX.peak; FX.pop = true else FX.pop = not FX.pop end
  elseif verb == "ghost" then
    FX.ghost = not FX.ghost
  elseif verb == "sound" then
    local a2 = words[4]
    if a1 == "test" then
      soundDiagnose()
      return true
    elseif a1 == "channel" then
      -- The nearest thing to a volume control: pick the slider that governs it.
      if tonumber(a2) then
        FX.channel = math.max(1, math.min(#SOUND_CHANNELS, math.floor(tonumber(a2))))
      else
        FX.channel = FX.channel % #SOUND_CHANNELS + 1
      end
      playCueSound()
      ns.Printf("rt fx sound channel: |cffffffff%s|r  (of %d: Master SFX Dialog Ambience Music)",
        SOUND_CHANNELS[FX.channel], #SOUND_CHANNELS)
      return true
    elseif a1 == "sweep" then
      -- Walk the verified max-volume UI pool.  Bare = next; a number JUMPS to that
      -- POSITION (not that id), so a promising one can be re-found by index.  Opens the
      -- panel on the way through: the whole point is that step 2 onward is a click.
      ensureFxPanel().frame:Show()
      local id, willPlay = sweepTo(tonumber(a2) and math.floor(tonumber(a2)) or (FX.sweep + 1))
      ns.Printf("rt fx sweep |cffffffff%d/%d|r — id |cffffffff%d|r %s  (now use the panel)",
        FX.sweep, #LOUD_UI, id,
        willPlay == false and "|cffff4040[refused]|r" or "|cff88ff88[playing]|r")
      return true
    elseif a1 == "panel" then
      local p = ensureFxPanel()
      if p.frame:IsShown() then stopSoundLoop(); p.frame:Hide() else p.frame:Show() end
      updatePanel()
      return true
    elseif a1 == "loop" then
      if FX.loop then stopSoundLoop() else startSoundLoop() end
      updatePanel()
      ns.Printf("rt fx sound loop: |cffffffff%s|r", FX.loop and "on" or "off")
      return true
    elseif a1 == "rep" then
      FX.rep = math.max(1, math.min(8, math.floor(tonumber(a2 or "") or 3)))
      if words[5] then FX.repGap = tonumber(words[5]) or FX.repGap end
      updatePanel()
      playCueBurst()
      ns.Printf("rt fx sound rep: |cffffffffx%d|r every %.2fs", FX.rep, FX.repGap)
      return true
    elseif a1 == "off" then
      selectSound(nil, nil, nil, nil)
    elseif a1 == "list" then
      ns.Heading("rt fx sound — the audition list (a starting point, NOT a verified set)")
      for i, e in ipairs(SOUNDS) do
        local kit, file = soundSrc(i)
        ns.Printf("  %d. |cffffffff%s|r %s", i, e.label,
          file and "|cff88ff88[ours, CC0 ogg]|r"
            or (kit and ("|cff88ff88[kit " .. kit .. "]|r")
                or "|cffff4040[absent on this build]|r"))
      end
      ns.Print("SOUNDKIT is named constants over |cffffffff333,671|r SoundKit ids — the")
      ns.Print("list is a shortcut, not the limit.  Reach the rest directly:")
      ns.Printf("|cffffd100no API scales one sound's volume|r — use |cffffffffsweep|r "
        .. "(%d verified max-volume UI kits) or |cffffffffchannel|r, or ship our own file.",
        #LOUD_UI)
      ns.Print("usage: |cffffffff/cdmp rt fx sound|r (next) | <n> | id <kitID> | file <path>")
      ns.Print("       |cffffffffsweep|r [n] | |cffffffffchannel|r [n] | test | off | list")
      return true
    elseif a1 == "id" and tonumber(a2) then
      -- ANY of the 333,671 kits, by raw id.  No name to resolve, so nothing to be absent.
      local id = math.floor(tonumber(a2))
      selectSound(nil, id, nil, "SoundKit id " .. id)
    elseif a1 == "file" and a2 then
      -- ANY sound file — a game asset by path/FileDataID, or one we ship in Media/.
      selectSound(nil, nil, a2, "file " .. a2)
    elseif tonumber(a1) then
      local i = math.max(1, math.min(#SOUNDS, math.floor(tonumber(a1))))
      local kit, file = soundSrc(i)
      selectSound(i, kit, file, soundLabel(i))
    else
      local i = (FX.sound or 0) % #SOUNDS + 1            -- bare `sound` = audition the next
      local kit, file = soundSrc(i)
      selectSound(i, kit, file, soundLabel(i))
    end
    if FX.sound and not (FX.soundID or FX.soundFile) then
      ns.Printf("|cffff4040%s is not in SOUNDKIT on this build|r — try another, or "
        .. "|cffffffffsound id <kitID>|r", SOUNDS[FX.sound].id)
    end
    playCueBurst()                                       -- hear it right now, as a burst
    updatePanel()
    ns.Printf("rt fx sound: |cffffffff%s|r", FX.soundLabel or "off")
    return true
  else
    ns.Heading("rt fx — experimental cue treatments")
    ns.Print("  |cff88ff88(bare)|r        open the PANEL — every knob as a button")
    ns.Print("  |cff88ff88bg|r [size <n>|alpha <n>]  black backing disc (contrast)")
    ns.Print("  |cff88ff88glow|r [1-4]     additive ring copies — the BRIGHTNESS knob")
    ns.Print("  |cff88ff88ring|r [n] / |cff88ff88spin|r [n]  ring SIZE / spin PERIOD, x the Renderer's")
    ns.Print("         (LATE already runs 1.4x bigger + 2.5x faster than the rest)")
    ns.Print("  |cff88ff88rays|r [n] [a]   outer ring echo — the REACH knob, light-compensated")
    ns.Print("  |cff88ff88art|r [n|reset|list]  swap the ring ART — incl. our CC0 TGAs")
    ns.Print("  |cff88ff88pop|r [peak]     one-shot scale on cue APPLICATION")
    ns.Print("  |cff88ff88ghost|r          one-shot scale+fade on cue REMOVAL")
    ns.Print("  |cff88ff88sound|r [n|id|file|sweep|channel|test|off|list]  cue SFX (bare = next)")
    ns.Print("         |cffffd100no volume API|r — `sound sweep` walks the loud pool,")
    ns.Print("         `sound channel` picks which slider governs it")
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
  stopSoundLoop()                            -- ...and silences an audition still looping
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
