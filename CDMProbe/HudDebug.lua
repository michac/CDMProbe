-- HudDebug.lua — `/cdmp hud debug`: say it in WORDS before we say it in pixels.
--
-- WHY THIS EXISTS (2026-07-20).  M3a/M3b encoded state as colour, luminance,
-- thickness and glow — and the first honest reaction to seeing it in game was
-- "I can see differences, but yellow and purple don't mean anything in
-- isolation."  That's correct, and it's a property of the design, not a bug:
-- hue carries GROUP, which is ambient *identity* (guidance-model §0.5.8.3 #4 is
-- `ambient` tier), not an instruction.  You can't read an arbitrary encoding you
-- haven't learned yet.
--
-- So this module inverts the order of work.  It writes out, in plain text beside
-- each icon, EVERYTHING the HUD currently believes about that item.  Two payoffs:
--
--   1. It's a legend you can't misread — each row names its own group and role,
--      printed in that group's actual colour, so the colour map teaches itself.
--   2. It's the correctness check.  Before we compress state into pixels we get
--      to see whether the state is even RIGHT — whether readiness tracks, whether
--      the proc routing fires on the spell we think, whether presence agrees with
--      the level read.  Encoding a wrong signal beautifully is worse than useless.
--
-- The intended lifecycle is: read the words -> decide which facts actually earn a
-- visual channel -> compress those -> keep this mode as the debugging fallback.
-- It is NOT part of the §0.5.8 indicator contract and never ships as "the HUD".
--
-- Deliberately self-contained (one file, one toggle, its own frames) so it can be
-- deleted or left switched off without touching anything else.
local ADDON, ns = ...

ns.HudDebug = { on = false }
local D = ns.HudDebug

local FONT = "Fonts\\ARIALN.TTF"
local SIZE = 11
local REFRESH = 0.15            -- debug mode; a few string ops at ~7 Hz is free

-- Weak keys: rows hang off pooled item frames we don't own.
local rows = setmetatable({}, { __mode = "k" })
local summary, ticker

--------------------------------------------------------------------------------
-- Colour helpers
--------------------------------------------------------------------------------
local function hex(r, g, b)
  return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- The group name printed in the group's own hue — this is what makes the colour
-- map self-teaching rather than something you have to hold in your head.
local function groupTag(group)
  local c = ns.SpecGroups[group] or ns.SpecGroups.neutral
  return hex(c[1], c[2], c[3]) .. group .. "|r"
end

local WHITE, GREY = "|cffffffff", "|cff808080"
local GREEN, RED, AMBER, CYAN = "|cff55ff55", "|cffff5555", "|cffffd100", "|cff44e0ff"

--------------------------------------------------------------------------------
-- One text row per item, anchored OUTSIDE the icon to its right
--------------------------------------------------------------------------------
-- Nothing clips our overlay (notes.md §9 — no clipsChildren in the CDM
-- templates), so a row can run as far right as it likes past the narrow column.
local function ensureRow(item)
  if rows[item] then return rows[item] end
  local lvl = (ns.HasMethod(item, "GetFrameLevel") and item:GetFrameLevel() or 1) + 20
  local f = CreateFrame("Frame", nil, item)
  f:SetSize(1, 1)
  f:SetFrameLevel(lvl)
  f:SetPoint("LEFT", item, "RIGHT", 8, 0)
  local fs = f:CreateFontString(nil, "OVERLAY")
  fs:SetFont(FONT, SIZE, "OUTLINE")
  fs:SetPoint("LEFT", f, "LEFT", 0, 0)
  fs:SetJustifyH("LEFT")
  f.text = fs
  rows[item] = f
  return f
end

