-- Util.lua — color, spell-name, method probing, and Secret-Values-aware describe.
local ADDON, ns = ...

-- HSV -> RGB.  h in [0,360), s,v in [0,1].
function ns.HSV(h, s, v)
  h = h % 360
  local c = v * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, b
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

-- The bundled monospace, and the ONE place a font is applied.
--
-- `SetFont` returns FALSE when the .ttf can't load, and a FontString whose font
-- failed to set draws NOTHING.  So an unguarded call is not "falls back to
-- something ugly", it is "the text silently disappears" — which for the imp
-- count (§7.2 item 3) would hide the readout rather than degrade it.  HudRow had
-- this guard; HudChrome's stack path did not.  Hence one helper, two callers.
--
-- Returns true if the bundled font took, false if we fell back — callers that
-- care about metrics (anything relying on monospaced digit advance) can check.
ns.FONT_MONO = "Interface\\AddOns\\CDMProbe\\Media\\JetBrainsMono.ttf"

function ns.SetFont(obj, size, flags)
  if not (obj and obj.SetFont) then return false end
  if obj:SetFont(ns.FONT_MONO, size, flags) then return true end
  obj:SetFont("Fonts\\ARIALN.TTF", size, flags)
  return false
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

-- True if t is a Secret TABLE — a distinct verdict from ns.IsSecret on a field.
-- Both were OBSERVED by the v0.12.0 probe (`<secret table>` and `<secret
-- fields>` are separate lines in Section A), which is why every reader has to
-- ask both questions: a secret table cannot be indexed at all, while a readable
-- table can still hand back secret members.
function ns.IsSecretTable(t)
  if type(issecrettable) ~= "function" then return false end
  local ok, s = pcall(issecrettable, t)
  return ok and s or false
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

-- STASHABLE form of an observed value — the ONE guard for "this is about to be
-- written to SavedVariables".  A Secret Value must never reach disk (serializing
-- one writes garbage at best and taints the writer at worst), so a secret degrades
-- to the STRING "<secret>" — which is itself the finding a reader wants ("this read
-- secret here") — and anything not a scalar drops to nil rather than persisting a
-- live frame/table reference.
--
-- This is Probe.lua's file-local `stash` promoted to a shared helper (M4.5 T3 / W4
-- Phase 1): State stamps event payloads (`ns.Stash(base)`, transform from/to) that may
-- end up serialized, and needs the exact same secret-never-reaches-disk discipline the
-- probe snapshot has.  One idiom, one home.  (Probe.lua keeps its own copy for now; do not chase that
-- de-dupe here — it is a behavioural no-op and this file must stay low-risk.)
function ns.Stash(v)
  if ns.IsSecret(v) then return "<secret>" end
  local t = type(v)
  if t == "number" or t == "boolean" or t == "string" then return v end
  return nil
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

--------------------------------------------------------------------------------
-- ns.ReadCooldown — the ONE door for "what does the client say about this
-- cooldown right now"  (M3d D1)
--------------------------------------------------------------------------------
-- THIS IS READING, NOT GUESSING, and the distinction is the whole milestone.
-- The M3b doctrine — readiness comes only from an OBSERVED EDGE, we refuse to
-- infer a secret — stands unchanged INSIDE COMBAT.  The seam is the combat
-- boundary, and it was MEASURED, not assumed: the v0.12.0 probe (Probe.lua
-- Section A) read C_Spell.GetSpellCooldown on all 13 tracked spells in two
-- contexts and got 13/13 readable OUT OF COMBAT, 0/13 IN COMBAT.  Open-world
-- both runs, so the gate is COMBAT, not instancing.  And the residual worry —
-- that duration=0 everywhere meant a "not on cooldown" constant rather than a
-- real value — was closed by a genuine mid-cooldown read:
--
--     Summon Demonic Tyrant        duration=60 startTime=126156.254
--
-- startTime is in GetTime() units, so startTime + duration - GetTime() seeds
-- readiness AND the countdown directly.
--
-- Returns (ready, remaining, duration, startTime), or NIL when unreadable.
-- `nil` is the load-bearing return: an unreadable read is NOT evidence of
-- anything, and every caller must leave the state it had alone rather than
-- overwrite it with a shrug.
local GCD_SPELLID = 61304   -- the global cooldown, as a spell (Probe.lua:155)

