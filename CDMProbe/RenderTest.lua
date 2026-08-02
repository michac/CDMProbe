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

--------------------------------------------------------------------------------
-- EXPERIMENTAL FX (`/cdmp rt fx …`) — the dialling rig, 2026-08-01
--------------------------------------------------------------------------------
-- ✅ THE FIRST ROUND IS DONE AND ITS WINNERS ARE SHIPPED.  This rig was built to answer
-- "why do the cues read more subdued in play than in the render test".  It answered:
-- star_07 art, ring 1.45x (GLOW_SCALE 2.3 -> 3.34), an outer echo at 1.5x / 55 % of the
-- light counter-rotating at 2.5x the base period, a black backing disc, and the pop +
-- ghost.  All of that now lives in **Renderer.lua**, so `/cdmp rt states` — which draws
-- the shipped renderer and nothing else — already looks like the dialled version.
--
-- ⚠ SO THE KNOBS NOW DIAL *RELATIVE TO THE SHIPPED LOOK*, NOT UP FROM A BARE ONE.
-- `ring 1.45` used to mean "1.45x Blizzard's stock ring"; it now means "1.45x the ring
-- the HUD already draws".  Everything defaults to neutral (`scale`/`spinMul`/`rays` 1.0,
-- `bg` off, `art` stock, `stack` 1, `pop`/`ghost` off), so a bare `/cdmp rt fx` is once
-- again pixel-identical to `/cdmp rt states` — that A/B is the point, turn one on at a
-- time.  Two knobs now DOUBLE something the Renderer already draws rather than adding
-- it: `bg` puts a second disc behind the Renderer's, and `rays` a second echo outside
-- its echo.  That is still a legitimate way to ask "more?", but read the result as
-- "twice", not "at all".  `pop`/`ghost` likewise re-play on top of the shipped ones.
--
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
  bg      = false,  -- black backing disc on/off.  ⚠ A SECOND one — Renderer.lua now draws
                    -- its own (DISC_ALPHA/DISC_SCALE); this stacks on top of it.
  bgAlpha = 0.75,   -- its opacity
  -- ⚠ MEASURED AGAINST THE RING'S TEXTURE BOUNDS, WHICH IS WHY IT LOOKS TOO BIG.
  -- 1.0 = the full quad the ring sprite is drawn into.  But the sprite does not fill its
  -- own quad: the art has transparent padding and its rays fade out well before the edge,
  -- so a disc sized to the QUAD is visibly larger than the light it is
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
  scale     = 1.0,  -- ring diameter multiplier (base GLOW_SCALE is 3.34 since the promotion)
  spinMul   = 1.0,  -- spin PERIOD multiplier; <1 = faster (base SPIN_SECS is 12.0 since
                    -- the art-symmetry retune; star_07 is 8-fold, so 4.0 strobed)
  -- THE LATE EFFECT, GENERALISED.  See layerSpin(): the extra ring layers used to spin at
  -- a HARDCODED absolute period, which happened to equal the base everywhere except LATE.
  -- This is that accident turned into a ratio, so any emphasis can have it.
  desync    = 2.5,  -- extra layers' spin period / the BASE ring's period.  1.0 = locked
  counter   = true, -- extra layers turn the OTHER way (relative slide is the whole effect)
  rays      = 1.0,  -- echo diameter multiplier; 1.0 = no echo.  ⚠ A SECOND echo — the
                    -- Renderer ships one at ECHO_SCALE 1.5; this draws outside it.
  raysAlpha = 0.55, -- the echo's share of the light
  art       = nil,  -- index into GLOW_ART; nil = whatever Renderer.lua's GLOW_ART is
                    -- (entry 8, star_07, since the promotion)
  -- THE TWO MOTIONS THIS RIG WAS BLIND TO, and the reason a "too fast" reading survived a
  -- whole dialling session plus a spin retune.  Everything above dials the RING; but the
  -- ring is only one of THREE things moving on a cue, and the other two had no knob:
  --   * the PULSE — a BOUNCE alpha breathe, 0.60s each way, so a 1.2s cycle at a ~2:1
  --     swing.  Older than this rig and never questioned by it.
  --   * the ECHO/base MOIRÉ — two 8-fold sprites counter-rotating.  They align 8x per
  --     relative revolution, so at 30 deg/s + 12 deg/s that is a ~1 Hz shimmer over the
  --     whole ring, independent of how slow either one turns.
  -- Both dial the SHIPPED layers (unlike every knob above, which adds a layer on top),
  -- and both default neutral.
  -- THE LAYER LADDER — the answer to "we have been judging four simultaneous motions as
  -- one lump".  A shipped cue is dot + backing disc + ring + spin + breathe + echo, all
  -- at once, and three rounds of "it moves too fast" could not say WHICH.  `layers <n>`
  -- suppresses everything above rung n, so you start at a bare coloured dot and add one
  -- thing at a time — the first rung that looks wrong IS the culprit, with no arithmetic
  -- and no guessing.  nil = the shipped stack (all rungs).
  layers    = nil,
  -- ⚠ SUPPRESS THE RENDERER'S OWN POP (not the FX one below).  It exists because the pop
  -- is the ONE thing that differs between "rt off -> layers 3" (which misbehaves) and
  -- "rt off -> layers 2 -> layers 3" (which does not): the first sees every handle ARRIVE
  -- and scales each cue layer, the second already spent that edge a rung earlier.  With
  -- no way to turn it off, that hypothesis could only be argued, not tested.
  noPop     = false,
  pulseMul  = 1.0,  -- multiplier on the Renderer's PULSE_SECS
  pulseFloor= nil,  -- override the breathe's floor alpha; nil = Renderer's (0.55).
                    -- 1.0 = no breathe at all, which is the real A/B
  pulseOff  = false,-- stop the breathe outright
  echoOff   = false,-- hide the Renderer's OWN echo (the `rays` knob adds another one)
  echoMul   = 1.0,  -- multiplier on the Renderer's echo period (kills the moiré as it
                    -- approaches the base's, since in-phase = no relative slide)
  -- ⚠ THE ECHO HAS THREE INDEPENDENT VARIABLES AND ONLY ONE OF THEM HAS EVER BEEN TESTED.
  -- Phase was found and fixed (the moiré).  These are the other two, and the second is
  -- the suspicious one: the echo ships carrying 0.55 of the light while the ring it
  -- echoes keeps 0.45 — a copy that is BOTH 1.5x bigger AND brighter than its original
  -- is not an echo, it is the main event.  Nothing could dial either until now, which is
  -- why "take the echo out" was reached for before "find out which part of it is wrong".
  echoScale = nil,  -- echo diameter x the base ring; nil = the Renderer's 1.5
  echoLight = nil,  -- echo's share of the light; nil = the Renderer's 0.55.  The base
                    -- ring gets 1-this, so the pair's total stays flat as you slide it
  stack   = 1,      -- additive glow copies: 1 = stock, 2 = "doubled"
  pop     = false,  -- one-shot scale on application.  ⚠ A SECOND one: the Renderer pops
  ghost   = false,  -- ...and ghosts natively now, on its own CUE LAYER frame.  These
                    -- re-play on top, on the textures, so use them to try a DIFFERENT
                    -- peak/duration, not to ask whether a pop helps at all.
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

