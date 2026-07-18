-- CRT.lua — M1 prototype skin (feasibility, DUMMY content) + terminal chrome.
--
-- The v1 pivot (project-spec §0/§6) is a CRT / green-phosphor overlay that
-- *keeps* Blizzard's icons and tints them in place — NOT the retired
-- "hide icon -> solid block" of /cdmp skin + /cdmp resource.  This command
-- proves the rendering/anchoring stack is buildable, with placeholder labels /
-- keybinds / meter values that need not line up with the real layout, and wraps
-- the columns in a "DEMONOLOGY.SYS" terminal frame (header/footer flavor from
-- the overlay-styles.html direction B) so it reads as part of a larger UI.
--
-- Five M1 feasibility questions (readout: /cdmp crt status):
--   F1  keep + tint the icon in place, PERSISTING across repaints
--   F2  draw our chrome over a secure item (label, keybind, block-char meter)
--   F3  lay a scanline / vignette overlay over the viewer
--   F4  anchor a custom frame (shard rail) to the viewer so it RIDES ALONG
--   F5  persist off the per-ITEM RefreshData/RefreshSpellTexture hook, not a poll
--
-- F5 detail (source: Blizzard_CooldownViewer/CooldownViewer.lua @ 68453):
--   CooldownViewerCooldownItemMixin:RefreshData() runs, in order,
--   RefreshSpellTexture (SetTexture resets the icon) -> RefreshIconDesaturation
--   -> RefreshIconColor: Blizzard re-desaturates AND re-colors every refresh,
--   clobbering our tint (the white flash).  The methods are Mixin()-copied onto
--   each frame, so we hook the ITEM INSTANCE (not the shared mixin table) and
--   re-apply AFTER Blizzard.  The viewer-level RefreshLayout only fires on
--   relayout — it reflows chrome + re-hooks new items, it is NOT the tint fix.
--
-- Toggle: /cdmp crt   ·   verdicts: /cdmp crt status.  New command only, so
-- /cdmp skin + /cdmp resource stay as reference.
local ADDON, ns = ...

local ESS_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }

-- Green-phosphor palette (monochrome CRT; brightness carries emphasis) ---------
local PHOS      = { 0.29, 1.00, 0.48 } -- icon tint / bright text
local PHOS_MID  = { 0.24, 0.82, 0.42 } -- labels / header
local PHOS_DIM  = { 0.17, 0.55, 0.30 } -- meter / chrome-secondary
local TERM_FONT = "Fonts\\ARIALN.TTF"  -- narrow bundled font (closest to mono)

-- DUMMY content (M1): cycled by item index, intentionally not the real layout.
local DUMMY_KEYS  = { "Q", "E", "R", "F", "1", "2", "3", "4", "5", "6", "T", "G", "C", "V", "Z", "X" }
local DUMMY_METER = { "▮▮▮▮", "▮▮▮▯", "▮▮▯▯", "▮▯▯▯", "▯▯▯▯" }

-- Module state ----------------------------------------------------------------
local M = { on = false, hooked = false, fires = { item = 0, layout = 0 }, tinted = 0 }
local ticker, rail, blinkTicker, terminal

--------------------------------------------------------------------------------
-- F1 + F5 : tint the icon, and make it survive Blizzard's per-item repaint
--------------------------------------------------------------------------------