-- The raw guarded read, shared by the spell and the GCD paths.  Guards in
-- order, because each is a DIFFERENT failure: the call itself -> a secret table
-- (cannot be indexed) -> secret fields on a readable table.
local function rawCooldown(spellID)
  if not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
  local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
  if not ok or type(info) ~= "table" then return nil end
  if ns.IsSecretTable(info) then return nil end
  local d, st
  -- Indexing is itself pcall'd: a table that passes issecrettable can still
  -- throw on access under the 12.0 restrictions, and this runs from rebind(),
  -- which is a hooksecurefunc callback inside Blizzard's layout path.
  if not pcall(function() d, st = info.duration, info.startTime end) then return nil end
  if ns.IsSecret(d) or ns.IsSecret(st) then return nil end
  if type(d) ~= "number" or type(st) ~= "number" then return nil end
  return d, st
end

-- Charges, guarded.  For a CHARGED ability GetSpellCooldown reports the
-- RECHARGE of the next charge, so an ability with a charge banked would seed as
-- on-cooldown.  A banked charge means PRESSABLE, whatever the recharge says.
-- No tracked Demo ability has charges today, so this is pre-emptive — but it is
-- a one-line miss that would look exactly like "seeding just doesn't work on
-- that button", which is the failure mode this project keeps re-learning.
local function readCharges(spellID)
  if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
  local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
  if not ok or type(info) ~= "table" then return nil end
  if ns.IsSecretTable(info) then return nil end
  local c
  if not pcall(function() c = info.currentCharges or info.charges end) then return nil end
  if ns.IsSecret(c) or type(c) ~= "number" then return nil end
  return c
end

