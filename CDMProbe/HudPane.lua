-- HudPane.lua — the SEQUENCE PANE.  M4.
--
-- WHY IT IS ITS OWN FRAME.  The sequence helper (opener + burst) is
-- INSTRUCTIONAL and wants CENTRAL vision, near the character where the eyes
-- already are — but every other HUD surface is VIEWER-ANCHORED to the CDM column
-- (HudChrome's terminal/rail, HudQueue's above-the-panel strip).  So the pane is
-- the addon's FIRST UIParent-anchored frame: movable, drag-to-save, and NOT part
-- of Edit Mode (its own lock/unlock + a saved position is the only placement path).
--
-- ⚠ It defaults BELOW the character, not above (§4.1, play-test 5).  The original
-- M4 build read "central vision" as "over the head" and put it there; that band is
-- the busiest real estate on screen (nameplates, cast bars, floating combat text)
-- and the pane competed with all of it.  See DEFAULT_POS below.
--
-- WHAT IT IS.  A WINDOW (§4.2) — a backing, a title bar and hairline separators,
-- so the rows read as one object rather than free-floating text — holding:
--   * a TITLE BAR carrying the header ("BURST" / "OPENER").
--   * a PREREQS ROW (a FontString) — the pre-pull wall-down state ("Tyrant ·
--     Dreadstalkers"), each lit bright when met, dim when not.
--   * a SHARD DOT ROW (§4.3) — the `5 shards` prereq as SHARD_CAP dots rather
--     than a word.  Hidden, never drawn empty, when shards are unreadable.
--   * a hosted HUDQUEUE STRIP — the draining ghost of keybinds, mounted INSIDE
--     the pane via HudQueue's new `host` arg.
--
-- ONE PANE, RE-ARMED.  The opener and the burst window are two CONSUMERS that
-- arm the same pane (the "second consumer = data + a trigger" pattern, per
-- HudOpener.lua's header).  `P.owner` tracks which one armed it so a consumer
-- only ever advances/dissolves ITS OWN arm — the burst window re-arming mid-pull
-- silently stops the opener from touching the strip.
--
-- JUICE IS ASYMMETRIC (§0.5.8.7).  A correct key flashes; completing the
-- sequence flourishes; a MISS only DIMS GENTLY and never scolds — a deviation is
-- often a legit opener branch, so a red "WRONG" would be lying about a good play.
-- The juice is wired through onCorrect/onMiss/onComplete SEAMS so M6 can add
-- sound WITHOUT refactoring (respecting the HudChrome.lua:920 no-PlaySound fence).
local ADDON, ns = ...

ns.HudPane = {}
local P = ns.HudPane

-- Terminal palette echoed from HudChrome/HudQueue (kept file-local there by
-- design; these are constants, not a shared contract).
-- Neutral palette (M4.3 — the CRT green is retired).  Near-white for "live", a
-- muted grey for "upcoming / not-yet".
local TERM      = { 0.92, 0.94, 0.98 }
local TERM_DIM  = { 0.45, 0.47, 0.52 }
local function hex(c)
  return string.format("%02x%02x%02x",
    math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local BRIGHT = "|cff" .. hex(TERM)
local DIM    = "|cff" .. hex(TERM_DIM)
local SEP    = DIM .. "  ·  |r"

-- M4.6 §4.2 — the pane is now a WINDOW: title bar, separators, a persistent
-- backing.  Deliberately NOT Blizzard-frame ornate (no gold, no tiled borders) —
-- just enough surface to read the four rows as ONE object rather than four
-- free-floating strings over the world.
-- Height grew from 60 to fit the title bar and the shard row (§4.3).
local PANE_W, PANE_H = 340, 92
local TITLE_H  = 18              -- title bar strip
local PAD      = 6

-- Window chrome palette — a dark translucent backing, one hairline rule weight.
local WIN_BG    = { 0.05, 0.06, 0.09, 0.72 }
local WIN_TITLE = { 0.10, 0.12, 0.17, 0.85 }
local WIN_RULE  = { 0.45, 0.47, 0.52, 0.55 }

-- Shard dots (§4.3) — the pane's `5 shards` prereq as a GRAPHIC, not text.
local DOT_SIZE, DOT_GAP = 9, 5
local DOT_FILLED = { 0.62, 0.40, 0.95 }   -- soul-shard violet
local DOT_EMPTY  = { 0.28, 0.29, 0.34 }

P.frame      = nil
P.queue      = nil       -- the hosted HudQueue instance
P.owner      = nil       -- "opener" | "burst" | "placeholder" | nil
P.locked     = true      -- passthrough overlay unless the player unlocks to drag
P.prereqSpec = nil       -- the current consumer's prereq descriptors
-- M6 SEAMS: set these to functions to fire sound alongside the visual juice.
-- Left nil in M4 so nothing here plays audio (the HudChrome.lua:920 fence).
P.hooks      = { onCorrect = nil, onMiss = nil, onComplete = nil }

--------------------------------------------------------------------------------
-- Saved position
--------------------------------------------------------------------------------
-- Default BELOW THE CHARACTER (§4.1, play-test 5).  This reverses the original
-- M4 placement, and the reasoning that put it overhead is worth correcting rather
-- than deleting: "over the character, where the eyes already are" is true of the
-- CHARACTER, not of the space above them — overhead the pane competes with
-- nameplates, cast bars and floating combat text, all of which live in that band
-- and all of which move.  Below the character the band is quiet, still central,
-- and reads on the same glance as the personal resource display.
-- Read defensively so a db written by an older build (no `sequence` key) works.
local DEFAULT_POS = { point = "CENTER", x = 0, y = -170 }
local function savedPos()
  local p = ns.db and ns.db.hud and ns.db.hud.sequence
  if type(p) ~= "table" then p = DEFAULT_POS end
  return p
end

-- Is a sequence step's ability off cooldown right now?  Used to skip optional
-- steps (Imp Lord) that are on CD.  readyAt is set on a ready edge and cleared on
-- cooldown-start (HudState), so non-nil ⇒ ready; a no-cooldown ability (resource-
-- gated) is always "ready"; the napkin covers the pre-edge estimate.
local function stepReady(spell)
  if not spell then return true end
  local St = ns.HudState
  if St and St.readyAt and St.readyAt[spell] ~= nil then return true end
  if ns.HudNapkin then
    local r = ns.HudNapkin.Remaining(spell)
    if r ~= nil and r <= 0 then return true end
  end
  if (ns.BaseCooldown and ns.BaseCooldown(spell) or 0) == 0 then return true end
  return false
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------
function P.Ensure()
  if P.frame then return P.frame end
  local f = CreateFrame("Frame", "CDMProbeSequencePane", UIParent)
  f:SetSize(PANE_W, PANE_H)
  f:SetFrameStrata("MEDIUM")
  local p = savedPos()
  f:SetPoint(p.point or DEFAULT_POS.point, UIParent, p.point or DEFAULT_POS.point,
    p.x or DEFAULT_POS.x, p.y or DEFAULT_POS.y)
  -- Drag-to-save, ported from the parked prototype (Resource.lua:153-158).  The
  -- StartMoving is gated on `not P.locked` so a locked pane is inert even though
  -- it stays movable/registered.
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) if not P.locked then self:StartMoving() end end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    ns.db.hud = ns.db.hud or {}
    ns.db.hud.sequence = { point = point, x = x, y = y }
  end)

  -- ── Window chrome (§4.2) ───────────────────────────────────────────────────
  -- PERSISTENT now, where the old backdrop only appeared while unlocked.  The
  -- ask was "some background to bring it together"; the drag-target job it used
  -- to do is taken over by the brighter `dragBg` below, so unlocking still reads
  -- differently from locked.
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  bg:SetColorTexture(unpack(WIN_BG))
  P.bg = bg

  -- Title bar — a slightly lighter strip across the top, with a rule under it.
  local title = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  title:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  title:SetHeight(TITLE_H)
  title:SetColorTexture(unpack(WIN_TITLE))
  P.titleBar = title

  -- Hairline separators: under the title bar, and above the step strip.  One
  -- weight, one colour — the "panel separators" ask, kept to the minimum that
  -- still groups the rows.
  local function rule(yOffAnchor, yOff)
    local r = f:CreateTexture(nil, "BORDER")
    r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, yOff)
    r:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, yOff)
    r:SetHeight(1)
    r:SetColorTexture(unpack(WIN_RULE))
    return r
  end
  P.ruleTop = rule(nil, -TITLE_H)
  P.ruleMid = rule(nil, -(TITLE_H + 38))

  -- The brighter drag wash — ONLY while unlocked, over the window backing.
  local dragBg = f:CreateTexture(nil, "ARTWORK")
  dragBg:SetAllPoints(f)
  dragBg:SetColorTexture(TERM_DIM[1] * 0.35, TERM_DIM[2] * 0.35, TERM_DIM[3] * 0.35, 0.45)
  dragBg:Hide()
  P.dragBg = dragBg

  -- Content holder — a child so a miss can dim JUST the content, not the whole
  -- drag frame (the flash overlay lives outside it, so a dim never hides a flash).
  local content = CreateFrame("Frame", nil, f)
  content:SetAllPoints(f)
  P.content = content

  -- HEADER at the very TOP (M4.3 v2 — over the prereqs, not squeezed between them
  -- and the strip).  The hosted queue's own header is suppressed (HudQueue checks
  -- `host`), so this is the one header shown.
  -- The header now sits INSIDE the title bar (§4.2) and is left-aligned, the way
  -- a window title reads, rather than centred over the content.
  local hdr = content:CreateFontString(nil, "OVERLAY")
  ns.SetFont(hdr, 12, "OUTLINE")
  hdr:SetJustifyH("LEFT")
  hdr:SetTextColor(TERM[1], TERM[2], TERM[3])
  hdr:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 2, -4)
  P.headerRow = hdr

  -- Prereqs row BELOW the title bar.  JetBrains Mono (ns.SetFont) at 13.
  local pr = content:CreateFontString(nil, "OVERLAY")
  ns.SetFont(pr, 13, "OUTLINE")
  pr:SetJustifyH("CENTER")
  pr:SetPoint("TOP", content, "TOP", 0, -(TITLE_H + 4))
  P.prereqRow = pr

  -- ── Shard dots (§4.3) ──────────────────────────────────────────────────────
  -- The `5 shards` prereq as a graphic: SHARD_CAP dots, filled = held.  It lives
  -- on its own row under the text prereqs so the text row keeps its centring
  -- regardless of how many dots the spec asks for.
  local dotRow = CreateFrame("Frame", nil, content)
  dotRow:SetSize(1, DOT_SIZE)
  dotRow:SetPoint("TOP", pr, "BOTTOM", 0, -4)
  P.dotRow  = dotRow
  P.dots    = {}
  P.dotNeed = nil            -- how many the current prereq spec requires
  local cap = ns.SHARD_CAP or 5
  for i = 1, cap do
    local d = dotRow:CreateTexture(nil, "OVERLAY")
    d:SetSize(DOT_SIZE, DOT_SIZE)
    d:SetPoint("LEFT", dotRow, "LEFT", (i - 1) * (DOT_SIZE + DOT_GAP), 0)
    d:SetColorTexture(unpack(DOT_EMPTY))
    P.dots[i] = d
  end
  dotRow:SetWidth(cap * DOT_SIZE + (cap - 1) * DOT_GAP)
  dotRow:Hide()              -- shown only when a spec carries a shard prereq

  -- The step strip: a hosted HudQueue mounted INSIDE the content (host arg).  The
  -- memo lives on `content`, so re-arm reuses the one instance.
  P.queue = ns.HudQueue.Ensure(content, "sequence", 0, "horizontal", content)
  -- Teach the strip which steps are on cooldown so it can skip optional ones.
  P.queue.stepReadyFn = stepReady

  -- Juice overlay — a one-shot alpha flash, above the content, never on an icon.
  -- Same discipline as H.Settle / fireGlitter: Stop() before Play() so a re-fire
  -- restarts rather than stacking a latched wash.
  local fx = CreateFrame("Frame", nil, f)
  fx:SetAllPoints(f)
  fx:SetFrameLevel(f:GetFrameLevel() + 20)
  local flash = fx:CreateTexture(nil, "OVERLAY")
  flash:SetAllPoints(fx)
  flash:SetColorTexture(TERM[1], TERM[2], TERM[3], 1)
  flash:SetAlpha(0)
  local ag = flash:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(0.4); a:SetToAlpha(0); a:SetDuration(0.3)
  ag:SetScript("OnFinished", function() flash:SetAlpha(0) end)
  P.flash, P.flashAG, P.flashA = flash, ag, a

  f:Hide()
  P.frame = f
  return f
