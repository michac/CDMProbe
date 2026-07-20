-- HudChrome.lua — everything we DRAW.  Never a write to item.Icon.
--
-- The 2026-07-19 aesthetic revision: Blizzard's icons stay native and untouched
-- (art, radial swipe, countdown text, charges, native glow all survive), and all
-- our value-add is terminal chrome AROUND them.  So this module owns:
--
--   * per-item group accent   — §0.5.8.3 #4: hue = GROUP (spec.md §3 colour map),
--                               role = the generator/consumer BATCH TINT
--   * per-item keybind text   — identity chrome, outside the indicator contract
--   * the DEMO.SYS terminal frame — header / rules / side borders / blinking footer
--   * the scanline + vignette overlay
--
-- Two encoding rules from spec.md §3 are load-bearing here:
--   [V2]/[V3]  hue carries GROUP only.  The batch tint therefore rides on
--              SATURATION + edge THICKNESS + alpha, and deliberately leaves
--              LUMINANCE alone — luminance is reserved for readiness (M3b), so
--              the two channels can never fight.
--   [X1]       never colour-alone: edge thickness is a redundant, non-colour
--              signifier of the builder/spender axis.
local ADDON, ns = ...

ns.HudChrome = {}
local H = ns.HudChrome

local TERM_FONT = "Fonts\\ARIALN.TTF"   -- narrow bundled font (closest to mono)
local TERM      = { 0.29, 1.00, 0.48 }  -- terminal bright (frame + header)
local TERM_MID  = { 0.24, 0.82, 0.42 }
local TERM_DIM  = { 0.17, 0.55, 0.30 }
local KEY_COL   = { 0.78, 0.92, 0.80 }  -- keybind text: near-white, reads on any icon

-- Batch tint per role (guidance-model §0.5.8.4 `batch_tint`).
--   sat   — saturation multiplier around the colour's own luminance (never a
--           luminance change; see the header note)
--   width — edge thickness in px, the redundant non-colour channel
--   alpha — presence
local BATCH = {
  spender = { sat = 1.25, width = 2, alpha = 0.95 },  -- consumers: warm/bright end
  burst   = { sat = 1.25, width = 2, alpha = 0.95 },
  builder = { sat = 0.62, width = 1, alpha = 0.60 },  -- generators: cool/dim end
  utility = { sat = 0.50, width = 1, alpha = 0.45 },
  proc    = { sat = 1.00, width = 1, alpha = 0.70 },
}

-- Push a colour toward/away from its own grey, holding luminance constant.
local function saturate(r, g, b, mul)
  local y = 0.299 * r + 0.587 * g + 0.114 * b
  local function ch(c) return math.max(0, math.min(1, y + (c - y) * mul)) end
  return ch(r), ch(g), ch(b)
end

--------------------------------------------------------------------------------
-- Per-item chrome
--------------------------------------------------------------------------------

-- A child frame ABOVE item.Cooldown holds our chrome, so accents and keybind
-- text aren't dimmed under the radial swipe.  (The frame-level trick is the one
-- proven in M1 — CRT.lua:96-106.)  Built once per item frame, reused thereafter.
local function ensure(item)
  if item.__hud then return item.__hud end
  local lvl = (ns.HasMethod(item, "GetFrameLevel") and item:GetFrameLevel() or 1) + 5
  if item.Cooldown and ns.HasMethod(item.Cooldown, "GetFrameLevel") then
    lvl = math.max(lvl, item.Cooldown:GetFrameLevel() + 2)
  end
  local f = CreateFrame("Frame", nil, item)
  f:SetAllPoints(item)
  f:SetFrameLevel(lvl)

  local o = { frame = f, edges = {} }
  -- Four edge textures forming the group accent border.
  for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    o.edges[side] = f:CreateTexture(nil, "OVERLAY")
  end
  o.key = f:CreateFontString(nil, "OVERLAY")
  o.key:SetFont(TERM_FONT, 10, "OUTLINE")
  o.key:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  o.key:SetTextColor(KEY_COL[1], KEY_COL[2], KEY_COL[3])

  item.__hud = o
  return o
end

