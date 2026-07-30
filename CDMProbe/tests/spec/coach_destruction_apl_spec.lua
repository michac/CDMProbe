-- coach_destruction_apl_spec.lua — the Tier-1 ROTATION gate for DESTRUCTION (spec 267).
--
-- The independent oracle for CoachDestruction.lua.  Every expected winner / fallback / SOON
-- below is read FROM specs/destruction/rotation.md (the spec of record), never from
-- RankWinner — the same discipline coach_apl_spec.lua applies to Demonology.  Minimal
-- hand-built State pulses exercise each BRANCH of the flat list plus the shard-threshold
-- boundaries on both sides.
--
-- Caveat honored: coverage proves a branch FIRED, not that the branch is RIGHT.
-- rotation.md stays the authority for each line's expected press, and that document is
-- itself still a DRAFT (desk-derived from the Tier-1 simc APL, not yet flown) — so these
-- tests pin the IMPLEMENTATION to the document, not the document to reality.
--
-- The list under test (specs/destruction/rotation.md; first usable line = the press):
--   L1   Ruination (the free Chaos Bolt replacement)
--   L2   Soul Fire            if shards <= 4
--   L3   Chaos Bolt           if a Demonic Art is armed        [see ART_FROM_RITUAL]
--   L4   Conflagrate          if shards <= 4 and no Backdraft
--   L5   Summon Infernal      (L5b: Malevolence, Hellcaller)
--   L6   Incinerate           if Chaotic Inferno and shards <= 4
--   L7   Shadowburn           if Fiendish Cruelty or target <= 20%
--   L8   Immolate / Wither    if missing or refreshable
--   L9   Cataclysm
--   L10  Rain of Fire         if AoE mode and shards >= 4
--   L11  Chaos Bolt           (the main dump)
--   L12  Infernal Bolt        if shards <= 3
--   L13  Incinerate           (the floor)
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

--------------------------------------------------------------------------------
-- Minimal State-pulse builder.  Every field the Destruction brain reads, nothing else.
--------------------------------------------------------------------------------
local NOW = 1000

-- Base spellIDs (SpecDestruction.SpecIDs) + the two Demonic Art override ids.  The Coach
-- consumes the DOMAIN VIEW keyed by base spellID, so these ARE the cue keys.
local ID = {
  CB = 116858, INC = 29722, CONF = 17962, SBURN = 17877, IMMO = 157736,
  ROF = 5740, SF = 6353, CATA = 152108, INFERNAL = 1122, MALEV = 442726,
  WITHER = 445468, UTILITY = 104773,
  -- buffs
  RITUAL = 428514, BACKDRAFT = 117828, CHAOTIC = 1244860, FIENDISH = 1245664,
  -- Art overrides (the Destruction-side ids from the cooldown-set residue)
  RUINATION = 433885, INFERNAL_BOLT = 433891,
}

-- Distinct cooldownID display handles, decoupled from spellIDs as in a live pulse.
local CID = {
  CB = 3001, INC = 3002, CONF = 3003, SBURN = 3004, IMMO = 3005, ROF = 3006,
  SF = 3007, CATA = 3008, INFERNAL = 3009, MALEV = 3010, WITHER = 3011, UTILITY = 3012,
}

-- cd sub-tables per the 3-state contract (state + a trust `source`).
local function cdReady(age)    return { state = "ready", readable = true, source = "live", changedAt = NOW - (age or 2) } end
local function cdProbably(age) return { state = "on-cooldown", remaining = 0, readable = false, source = "napkin", changedAt = NOW - (age or 2) } end
local function cdSoon(n)       return { state = "on-cooldown", remaining = n, readable = false, source = "napkin", changedAt = NOW - 1 } end
local function cdFar()         return { state = "on-cooldown", remaining = 30, readable = false, source = "napkin", changedAt = NOW - 1 } end
local function cdUnknown()     return { state = "unknown", readable = false, source = "none" } end

