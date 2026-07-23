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
-- probe that silently did nothing.  `/cdmp probe guide` tells you, IN GAME,
-- which observations that loop is still missing.
--
-- TWO OUTPUTS, ONE OBSERVATION SET (M4.5 T3).  Every probe run writes both:
--   * CDMProbeDB.reports[...] — the TEXT blob above, for a human.
--   * CDMProbeDB.probe.ooc / .combat — the SAME facts as a structured table,
--     for `uv run python -m wowkb.cdmp`, which asserts them against
--     projects/cooldown-hud/probe-baseline.json.
-- The reader must never text-parse the report (this codebase re-words it
-- freely), so each section computes its observation as a VALUE first and then
-- renders it twice — once as a chat line, once into the snapshot.  Read that as
-- a rule: NEVER read the game a second time to fill the table.
--
-- The division of labour that falls out (m4.5-t3-plan.md):
--   COLLECT a new observation -> addon change + release.
--   ASSERT / interpret / re-verify -> local tooling, no release.
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
-- ONE definition, in Util beside ns.IsSecret (M3d D1).  This was a duplicate
-- local; the seeding path needs the same question answered the same way, and
-- two copies of a secret guard is exactly one copy too many.
local secretTable = ns.IsSecretTable

-- STASHABLE form of an observed value (M4.5 T3).  Everything in the structured
-- snapshot ends up in SavedVariables, so a Secret Value must never reach it —
-- serializing one would at best write garbage and at worst taint the writer.
-- Secrets degrade to the STRING "<secret>", which is itself the finding the
-- reader wants ("this read secret here"), and anything not a scalar drops to nil
-- rather than persisting a live frame/table reference.
local function stash(v)
  if ns.IsSecret(v) then return "<secret>" end
  local t = type(v)
  if t == "number" or t == "boolean" or t == "string" then return v end
  return nil
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

local function sectionSecrets(snap)
  ns.Heading("Secret map")
  snap.secretAPI = ns.SecretAPI() and true or false
  if not snap.secretAPI then
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
local function sectionCooldownReadability(snap)
  ns.Heading("A. Cooldown readability — the M3d gate  (compare OOC vs in-combat)")
  local reads = {}
  snap.reads = reads
  if not (C_Spell and C_Spell.GetSpellCooldown) then
    ns.Print("  |cffff4040C_Spell.GetSpellCooldown absent|r")
    return
  end
  local readable, unreadable = 0, 0
  for _, s in ipairs(trackedSpells()) do
    -- OBSERVE ONCE, into a value.  The text line and the stashed table below are
    -- both rendered from `obs` — that is the no-drift rule (m4.5-t3-plan.md
    -- "Open questions"): one observation set, two renderers, never two reads.
    local obs
    local ok, info = pcall(C_Spell.GetSpellCooldown, s.id)
    if not ok or type(info) ~= "table" then
      obs = { readable = false, why = "call failed" }
    elseif secretTable(info) then
      obs = { readable = false, why = "secret table" }
    else
      local d, st = info.duration, info.startTime
      if ns.IsSecret(d) or ns.IsSecret(st) then
        obs = { readable = false, why = "secret fields" }
      else
        -- If this reads real numbers, M3d is ON: duration==0 means ready, and
        -- startTime+duration-now seeds the napkin directly.
        obs = { readable = true, duration = stash(d), startTime = stash(st) }
      end
    end
    reads[s.id] = obs

    local verdict
    if obs.readable then
      readable = readable + 1
      verdict = string.format("|cff88ff88duration=%s startTime=%s|r",
        ns.Describe(obs.duration), ns.Describe(obs.startTime))
    else
      unreadable = unreadable + 1
      verdict = string.format("|cffff4040<%s>|r", obs.why)
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
-- base spellID -> live spellID for every tracked button that is transformed RIGHT
-- NOW.  Factored out because `probe guide` asks the same question this section
-- does, and two copies of "is anything transformed" would eventually answer it
-- two different ways.
local function divergenceNow()
  local out = {}
  for _, s in ipairs(trackedSpells()) do
    local live = s.live
    if type(live) == "number" and not ns.IsSecret(live) and live ~= s.id then
      out[s.id] = live
    end
  end
  return out
end

