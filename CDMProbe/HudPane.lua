-- HudPane.lua — the SEQUENCE PANE.  M4.
--
-- WHY IT IS ITS OWN FRAME.  The sequence helper (opener + burst) is
-- INSTRUCTIONAL and wants central vision — over the character, where the eyes
-- already are — but every other HUD surface is VIEWER-ANCHORED to the CDM column
-- (HudChrome's terminal/rail, HudQueue's above-the-panel strip).  So the pane is
-- the addon's FIRST UIParent-anchored frame: movable, drag-to-save, and NOT part
-- of Edit Mode (its own lock/unlock + a saved position is the only placement
-- path, by design — over-the-head is the whole point).
--
-- WHAT IT IS.  A shared surface with two parts:
--   * a PREREQS ROW (a FontString) — the pre-pull wall-down state ("Tyrant ·
--     Dreadstalkers · 5 shards"), each lit bright when met, dim when not.
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
local TERM_FONT = "Fonts\\ARIALN.TTF"
local TERM      = { 0.29, 1.00, 0.48 }
local TERM_DIM  = { 0.17, 0.55, 0.30 }
local function hex(c)
  return string.format("%02x%02x%02x",
    math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local BRIGHT = "|cff" .. hex(TERM)
local DIM    = "|cff" .. hex(TERM_DIM)
local SEP    = DIM .. "  ·  |r"

local PANE_W, PANE_H = 340, 48

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
-- Default OVER THE CHARACTER (UIParent CENTER, nudged up toward the head).  Read
-- defensively so a db written by an older build (no `sequence` key) still works.
local function savedPos()
  local p = ns.db and ns.db.hud and ns.db.hud.sequence
  if type(p) ~= "table" then p = { point = "CENTER", x = 0, y = 120 } end
  return p
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
  f:SetPoint(p.point or "CENTER", UIParent, p.point or "CENTER", p.x or 0, p.y or 120)
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

  -- Backdrop: only shown while UNLOCKED, as a visible drag target.
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  bg:SetColorTexture(TERM_DIM[1] * 0.35, TERM_DIM[2] * 0.35, TERM_DIM[3] * 0.35, 0.55)
  bg:Hide()
  P.bg = bg

  -- Content holder — a child so a miss can dim JUST the content, not the whole
  -- drag frame (the flash overlay lives outside it, so a dim never hides a flash).
  local content = CreateFrame("Frame", nil, f)
  content:SetAllPoints(f)
  P.content = content

  -- Prereqs row at the TOP.  M4.1: JetBrains Mono (ns.SetFont) at 13 (was 10).
  local pr = content:CreateFontString(nil, "OVERLAY")
  ns.SetFont(pr, 13, "OUTLINE")
  pr:SetJustifyH("CENTER")
  pr:SetPoint("TOP", content, "TOP", 0, -2)
  P.prereqRow = pr

  -- The step strip: a hosted HudQueue mounted INSIDE the content (host arg).  The
  -- memo lives on `content`, so re-arm reuses the one instance.
  P.queue = ns.HudQueue.Ensure(content, "sequence", 0, "horizontal", content)

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

function P.RefreshPrereqs()
  if not (P.frame and P.prereqRow) then return end
  local spec = P.prereqSpec
  if not spec or #spec == 0 then P.prereqRow:SetText(""); return end
  local parts = {}
  for _, p in ipairs(spec) do
    local label, met = evalPrereq(p)
    parts[#parts + 1] = (met and BRIGHT or DIM) .. label .. "|r"
  end
  P.prereqRow:SetText(table.concat(parts, SEP))
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
  P.queue:Arm(spec)
  P.queue:SetPrimed(true)
  P.RefreshPrereqs()
  P.content:SetAlpha(1)
  P.frame:Show()
  if not P.locked then P.bg:Show() end
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

function P.SetPrimed(v) if P.queue then P.queue:SetPrimed(v) end end
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
  P.prereqRow:SetText(DIM .. "SEQUENCE — drag to position, then /cdmp hud pane lock|r")
  P.queue:Arm({ header = "SEQUENCE", steps = {
    { label = "step 1" }, { label = "step 2" }, { label = "step 3" } } })
  P.queue:SetPrimed(false)
  P.owner = "placeholder"
  P.content:SetAlpha(1)
  P.frame:Show()
end

function P.SetLocked(locked)
  P.Ensure()
  P.locked = locked and true or false
  if P.locked then
    P.frame:EnableMouse(false)
    P.bg:Hide()
    if P.owner == "placeholder" then P.Dissolve() end
    if not P.OwnedBy() then P.frame:Hide() end
  else
    P.frame:EnableMouse(true)
    P.bg:Show()
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
