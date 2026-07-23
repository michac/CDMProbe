-- HudCueWatch.lua — the CUE COLOUR WATCHDOG.  M4.6, play-test-5 follow-up.
--
-- WHY THIS EXISTS.  Play-test 5 reported cue bars that were "usually green, but
-- periodically white".  White is not in the cue palette (JUDGE cyan / SOON yellow
-- / ROTATION green / LATE green), so a white bar can only mean the hue was LOST —
-- but nothing in the addon could see that happen.  The first read of the evidence
-- got it wrong in exactly the way an un-instrumented bug invites: a single
-- screenshot was generalised to "the hue is lost for EVERY level", when the
-- player's actual report was INTERMITTENT.  Those are different defects with
-- different causes, and guessing between them from a still image is not analysis.
--
-- So: measure it.  This module samples what the cue textures ACTUALLY render and
-- records every divergence from what they were told to render, with enough
-- context to test a hypothesis rather than to admire the failure.
--
-- THE HYPOTHESIS IT IS BUILT TO KILL OR CONFIRM.  Colour reached the bar ONLY via
-- SetGradient; the texture's own base was set white first.  Anything that drops
-- the gradient therefore renders white, and the obvious periodic suspect is the
-- ALPHA BREATHE: `ag:Play()` runs on exactly the two levels that pulse — SOON and
-- LATE — and ROTATION, the steady green, does not pulse.  "Usually green,
-- periodically white" is what you would see if a playing alpha animation dropped
-- the gradient on the pulsing levels only.
--
--   PREDICTION (falsifiable): mismatches cluster on SOON/LATE with `playing=true`,
--   and are absent on ROTATION/JUDGE.  If mismatches show up on ROTATION too, the
--   animation is NOT the cause and this hypothesis is dead — which is worth just
--   as much as confirming it.
--
-- ⚠ NOTE ON THE M4.6 FIX.  paintCue now paints the LEVEL COLOUR as the base and
-- uses the gradient for depth only, so a dropped gradient degrades to a flat
-- correct colour instead of white.  That likely REMOVES THE SYMPTOM without
-- anyone having proved the cause — which is precisely why this watchdog reports
-- the underlying `gradientLost` separately from the visible `whiteish`.  A fix
-- whose mechanism you never confirmed is a fix that comes back.
--
-- COST.  A 4Hz ticker over the bound items, reading our OWN textures — no secret
-- reads, no game state, no strings on the sample path (strings are built only
-- when a NEW divergence is recorded, the HudLog discipline).
local ADDON, ns = ...

ns.HudCueWatch = {}
local W = ns.HudCueWatch

local SAMPLE_HZ   = 4
local MAX_EVENTS  = 40      -- ring: enough to see a pattern, bounded for SavedVars
-- How far a channel may drift before we call it a divergence.  Generous: we are
-- hunting "rendered white instead of green", not colour-grading.
local TOL         = 0.12

W.on        = false
W.samples   = 0
W.mismatch  = 0
W.events    = {}            -- ring of divergence records
W.byLevel   = {}            -- level -> count
W.byPlaying = { playing = 0, still = 0 }
local ticker

local function bump(t, k) t[k] = (t[k] or 0) + 1 end

-- Is this rgb close to plain white?  A white bar is the reported symptom, and it
-- is worth counting separately from "some other wrong colour": they implicate
-- different mechanisms (base-colour showing through vs. a bad paint).
local function isWhiteish(r, g, b)
  return r > 0.85 and g > 0.85 and b > 0.85
end

