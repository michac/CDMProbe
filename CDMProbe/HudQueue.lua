-- HudQueue.lua — a reusable, mode-scoped SEQUENCE widget.  M3c-c2.
--
-- WHY IT IS ITS OWN FILE.  M3c-c2's pre-pull opener and M4's burst-window queue
-- are the SAME SHAPE: a fixed sequence, shown, advanced by matching the ability
-- you PRESS (not a slot), and dissolved when it stops being relevant.  Rather
-- than build the opener bespoke and bend it into M4 later, the widget is factored
-- out here and shipped wired to ONE consumer (HudOpener.lua).  M4's burst queue
-- becomes a second consumer — data + a trigger, not new machinery — exactly the
-- seam SpecDemonology is for a second spec.
--
-- This module knows NOTHING about openers, Demonology, napkins or overrides.  It
-- holds a step list and a cursor and draws them in the DEMO.SYS terminal idiom.
-- All spell identity lives in the consumer — including the KEYBIND string, which
-- the consumer resolves and hands us as `step.key`; we just draw it.
--
-- THE TWO NON-OBVIOUS RULES, both of which M4 will need too:
--
--   * ADVANCE = DROP-THROUGH, NEVER JAM.  On a matching press we consume that
--     step AND silently drop every earlier un-pressed one.  A queue that froze
--     because you pressed things out of the listed order would sit there LYING
--     mid-fight — the exact §0.5.8.7 §0 "inform, don't instruct" failure.  It
--     tracks WHERE YOU ARE; it never blocks.
--   * A STEP CAN REPEAT (`count`).  The opener presses HoG x2 and SB x3; the
--     Tyrant block is HoG HoG too.  count decrements per matching press and the
--     step is consumed at 0 — so the field belongs to the WIDGET, not the data.
--
-- ORIENTATION (M3c-c2 feedback pass).  The opener is a LEFT-TO-RIGHT strip drawn
-- ABOVE the icon column: `orient = "horizontal"`.  It shows KEYBINDS, not ability
-- names — a draining ghost of "which keys, in what order".  The old vertical list
-- (rows stacked below the panel) is kept behind `orient = "vertical"` for a future
-- consumer, but nothing ships it today.
--
-- RENDER is a DRAINING GHOST, not a nag: the whole script shows dim, the current
-- step brightens, consumed steps fall off.  It informs the SHAPE of the opening;
-- it never says "press this now".  No motion, positions locked — the same
-- steady-state discipline the rail keeps.
local ADDON, ns = ...

ns.HudQueue = {}
local Q = ns.HudQueue

-- Terminal palette + font, matched to HudChrome's DEMO.SYS chrome so the queue
-- reads as part of the same terminal.  HudChrome keeps these file-local by
-- design; these are constants echoed here, not a shared contract.
-- Neutral palette (M4.3 — CRT green retired).  Near-white "live", muted grey "not".
local TERM_FONT = "Fonts\\ARIALN.TTF"
local TERM      = { 0.92, 0.94, 0.98 }   -- the current step (bright)
local TERM_DIM  = { 0.45, 0.47, 0.52 }   -- header / preamble / upcoming / not-ready
local ROW_H     = 14
local WIDTH     = 320                     -- generous; the strip self-centres
-- Draw at most this many steps in the horizontal strip; a longer script shows
-- "+N more" rather than running off the edge (the opener is ~7 steps).
local MAX_STEPS = 10

