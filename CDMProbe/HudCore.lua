-- HudCore.lua — the HUD's registry, binding, lifecycle and slash commands.
--
-- M2's decision (notes.md §5): we never move the CDM and we ship no layout
-- string.  We bind to whatever layout is CURRENTLY ACTIVE, per item, keyed by
-- GetCooldownID().  Reorder-safety and missing-spell-skip come free from that —
-- we only ever iterate live frames.
--
-- Binding is driven by EVENTS ONLY (perf cleanup (a), notes.md §9 — the M1
-- prototype's 2 s backstop ticker is GONE):
--   * viewer:RefreshLayout   — relayout: tracked-set change, orientation/size
--                              change, aura full-update, show.  This is also
--                              where newly-pooled item frames appear, so the
--                              callback RE-BINDS and RE-ATTACHES chrome, which
--                              is precisely the job the ticker was papering over.
--   * COOLDOWN_VIEWER_DATA_LOADED — tracked-set rebuild without a relayout.
--   * PLAYER_ENTERING_WORLD       — login / zone-in, viewers freshly built.
-- `/cdmp hud status` prints the per-source fire counts so the in-game pass can
-- confirm the event path alone keeps chrome attached.  If something detaches,
-- the fix is another EVENT, not the ticker back (milestones "known risks").
local ADDON, ns = ...

ns.Hud = {
  on = false,
  hooked = false,
  items = {},        -- key -> { item, spellID, viewer, index }
  counts = {},       -- viewer frame name -> bound item count
  fires = { layout = 0, dataLoaded = 0, enterWorld = 0, binds = 0 },
  keyStats = { hits = 0, misses = 0 },
}
local M = ns.Hud

-- Icon viewers get chrome; buff viewers are registered so M3b can read proc
-- presence off item:IsShown(), but we draw nothing on them in M3a.
local ICON_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }
local BUFF_VIEWERS = { "BuffBarCooldownViewer", "BuffIconCooldownViewer" }
local ALL_VIEWERS  = { "EssentialCooldownViewer", "UtilityCooldownViewer",
                       "BuffBarCooldownViewer", "BuffIconCooldownViewer" }
-- `hud status` tags: the first four characters collide ("Buff"/"Buff"), which
-- made the two buff viewers indistinguishable in the readout.
local VIEWER_TAG = {
  EssentialCooldownViewer = "ESS ",
  UtilityCooldownViewer   = "UTIL",
  BuffBarCooldownViewer   = "BBAR",
  BuffIconCooldownViewer  = "BICO",
}

local function isIconViewer(name)
  return name == ICON_VIEWERS[1] or name == ICON_VIEWERS[2]
end

-- Settings --------------------------------------------------------------------
-- First real user settings land in M3c (the opener variant); M3a only needs the
-- on/off flag.  Defaults are filled defensively here as well as in Core.lua so a
-- db written by an older build picks up new keys.
local HUD_DEFAULTS = { on = false, opener = "1b" }

local function ensureDB()
  ns.db.hud = ns.db.hud or {}
  for k, v in pairs(HUD_DEFAULTS) do
    if ns.db.hud[k] == nil then ns.db.hud[k] = v end
  end
  return ns.db.hud
end

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

-- The binding key.  cooldownID is the stable per-tracked-spell identity across
-- relayouts and reorders (M2 decision); the frame-index fallback only matters
-- for a viewer whose items don't expose one, and is never treated as stable.
function ns.ItemCooldownID(item)
  if type(item.cooldownID) == "number" then return item.cooldownID end
  if ns.HasMethod(item, "GetCooldownID") then
    local ok, id = pcall(item.GetCooldownID, item)
    if ok and type(id) == "number" then return id end
  end
  return nil
end

local function bindViewer(name)
  local viewer = ns.GetViewer(name)
  M.counts[name] = 0
  if not viewer then return end
  local items = ns.GetItemFrames(viewer)
  for i, item in ipairs(items) do
    local ok = pcall(function()
      local cdID = ns.ItemCooldownID(item)
      local spellID = ns.ItemSpellID(item)
      local key = cdID and (name .. ":cd" .. cdID) or (name .. ":ix" .. i)
      M.items[key] = { item = item, spellID = spellID, viewer = name, index = i, cooldownID = cdID }
      if isIconViewer(name) then
        if ns.HudChrome.Attach(item, spellID) then
          M.keyStats.hits = M.keyStats.hits + 1
        else
          M.keyStats.misses = M.keyStats.misses + 1
        end
      end
    end)
    if ok then M.counts[name] = M.counts[name] + 1 end
  end
end

-- Rebuild the whole registry and re-attach chrome to every live item frame.
-- Cheap: a handful of frames, a table wipe, a few texture setters.
local function rebind()
  if not M.on then return end
  wipe(M.items)
  M.keyStats.hits, M.keyStats.misses = 0, 0
  M.fires.binds = M.fires.binds + 1
  for _, name in ipairs(ALL_VIEWERS) do bindViewer(name) end
  for _, name in ipairs(ICON_VIEWERS) do
    local v = ns.GetViewer(name)
    if v then ns.HudChrome.FlowScan(v) end
  end
  ns.HudChrome.ShowTerminal(ns.GetViewer(ICON_VIEWERS[1]))
end
M.Rebind = rebind

-- Cheap path for HudBinds: keybind text only, no re-registry.
function M.RefreshKeybinds()
  if not M.on then return end
  M.keyStats.hits, M.keyStats.misses = 0, 0
  for _, entry in pairs(M.items) do
    if isIconViewer(entry.viewer) then
      if ns.HudChrome.Attach(entry.item, entry.spellID) then
        M.keyStats.hits = M.keyStats.hits + 1
      else
        M.keyStats.misses = M.keyStats.misses + 1
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Event wiring
--------------------------------------------------------------------------------

