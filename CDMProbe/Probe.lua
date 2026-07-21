-- Probe.lua — THE probe.  One command, one report, written to disk.
--
-- WHY THIS REPLACED SIX COMMANDS (2026-07-21).  `dump` / `secret` / `casts` /
-- `log` / `layout` / `shards` each answered one question and each needed the
-- player to remember to toggle it BEFORE the thing happened.  That is the wrong
-- shape: the interesting events (a proc, a transform, a cast reading secret) are
-- exactly the ones you can't schedule.  So:
--
--   * EVERYTHING PASSIVE IS ALWAYS RECORDING, from load, at near-zero cost —
--     counters and small ring buffers, no per-frame work, no printing.
--   * `/cdmp probe` renders the whole picture at once and CAPTURES IT TO
--     SavedVariables, so findings are read off disk instead of screenshotted.
--
-- READING THE REPORT (the loop this is built for):
--   1. `/cdmp probe`            out of combat
--   2. pull something, then     `/cdmp probe`  again in combat
--   3. `/reload`                <- SavedVariables are only FLUSHED on reload/logout
--   4. reports live in  …/_retail_/WTF/Account/<ACCT>/SavedVariables/CDMProbe.lua
--      under CDMProbeDB.reports["probe_ooc"] / ["probe_combat"].
-- Step 3 is not optional and is the one people forget: without a reload the file
-- on disk still holds the PREVIOUS session's text, which looks exactly like a
-- probe that silently did nothing.
local ADDON, ns = ...

ns.Probe = {}
local P = ns.Probe

--------------------------------------------------------------------------------
-- Passive recorders
--------------------------------------------------------------------------------
-- Everything here is counters + a short ring buffer.  No prints (the old `casts`
-- and `log` commands spammed chat, which is why they were off by default and
-- therefore off when it mattered).

local RING = 12          -- keep the last N of each interesting thing

P.casts = {              -- §7.2 item 7 / §7: is the spellID readable, PER PHASE?
  START = { readable = 0, secret = 0 },
  SUCCEEDED = { readable = 0, secret = 0 },
  STOP = { readable = 0, secret = 0 },
  INTERRUPTED = { readable = 0, secret = 0 },
}
P.overrides = {}         -- ring: base -> override pairs actually observed
P.overrideCount = 0
P.glow = { show = 0, hide = 0 }
P.dataLoaded = 0
P.lastCasts = {}         -- ring: recent readable cast spellIDs, for eyeballing

local function push(t, v)
  t[#t + 1] = v
  while #t > RING do table.remove(t, 1) end
end

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "COOLDOWN_VIEWER_DATA_LOADED" then
    P.dataLoaded = P.dataLoaded + 1
  elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
    P.glow.show = P.glow.show + 1
  elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
    P.glow.hide = P.glow.hide + 1
  elseif event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
    -- §7.2 item 6 + V1(c).  Every pass so far has reported `spell-override
    -- events: 0`, but HudState only listens while the HUD is ON — so "never
    -- observed" may only ever have meant "never watched".  This listens from
    -- load, unconditionally, and records the PAIRS: that is both the proof the
    -- channel works and the raw data for adding the transformed IDs to
    -- SpecDemonology (the Grimoire-becomes-a-pet-command case).
    P.overrideCount = P.overrideCount + 1
    local base = (type(a1) == "number" and not ns.IsSecret(a1)) and a1 or nil
    local over = (type(a2) == "number" and not ns.IsSecret(a2)) and a2 or nil
    push(P.overrides, { base = base, over = over, at = GetTime() })
  elseif a1 == "player" then
    local phase = event:match("UNIT_SPELLCAST_(.+)")
    local bucket = phase and P.casts[phase]
    if bucket then
      -- a3 is spellID for these events (unit, castGUID, spellID).
      if ns.IsSecret(a3) then
        bucket.secret = bucket.secret + 1
      else
        bucket.readable = bucket.readable + 1
        if type(a3) == "number" then push(P.lastCasts, { id = a3, phase = phase }) end
      end
    end
  end
end)

function P.StartRecording()
  ev:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
  ev:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
  ev:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
  ev:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
  ev:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
  ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
  ev:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
  ev:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
end