local function layoutEdges(o, w)
  local e = o.edges
  e.TOP:ClearAllPoints()
  e.TOP:SetPoint("TOPLEFT", o.frame, "TOPLEFT", 0, 0)
  e.TOP:SetPoint("TOPRIGHT", o.frame, "TOPRIGHT", 0, 0)
  e.TOP:SetHeight(w)
  e.BOTTOM:ClearAllPoints()
  e.BOTTOM:SetPoint("BOTTOMLEFT", o.frame, "BOTTOMLEFT", 0, 0)
  e.BOTTOM:SetPoint("BOTTOMRIGHT", o.frame, "BOTTOMRIGHT", 0, 0)
  e.BOTTOM:SetHeight(w)
  e.LEFT:ClearAllPoints()
  e.LEFT:SetPoint("TOPLEFT", o.frame, "TOPLEFT", 0, 0)
  e.LEFT:SetPoint("BOTTOMLEFT", o.frame, "BOTTOMLEFT", 0, 0)
  e.LEFT:SetWidth(w)
  e.RIGHT:ClearAllPoints()
  e.RIGHT:SetPoint("TOPRIGHT", o.frame, "TOPRIGHT", 0, 0)
  e.RIGHT:SetPoint("BOTTOMRIGHT", o.frame, "BOTTOMRIGHT", 0, 0)
  e.RIGHT:SetWidth(w)
end

-- Attach (or refresh) the chrome for one item.  Returns true if a keybind text
-- was resolved, so HudCore can report hits/misses in `hud status`.
function H.Attach(item, spellID)
  local o = ensure(item)
  local info = ns.SpecInfo(spellID)
  local batch = BATCH[info.role] or BATCH.utility
  local r, g, b = ns.SpecColor(spellID)
  r, g, b = saturate(r, g, b, batch.sat)

  layoutEdges(o, batch.width)
  for _, t in pairs(o.edges) do
    t:SetColorTexture(r, g, b, batch.alpha)
    t:Show()
  end

  local key = ns.HudBinds.Get(spellID)
  o.key:SetText(key or "")           -- unbound -> blank, never a placeholder
  o.frame:Show()
  return key ~= nil
end

function H.Detach(item)
  if item.__hud then item.__hud.frame:Hide() end
end

--------------------------------------------------------------------------------
-- Scanline + vignette overlay
--------------------------------------------------------------------------------
-- Perf cleanup (b), notes.md §9.  M1 grew the texture pool on every reflow.  The
-- plan's preferred fix was ONE tiled texture, which needs a bundled power-of-two
-- scanline art file; we took the named fallback instead — a FIXED pool allocated
-- lazily up to a hard cap and only ever re-anchored afterwards.  Allocations are
-- O(1) amortised (they stop entirely once the tallest viewer has been seen) and
-- there is no binary art file whose load we cannot verify from here.
local SCAN_STEP, SCAN_MAX = 3, 128       -- a line every 3px, up to 384px of column

local function ensureScan(viewer)
  if viewer.__hudScan then return viewer.__hudScan end
  local f = CreateFrame("Frame", nil, viewer)
  f:SetAllPoints(viewer)
  f:SetFrameLevel((ns.HasMethod(viewer, "GetFrameLevel") and viewer:GetFrameLevel() or 1) + 10)
  -- Never EnableMouse: clicks pass through to the secure item beneath.
  local glow = f:CreateTexture(nil, "BACKGROUND")     -- faint phosphor wash
  glow:SetAllPoints(f)
  glow:SetColorTexture(TERM[1], TERM[2], TERM[3], 0.05)
  f.lines = {}
  viewer.__hudScan = f
  return f
end

function H.FlowScan(viewer)
  local f = ensureScan(viewer)
  local h = math.floor((ns.HasMethod(viewer, "GetHeight") and viewer:GetHeight()) or 0)
  local n = math.max(0, math.min(SCAN_MAX, math.floor(h / SCAN_STEP)))
  for i = 1, n do
    local ln = f.lines[i]
    if not ln then
      ln = f:CreateTexture(nil, "OVERLAY")
      ln:SetColorTexture(0, 0, 0, 0.22)
      ln:SetHeight(1)
      f.lines[i] = ln
    end
    ln:ClearAllPoints()
    ln:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(i - 1) * SCAN_STEP)
    ln:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -(i - 1) * SCAN_STEP)
    ln:Show()
  end
  for i = n + 1, #f.lines do f.lines[i]:Hide() end
  f:Show()
  return #f.lines