-- The light re-apply: just our desaturation + green vertex color (the two things
-- Blizzard's RefreshIconDesaturation / RefreshIconColor overwrite).  Cheap.
local function reTint(item)
  local icon = item.Icon
  if not icon then return end
  if ns.HasMethod(icon, "SetDesaturated") then icon:SetDesaturated(true) end
  if ns.HasMethod(icon, "SetVertexColor") then icon:SetVertexColor(PHOS[1], PHOS[2], PHOS[3]) end
  if ns.HasMethod(icon, "SetAlpha") then icon:SetAlpha(1) end -- keep it, never hide
end

-- Hook a single item INSTANCE once (methods are Mixin()-copied per frame, so a
-- shared-mixin hook wouldn't reach already-created frames).  Both callbacks
-- run AFTER Blizzard's, and are gated on M.on so toggling off leaves clean.
local function hookItem(item)
  if item.__crtHooked then return end
  if ns.HasMethod(item, "RefreshData") then
    hooksecurefunc(item, "RefreshData", function(self)
      if M.on then M.fires.item = M.fires.item + 1; reTint(self) end
    end)
  end
  if ns.HasMethod(item, "RefreshSpellTexture") then           -- standalone icon-event path
    hooksecurefunc(item, "RefreshSpellTexture", function(self)
      if M.on then reTint(self) end
    end)
  end
  item.__crtHooked = true
end

--------------------------------------------------------------------------------
-- F2 : draw our chrome over a secure item (label / keybind / block-char meter)
--------------------------------------------------------------------------------

-- A child frame ABOVE the Cooldown swipe holds our chrome, so labels aren't
-- dimmed under the radial swipe.  Attached once per item, reused thereafter.
local function ensureChrome(item)
  if item.__crt then return item.__crt end
  local o = {}
  local lvl = (ns.HasMethod(item, "GetFrameLevel") and item:GetFrameLevel() or 1) + 5
  if item.Cooldown and ns.HasMethod(item.Cooldown, "GetFrameLevel") then
    lvl = math.max(lvl, item.Cooldown:GetFrameLevel() + 2)
  end
  local f = CreateFrame("Frame", nil, item)
  f:SetAllPoints(item)
  f:SetFrameLevel(lvl)
  o.frame = f

  o.key = f:CreateFontString(nil, "OVERLAY")           -- keybind, top-left
  o.key:SetFont(TERM_FONT, 11, "OUTLINE")
  o.key:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  o.key:SetTextColor(PHOS[1], PHOS[2], PHOS[3])

  o.label = f:CreateFontString(nil, "OVERLAY")          -- 4-letter id, bottom
  o.label:SetFont(TERM_FONT, 11, "OUTLINE")
  o.label:SetPoint("BOTTOM", f, "BOTTOM", 0, 1)
  o.label:SetTextColor(PHOS_MID[1], PHOS_MID[2], PHOS_MID[3])

  o.meter = f:CreateFontString(nil, "OVERLAY")          -- block-char meter, top-right
  o.meter:SetFont(TERM_FONT, 9, "OUTLINE")
  o.meter:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
  o.meter:SetTextColor(PHOS_DIM[1], PHOS_DIM[2], PHOS_DIM[3])

  item.__crt = o
  return o
end

local function labelFor(id, idx)
  local n = id and ns.SpellName(id)
  if n then return n:sub(1, 4):upper() end
  return "SP" .. string.format("%02d", idx) -- dummy fallback, clearly placeholder
end

local function tintItem(item, idx)
  reTint(item)                                                       -- F1
  hookItem(item)                                                     -- F5 (persist)
  local id = ns.ItemSpellID(item)
  local o = ensureChrome(item)                                       -- F2
  o.key:SetText(DUMMY_KEYS[((idx - 1) % #DUMMY_KEYS) + 1])          -- DUMMY
  o.label:SetText(labelFor(id, idx))
  o.meter:SetText(DUMMY_METER[((idx - 1) % #DUMMY_METER) + 1])      -- DUMMY
  o.frame:Show()
  M.tinted = M.tinted + 1
end

local function restoreItem(item)
  local icon = item.Icon
  if ns.HasMethod(icon, "SetDesaturated") then icon:SetDesaturated(false) end
  if ns.HasMethod(icon, "SetVertexColor") then icon:SetVertexColor(1, 1, 1) end
  if item.__crt then item.__crt.frame:Hide() end
end

--------------------------------------------------------------------------------
-- F3 : scanline + vignette overlay over each viewer
--------------------------------------------------------------------------------
local function ensureScan(viewer)
  if viewer.__crtScan then return viewer.__crtScan end
  local f = CreateFrame("Frame", nil, viewer)
  f:SetAllPoints(viewer)
  f:SetFrameLevel((ns.HasMethod(viewer, "GetFrameLevel") and viewer:GetFrameLevel() or 1) + 10)
  -- mouse-transparent by default (we never EnableMouse) so clicks pass through.
  local glow = f:CreateTexture(nil, "BACKGROUND")      -- faint phosphor wash
  glow:SetAllPoints(f); glow:SetColorTexture(PHOS[1], PHOS[2], PHOS[3], 0.05)
  f.lines = {}
  viewer.__crtScan = f
  return f
end

-- (Re)flow horizontal scanlines to the viewer's current height.
local function flowScan(viewer)
  local f = ensureScan(viewer)
  local h = math.floor((ns.HasMethod(viewer, "GetHeight") and viewer:GetHeight()) or 0)
  local n = math.max(0, math.floor(h / 3))                    -- one dark line every 3px
  for i = 1, n do
    local ln = f.lines[i]
    if not ln then
      ln = f:CreateTexture(nil, "OVERLAY"); ln:SetColorTexture(0, 0, 0, 0.22)
      ln:SetHeight(1)
      f.lines[i] = ln
    end
    ln:ClearAllPoints()
    ln:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(i - 1) * 3)
    ln:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -(i - 1) * 3)
    ln:Show()
  end
  for i = n + 1, #f.lines do f.lines[i]:Hide() end             -- pool: hide extras
  f:Show()
end

--------------------------------------------------------------------------------
-- Terminal chrome : DEMONOLOGY.SYS header / footer, so the column reads as a
-- readout inside a larger interface (flavor from overlay-styles.html · dir B).
-- Anchored to the Essential viewer's edges → rides along + reflows with it.
--------------------------------------------------------------------------------
local function rule(parent, anchorTo, ptA, ptB, offY)
  local t = parent:CreateTexture(nil, "OVERLAY")
  t:SetColorTexture(PHOS_MID[1], PHOS_MID[2], PHOS_MID[3], 0.8)
  t:SetHeight(1)
  t:SetPoint("TOPLEFT", anchorTo, ptA, 0, offY)
  t:SetPoint("TOPRIGHT", anchorTo, ptB, 0, offY)
  return t
end

local function buildTerminal(viewer)
  if viewer.__crtTerm then return viewer.__crtTerm end
  local f = CreateFrame("Frame", nil, viewer)
  f:SetAllPoints(viewer)
  f:SetFrameLevel((ns.HasMethod(viewer, "GetFrameLevel") and viewer:GetFrameLevel() or 1) + 12)

  -- header (above the column)
  local hd = f:CreateFontString(nil, "OVERLAY")
  hd:SetFont(TERM_FONT, 11, "OUTLINE")
  hd:SetPoint("BOTTOMLEFT", viewer, "TOPLEFT", 0, 6)
  hd:SetPoint("BOTTOMRIGHT", viewer, "TOPRIGHT", 0, 6)
  hd:SetJustifyH("CENTER")
  hd:SetTextColor(PHOS[1], PHOS[2], PHOS[3])
  hd:SetText(">> DEMONOLOGY.SYS")
  local sub = f:CreateFontString(nil, "OVERLAY")
  sub:SetFont(TERM_FONT, 8, "OUTLINE")
  sub:SetPoint("TOP", hd, "BOTTOM", 0, 0)
  sub:SetJustifyH("CENTER")
  sub:SetTextColor(PHOS_DIM[1], PHOS_DIM[2], PHOS_DIM[3])
  sub:SetText("v12.0.7 // CDM OVERLAY")
  rule(f, viewer, "TOPLEFT", "TOPRIGHT", 4)        -- rule just above the icons

  -- side borders (enclose the column)
  local function vrule(pt)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(PHOS_MID[1], PHOS_MID[2], PHOS_MID[3], 0.55); t:SetWidth(1)
    t:SetPoint("TOP", viewer, pt == "L" and "TOPLEFT" or "TOPRIGHT", pt == "L" and -2 or 2, 4)
    t:SetPoint("BOTTOM", viewer, pt == "L" and "BOTTOMLEFT" or "BOTTOMRIGHT", pt == "L" and -2 or 2, -4)
  end
  vrule("L"); vrule("R")

  -- footer (below the column) — blinking terminal prompt
  rule(f, viewer, "BOTTOMLEFT", "BOTTOMRIGHT", -4)
  local ft = f:CreateFontString(nil, "OVERLAY")
  ft:SetFont(TERM_FONT, 10, "OUTLINE")
  ft:SetPoint("TOPLEFT", viewer, "BOTTOMLEFT", 1, -6)
  ft:SetJustifyH("LEFT")
  ft:SetTextColor(PHOS_MID[1], PHOS_MID[2], PHOS_MID[3])
  f.footer = ft
  f.cursorOn = true
  f.footer:SetText("C:\\WOW\\HUD> _")

  viewer.__crtTerm = f
  return f
end

local function setBlink(on)
  if on then
    if blinkTicker then return end
    blinkTicker = C_Timer.NewTicker(0.53, function()
      if not terminal or not terminal.footer then return end
      terminal.cursorOn = not terminal.cursorOn
      terminal.footer:SetText("C:\\WOW\\HUD> " .. (terminal.cursorOn and "_" or " "))
    end)
  elseif blinkTicker then
    blinkTicker:Cancel(); blinkTicker = nil
  end
end

--------------------------------------------------------------------------------
-- F4 : a shard rail ANCHORED to the viewer (rides along when the CDM moves)
--------------------------------------------------------------------------------
local SHARD_MAX = 5
local SOUL = (Enum.PowerType and Enum.PowerType.SoulShards) or 7
local SEG_W, SEG_H, GAP, PAD = 40, 12, 4, 6

local function buildRail()
  if rail then return rail end
  local f = CreateFrame("Frame", "CDMCrtRail", UIParent)
  f:SetSize(SHARD_MAX * SEG_W + (SHARD_MAX - 1) * GAP + PAD * 2, SEG_H + PAD * 2)
  local bg = f:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(f); bg:SetColorTexture(0, 0, 0, 0.5)
  f.segs = {}
  for i = 1, SHARD_MAX do
    local segbg = f:CreateTexture(nil, "ARTWORK")
    segbg:SetSize(SEG_W, SEG_H)
    segbg:SetPoint("LEFT", f, "LEFT", PAD + (i - 1) * (SEG_W + GAP), 0)
    segbg:SetColorTexture(PHOS_DIM[1] * 0.4, PHOS_DIM[2] * 0.4, PHOS_DIM[3] * 0.4, 1)
    local fill = f:CreateTexture(nil, "ARTWORK", nil, 1)
    fill:SetPoint("LEFT", segbg, "LEFT"); fill:SetSize(SEG_W, SEG_H)
    fill:SetColorTexture(PHOS[1], PHOS[2], PHOS[3], 1)
    f.segs[i] = fill
  end
  f.tag = f:CreateFontString(nil, "OVERLAY")
  f.tag:SetFont(TERM_FONT, 9, "OUTLINE")
  f.tag:SetPoint("BOTTOM", f, "TOP", 0, 2)
  f.tag:SetTextColor(PHOS_MID[1], PHOS_MID[2], PHOS_MID[3])
  f.tag:SetText("SHARDS")
  rail = f
  return f
end

-- The F4 test: anchor to the viewer frame, NOT screen coords, so dragging the
-- CDM in Edit Mode moves the rail with it — no polling of GetRect needed.
local function anchorRail()
  local f = buildRail()
  local v = ns.GetViewer("EssentialCooldownViewer")
  f:ClearAllPoints()
  if v then
    f:SetPoint("TOPRIGHT", v, "TOPLEFT", -8, 0)        -- rides along
    f.anchoredToViewer = true
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -180)  -- fallback if viewer absent
    f.anchoredToViewer = false
  end
end

local function updateRail()
  if not rail or not rail:IsShown() then return end
  local raw = UnitPower("player", SOUL, true)
  if ns.IsSecret(raw) then return end
  local maxRaw = UnitPowerMax("player", SOUL, true)
  local shards = ((maxRaw and maxRaw > 0) and (raw / maxRaw) or 0) * SHARD_MAX
  for i = 1, SHARD_MAX do
    local frac = math.max(0, math.min(1, shards - (i - 1)))
    rail.segs[i]:SetWidth(math.max(0.001, SEG_W * frac))
    rail.segs[i]:SetShown(frac > 0)
  end
end

local railEvents = CreateFrame("Frame")
railEvents:SetScript("OnEvent", updateRail)

--------------------------------------------------------------------------------
-- Apply / relayout
--------------------------------------------------------------------------------
local function forEachItem(fn)
  for _, name in ipairs(ESS_VIEWERS) do
    local viewer = ns.GetViewer(name)
    if viewer then
      local items = ns.GetItemFrames(viewer)
      for i, item in ipairs(items) do pcall(fn, item, i) end
    end
  end
end

local function reapply()
  if not M.on then return end
  M.tinted = 0
  forEachItem(tintItem)                                  -- tint + hook + chrome
  for _, name in ipairs(ESS_VIEWERS) do
    local v = ns.GetViewer(name)
    if v then flowScan(v) end
  end
  terminal = buildTerminal(ns.GetViewer("EssentialCooldownViewer") or UIParent)
  anchorRail()
end

-- Viewer-level RefreshLayout: fires on relayout (tracked-set / orientation /
-- size change).  It reflows chrome and re-hooks any newly-created item frames.
-- Installed ONCE; hooksecurefunc can't be undone, so gate on M.on.
local function installHooks()
  if M.hooked then return end
  local any = false
  for _, name in ipairs(ESS_VIEWERS) do
    local v = ns.GetViewer(name)
    if v and ns.HasMethod(v, "RefreshLayout") then
      hooksecurefunc(v, "RefreshLayout", function()
        if M.on then M.fires.layout = M.fires.layout + 1; reapply() end
      end)
      any = true
    end
  end
  M.hooked = any   -- if viewers weren't present yet, retry next enable
end

--------------------------------------------------------------------------------
-- Verdict readout
--------------------------------------------------------------------------------
local function printStatus()
  ns.Heading("CRT prototype — M1 feasibility verdicts")
  ns.Printf("  state: %s", M.on and "|cff88ff88ON|r" or "|cffff8080OFF|r")
  local essV = ns.GetViewer("EssentialCooldownViewer")
  local firstItem = essV and ns.GetItemFrames(essV)[1]
  local icon = firstItem and firstItem.Icon
  ns.Printf("  F1 keep+tint  : icon:SetDesaturated present=%s  items tinted last pass=%d",
    tostring(ns.HasMethod(icon, "SetDesaturated")), M.tinted)
  ns.Printf("  F2 chrome     : label/keybind/meter drawn over %d item(s) (DUMMY content)", M.tinted)
  ns.Printf("  F3 scanlines  : overlay built on %s",
    (essV and essV.__crtScan) and "|cff88ff88viewer|r" or "|cffff4040none yet|r")
  ns.Printf("  F4 anchor     : rail anchored to viewer=%s (drag the CDM in Edit Mode — it should follow)",
    (rail and rail.anchoredToViewer) and "|cff88ff88yes|r" or "|cffffd100fallback UIParent|r")
  ns.Printf("  F5 persist    : per-item RefreshData hooks fired=%d  (viewer RefreshLayout=%d) %s",
    M.fires.item, M.fires.layout,
    M.fires.item > 0 and "|cff88ff88(tint persists off the hook — no more white flash)|r"
                       or "|cffffd100(cast/use a spell so an item refreshes)|r")
  ns.Print("  verdict: F1-F4 built + F5 item-hook firing → M1 done; watch the icons DON'T flash white.")
end

--------------------------------------------------------------------------------
-- Toggle
--------------------------------------------------------------------------------
function ns.SetCRT(on)
  ns.db.crtOn = on and true or false
  M.on = ns.db.crtOn
  if on then
    if ns.db.skinOn and ns.SetSkin then ns.SetSkin(false) end      -- these hide the icon; don't fight
    if ns.db.resourceOn and ns.SetResource then ns.SetResource(false) end
    installHooks()
    reapply()
    buildRail():Show(); anchorRail()
    railEvents:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
    railEvents:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
    updateRail()
    setBlink(true)
    -- Backstop ONLY: catch item frames created/pooled between relayouts (re-hook
    -- + re-tint).  The per-item hook (F5) is what kills the flash; this is slow.
    if not ticker then ticker = C_Timer.NewTicker(2.0, reapply) end
    ns.Print("CRT prototype |cff88ff88ON|r — icons kept + green-tinted (persist-hooked), DEMONOLOGY.SYS terminal chrome, DUMMY labels/keybinds, anchored rail. |cffffffff/cdmp crt status|r for verdicts.")
  else
    M.on = false
    if ticker then ticker:Cancel(); ticker = nil end
    setBlink(false)
    forEachItem(restoreItem)
    for _, name in ipairs(ESS_VIEWERS) do
      local v = ns.GetViewer(name)
      if v and v.__crtScan then v.__crtScan:Hide() end
      if v and v.__crtTerm then v.__crtTerm:Hide() end
      if v and ns.HasMethod(v, "RefreshData") then pcall(v.RefreshData, v) end -- let Blizzard repaint clean
    end
    if rail then rail:Hide() end
    railEvents:UnregisterAllEvents()
    ns.Print("CRT prototype |cffff8080OFF|r — Blizzard icons restored.")
  end
end

ns.RegisterCommand("crt",
  "M1 prototype: keep+tint icons (green phosphor, persist-hooked) + DEMONOLOGY.SYS terminal chrome + DUMMY labels + anchored rail. 'status' = verdicts.",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("status") or rest:find("verdict") then return printStatus() end
    ns.SetCRT(not ns.db.crtOn)
  end)

-- Fold into /cdmp reset (wrap the chain Probes.lua + Resource.lua built).
local prevReset = ns.commands.reset and ns.commands.reset.fn
ns.RegisterCommand("reset", "turn every experiment off (unskin, hide bars/rail, resource+crt off, log off)", function(rest)
  if ns.db.crtOn then ns.SetCRT(false) end
  if prevReset then prevReset(rest) end
end)

-- Restore on login (wrap the existing chain).
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  if ns.db and ns.db.crtOn then
    C_Timer.After(1.0, function() ns.SetCRT(true) end)
  end
end