-- An `abilities` entry keyed by BASE spellID — the domain-view row the shell classifies.
-- `extra` carries the Destruction-specific channels: `charge` (the first charged tracked
-- abilities in this project), and `aura`/`buff` (the DoT-presence read L8 gates on).
local function ability(base, cid, cd, extra)
  extra = extra or {}
  local category = extra.category or "Essential"
  return {
    cooldownID = cid, spellID = base,
    overrideSpellID = extra.override or base,
    liveSpellID = extra.live or base,
    category = category,
    cd = cd or cdUnknown(),
    charge = extra.charge,
    aura = extra.aura,
    buff = extra.buff,
    uptime = extra.uptime,
    glow = { active = extra.glow or false, readable = true },
    display = { cooldownID = cid, category = category },
  }
end

-- Build a pulse from high-level facts.  Cooldown-bearing abilities default to cdFar (not
-- usable — the safe reading); the no-cooldown spenders/fillers are always present with an
-- `unknown` cd, since their gates are cost and proc, not readiness.
--   shards, incoming    projected = shards + incoming
--   art "ruination"|"infernal"   the armed Demonic Art (override on the CB / Incinerate frame)
--   soulFire/conflagrate/infernal/malevolence/shadowburn/cataclysm   a cd sub-table
--   confCharge/sburnCharge       a `charge` sub-table (the OOC banked-charge read)
--   ritual/backdraft/chaotic/fiendish   buff presence
--   dot "up"|"missing"|"unknown" the Immolate/Wither presence read; dotUptime = seconds left
--   hellcaller (bool)   swap the tracked maintenance DoT from Immolate to Wither
--   mode "st"|"aoe"     the manual target-mode toggle
--   targetHp            target health percent (nil = no target channel, today's reality)
--   noIncinerate        omit the Incinerate row entirely (the predicted-untracked worry)
local function build(f)
  f = f or {}
  local abilities = {}

  -- Cooldown-bearing rotation buttons.
  abilities[ID.SF]       = ability(ID.SF, CID.SF, f.soulFire or cdFar())
  abilities[ID.CONF]     = ability(ID.CONF, CID.CONF, f.conflagrate or cdFar(), { charge = f.confCharge })
  abilities[ID.INFERNAL] = ability(ID.INFERNAL, CID.INFERNAL, f.infernal or cdFar())
  abilities[ID.SBURN]    = ability(ID.SBURN, CID.SBURN, f.shadowburn or cdFar(), { charge = f.sburnCharge })
  abilities[ID.CATA]     = ability(ID.CATA, CID.CATA, f.cataclysm or cdFar())
  if f.malevolence then abilities[ID.MALEV] = ability(ID.MALEV, CID.MALEV, f.malevolence) end

  -- Costless / cooldownless buttons: gated by shards and procs, never by readiness.
  local cbExtra, incExtra = {}, {}
  if f.art == "ruination" then cbExtra = { override = ID.RUINATION, live = ID.RUINATION, glow = true } end
  if f.art == "infernal"  then incExtra = { override = ID.INFERNAL_BOLT, live = ID.INFERNAL_BOLT, glow = true } end
  abilities[ID.CB]  = ability(ID.CB, CID.CB, cdUnknown(), cbExtra)
  if not f.noIncinerate then
    abilities[ID.INC] = ability(ID.INC, CID.INC, cdUnknown(), incExtra)
  end
  abilities[ID.ROF] = ability(ID.ROF, CID.ROF, cdUnknown())

  -- The maintenance DoT.  `aura.readable` is what separates "missing" from "unknown": a
  -- refused read must never become a positive "the DoT is down" claim.
  local dotID, dotCid = ID.IMMO, CID.IMMO
  if f.hellcaller then dotID, dotCid = ID.WITHER, CID.WITHER end
  local dotAura
  if f.dot == "up"      then dotAura = { readable = true, active = true }
  elseif f.dot == "missing" then dotAura = { readable = true, active = false }
  else dotAura = { readable = false } end
  abilities[dotID] = ability(dotID, dotCid, cdUnknown(), { aura = dotAura, uptime = f.dotUptime })

  if f.utility then abilities[ID.UTILITY] = ability(ID.UTILITY, CID.UTILITY, f.utility, { category = "Utility" }) end

  -- Buff PRESENCE — spellID-keyed, exactly as State's domain view emits it.
  local buffs = {}
  if f.ritual   then buffs[ID.RITUAL]   = true end
  if f.backdraft then buffs[ID.BACKDRAFT] = true end
  if f.chaotic  then buffs[ID.CHAOTIC]  = true end
  if f.fiendish then buffs[ID.FIENDISH] = true end

  local shardBar = { value = f.shards or 0, incoming = f.incoming or 0, max = 5, readable = true }
  return {
    at = NOW, combat = (f.combat ~= false), combatStartedAt = NOW - 60,
    mode = f.mode or "st",
    power = { SoulShards = shardBar },
    buffs = buffs,
    history = {},
    abilities = abilities,
    target = f.targetHp and { healthPct = f.targetHp } or nil,
  }
end

--------------------------------------------------------------------------------
-- Guidance readers (identical contract to the Demonology oracle).
--------------------------------------------------------------------------------
local function pressOf(g)
  local found
  for spellID, cue in pairs(g.cues) do
    if cue.emphasis == "ROTATION" or cue.emphasis == "LATE" then
      assert.is_nil(found, "more than one top press emitted")
      found = { cid = spellID, cue = cue }
    end
  end
  return found
end

local function fallbackOf(g)
  for spellID, cue in pairs(g.cues) do
    if cue.emphasis == "ROTATION_FALLBACK" then return { cid = spellID, cue = cue } end
  end
end

local function soonSet(g)
  local t = {}
  for spellID, cue in pairs(g.cues) do if cue.emphasis == "SOON" then t[spellID] = true end end
  return t
end

--------------------------------------------------------------------------------
describe("Destruction rotation list (from specs/destruction/rotation.md)", function()
  local ns, Coach
  before_each(function()
    ns = H.fresh()
    -- The harness activates Demonology by default; drive spec 267 through the REAL
    -- resolver (index 3 -> 267), exactly as a live respec would.
    H.setSpecIndex(3)
    ns.ResolveActiveSpec()
    H.load("Coach.lua")
    Coach = ns.Coach.New()
  end)

  local function winner(facts) return pressOf(Coach:Compute(build(facts))) end

  ----------------------------------------------------------------------------
  it("activates spec 267 with the Destruction data bound", function()
    assert.equals(ns.Specs[267], ns.ActiveSpec)
    assert.equals(ID.CB, ns.SpecIDs.CHAOS_BOLT)
    assert.equals(ID.IMMO, ns.SpecIDs.IMMOLATE)
    -- The dormant Tier-3 fields Demonology carries are deliberately absent here.
    assert.is_nil(ns.SpecOpener)
    assert.is_nil(ns.SpecBurst)
  end)

  ----------------------------------------------------------------------------
  -- L1 — Ruination: the free granted press, top of the list.
  ----------------------------------------------------------------------------
  describe("L1 Ruination", function()
    it("wins outright whenever the Ruination Art is armed", function()
      local w = winner({ art = "ruination", shards = 3, soulFire = cdReady() })
      assert.equals(ID.CB, w.cid)   -- Ruination rides the Chaos Bolt frame
      assert.equals("ROTATION", w.cue.emphasis)
      assert.equals("Ruination — free empowered Chaos Bolt", w.cue.note)
    end)

    it("outranks even a ready Summon Infernal", function()
      assert.equals(ID.CB, winner({ art = "ruination", shards = 5, infernal = cdReady() }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L2 — Soul Fire while it fits without overcapping.
  ----------------------------------------------------------------------------
  describe("L2 Soul Fire", function()
    it("is the press when off cooldown and shards fit", function()
      assert.equals(ID.SF, winner({ soulFire = cdReady(), shards = 3 }).cid)
    end)

    it("boundary <=4: 4 shards casts it, 5 shards does not", function()
      assert.equals(ID.SF, winner({ soulFire = cdReady(), shards = 4 }).cid)
      assert.equals(ID.CB, winner({ soulFire = cdReady(), shards = 5 }).cid)
    end)

    it("is skipped while on cooldown", function()
      assert.equals(ID.CB, winner({ soulFire = cdFar(), shards = 3 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L3 — spend an armed Demonic Art with Chaos Bolt.  ART_FROM_RITUAL is the
  -- unsettled read: by default only a VISIBLE transform arms the Art.
  ----------------------------------------------------------------------------
  describe("L3 Demonic Art -> Chaos Bolt", function()
    it("does NOT fire off the Diabolic Ritual container by default", function()
      -- Ritual up, Conflagrate ready: L4 must still win, because the ritual container is
      -- not evidence the Art is armed.
      assert.equals(ID.CONF, winner({ ritual = true, conflagrate = cdReady(), shards = 3 }).cid)
    end)

    it("fires off the ritual when ART_FROM_RITUAL is enabled", function()
      ns.Specs[267].ART_FROM_RITUAL = true
      local w = winner({ ritual = true, conflagrate = cdReady(), shards = 3 })
      assert.equals(ID.CB, w.cid)
      assert.equals("spend the Demonic Art", w.cue.note)
    end)

    it("an armed INFERNAL BOLT never arms the Chaos Bolt line (that Art is Incinerate's)", function()
      ns.Specs[267].ART_FROM_RITUAL = true
      assert.equals(ID.CONF, winner({ ritual = true, art = "infernal",
                                      conflagrate = cdReady(), shards = 3 }).cid)
    end)

    it("needs Chaos Bolt to be affordable", function()
      ns.Specs[267].ART_FROM_RITUAL = true
      -- 1 shard < the 2-shard Chaos Bolt: the line is skipped, the floor answers.
      assert.equals(ID.INC, winner({ ritual = true, shards = 1 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L4 — Conflagrate to build, gated on Backdraft PRESENCE (the count is secret).
  ----------------------------------------------------------------------------
  describe("L4 Conflagrate", function()
    it("builds when off cooldown with no Backdraft up", function()
      assert.equals(ID.CONF, winner({ conflagrate = cdReady(), shards = 3 }).cid)
    end)

    it("is held while ANY Backdraft is present (stricter than simc's '< 2 stacks')", function()
      assert.equals(ID.CB, winner({ conflagrate = cdReady(), backdraft = true, shards = 3 }).cid)
    end)

    it("boundary <=4: 4 shards builds, 5 shards does not", function()
      assert.equals(ID.CONF, winner({ conflagrate = cdReady(), shards = 4 }).cid)
      assert.equals(ID.CB, winner({ conflagrate = cdReady(), shards = 5 }).cid)
    end)

    it("a BANKED CHARGE makes it usable while the recharge timer runs (OOC read)", function()
      assert.equals(ID.CONF, winner({ conflagrate = cdFar(),
                                      confCharge = { readable = true, cur = 1, max = 2 },
                                      shards = 3 }).cid)
    end)

    it("an UNREADABLE charge count (in combat) degrades to the plain cooldown read", function()
      assert.equals(ID.CB, winner({ conflagrate = cdFar(),
                                    confCharge = { readable = false },
                                    shards = 3 }).cid)
    end)

    it("zero banked charges is not a press", function()
      assert.equals(ID.CB, winner({ conflagrate = cdFar(),
                                    confCharge = { readable = true, cur = 0, max = 2 },
                                    shards = 3 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L5 — Summon Infernal, the whole burst window (nothing is staged for it).
  ----------------------------------------------------------------------------
  describe("L5 Summon Infernal / L5b Malevolence", function()
    it("is the press when off cooldown", function()
      assert.equals(ID.INFERNAL, winner({ infernal = cdReady(), shards = 3 }).cid)
    end)

    it("sits BELOW Conflagrate, per the list order", function()
      assert.equals(ID.CONF, winner({ infernal = cdReady(), conflagrate = cdReady(), shards = 3 }).cid)
    end)

    it("Malevolence is its own independent on-cooldown line (Hellcaller)", function()
      assert.equals(ID.MALEV, winner({ malevolence = cdReady(), hellcaller = true, shards = 3 }).cid)
    end)

    it("Summon Infernal outranks Malevolence when both are up (they never pair)", function()
      assert.equals(ID.INFERNAL, winner({ infernal = cdReady(), malevolence = cdReady(),
                                          hellcaller = true, shards = 3 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L6 — Chaotic Inferno arms an empowered Incinerate.
  ----------------------------------------------------------------------------
  describe("L6 Chaotic Inferno -> Incinerate", function()
    it("presses Incinerate while the buff is up and shards fit", function()
      local w = winner({ chaotic = true, shards = 3 })
      assert.equals(ID.INC, w.cid)
      assert.equals("Chaotic Inferno", w.cue.note)
    end)

    it("boundary <=4: 4 shards presses it, 5 shards does not", function()
      assert.equals(ID.INC, winner({ chaotic = true, shards = 4 }).cid)
      assert.equals(ID.CB, winner({ chaotic = true, shards = 5 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L7 — Shadowburn on Fiendish Cruelty, or in execute range.
  ----------------------------------------------------------------------------
  describe("L7 Shadowburn", function()
    it("fires with Fiendish Cruelty up", function()
      local w = winner({ shadowburn = cdReady(), fiendish = true, shards = 1 })
      assert.equals(ID.SBURN, w.cid)
      assert.equals("Fiendish Cruelty", w.cue.note)
    end)

    it("does NOT fire off readiness alone (neither half of the gate is met)", function()
      assert.equals(ID.INC, winner({ shadowburn = cdReady(), shards = 1 }).cid)
    end)

    it("fires on the execute gate once a target channel exists (<=20% HP)", function()
      local w = winner({ shadowburn = cdReady(), targetHp = 15, shards = 1 })
      assert.equals(ID.SBURN, w.cid)
      assert.equals("execute", w.cue.note)
    end)

    it("does not claim execute above 20%", function()
      assert.equals(ID.INC, winner({ shadowburn = cdReady(), targetHp = 40, shards = 1 }).cid)
    end)

    it("needs the shard to be affordable", function()
      assert.equals(ID.INC, winner({ shadowburn = cdReady(), fiendish = true, shards = 0 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L8 — the maintenance DoT.  Fires only on POSITIVE evidence of absence.
  ----------------------------------------------------------------------------
  describe("L8 Immolate / Wither maintenance", function()
    it("presses Immolate when the DoT positively reads missing", function()
      local w = winner({ dot = "missing", shards = 1 })
      assert.equals(ID.IMMO, w.cid)
      assert.equals("not up", w.cue.note)
    end)

    it("does NOT press when the DoT is up", function()
      assert.equals(ID.INC, winner({ dot = "up", shards = 1 }).cid)
    end)

    it("stays SILENT when the DoT read is refused — absence of a read is not absence", function()
      assert.equals(ID.INC, winner({ dot = "unknown", shards = 1 }).cid)
    end)

    it("refreshes inside the pandemic window once an uptime read exists", function()
      local w = winner({ dot = "up", dotUptime = 3, shards = 1 })
      assert.equals(ID.IMMO, w.cid)
      assert.equals("pandemic refresh", w.cue.note)
    end)

    it("leaves a healthy DoT alone (uptime beyond the refresh lead)", function()
      assert.equals(ID.INC, winner({ dot = "up", dotUptime = 12, shards = 1 }).cid)
    end)

    it("maintains WITHER instead of Immolate on Hellcaller", function()
      assert.equals(ID.WITHER, winner({ hellcaller = true, dot = "missing", shards = 1 }).cid)
    end)

    it("sits BELOW Shadowburn, per the list order", function()
      assert.equals(ID.SBURN, winner({ dot = "missing", shadowburn = cdReady(),
                                       fiendish = true, shards = 1 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L9 / L10 — Cataclysm, then the mode-gated Rain of Fire.
  ----------------------------------------------------------------------------
  describe("L9 Cataclysm / L10 Rain of Fire", function()
    it("Cataclysm is the press when off cooldown", function()
      assert.equals(ID.CATA, winner({ cataclysm = cdReady(), shards = 3 }).cid)
    end)

    it("Rain of Fire needs BOTH the AoE toggle and 4 banked shards", function()
      assert.equals(ID.ROF, winner({ mode = "aoe", shards = 4 }).cid)
      assert.equals(ID.CB, winner({ mode = "aoe", shards = 3 }).cid)   -- boundary >=4
      assert.equals(ID.CB, winner({ mode = "st", shards = 4 }).cid)    -- never count-gated
    end)

    it("Cataclysm outranks Rain of Fire", function()
      assert.equals(ID.CATA, winner({ cataclysm = cdReady(), mode = "aoe", shards = 4 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L11 / L12 / L13 — the dump, the refill and the floor.
  ----------------------------------------------------------------------------
  describe("L11 Chaos Bolt / L12 Infernal Bolt / L13 floor", function()
    it("Chaos Bolt is the dump at or above its cost", function()
      assert.equals(ID.CB, winner({ shards = 2 }).cid)
    end)

    it("boundary >=2: 1 shard cannot afford it and falls to the floor", function()
      assert.equals(ID.INC, winner({ shards = 1 }).cid)
    end)

    it("Infernal Bolt is the refill when armed and low on shards", function()
      local w = winner({ art = "infernal", shards = 1 })
      assert.equals(ID.INC, w.cid)   -- Infernal Bolt rides the Incinerate frame
      assert.equals("Infernal Bolt — shard refill", w.cue.note)
    end)

    it("Incinerate is the plain floor with nothing armed", function()
      local w = winner({ shards = 0 })
      assert.equals(ID.INC, w.cid)
      assert.is_nil(w.cue.note)
    end)

    it("an UNTRACKED Incinerate leaves no floor — no press, and no crash", function()
      -- The predicted-untracked worry (specs/destruction/notes.md).  The honest answer at
      -- low shards is "no call", which shows up in the decision log as `w:-`.
      local g = Coach:Compute(build({ shards = 1, noIncinerate = true }))
      assert.is_nil(pressOf(g))
      assert.is_nil(fallbackOf(g))
      assert.equals(1, #g.resourceBars)   -- the rest of the HUD still renders
    end)

    it("an untracked Incinerate still lets Chaos Bolt answer once affordable", function()
      assert.equals(ID.CB, winner({ shards = 2, noIncinerate = true }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- ROTATION_FALLBACK — the winner's ABILITY removed, list re-run from the top.
  ----------------------------------------------------------------------------
  describe("fallback (ROTATION_FALLBACK)", function()
    it("Ruination winner -> Soul Fire surfaces as the runner-up", function()
      local g = Coach:Compute(build({ art = "ruination", shards = 3, soulFire = cdReady() }))
      assert.equals(ID.CB, pressOf(g).cid)
      assert.equals(ID.SF, fallbackOf(g).cid)
    end)

    it("removing Chaos Bolt suppresses L1, L3 AND L11 (all three ride one base id)", function()
      -- Ruination armed AND the bar full: with Chaos Bolt pulled, the L11 dump must not
      -- resurface — the floor answers instead.
      local g = Coach:Compute(build({ art = "ruination", shards = 5 }))
      assert.equals(ID.CB, pressOf(g).cid)
      assert.equals(ID.INC, fallbackOf(g).cid)
    end)

    it("Chaos Bolt winner -> the Incinerate floor is the runner-up", function()
      local g = Coach:Compute(build({ shards = 3 }))
      assert.equals(ID.CB, pressOf(g).cid)
      assert.equals(ID.INC, fallbackOf(g).cid)
    end)

    it("no fallback when removing the winner leaves nothing castable", function()
      -- The Incinerate floor is the winner; pulling it also kills L6 and L12.
      local g = Coach:Compute(build({ shards = 1 }))
      assert.equals(ID.INC, pressOf(g).cid)
      assert.is_nil(fallbackOf(g))
    end)
  end)

  ----------------------------------------------------------------------------
  -- SOON — the dumb per-ability "coming off cooldown" decoration.
  ----------------------------------------------------------------------------
  describe("SOON decoration", function()
    it("a tracked cooldown anticipated within the lead lights SOON", function()
      local g = Coach:Compute(build({ shards = 3, cataclysm = cdSoon(2) }))
      assert.equals(ID.CB, pressOf(g).cid)
      assert.is_true(soonSet(g)[ID.CATA])
    end)

    it("multiple cooldowns can show SOON at once", function()
      local g = Coach:Compute(build({ shards = 3, cataclysm = cdSoon(2), infernal = cdSoon(2) }))
      local s = soonSet(g)
      assert.is_true(s[ID.CATA])
      assert.is_true(s[ID.INFERNAL])
    end)

    it("does NOT show SOON beyond the lead", function()
      assert.is_nil(soonSet(Coach:Compute(build({ shards = 3, cataclysm = cdSoon(5) })))[ID.CATA])
    end)

    it("excludes utility buttons from SOON", function()
      assert.is_nil(soonSet(Coach:Compute(build({ shards = 3, utility = cdSoon(2) })))[ID.UTILITY])
    end)
  end)

  ----------------------------------------------------------------------------
  -- Escalate — ROTATION -> LATE only from readable overdue-ness.  No window
  -- suppression: Destruction holds nothing, so a ready burst button is always late.
  ----------------------------------------------------------------------------
  describe("Escalate LATE", function()
    it("a Summon Infernal left sitting past the lead goes LATE", function()
      local w = winner({ infernal = cdProbably(6), shards = 3 })
      assert.equals(ID.INFERNAL, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("a Malevolence left sitting past the lead goes LATE", function()
      local w = winner({ malevolence = cdProbably(6), hellcaller = true, shards = 3 })
      assert.equals(ID.MALEV, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("a freshly-ready Summon Infernal is NOT late", function()
      local w = winner({ infernal = cdReady(1), shards = 3 })
      assert.equals(ID.INFERNAL, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)

    it("Chaos Bolt parked at a full bar goes LATE", function()
      local w = winner({ shards = 5 })
      assert.equals(ID.CB, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("a full bar with a Chaos Bolt already in flight is NOT late (the spend is committed)", function()
      -- Escalate reads ACTUAL shards, but an in-flight spender drops the projection below
      -- the L11 gate, so the winner is no longer Chaos Bolt at all.
      local w = winner({ shards = 5, incoming = -4 })
      assert.are_not.equals(ID.CB, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- The resource seam — one discrete SoulShards meter, as Demonology renders.
  ----------------------------------------------------------------------------
  it("emits exactly one discrete SOUL_SHARDS resource bar", function()
    local g = Coach:Compute(build({ shards = 3, incoming = -2 }))
    assert.equals(1, #g.resourceBars)
    local bar = g.resourceBars[1]
    assert.equals(3, bar.value)
    assert.equals(5, bar.max)
    assert.equals(-2, bar.incoming)
    assert.equals("discrete", bar.display)
    assert.equals("SOUL_SHARDS", bar.powerType)
  end)
end)
