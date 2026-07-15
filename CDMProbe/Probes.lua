-- Probes.lua — the "what actually works in combat" experiments:
--   * a draggable Soul Shard bar that is Secret-Values-aware,
--   * an on-demand secret probe (run out of combat, then in combat),
--   * an event logger (glow show/hide tests proc detection; CDM data-loaded etc).
local ADDON, ns = ...

local SHARD_MAX = 5
local SOUL = Enum.PowerType and Enum.PowerType.SoulShards
local shardFrame

--------------------------------------------------------------------------------
-- Soul Shard bar
--------------------------------------------------------------------------------
local function buildShardFrame()
  if shardFrame then return shardFrame end
  local f = CreateFrame("Frame", "CDMProbeShards", UIParent)
  f:SetSize(SHARD_MAX * 26 + (SHARD_MAX - 1) * 3 + 8, 40)
  local p = ns.db.shardFrame
  f:SetPoint(p.point, UIParent, p.point, p.x, p.y)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    ns.db.shardFrame = { point = point, x = x, y = y }
  end)

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  bg:SetColorTexture(0, 0, 0, 0.4)

  f.segs = {}
  for i = 1, SHARD_MAX do
    local s = f:CreateTexture(nil, "ARTWORK")
    s:SetSize(26, 22)
    s:SetPoint("LEFT", f, "LEFT", 4 + (i - 1) * (26 + 3), 6)
    s:SetColorTexture(0.2, 0.2, 0.25, 1)
    f.segs[i] = s
  end

  f.text = f:CreateFontString(nil, "OVERLAY")
  f.text:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
  f.text:SetPoint("BOTTOM", f, "TOP", 0, 2)

  shardFrame = f
  return f
end

local function updateShards()
  local f = shardFrame
  if not f or not f:IsShown() then return end
  local val = UnitPower("player", SOUL) -- may be a Secret Value in restricted combat

  if ns.IsSecret(val) then
    -- We must NOT compare a secret; just show that fact.  This IS the experiment.
    for i = 1, SHARD_MAX do f.segs[i]:SetColorTexture(0.45, 0.12, 0.5, 1) end
    f.text:SetText("shards = |cffff4040<secret>|r  (can't read in Lua here)")
  else
    local n = tonumber(val) or 0
    local pr, pg, pb = ns.HSV(275, 0.7, 0.98) -- Warlock purple
    for i = 1, SHARD_MAX do
      if i <= n then f.segs[i]:SetColorTexture(pr, pg, pb, 1)
      else f.segs[i]:SetColorTexture(0.2, 0.2, 0.25, 1) end
    end
    if n >= SHARD_MAX then
      f.text:SetText("shards = |cffffd100" .. n .. " (MAX)|r")
    else
      f.text:SetText("shards = " .. n)
    end
  end
end

local shardEvents = CreateFrame("Frame")
shardEvents:SetScript("OnEvent", updateShards)
local function shardEventsOn(on)
  if on then
    shardEvents:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
    shardEvents:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
    shardEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
    shardEvents:RegisterEvent("PLAYER_REGEN_DISABLED")
    shardEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
  else
    shardEvents:UnregisterAllEvents()
  end
end

ns.RegisterCommand("shards", "toggle a draggable Soul Shard bar (reports <secret> if unreadable in combat)", function()
  local f = buildShardFrame()
  if f:IsShown() then
    f:Hide(); shardEventsOn(false); ns.db.shardShown = false
    ns.Print("shard bar hidden")
  else
    f:Show(); shardEventsOn(true); ns.db.shardShown = true; updateShards()
    ns.Print("shard bar shown (drag to move). Pull a dummy and watch whether it flips to |cffff4040<secret>|r in combat.")
  end
end)

--------------------------------------------------------------------------------
-- On-demand secret probe
--------------------------------------------------------------------------------
-- Indexing a *secret table* throws, so guard with issecrettable + pcall.
local function secretTable(t)
  if type(issecrettable) == "function" then
    local ok, s = pcall(issecrettable, t)
    return ok and s
  end
  return false
end

local function cdFields(spellID, label)
  if not (C_Spell and C_Spell.GetSpellCooldown) then return end
  local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
  if not ok or type(info) ~= "table" then ns.Printf("  %s: <call failed>", label); return end
  if secretTable(info) then ns.Printf("  %s: |cffff4040<secret table>|r (cannot index in Lua)", label); return end
  local dur, start = "?", "?"
  pcall(function() dur = ns.Describe(info.duration); start = ns.Describe(info.startTime) end)
  ns.Printf("  %s: duration=%s startTime=%s", label, dur, start)
end

