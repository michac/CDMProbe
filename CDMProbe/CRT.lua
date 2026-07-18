-- CRT.lua — M1 prototype skin (feasibility, DUMMY content).
--
-- The v1 pivot (project-spec §0/§6) is a CRT / green-phosphor overlay that
-- *keeps* Blizzard's icons and tints them in place — NOT the retired
-- "hide icon -> solid block" of /cdmp skin + /cdmp resource.  This command's job
-- is to prove the rendering/anchoring stack is even buildable, using placeholder
-- labels / keybinds / meter values that need not line up with the real layout.
-- Correctness comes in M3; M1 only answers five yes/no feasibility questions:
--
--   F1  keep + tint the icon in place, and have it PERSIST across repaints
--   F2  draw our chrome over a secure item (label, keybind, block-char meter)
--   F3  lay a scanline / vignette overlay over the viewer
--   F4  anchor a custom frame (shard rail) to the viewer so it RIDES ALONG
--   F5  drive persistence off the RefreshLayout/RefreshData hook, not a poll
--
-- Toggle: /cdmp crt   ·   verdict readout: /cdmp crt status
-- Deliberately a NEW command, so /cdmp skin + /cdmp resource stay as reference.
local ADDON, ns = ...

local ESS_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }

-- Green-phosphor palette (a monochrome CRT; brightness carries emphasis) -------
local PHOS      = { 0.29, 1.00, 0.48 } -- icon tint / bright text
local PHOS_MID  = { 0.24, 0.82, 0.42 } -- labels
local PHOS_DIM  = { 0.17, 0.55, 0.30 } -- meter / chrome-secondary

-- DUMMY content (M1): cycled by item index, intentionally not the real layout.
local DUMMY_KEYS  = { "Q", "E", "R", "F", "1", "2", "3", "4", "5", "6", "T", "G", "C", "V", "Z", "X" }
local DUMMY_METER = { "▮▮▮▮", "▮▮▮▯", "▮▮▯▯", "▮▯▯▯", "▯▯▯▯" }

-- Module state ----------------------------------------------------------------
local M = { on = false, hooked = false, fires = { layout = 0, data = 0 }, tinted = 0 }
local ticker, rail

--------------------------------------------------------------------------------
-- F1 + F2 : keep-and-tint the icon, draw CRT chrome over the secure item
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
  o.key:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
  o.key:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  o.key:SetTextColor(PHOS[1], PHOS[2], PHOS[3])

  o.label = f:CreateFontString(nil, "OVERLAY")          -- 4-letter id, bottom
  o.label:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
  o.label:SetPoint("BOTTOM", f, "BOTTOM", 0, 1)
  o.label:SetTextColor(PHOS_MID[1], PHOS_MID[2], PHOS_MID[3])

  o.meter = f:CreateFontString(nil, "OVERLAY")          -- block-char meter, top-right
  o.meter:SetFont(STANDARD_TEXT_FONT, 8, "OUTLINE")
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
  local icon = item.Icon
  if ns.HasMethod(icon, "SetDesaturated") then icon:SetDesaturated(true) end   -- F1
  if ns.HasMethod(icon, "SetVertexColor") then icon:SetVertexColor(PHOS[1], PHOS[2], PHOS[3]) end
  if ns.HasMethod(icon, "SetAlpha") then icon:SetAlpha(1) end                  -- ensure kept, not hidden

  local id = ns.ItemSpellID(item)
  local o = ensureChrome(item)                                                 -- F2
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
  -- vignette = four dark edge strips (cheap, no gradient asset needed)
  local function edge(p1, p2, w, h)
    local t = f:CreateTexture(nil, "ARTWORK"); t:SetColorTexture(0, 0, 0, 0.45)
    t:SetPoint(p1); t:SetPoint(p2); if w then t:SetWidth(w) end; if h then t:SetHeight(h) end
    return t
  end
  edge("TOPLEFT", "TOPRIGHT", nil, 3); edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 3)
  edge("TOPLEFT", "BOTTOMLEFT", 3, nil); edge("TOPRIGHT", "BOTTOMRIGHT", 3, nil)
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
  f.tag:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
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
-- F5 : reapply off the RefreshLayout/RefreshData hook (the choke point)
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
  forEachItem(tintItem)
  for _, name in ipairs(ESS_VIEWERS) do
    local v = ns.GetViewer(name)
    if v then flowScan(v) end
  end
  anchorRail()
end

-- hooksecurefunc can't be undone, so install ONCE and gate every callback on
-- M.on.  We count fires so /cdmp crt status can confirm the hook path is live.
local function installHooks()
  if M.hooked then return end
  local any = false
  for _, name in ipairs(ESS_VIEWERS) do
    local v = ns.GetViewer(name)
    if v then
      if ns.HasMethod(v, "RefreshLayout") then
        hooksecurefunc(v, "RefreshLayout", function() if M.on then M.fires.layout = M.fires.layout + 1; reapply() end end)
        any = true
      end
      if ns.HasMethod(v, "RefreshData") then
        hooksecurefunc(v, "RefreshData", function() if M.on then M.fires.data = M.fires.data + 1; reapply() end end)
        any = true
      end
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
  local icon = essV and ns.GetItemFrames(essV)[1] and ns.GetItemFrames(essV)[1].Icon
  ns.Printf("  F1 keep+tint  : icon:SetDesaturated present=%s  items tinted last pass=%d",
    tostring(ns.HasMethod(icon, "SetDesaturated")), M.tinted)
  ns.Printf("  F2 chrome     : label/keybind/meter drawn over %d item(s) (DUMMY content)", M.tinted)
  ns.Printf("  F3 scanlines  : overlay built on %s",
    (essV and essV.__crtScan) and "|cff88ff88viewer|r" or "|cffff4040none yet|r")
  ns.Printf("  F4 anchor     : rail anchored to viewer=%s (drag the CDM in Edit Mode — it should follow)",
    (rail and rail.anchoredToViewer) and "|cff88ff88yes|r" or "|cffffd100fallback UIParent|r")
  ns.Printf("  F5 hook fires : RefreshLayout=%d  RefreshData=%d %s",
    M.fires.layout, M.fires.data,
    (M.fires.layout + M.fires.data) > 0 and "|cff88ff88(hook path live)|r" or "|cffffd100(resize/relayout the CDM to test)|r")
  ns.Print("  verdict: all five |cff88ff88ON/present/firing|r → M1 done; any ✗ → design changes there (that's the point).")
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
    if not ticker then ticker = C_Timer.NewTicker(1.0, reapply) end -- SAFETY NET only; F5 hook is primary
    ns.Print("CRT prototype |cff88ff88ON|r — icons kept + green-tinted, DUMMY labels/keybinds/meters, scanlines, anchored rail. |cffffffff/cdmp crt status|r for verdicts.")
  else
    M.on = false
    if ticker then ticker:Cancel(); ticker = nil end
    forEachItem(restoreItem)
    for _, name in ipairs(ESS_VIEWERS) do
      local v = ns.GetViewer(name)
      if v and v.__crtScan then v.__crtScan:Hide() end
      if v and ns.HasMethod(v, "RefreshData") then pcall(v.RefreshData, v) end -- let Blizzard repaint clean
    end
    if rail then rail:Hide() end
    railEvents:UnregisterAllEvents()
    ns.Print("CRT prototype |cffff8080OFF|r — Blizzard icons restored.")
  end
end

ns.RegisterCommand("crt",
  "M1 prototype: keep+tint icons (green phosphor) + DUMMY chrome + scanlines + anchored rail. 'status' = feasibility verdicts.",
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
