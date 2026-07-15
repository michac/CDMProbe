-- Viewers.lua — locate the Cooldown Manager viewer frames, enumerate their item
-- frames, resolve each item's spellID, and dump the whole live API surface.
local ADDON, ns = ...

ns.VIEWERS = {
  { key = "essential", frame = "EssentialCooldownViewer", label = "Essential" },
  { key = "utility",   frame = "UtilityCooldownViewer",   label = "Utility"   },
  { key = "bufficon",  frame = "BuffIconCooldownViewer",  label = "Buff (icon)" },
  { key = "buffbar",   frame = "BuffBarCooldownViewer",   label = "Buff (bar)"  },
}

-- Item frames known to hold these sub-parts (per Blizzard's CooldownViewerItem).
local ITEM_FIELDS = {
  "Icon", "IconOverlay", "IconMask", "Cooldown", "Count", "ChargeCount",
  "CooldownFlash", "OutOfRange", "Name", "Bar", "StatusBar", "isActive",
}

function ns.GetViewer(frameName)
  return _G[frameName]
end

-- Returns (itemFrames, howResolved).  Prefers the documented GetItemFrames()
-- method; falls back to filtering GetChildren() for item-looking frames.
function ns.GetItemFrames(viewer)
  if ns.HasMethod(viewer, "GetItemFrames") then
    local ok, frames = pcall(viewer.GetItemFrames, viewer)
    if ok and type(frames) == "table" then return frames, "GetItemFrames()" end
  end
  local out = {}
  if ns.HasMethod(viewer, "GetChildren") then
    for _, c in ipairs({ viewer:GetChildren() }) do
      if type(c) == "table" and (c.Cooldown or c.Icon or ns.HasMethod(c, "GetCooldownID")) then
        out[#out + 1] = c
      end
    end
  end
  return out, "GetChildren() filtered"
end

-- Returns (spellID, sourceLabel).  Tries several strategies since the exact
-- item->spell accessor is not fully documented for 12.0.
function ns.ItemSpellID(item)
  if ns.HasMethod(item, "GetSpellID") then
    local ok, id = pcall(item.GetSpellID, item)
    if ok and type(id) == "number" then return id, "item:GetSpellID()" end
  end
  local cdID = item.cooldownID
  if not cdID and ns.HasMethod(item, "GetCooldownID") then
    local ok, id = pcall(item.GetCooldownID, item)
    if ok and type(id) == "number" then cdID = id end
  end
  if cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
    if ok and type(info) == "table" and info.spellID then
      return info.spellID, "C_CooldownViewer(" .. tostring(cdID) .. ").spellID"
    end
  end
  if type(item.spellID) == "number" then return item.spellID, "item.spellID" end
  return nil, "unresolved"
end

ns.RegisterCommand("dump", "introspect viewers, items, spellIDs, item anatomy + which APIs exist", function()
  ns.BeginCapture()
  ns.Heading("Environment")
  ns.Printf("  in combat: %s   |   Secret Values API (issecretvalue): %s",
    tostring(InCombatLockdown()), tostring(ns.SecretAPI()))
  ns.Printf("  canaccessvalue: %s   issecrettable: %s   C_Secrets: %s",
    tostring(type(canaccessvalue) == "function"),
    tostring(type(issecrettable) == "function"),
    tostring(C_Secrets ~= nil))

  ns.Heading("C_CooldownViewer")
  if C_CooldownViewer then
    local fns = {}
    for k, v in pairs(C_CooldownViewer) do if type(v) == "function" then fns[#fns + 1] = k end end
    table.sort(fns)
    ns.Printf("  %s", #fns > 0 and table.concat(fns, ", ") or "(present, no functions enumerable)")
  else
    ns.Print("  |cffff4040absent|r")
  end

  for _, vinfo in ipairs(ns.VIEWERS) do
    local viewer = ns.GetViewer(vinfo.frame)
    ns.Heading(string.format("%s  (%s)", vinfo.label, vinfo.frame))
    if not viewer then
      ns.Print("  |cffff4040frame not found|r (viewer not enabled for this spec/config?)")
    else
      local shown = ns.HasMethod(viewer, "IsShown") and viewer:IsShown()
      ns.Printf("  shown: %s   GetItemFrames(): %s", tostring(shown), tostring(ns.HasMethod(viewer, "GetItemFrames")))
      local items, how = ns.GetItemFrames(viewer)
      ns.Printf("  %d item(s) via %s", #items, how)
      for i, item in ipairs(items) do
        local id, src = ns.ItemSpellID(item)
        local name = (id and ns.SpellName(id)) or "?"
        local present = {}
        for _, f in ipairs(ITEM_FIELDS) do if item[f] ~= nil then present[#present + 1] = f end end
        local vis = ns.HasMethod(item, "IsShown") and item:IsShown()
        ns.Printf("   [%d] |cffffffff%s|r  id=%s (%s)  shown=%s  {%s}",
          i, name, tostring(id), src, tostring(vis), table.concat(present, ", "))
      end
    end
  end
  ns.Print("tip: run |cffffffff/cdmp dump|r again while in combat on a dummy — compare what turns |cffff4040<secret>|r.")
  ns.EndCapture("dump_" .. (InCombatLockdown() and "combat" or "ooc"))
end)
