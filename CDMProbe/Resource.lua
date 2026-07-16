-- Resource.lua — the "resource-centric" skin (design direction 3).
--   * Essential/Utility items -> group-colored blocks + 4-letter labels (keeps swipe)
--   * BuffBar items          -> recolored duration bars (Blizzard drives the fill)
--   * a hero Soul Shard rail we OWN: partial fill, generate->spend->cap recolor,
--     a cap flash + spark burst + earcon (shards are readable & branchable).
-- Rough M1 prototype: toggle with /cdmp resource.  Reuses Viewers/Skin/Util helpers.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- palette (matches the HTML prototype; hue carries GROUP, not per-spell identity)
--------------------------------------------------------------------------------
local C = {
  summon  = { 0.216, 0.784, 0.435 }, -- fel green  — demon summons / burst
  core    = { 0.627, 0.396, 1.000 }, -- shadow violet — core shadow damage
  aoe     = { 0.741, 0.953, 0.227 }, -- fel lime  — Implosion
  proc    = { 0.176, 0.831, 0.933 }, -- arcane cyan — procs / resource accent
  def     = { 0.290, 0.620, 1.000 }, -- blue      — defensives
  cc      = { 0.541, 0.580, 0.671 }, -- slate     — control
  mob     = { 0.961, 0.773, 0.259 }, -- gold      — mobility
  neutral = { 0.360, 0.340, 0.420 }, -- untracked / not in our opinionated set
}
local SHARD = {
  gen   = { 0.690, 0.420, 1.000 }, -- generate — soul purple
  spend = { 1.000, 0.541, 0.239 }, -- spend    — orange
  cap   = { 0.961, 0.773, 0.259 }, -- at cap   — gold
  empty = { 0.140, 0.120, 0.180 },
}

-- Opinionated Demonology tracked set (Kalamazi / Diabolist).  spellID -> group.
local GROUP = {
  [265187] = "summon", [104316] = "summon", [1276467] = "summon", -- Tyrant, Dreadstalkers, Fel Ravager
  [105174] = "core",   [264178] = "core",                          -- Hand of Gul'dan, Demonbolt
  [196277] = "aoe",                                                -- Implosion
  [104773] = "def",    [108416] = "def",                           -- Unending Resolve, Dark Pact
  [30283]  = "cc",     [119914] = "cc", [6789] = "cc", [1271802] = "cc", -- Shadowfury, Axe Toss, Mortal Coil, Blight
  [48020]  = "mob",                                                -- Demonic Circle: Teleport
  [264173] = "proc",   [1276166] = "core",                         -- (buff bars) Demonic Core, Dominion of Argus
}
local LABEL = {
  [265187] = "TYRA", [104316] = "DREA", [1276467] = "FELR",
  [105174] = "HAND", [264178] = "CORE", [196277] = "IMPL",
  [104773] = "UNEN", [108416] = "DARK", [30283] = "SHAD",
  [119914] = "AXE",  [6789]   = "MORT", [48020] = "CIRC",
  [1271802] = "BLIG", [264173] = "CORE", [1276166] = "DOMI",
}

local function groupColorFor(id)
  local g = id and GROUP[id]
  local c = (g and C[g]) or C.neutral
  return c[1], c[2], c[3]
end
local function labelFor(id)
  if id and LABEL[id] then return LABEL[id] end
  local n = id and ns.SpellName(id)
  return (n and n:sub(1, 4):upper()) or "?"
end

--------------------------------------------------------------------------------
-- viewer skinning (blocks + bars)
--------------------------------------------------------------------------------
local ESS_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }
local BAR_VIEWERS = { "BuffBarCooldownViewer" }
local ticker

local function ensureOverlay(item)
  if item.__cdmr then return item.__cdmr end
  local o = {}
  local sw = item:CreateTexture(nil, "ARTWORK", nil, 7) -- above the icon art
  sw:SetAllPoints(item)
  o.swatch = sw
  local lb = item:CreateFontString(nil, "OVERLAY")
  lb:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
  lb:SetPoint("BOTTOM", item, "BOTTOM", 0, 1)
  o.label = lb
  item.__cdmr = o
  return o
end

local function skinBlock(item)
  local id = ns.ItemSpellID(item)
  local o = ensureOverlay(item)
  local r, g, b = groupColorFor(id)
  o.swatch:SetColorTexture(r, g, b, 0.92)
  o.label:SetText(labelFor(id))
  if item.Icon and item.Icon.SetAlpha then item.Icon:SetAlpha(0) end
  o.swatch:Show(); o.label:Show()
end