--------------------------------------------------------------------------------
-- The line itself
--------------------------------------------------------------------------------
-- Everything the HUD knows about one item, in reading order:
--   <key> Name · group/role · <readiness> · <proc> · <notes>
local function lineFor(key, e)
  local info, known = ns.SpecInfo(e.spellID)
  local parts = {}

  local bind = ns.HudBinds.GetForItem(e.item, e.spellID)
  parts[#parts + 1] = bind and (AMBER .. "[" .. bind .. "]|r") or (GREY .. "[--]|r")

  local name = (e.spellID and ns.SpellName(e.spellID)) or "?"
  if ns.IsSecret(name) then name = "<secret>" end
  parts[#parts + 1] = WHITE .. tostring(name) .. "|r"

  parts[#parts + 1] = groupTag(info.group) .. GREY .. "/" .. "|r" .. info.role
    .. (known and "" or (AMBER .. "(unmapped)|r"))

  if ns.Hud.IsIconViewer(e.viewer) then
    -- Readiness is TRI-state and the unknown is meaningful: we have not observed
    -- an edge for this spell yet, and we refuse to guess one (that would need a
    -- secret read).  Showing "?" rather than defaulting to READY or CD is the
    -- whole point — see HudChrome's note on `ready = nil`.
    local ready = ns.HudChrome.GetReady(e.item)
    if ready == true then parts[#parts + 1] = GREEN .. "READY|r"
    elseif ready == false then parts[#parts + 1] = RED .. "on-CD|r"
    else parts[#parts + 1] = GREY .. "? (no edge seen yet)|r" end

    if ns.HudChrome.IsGlowing(e.item) then parts[#parts + 1] = CYAN .. "GLOW|r" end
  else
    -- Buff viewers: presence is the interesting fact, plus where it came from.
    local present = ns.HudState.presence[key]
    parts[#parts + 1] = present and (CYAN .. "PRESENT|r") or (GREY .. "absent|r")
    local src = e.baseSpellID and ns.HudState.lastEdge[e.baseSpellID]
    if src then parts[#parts + 1] = GREY .. "via " .. src .. "|r" end
  end

  -- A live spell override (Demonic Art) — the one case where the item's reported
  -- spell differs from its identity, and the thing #3 glows on.
  if e.baseSpellID and ns.HudState.override[e.baseSpellID] then
    parts[#parts + 1] = AMBER .. "OVERRIDE->" ..
      (ns.SpellName(ns.HudState.override[e.baseSpellID]) or "?") .. "|r"
  end

  return table.concat(parts, GREY .. " · |r")
end

--------------------------------------------------------------------------------
-- The global summary line, above the Essential column
--------------------------------------------------------------------------------
local function ensureSummary()
  if summary then return summary end
  local anchor = ns.GetViewer("EssentialCooldownViewer")
  if not anchor then return nil end
  local f = CreateFrame("Frame", nil, anchor)
  f:SetSize(1, 1)
  f:SetFrameLevel((ns.HasMethod(anchor, "GetFrameLevel") and anchor:GetFrameLevel() or 1) + 20)
  f:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 26)
  local fs = f:CreateFontString(nil, "OVERLAY")
  fs:SetFont(FONT, SIZE, "OUTLINE")
  fs:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  fs:SetJustifyH("LEFT")
  f.text = fs
  summary = f
  return f
end

local function summaryLine()
  local S = ns.HudState
  local shards = S.shards and (WHITE .. tostring(S.shards) .. "/5|r")
    or (RED .. "unreadable|r")
  return string.format(
    "%sDEBUG|r  shards %s  %sedges|r rdy+%d/-%d aura+%d/-%d  %srecede|r %.2f  %slevel|r %s",
    AMBER, shards, GREY,
    S.fires.available, S.fires.oncd, S.fires.applied, S.fires.removed,
    GREY, ns.HudChrome.GetRecede(), GREY,
    S.levelOK == true and "ok" or (S.levelOK == false and "edges-only" or "?"))
end

--------------------------------------------------------------------------------
-- Refresh / toggle
--------------------------------------------------------------------------------
function D.Refresh()
  if not D.on or not (ns.Hud and ns.Hud.on) then return end
  for key, e in pairs(ns.Hud.items) do
    if e.item then
      local ok, line = pcall(lineFor, key, e)
      local row = ensureRow(e.item)
      row.text:SetText(ok and line or (RED .. "<row error>|r"))
      row:Show()
    end
  end
  local s = ensureSummary()
  if s then
    local ok, line = pcall(summaryLine)
    s.text:SetText(ok and line or "")
    s:Show()
  end
end

local function hideAll()
  for _, f in pairs(rows) do f:Hide() end
  if summary then summary:Hide() end
end

function D.Set(on)
  D.on = on and true or false
  if D.on then
    if not (ns.Hud and ns.Hud.on) then
      ns.Print("debug readout armed, but the HUD is off — |cffffffff/cdmp hud|r to turn it on.")
    end
    if not ticker then ticker = C_Timer.NewTicker(REFRESH, D.Refresh) end
    D.Refresh()
    ns.Print("HUD debug |cff88ff88ON|r — every tracked fact in words beside each icon. "
      .. "Group names print in their own hue, so the colour map reads itself.")
  else
    if ticker then ticker:Cancel(); ticker = nil end
    hideAll()
    ns.Print("HUD debug |cffff8080OFF|r.")
  end
  ns.db.hud.debug = D.on
end

-- Called by HudCore when the HUD itself goes off, so rows never outlive it.
function D.Hide() hideAll() end