-- The ladder's rungs, lowest first.  Rung 0 is a bare coloured dot: the simplest thing
-- that is still a cue.  Each successive rung adds exactly ONE visual element or ONE
-- motion, so "which layer is wrong" is answered by stepping until it looks wrong.
local LAYER_NAMES = {
  [0] = "dot only",
  [1] = "+ backing disc",
  [2] = "+ ring (still)",
  [3] = "+ ring SPIN",
  [4] = "+ ring BREATHE",
  -- ⚠ THE ECHO IS THREE CHOICES, NOT ONE, and bundling them is why "rung 5 goes wrong"
  -- could not say WHICH part of it is wrong.  It is a second draw of the SAME sprite:
  -- bigger, brighter, and separately rotating.  Split so each rung moves ONE variable —
  -- and note the BASE ring is deliberately left untouched across 4..7, so nothing else
  -- changes underneath while you step.
  [5] = "+ echo, STATIC and dim (does reach help at all?)",
  [6] = "+ echo at its full light share (is BRIGHTNESS what breaks it?)",
  [7] = "+ echo's own rotation  = the shipped cue",
}
local LAYER_MAX = 7
-- What rung 5 dims the echo to.  A whisper: enough to see whether the extra reach reads,
-- far too little to dominate.  Rung 6 hands it back whatever the Renderer actually set.
local ECHO_PROBE_LIGHT = 0.15


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
-- WHY SHIPPING OUR OWN IS THE STRONGER ANSWER, not merely another option — and this one
-- is SETTLED: entry 8 won and is the Renderer's shipped art.  SetVertexColor MULTIPLIES,
-- so a tint can only ever remove energy the art already has.  Blizzard's
-- `services-ring-large-glowspin` is GOLD — mostly red+green — so our violet
-- ROTATION_FALLBACK (green channel 0.16) multiplies most of it away, which is a real part
-- of why the fallback read dim.  The Kenney sprites are WHITE/GREY with the shape carried
-- in alpha, so every hue tints at full strength.  That is a property no amount of dialling
-- the Blizzard atlas can buy.
local GLOW_ART = {
  -- Blizzard atlases — names written from knowledge of the atlas set, NOT verified against
  -- this build.  `C_Texture.GetAtlasInfo` validates them, so `art list` reports each
  -- present/absent rather than letting a typo read as "that one looks bad".
  { kind = "atlas", id = "services-ring-large-glowspin", label = "Blizz ring (the OLD stock)" },
  { kind = "atlas", id = "services-ring-small-glowspin", label = "Blizz ring, tighter" },
  { kind = "atlas", id = "ChallengeMode-RingGlow",       label = "Blizz M+ keystone ring" },
  { kind = "atlas", id = "Artifacts-StarGlow",           label = "Blizz star burst" },
  -- Ours (CC0, Kenney).  These EXIST by construction — they are in the addon folder.
  { kind = "file",  id = MEDIA .. "glow\\twirl_01.tga",  label = "Kenney twirl 01 — spiral" },
  { kind = "file",  id = MEDIA .. "glow\\twirl_03.tga",  label = "Kenney twirl 03 — dense spiral" },
  { kind = "file",  id = MEDIA .. "glow\\star_04.tga",   label = "Kenney star 04 — LONG spokes" },
  { kind = "file",  id = MEDIA .. "glow\\star_07.tga",   label = "Kenney star 07 — long, sparse |cff88ff88(SHIPPED — the Renderer's stock)|r" },
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

-- LAYER SPIN — re-time/re-aim ONE extra ring layer against the BASE ring's actual period.
--
-- ⚠ THIS IS THE "WHY IS LATE SPECIAL" BUG, AND IT WAS A GOOD ONE.  The stack copies and
-- the ray echo used to spin at HARDCODED absolute periods (4.0s and 6.0s).  The base ring
-- ran at SPIN_SECS = 4.0 for ROTATION / SOON / FALLBACK -- so a copy at 4.0 sat exactly
-- in phase with it, two identical spoked rings superimposed, invisible as a second layer.
-- LATE is the ONE emphasis with its own spinSecs (1.6), so there the copy ran 2.5x slower
-- than the base and the two spoke sets slid continuously past each other.  That slide IS
-- the effect: relative motion reads as a counter-rotating inner set, and the spokes
-- crossing and separating near the hub is the "rippling".  It was never LATE-specific --
-- it was a desync that only LATE happened to have.
--
-- So the period is now a RATIO to whatever the base is actually doing, which makes the
-- effect available to every emphasis and survives any retune of GLOW_SPEC/SPIN_SECS.
-- ratio 1.0 = locked in phase (the old ROTATION behaviour, i.e. no effect).
local function layerSpin(tex, baseSecs, ratio, counter)
  if not (tex and tex._rot) then return end
  local secs = math.max(0.15, (baseSecs or 4.0) * (ratio or 1.0))
  local deg  = counter and 360 or -360
  -- Re-apply only on CHANGE: SetDuration/SetDegrees on a playing group restart it, which
  -- at 10 Hz would reset the slide every tick and hide the very thing being tested.
  if tex._fxSecs ~= secs or tex._fxDeg ~= deg then
    tex._fxSecs, tex._fxDeg = secs, deg
    tex._rot:SetDuration(secs)
    tex._rot:SetDegrees(deg)
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
  -- ✅ THE TWO THE HUD ACTUALLY PLAYS, first so a candidate is auditioned against what
  -- ships rather than against silence.  HudDriver plays these ONCE per change of the cue
  -- set; here they come as the ×3 audition burst like everything else in this list.
  { kind = "file", id = MEDIA .. "sfx\\drawKnife1.ogg",       label = "SHIPPED — cue set gained something ('new')" },
  { kind = "file", id = MEDIA .. "sfx\\chip-lay-1.ogg",       label = "SHIPPED — cue set only lost ('gone'; rare)" },
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
  p.layersVal:SetText(string.format("%s%s", FX.layers
    and string.format("|cffffffff%d/%d|r %s", FX.layers, LAYER_MAX, LAYER_NAMES[FX.layers])
    or "|cff808080all — the shipped cue|r",
    FX.noPop and "  |cffffcc00nopop|r" or ""))
  p.bgVal:SetText(FX.bg and string.format("|cff88ff88on|r  a%.2f s%.2f", FX.bgAlpha, FX.bgScale)
                        or "|cff808080off|r")
  p.glowVal:SetText(string.format("|cffffffffx%d|r  desync |cffffffff%.1f|r%s%s",
    FX.stack, FX.desync, FX.counter and " rev" or "",
    (FX.stack < 2 and FX.rays <= 1.0) and "  |cff808080(needs glow 2+ or rays)|r" or ""))
  p.ringVal:SetText(string.format("size |cffffffff%.2fx|r  spin |cffffffff%.2fx|r%s",
    FX.scale, FX.spinMul,
    (FX.scale == 1.0 and FX.spinMul == 1.0) and "  |cff808080(stock)|r" or ""))
  p.raysVal:SetText(FX.rays > 1.0 and string.format("|cffffffff%.2fx|r @%.0f%%",
                      FX.rays, FX.raysAlpha * 100) or "|cff808080off|r")
  local ae = FX.art and GLOW_ART[FX.art]
  p.artVal:SetText(ae and ("|cffffffff" .. FX.art .. ".|r " .. ae.label) or "|cff808080stock|r")
  -- Absolute seconds, not just the multiplier: the whole point of this row is that nobody
  -- knew the breathe was a 1.2s cycle.
  p.motionVal:SetText(string.format("pulse %s%s   echo %s",
    FX.pulseOff and "|cffff8080off|r"
      or (FX.pulseFloor == 1.0 and "|cffffcc00flat|r"
          or string.format("|cffffffff%.1fs|r cyc", 0.60 * FX.pulseMul * 2)),
    (FX.pulseMul == 1.0 and not FX.pulseOff and not FX.pulseFloor)
      and "  |cff808080(shipped)|r" or "",
    FX.echoOff and "|cffff8080hidden|r" or "|cff88ff88on|r"))
  -- The echo's three variables side by side, with the SHIPPED value in brackets, because
  -- the whole point is that two of them had never been moved off it.
  p.echoVal:SetText(string.format("light |cffffffff%.2f|r%s  size |cffffffff%.2fx|r%s  spin |cffffffff%.2fx|r",
    FX.echoLight or 0.55, FX.echoLight and "" or "|cff808080(stock)|r",
    FX.echoScale or 1.5, FX.echoScale and "" or "|cff808080(stock)|r",
    FX.echoMul))
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
  local rows = 11
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
  -- THE LADDER, first because it is where you should start: strip to a bare dot, then
  -- add one layer at a time until it looks wrong.
  label("|cffffd100layers|r", y)
  btn("<", 24, 56, y, bump(function()
    FX.layers = math.max(0, (FX.layers or LAYER_MAX + 1) - 1)
  end))
  btn(">", 24, 82, y, bump(function()
    local n = (FX.layers or -1) + 1
    FX.layers = n > LAYER_MAX and nil or n   -- past the top rung = back to the shipped cue
  end))
  btn("all", 34, 112, y, bump(function() FX.layers = nil end))
  btn("nopop", 46, 150, y, bump(function() FX.noPop = not FX.noPop end))
  local layersVal = value(y)
  -- bg
  y = y - ROW_H2
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
  btn("dsy", 30, 96, y, bump(function()
    FX.desync = FX.desync >= 3.0 and 1.0 or FX.desync + 0.5
  end))
  btn("rev", 30, 130, y, bump(function() FX.counter = not FX.counter end))
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
  -- motion: the SHIPPED pulse + the SHIPPED echo (everything else adds a layer; these
  -- two re-dial one the Renderer already draws).  This row is the one that was missing.
  y = y - ROW_H2
  label("motion", y)
  btn("slow", 40, 40, y, bump(function()
    FX.pulseMul = FX.pulseMul >= 4.0 and 1.0 or FX.pulseMul + 0.5
  end))
  btn("flat", 34, 84, y, bump(function()
    -- 1.0 = no breathe at all; cycling back to nil restores the Renderer's own floor.
    FX.pulseFloor = FX.pulseFloor and nil or 1.0
  end))
  btn("echo", 36, 122, y, bump(function() FX.echoOff = not FX.echoOff end))
  local motionVal = value(y)
  -- THE ECHO'S TWO UNTESTED VARIABLES, on their own row because troubleshooting it is
  -- the open question.  `dim` walks its light share DOWN (it ships at 0.55, i.e. brighter
  -- than the ring it echoes — start here); `size` walks its diameter down from 1.5x.
  y = y - ROW_H2
  label("echo", y)
  btn("dim", 34, 40, y, bump(function()
    FX.echoLight = (FX.echoLight or 0.55) - 0.10
    if FX.echoLight < 0.05 then FX.echoLight = nil end   -- past the bottom = back to stock
  end))
  btn("size", 36, 78, y, bump(function()
    FX.echoScale = (FX.echoScale or 1.5) - 0.15
    if FX.echoScale < 1.05 then FX.echoScale = nil end
  end))
  btn("sync", 34, 118, y, bump(function()
    -- Toward 1.0 the echo locks in phase with the base and the moiré disappears.
    FX.echoMul = FX.echoMul <= 0.45 and 1.0 or FX.echoMul - 0.15
  end))
  btn("stock", 40, 156, y, bump(function()
    FX.echoLight, FX.echoScale, FX.echoMul = nil, nil, 1.0
  end))
  local echoVal = value(y)
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
    FX.desync, FX.counter = 2.5, true
    FX.pulseMul, FX.pulseFloor, FX.pulseOff = 1.0, nil, false
    FX.echoOff, FX.echoMul, FX.layers = false, 1.0, nil
    FX.echoLight, FX.echoScale, FX.noPop = nil, nil, false
    FX.pop, FX.ghost, FX.peak = false, false, 2.0
    stopSoundLoop(); selectSound(nil, nil, nil, nil)
  end))
  btn("close", 60, 86, y, function() stopSoundLoop(); f:Hide() end)

  p = { frame = f, bgVal = bgVal, glowVal = glowVal, ringVal = ringVal,
        raysVal = raysVal, artVal = artVal, motionVal = motionVal, layersVal = layersVal,
        echoVal = echoVal,
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

-- Suppress every shipped layer above rung `L`.  Runs AFTER the knobs above and overrides
-- them: the ladder is the more explicit instruction.  Writes into the Renderer's own
-- pools, like the other in-place knobs — `R:Draw` re-shows everything each draw, and the
-- rig redraws once per click, so a suppression holds exactly as long as the view does.
local function applyLadder(renderer, key, glow, echo, r, g, b, safe)
  local L = FX.layers
  if not L then return end
  local disc = renderer.cueDiscs and renderer.cueDiscs[key]
  if disc then if L >= 1 then disc:Show() else disc:Hide() end end
  if glow then
    if L >= 2 then glow:Show() else glow:Hide() end
    if glow.spin then
      if L >= 3 then
        if not safe(glow.spin, "IsPlaying", false) then glow.spin:Play() end
      else
        glow.spin:Stop()
      end
    end
    if glow.pulse then
      if L >= 4 then
        if not safe(glow.pulse, "IsPlaying", false) then glow.pulse:Play() end
      else
        glow.pulse:Stop()
        glow:SetAlpha(1)   -- a stopped breathe leaves the alpha wherever it stalled
      end
    end
  end
  -- THE ECHO'S THREE RUNGS.  Its shipped light share is READ off the texture rather than
  -- restated here (R:Draw sets it every pass, and the `echo light` knob may have moved
  -- it), so this can never drift from what the Renderer actually does.
  if echo then
    local shippedA = select(4, echo:GetVertexColor())
    if L < 5 then
      echo:Hide()
      if echo.spin then echo.spin:Stop() end
    else
      echo:Show()
      echo:SetVertexColor(r or 1, g or 1, b or 1,
                          (L >= 6) and (shippedA or 0.55) or ECHO_PROBE_LIGHT)
      if echo.spin then
        if L >= 7 then
          if not safe(echo.spin, "IsPlaying", false) then echo.spin:Play() end
        else
          echo.spin:Stop()
        end
      end
    end
  end
end

-- Read a widget getter that may not exist on this build / this stub.  Sits ABOVE its
-- first caller on purpose: a `local function` declared later resolves as a nil GLOBAL.
local function safeCall(obj, method, dflt)
  if not (obj and obj[method]) then return dflt end
  local ok, v = pcall(obj[method], obj)
  if ok and v ~= nil then return v end
  return dflt
end


--------------------------------------------------------------------------------
-- THE FX CAPTURE — the dump, recorded instead of printed.
--------------------------------------------------------------------------------
-- WHY: reading the dump out of chat means copying a screenful per rung, and a ladder is
-- EIGHT rungs across TWO paths.  The transcription cost swamped the experiment, which is
-- the same complaint that turned `/cdmp flight` from a ten-command checklist into a
-- recorder.  So this is that shape again, applied to the render test: every view change
-- snapshots what is ACTUALLY on each cue into `CDMProbeDB.rtfx`, and
-- `uv run python -m wowkb.cdmp rtfx` reads it on the desktop.
--
-- IT FIRES ON EVERY REDRAW, not on a `dump` verb — so walking the rungs IS the recording
-- and there is nothing extra to remember to type.  The knob state that produced each
-- sample rides along, because a measurement without its inputs is not a measurement.
-- ⚠ SavedVariables only flush on **/reload**.
local RTFX_MAX = 60   -- a bounded ring; two full ladder walks and change

-- Everything numeric, read off the LIVE widgets through the same guarded reader the
-- printed dump uses.  Nothing here is computed from what the code SHOULD have done.
local function sampleFx(renderer, activeKeys, settled)
  if not (ns.db and renderer and activeKeys) then return end
  local ring = ns.db.rtfx
  if type(ring) ~= "table" then ring = {}; ns.db.rtfx = ring end
  local cues = {}
  for key, emph in pairs(activeKeys) do
    local lay  = renderer.cueLayers and renderer.cueLayers[key]
    local glow = renderer.cueGlows and renderer.cueGlows[key]
    local echo = renderer.cueEchoes and renderer.cueEchoes[key]
    local dot  = renderer.cueFrames and renderer.cueFrames[key]
    cues[#cues + 1] = {
      key = tostring(key), emphasis = tostring(emph),
      dotW = safeCall(dot, "GetWidth", 0),
      -- THE CUE LAYER: the frame the ring is parented to.  Its scale is what the arrival
      -- pop animates, and a rotating texture inside a scaled/non-uniform frame is the
      -- shape of every "the spin surges" report.
      layW = lay and safeCall(lay, "GetWidth", 0) or nil,
      layH = lay and safeCall(lay, "GetHeight", 0) or nil,
      layScale = lay and safeCall(lay, "GetScale", 1) or nil,
      layEff   = lay and safeCall(lay, "GetEffectiveScale", 1) or nil,
      popPlaying = (lay and lay.pop) and (safeCall(lay.pop, "IsPlaying", false) and 1 or 0) or nil,
      ringW = glow and safeCall(glow, "GetWidth", 0) or nil,
      ringH = glow and safeCall(glow, "GetHeight", 0) or nil,
      ringShown = glow and (glow:IsShown() and 1 or 0) or nil,
      spinSecs = glow and safeCall(glow.rot, "GetDuration", 0) or nil,
      spinDeg  = glow and safeCall(glow.rot, "GetDegrees", 0) or nil,
      spinPlay = glow and (safeCall(glow.spin, "IsPlaying", false) and 1 or 0) or nil,
      pulseSecs = glow and safeCall(glow.pulseAnim, "GetDuration", 0) or nil,
      pulsePlay = glow and (safeCall(glow.pulse, "IsPlaying", false) and 1 or 0) or nil,
      ringAlpha = glow and (select(4, glow:GetVertexColor()) or 1) or nil,
      regionAlpha = glow and safeCall(glow, "GetAlpha", 1) or nil,
      echoW = echo and safeCall(echo, "GetWidth", 0) or nil,
      echoShown = echo and (echo:IsShown() and 1 or 0) or nil,
      echoSecs = echo and safeCall(echo.rot, "GetDuration", 0) or nil,
      echoDeg  = echo and safeCall(echo.rot, "GetDegrees", 0) or nil,
      echoPlay = echo and (safeCall(echo.spin, "IsPlaying", false) and 1 or 0) or nil,
      echoAlpha = echo and (select(4, echo:GetVertexColor()) or 1) or nil,
    }
  end
  ring[#ring + 1] = {
    t = GetTime(),
    -- ⚠ `settled` IS THE WHOLE POINT OF THE SECOND SAMPLE.  The immediate one is taken the
    -- instant after Draw, when a just-started pop has not moved anything yet — so it can
    -- say the pop RAN but never what the pop LEFT.  The settled sample is taken well after
    -- the 0.28s pop has finished, so the pair answers "does the cue layer come back to
    -- scale 1?" — which is the difference between a one-shot flourish and a frame that is
    -- permanently enlarged with a spinning ring inside it.
    settled = settled and 1 or 0,
    -- The inputs that produced this sample.  `layers` is the headline: the whole point is
    -- to diff one rung against another, and against the same rung reached another way.
    layers = FX.layers, noPop = FX.noPop and 1 or 0,
    scale = FX.scale, spinMul = FX.spinMul, rays = FX.rays, stack = FX.stack,
    bg = FX.bg and 1 or 0, art = FX.art,
    pulseMul = FX.pulseMul, pulseFloor = FX.pulseFloor, pulseOff = FX.pulseOff and 1 or 0,
    echoOff = FX.echoOff and 1 or 0, echoMul = FX.echoMul,
    echoLight = FX.echoLight, echoScale = FX.echoScale,
    cues = cues,
  }
  while #ring > RTFX_MAX do table.remove(ring, 1) end
end

-- Two samples per view change: one NOW, one after everything one-shot has finished.
local SETTLE_SECS = 0.6   -- comfortably past POP_SECS (0.28) plus a frame or two
local function captureFx(renderer, activeKeys)
  sampleFx(renderer, activeKeys, false)
  C_Timer.After(SETTLE_SECS, function() sampleFx(renderer, activeKeys, true) end)
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
      if ring <= 0 then ring = dot:GetWidth() * 3.34 end   -- Renderer.lua's GLOW_SCALE
      -- RING SIZE + SPIN SPEED, as MULTIPLIERS on whatever the Renderer chose.
      --
      -- ⚠ THIS IS WHY ONE ART LOOKS RIGHT ON LATE AND WRONG EVERYWHERE ELSE.  LATE is the
      -- only emphasis carrying per-token overrides (GLOW_SPEC.LATE: ringScale 4.64 vs the
      -- base GLOW_SCALE 3.34, spinSecs 4.8 vs SPIN_SECS 12.0) — so it draws every ring ~1.4x
      -- bigger and spinning 2.5x faster than ROTATION/SOON/FALLBACK do.  Spoked art needs
      -- BOTH: radius, because a spoke's length is what makes it a ray rather than a bump,
      -- and angular speed, because spokes are what let rotation read at all.  At the base
      -- 2.3/4.0 the same sprite is shorter-spoked and turning lazily, and reads as a smudge.
      --
      -- MULTIPLIERS, not absolutes, deliberately: LATE's escalation is a RATIO to the base
      -- (Renderer.lua: "the escalation is 'a bigger ring', not this exact number"), so
      -- scaling both together preserves it.  Dial the base up until ROTATION reads, then
      -- promote the number to GLOW_SCALE / SPIN_SECS rather than shipping it from here.
      -- ✅ That is exactly what happened: `ring 1.45` here became GLOW_SCALE 2.3 -> 3.34
      -- and LATE's ringScale 3.2 -> 4.64, ratio intact.  A `ring` multiplier now stacks on
      -- TOP of that, so it is the lever for a SECOND round, not a re-run of the first.
      --
      -- And note GLOW_SCALE is ART-SPECIFIC: 3.34 was dialled against star_07 to close the
      -- gap between the dot's rim and THAT sprite's inner edge (2.3 belonged to Blizzard's
      -- ring, and did not transfer).  A sprite whose spokes start at a different radius
      -- invalidates the number, so swapping art and re-dialling scale are one job, not two.
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
      -- THE SHIPPED PULSE + THE SHIPPED ECHO, re-dialled in place.  These write back into
      -- the Renderer's own layers rather than decorating around them — the same
      -- unavoidable exception the atlas override below makes, and for the same reason:
      -- "the same motion, slower" is the experiment.  `R:Draw` re-asserts size/colour/
      -- points every draw but never re-times a group it thinks is already correct, so
      -- these stick until the emphasis changes.
      if glow and glow.pulseAnim then
        local want = (glow.pulseSecs or 0.60) * FX.pulseMul
        if glow._fxPulse ~= want then
          glow._fxPulse = want
          glow.pulseAnim:SetDuration(want)
        end
        if FX.pulseFloor then glow.pulseAnim:SetFromAlpha(FX.pulseFloor) end
        if FX.pulseOff then
          glow.pulse:Stop()
        elseif not safeCall(glow.pulse, "IsPlaying", false) then
          glow.pulse:Play()
        end
      end
      local shipped = renderer.cueEchoes and renderer.cueEchoes[key]
      if shipped then
        if FX.echoOff then shipped:Hide() else shipped:Show() end
        if shipped.rot and shipped._spinSecs and FX.echoMul ~= 1.0 then
          local want = shipped._spinSecs * FX.echoMul
          if shipped._fxEcho ~= want then
            shipped._fxEcho = want
            shipped.rot:SetDuration(want)
          end
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
      -- every draw but never re-sets the atlas after creation, so the override sticks.
      --
      -- ⚠ THE ALPHA IS ONLY WRITTEN WHEN THIS RIG ADDS ITS OWN ECHO, and that guard is a
      -- BUG FIX (2026-08-01).  It used to write unconditionally, from a era when the
      -- Renderer left the ring at full alpha and only this file ever dimmed it.  The
      -- Renderer now OWNS the ring's light (RING_LIGHT 0.45), so writing `echoAlpha()`'s
      -- rays-off value of 1.0 over the top silently drew the base ring at MORE THAN TWICE
      -- its shipped brightness — meaning `rt fx` was not the faithful baseline it claims
      -- to be, and every judgement made in it was made against a hotter ring than the HUD
      -- draws.  Leave the Renderer's value alone unless we are actually splitting light
      -- with an FX-owned echo.
      if glow then
        if FX.art then applyArt(glow, FX.art) end
        if FX.rays > 1.0 then glow:SetVertexColor(r, g2, b, baseA) end
      end
      -- THE ECHO'S OTHER TWO VARIABLES — size and light share — re-dialled in place, AFTER
      -- the base ring's colour is set above, because sliding the share has to move BOTH
      -- ends of it or the total light drifts as you dial.  This is the pair that had no
      -- knob, and the pair most likely to explain "the echo is the layer that goes wrong".
      if shipped and (FX.echoScale or FX.echoLight) then
        if FX.echoScale then
          local d = ring * FX.echoScale
          shipped:SetSize(d, d)
        end
        if FX.echoLight then
          shipped:SetVertexColor(r, g2, b, FX.echoLight)
          if glow then glow:SetVertexColor(r, g2, b, 1 - FX.echoLight) end
        end
      end
      -- LAST, so the ladder wins over every knob above it: when you are stepping rungs you
      -- want the rung's definition on screen, not a leftover from an earlier click.
      applyLadder(renderer, key, glow, shipped, r, g2, b, safeCall)
      -- Stop it the same frame it was started: it has had <1 frame to move anything, so
      -- this is as close to "the pop never ran" as the rig can get without a Renderer edit.
      if FX.noPop then
        local lay = renderer.cueLayers and renderer.cueLayers[key]
        if lay and lay.pop then lay.pop:Stop() end
      end
      -- 1. BACKING DISC.  Sized off the ring's OUTERMOST drawn extent (the echo, when one
      -- is on), not off the base ring — otherwise turning `rays` up leaves the echo
      -- hanging off an undersized disc.
      -- The base ring's ACTUAL period (per-emphasis: 1.6 on LATE, 4.0 elsewhere), which
      -- every extra layer is timed against.
      local baseSecs = (glow and (glow._fxSpin or glow._spinSecs)) or 4.0
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
          rot:SetOrigin("CENTER", 0, 0); rot:SetOrder(1)
          sg:SetLooping("REPEAT")
          echo._spin, echo._rot = sg, rot
          FX.echoes[key] = echo
        end
        mirrorArt(echo, glow)
        layerSpin(echo, baseSecs, FX.desync, FX.counter)
        echo:SetVertexColor(r, g2, b, echoA)
        echo:SetSize(outer, outer)
        echo:ClearAllPoints()
        echo:SetPoint("CENTER", glow, "CENTER", 0, 0)
        echo:Show()
        if not echo._spinOn then echo._spin:Play(); echo._spinOn = true end
      elseif echo then
        echo:Hide()
      end
      -- 2. GLOW STACK — extra additive copies of the live ring, DESYNCED (see layerSpin).
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
          rot:SetOrigin("CENTER", 0, 0); rot:SetOrder(1)
          sg:SetLooping("REPEAT")
          c._spin, c._rot = sg, rot
          copies[i] = c
        end
        if glow then
          mirrorArt(c, glow)
          -- Each copy gets its OWN ratio (i * desync): with 3+ layers a single shared
          -- ratio would put copies 2..n back in phase with each other, collapsing them
          -- into one slide instead of several.
          layerSpin(c, baseSecs, 1 + (FX.desync - 1) * i, FX.counter)
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
  FX.lastKeys, FX.lastRenderer = activeKeys, renderer   -- for `rt fx dump`
  captureFx(renderer, activeKeys)                       -- ...and for the desktop