-- Inline colour codes for the single-FontString horizontal strip (per-segment
-- colour in one string, so the strip is naturally centred and needs no per-cell
-- frame maths).
local function hex(c)
  return string.format("%02x%02x%02x",
    math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local BRIGHT = "|cff" .. hex(TERM)
local DIM    = "|cff" .. hex(TERM_DIM)
local SEP    = DIM .. "-|r"                  -- compact dim dash: [E]-[sE]-[Q]

local QueueMeta = {}
QueueMeta.__index = QueueMeta

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

local function buildFrame(viewer, inst)
  -- M4 — an optional HOST frame.  With no host the strip anchors ABOVE the CDM
  -- viewer (the M3c-c2 opener).  With a host (HudPane) the strip mounts INSIDE
  -- that frame instead, so the same widget can live in a movable, UIParent-
  -- anchored pane over the character.  The widget itself stays viewer-agnostic.
  local parent = inst.host or viewer
  local f = CreateFrame("Frame", nil, parent)
  f:SetFrameLevel((ns.HasMethod(parent, "GetFrameLevel") and parent:GetFrameLevel() or 1) + 12)
  -- ONE centre point + an explicit width: the clipping hazard (HudChrome
  -- buildRail / notes.md §9).  Two horizontal points would pin the width to the
  -- ~28px icon column and clip every row.
  f:SetSize(WIDTH, ROW_H * (inst.orient == "horizontal" and 2 or 12))
  if inst.host then
    -- Hosted: sit at the BOTTOM of the pane; the pane draws its prereqs row above.
    f:SetPoint("BOTTOM", inst.host, "BOTTOM", 0, 2)
  elseif inst.orient == "horizontal" then
    -- ABOVE the panel, grown upward, centred on the icon column.
    f:SetPoint("BOTTOM", viewer, "TOP", 0, inst.drop)
  else
    f:SetPoint("TOP", viewer, "BOTTOM", 0, -inst.drop)
  end
  -- Never EnableMouse: clicks pass through to the secure items beneath.

  local hd = f:CreateFontString(nil, "OVERLAY")
  -- M4.1: JetBrains Mono (ns.SetFont — the HudRow font the player finds sharp)
  -- and bigger (header 9 -> 12, strip 12 -> 16) so the strip is legible at 1440p+.
  ns.SetFont(hd, 12, "OUTLINE")
  hd:SetJustifyH("CENTER")
  hd:SetTextColor(TERM_DIM[1], TERM_DIM[2], TERM_DIM[3])
  f.header = hd

  if inst.orient == "horizontal" then
    -- The strip: one FontString carrying per-step inline colour, at the BOTTOM of
    -- the frame (nearest the panel); the header sits above it.
    local strip = f:CreateFontString(nil, "OVERLAY")
    ns.SetFont(strip, 16, "OUTLINE")
    strip:SetJustifyH("CENTER")
    strip:SetPoint("BOTTOM", f, "BOTTOM", 0, 0)
    f.strip = strip
    hd:SetPoint("BOTTOM", strip, "TOP", 0, 2)
  else
    hd:SetPoint("TOP", f, "TOP", 0, 0)
  end

  f:Hide()
  return f
end

-- Rows are created lazily, in order, and anchored under the one above — so row i
-- always exists when row i+1 is built during the same render pass.  (Vertical
-- orientation only.)
local function rowAt(inst, i)
  local r = inst.rows[i]
  if r then return r end
  r = inst.frame:CreateFontString(nil, "OVERLAY")
  ns.SetFont(r, 12, "OUTLINE")
  r:SetJustifyH("CENTER")
  r:SetPoint("TOP", (i == 1) and inst.frame.header or inst.rows[i - 1], "BOTTOM", 0, -2)
  inst.rows[i] = r
  return r
end

-- One display CELL for a step: the bracketed keybind (already short, e.g. "sE"),
-- or the human name as a fallback (an unbound ability is better named than blank).
-- A repeated step (HoG x2) is NOT "[R] x2" — it renders as one cell PER remaining
-- press ([R]-[R]), so the widget owns the repetition, not the label.
local function cellText(s)
  return "[" .. (s.key or s.label or "?") .. "]"
end

-- Kept for the vertical renderer (no live consumer), where "x2" is fine.
local function stepLabel(s)
  local base = s.key or s.label or "?"
  if (s.count or 1) > 1 then base = base .. " x" .. s.count end
  return base
end

--------------------------------------------------------------------------------
-- Horizontal render — one colour-coded strip
--------------------------------------------------------------------------------
local function renderHorizontal(inst)
  inst.frame.header:SetText(inst.header or "")
  local parts = {}
  local shown = 0
  for i = inst.cursor, #inst.steps do
    local s = inst.steps[i]
    if not s.consumed then
      if shown >= MAX_STEPS and i < #inst.steps then
        local remaining = 0
        for j = i, #inst.steps do if not inst.steps[j].consumed then remaining = remaining + 1 end end
        parts[#parts + 1] = DIM .. "+" .. remaining .. "|r"
        break
      end
      -- The current step brightens ONLY when the wall is down (inst.ready); until
      -- prereqs are met the whole strip stays dim, so a brightened [E] never reads
      -- as "start now" while you should be building to 5 shards (feedback
      -- 2026-07-23).  Notes ("t~3s"/"AoE") are dropped — too long.  A count draws
      -- as repeated cells ([R]-[R]), so "two presses left" reads at a glance.
      local col = (inst.ready and i == inst.cursor) and BRIGHT or DIM
      local cell = col .. cellText(s) .. "|r"
      for _ = 1, (s.count or 1) do parts[#parts + 1] = cell end
      shown = shown + 1
    end
  end
  inst.frame.strip:SetText(table.concat(parts, SEP))
end

--------------------------------------------------------------------------------
-- Vertical render — the original stacked list (no consumer today)
--------------------------------------------------------------------------------
local function renderVertical(inst)
  inst.frame.header:SetText(inst.header or "")
  local lines = {}
  if inst.preamble then lines[#lines + 1] = { text = inst.preamble, cur = false } end
  for i = inst.cursor, #inst.steps do
    local s = inst.steps[i]
    if not s.consumed then
      if #lines >= 12 - 1 and i < #inst.steps then
        local remaining = 0
        for j = i, #inst.steps do if not inst.steps[j].consumed then remaining = remaining + 1 end end
        lines[#lines + 1] = { text = "+" .. remaining .. " more", cur = false }
        break
      end
      local label = stepLabel(s)
      if s.note then label = label .. "  (" .. s.note .. ")" end
      lines[#lines + 1] = { text = label, cur = (i == inst.cursor) }
    end
  end
  local drawn = 0
  for i = 1, #lines do
    local r = rowAt(inst, i)
    r:SetText(lines[i].text)
    if lines[i].cur then r:SetTextColor(TERM[1], TERM[2], TERM[3])
    else r:SetTextColor(TERM_DIM[1], TERM_DIM[2], TERM_DIM[3]) end
    r:Show()
    drawn = i
  end
  for i = drawn + 1, #inst.rows do inst.rows[i]:Hide() end
end

local function render(inst)
  if inst.orient == "horizontal" then renderHorizontal(inst) else renderVertical(inst) end
end

--------------------------------------------------------------------------------
-- Instance API
--------------------------------------------------------------------------------

-- Load a spec and show.  `spec = { header, preamble, steps = { {spell, alt,
-- label, key, count=1, optional, note}, ... } }`.  Steps are COPIED so `count`
-- can be decremented without mutating the caller's data table.  `key` is the
-- pre-resolved keybind string the consumer wants drawn instead of the name.
function QueueMeta:Arm(spec)
  self.header   = spec and spec.header
  self.preamble = spec and spec.preamble
  wipe(self.steps)
  if spec and spec.steps then
    for i, s in ipairs(spec.steps) do
      self.steps[i] = { spell = s.spell, alt = s.alt, label = s.label, key = s.key,
                        count = s.count or 1, optional = s.optional, note = s.note,
                        consumed = false }
    end
  end
  self.cursor = 1
  self.armed  = true
  -- Re-arm always starts UN-primed; a consumer that wants start-on-first-key
  -- (the M4 desync fix) opts in with SetPrimed(true) right after Arm.
  self.primed = false
  -- ...and NOT-ready, so the strip opens de-emphasised until the consumer's
  -- prereq wall reports in via SetReady (M4.3).
  self.ready  = false
  render(self)
  self.frame:Show()
end

-- PRIMED (M4).  While primed the cursor sits at step 1 and only a press matching
-- step 1 un-primes and begins the drain — every other press is ignored, so a
-- pre-pull cast of a LATER step (Shadow Bolt) can no longer drop-through-match
-- and silently consume the summons ahead of it.  See Advance.
function QueueMeta:SetPrimed(v)
  self.primed = v and true or false
end

-- READY (M4.3): the consumer sets this from its prereq wall.  While false the strip
-- stays fully dim (de-emphasised — "keep building"); when true the current step
-- brightens ("go").  Re-renders only on a change.
function QueueMeta:SetReady(v)
  local nv = v and true or false
  if self.ready == nv then return end
  self.ready = nv
  if self.armed then render(self) end
end

-- JUICE (feedback 2026-07-23): a pressed step doesn't just vanish — its key
-- brightens and RISES off the strip, then fades.  A transient FontString above
-- the strip; consumed cells drop from the FRONT and the strip is centre-justified,
-- so centre is the honest launch point.  Horizontal orient only.
function QueueMeta:playPop(text)
  local f = self.frame
  if not (f and self.orient == "horizontal" and f.strip) then return end
  local pop = f.pop
  if not pop then
    pop = f:CreateFontString(nil, "OVERLAY")
    ns.SetFont(pop, 16, "OUTLINE")
    pop:SetJustifyH("CENTER")
    local ag = pop:CreateAnimationGroup()
    local tr = ag:CreateAnimation("Translation")
    tr:SetDuration(0.5); tr:SetSmoothing("OUT"); tr:SetOffset(0, 18)
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(1); fade:SetToAlpha(0); fade:SetDuration(0.5); fade:SetSmoothing("IN")
    ag:SetScript("OnFinished", function() pop:SetAlpha(0) end)
    pop.ag = ag
    f.pop = pop
  end
  pop:ClearAllPoints()
  pop:SetPoint("BOTTOM", f.strip, "TOP", 0, 2)
  pop:SetTextColor(TERM[1], TERM[2], TERM[3])
  pop:SetText(text)
  pop.ag:Stop()
  pop:SetAlpha(1)
  pop.ag:Play()
end

-- A press landed.  Returns true if it advanced the queue (matched a step),
-- false if the cast wasn't in the script.  DROP-THROUGH: matching a later step
-- consumes every earlier un-pressed one.
function QueueMeta:Advance(spellID)
  if not self.armed or type(spellID) ~= "number" then return false end
  -- PRIMED (M4): the queue waits at step 1 until the FIRST sequence key lands.
  -- Only a press matching step 1's spell/alt un-primes; any other press is
  -- ignored (no drop-through while primed) — the desync fix, so a pre-pull SB to
  -- cap shards no longer matches the later SB step and eats the summons ahead of
  -- it.  Once un-primed the normal drop-through drain below resumes.
  if self.primed then
    local s = self.steps[self.cursor]
    if not (s and not s.consumed and (s.spell == spellID or s.alt == spellID)) then
      return false
    end
    self.primed = false
  end
  for k = self.cursor, #self.steps do
    local s = self.steps[k]
    if not s.consumed and (s.spell == spellID or s.alt == spellID) then
      for j = self.cursor, k - 1 do self.steps[j].consumed = true end
      self:playPop(cellText(s))     -- the pressed key rises + fades before the redraw
      s.count = (s.count or 1) - 1
      if s.count <= 0 then s.consumed = true end
      local c = self.cursor
      while c <= #self.steps and self.steps[c].consumed do c = c + 1 end
      self.cursor = c
      render(self)
      return true
    end
  end
  return false
end

function QueueMeta:IsEmpty()
  return self.cursor > #self.steps
end

function QueueMeta:Dissolve()
  self.armed = false
  if self.frame then self.frame:Hide() end
end

-- For `/cdmp hud status`.  Reports the human NAME (not the keybind) so the
-- readout stays legible.
function QueueMeta:Info()
  local cur = self.steps[self.cursor]
  return { armed = self.armed, primed = self.primed, cursor = self.cursor,
           total = #self.steps, current = cur and (cur.label or cur.key) }
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

-- One instance per (viewer, id).  Memoised on the viewer so it rides Edit Mode
-- and is not rebuilt on every RefreshLayout — exactly like HudChrome's __hudRail.
-- `drop` is the gap between the viewer edge and the widget; `orient` is
-- "horizontal" (a strip above the panel) or "vertical" (a list below it).
-- `host` (M4, optional) mounts the strip INSIDE that frame instead of above the
-- viewer — how HudPane hosts the shared sequence strip.
function Q.Ensure(viewer, id, drop, orient, host)
  if not viewer then return nil end
  viewer.__hudQueue = viewer.__hudQueue or {}
  local inst = viewer.__hudQueue[id]
  if inst then return inst end
  inst = setmetatable({ steps = {}, rows = {}, cursor = 1, drop = drop or 8,
                        orient = orient or "horizontal", host = host }, QueueMeta)
  inst.frame = buildFrame(viewer, inst)
  viewer.__hudQueue[id] = inst
  return inst
end