-- One divergence record.  Everything here is a plain scalar so it can persist
-- into SavedVariables untouched — no frames, no tables, nothing secret (these are
-- OUR textures; the game is never read).
local function record(name, level, exp, got, playing, receded, shown)
  W.mismatch = W.mismatch + 1
  bump(W.byLevel, level)
  if playing then W.byPlaying.playing = W.byPlaying.playing + 1
  else W.byPlaying.still = W.byPlaying.still + 1 end
  local e = {
    t       = GetTime(),
    name    = name,
    level   = level,
    playing = playing and true or false,
    shown   = shown and true or false,
    recede  = receded,
    -- what it should be vs what it is, to 2dp — enough to tell green from white
    expR = math.floor(exp[1] * 100 + 0.5) / 100,
    expG = math.floor(exp[2] * 100 + 0.5) / 100,
    expB = math.floor(exp[3] * 100 + 0.5) / 100,
    gotR = math.floor(got[1] * 100 + 0.5) / 100,
    gotG = math.floor(got[2] * 100 + 0.5) / 100,
    gotB = math.floor(got[3] * 100 + 0.5) / 100,
    whiteish = isWhiteish(got[1], got[2], got[3]),
  }
  W.events[#W.events + 1] = e
  if #W.events > MAX_EVENTS then table.remove(W.events, 1) end
end

-- One sampling pass.  Reads GetVertexColor off each visible cue texture and
-- compares it against the palette entry for the level the cue was SET to.
local function sample()
  if not (ns.Hud and ns.Hud.on and ns.Hud.items) then return end
  W.samples = W.samples + 1
  for _, e in pairs(ns.Hud.items) do
    local o = e.item and e.item.__hud
    local t = o and o.cue
    local level = o and o.cueLevel
    if t and level then
      local exp = ns.HudChrome.CueColor and ns.HudChrome.CueColor(level)
      if exp then
        local ok, r, g, b = pcall(t.GetVertexColor, t)
        if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
          if math.abs(r - exp[1]) > TOL or math.abs(g - exp[2]) > TOL
             or math.abs(b - exp[3]) > TOL then
            local playing = false
            if t.ag then
              local okp, p = pcall(t.ag.IsPlaying, t.ag)
              playing = okp and p or false
            end
            local oks, s = pcall(t.IsShown, t)
            local shown = oks and s or false
            record(ns.HudState and ns.HudState.LiveName and ns.HudState.LiveName(e) or "?",
              level, exp, { r, g, b }, playing, ns.HudChrome.GetRecede(), shown)
          end
        end
      end
    end
  end
end

function W.Start()
  if W.on then return end
  W.on = true
  if ticker then ticker:Cancel() end
  ticker = C_Timer.NewTicker(1 / SAMPLE_HZ, sample)
end

function W.Stop()
  W.on = false
  if ticker then ticker:Cancel() end
  ticker = nil
end

function W.Clear()
  W.samples, W.mismatch = 0, 0
  W.events = {}
  W.byLevel = {}
  W.byPlaying = { playing = 0, still = 0 }
end

-- The structured observation, for CDMProbeDB.probe.* and `wowkb.cdmp`.  Plain
-- scalars only.  Note it reports the RATE, not just the count: "12 mismatches"
-- means nothing without the sample count behind it.
function W.Snapshot()
  local byLevel = {}
  for k, v in pairs(W.byLevel) do byLevel[k] = v end
  local ev = {}
  for i, e in ipairs(W.events) do ev[i] = e end
  return {
    on        = W.on,
    samples   = W.samples,
    mismatch  = W.mismatch,
    rate      = (W.samples > 0) and (W.mismatch / W.samples) or 0,
    byLevel   = byLevel,
    playing   = W.byPlaying.playing,
    still     = W.byPlaying.still,
    events    = ev,
  }
end

-- The chat rendering of the SAME values (the M4.5 T3 rule: compute once, render
-- twice, so the report and the snapshot cannot disagree).
function W.Report()
  ns.Heading("Cue colour watchdog (M4.6) — is the hue reaching the texture?")
  if not W.on then
    ns.Print("  |cffff4040off|r — /cdmp hud cuewatch on, then play a pull.")
    return
  end
  ns.Printf("  samples %d   divergences %d   (%.1f%% of samples)",
    W.samples, W.mismatch, (W.samples > 0) and (100 * W.mismatch / W.samples) or 0)
  if W.mismatch == 0 then
    ns.Print("  |cff40ff40no divergence seen|r — every cue rendered the colour it was set to.")
    ns.Print("  ⚠ absence of evidence: if no SOON/LATE cue was ever up, this proves nothing.")
    return
  end
  local parts = {}
  for lvl, n in pairs(W.byLevel) do parts[#parts + 1] = string.format("%s:%d", lvl, n) end
  table.sort(parts)
  ns.Printf("  by level: %s", table.concat(parts, "  "))
  -- THE decisive line for the hypothesis.
  ns.Printf("  while the breathe was PLAYING: %d   while still: %d",
    W.byPlaying.playing, W.byPlaying.still)
  local white = 0
  for _, e in ipairs(W.events) do if e.whiteish then white = white + 1 end end
  ns.Printf("  rendered WHITEISH: %d of the last %d recorded", white, #W.events)
  for i = math.max(1, #W.events - 5), #W.events do
    local e = W.events[i]
    ns.Printf("    %s  %s  expected %.2f/%.2f/%.2f  got %.2f/%.2f/%.2f  %s",
      e.name, e.level, e.expR, e.expG, e.expB, e.gotR, e.gotG, e.gotB,
      e.playing and "|cffffd100(breathe PLAYING)|r" or "(still)")
  end
end