--------------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------------
local function secretTable(t)
  if type(issecrettable) == "function" then
    local ok, s = pcall(issecrettable, t)
    return ok and s
  end
  return false
end

-- Every tracked icon-viewer spell, whether or not the HUD is running.  Reading
-- the viewers directly (rather than ns.Hud.items) keeps the probe useful with
-- the HUD off, which is the state a fresh install is in.
local function trackedSpells()
  local out, seen = {}, {}
  for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer" }) do
    local viewer = ns.GetViewer(name)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        local base = ns.ItemBaseSpellID(item)
        local live = ns.ItemSpellID(item)
        local id = base or live
        if type(id) == "number" and not ns.IsSecret(id) and not seen[id] then
          seen[id] = true
          out[#out + 1] = { id = id, live = live, item = item, viewer = name }
        end
      end
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- SECTION: the secret map  (was `/cdmp secret`)
--------------------------------------------------------------------------------
local SOUL = Enum.PowerType and Enum.PowerType.SoulShards

local function cdFields(spellID, label)
  if not (C_Spell and C_Spell.GetSpellCooldown) then return end
  local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
  if not ok or type(info) ~= "table" then ns.Printf("  %s: <call failed>", label); return end
  if secretTable(info) then ns.Printf("  %s: |cffff4040<secret table>|r (cannot index in Lua)", label); return end
  local dur, start = "?", "?"
  pcall(function() dur = ns.Describe(info.duration); start = ns.Describe(info.startTime) end)
  ns.Printf("  %s: duration=%s startTime=%s", label, dur, start)
end

local function sectionSecrets()
  ns.Heading("Secret map")
  if not ns.SecretAPI() then
    ns.Print("  issecretvalue() absent — Secret Values not present on this build; everything is readable.")
    return
  end
  ns.Printf("  UnitPower(SoulShards): %s", ns.Describe(UnitPower("player", SOUL)))
  ns.Printf("  UnitPower(SoulShards, unmodified/fragments): %s", ns.Describe(UnitPower("player", SOUL, true)))
  cdFields(61304, "GCD (61304)")
  if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", "Demonic Core", "HELPFUL")
    if not ok or type(aura) ~= "table" then
      ns.Print("  Demonic Core aura: not active (proc it and re-run to test aura secrecy)")
    elseif secretTable(aura) then
      ns.Print("  Demonic Core aura: |cffff4040<secret table>|r (cannot index in Lua)")
    else
      local exp, apps = "?", "?"
      pcall(function() exp = ns.Describe(aura.expirationTime); apps = ns.Describe(aura.applications) end)
      ns.Printf("  Demonic Core aura: expirationTime=%s applications=%s", exp, apps)
    end
  end
end

--------------------------------------------------------------------------------
-- SECTION A: is cooldown state readable HERE?  (the M3d gate)
--------------------------------------------------------------------------------
-- THE ENTIRE M3d DECISION rides on this table.  §1's capability map says
-- `GetSpellCooldown().duration` is `<secret>` — but that was captured IN COMBAT,
-- IN A DELVE, and Secret Values only bite in restricted content.  If these read
-- real out of combat we can SEED readiness at bind time and delete the
-- "NEVER · no edge seen yet" cold start; if they're secret everywhere, M3d
-- closes for free.  Run once in a city, once mid-fight, and diff the two.
--
-- Printed per tracked spell rather than for a sample of three, because "readable
-- for some spells" is a real possible answer (the GCD is whitelisted) and a
-- three-row sample can't distinguish it from "readable for all".
local function sectionCooldownReadability()
  ns.Heading("A. Cooldown readability — the M3d gate  (compare OOC vs in-combat)")
  if not (C_Spell and C_Spell.GetSpellCooldown) then
    ns.Print("  |cffff4040C_Spell.GetSpellCooldown absent|r")
    return
  end
  local readable, unreadable = 0, 0
  for _, s in ipairs(trackedSpells()) do
    local ok, info = pcall(C_Spell.GetSpellCooldown, s.id)
    local verdict
    if not ok or type(info) ~= "table" then
      verdict = "|cffff4040<call failed>|r"; unreadable = unreadable + 1
    elseif secretTable(info) then
      verdict = "|cffff4040<secret table>|r"; unreadable = unreadable + 1
    else
      local d, st = info.duration, info.startTime
      if ns.IsSecret(d) or ns.IsSecret(st) then
        verdict = "|cffff4040<secret fields>|r"; unreadable = unreadable + 1
      else
        readable = readable + 1
        -- If this line ever prints real numbers, M3d is ON: duration==0 means
        -- ready, and startTime+duration-now seeds the napkin directly.
        verdict = string.format("|cff88ff88duration=%s startTime=%s|r",
          ns.Describe(d), ns.Describe(st))
      end
    end
    ns.Printf("   %-28s %s", (ns.SpellName(s.id) or tostring(s.id)):sub(1, 28), verdict)
  end
  ns.Printf("  -> %d readable / %d unreadable   |cffffd100M3d is viable iff the OOC run reads REAL and the combat run does not have to|r",
    readable, unreadable)
end

--------------------------------------------------------------------------------
-- SECTION B: spell overrides — the transform channel  (§7.2 item 6, V1(c))
--------------------------------------------------------------------------------
-- Two independent reads of the same question, because they can disagree and the
-- disagreement is the finding:
--   * the EVENT count (passive, since load) — does the channel fire at all?
--   * the LIVE divergence (base vs item:GetSpellID() right now) — is a button
--     transformed even though no event told us?
-- If divergence appears with an event count of 0, the override event is NOT the
-- mechanism for that button and item 6 must poll identity instead of trusting
-- the event.  That is precisely the Grimoire case to watch for.
local function sectionOverrides()
  ns.Heading("B. Spell overrides / transforms")
  ns.Printf("  COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED fired: |cffffd100%d|r  (passive, since load)", P.overrideCount)
  for _, o in ipairs(P.overrides) do
    ns.Printf("    base=%s -> override=%s  (%s / %s)",
      tostring(o.base), tostring(o.over),
      (o.base and ns.SpellName(o.base)) or "?", (o.over and ns.SpellName(o.over)) or "?")
  end
  local diverged = 0
  for _, s in ipairs(trackedSpells()) do
    local live = s.live
    if type(live) == "number" and not ns.IsSecret(live) and live ~= s.id then
      diverged = diverged + 1
      ns.Printf("    |cffffd100LIVE DIVERGENCE|r %s base=%d -> live=%d (%s)  [%s]",
        ns.SpellName(s.id) or "?", s.id, live, ns.SpellName(live) or "?", s.viewer)
    end
  end
  if diverged == 0 then
    ns.Print("    no button is currently transformed")
  end
  ns.Print("  |cff808080run this while a Grimoire is on cooldown / a Demonic Art is armed — that is the whole point|r")
end

--------------------------------------------------------------------------------
-- SECTION C: cast readability per phase  (§7.2 item 7, §7 raid assumption)
--------------------------------------------------------------------------------
-- SUCCEEDED carries the napkin (shipped).  START carries the spend-side
-- anticipation (M3c item 7) and has NEVER been counted separately — the status
-- block only ever reported SUCCEEDED.  A phase that reads secret while the other
-- doesn't is the single most consequential thing this probe can find in a raid.
local function sectionCasts()
  ns.Heading("C. Player-cast spellID readability, per phase")
  for _, phase in ipairs({ "START", "SUCCEEDED", "STOP", "INTERRUPTED" }) do
    local b = P.casts[phase]
    local verdict
    if b.readable + b.secret == 0 then verdict = "|cff808080no events yet|r"
    elseif b.secret == 0 then verdict = "|cff88ff88fully readable|r"
    elseif b.readable == 0 then verdict = "|cffff4040ALL SECRET — feature dark here|r"
    else verdict = "|cffffd100MIXED — investigate|r" end
    ns.Printf("   %-12s readable=%-4d secret=%-4d  %s", phase, b.readable, b.secret, verdict)
  end
  if #P.lastCasts > 0 then
    local out = {}
    for _, c in ipairs(P.lastCasts) do
      out[#out + 1] = string.format("%s(%s)", ns.SpellName(c.id) or c.id, c.phase:sub(1, 4))
    end
    ns.Printf("   recent: %s", table.concat(out, ", "))
  end
  ns.Printf("   glow show/hide: %d/%d   CDM data-loaded: %d", P.glow.show, P.glow.hide, P.dataLoaded)
end

--------------------------------------------------------------------------------
-- SECTION D: can we measure the imp count without reading it?
--------------------------------------------------------------------------------
-- A long shot with a big payoff, and cheap to ask.  The Wild Imp count is a
-- Secret Value, but the FontString drawing it is an ordinary widget.  If
-- GetStringWidth() reads non-secret it is a side channel to the DIGIT COUNT —
-- not the number, just "is it 1 digit or 2" — which is exactly the fact that
-- parked the dot-glyph font (§7.2 item 11): 2 digits means >=10 imps, i.e.
-- unambiguously past the >=6 gate.
--
-- ⚠ PROBE ONLY.  If this reads real, DO NOT build on it before a deliberate
-- review: a width derived from a secret may still taint on comparison, and
-- Blizzard may well consider it a leak to be closed.  Record the fact, don't
-- spend it.
local function sectionStackWidth()
  ns.Heading("D. Imp-count side channel (probe only — do not build on it yet)")
  local wild = ns.SpecIDs and ns.SpecIDs.WILD_IMP
  local found = false
  for _, name in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
    local viewer = ns.GetViewer(name)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        local base = ns.ItemBaseSpellID(item)
        if base == wild then
          found = true
          local fs = item.Applications
          if not fs then
            ns.Print("  Wild Imp item has no Applications FontString right now")
          else
            local w, txt = "?", "?"
            pcall(function() w = ns.Describe(fs:GetStringWidth()) end)
            pcall(function() txt = ns.Describe(fs:GetText()) end)
            ns.Printf("  Applications: GetStringWidth()=%s  GetText()=%s  shown=%s",
              w, txt, tostring(item:IsShown()))
          end
        end
      end
    end
  end
  if not found then
    ns.Print("  Wild Imp aura not currently tracked/active — summon imps and re-run")
  end
end

--------------------------------------------------------------------------------
-- The command
--------------------------------------------------------------------------------
ns.RegisterCommand("probe",
  "run EVERY probe and save the report to disk (run once OOC, once in combat, then /reload)",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("clear") or rest:find("reset") then
      for _, b in pairs(P.casts) do b.readable, b.secret = 0, 0 end
      wipe(P.overrides); wipe(P.lastCasts)
      P.overrideCount, P.dataLoaded = 0, 0
      P.glow.show, P.glow.hide = 0, 0
      return ns.Print("passive probe counters cleared.")
    end

    ns.BeginCapture()
    ns.Heading(string.format("CDMProbe v%s — full probe   (in combat: %s)",
      ns.version, tostring(InCombatLockdown())))
    local inst = "?"
    pcall(function() local _, t = IsInInstance(); inst = tostring(t) end)
    ns.Printf("  instance type: %s   |   HUD: %s",
      inst, (ns.Hud and ns.Hud.on) and "|cff88ff88on|r" or "off")

    ns.DumpViewers()
    sectionSecrets()
    sectionCooldownReadability()
    sectionOverrides()
    sectionCasts()
    sectionStackWidth()

    -- The HUD's own state/score/napkin readout, so ONE report has everything.
    if ns.Hud and ns.Hud.on then
      ns.HudState.PrintStatus()
    else
      ns.Print("(HUD off — enable it with /cdmp hud for the state + score block)")
    end

    ns.EndCapture("probe_" .. (InCombatLockdown() and "combat" or "ooc"))
    ns.Print("|cffffd100now /reload|r — SavedVariables only flush on reload/logout.")
  end)

--------------------------------------------------------------------------------
-- Base `reset` + `OnLogin` (were in the deleted Probes.lua; other modules wrap
-- both, so the base definitions have to exist before Skin/Resource/HudCore load)
--------------------------------------------------------------------------------
ns.RegisterCommand("reset", "turn every experiment off", function()
  if ns.db.skinOn and ns.SetSkin then ns.SetSkin(false) end
  ns.Print("all experiments off.")
end)

function ns.OnLogin()
  if ns.RestoreSkin then ns.RestoreSkin() end
  P.StartRecording()
end
