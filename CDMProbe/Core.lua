-- CDMProbe — experimental Cooldown Manager probe / kitchen sink.
-- Bootstrap: namespace, saved vars, chat helpers, command registry, slash cmds.
-- License: MIT (see repo LICENSE). ECM (GPL-3.0) was read for API discovery only;
-- no code copied — the shared surface (Blizzard frame/field names, hook idioms)
-- is API fact, not expression.
local ADDON, ns = ...

ns.name = ADDON
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "?"

-- Saved-variable defaults -----------------------------------------------------
-- `logMode` / `shardShown` / `shardFrame` were dropped in v0.12.0 with the
-- commands that owned them (see Probe.lua's header).  Stale keys in an existing
-- CDMProbeDB are harmless — nothing reads them — so there is no migration.
local DEFAULTS = {
  skinOn = false,
  -- The real HUD's settings (HudCore fills missing sub-keys defensively too, so
  -- a db written by an older build picks up keys added later).
  hud = { on = false, opener = "1b" },
  reports = {},          -- persisted `/cdmp probe` output, read off disk
}

-- Chat helpers ----------------------------------------------------------------
-- Print also tees a color-stripped copy into an optional capture buffer, so a
-- command can persist its whole (untruncated) output to SavedVariables for
-- off-disk reading — chat scrollback/paste eats the most important lines.
local PREFIX = "|cff8788eeCDMProbe|r "
-- Secret-safe: a Secret Value must never be indexed/formatted (that taints).
local function secret(v)
  if type(issecretvalue) == "function" then
    local ok, s = pcall(issecretvalue, v)
    return ok and s
  end
  return false
end
local function strip(s)
  if secret(s) then return "<secret>" end
  return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
function ns.Print(msg)
  local disp = secret(msg) and "<secret>" or tostring(msg)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. disp)
  if ns._cap then ns._cap[#ns._cap + 1] = strip(msg) end
end
function ns.Printf(fmt, ...) ns.Print(string.format(fmt, ...)) end
function ns.Heading(t) ns.Print("|cffffd100" .. tostring(t) .. "|r") end

-- Capture: buffer every Print, then store the joined text under reports[key].
-- Keyed by combat state so out-of-combat and in-combat runs don't clobber.
function ns.BeginCapture() ns._cap = {} end
function ns.EndCapture(key)
  if not ns._cap then return end
  ns.db.reports = ns.db.reports or {}
  ns.db.reports[key] = table.concat(ns._cap, "\n")
  ns.db.reports[key .. "_combat"] = InCombatLockdown() and true or false
  ns._cap = nil
  ns.Printf("saved report '%s' — |cffffffff/reload|r then read SavedVariables/CDMProbe.lua", key)
end

-- Command registry ------------------------------------------------------------
ns.commands = {}       -- name -> { fn = function(argString), help = string }
ns.commandOrder = {}
function ns.RegisterCommand(name, help, fn)
  if not ns.commands[name] then ns.commandOrder[#ns.commandOrder + 1] = name end
  ns.commands[name] = { fn = fn, help = help }
end

local function printHelp()
  ns.Heading("CDMProbe — /cdmp <command>")
  for _, name in ipairs(ns.commandOrder) do
    ns.Printf("  |cff88ff88%s|r — %s", name, ns.commands[name].help)
  end
  ns.Print("suggested run: |cffffffffprobe|r (out of combat) -> pull a dummy -> |cffffffffprobe|r again in combat -> |cffffffff/reload|r, then the reports are on disk.")
end

local function dispatch(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = cmd and cmd:lower() or ""
  if cmd == "" or cmd == "help" then return printHelp() end
  local entry = ns.commands[cmd]
  if not entry then
    ns.Printf("unknown command '%s' — try |cffffffff/cdmp help|r", cmd)
    return
  end
  local ok, err = pcall(entry.fn, rest)
  if not ok then ns.Printf("|cffff4040error in '%s':|r %s", cmd, tostring(err)) end
end

SLASH_CDMPROBE1 = "/cdmp"
SLASH_CDMPROBE2 = "/cdmprobe"
SlashCmdList["CDMPROBE"] = dispatch

-- Bootstrap -------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    CDMProbeDB = CDMProbeDB or {}
    for k, v in pairs(DEFAULTS) do
      if CDMProbeDB[k] == nil then
        CDMProbeDB[k] = (type(v) == "table") and CopyTable(v) or v
      end
    end
    ns.db = CDMProbeDB
  elseif event == "PLAYER_LOGIN" then
    ns.Printf("v%s loaded. |cffffffff/cdmp help|r — kitchen-sink probe for the Cooldown Manager.", ns.version)
    if ns.OnLogin then ns.OnLogin() end
  end
end)
