-- Util.lua — color, spell-name, method probing, and Secret-Values-aware describe.
local ADDON, ns = ...

-- HSV -> RGB.  h in [0,360), s,v in [0,1].
function ns.HSV(h, s, v)
  h = h % 360
  local c = v * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, b = 0, 0, 0
  if h < 60 then r, g, b = c, x, 0
  elseif h < 120 then r, g, b = x, c, 0
  elseif h < 180 then r, g, b = 0, c, x
  elseif h < 240 then r, g, b = 0, x, c
  elseif h < 300 then r, g, b = x, 0, c
  else r, g, b = c, 0, x end
  return r + m, g + m, b + m
end

-- A stable, well-spread color for a given spellID (identity color, no icon).
function ns.IdColor(id)
  id = tonumber(id) or 0
  local hue = (id * 47) % 360     -- 47 is coprime-ish with 360 -> good spread
  return ns.HSV(hue, 0.62, 0.95)
end

-- Modern spell-name lookup, best effort.
function ns.SpellName(spellID)
  if not spellID then return nil end
  if C_Spell and C_Spell.GetSpellName then
    local ok, n = pcall(C_Spell.GetSpellName, spellID)
    if ok and n then return n end
  end
  return nil
end

function ns.HasMethod(obj, name)
  return type(obj) == "table" and type(obj[name]) == "function"
end

-- Is the 12.0 Secret Values API present?
function ns.SecretAPI()
  return type(issecretvalue) == "function"
end

-- True if v is a Secret Value (guarded; false when the API is absent).
function ns.IsSecret(v)
  if not ns.SecretAPI() then return false end
  local ok, secret = pcall(issecretvalue, v)
  return ok and secret or false
end

-- Human string for a value, flagging Secret Values in red.  Never compares a
-- secret (that would error/taint) — it only asks issecretvalue().
function ns.Describe(v)
  if ns.IsSecret(v) then return "|cffff4040<secret>|r" end
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v)
  elseif t == "string" then return '"' .. v .. '"'
  elseif t == "nil" then return "nil"
  else return "<" .. t .. ">" end
end

-- Base cooldown in SECONDS for a spellID, or nil if unreadable.  Static spell
-- metadata, not live cooldown state — readable and branchable (notes.md §1);
-- the *remaining* time is the secret, the base length is not.
--
-- 0 is a MEANINGFUL answer, not a failure: Hand of Gul'dan and Demonbolt have no
-- cooldown at all, so they never fire a cooldown alert edge and "readiness" is
-- simply the wrong frame for them — their gate is shards / a proc.
function ns.BaseCooldown(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  local ms
  if C_Spell and C_Spell.GetSpellBaseCooldown then
    local ok, v = pcall(C_Spell.GetSpellBaseCooldown, spellID)
    if ok and type(v) == "number" then ms = v end
  end
  if ms == nil and type(GetSpellBaseCooldown) == "function" then
    local ok, v = pcall(GetSpellBaseCooldown, spellID)
    if ok and type(v) == "number" then ms = v end
  end
  if ms == nil then return nil end
  return math.floor(ms / 1000 + 0.5)
end

-- Power cost for a spell, as the CLIENT reports it for THIS character's build.
-- Returns (cost, powerTypeName) or nil.
--
-- Deliberately read at runtime rather than authored into SpecDemonology: costs
-- are TALENT-DEPENDENT (Demonic Calling makes Dreadstalkers free; the Grimoire
-- and Tyrant costs move with the build), so any number hardcoded in the spec
-- table is correct for exactly one loadout and silently wrong for every other.
-- The client already knows the answer for the character actually logged in.
--
-- Units caveat: Soul Shards are reported in FRAGMENTS in some places (10 per
-- shard) and whole shards in others, so the raw value is surfaced as-is rather
-- than divided by a guess.  The in-game readout settles it.
function ns.PowerCost(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  if not (C_Spell and C_Spell.GetSpellPowerCost) then return nil end
  local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellID)
  if not ok or type(costs) ~= "table" then return nil end
  for _, c in ipairs(costs) do
    if type(c) == "table" and not ns.IsSecret(c.cost) and type(c.cost) == "number" then
      if c.cost > 0 then
        local name = c.name
        if type(name) ~= "string" then name = "power" .. tostring(c.type) end
        return c.cost, name
      end
    end
  end
  return 0, nil
end
