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
  -- `ns.db.hud` is the pipeline HUD's enable BOOL.  No default entry: absent == off;
  -- HudDriver's OnLogin drops a stale TABLE-shaped value, and SetHud writes it after.
  -- `ns.db.hudSound` is the CUE SOUND's enable bool — one play per change of the cue set
  -- (HudDriver's onCueSetChanged).  ⚠ Unlike `hud` it DOES get a default, because it
  -- defaults ON: absent must mean "on", not "off", and only an entry can say that.
  -- `/cdmp hud sound off` is the one command that silences it — in a raid you want that
  -- to be a toggle, not a rebuild.
  hudSound = true,
  -- Pipeline decision log — a ring of recent sessions (count: DecisionLog.SESSIONS),
  -- each a list of one-line
  -- `S{…} G{…} B{…}` pipeline traces appended on every DECISION CHANGE (DecisionLog.lua).
  -- The greppable instrument for "why does /cdmp hud show nothing here?"; extracted to a
  -- flat .log by `wowkb.cdmp decisionlog`.  Structured, flushed on /reload.
  decisionlog = {},
  -- TEMPORARY — the CDM alert-channel discovery tape.  Off unless `/cdmp alerts on`
  -- (`alerttape_on`).  Its end date and what it is for: AlertTape.lua's header.
  alerttape = {},
  -- TEMPORARY — the C_AssistedCombat readability ring (`/cdmp assist watch`, off unless
  -- `assist_on`).  One row per readability-CLASS change; deleted with Assist.lua once the
  -- "does GetNextCastSpell survive combat" answer lands in the KB.
  assist = {},
  -- The ACCEPTANCE RECORDER's ring (`/cdmp flight`).  One row per change of ANSWER SHAPE
  -- across a whole in-game pass; read by `wowkb.cdmp flight`, which turns it into a
  -- PASS/FAIL report.  Wiped on every arm — a flight is one session.
  flight = {},
  -- The `/cdmp rt fx` CAPTURE — one sample per view change, recording what is ACTUALLY on
  -- each cue (the cue layer's scale, the ring's period/direction/alpha, the echo's) plus
  -- the knob state that produced it.  Read by `wowkb.cdmp rtfx`.  Exists because dialling
  -- a visual by copy-pasting a screenful of chat per rung costs more than the judgement —
  -- the same complaint that turned the acceptance pass into `/cdmp flight`.  Bounded ring.
  rtfx = {},
  -- The moveable virtual-icon panel's saved point (HudVirtual.lua, `/cdmp panel`):
  -- `{ point, relPoint, x, y }`.  The EMPTY table means "no saved position" — RestorePosition
  -- detects that via the absent `point` and falls back to the default anchor, exactly as
  -- BucketBinds' console does.  It gets a default entry because it is table-valued.
  virtualPanel = {},
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

-- The render test mode.  Registered here (like the other top-level commands) but
-- implemented in RenderTest.lua (ns.RenderTest), which owns the placeholder-frame rig +
-- the hand-authored DrawList fixtures.  The thin wrapper guards the load order:
-- RenderTest.lua loads after Core, so resolve ns.RenderTest at DISPATCH time, not
-- registration time.
ns.RegisterCommand("rt",
  "render test: draw a DrawList fixture (states | list | rotate | fx | off)",
  function(rest)
    if ns.RenderTest then ns.RenderTest(rest)
    else ns.Print("RenderTest not loaded") end
  end)

-- ⚠ TEMPORARY, rides with the `rt fx` sound experiment and is deleted with it.  A pure
-- ergonomics alias: `/cdmp rt fx sound sweep` is 24 characters to advance ONE of 235
-- candidates, which makes the audition cost more than the judgement.  Macro-friendly.
ns.RegisterCommand("sweep",
  "audition the next loud cue sound (alias for `rt fx sound sweep`)",
  function(rest)
    if ns.RenderTest then ns.RenderTest("fx sound sweep " .. (rest or ""))
    else ns.Print("RenderTest not loaded") end
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