-- ns.ReadCharges — live (current, max) charges for a spellID, guarded, or nil.
-- The public door over the same secret-aware read `rawCooldown` uses internally,
-- exposed for State (W4 Phase 1): a charged ability's readiness is "a charge
-- banked", not "the recharge timer", and State reports both so the Coach can
-- decide.  Same discipline as every read here — a secret or an unreadable table
-- returns nil ("we don't know"), never a poisoned number.  Combat-gated like
-- ns.ReadCooldown: GetSpellCharges reads secret in restricted combat.
function ns.ReadCharges(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  if InCombatLockdown() then return nil end
  if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
  local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
  if not ok or type(info) ~= "table" then return nil end
  if ns.IsSecretTable(info) then return nil end
  local cur, max
  if not pcall(function()
    cur = info.currentCharges or info.charges
    max = info.maxCharges
  end) then return nil end
  if ns.IsSecret(cur) or ns.IsSecret(max) then return nil end
  if type(cur) ~= "number" or type(max) ~= "number" then return nil end
  return cur, max
end

function ns.ReadCooldown(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  -- Short-circuited HERE as well as at the call site, because a caller added
  -- later will not remember the rule.  The guards above would refuse a combat
  -- read anyway, but silently burning 13 pcalls per rebind mid-fight is not
  -- free — and a caller that got `nil` for the wrong reason would look like the
  -- feature is broken rather than out of scope.
  if InCombatLockdown() then return nil end

  local duration, startTime = rawCooldown(spellID)
  if duration == nil then return nil end

  local charges = readCharges(spellID)
  if charges and charges > 0 then return true, 0, duration, startTime end

  -- ⚠ THE GCD TRAP — load-bearing.  GetSpellCooldown reports the GLOBAL
  -- COOLDOWN for a spell that is genuinely ready, so a naive `duration > 0`
  -- reads EVERY ability as on-cooldown for 1.5s after any cast.  Resolved
  -- against the LIVE GCD rather than a magic number: a (startTime, duration)
  -- pair matching the GCD's own is the GCD, not this spell's cooldown.
  local gDur, gStart = rawCooldown(GCD_SPELLID)
  if gDur and gDur > 0 then
    if duration == gDur and startTime == gStart then
      return true, 0, duration, startTime
    end
  elseif duration > 0 and duration <= 1.5 then
    -- Backstop for when the GCD read itself is unavailable.  1.5s is the
    -- unhasted global; a real cooldown that short is not something we track.
    return true, 0, duration, startTime
  end

  if duration <= 0 then return true, 0, duration, startTime end
  local remaining = startTime + duration - GetTime()
  if remaining <= 0 then return true, 0, duration, startTime end
  return false, remaining, duration, startTime
end

-- Power cost for a spell, as the CLIENT reports it for THIS character's build.
-- Returns (cost, powerTypeName) or nil.
--
-- `powerType` (an Enum.PowerType value) FILTERS to one resource.  Passing it is
-- not optional politeness — see the defect note below.  Omit it only when you
-- genuinely want "whatever this costs", which nothing in the HUD does.
--
-- Deliberately read at runtime rather than authored into SpecDemonology: costs
-- are TALENT-DEPENDENT (Demonic Calling makes Dreadstalkers free; the Grimoire
-- and Tyrant costs move with the build), so any number hardcoded in the spec
-- table is correct for exactly one loadout and silently wrong for every other.
-- The client already knows the answer for the character actually logged in.
--
-- ⚠ THE v0.10.0 DEFECT (fixed here, §7.2 item 1).  This returned the first
-- non-zero cost of ANY power type, and most of the tracked set costs MANA.  So
-- Demonbolt's 5000-mana cost became "shards 3<500" (via the fragment heuristic
-- below) and was compared against a shard count that maxes at 5 — a gate that can
-- never open, which is why Demonbolt could never be recommended and why Mortal
-- Coil talked about shards at all.  Hand of Gul'dan "worked" only because the
-- client happened to list its shard cost first.  Read that again before removing
-- the filter: an UNFILTERED cost is not a slightly-worse answer, it is a
-- different resource silently wearing the right units.
--
-- Units caveat: Soul Shards are reported in FRAGMENTS in some places (10 per
-- shard) and whole shards in others, so the raw value is surfaced as-is rather
-- than divided by a guess.  The in-game readout settles it.
function ns.PowerCost(spellID, powerType)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  if not (C_Spell and C_Spell.GetSpellPowerCost) then return nil end
  local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellID)
  if not ok or type(costs) ~= "table" then return nil end
  for _, c in ipairs(costs) do
    if type(c) == "table" and not ns.IsSecret(c.cost) and type(c.cost) == "number" then
      -- `c.type` is guarded like every other read: an unreadable type can't be
      -- matched against the filter, so it's skipped rather than assumed to be
      -- the resource we asked for.
      local typeOK = true
      if powerType ~= nil then
        typeOK = (not ns.IsSecret(c.type)) and c.type == powerType
      end
      if typeOK and c.cost > 0 then
        local name = c.name
        if type(name) ~= "string" then name = "power" .. tostring(c.type) end
        return c.cost, name
      end
    end
  end
  -- 0 = "no cost in the resource we asked about".  NOTE this still reports
  -- "genuinely free" and "unreadable" identically — HudScore's gated branch
  -- guards that ambiguity explicitly and must keep doing so.
  return 0, nil
end

