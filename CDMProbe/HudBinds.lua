-- HudBinds.lua — action-bar scan -> keybind string per spellID (cached).
--
-- Identity chrome, deliberately OUTSIDE the §0.5.8 indicator contract: a keybind
-- is not a rotation signal, it's how you know which icon is which button.
--
-- Cost control (milestones "known risks"): the 180-slot scan is CACHED and only
-- ever runs OUT OF COMBAT.  Anything that could invalidate it (bindings changed,
-- a slot's contents changed, spec swap, bar page flip) marks the cache dirty; the
-- rescan is deferred to PLAYER_REGEN_ENABLED if we're in combat.  Nothing here
-- runs on a hot path.
--
-- Unbound spell -> nil -> blank text.  Never a placeholder (a fake keybind is
-- worse than no keybind).
local ADDON, ns = ...

ns.HudBinds = {}
local B = ns.HudBinds

-- slot range -> binding command prefix.  Slots 13-24 are page 2 of bar 1 and
-- slots 109-180 are the extra pages: they have no bindings of their own, so they
-- are simply absent from this table and resolve to nil.
local SLOT_BARS = {
  { first = 1,   last = 12,  cmd = "ACTIONBUTTON%d" },
  { first = 25,  last = 36,  cmd = "MULTIACTIONBAR3BUTTON%d" },  -- right bar
  { first = 37,  last = 48,  cmd = "MULTIACTIONBAR4BUTTON%d" },  -- right bar 2
  { first = 49,  last = 60,  cmd = "MULTIACTIONBAR2BUTTON%d" },  -- bottom right
  { first = 61,  last = 72,  cmd = "MULTIACTIONBAR1BUTTON%d" },  -- bottom left
  { first = 73,  last = 84,  cmd = "MULTIACTIONBAR5BUTTON%d" },
  { first = 85,  last = 96,  cmd = "MULTIACTIONBAR6BUTTON%d" },
  { first = 97,  last = 108, cmd = "MULTIACTIONBAR7BUTTON%d" },
}

local function bindingCommand(slot)
  for _, bar in ipairs(SLOT_BARS) do
    if slot >= bar.first and slot <= bar.last then
      return string.format(bar.cmd, slot - bar.first + 1)
    end
  end
  return nil
end

-- "SHIFT-BUTTON3" -> "sM3".  Terminal chrome is ~10px in a ~28px column, so the
-- string has to be tiny; modifiers become single lowercase letters.
local KEY_SHORT = {
  ["BUTTON1"] = "M1", ["BUTTON2"] = "M2", ["BUTTON3"] = "M3", ["BUTTON4"] = "M4",
  ["BUTTON5"] = "M5", ["MOUSEWHEELUP"] = "MU", ["MOUSEWHEELDOWN"] = "MD",
  ["NUMPADPLUS"] = "N+", ["NUMPADMINUS"] = "N-", ["NUMPADMULTIPLY"] = "N*",
  ["NUMPADDIVIDE"] = "N/", ["NUMPADDECIMAL"] = "N.",
  ["SPACE"] = "SP", ["ESCAPE"] = "ESC", ["INSERT"] = "INS", ["DELETE"] = "DEL",
  ["HOME"] = "HM", ["END"] = "END", ["PAGEUP"] = "PU", ["PAGEDOWN"] = "PD",
  ["BACKSPACE"] = "BS", ["TAB"] = "TB", ["CAPSLOCK"] = "CL",
}

local function shorten(key)
  if type(key) ~= "string" or key == "" then return nil end
  local mods = ""
  local rest = key
  while true do
    local m, tail = rest:match("^(%u+)%-(.+)$")
    if m == "SHIFT" then mods = mods .. "s"; rest = tail
    elseif m == "CTRL" then mods = mods .. "c"; rest = tail
    elseif m == "ALT" then mods = mods .. "a"; rest = tail
    else break end
  end
  local short = KEY_SHORT[rest]
  if not short then
    short = rest:gsub("^NUMPAD", "N")
    if #short > 3 then short = short:sub(1, 3) end
  end
  return mods .. short
end

-- Cache ------------------------------------------------------------------------
B.map = {}        -- spellID -> short key string
B.dirty = true
B.stats = { slots = 0, bound = 0, scans = 0, deferred = 0 }

local function scan()
  wipe(B.map)
  B.stats.slots, B.stats.bound = 0, 0
  for slot = 1, 180 do
    local actionType, id = GetActionInfo(slot)
    local spellID
    if actionType == "spell" then
      spellID = tonumber(id)
    elseif actionType == "macro" then
      spellID = GetMacroSpell and GetMacroSpell(id) or nil
    end
    if spellID then
      B.stats.slots = B.stats.slots + 1
      -- First bound slot wins: a spell on several bars keeps the binding of the
      -- lowest-numbered one (bar 1 before the multibars), which is the one the
      -- player thinks of as "the" key.
      if not B.map[spellID] then
        local cmd = bindingCommand(slot)
        local key = cmd and GetBindingKey(cmd)
        local short = key and shorten(key)
        if short then
          B.map[spellID] = short
          B.stats.bound = B.stats.bound + 1
        end
      end
    end
  end
  B.dirty = false
  B.stats.scans = B.stats.scans + 1
end

-- Rescan now if it's safe, otherwise leave the cache dirty and let
-- PLAYER_REGEN_ENABLED pick it up.  Never scans in combat.
local function refresh()
  if InCombatLockdown() then
    B.dirty = true
    B.stats.deferred = B.stats.deferred + 1
    return false
  end
  scan()
  return true
end

function B.Invalidate()
  B.dirty = true
  refresh()
end

-- The read path: cheap, cache-only.  If the cache is dirty we serve the stale
-- value rather than scanning — the refresh will land out of combat and the
-- chrome re-reads on the next relayout.
function B.Get(spellID)
  -- Never index with a Secret Value (that taints); an unreadable ID is simply
  -- an unbound one as far as the chrome is concerned.
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  return B.map[spellID]
end

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_REGEN_ENABLED" then
    if B.dirty then
      scan()
      if ns.Hud and ns.Hud.RefreshKeybinds then ns.Hud.RefreshKeybinds() end
    end
    return
  end
  B.dirty = true
  if refresh() and ns.Hud and ns.Hud.RefreshKeybinds then ns.Hud.RefreshKeybinds() end
end)

function B.Start()
  ev:RegisterEvent("UPDATE_BINDINGS")
  ev:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
  ev:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
  ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
  ev:RegisterEvent("PLAYER_REGEN_ENABLED")
  refresh()
end

function B.Stop()
  ev:UnregisterAllEvents()
end