local function sectionOverrides(snap)
  ns.Heading("B. Spell overrides / transforms")
  -- The two independent reads, each captured as a value before anything prints.
  local pairsSeen = {}
  for _, o in ipairs(P.overrides) do
    pairsSeen[#pairsSeen + 1] = { base = stash(o.base), over = stash(o.over), at = stash(o.at) }
  end
  snap.overrides = { count = P.overrideCount, pairs = pairsSeen }
  local divergence = divergenceNow()
  snap.divergence = divergence

  ns.Printf("  COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED fired: |cffffd100%d|r  (passive, since load)", P.overrideCount)
  for _, o in ipairs(P.overrides) do
    ns.Printf("    base=%s -> override=%s  (%s / %s)",
      tostring(o.base), tostring(o.over),
      (o.base and ns.SpellName(o.base)) or "?", (o.over and ns.SpellName(o.over)) or "?")
  end
  local diverged = 0
  for _, s in ipairs(trackedSpells()) do
    local live = divergence[s.id]
    if live then
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
-- SECTION C: cast readability per phase  (§7.2 item 7, §7 cast assumption)
--------------------------------------------------------------------------------
-- SUCCEEDED carries the napkin (shipped).  START carries the spend-side
-- anticipation (M3c item 7) and has NEVER been counted separately — the status
-- block only ever reported SUCCEEDED.  A phase that reads secret while the other
-- doesn't would be invisible in aggregate, hence the per-phase split.
local function sectionCasts(snap)
  ns.Heading("C. Player-cast spellID readability, per phase")
  local casts = {}
  snap.casts = casts
  for _, phase in ipairs({ "START", "SUCCEEDED", "STOP", "INTERRUPTED" }) do
    local b = P.casts[phase]
    local obs = { readable = b.readable, secret = b.secret }
    casts[phase] = obs
    local verdict
    if obs.readable + obs.secret == 0 then verdict = "|cff808080no events yet|r"
    elseif obs.secret == 0 then verdict = "|cff88ff88fully readable|r"
    elseif obs.readable == 0 then verdict = "|cffff4040ALL SECRET — feature dark here|r"
    else verdict = "|cffffd100MIXED — investigate|r" end
    ns.Printf("   %-12s readable=%-4d secret=%-4d  %s", phase, obs.readable, obs.secret, verdict)
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
-- The live Applications read, factored out for the same reason divergenceNow()
-- is: `probe guide`'s imp goal asks exactly this.  Returns nil when the aura
-- isn't tracked/active right now, `{ noFontString = true }` when the item exists
-- without its FontString, else an obs table whose fields may be the STRING
-- "<secret>" — which is itself the finding this section exists to record.
-- ⚠ THE ANSWER IS ALREADY "CLOSED" (2026-07-21): GetStringWidth() and GetText()
-- BOTH ERROR on this FontString, so there is no side channel to the digit count.
-- This section therefore exists to RE-TEST that verdict every patch, which is why
-- it records HOW each read failed rather than just failing quietly:
--   * `errored`  — the pcall itself threw (today's answer, and the one the
--                  baseline asserts).
--   * "<secret>" — the call returned, carrying a Secret Value.
-- Those are different worlds and collapsing them would hide the very flip
-- (Blizzard opening a leak) this is here to catch.
local function readField(obs, key, fn)
  local ok = pcall(function() obs[key] = stash(fn()) end)
  if not ok then
    obs[key] = nil
    obs[key .. "Errored"] = true
    return
  end
  obs[key .. "Readable"] = (obs[key] ~= nil and obs[key] ~= "<secret>")
end

local function readImps()
  local wild = ns.SpecIDs and ns.SpecIDs.WILD_IMP
  for _, name in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
    local viewer = ns.GetViewer(name)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        if ns.ItemBaseSpellID(item) == wild then
          local fs = item.Applications
          if not fs then return { noFontString = true } end
          local obs = {}
          readField(obs, "width", function() return fs:GetStringWidth() end)
          readField(obs, "text", function() return fs:GetText() end)
          pcall(function() obs.shown = item:IsShown() and true or false end)
          return obs
        end
      end
    end
  end
  return nil
end

local function describeField(obs, key)
  if obs[key .. "Errored"] then return "|cffff4040<errored>|r" end
  return ns.Describe(obs[key])
end

local function sectionStackWidth(snap)
  ns.Heading("D. Imp-count side channel (probe only — do not build on it yet)")
  local obs = readImps()
  if not obs then
    ns.Print("  Wild Imp aura not currently tracked/active — summon imps and re-run")
  elseif obs.noFontString then
    ns.Print("  Wild Imp item has no Applications FontString right now")
  else
    snap.imps = obs
    ns.Printf("  Applications: GetStringWidth()=%s  GetText()=%s  shown=%s",
      describeField(obs, "width"), describeField(obs, "text"), tostring(obs.shown))
  end
end

--------------------------------------------------------------------------------
-- SECTION E: the keybind reverse index  (§7.2 item 5)
--------------------------------------------------------------------------------
-- "I remapped a key and the HUD didn't pick it up" has been open since v0.4.0
-- and is explicitly NOT DIAGNOSABLE FROM SOURCE — it depends on the player's
-- actual bars.  `hud binds` was built to answer it and then had to be READ LIVE,
-- which is the same scheduling problem this whole file exists to delete.  So the
-- reverse index goes INTO THE REPORT, and all four failure modes are then
-- readable off disk after the fact (see ns.HudBinds.Explain's header):
--
--   two rows, lower one `<-- used`  -> first-bound-slot-wins
--   a row with cmd=none             -> the unbindable 13-24 / 109-180 ranges
--   no rows at all                  -> a macro GetMacroSpell can't resolve
--   a populated 2nd=                -> the SECONDARY binding was the one remapped
--
-- Reads the viewers directly rather than ns.Hud.items, like every other section,
-- so it still answers with the HUD off.
local function sectionBinds()
  ns.Heading("E. Keybind reverse index — every action slot per tracked spell")
  if not ns.HudBinds then return ns.Print("  |cffff4040HudBinds absent|r") end
  if InCombatLockdown() then
    ns.Print("  |cffffd100in combat|r — the bar scan is out-of-combat only, so the cache may be stale (the rows below are a LIVE read).")
  end
  local ok, bySpell = pcall(ns.HudBinds.Explain)
  if not ok or type(bySpell) ~= "table" then
    return ns.Print("  |cffff4040Explain() failed|r")
  end
  for _, s in ipairs(trackedSpells()) do
    local used = ns.HudBinds.Get(s.id)
    ns.Printf("  |cffffd100%s|r (%d) -> chrome shows %s",
      ns.SpellName(s.id) or "?", s.id,
      used and ("|cff88ff88" .. used .. "|r") or "|cff808080nothing|r")
    local rows = bySpell[s.id]
    if not rows then
      ns.Print("    |cff808080no action slot holds this spell (off-bars, or a macro that doesn't resolve)|r")
    else
      for _, r in ipairs(rows) do
        ns.Printf("    slot %3d (%s)  cmd=%s  key=%s%s  -> %s%s",
          r.slot, r.via,
          r.cmd or "|cffff4040none — unbindable slot range|r",
          r.key or "|cff808080unbound|r",
          r.key2 and ("  |cffffd1002nd=" .. r.key2 .. " (not used)|r") or "",
          r.short or "|cff808080-|r",
          (r.short and r.short == used) and "  |cff88ff88<-- used|r" or "")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- `probe guide` — coverage, on demand  (M4.5 T3 / A2)
--------------------------------------------------------------------------------
-- PULL-BASED by design (Option 2): no frame, no ticker, no auto-refresh.  You
-- re-type it whenever you want to know what is still missing.
--
-- WHAT IT BUYS IS TIMING.  Every goal below is already answerable from the
-- capture — but only an hour later, from `wowkb.cdmp check`, when you are logged
-- out and the missing observation costs another session.  Asking in-game means
-- you learn the capture is incomplete while you are still standing at the dummy
-- and able to fix it.
--
-- HONEST LIMIT: this DETECTS and NUDGES, it cannot CREATE state.  It can't force
-- a Demonic Core proc or summon your imps on demand.  It makes the gap visible;
-- you close it.
--
-- The list is deliberately small and lives here rather than being mirrored from
-- probe-baseline.json — a handful of goals is not worth a second source of
-- truth.  If it ever outgrows a handful, drive it from the baseline instead.
local function snapshot(key)
  local p = ns.db and ns.db.probe
  if type(p) ~= "table" or type(p[key]) ~= "table" then return nil end
  return p[key]
end

local function hasReads(snap)
  return snap ~= nil and type(snap.reads) == "table" and next(snap.reads) ~= nil
end

local GOALS = {
  { label = "OOC cooldown reads captured",
    nudge = "run |cffffffff/cdmp probe|r out of combat",
    met   = function() return hasReads(snapshot("ooc")) end },

  { label = "SUCCEEDED seen readable",
    nudge = "cast anything — the napkin/anticipation engine rides on this",
    met   = function() return P.casts.SUCCEEDED.readable > 0 end },

  { label = "a transform observed",
    nudge = "arm a Demonic Art / let a Grimoire hit cooldown",
    met   = function()
      if P.overrideCount > 0 then return true end
      if next(divergenceNow()) ~= nil then return true end
      for _, k in ipairs({ "ooc", "combat" }) do
        local s = snapshot(k)
        if s and type(s.divergence) == "table" and next(s.divergence) ~= nil then return true end
      end
      return false
    end },

  -- NOT "imp count >=2 seen".  The side channel is CLOSED — both reads error —
  -- so a goal asking for a readable count could never go green and `coverage
  -- complete` would be unreachable forever.  What is still worth asking each
  -- patch is whether the capture EXERCISED the channel at all, because an
  -- un-exercised Section D leaves the "still closed?" assumption unre-tested.
  { label = "imp aura observed (re-tests the closed side channel)",
    nudge = "summon imps (Hand of Gul'dan), then re-run",
    met   = function()
      if readImps() ~= nil then return true end
      for _, k in ipairs({ "ooc", "combat" }) do
        local s = snapshot(k)
        if s and type(s.imps) == "table" then return true end
      end
      return false
    end },

  { label = "in-combat probe taken",
    nudge = "pull a dummy, then |cffffffff/cdmp probe|r again",
    met   = function() return hasReads(snapshot("combat")) end },
}

local function printGuide()
  ns.Heading("probe coverage — what this capture still needs")
  local left = 0
  for _, g in ipairs(GOALS) do
    local ok = false
    local called, res = pcall(g.met)
    if called then ok = res and true or false end
    if ok then
      ns.Printf("  |cff88ff88[x]|r %s", g.label)
    else
      left = left + 1
      ns.Printf("  |cff808080[ ]|r %s   |cffffd100<- %s|r", g.label, g.nudge)
    end
  end
  if left == 0 then
    ns.Print("  |cff88ff88coverage complete|r — |cffffffff/reload|r, then |cffffffffuv run python -m wowkb.cdmp check|r")
  else
    ns.Printf("  -> |cffffd100%d goal%s left|r; re-run |cffffffff/cdmp probe guide|r to re-check, then |cffffffff/reload|r",
      left, left == 1 and "" or "s")
  end
  ns.Print("  |cff808080(start a session with `/cdmp probe clear` so these read THIS session)|r")
end

--------------------------------------------------------------------------------
-- The command
--------------------------------------------------------------------------------
ns.RegisterCommand("probe",
  "run EVERY probe and save the report to disk (run once OOC, once in combat, then /reload). `probe guide` = what coverage is still missing; `probe clear` = reset for a new session",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("guide") then
      return printGuide()
    end
    if rest:find("clear") or rest:find("reset") then
      for _, b in pairs(P.casts) do b.readable, b.secret = 0, 0 end
      wipe(P.overrides); wipe(P.lastCasts)
      P.overrideCount, P.dataLoaded = 0, 0
      P.glow.show, P.glow.hide = 0, 0
      -- The stored SNAPSHOTS go too, and that is the point of calling this at
      -- the start of a session: `probe guide`'s "in-combat probe taken" goal is
      -- a test of THIS session's coverage, and a snapshot left on disk from last
      -- week would tick it green while the capture you are about to hand the
      -- reader has no combat half at all.
      if ns.db then ns.db.probe = {} end
      return ns.Print("passive probe counters + stored snapshots cleared.")
    end

    local combat = InCombatLockdown() and true or false
    ns.BeginCapture()
    ns.Heading(string.format("CDMProbe v%s — full probe   (in combat: %s)",
      ns.version, tostring(combat)))
    local inst = "?"
    pcall(function() local _, t = IsInInstance(); inst = tostring(t) end)
    ns.Printf("  instance type: %s   |   HUD: %s",
      inst, (ns.Hud and ns.Hud.on) and "|cff88ff88on|r" or "off")

    -- M4.5 T3 — the structured half.  Each section below fills its own slice of
    -- `snap` from the SAME value it prints its text line from, so the report a
    -- human reads and the table `wowkb.cdmp` checks can never disagree.
    local snap = {
      at         = date("%Y-%m-%d %H:%M:%S"),
      capturedAt = GetTime(),
      version    = ns.version,
      combat     = combat,
      instance   = inst,
      interface  = "?",
    }
    pcall(function() snap.interface = tostring(select(4, GetBuildInfo())) end)

    ns.DumpViewers()
    sectionSecrets(snap)
    sectionCooldownReadability(snap)
    sectionOverrides(snap)
    sectionCasts(snap)
    sectionStackWidth(snap)
    sectionBinds()

    ns.db.probe = ns.db.probe or {}
    ns.db.probe[combat and "combat" or "ooc"] = snap

    -- The HUD's own state/score/napkin readout, so ONE report has everything.
    if ns.Hud and ns.Hud.on then
      ns.HudState.PrintStatus()
      -- M3e — the LAST CLOSED PULL, folded in here so one report still has
      -- everything and the existing OOC-then-combat workflow is unchanged.  The
      -- status block's `lit now` is a snapshot of THIS instant; this is the
      -- distribution across the whole fight, which is what §7.3 item 6 actually
      -- asks about.  (The full ring is `/cdmp hud log all`, or read
      -- CDMProbeDB.pulls off disk.)
      ns.Heading("  last pull — M3e (the recorder)")
      local pulls = ns.db and ns.db.pulls or {}
      ns.HudLog.Summary(pulls[#pulls] or ns.HudLog.last, 20)
    else
      ns.Print("(HUD off — enable it with /cdmp hud for the state + score block, and NOTHING IS BEING RECORDED)")
    end

    ns.EndCapture("probe_" .. (combat and "combat" or "ooc"))
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