end

-- LAYER DUMP — read back what is ACTUALLY on screen, per handle, instead of reasoning
-- about what the code should have produced.  Written after two wrong theories about why
-- LATE looks different: the answer has to come off the live widgets, because every guess
-- so far has been about numbers nobody had measured.  Reports, per cue: the base ring's
-- real size and spin, and every extra layer's size/period/direction/playing state.
local function describeLayer(tag, tex)
  if not tex then return end
  local rot = tex._rot
  local grp = tex._spin
  ns.Printf("      %-8s %5.1fpx  %s  period |cffffffff%s|r deg |cffffffff%s|r  %s  a=%.2f",
    tag, safeCall(tex, "GetWidth", 0),
    tex:IsShown() and "|cff88ff88shown|r" or "|cff808080hidden|r",
    rot and string.format("%.2fs", safeCall(rot, "GetDuration", 0)) or "-",
    rot and tostring(safeCall(rot, "GetDegrees", 0)) or "-",
    grp and (safeCall(grp, "IsPlaying", false) and "|cff88ff88playing|r" or "|cffff4040STOPPED|r")
        or "-",
    select(4, tex:GetVertexColor()) or 1)
end

local function fxDump()
  local r = FX.lastRenderer
  if not (r and FX.lastKeys) then
    ns.Print("rt fx dump: nothing drawn yet — run |cffffffff/cdmp rt fx|r first")
    return
  end
  ns.Heading("rt fx dump — what is ACTUALLY on each cue")
  ns.Printf("  desync |cffffffff%.1f|r  counter |cffffffff%s|r  glow x%d  rays %.2f  "
    .. "ring %.2fx  spin %.2fx", FX.desync, tostring(FX.counter), FX.stack, FX.rays,
    FX.scale, FX.spinMul)
  for key, emph in pairs(FX.lastKeys) do
    local glow = r.cueGlows[key]
    local dot  = r.cueFrames[key]
    ns.Printf("  |cff88ff88%s|r  (%s)  dot %.0fpx",
      tostring(emph), tostring(key), safeCall(dot, "GetWidth", 0))
    -- ⚠ THE CUE LAYER — the frame the ring is parented to, and the thing this dump was
    -- BLIND to.  Its scale is animated by the pop, and a rotating texture inside a frame
    -- whose scale is not 1 (or not uniform) is the shape of every "the spin surges"
    -- report.  Reported before the ring, because it is upstream of it.
    local lay = r.cueLayers and r.cueLayers[key]
    if lay then
      ns.Printf("      %-8s %5.1fx%-5.1f  scale |cffffffff%.3f|r  eff |cffffffff%.3f|r  pop %s",
        "LAYER", safeCall(lay, "GetWidth", 0), safeCall(lay, "GetHeight", 0),
        safeCall(lay, "GetScale", 1), safeCall(lay, "GetEffectiveScale", 1),
        lay.pop and (safeCall(lay.pop, "IsPlaying", false)
          and "|cffffcc00PLAYING|r" or "idle") or "-")
    else
      ns.Print("      |cffff4040no cue layer|r")
    end
    if glow then
      -- The BASE ring is the Renderer's, so its rotation lives on glow.rot with the
      -- per-emphasis period the Renderer chose (LATE 4.8s, everything else 12.0s).
      ns.Printf("      %-8s %5.1fx%-5.1f  %s  period |cffffffff%.2fs|r deg |cffffffff%s|r  %s",
        "BASE", safeCall(glow, "GetWidth", 0), safeCall(glow, "GetHeight", 0),
        glow:IsShown() and "|cff88ff88shown|r" or "|cff808080hidden|r",
        safeCall(glow.rot, "GetDuration", 0),
        tostring(safeCall(glow.rot, "GetDegrees", 0)),
        safeCall(glow.spin, "IsPlaying", false) and "|cff88ff88playing|r" or "|cffff4040STOPPED|r")
      -- THE BREATHE, with its ACTUAL period — the field that would have caught the "still
      -- too fast" reading in one command instead of two builds.  BOUNCE, so the cycle is
      -- twice the duration.
      local ps = safeCall(glow.pulseAnim, "GetDuration", 0)
      ns.Printf("      %-8s pulse %s  period |cffffffff%.2fs|r (cycle |cffffffff%.2fs|r)  "
        .. "floor |cffffffff%.2f|r", "",
        safeCall(glow.pulse, "IsPlaying", false) and "|cff88ff88playing|r" or "stopped",
        ps, ps * 2, safeCall(glow.pulseAnim, "GetFromAlpha", 0))
    else
      ns.Print("      |cffff4040no base ring|r")
    end
    for i, c in ipairs(FX.stacks[key] or {}) do describeLayer("copy" .. i, c) end
    describeLayer("echo", FX.echoes[key])
    describeLayer("ghost", FX.ghosts[key])
  end
  ns.Print("|cffffd100Compare the ROTATION and LATE rows: any field that differs is the "
    .. "cause.|r")
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
    if c.anchorTo ~= nil and renderer.registry[c.anchorTo] then
      set[c.anchorTo] = c.emphasis or true       -- truthy either way; the token is for the dump
    end
  end
  return set