local function skinBar(item)
  local id = ns.ItemSpellID(item)
  local r, g, b = groupColorFor(id)
  local bar = item.Bar or item.StatusBar
  if bar and bar.SetStatusBarColor then bar:SetStatusBarColor(r, g, b) end
  if item.Icon and item.Icon.SetAlpha then item.Icon:SetAlpha(0) end -- drop the bar's icon
end

local function unskinItem(item)
  local o = item.__cdmr
  if o then o.swatch:Hide(); o.label:Hide() end
  if item.Icon and item.Icon.SetAlpha then item.Icon:SetAlpha(1) end
end

local function forEach(viewerNames, fn)
  for _, name in ipairs(viewerNames) do
    local viewer = ns.GetViewer(name)
    if viewer then
      local items = ns.GetItemFrames(viewer)
      for _, item in ipairs(items) do pcall(fn, item) end
    end
  end
end

local function applyAll()
  forEach(ESS_VIEWERS, skinBlock)
  forEach(BAR_VIEWERS, skinBar)
end
local function clearAll()
  forEach(ESS_VIEWERS, unskinItem)
  forEach(BAR_VIEWERS, unskinItem)
  -- ask Blizzard to repaint the bars back to their own colors
  for _, name in ipairs(BAR_VIEWERS) do
    local v = ns.GetViewer(name)
    if v and ns.HasMethod(v, "RefreshData") then pcall(v.RefreshData, v) end
  end
end

--------------------------------------------------------------------------------
-- Soul Shard rail (OURS — readable & branchable)
--------------------------------------------------------------------------------
local SHARD_MAX = 5
local SOUL = (Enum.PowerType and Enum.PowerType.SoulShards) or 7
local SEG_W, SEG_H, GAP, PAD = 46, 30, 6, 8
local rail

local function buildSpark(parent)
  local t = parent:CreateTexture(nil, "OVERLAY")
  t:SetSize(4, 4); t:SetColorTexture(1, 1, 1, 1); t:SetAlpha(0)
  local ag = t:CreateAnimationGroup()
  local tr = ag:CreateAnimation("Translation"); tr:SetDuration(0.85); tr:SetSmoothing("OUT")
  local fa = ag:CreateAnimation("Alpha"); fa:SetFromAlpha(1); fa:SetToAlpha(0); fa:SetDuration(0.85)
  ag:SetScript("OnPlay", function() t:SetAlpha(1) end)
  ag:SetScript("OnFinished", function() t:SetAlpha(0) end)
  t.ag, t.tr = ag, tr
  return t
end

local function buildRail()
  if rail then return rail end
  local f = CreateFrame("Frame", "CDMResourceRail", UIParent)
  f:SetSize(SHARD_MAX * SEG_W + (SHARD_MAX - 1) * GAP + PAD * 2, SEG_H + PAD * 2)
  local p = ns.db.resourceRail or { point = "CENTER", x = 0, y = -180 }
  f:SetPoint(p.point, UIParent, p.point, p.x, p.y)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    ns.db.resourceRail = { point = point, x = x, y = y }
  end)

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f); bg:SetColorTexture(0, 0, 0, 0.35)

  f.segs = {}
  for i = 1, SHARD_MAX do
    local seg = CreateFrame("Frame", nil, f)
    seg:SetSize(SEG_W, SEG_H)
    seg:SetPoint("LEFT", f, "LEFT", PAD + (i - 1) * (SEG_W + GAP), 0)
    local segbg = seg:CreateTexture(nil, "ARTWORK")
    segbg:SetAllPoints(seg); segbg:SetColorTexture(unpack(SHARD.empty))
    local fill = seg:CreateTexture(nil, "ARTWORK", nil, 1)
    fill:SetPoint("LEFT", seg, "LEFT", 0, 0)
    fill:SetSize(SEG_W, SEG_H)
    seg.fill = fill
    f.segs[i] = seg
  end

  f.text = f:CreateFontString(nil, "OVERLAY")
  f.text:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
  f.text:SetPoint("BOTTOM", f, "TOP", 0, 3)

  -- cap flash overlay (fades out)
  local flash = f:CreateTexture(nil, "OVERLAY")
  flash:SetAllPoints(f); flash:SetColorTexture(SHARD.cap[1], SHARD.cap[2], SHARD.cap[3], 0.5); flash:SetAlpha(0)
  local fag = flash:CreateAnimationGroup()
  local fa = fag:CreateAnimation("Alpha"); fa:SetFromAlpha(0.55); fa:SetToAlpha(0); fa:SetDuration(0.7)
  fag:SetScript("OnPlay", function() flash:SetAlpha(0.55) end)
  fag:SetScript("OnFinished", function() flash:SetAlpha(0) end)
  f.flash, f.flashAG = flash, fag

  f.sparks = {}
  for i = 1, 10 do f.sparks[i] = buildSpark(f) end

  f.prevCapped = false
  rail = f
  return f
