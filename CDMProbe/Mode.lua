-- Mode.lua — the single/AoE target-mode toggle, extracted from the retired HudCore
-- (W4 cutover) so the feature survives the old engine's deletion.  A bool + setter +
-- 3 macro-friendly commands, nothing more.
--
-- WHO READS IT.  State forwards `ns.Mode.aoe` as its generic `mode` ("st"|"aoe")
-- field; the Coach copies it but does not branch on it yet (Demo is a passive-cleave
-- spec — no dot changes).  The feature is live and ready for a future AoE-aware rule
-- or a second spec; it is deliberately kept vestigial rather than dropped.
local ADDON, ns = ...

ns.Mode = ns.Mode or {}
local M = ns.Mode
M.aoe = false

function M.SetAoE(on)
  M.aoe = on and true or false
end

-- Manual single/AoE toggle — MACRO-FRIENDLY, on purpose.  `/cdmp single` and
-- `/cdmp multi` are idempotent setters (bind each to a button, or put both in one
-- /click macro), and `/cdmp aoe` bare-toggles for a single key.  Setting a flag is
-- not a protected action, so these run fine mid-combat.
local function reportAoE()
  ns.Printf("target mode: %s  |cff808080(no Demo dot changes yet — Demo is a passive-cleave spec; scaffolding for a 2nd spec / talent rule)|r",
    M.aoe and "|cffbef264MULTI (AoE)|r" or "|cff88ccffSINGLE|r")
end
ns.RegisterCommand("single", "target mode: SINGLE-target (suppresses Implosion). Macro-friendly.", function()
  M.SetAoE(false); reportAoE()
end)
ns.RegisterCommand("multi", "target mode: MULTI-target / AoE (offers Implosion). Macro-friendly.", function()
  M.SetAoE(true); reportAoE()
end)
ns.RegisterCommand("aoe", "toggle target mode single<->multi (bare toggle for a one-key macro)", function(rest)
  rest = (rest or ""):lower()
  if rest:find("on") or rest:find("multi") then M.SetAoE(true)
  elseif rest:find("off") or rest:find("single") then M.SetAoE(false)
  else M.SetAoE(not M.aoe) end
  reportAoE()
end)