end

local function fxStatus()
  ns.Heading("rt fx — experimental cue treatments")
  ns.Printf("  layers|cffffffff%s|r", FX.layers
    and string.format(" %d/%d — %s  |cff808080(every higher layer suppressed)|r",
                      FX.layers, LAYER_MAX, LAYER_NAMES[FX.layers])
    or " all — the shipped cue")
  ns.Printf("  bg    |cffffffff%s|r  (alpha %.2f, size %.2fx the ring's texture bounds)",
    FX.bg and "|cff88ff88on|r" or "off", FX.bgAlpha, FX.bgScale)
  ns.Printf("  glow  |cffffffffx%d|r  (%d additive cop%s — the BRIGHTNESS knob)",
    FX.stack, FX.stack - 1, FX.stack == 2 and "y" or "ies")
  ns.Printf("  desync|cffffffff%.1fx|r%s — extra layers vs the base ring's period. "
    .. "THE LATE RIPPLE; 1.0 = in phase, no effect",
    FX.desync, FX.counter and " |cffffffffrev|r" or "")
  ns.Printf("  ring  |cffffffff%.2fx|r size, spin |cffffffff%.2fx|r period  "
    .. "(LATE is already 1.4x / 2.5x faster than the rest)", FX.scale, FX.spinMul)
  ns.Printf("  rays  |cffffffff%.2fx|r (%s — this is the REACH knob, light-compensated)",
    FX.rays, FX.rays > 1.0 and string.format("echo at %.0f%% of the light", FX.raysAlpha * 100)
                            or "no echo")
  local ae = FX.art and GLOW_ART[FX.art]
  ns.Printf("  art   |cffffffff%s|r", ae and (FX.art .. ". " .. ae.label)
    or "(Renderer.lua's GLOW_ATLAS)")
  -- A CUE HAS THREE MOTIONS, not one.  Printed together because judging "how fast do the
  -- cues move" against only the ring is what let a 1.2s breathe and a ~1 Hz moiré sit
  -- unquestioned through a whole dialling session AND a spin retune.
  ns.Printf("  pulse |cffffffff%s|r  — the SHIPPED breathe, %s",
    FX.pulseOff and "off" or (FX.pulseFloor == 1.0 and "flat"
      or string.format("%.2fs cycle", 0.60 * FX.pulseMul * 2)),
    FX.pulseMul == 1.0 and "at the shipped period" or ("x" .. FX.pulseMul))
  ns.Printf("  echo  |cffffffff%s|r  light |cffffffff%.2f|r%s  size |cffffffff%.2fx|r%s  spin |cffffffff%.2fx|r",
    FX.echoOff and "hidden" or "on",
    FX.echoLight or 0.55, FX.echoLight and "" or " (stock)",
    FX.echoScale or 1.5, FX.echoScale and "" or " (stock)", FX.echoMul)
  ns.Print("        |cffffd100the echo ships BRIGHTER (0.55) than the ring it echoes (0.45)|r "
    .. "— `echo light` is the variable that has never been moved")
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
  if verb == "dump" then
    fxDump()
    return true
  elseif verb == "bg" then
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
  elseif verb == "desync" then
    FX.desync = math.max(1.0, math.min(4.0, tonumber(a1 or "") or (FX.desync + 0.5)))
    if words[4] then FX.counter = words[4] ~= "off" end
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
  elseif verb == "layers" or verb == "layer" then
    if a1 == "all" or a1 == "off" then FX.layers = nil
    elseif tonumber(a1) then
      FX.layers = math.max(0, math.min(LAYER_MAX, math.floor(tonumber(a1))))
    else
      local n = (FX.layers or -1) + 1
      FX.layers = n > LAYER_MAX and nil or n
    end
    ns.Heading("rt fx layers — build the cue up one layer at a time")
    for i = 0, LAYER_MAX do
      ns.Printf("  %s%d.|r %s", FX.layers == i and "|cff88ff88" or "|cff808080",
        i, LAYER_NAMES[i])
    end
    ns.Printf("now: |cffffffff%s|r", FX.layers
      and (FX.layers .. " — " .. LAYER_NAMES[FX.layers]) or "all (the shipped cue)")
  elseif verb == "nopop" then
    FX.noPop = not FX.noPop
    ns.Printf("rt fx nopop: |cffffffff%s|r — the RENDERER's arrival pop is %s",
      FX.noPop and "on" or "off",
      FX.noPop and "suppressed" or "left alone")
  elseif verb == "pulse" then
    -- The SHIPPED breathe: `pulse` cycles the period, `pulse flat` removes it entirely
    -- (the real A/B), `pulse off` stops the group.
    if a1 == "flat" then FX.pulseFloor = FX.pulseFloor and nil or 1.0
    elseif a1 == "off" then FX.pulseOff = not FX.pulseOff
    elseif tonumber(a1) then FX.pulseMul = math.max(0.25, math.min(6.0, tonumber(a1)))
    else FX.pulseMul = FX.pulseMul >= 4.0 and 1.0 or FX.pulseMul + 0.5 end
  elseif verb == "echo" then
    -- The SHIPPED echo (`rays` adds a SECOND one on top).  `echo sync <n>` walks its
    -- period toward the base's, which is what kills the counter-rotation moiré.
    local a2 = tonumber(words[4])
    if a1 == "sync" then
      FX.echoMul = a2 or (FX.echoMul <= 0.45 and 1.0 or FX.echoMul - 0.15)
    elseif a1 == "light" or a1 == "dim" then
      FX.echoLight = a2 or ((FX.echoLight or 0.55) - 0.10)
      if FX.echoLight < 0.05 then FX.echoLight = nil end
    elseif a1 == "size" then
      FX.echoScale = a2 or ((FX.echoScale or 1.5) - 0.15)
      if FX.echoScale < 1.05 then FX.echoScale = nil end
    elseif a1 == "stock" then
      FX.echoLight, FX.echoScale, FX.echoMul = nil, nil, 1.0
    else FX.echoOff = not FX.echoOff end
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
    ns.Print("  |cff88ff88nopop|r         suppress the RENDERER's arrival pop (the one thing")
    ns.Print("         that differs between `off->3` and `off->2->3`)")
    ns.Print("  |cffffd100layers|r [n|all]  |cffffd100START HERE.|r Strip the cue to a bare dot and")
    ns.Print("         add ONE layer at a time — disc, ring, spin, breathe, echo.")
    ns.Print("         The first rung that looks wrong IS the culprit.")
    ns.Print("  |cff88ff88bg|r [size <n>|alpha <n>]  black backing disc (contrast)")
    ns.Print("  |cff88ff88glow|r [1-4]     additive ring copies — the BRIGHTNESS knob")
    ns.Print("  |cff88ff88desync|r [n] [off]  extra layers' spin ratio vs the base ring —")
    ns.Print("         |cffffd100this is the LATE ripple|r; 1.0 locks them in phase")
    ns.Print("  |cff88ff88ring|r [n] / |cff88ff88spin|r [n]  ring SIZE / spin PERIOD, x the Renderer's")
    ns.Print("         (LATE already runs 1.4x bigger + 2.5x faster than the rest)")
    ns.Print("  |cff88ff88rays|r [n] [a]   outer ring echo — the REACH knob, light-compensated")
    ns.Print("  |cff88ff88art|r [n|reset|list]  swap the ring ART — incl. our CC0 TGAs")
    ns.Print("  |cff88ff88pulse|r [n|flat|off]  the SHIPPED breathe — |cffffd100the other")
    ns.Print("         continuous motion|r, a 1.2s cycle nothing here could dial before")
    ns.Print("  |cff88ff88echo|r [light|size|sync|stock]  the SHIPPED echo. |cffffd100light is the")
    ns.Print("         untested one|r — it ships at 0.55, BRIGHTER than the 0.45 ring it")
    ns.Print("         echoes; size walks 1.5x down; sync walks its period to the base's")
    ns.Print("  |cff88ff88pop|r [peak]     one-shot scale on cue APPLICATION")
    ns.Print("  |cff88ff88ghost|r          one-shot scale+fade on cue REMOVAL")
    ns.Print("  |cff88ff88sound|r [n|id|file|sweep|channel|test|off|list]  cue SFX (bare = next)")
    ns.Print("         |cffffd100no volume API|r — `sound sweep` walks the loud pool,")
    ns.Print("         `sound channel` picks which slider governs it")
    ns.Print("  |cff88ff88status|r         print the current settings")
    ns.Print("  |cff88ff88dump|r           read back what is ACTUALLY on each cue "
      .. "(sizes, spin periods, directions) — use this when a state looks different "
      .. "and you want to know why")
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
    ns.Print("  |cff88ff88lab|r — the RENDER LAB: three blind implementations of the "
      .. "spinning ring, side by side (`rt lab 1|2|3` magnifies one)")
    ns.Print("usage: |cffffffff/cdmp rt <name>|r | fx | lab | rotate | off")
    return
  end
  stopRotate()                               -- any view change cancels a live rotate
  clearProcGlow()                            -- ...and drops any native proc glow
  -- THE RENDER LAB (RenderLab.lua) is a clean-slate experiment that shares nothing with
  -- this file — but it still goes through this one door, so `/cdmp rt off` tears it down
  -- with everything else and no second teardown path can drift from this one.
  if words[1] == "lab" then return ns.RenderLab(words[2]) end
  ns.RenderLabHide()                         -- ...and any other view drops the lab
  if words[1] == "fx" then return fxCommand(words) end
  stopSoundLoop()                            -- ...and silences an audition still looping
  clearFX()                                  -- ...and any experimental chrome
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
