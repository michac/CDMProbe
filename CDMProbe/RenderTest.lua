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
    -- ⚠ THE SQUARES ARE POOLED ACROSS VIEWS, SO CLICKABILITY HAS TO BE UNSET HERE.  The
    -- pop lab makes two of them clickable; without this reset, `states` would inherit
    -- live click handlers pointing at a DrawList it is not showing.  Each view opts in.
    icon:EnableMouse(false)
    icon:SetScript("OnMouseDown", nil)
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

-- Cancel whatever live view is running.  ⚠ IT ALSO BUMPS `labGen`, and that is not
-- bookkeeping for its own sake: the pop lab schedules C_Timer callbacks that draw, so a
-- view change while one is in flight would repaint the pop lab's DrawList over whatever
-- view you just asked for.  Every callback captures the generation and refuses if it moved.
local labGen = 0
local function stopTicker()
  labGen = labGen + 1
  if ns._renderTestTicker then
    ns._renderTestTicker:Cancel()
    ns._renderTestTicker = nil
  end
end

local function startRotate()
  stopTicker()
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

--------------------------------------------------------------------------------
-- `/cdmp rt pop` — THE POP LAB.  Four panels, one open question.
--------------------------------------------------------------------------------
-- WHY IT EXISTS.  The pop reproduces the spin artefact (Renderer.lua, the header at
-- POP_PEAK), and every observation of it so far has come from PLAY: a whole rotation
-- moving, cues arriving and leaving on their own schedule, several icons at once.  That is
-- the worst possible place to characterise a visual defect — you cannot see the control,
-- you cannot choose the moment, and you cannot look at a pop on its own.  This gives all
-- three.
--
-- ⚠ THE DESIGN RULE: EVERY PANEL IS THE SHIPPED PATH, MINUS OR PLUS EXACTLY ONE THING.
-- Nothing here reimplements a pop, a ring or a draw — panels 1-3 differ only in WHO calls
-- the shipped `R:popCue`, and panel 4 differs only in the shipped `R:Draw` edge it feeds.
-- The archived `rt fx` rig is the cautionary tale: it claimed to be a faithful A/B, drifted
-- from the shipped path, and showed a ring at over twice shipped brightness for six builds.
--
--   1 STEADY      the CONTROL.  Drawn once, never popped, rings turn undisturbed forever.
--   2 AUTO-POP    identical to panel 1 in every respect except that it gets popped on a
--                 2s timer.  Side by side with panel 1 this is the whole A/B: if the two
--                 spins diverge, the pop is the only thing that could have done it.
--   3 CLICK       the same pop, at a moment YOU choose.  Watch a clean ring, click, and
--                 see whether it changes AT the click — which separates "the pop breaks
--                 it" from "it was always going to drift".
--   4 SOLO        a pop with nothing else on screen: click spawns the cue (a real
--                 ARRIVAL, so the shipped edge path pops it) and tears it down once the
--                 animation is over.  For judging the pop ITSELF, not its aftermath.
--
-- ⚠ NOTHING POPS ON LOAD.  `cuedLast` is seeded before the opening draw so panels 1-3 are
-- not arrivals.  A control that got popped once before you looked at it is not a control.
-- ⚠ PANELS 5 AND 6 ARE PROBES, NOT POPS, AND THE DIFFERENCE IS THE POINT.  The measured
-- symptom is that a popped ring spins FASTER, permanently, from the moment of the pop —
-- which our own code cannot explain, because nothing in it touches the rings (renderer_spec
-- pins that a pop never Play()s either Rotation, and that assertion passes).  So the
-- question stops being "what does our pop do" and becomes "what does the CLIENT do when an
-- animation plays near a running Rotation".  These two answer it by changing exactly one
-- property of the trigger each:
--
--   5 ALPHA    an ALPHA animation on the cue layer instead of a Scale.  Same ancestor,
--              same duration, visually inert (1 -> 1).  Speeds the ring up too ⇒ the
--              trigger is ANY animation on an ancestor.  Leaves it alone ⇒ it is
--              specifically a TRANSFORM, which points at the scale/rotation composition.
--   6 FAR      a Scale animation on an UNRELATED frame — same container, no relationship
--              to this cue at all.  Speeds the ring up ⇒ ancestry is irrelevant and this
--              is global to the animation system, which would reframe the whole hunt.
--
-- ⚠ BOTH PROBES ARE VISUALLY INERT ON PURPOSE.  Flight 2 (v0.32.77) established that a
-- Scale animating 1 -> 1 still reproduces, so what is under test is the PRESENCE of a
-- running animation, not anything you can see.  A probe that also moved something would
-- confound the two back together.
local POP_LAB_ICONS = 6
local POP_LAB_INTERVAL = 2.0
local POP_LAB_CAPTIONS = {
  "1 STEADY", "2 AUTO-BURST 2s", "3 CLICK=BURST", "4 CLICK=SOLO", "5 CLICK=ALPHA",
  "6 CLICK=FAR",
}
-- The PERSISTENT panels — the ones carrying a ring that is measurable end to end.  Panel 4
-- is absent by design: it only exists between a click and its teardown.
local POP_LAB_KEYS = { "fake1", "fake2", "fake3", "fake5", "fake6" }

