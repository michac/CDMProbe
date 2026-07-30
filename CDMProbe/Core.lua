-- CDMProbe — experimental Cooldown Manager probe / kitchen sink.
-- Bootstrap: namespace, saved vars, chat helpers, command registry, slash cmds.
-- License: MIT (see repo LICENSE). ECM (GPL-3.0) was read for API discovery only;
-- no code copied — the shared surface (Blizzard frame/field names, hook idioms)
-- is API fact, not expression.
local ADDON, ns = ...

ns.name = ADDON
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "?"

-- Saved-variable defaults -----------------------------------------------------
-- The probe (`reports` / `probe` stores) was retired 2026-07-29; the decision log
-- is the addon's only recorder now.  Stale `reports`/`probe`/`logMode`/… keys in an
-- existing CDMProbeDB are harmless — nothing reads them — so there is no migration.
local DEFAULTS = {
  -- `ns.db.hud` is the pipeline HUD's enable BOOL (W4 cutover reclaimed the key from
  -- the old engine's settings TABLE).  No default entry: absent == off; HudDriver's
  -- OnLogin migrates any stale old-engine table / prior `hud2` bool into it, and
  -- SetHud writes it thereafter.
  -- Pipeline decision log — a ring of the last 3 sessions, each a list of one-line
  -- `S{…} G{…} B{…}` pipeline traces appended on every DECISION CHANGE (DecisionLog.lua).
  -- The greppable instrument for "why does /cdmp hud show nothing here?"; extracted to a
  -- flat .log by `wowkb.cdmp decisionlog`.  Structured, flushed on /reload.
  -- (A prior `hud2log` store is folded in one-shot on login — see HudDriver.OnLogin.)
  decisionlog = {},
  -- TEMPORARY (AlertTape.lua) — a discovery tape for the CDM alert channel, answering
  -- whether PandemicTime / ChargeGained / OnAura* fire in combat and whether the pandemic
  -- fields are readable there.  Off unless `/cdmp alerts on` (`alerttape_on`).  **Delete
  -- this key, AlertTape.lua and its .toc line once those rules are settled in
  -- knowledge/addon-dev/api-events-and-discovery.md §2.8** — it is deliberately not a
  -- permanent instrument.
  alerttape = {},
}

-- Chat helpers ----------------------------------------------------------------
local PREFIX = "|cff8788eeCDMProbe|r "
-- Secret-safe: a Secret Value must never be indexed/formatted (that taints).
local function secret(v)
  if type(issecretvalue) == "function" then
    local ok, s = pcall(issecretvalue, v)
    return ok and s
  end
  return false
end
function ns.Print(msg)
  local disp = secret(msg) and "<secret>" or tostring(msg)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. disp)
end
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
  ns.Print("the HUD is the point: |cffffffff/cdmp hud|r to toggle it, |cffffffff/cdmp hud status|r for the pipeline readout.")
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

-- W4 Phase 3 — the Renderer test mode.  Registered here (like the other top-level
-- commands) but implemented in Renderer.lua (ns.RenderTest), which owns the
-- placeholder-frame rig + the hand-authored DrawList fixtures.  The thin wrapper
-- guards the load order: Renderer.lua loads after Core, so resolve ns.RenderTest
-- at DISPATCH time, not registration time.
ns.RegisterCommand("rendertest",
  "Phase-3 draw test: render a DrawList fixture (inventory | rotate | list | off)",
  function(rest)
    if ns.RenderTest then ns.RenderTest(rest)
    else ns.Print("Renderer not loaded") end
  end)

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