-- The SAME cost, normalised to WHOLE SOUL SHARDS so it can be compared against
-- UnitPower(player, SoulShards) — which reports 0..5.
--
-- This is the load-bearing half of the units caveat above.  M3c-a's gate rule is
-- `shards >= cost`, so a cost still expressed in FRAGMENTS (10 per shard) would
-- make every gate unreachable and every dot permanently dark.  The shard cap is
-- 5, so any reported cost that is a clean multiple of 10 can only be fragments —
-- there is no ability that costs ten shards.  Anything else is passed through
-- untouched rather than divided by a guess.
--
-- Returns (shardCost, rawCost).
--
-- ⚠ The fragment heuristic below is STILL UNPROVEN against a real shard cost.  Until
-- v0.10.0 it only ever saw MANA figures, where it "worked" — 5000 -> 500 — and manufactured
-- the defect's signature numbers.  Now that the type filter means it only sees shards, the
-- decision log's `PW:` field is the read that confirms or falsifies it.  @verify-ingame
-- (`/cdmp hud debug`, which used to print both columns, was retired at the W4 cutover.)
function ns.ShardCost(spellID)
  -- No Enum -> no way to ask about the right resource, and an UNFILTERED read is
  -- exactly the defect.  Report "unreadable" instead, which the scorer already
  -- handles honestly (it caps at AVAILABLE and says "shards unreadable").
  local pt = Enum and Enum.PowerType and Enum.PowerType.SoulShards
  if pt == nil then return nil, nil end
  local raw = ns.PowerCost(spellID, pt)
  if raw == nil then return nil, nil end
  if raw >= 10 and raw % 10 == 0 then return raw / 10, raw end
  return raw, raw
end

--------------------------------------------------------------------------------
-- ns.DisplayIdentity — the ONE rule for "which spell is this CDM row actually
-- showing?", shared by every producer that keys on a spell.
--------------------------------------------------------------------------------
-- A Cooldown Manager row's own spellID is not always the spell it DRAWS.  Destruction's
-- cid 66181 is Shadow Bolt 686 with its display overridden to Incinerate 29722, and on
-- DIABOLIST (where 686 reads isKnown) that is the row Blizzard puts on screen.  Every
-- consumer that keyed on the raw base therefore disagreed with what the player saw:
--   * State keyed `abilities[686]`, so the Coach's `facts[29722]` was nil and the
--     Incinerate line could never win  (0 wins in 225 Diabolist decisions, 2026-07-30);
--   * HudLayout published `spellID = 686`, so the Binder's cue join (`cues[entry.spellID]`)
--     missed, AND the keybind was looked up for Shadow Bolt — which is not on the bars.
-- Both symptoms are one cause, so the rule lives in ONE place and both producers call it.
--
-- ⚠ USE THE STATIC OVERRIDES, NEVER `liveSpellID`.  `liveSpellID` moves to Infernal Bolt
-- 433891 while the Demonic Art is armed, so keying on it would make Incinerate's identity
-- VANISH mid-combat — exactly when the ability is most active.  `overrideSpellID` /
-- `overrideTooltipSpellID` carry the displayed id throughout.  (Same reasoning as State's
-- `displayedIdentities` fence, which unions both fields for the same reason.)
--
-- Adopting an override is DELIBERATELY conservative — it must be a real, pressable
-- ability of the active spec:
--   * declared in the spec table   — an id we have no opinion about is not an identity;
--   * `kind == "button"`           — an aura row is an input, never a press;
--   * `expect ~= false`            — the transforms (Ruination / Infernal Bolt) and the
--                                    cast-id aliases declare they never own an icon.  A
--                                    transform must never become the identity of the frame
--                                    it merely rides.
-- Anything short of all three falls back to `base`, which is today's behaviour — so a spec
-- with no display-overridden rows is completely unaffected.
function ns.DisplayIdentity(base, overrideSpellID, overrideTooltipSpellID)
  if type(base) ~= "number" then return base end
  local shown = overrideSpellID
  if type(shown) ~= "number" or ns.IsSecret(shown) then shown = overrideTooltipSpellID end
  if type(shown) ~= "number" or ns.IsSecret(shown) or shown == base then return base end
  -- ⚠ NOT a banned nil guard.  ns.SpecInfo is a REBOUND global — SpecRegistry copies it off
  -- the active spec and leaves it nil on an unregistered spec (the passive path), so this is
  -- a STATE test, not a "did someone delete the definition" test.  Passive ⇒ no opinion about
  -- any id ⇒ the raw base is the honest identity.
  if type(ns.SpecInfo) ~= "function" then return base end
  local info, declared = ns.SpecInfo(shown)
  if not declared or type(info) ~= "table" then return base end
  if info.kind ~= "button" or info.expect == false then return base end
  return shown
end