end

local function fireGlitter()
  local f = rail
  if not f then return end
  f.flashAG:Stop(); f.flashAG:Play()
  local w = f:GetWidth()
  for _, s in ipairs(f.sparks) do
    s:ClearAllPoints()
    s:SetPoint("CENTER", f, "CENTER", math.random(-w / 2 + 6, w / 2 - 6), math.random(-6, 6))
    s.tr:SetOffset(math.random(-8, 8), math.random(10, 22))
    s.ag:Stop(); s.ag:Play()
  end
  if SOUNDKIT and SOUNDKIT.UI_BNET_TOAST then PlaySound(SOUNDKIT.UI_BNET_TOAST, "SFX") end
end

local function updateRail()
  local f = rail
  if not f or not f:IsShown() then return end
  local raw = UnitPower("player", SOUL, true)
  if ns.IsSecret(raw) then return end -- shards ARE normally readable; bail if not
  local maxRaw = UnitPowerMax("player", SOUL, true)
  local total = (maxRaw and maxRaw > 0) and (raw / maxRaw) or 0 -- 0..1 across all 5
  local shards = total * SHARD_MAX

  local capped = shards >= SHARD_MAX - 0.02
  local spend  = capped or shards >= 4.5
  local col = capped and SHARD.cap or (spend and SHARD.spend or SHARD.gen)

  for i = 1, SHARD_MAX do
    local segFrac = math.max(0, math.min(1, shards - (i - 1)))
    local fill = f.segs[i].fill
    fill:SetColorTexture(col[1], col[2], col[3], 1)
    fill:SetWidth(math.max(0.001, SEG_W * segFrac))
    fill:SetShown(segFrac > 0)
  end

  if capped then
    f.text:SetText("|cffffd100SPEND — CAP (" .. math.floor(shards + 0.01) .. "/5)|r")
  elseif spend then
    f.text:SetText("|cffff9a4dSPEND|r  " .. math.floor(shards) .. "/5")
  else
    f.text:SetText("|cffb06bffGENERATE|r  " .. math.floor(shards) .. "/5")
  end

  if capped and not f.prevCapped then fireGlitter() end
  f.prevCapped = capped
end

local railEvents = CreateFrame("Frame")
railEvents:SetScript("OnEvent", updateRail)
local function railEventsOn(on)
  if on then
    railEvents:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
    railEvents:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
    railEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
  else
    railEvents:UnregisterAllEvents()
  end
end

--------------------------------------------------------------------------------
-- toggle
--------------------------------------------------------------------------------
function ns.SetResource(on)
  ns.db.resourceOn = on and true or false
  if on then
    if ns.db.skinOn and ns.SetSkin then ns.SetSkin(false) end -- avoid fighting the plain skin
    if _G.CDMProbeShards then _G.CDMProbeShards:Hide() end      -- and the plain shard bar
    local f = buildRail(); f:Show(); railEventsOn(true); updateRail()
    applyAll()
    if not ticker then ticker = C_Timer.NewTicker(0.5, applyAll) end -- watchdog re-apply
    ns.Print("resource skin |cff88ff88ON|r — group-color blocks + duration bars + soul-shard rail (drag the rail to move).")
  else
    if ticker then ticker:Cancel(); ticker = nil end
    clearAll()
    if rail then rail:Hide(); railEventsOn(false) end
    ns.Print("resource skin |cffff8080OFF|r — Blizzard restored.")
  end
end

ns.RegisterCommand("resource",
  "resource-centric skin: group-color blocks + duration bars + soul-shard rail (cap glitter+sound)",
  function() ns.SetResource(not ns.db.resourceOn) end)

-- fold into /cdmp reset (defined in Probes.lua; wrap it)
local prevReset = ns.commands.reset and ns.commands.reset.fn
ns.RegisterCommand("reset", "turn every experiment off (unskin, hide bars/rail, resource off, log off)", function(rest)
  if ns.db.resourceOn then ns.SetResource(false) end
  if prevReset then prevReset(rest) end
end)

-- restore on login (wrap the existing OnLogin from Probes.lua)
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  if ns.db and ns.db.resourceOn then
    C_Timer.After(1.0, function() ns.SetResource(true) end)
  end
end