-- hooksecurefunc can't be undone, so the callbacks are installed once and gated
-- on M.on.  If the viewers didn't exist yet, M.hooked stays false and the next
-- enable retries.
local function installHooks()
  if M.hooked then return end
  local any = false
  for _, name in ipairs(ALL_VIEWERS) do
    local v = ns.GetViewer(name)
    if v and ns.HasMethod(v, "RefreshLayout") then
      hooksecurefunc(v, "RefreshLayout", function()
        if not M.on then return end
        M.fires.layout = M.fires.layout + 1
        rebind()
      end)
      any = true
    end
  end
  M.hooked = any
end

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event)
  if not M.on then return end
  if event == "COOLDOWN_VIEWER_DATA_LOADED" then
    M.fires.dataLoaded = M.fires.dataLoaded + 1
  elseif event == "PLAYER_ENTERING_WORLD" then
    M.fires.enterWorld = M.fires.enterWorld + 1
    installHooks()          -- viewers may only now exist
  end
  rebind()
end)

--------------------------------------------------------------------------------
-- Enable / disable
--------------------------------------------------------------------------------
function ns.SetHud(on)
  local db = ensureDB()
  db.on = on and true or false
  M.on = db.on
  if M.on then
    -- The retired experiments write to item.Icon; don't fight them.
    if ns.db.skinOn and ns.SetSkin then ns.SetSkin(false) end
    if ns.db.resourceOn and ns.SetResource then ns.SetResource(false) end
    ns.HudBinds.Start()
    installHooks()
    ev:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    rebind()
    ns.Print("HUD |cff88ff88ON|r — native icons + group accents, keybinds, DEMO.SYS chrome. |cffffffff/cdmp hud status|r for the bind readout.")
  else
    M.on = false
    ev:UnregisterAllEvents()
    ns.HudBinds.Stop()
    ns.HudChrome.HideTerminal()
    for _, entry in pairs(M.items) do
      pcall(ns.HudChrome.Detach, entry.item)
    end
    for _, name in ipairs(ICON_VIEWERS) do
      local v = ns.GetViewer(name)
      if v then ns.HudChrome.HideScan(v) end
    end
    -- Our frames are hidden; ask Blizzard to repaint so the CDM is pixel-clean.
    for _, name in ipairs(ALL_VIEWERS) do
      local v = ns.GetViewer(name)
      if v and ns.HasMethod(v, "RefreshData") then pcall(v.RefreshData, v) end
    end
    wipe(M.items)
    ns.Print("HUD |cffff8080OFF|r — Blizzard's Cooldown Manager restored untouched.")
  end
end

--------------------------------------------------------------------------------
-- Status readout
--------------------------------------------------------------------------------
local function printStatus()
  local db = ensureDB()
  ns.Heading("HUD status — M3a (identity + chrome)")
  ns.Printf("  state: %s   opener setting: |cffffffff%s|r (M3c)", M.on and "|cff88ff88ON|r" or "|cffff8080OFF|r", tostring(db.opener))
  ns.Printf("  bind fires: RefreshLayout=%d  DATA_LOADED=%d  ENTERING_WORLD=%d  -> rebinds=%d  (|cffffd100no ticker running|r)",
    M.fires.layout, M.fires.dataLoaded, M.fires.enterWorld, M.fires.binds)
  ns.Printf("  hooks installed: %s", M.hooked and "|cff88ff88yes|r" or "|cffff4040no (viewers absent at install time)|r")
  for _, name in ipairs(ALL_VIEWERS) do
    ns.Printf("  |cffffd100%s|r — %d bound", name, M.counts[name] or 0)
  end
  ns.Printf("  keybinds: %d resolved / %d unbound   (cache: %d slot(s) with a spell, %d scan(s), %d coalesced, %d deferred to OOC%s)",
    M.keyStats.hits, M.keyStats.misses,
    ns.HudBinds.stats.slots, ns.HudBinds.stats.scans, ns.HudBinds.stats.coalesced,
    ns.HudBinds.stats.deferred,
    ns.HudBinds.dirty and ", |cffffd100dirty|r" or "")
  ns.Heading("  bound items")
  for _, name in ipairs(ALL_VIEWERS) do
    for _, e in pairs(M.items) do
      if e.viewer == name then
        local info, known = ns.SpecInfo(e.spellID)
        ns.Printf("   [%s] cd=%s id=%s %s  group=%s role=%s%s  key=%s",
          VIEWER_TAG[name] or name:sub(1, 4), tostring(e.cooldownID), ns.Describe(e.spellID),
          (e.spellID and ns.SpellName(e.spellID)) or "?",
          info.group, info.role, known and "" or " |cffffd100(not in ns.Spec — neutral)|r",
          ns.HudBinds.Get(e.spellID) or "|cff808080none|r")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
ns.RegisterCommand("hud",
  "the real spec HUD: native icons + group accents + keybinds + DEMO.SYS chrome. 'hud status' = bind readout.",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("status") then return printStatus() end
    ns.SetHud(not ensureDB().on)
  end)

-- Fold into /cdmp reset (wrap the chain Probes.lua + Resource.lua built).
local prevReset = ns.commands.reset and ns.commands.reset.fn
ns.RegisterCommand("reset", "turn every experiment off (unskin, hide bars/rail, resource + hud off, log off)", function(rest)
  if ns.db.hud and ns.db.hud.on then ns.SetHud(false) end
  if prevReset then prevReset(rest) end
end)

-- Restore on login (wrap the existing chain).
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  if ns.db and ns.db.hud and ns.db.hud.on then
    C_Timer.After(1.0, function() ns.SetHud(true) end)
  end
end