end

--------------------------------------------------------------------------------
-- Juice — asymmetric, and never a scold
--------------------------------------------------------------------------------
local function playFlash(fromAlpha, dur)
  if not P.flash then return end
  P.flashA:SetFromAlpha(fromAlpha)
  P.flashA:SetDuration(dur)
  P.flashAG:Stop()
  P.flash:SetAlpha(fromAlpha)
  P.flashAG:Play()
end

local function fireCorrect()
  playFlash(0.35, 0.3)
  if P.hooks.onCorrect then pcall(P.hooks.onCorrect) end
end

local FLOURISH_DUR = 0.7
local function fireComplete()
  -- Brighter, longer flourish on finishing the sequence.  A completing sequence
  -- makes the consumer Dissolve immediately, so mark a window Dissolve defers the
  -- frame-hide through — otherwise the flourish is hidden before it plays.
  playFlash(0.65, FLOURISH_DUR)
  P.flourishUntil = GetTime() + FLOURISH_DUR
  if P.hooks.onComplete then pcall(P.hooks.onComplete) end
end

local missTimer
local function fireMiss()
  -- GENTLE DIM ONLY — never a red "WRONG" (§0.5.8.7).  A deviation may be a legit
  -- branch, so this only lowers the content alpha briefly, then restores it.
  if P.content then
    P.content:SetAlpha(0.45)
    if missTimer then missTimer:Cancel() end
    missTimer = C_Timer.NewTimer(0.25, function()
      missTimer = nil
      if P.content then P.content:SetAlpha(1) end
    end)
  end
  if P.hooks.onMiss then pcall(P.hooks.onMiss) end