-- The resting DrawList: every persistent panel lit, panel 4 empty until it is clicked.
-- ⚠ EVERY PROBE REPORTS THAT IT FIRED, AND THAT IS NOT DECORATION.  These are visually
-- inert by design, so "I clicked and nothing happened" is exactly what a probe that
-- SILENTLY FAILED looks like — and a null result you cannot distinguish from a dead
-- instrument is not a result at all.  `IsPlaying()` is read back from the client after the
-- Play, so the line says what the client thinks, not what we asked for.
local function firedProbe(label, g)
  local playing = g and g.IsPlaying and g:IsPlaying()
  ns.Printf("rt pop: %s fired — client reports playing=|cffffffff%s|r", label, tostring(playing))
end

-- ⚠ Reads the OUTER RING'S ACTUAL WIDTH rather than recomputing it: the flare has to be
-- sized by the same number the shipped path uses, or the lab is auditioning a different
-- effect from the one that ships.
local function fireShippedBurst(r, key)
  local outer = r.cueRingOut[key]
  if not outer then ns.Print("rt pop: no rings on " .. key .. " — did NOT fire"); return end
  r:fireBurst(key, outer:GetWidth(), r.theme.ROTATION)
  local b = r.cueLayers[key] and r.cueLayers[key].burst
  firedProbe("burst on " .. key, b and b.groups and b.groups[1])
end

