-- CDMProbe — experimental Cooldown Manager probe / kitchen sink.
-- Bootstrap: namespace, saved vars, chat helpers, command registry, slash cmds.
-- License: MIT (see repo LICENSE). ECM (GPL-3.0) was read for API discovery only;
-- no code copied — the shared surface (Blizzard frame/field names, hook idioms)
-- is API fact, not expression.
local ADDON, ns = ...

ns.name = ADDON
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "?"

-- Saved-variable defaults -----------------------------------------------------
local DEFAULTS = {
  skinOn = false,
  logOn = false,
  shardShown = false,
  shardFrame = { point = "CENTER", x = 0, y = -140 },
}

-- Chat helpers ----------------------------------------------------------------
local PREFIX = "|cff8788eeCDMProbe|r "
function ns.Print(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg)) end
function ns.Printf(fmt, ...) ns.Print(string.format(fmt, ...)) end
function ns.Heading(t) ns.Print("|cffffd100" .. tostring(t) .. "|r") end

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
  ns.Print("suggested run at a target dummy: |cffffffffdump|r (out of combat) -> |cffffffffskin|r -> |cffffffffshards|r -> pull, then |cffffffffsecret|r again in combat.")
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