end

function H.HideScan(viewer)
  if viewer.__hudScan then viewer.__hudScan:Hide() end
end

--------------------------------------------------------------------------------
-- DEMO.SYS terminal frame
--------------------------------------------------------------------------------
-- Ported from the M1 prototype (CRT.lua:193-259).  Keep the COMPACT
-- single-centre-anchor labels: notes.md §9 — a wide banner anchored with two
-- horizontal points fixes its width to the ~28px column and clips.
local terminal, blinkTicker

local function rule(parent, anchorTo, ptA, ptB, offY)
  local t = parent:CreateTexture(nil, "OVERLAY")
  t:SetColorTexture(TERM_MID[1], TERM_MID[2], TERM_MID[3], 0.8)
  t:SetHeight(1)
  t:SetPoint("TOPLEFT", anchorTo, ptA, 0, offY)
  t:SetPoint("TOPRIGHT", anchorTo, ptB, 0, offY)
  return t
end

local function buildTerminal(viewer)
  if viewer.__hudTerm then return viewer.__hudTerm end
  local f = CreateFrame("Frame", nil, viewer)
  f:SetAllPoints(viewer)
  f:SetFrameLevel((ns.HasMethod(viewer, "GetFrameLevel") and viewer:GetFrameLevel() or 1) + 12)

  local hd = f:CreateFontString(nil, "OVERLAY")
  hd:SetFont(TERM_FONT, 11, "OUTLINE")
  hd:SetPoint("BOTTOM", viewer, "TOP", 0, 9)
  hd:SetJustifyH("CENTER")
  hd:SetTextColor(TERM[1], TERM[2], TERM[3])
  hd:SetText("DEMO.SYS")
  f.header = hd

  local sub = f:CreateFontString(nil, "OVERLAY")
  sub:SetFont(TERM_FONT, 8, "OUTLINE")
  sub:SetPoint("TOP", hd, "BOTTOM", 0, -1)
  sub:SetJustifyH("CENTER")
  sub:SetTextColor(TERM_DIM[1], TERM_DIM[2], TERM_DIM[3])
  sub:SetText("v" .. tostring(ns.version))
  f.sub = sub

  rule(f, viewer, "TOPLEFT", "TOPRIGHT", 4)

  local function vrule(pt)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(TERM_MID[1], TERM_MID[2], TERM_MID[3], 0.55)
    t:SetWidth(1)
    t:SetPoint("TOP", viewer, pt == "L" and "TOPLEFT" or "TOPRIGHT", pt == "L" and -2 or 2, 4)
    t:SetPoint("BOTTOM", viewer, pt == "L" and "BOTTOMLEFT" or "BOTTOMRIGHT", pt == "L" and -2 or 2, -4)
  end
  vrule("L"); vrule("R")

  rule(f, viewer, "BOTTOMLEFT", "BOTTOMRIGHT", -4)
  local ft = f:CreateFontString(nil, "OVERLAY")
  ft:SetFont(TERM_FONT, 10, "OUTLINE")
  ft:SetPoint("TOP", viewer, "BOTTOM", 0, -6)
  ft:SetJustifyH("CENTER")
  ft:SetTextColor(TERM_MID[1], TERM_MID[2], TERM_MID[3])
  ft:SetText("C:\\>_")
  f.footer = ft
  f.cursorOn = true

  viewer.__hudTerm = f
  return f
end

local function setBlink(on)
  if on then
    if blinkTicker then return end
    blinkTicker = C_Timer.NewTicker(0.53, function()
      if not terminal or not terminal.footer then return end
      terminal.cursorOn = not terminal.cursorOn
      terminal.footer:SetText("C:\\>" .. (terminal.cursorOn and "_" or " "))
    end)
  elseif blinkTicker then
    blinkTicker:Cancel(); blinkTicker = nil
  end
end

function H.ShowTerminal(viewer)
  if not viewer then return end
  terminal = buildTerminal(viewer)
  terminal:Show()
  setBlink(true)
end

function H.HideTerminal()
  setBlink(false)
  if terminal then terminal:Hide() end
end