local function popLabSteady()
  local cues = {}
  for _, key in ipairs(POP_LAB_KEYS) do cues[#cues + 1] = cue(key, "ROTATION") end
  return { cues = cues, keybinds = { kb("fake4", "4") } }
end

-- PROBE 5 — an Alpha animation on the layer.  ⚠ `fromAlpha` defaults to 0.0, so both ends
-- are set explicitly to keep it inert; the Scale probe below needs no such care because
-- every scale attribute already defaults to 1.0 (UI.xsd:1500).
local function probeAlpha(frame)
  if not frame then ns.Print("rt pop: no cue layer on panel 5 — probe did NOT fire"); return end
  local g = frame._probeAlpha
  if not g then
    g = frame:CreateAnimationGroup()
    local a = g:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(1)
    a:SetDuration(R.POP_SECS)
    frame._probeAlpha = g
  end
  g:Stop()
  g:Play()
  firedProbe("alpha-on-layer", g)
end

-- PROBE 6 — a Scale animation on a frame with no relationship to any cue.
local function probeFarScale(rig)
  local f = rig._probeFar
  if not f then
    f = CreateFrame("Frame", nil, rig.container)
    f:SetSize(8, 8)
    f:SetPoint("BOTTOM", rig.container, "BOTTOM", 0, 8)
    local g = f:CreateAnimationGroup()
    local a = g:CreateAnimation("Scale")   -- endpoints default to 1.0 -> inert
    a:SetDuration(R.POP_SECS)
    a:SetOrigin("CENTER", 0, 0)
    f._probe = g
    rig._probeFar = f
  end
  f._probe:Stop()
  f._probe:Play()
  firedProbe("far-scale", f._probe)
end

-- ⚠ THE CANDIDATE PANELS (a dot-only pop, an alpha flash, the burst) ARE GONE FROM HERE
-- BECAUSE THE BURST WON AND WAS PROMOTED.  It lives in Renderer.lua as R.BURST /
-- R:fireBurst, and panels 2 and 3 below fire THAT — the shipped path, never a copy of it.
-- Recover the two losers from git history if a future round wants to re-audition them;
-- keeping dead candidates here is how a rig starts drifting from what actually ships.
local BURST = R.BURST      -- ⚠ THE SHIPPED TABLE, deliberately not a copy
local BURST_ORDER = { "size", "peak", "alpha", "back", "secs", "stack", "spin" }

-- `/cdmp rt pop burst [<knob> <value>]` — dial it live.  ⚠ This is a LAB dial, and the
-- winner gets PROMOTED into Renderer.lua properly rather than shipped from here; that is
-- the one rule the archived `rt fx` rig broke and paid for.
local function burstKnob(rest)
  local knob, value = (rest or ""):match("^(%a+)%s+([%d%.]+)$")
  if knob and BURST[knob] ~= nil then
    BURST[knob] = knob == "stack" and math.max(1, math.floor(tonumber(value))) or tonumber(value)
    ns.Printf("rt pop burst: |cffffffff%s|r = %s — click panel 9", knob, tostring(BURST[knob]))
    return
  end
  if rest and rest ~= "" then ns.Printf("rt pop burst: unknown knob '%s'", rest) end
  local parts = {}
  for _, k in ipairs(BURST_ORDER) do parts[#parts + 1] = ("%s %s"):format(k, tostring(BURST[k])) end
  ns.Heading("rt pop burst — " .. table.concat(parts, " · "))
  ns.Print("  |cffffffff/cdmp rt pop burst <knob> <value>|r — size (start px) · peak (grow x) · "
    .. "alpha (flare) · back (dark disc, 0 = off) · secs · stack (additive copies) · "
    .. "spin (degrees over the flare; stacked copies counter-rotate)")
end

--------------------------------------------------------------------------------
-- `/cdmp rt pop stats` — MEASURE the spin instead of describing it.
--------------------------------------------------------------------------------
-- "Super speed spinny" is an observation, not a number, and the number is what discriminates
-- the remaining theories.  This samples every panel's INNER ring straight off the client
-- (`Rotation:GetProgress()`), unwraps it across revolutions and reports the ACTUAL angular
-- rate beside what the animation was TOLD its period is.  Two things to read:
--
--   * the RATIO against panel 1.  A clean 2.00x says the rotation is being advanced twice
--     per frame — a duplicated driver, and a completely different bug from a mistimed one.
--     A ratio that CLIMBS with each further pop says something accumulates per pop.
--   * `told` vs `measured`.  If SetDuration still reads 6.00s while the ring measures 3s,
--     the client is not honouring its own duration, and no amount of re-timing will help.
--
-- ⚠ It measures the SHIPPED rings — `renderer.cueRingIn[key].rot` — never a copy.  A probe
-- that instruments its own private animation can pass while the real one fails, which is
-- the failure mode this whole file's design rule exists to prevent.
local MEASURE_SECS, MEASURE_HZ = 3.0, 20

local function popLabMeasure()
  local rig = ns._renderTestRig
  local r = rig and rig.renderer
  if not (r and r.cueRingIn and r.cueRingIn["fake1"]) then
    ns.Print("rt pop: no pop lab running — |cffffffff/cdmp rt pop|r first")
    return
  end
  local gen = labGen
  -- ⚠ BOTH RINGS, NOT JUST THE INNER ONE.  The first cut of this measured `cueRingIn`
  -- alone and reported "1.00x control" across the board — which was true and useless: the
  -- perceived rate of the PAIR is dominated by the beat between them (8-fold art, 6s
  -- against 9s counter-rotating = 2.2 Hz, see Renderer.lua's RING_SCALE header), so an
  -- instrument that watches one ring cannot see the quantity the eye is actually reading.
  -- The SIZES and the layer SCALE ride along for the same reason: a ring left larger, or a
  -- layer left at a fraction, changes what the eye clocks without touching a period.
  local acc, prev = { inner = {}, outer = {} }, { inner = {}, outer = {} }
  for _, key in ipairs(POP_LAB_KEYS) do acc.inner[key], acc.outer[key] = 0, 0 end
  local pools = { inner = r.cueRingIn, outer = r.cueRingOut }
  local function sample()
    for which, pool in pairs(pools) do
      for _, key in ipairs(POP_LAB_KEYS) do
        local ring = pool[key]
        local p = ring and ring.rot and ring.rot:GetProgress()
        if type(p) == "number" then
          -- Progress runs 0->1 per revolution and wraps.  At 6s and 20 Hz one step is
          -- ~0.008, so a NEGATIVE step is a wrap and never an ambiguity — it stays
          -- unambiguous even at ten times the nominal rate.
          if prev[which][key] then
            local d = p - prev[which][key]
            if d < 0 then d = d + 1 end
            acc[which][key] = acc[which][key] + d
          end
          prev[which][key] = p
        end
      end
    end
  end
  local t0 = GetTime()
  sample()
  C_Timer.NewTicker(1 / MEASURE_HZ, sample, math.floor(MEASURE_SECS * MEASURE_HZ))
  C_Timer.After(MEASURE_SECS + 0.2, function()
    if labGen ~= gen or ns._renderTestRig ~= rig then return end
    local elapsed = GetTime() - t0
    ns.Heading(("rt pop — measured over %.1fs (nominal inner 0.167 / outer 0.111 rev/s)"):format(elapsed))
    ns.Print("  |cff808080beat = (inner + outer rev/s) x 8, the 8-fold sprite's spoke rate — "
      .. "THE quantity the eye reads|r")
    for _, key in ipairs(POP_LAB_KEYS) do
      local idx = tonumber(key:match("(%d+)$"))
      local inRev  = acc.inner[key] / elapsed
      local outRev = acc.outer[key] / elapsed
      local layer  = r.cueLayers[key]
      local scale  = layer and layer.GetScale and layer:GetScale()
      local ringIn, ringOut = r.cueRingIn[key], r.cueRingOut[key]
      ns.Printf("  |cff88ff88%-14s|r in %.3f  out %.3f  |cffffffffbeat %.2f Hz|r  "
        .. "scale %.3f  size %d/%d",
        POP_LAB_CAPTIONS[idx] or key, inRev, outRev, (inRev + outRev) * 8,
        type(scale) == "number" and scale or -1,
        ringIn and math.floor(ringIn:GetWidth() + 0.5) or -1,
        ringOut and math.floor(ringOut:GetWidth() + 0.5) or -1)
    end
  end)
end

local function startPopLab()
  stopTicker()
  local gen = labGen                          -- ...captured AFTER the bump; see stopTicker
  local rig = buildRig(POP_LAB_ICONS, POP_LAB_CAPTIONS)
  rig.container:Show()
  local r = rig.renderer
  local alive = function() return labGen == gen and ns._renderTestRig == rig end

  -- Seed the previous cue set so the opening draw is not an arrival for panels 1-3.
  r.cuedLast = {}
  for _, key in ipairs(POP_LAB_KEYS) do r.cuedLast[key] = true end
  r:Draw(popLabSteady())

  -- PANEL 2 — the shipped pop, out of band, on a timer.  Deliberately NOT a remove-and-
  -- re-add: that would also exercise the departure bookkeeping (the OTHER surviving
  -- suspect), and then a difference against panel 1 would not tell you which one did it.
  ns._renderTestTicker = C_Timer.NewTicker(POP_LAB_INTERVAL, function()
    if alive() then r:fireBurst("fake2", r.cueRingOut["fake2"]:GetWidth(), r.theme.ROTATION) end
  end)

  -- PANEL 3 — the same call, on your click.
  rig.icons[3]:EnableMouse(true)
  rig.icons[3]:SetScript("OnMouseDown", function()
    if alive() then fireShippedBurst(r, "fake3") end
  end)

  -- PANEL 4 — spawn, pop, tear down.  ⚠ The teardown drops fake4 from `cuedLast` FIRST, so
  -- it is not a DEPARTURE: otherwise the panel would pop twice per click (in, then out) and
  -- there would be no single pop to judge.  `busy` swallows a click mid-flight for the
  -- same reason.
  local busy = false
  rig.icons[4]:EnableMouse(true)
  rig.icons[4]:SetScript("OnMouseDown", function()
    if busy or not alive() then return end
    busy = true
    local dl = popLabSteady()
    dl.cues[#dl.cues + 1] = cue("fake4", "ROTATION")   -- NEW handle -> the shipped arrival
    r:Draw(dl)
    C_Timer.After(R.BURST.secs + 0.10, function()
      busy = false
      if not alive() then return end
      r.cuedLast["fake4"] = nil
      r:Draw(popLabSteady())
    end)
  end)

  -- PANELS 5 + 6 — the two probes.  Each fires an INERT animation and touches nothing
  -- else; the cue under them is drawn exactly like the control and is never popped.
  rig.icons[5]:EnableMouse(true)
  rig.icons[5]:SetScript("OnMouseDown", function()
    if alive() then probeAlpha(r.cueLayers["fake5"]) end
  end)
  rig.icons[6]:EnableMouse(true)
  rig.icons[6]:SetScript("OnMouseDown", function()
    if alive() then probeFarScale(rig) end
  end)
end

-- `/cdmp rt [<name>|rotate|pop|off|list]` — render a fixture; bare = the first one
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
    ns.Print("  |cff88ff88pop|r — the POP LAB: a steady control beside an auto-popping twin, "
      .. "plus click-to-pop and a solo pop (panels 3+4 are |cffffffffclickable|r)")
    ns.Print("  |cff88ff88pop stats|r — MEASURE every lab panel's spin (both rings + the beat)")
    ns.Print("  |cff88ff88pop burst <knob> <value>|r — dial panel 9's burst live, no reload")
    ns.Print("usage: |cffffffff/cdmp rt <name>|r | rotate | pop | pop stats | off")
    return
  end
  -- ⚠ BEFORE stopTicker: measuring must not tear down the very lab it is measuring.
  local burstRest = arg:match("^pop burst%s*(.*)$")
  if burstRest then
    burstKnob(burstRest)
    return
  end
  if arg == "pop stats" or arg == "popstats" then
    popLabMeasure()
    ns.Printf("rt pop: sampling %.1fs …", MEASURE_SECS)
    return
  end
  stopTicker()                               -- any view change cancels a live view
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
  if arg == "pop" then
    startPopLab()
    ns.Printf("rt: |cffffffffpop lab|r — 1 STEADY · 2 AUTO-POP %.1fs · 3 CLICK=pop · "
      .. "4 CLICK=solo · 5+6 the safety probes", POP_LAB_INTERVAL)
    ns.Print("  |cffffffff2 and 3 fire the SHIPPED burst|r (R:fireBurst) against panel 1's "
      .. "untouched control — the standing regression check for the spin artefact.")
  ns.Print("  |cffffffff/cdmp rt pop burst <knob> <value>|r dials panel 9 LIVE (no reload): "
      .. "size · peak · alpha · back · secs · stack.  Bare = show current values.")
  ns.Print("  |cffffffff/cdmp rt pop stats|r measures both rings + the beat.  Every probe "
      .. "prints whether it actually fired.")
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
