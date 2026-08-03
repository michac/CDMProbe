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
-- count would hide the readout rather than degrade it.  Hence one helper, and every
-- caller goes through it.
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

-- True if t is a Secret TABLE — a distinct verdict from ns.IsSecret on a field, and
-- both were OBSERVED, which is why every reader has to ask both questions: a secret
-- table cannot be indexed at all, while a readable table can still hand back secret
-- members.
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
-- cooldown right now"
--------------------------------------------------------------------------------
-- THIS IS READING, NOT GUESSING.  The doctrine — readiness comes only from an
-- OBSERVED EDGE, we refuse to infer a secret — stands unchanged INSIDE COMBAT.  The
-- seam is the combat boundary, and it was MEASURED, not assumed: C_Spell.GetSpellCooldown
-- across all 13 tracked spells read 13/13 OUT OF COMBAT and 0/13 IN COMBAT, open-world
-- both runs, so the gate is COMBAT, not instancing.  And the residual worry — that
-- duration=0 everywhere meant a "not on cooldown" constant rather than a real value —
-- was closed by a genuine mid-cooldown read:
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
local GCD_SPELLID = 61304   -- the global cooldown, as a spell

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

-- ns.ReadCharges — live (current, max, recharge) charges for a spellID, guarded, or nil.
-- The public door over the same secret-aware read `rawCooldown` uses internally,
-- exposed for State (W4 Phase 1): a charged ability's readiness is "a charge
-- banked", not "the recharge timer", and State reports both so the Coach can
-- decide.  Same discipline as every read here — a secret or an unreadable table
-- returns nil ("we don't know"), never a poisoned number.  Combat-gated like
-- ns.ReadCooldown: GetSpellCharges reads secret in restricted combat.
--
-- THE THIRD RETURN, `recharge`, is `cooldownDuration` — how long ONE charge takes to come
-- back.  Added 2026-07-31 for the charge napkin's GAIN FLOOR (see State.lua's chargeGain):
-- it is the only number that says how fast charges *can* arrive, and there is no fallback
-- for it.  A charged spell's cooldown lives on its CHARGE CATEGORY, not the spell —
-- Conflagrate 17962 is `RecoveryTime = 0` / `ChargeCategory = 672` [DB2 @ 12.0.7] — so
-- `GetSpellBaseCooldown` yields nothing to count down from.  This OOC read is it.
--
-- ⚠ It is 0 (not nil) at full charges, because nothing is recharging.  Callers must treat
-- "0" as "no measurement this time" and keep the last positive one, NOT overwrite with 0.
function ns.ReadCharges(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  if InCombatLockdown() then return nil end
  if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
  local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
  if not ok or type(info) ~= "table" then return nil end
  if ns.IsSecretTable(info) then return nil end
  local cur, max, recharge
  if not pcall(function()
    cur = info.currentCharges or info.charges
    max = info.maxCharges
    recharge = info.cooldownDuration
  end) then return nil end
  if ns.IsSecret(cur) or ns.IsSecret(max) then return nil end
  if type(cur) ~= "number" or type(max) ~= "number" then return nil end
  -- `recharge` is BEST-EFFORT and must never cost us the count: a secret or absent
  -- duration drops to nil and the caller simply keeps whatever floor it already had.
  if ns.IsSecret(recharge) or type(recharge) ~= "number" or recharge <= 0 then
    recharge = nil
  end
  return cur, max, recharge
end

--------------------------------------------------------------------------------
-- THE CLASS-RESOURCE CHANNEL (2026-08-02) — two guarded readers for the resources
-- `Enum.PowerType` does not have.
--------------------------------------------------------------------------------
-- WHY THIS EXISTS.  `state.power` iterates `Enum.PowerType` and reports every power the
-- character actually has.  That is complete for Fury (17) and Holy Power (9) — and it can
-- NEVER carry Demon Hunter Soul Fragments, because there is no `SoulFragments` member to
-- iterate.  `PowerBarColor["SOUL_FRAGMENTS"]` exists, but it only colours a StatusBar.
--
-- oUF — which is what actually draws these bars in the wild — calls them CLASS POWERS with
-- negative pseudo-IDs, commented verbatim `-- these are not real class powers`
-- [T1 src: ElvUI_Libraries/Game/Shared/oUF/elements/classpower.lua:70-77].  They are
-- bespoke per-spec reads the UI SYNTHESIZES from an ordinary spell API.  So a spec that
-- wants one has to ask for it explicitly, which is what `spec.derived` (State.lua) does and
-- what these two readers serve.
--
-- ⚠ NO `InCombatLockdown()` GATE, AND THAT IS DELIBERATE — do not copy it down from
-- `ns.ReadCharges` above.  That fence is there because `C_Spell.GetSpellCharges` was
-- MEASURED secret in restricted combat; it is a record of a measurement, not a house style.
-- These two APIs have not been measured, and gating them pre-emptively would make the
-- measurement impossible: every in-combat read would return nil for a reason we chose
-- rather than one the client imposed.  The rest of the ladder is identical, so an actually
-- secret return degrades honestly instead of tainting.  If either turns out to be secret in
-- combat, ADD the gate then and cite the capture — the way ReadCharges does.
--
-- Both return nil for "we could not ask", NEVER 0.  Zero is a real answer ("you have none")
-- and a refusal must never impersonate one — the same absent-never-zero rule the exact power
-- rail follows.

-- ns.ReadCastCount(spellID) -> count | nil
--
-- `C_Spell.GetSpellCastCount` is how oUF reads VENGEANCE's Soul Fragments (Soul Cleave
-- 228477) [classpower.lua:265-300], and it is not an obscure corner: it is Blizzard's OWN
-- `ChargeCount` fallback inside the Cooldown Viewer
-- [T1 src: Blizzard_CooldownViewer/CooldownViewer.lua:1009] — the very channel
-- knowledge/addon-dev/api-events-and-discovery.md §2 filed as an unmeasured lead ("an
-- ability icon *can* raise ChargeGained off GetSpellCastCount without having real charges").
-- This addon has never called it.  That standing `@verify-ingame` closes the first time a
-- Vengeance character flies a build carrying this.
function ns.ReadCastCount(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  if not (C_Spell and C_Spell.GetSpellCastCount) then return nil end
  local ok, count = pcall(C_Spell.GetSpellCastCount, spellID)
  if not ok or ns.IsSecret(count) or type(count) ~= "number" then return nil end
  return count
end

-- ns.ReadAuraApplications(spellID) -> applications | nil
--
-- The DEVOURER read: Soul Fragments are aura STACKS there, on Dark Heart (1225789) or —
-- inside Void Metamorphosis — Silence the Whispers (1227702).  Blizzard's own bar does
-- exactly this [T1 src: Blizzard_UnitFrame/DemonHunterSoulFragmentsBar.lua:150-177], which
-- is the Tier-1 corroboration for oUF's version of it.
--
-- ⚠ THE KB PREDICTS THIS ONE REFUSES IN COMBAT, and the prediction is specific enough to
-- act on: `knowledge/addon-dev/cooldown-manager.md:517` records that the ENTIRE `AuraData`
-- record is secret when restricted — *"including `GetPlayerAuraBySpellID`. Your own auras
-- are as sealed as the target's."*  That is a measured, general fact about the API, not a
-- guess about these two spells, and it is the reason `state.buffs` reads PRESENCE off item
-- frames rather than asking `C_UnitAuras` directly.
--
-- It is written anyway, and without the combat gate, for two reasons.  It is CORRECT AND
-- USEFUL out of combat (the opener's starting stack count, and the `/cdmp hud coverage`
-- style desk check), and leaving the gate off is what turns a prediction into a
-- MEASUREMENT — the ladder already makes a secret return safe.  A brain must therefore
-- treat this as an OPTIONAL enrichment and never gate a rotation line on it; see
-- specs/devourer/observability-map.md for the degradation.
function ns.ReadAuraApplications(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
  local ok, info = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
  if not ok or type(info) ~= "table" then return nil end
  if ns.IsSecretTable(info) then return nil end
  -- Indexing is itself pcall'd: a table that passes `issecrettable` can still throw on
  -- access under the 12.0 restrictions (the same shape rawCooldown guards against).
  local n
  if not pcall(function() n = info.applications end) then return nil end
  if ns.IsSecret(n) or type(n) ~= "number" then return nil end
  return n
end

-- ns.ReadMaxAuraApplications(spellID) -> max | nil
--
-- The MAX half of the read above, and a genuinely different API: `C_Spell` rather than
-- `C_UnitAuras`, and spell DATA rather than unit state — so it has no reason to share the
-- aura record's secrecy.  Blizzard's Devourer bar resolves its cap through exactly this
-- [DemonHunterSoulFragmentsBar.lua:167-177].
function ns.ReadMaxAuraApplications(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return nil end
  if not (C_Spell and C_Spell.GetSpellMaxCumulativeAuraApplications) then return nil end
  local ok, n = pcall(C_Spell.GetSpellMaxCumulativeAuraApplications, spellID)
  if not ok or ns.IsSecret(n) or type(n) ~= "number" or n <= 0 then return nil end
  return n
end

-- ns.ReadGCD — the global cooldown's own (duration, startTime), read ONCE.
--
-- It is one global fact per instant, but `ns.ReadCooldown` used to resolve it inside
-- itself, so it was re-read for EVERY enumerated entry — ~64 identical guarded reads per
-- tick at 10 Hz.  Callers that enumerate hoist this out of their loop and pass it down.
--
-- ⚠ COMBAT-GATED, exactly like the read it feeds.  The short-circuit used to live INSIDE
-- ns.ReadCooldown (below), so hoisting the read without hoisting the gate would have
-- started burning a guarded call per pulse in combat, where it can only ever refuse.
function ns.ReadGCD()
  if InCombatLockdown() then return nil end
  return rawCooldown(GCD_SPELLID)
end

-- `gcd` is the OPTIONAL hoisted GCD read: `{ duration, startTime }` from ns.ReadGCD, or
-- nil to resolve it here as before.  Passing it is what makes the trap below cost one read
-- per pulse instead of one per entry.
function ns.ReadCooldown(spellID, gcd)
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
  local gDur, gStart
  if gcd ~= nil then gDur, gStart = gcd[1], gcd[2] else gDur, gStart = rawCooldown(GCD_SPELLID) end
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

-- ns.AlertEventName(v) -> "PandemicTime" | "?<v>"
--
-- The `Enum.CooldownViewerAlertEventType` value -> name map, built LAZILY on first use
-- (the enum is not populated at file-load time) and cached thereafter.  Exists so a
-- readout says "PandemicTime" rather than "2".
--
-- ⚠ NEVER PASS A SECRET.  `tostring` on a Secret Value taints the string it lands in, and
-- an alert-type member CAN read secret in combat.  Every caller asks `ns.IsSecret` first
-- and renders "SECRET" instead — the same rule `ns.ReadValidAlertTypes` states below.
--
-- Promoted out of `AlertTape.lua` (Phase 4 housekeeping), for the same reason
-- `ReadValidAlertTypes` was promoted in Phase 3: that file is a temporary discovery
-- instrument scheduled for deletion, and the coverage report is built on this.  AlertTape
-- calls this copy — there is exactly one map.
local ALERT_EVENT_NAME

function ns.AlertEventName(v)
  if not ALERT_EVENT_NAME then
    ALERT_EVENT_NAME = {}
    local A = Enum and Enum.CooldownViewerAlertEventType
    if type(A) == "table" then
      for name, value in pairs(A) do
        if type(value) == "number" and type(name) == "string" then
          ALERT_EVENT_NAME[value] = name
        end
      end
    end
  end
  return ALERT_EVENT_NAME[v] or ("?" .. tostring(v))
end

-- ns.ReadValidAlertTypes(cooldownID) -> list | nil, err
--
-- Which alert types a tracked cooldown can raise, via the public
-- `C_CooldownViewer.GetValidAlertTypes`.  Same shape as the guarded-read ladder above:
-- capability check, then a pcall, then a type check — a refusal is `nil` plus a REASON,
-- never an empty list dressed as an answer (an empty list is a real, different answer:
-- "this row raises nothing").  Members are returned RAW; a caller that wants to print one
-- must run it through `ns.IsSecret` itself, because a member can read secret in combat.
--
-- ⚠ THE API UNDER-REPORTS, SO THIS IS A LOWER BOUND.  The 2026-07-31 capture caught a row
-- raising an `OnAuraApplied` it did not list.  Any consumer must therefore phrase its
-- output as "not reported eligible", NEVER as "cannot fire" — the difference is the whole
-- value of the Phase-4 coverage report, which is about finding roster ids the CDM tracks
-- nowhere, not about proving a negative on one that it does.
--
-- Promoted out of `AlertTape.lua` (Phase 3 housekeeping): that file is a temporary
-- discovery instrument scheduled for deletion, and Phase 4 is built on this call.
function ns.ReadValidAlertTypes(cooldownID)
  if type(cooldownID) ~= "number" or ns.IsSecret(cooldownID) then
    return nil, "unreadable cooldownID"
  end
  if not (C_CooldownViewer and C_CooldownViewer.GetValidAlertTypes) then
    return nil, "C_CooldownViewer.GetValidAlertTypes absent"
  end
  local ok, types = pcall(C_CooldownViewer.GetValidAlertTypes, cooldownID)
  if not ok then return nil, "GetValidAlertTypes raised" end
  if type(types) ~= "table" or ns.IsSecretTable(types) then return nil, "unreadable" end
  return types
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
-- ⚠ THE v0.10.0 DEFECT (fixed here).  This returned the first
-- non-zero cost of ANY power type, and most of the tracked set costs MANA.  So
-- Demonbolt's 5000-mana cost became "shards 3<500" (via the fragment heuristic
-- below) and was compared against a shard count that maxes at 5 — a gate that can
-- never open, which is why Demonbolt could never be recommended and why Mortal
-- Coil talked about shards at all.  Hand of Gul'dan "worked" only because the
-- client happened to list its shard cost first.  Read that again before removing
-- the filter: an UNFILTERED cost is not a slightly-worse answer, it is a
-- different resource silently wearing the right units.
--
-- ✅ UNITS, SETTLED IN GAME 2026-08-01.  `C_Spell.GetSpellPowerCost` PRE-APPLIES the
-- display divisor: Chaos Bolt is stored as 20 fragments in DB2 and the client hands back
-- **2**.  So this returns WHOLE SHARDS for a Soul Shard cost, always — the old "might be
-- fragments" caveat is closed, and ns.ShardCost below is now a pass-through.
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
  -- 0 = "no cost in the resource we asked about".  ⚠ This still reports "genuinely
  -- free" and "unreadable" identically, so a caller gating on cost must guard the
  -- ambiguity itself rather than reading 0 as a fact.
  return 0, nil
end

-- The same cost, FILTERED TO SOUL SHARDS.  Returns (shardCost, rawCost) — the same number
-- twice, because the client already reports it in whole shards (0..5, the rail
-- `UnitPower(player, SoulShards)` reports).  ⚠ The NAME says shards and it means it: a
-- consumer working in FRAGMENTS must multiply by the power's `modifier` itself, at exactly
-- one place, and rename what it holds (Phase 6.2 — both brains do this in their Context).
--
-- ⚠ THE FRAGMENT HEURISTIC IS DELETED, NOT GENERALISED (Phase 6.2).  It read
-- `if raw >= 10 and raw % 10 == 0 then return raw / 10`, and the in-game measurement that
-- settled the units showed it can never legitimately fire: a Soul Shard cost of ten or more
-- is impossible against a five-shard cap, so the branch could only ever have corrupted a
-- correct answer.  It survived as long as it did because until v0.10.0 it only saw MANA
-- figures (5000 -> 500), where it manufactured the defect's signature numbers; the type
-- filter below then starved it, and it has not fired since.  Its `@verify-ingame` marker
-- went with it — it pointed at the decision log, which could never have answered the
-- question anyway (a raw 3 and a raw 30 both render `3`).
--
-- THE TYPE FILTER STAYS, and is the load-bearing part — see ns.PowerCost's v0.10.0 banner.
function ns.ShardCost(spellID)
  -- No Enum -> no way to ask about the right resource, and an UNFILTERED read is
  -- exactly the defect.  Report "unreadable" instead, which the scorer already
  -- handles honestly (it caps at AVAILABLE and says "shards unreadable").
  local pt = Enum and Enum.PowerType and Enum.PowerType.SoulShards
  if pt == nil then return nil, nil end
  local raw = ns.PowerCost(spellID, pt)
  if raw == nil then return nil, nil end
  return raw, raw
end

-- ns.DisplayIdentity — "which spell is this CDM row actually showing?" — lives in
-- Viewers.lua with the rest of the item-identity resolvers.  It reads ns.SpecInfo, and
-- this file is the bottom of the stack (loaded 3rd, before the spec registry exists).