end

--------------------------------------------------------------------------------
-- Prereqs — the wall-down state, evaluated OOC
--------------------------------------------------------------------------------
-- One descriptor -> (label, met).  Readiness off the SAME edges the dot uses
-- (HudState.readyAt) with the napkin as the soon-estimate; shards off the live
-- count.  Best-guess, never secret: an unreadable input reads as NOT met (a
-- prereq we cannot confirm is one we do not claim).
local function evalPrereq(p)
  local St = ns.HudState
  if p.shards then
    local n = St and St.shards
    return p.label or (p.shards .. " shards"), (type(n) == "number" and n >= p.shards)
  end
  if p.spell then
    local ready = St and St.readyAt and St.readyAt[p.spell] ~= nil
    if not ready and ns.HudNapkin then
      local r = ns.HudNapkin.Remaining(p.spell)
      ready = (r ~= nil and r <= (p.lead or 0))
    end
    return p.label or "?", ready and true or false
  end
  return p.label or "?", false
end

-- §4.3 — paint the shard dot row.  `filled` = shards held; the dots BELOW the
-- requirement stay dim so the row reads as "how far up the wall you are".
-- Shards unreadable is NOT drawn as zero: an empty row would be a claim ("you
-- have none") we cannot make, so the row hides instead — the same refusal the
-- rail and the dot score already make elsewhere.
function P.RefreshShardDots()
  local row = P.dotRow
  if not row then return end
  if not P.dotNeed then row:Hide() return end
  local held = ns.HudState and ns.HudState.shards
  if type(held) ~= "number" then row:Hide() return end
  for i, d in ipairs(P.dots) do
    local c = (i <= held) and DOT_FILLED or DOT_EMPTY
    -- A dot past the requirement that is still filled is fine (5/5 when 5 needed);
    -- what matters is the first `need` dots being lit.
    d:SetColorTexture(c[1], c[2], c[3], (i <= held) and 1 or 0.55)
  end
  row:Show()
end

function P.RefreshPrereqs()
  if not (P.frame and P.prereqRow) then return end
  local spec = P.prereqSpec
  if not spec or #spec == 0 then
    P.prereqRow:SetText("")
    if P.queue and P.queue.SetReady then P.queue:SetReady(true) end
    return
  end
  local parts = {}
  local allMet = true
  local shardNeed = nil
  for _, p in ipairs(spec) do
    local label, met = evalPrereq(p)
    -- Feedback 2026-07-23: the sequence only "goes" once its REQUIRED prereqs are
    -- met (5 shards, Tyrant, Dreadstalkers).  An OPTIONAL prereq (Imp Lord) shows
    -- its state but does NOT gate readiness.
    if not met and not p.optional then allMet = false end
    -- §4.3 — a shard prereq is rendered by the DOT ROW, not as a word.  It still
    -- gates `allMet` exactly as before; only its rendering moved.
    if p.shards then
      shardNeed = p.shards
    else
      parts[#parts + 1] = (met and BRIGHT or DIM) .. label
        .. (p.optional and DIM .. " (opt)" or "") .. "|r"
    end
  end
  P.prereqRow:SetText(table.concat(parts, SEP))
  P.dotNeed = shardNeed
  P.RefreshShardDots()
  -- Drives the strip's emphasis: dim until ready, current step brightens when the
  -- wall is down (so a brightened [E] never says "start" while you should be
  -- building to 5 shards).
  if P.queue and P.queue.SetReady then P.queue:SetReady(allMet) end
end

--------------------------------------------------------------------------------
-- Consumer API — Arm / Advance / SetPrimed / Info / Dissolve
--------------------------------------------------------------------------------
-- `spec` is a HudQueue render spec (header + steps, with keybinds pre-resolved by
-- the consumer); `prereqs` is the descriptor list above; `owner` tags the arm so
-- only that consumer touches the strip.  Always primed (start-on-first-key) — the
-- desync fix both consumers want.
function P.Arm(spec, prereqs, owner)
  P.Ensure()
  P.owner      = owner
  P.prereqSpec = prereqs
  if P.headerRow then P.headerRow:SetText(spec and spec.header or "") end
  P.queue:Arm(spec)
  P.queue:SetPrimed(true)
  P.RefreshPrereqs()
  P.content:SetAlpha(1)
  P.frame:Show()
  if not P.locked then P.dragBg:Show() end
end

-- Is the pane armed (optionally: by a specific owner)?
function P.OwnedBy(owner)
  local armed = P.queue and P.queue.armed
  if owner == nil then return armed and true or false end
  return armed and P.owner == owner and true or false
end

-- A press landed.  Returns whether it advanced the strip, and fires the juice:
-- a match flashes (or flourishes on completion); a non-match while the sequence
-- is LIVE (un-primed) dims gently.  A non-match while PRIMED is a no-op — the
-- desync case, and NOT a miss.
function P.Advance(spellID)
  if not P.queue then return false end
  local wasPrimed = P.queue.primed
  local matched   = P.queue:Advance(spellID)
  if matched then
    if P.queue:IsEmpty() then fireComplete() else fireCorrect() end
  elseif not wasPrimed and P.queue.armed then
    fireMiss()
  end
  return matched
end

-- C2 (M4.4) — cast-START feedback: a "casting…" shimmer on the current step.
-- The consumer resolves the base identity and forwards here; the shimmer only
-- fires when the started spell matches the current step (HudQueue guards that).
function P.CastStart(spellID) if P.queue then P.queue:playCastStart(spellID) end end
function P.ClearCastStart() if P.queue then P.queue:clearCastStart() end end

function P.SetPrimed(v) if P.queue then P.queue:SetPrimed(v) end end
function P.IsPrimed() return (P.queue and P.queue.primed) and true or false end
function P.IsEmpty() return (not P.queue) or P.queue:IsEmpty() end

function P.Info()
  local qi = (P.queue and P.queue:Info()) or {}
  qi.owner  = P.owner
  qi.locked = P.locked
  return qi
end

-- Dissolve.  With an `owner` arg, refuses to dissolve another consumer's arm —
-- so the opener's dissolve clock can't tear down a burst arm that replaced it.
local hideTimer
function P.Dissolve(owner)
  if owner and P.owner ~= owner then return end
  P.owner      = nil
  P.prereqSpec = nil
  if P.queue then P.queue:Dissolve() end
  if P.prereqRow then P.prereqRow:SetText("") end
  if P.headerRow then P.headerRow:SetText("") end
  P.dotNeed = nil
  if P.dotRow then P.dotRow:Hide() end
  if P.frame and P.locked then
    -- Let an in-flight completion flourish finish before hiding the frame.
    local wait = P.flourishUntil and (P.flourishUntil - GetTime()) or 0
    if wait > 0 then
      if hideTimer then hideTimer:Cancel() end
      hideTimer = C_Timer.NewTimer(wait, function()
        hideTimer = nil
        if P.frame and not P.OwnedBy() then P.frame:Hide() end
      end)
    else
      P.frame:Hide()
    end
  end
end

--------------------------------------------------------------------------------
-- Lock / unlock — the only positioning path (no Edit Mode)
--------------------------------------------------------------------------------
-- Unlocking shows the pane with a placeholder if nothing is armed, so there is
-- always something to drag; locking makes it a click-through overlay again and
-- hides it when idle.  NEVER EnableMouse while locked — clicks must pass through
-- to the world/units beneath.
local function showPlaceholder()
  P.Ensure()
  P.prereqSpec = nil
  if P.headerRow then P.headerRow:SetText(BRIGHT .. "SEQUENCE|r") end
  P.prereqRow:SetText(DIM .. "drag to position, then /cdmp hud pane lock|r")
  P.queue:Arm({ header = "SEQUENCE", steps = {
    { label = "step 1" }, { label = "step 2" }, { label = "step 3" } } })
  P.queue:SetPrimed(false)
  P.queue:SetReady(true)          -- the drag placeholder shows bright, not dimmed
  P.owner = "placeholder"
  P.content:SetAlpha(1)
  P.frame:Show()
end

function P.SetLocked(locked)
  P.Ensure()
  P.locked = locked and true or false
  if P.locked then
    P.frame:EnableMouse(false)
    P.dragBg:Hide()
    if P.owner == "placeholder" then P.Dissolve() end
    if not P.OwnedBy() then P.frame:Hide() end
  else
    P.frame:EnableMouse(true)
    P.dragBg:Show()
    P.frame:Show()
    if not P.OwnedBy() then showPlaceholder() end
  end
end

-- SetHud(false): tear the whole pane down.
function P.Hide()
  P.Dissolve()
  if P.frame then
    P.frame:EnableMouse(false)
    P.locked = true
    P.frame:Hide()
  end
end

function P.StatusText()
  if not P.frame then return "|cff808080idle|r" end
  local qi = P.Info()
  local lock = P.locked and "|cff808080locked|r" or "|cffffd100UNLOCKED (drag)|r"
  if qi.armed and qi.owner ~= "placeholder" then
    return string.format("|cff88ff88armed|r by %s (%d/%d)%s  %s",
      tostring(qi.owner), qi.cursor or 0, qi.total or 0,
      qi.primed and "  |cffffd100primed|r" or "", lock)
  end
  return "|cff808080idle|r  " .. lock
end