ns.RegisterCommand("secret", "test which values are secret RIGHT NOW (run once out of combat, once in combat)", function()
  ns.BeginCapture()
  ns.Heading(string.format("Secret probe  (in combat: %s)", tostring(InCombatLockdown())))
  if not ns.SecretAPI() then
    ns.Print("  issecretvalue() absent — Secret Values not present on this build; everything is readable.")
    ns.EndCapture("secret_" .. (InCombatLockdown() and "combat" or "ooc"))
    return
  end
  ns.Printf("  UnitPower(SoulShards): %s", ns.Describe(UnitPower("player", SOUL)))
  ns.Printf("  UnitPower(SoulShards, unmodified/fragments): %s", ns.Describe(UnitPower("player", SOUL, true)))
  cdFields(61304, "GCD (61304)")
  cdFields(105174, "Hand of Gul'dan (105174)")
  cdFields(265187, "Summon Demonic Tyrant (265187)")
  if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", "Demonic Core", "HELPFUL")
    if not ok or type(aura) ~= "table" then
      ns.Print("  Demonic Core aura: not active (proc it and re-run to test aura secrecy)")
    elseif secretTable(aura) then
      ns.Print("  Demonic Core aura: |cffff4040<secret table>|r (cannot index in Lua)")
    else
      local exp, apps = "?", "?"
      pcall(function() exp = ns.Describe(aura.expirationTime); apps = ns.Describe(aura.applications) end)
      ns.Printf("  Demonic Core aura: expirationTime=%s applications=%s", exp, apps)
    end
  end
  ns.EndCapture("secret_" .. (InCombatLockdown() and "combat" or "ooc"))
end)

--------------------------------------------------------------------------------
-- Event logger
--------------------------------------------------------------------------------
-- Quiet default: only the events that actually tell us something. GLOW show/hide
-- is the proc-detection test; COOLDOWN_VIEWER_DATA_LOADED marks a tracked-set
-- rebuild. The high-frequency SPELL_UPDATE_*/UNIT_AURA firehose is opt-in.
local QUIET_EVENTS = {
  "COOLDOWN_VIEWER_DATA_LOADED",
  "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW",
  "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
}
local VERBOSE_EVENTS = { "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES", "UNIT_AURA" }

local lastAt = {}
local function throttle(key, secs)
  local t = GetTime()
  if lastAt[key] and (t - lastAt[key]) < secs then return false end
  lastAt[key] = t
  return true
end

local logFrame = CreateFrame("Frame")
logFrame:SetScript("OnEvent", function(_, event, ...)
  if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
    local spellID = ...
    local verb = event:match("GLOW_(%a+)")
    ns.Printf("|cff66ccffGLOW %s|r %s (id=%s)", verb, ns.SpellName(spellID) or "?", tostring(spellID))
  elseif event == "COOLDOWN_VIEWER_DATA_LOADED" then
    ns.Print("|cffffd100COOLDOWN_VIEWER_DATA_LOADED|r — tracked-spell set (re)built")
  elseif event == "UNIT_AURA" then
    local unit = ...
    if unit == "player" and throttle("UNIT_AURA", 2.0) then ns.Print("|cff999999UNIT_AURA player|r (2s)") end
  elseif event == "SPELL_UPDATE_COOLDOWN" then
    if throttle("SPELL_UPDATE_COOLDOWN", 2.0) then ns.Print("|cff999999SPELL_UPDATE_COOLDOWN|r (2s)") end
  elseif event == "SPELL_UPDATE_CHARGES" then
    if throttle("SPELL_UPDATE_CHARGES", 2.0) then ns.Print("|cff999999SPELL_UPDATE_CHARGES|r (2s)") end
  end
end)

-- mode: "off" | "quiet" | "verbose"
local function logSet(mode)
  ns.db.logMode = mode
  logFrame:UnregisterAllEvents()
  if mode == "off" then ns.Print("event log |cffff8080OFF|r"); return end
  for _, e in ipairs(QUIET_EVENTS) do logFrame:RegisterEvent(e) end
  if mode == "verbose" then
    for _, e in ipairs(VERBOSE_EVENTS) do
      if e == "UNIT_AURA" then logFrame:RegisterUnitEvent("UNIT_AURA", "player")
      else logFrame:RegisterEvent(e) end
    end
  end
  ns.Printf("event log |cff88ff88%s|r — GLOW show/hide = proc detection%s",
    mode, mode == "verbose" and "; cd/charge/aura spam ON (2s throttle)" or " (glow + CDM-data only)")
end

ns.RegisterCommand("log", "toggle event logger; add 'verbose' for the cd/charge/aura firehose", function(rest)
  rest = (rest or ""):lower()
  if rest:find("verbose") then
    logSet(ns.db.logMode == "verbose" and "off" or "verbose")
  else
    logSet(ns.db.logMode == "quiet" and "off" or "quiet")
  end
end)

ns.RegisterCommand("reset", "turn every experiment off (unskin, hide shard bar, log off)", function()
  if ns.db.skinOn then ns.SetSkin(false) end
  if shardFrame and shardFrame:IsShown() then shardFrame:Hide(); shardEventsOn(false); ns.db.shardShown = false end
  if ns.db.logMode and ns.db.logMode ~= "off" then logSet("off") end
  ns.Print("all experiments off.")
end)

--------------------------------------------------------------------------------
-- Login restore (Core calls ns.OnLogin once, after saved vars are ready)
--------------------------------------------------------------------------------
function ns.OnLogin()
  if ns.RestoreSkin then ns.RestoreSkin() end
  if ns.db.logMode and ns.db.logMode ~= "off" then logSet(ns.db.logMode) end
  if ns.db.shardShown then
    local f = buildShardFrame()
    f:Show(); shardEventsOn(true); updateShards()
  end
end
