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
-- All spell identity lives in the consumer.
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
-- RENDER is a DRAINING GHOST, not a nag: the whole script shows dim, the current
-- step brightens, consumed steps fall off.  It informs the SHAPE of the opening;
-- it never says "press this now".  No motion, positions locked ([V3][V7]) — the
-- same steady-state discipline the rail keeps.
local ADDON, ns = ...

ns.HudQueue = {}
local Q = ns.HudQueue

-- Terminal palette + font, matched to HudChrome's DEMO.SYS chrome so the queue
-- reads as part of the same terminal.  HudChrome keeps these file-local by
-- design; these are four constants echoed here, not a shared contract.
local TERM_FONT = "Fonts\\ARIALN.TTF"
local TERM      = { 0.29, 1.00, 0.48 }   -- the current step (bright)
local TERM_DIM  = { 0.17, 0.55, 0.30 }   -- header / preamble / upcoming
local ROW_H     = 12
local WIDTH     = 150
-- Draw at most this many rows; a longer script shows "+N more" rather than
-- truncating silently (the opener is ~8 rows — this is headroom for M4).
local MAX_ROWS  = 12

local QueueMeta = {}
QueueMeta.__index = QueueMeta

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

local function buildFrame(viewer, inst)
  local f = CreateFrame("Frame", nil, viewer)
  f:SetFrameLevel((ns.HasMethod(viewer, "GetFrameLevel") and viewer:GetFrameLevel() or 1) + 12)
  -- ONE centre point + an explicit width: the clipping hazard (HudChrome
  -- buildRail / notes.md §9).  Two horizontal points would pin the width to the
  -- ~28px icon column and clip every row.
  f:SetSize(WIDTH, ROW_H * MAX_ROWS)
  f:SetPoint("TOP", viewer, "BOTTOM", 0, -inst.drop)
  -- Never EnableMouse: clicks pass through to the secure items beneath.
  local hd = f:CreateFontString(nil, "OVERLAY")
  hd:SetFont(TERM_FONT, 9, "OUTLINE")
  hd:SetPoint("TOP", f, "TOP", 0, 0)
  hd:SetJustifyH("CENTER")
  hd:SetTextColor(TERM_DIM[1], TERM_DIM[2], TERM_DIM[3])
  f.header = hd
  f:Hide()
  return f
end

-- Rows are created lazily, in order, and anchored under the one above — so row i
-- always exists when row i+1 is built during the same render pass.
local function rowAt(inst, i)
  local r = inst.rows[i]
  if r then return r end
  r = inst.frame:CreateFontString(nil, "OVERLAY")
  r:SetFont(TERM_FONT, 9, "OUTLINE")
  r:SetJustifyH("CENTER")
  r:SetPoint("TOP", (i == 1) and inst.frame.header or inst.rows[i - 1], "BOTTOM", 0, -2)
  inst.rows[i] = r
  return r
end

-- Rebuild the visible list from the cursor.  Consumed steps simply aren't drawn
-- (they "drop off"); the step AT the cursor is bright, the rest dim.
local function render(inst)
  inst.frame.header:SetText(inst.header or "")
  local lines = {}
  if inst.preamble then lines[#lines + 1] = { text = inst.preamble, cur = false } end
  for i = inst.cursor, #inst.steps do
    local s = inst.steps[i]
    if not s.consumed then
      if #lines >= MAX_ROWS - 1 and i < #inst.steps then
        local remaining = 0
        for j = i, #inst.steps do if not inst.steps[j].consumed then remaining = remaining + 1 end end
        lines[#lines + 1] = { text = "+" .. remaining .. " more", cur = false }
        break
      end
      local label = s.label or "?"
      if (s.count or 1) > 1 then label = label .. " x" .. s.count end
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

--------------------------------------------------------------------------------
-- Instance API
--------------------------------------------------------------------------------

-- Load a spec and show.  `spec = { header, preamble, steps = { {spell, alt,
-- label, count=1, optional, note}, ... } }`.  Steps are COPIED so `count` can be
-- decremented without mutating the caller's data table.
function QueueMeta:Arm(spec)
  self.header   = spec and spec.header
  self.preamble = spec and spec.preamble
  wipe(self.steps)
  if spec and spec.steps then
    for i, s in ipairs(spec.steps) do
      self.steps[i] = { spell = s.spell, alt = s.alt, label = s.label,
                        count = s.count or 1, optional = s.optional, note = s.note,
                        consumed = false }
    end
  end
  self.cursor = 1
  self.armed  = true
  render(self)
  self.frame:Show()
end

-- A press landed.  Returns true if it advanced the queue (matched a step),
-- false if the cast wasn't in the script.  DROP-THROUGH: matching a later step
-- consumes every earlier un-pressed one.
function QueueMeta:Advance(spellID)
  if not self.armed or type(spellID) ~= "number" then return false end
  for k = self.cursor, #self.steps do
    local s = self.steps[k]
    if not s.consumed and (s.spell == spellID or s.alt == spellID) then
      for j = self.cursor, k - 1 do self.steps[j].consumed = true end
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

-- For `/cdmp hud status`.
function QueueMeta:Info()
  local cur = self.steps[self.cursor]
  return { armed = self.armed, cursor = self.cursor, total = #self.steps,
           current = cur and cur.label }
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

-- One instance per (viewer, id).  Memoised on the viewer so it rides Edit Mode
-- and is not rebuilt on every RefreshLayout — exactly like HudChrome's __hudRail.
-- `drop` is the gap below the viewer's bottom (below the rail, for the opener).
function Q.Ensure(viewer, id, drop)
  if not viewer then return nil end
  viewer.__hudQueue = viewer.__hudQueue or {}
  local inst = viewer.__hudQueue[id]
  if inst then return inst end
  inst = setmetatable({ steps = {}, rows = {}, cursor = 1, drop = drop or 60 }, QueueMeta)
  inst.frame = buildFrame(viewer, inst)
  viewer.__hudQueue[id] = inst
  return inst
end
