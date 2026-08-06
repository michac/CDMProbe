-- Dump registrations — what buttons the panel offers.
--
-- Mechanism is DumpPanel.lua; this file is only content. Each `capture` reads a data
-- accessor and returns plain-text lines — no chat, no colour escapes.
--
-- Loads last: every accessor it touches must already exist.

local ADDON, ns = ...

local D = ns.Dumps
local Safe = ns.Capture.Safe

local function name(spellID)
  return (spellID and ns.SpellName and ns.SpellName(spellID)) or "?"
end

D.Register{
  id = "layout",
  label = "HUD layout",
  blurb = function()
    local layout = ns.HudLayout and ns.HudLayout.Scan()
    local n = 0
    for _ in pairs(layout or {}) do n = n + 1 end
    return ("layout · %d icons"):format(n)
  end,
  capture = function()
    local layout, registry = ns.HudLayout.Scan()
    local cds = (ns.State.Build(false) or {}).cooldowns or {}
    local out = { "# HUD layout — cooldownID -> spellID + State keybind" }
    local ids = {}
    for cid in pairs(layout or {}) do ids[#ids + 1] = cid end
    table.sort(ids)
    if #ids == 0 then
      out[#out + 1] = "  (no icons — are the Cooldown Manager viewers enabled?)"
      return out
    end
    for _, cid in ipairs(ids) do
      local e = layout[cid]
      out[#out + 1] = ("  cd=%d spellID=%s (%s) key=%s frame=%s"):format(
        cid, Safe(e.spellID), name(e.spellID),
        Safe(cds[cid] and cds[cid].keybind), Safe(registry and registry[cid]))
    end
    return out
  end,
}

D.Register{
  id = "coverage",
  label = "Roster coverage",
  blurb = function()
    local rep = ns.Coverage and ns.Coverage.Get()
    if not rep or not rep.ok then return ("coverage · %s"):format((rep and rep.reason) or "n/a") end
    local blind = 0
    for _, e in ipairs(rep.entries or {}) do
      if e.verdict ~= "ok" then blind = blind + 1 end
    end
    return ("coverage · %d blind"):format(blind)
  end,
  capture = function()
    local rep = ns.Coverage.Get()
    local out = { "# Roster coverage — declared ids vs what the CDM tracks" }
    if not rep.ok then
      -- An empty scan is a refused read, not a blind roster, so there is no per-id table.
      out[#out + 1] = ("  no report: %s"):format(Safe(rep.reason))
      return out
    end
    for _, e in ipairs(rep.entries or {}) do
      out[#out + 1] = ("  %-9s %-7s %s%s"):format(
        Safe(e.verdict), Safe(e.spellID), name(e.spellID),
        e.known == false and "  (not talented)" or
        (e.known == nil and "  (knownness unreadable)" or ""))
    end
    return out
  end,
}
