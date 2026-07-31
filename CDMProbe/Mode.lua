-- Mode.lua — the single/AoE target-mode toggle.  A bool + setter + 3 macro-friendly
-- commands, nothing more.
--
-- WHO READS IT.  State forwards `ns.Mode.aoe` as its generic `mode` ("st"|"aoe") field
-- and the Coach passes it to the active spec brain as `ctx.mode`.  WHAT a mode gates is
-- the spec table's business, and it differs per spec — so this file names no spell.
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
  ns.Printf("target mode: %s  |cff808080(what it gates is per-spec — a spec brain may ignore it entirely)|r",
    M.aoe and "|cffbef264MULTI (AoE)|r" or "|cff88ccffSINGLE|r")
end
ns.RegisterCommand("single", "target mode: SINGLE-target. Macro-friendly.", function()
  M.SetAoE(false); reportAoE()
end)
ns.RegisterCommand("multi", "target mode: MULTI-target / AoE. Macro-friendly.", function()
  M.SetAoE(true); reportAoE()
end)
ns.RegisterCommand("aoe", "toggle target mode single<->multi (bare toggle for a one-key macro)", function(rest)
  rest = (rest or ""):lower()
  if rest:find("on") or rest:find("multi") then M.SetAoE(true)
  elseif rest:find("off") or rest:find("single") then M.SetAoE(false)
  else M.SetAoE(not M.aoe) end
  reportAoE()
end)
