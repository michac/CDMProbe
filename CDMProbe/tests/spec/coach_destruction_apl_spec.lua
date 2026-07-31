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
  IMMO_CAST = 348,
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
  IMMO_CAST = 3013,
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
--   dot "up"|"missing"|"unknown" the Immolate/Wither presence read (the OOC channel)
--   dotEdge "pandemic"|"fresh"|"absent"  the CDM alert latch (the COMBAT channel), and
--                       dotEdgeOn / dotEdgesRaw pick which of the DoT's ids carries it;
--                       dotEdgeAge ages it in seconds (default 1) for the TTL
--   dotFrame "target"|"player"|"none"|"unreadable"   the PER-FRAME aura verdict (§3.10),
--                       the channel that outranks the latch; dotFramePandemic is its
--                       refresh-window half and dotFrameIncapable removes the capability
--   hellcaller (bool)   swap the tracked maintenance DoT from Immolate to Wither
--   immolateAsCast      track Immolate on its CAST id 348 (what the live build does)
--   noWither            a Hellcaller build that does NOT track Wither (the field case)
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
  -- `artID` overrides WHICH numeric override id arms the Art.  SpellName carries several
  -- ids per Art (see SpecDestruction's ID-split note) and the brain must recognise every
  -- one of them — it keys on the spec table's `art` field, never on the display `abbr`.
  if f.art == "ruination" then
    local id = f.artID or ID.RUINATION
    cbExtra = { override = id, live = id, glow = true }
  end
  if f.art == "infernal" then
    local id = f.artID or ID.INFERNAL_BOLT
    incExtra = { override = id, live = id, glow = true }
  end
  abilities[ID.CB]  = ability(ID.CB, CID.CB, cdUnknown(), cbExtra)
  if f.virtualIncinerate then
    -- The row State SYNTHESISES when the CDM tracks Incinerate nowhere: a negative display
    -- handle, `ready` from the spell's 0-cooldown nature rather than an observation
    -- (`source = "static"`), and `virtual = true`.  Shaped exactly as State.VirtualRow emits
    -- it, so this asserts what the Coach really receives.
    abilities[ID.INC] = ability(ID.INC, -ID.INC, nil, incExtra)
    abilities[ID.INC].cd = { state = "ready", remaining = 0, readable = true, source = "static" }
    abilities[ID.INC].virtual = true
  elseif not f.noIncinerate then
    abilities[ID.INC] = ability(ID.INC, CID.INC, cdUnknown(), incExtra)
  end
  abilities[ID.ROF] = ability(ID.ROF, CID.ROF, cdUnknown())

  -- The maintenance DoT.  `aura.readable` is what separates "missing" from "unknown": a
  -- refused read must never become a positive "the DoT is down" claim.
  --
  -- ⚠ WHICH IMMOLATE ID.  The live build tracks the CAST id 348 as the pressable Essential
  -- row; the DoT aura 157736 sits on the Buff-bar viewer and never enters `abilities`.  The
  -- fixture defaults to 157736 (what the code assumed before field-fix B) and
  -- `immolateAsCast` swaps to the real one, so both are exercised.
  local dotID, dotCid = ID.IMMO, CID.IMMO
  if f.immolateAsCast then dotID, dotCid = ID.IMMO_CAST, CID.IMMO_CAST end
  if f.hellcaller and not f.noWither then dotID, dotCid = ID.WITHER, CID.WITHER end
  local dotAura
  if f.dot == "up"      then dotAura = { readable = true, active = true }
  elseif f.dot == "missing" then dotAura = { readable = true, active = false }
  else dotAura = { readable = false } end
  abilities[dotID] = ability(dotID, dotCid, cdUnknown(), { aura = dotAura })

  if f.utility then abilities[ID.UTILITY] = ability(ID.UTILITY, CID.UTILITY, f.utility, { category = "Utility" }) end

  -- Buff PRESENCE — spellID-keyed, exactly as State's domain view emits it.
  local buffs = {}
  if f.ritual   then buffs[ID.RITUAL]   = true end
  if f.backdraft then buffs[ID.BACKDRAFT] = true end
  if f.chaotic  then buffs[ID.CHAOTIC]  = true end
  if f.fiendish then buffs[ID.FIENDISH] = true end

  -- The aura-lifecycle latch (field-fix C), base-spellID-keyed exactly as State emits it.
  -- `dotEdgeOn` picks WHICH of the DoT's ids carries it — the two-cooldownID case.
  local dotEdges = {}
  if f.dotEdge then
    dotEdges[f.dotEdgeOn or dotID] = { state = f.dotEdge, at = NOW - (f.dotEdgeAge or 1) }
  end
  -- Raw form, for the case where the SAME DoT has latched on both of its ids at different
  -- times: { [spellID] = { state, at } }.
  for id, e in pairs(f.dotEdgesRaw or {}) do dotEdges[id] = e end

  -- The PER-FRAME AURA VERDICT (§3.10), base-spellID-keyed exactly as State emits it.  This
  -- is the channel that OUTRANKS the latch: `auraDataUnit` says whether the aura is up and
  -- `PandemicIcon` whether it is in the refresh window, and Blizzard recomputes both every
  -- frame, so unlike an edge they self-clear.
  --   dotFrame "target"|"player"|"none"|"unreadable"   what the frame says about presence
  --   dotFramePandemic (bool)                          the refresh-window mirror
  --   dotFrameIncapable                                the writer methods are gone —
  --                                                    rule-18's fallback-to-the-latch case
  --   dotFrameOn                                       which id carries it (default: dotID)
  local auraFrames = {}
  if f.dotFrame or f.dotFrameIncapable then
    local af = { capable = not f.dotFrameIncapable, pandemic = f.dotFramePandemic or false }
    if f.dotFrame == "unreadable" then
      af.unitReadable = false
    else
      af.unitReadable = true
      if f.dotFrame == "target" or f.dotFrame == "player" then af.unit = f.dotFrame end
    end
    auraFrames[f.dotFrameOn or dotID] = af
  end
  for id, a in pairs(f.auraFramesRaw or {}) do auraFrames[id] = a end

  local shardBar = { value = f.shards or 0, incoming = f.incoming or 0, max = 5, readable = true }
  return {
    at = NOW, combat = (f.combat ~= false), combatStartedAt = NOW - 60,
    mode = f.mode or "st",
    -- The hero tree rides the PULSE (State reads the talent API, not the brain).  nil =
    -- State could not read it, which is what drives the brain's inference fallback.
    hero = f.hero,
    power = { SoulShards = shardBar },
    buffs = buffs,
    history = {},
    abilities = abilities,
    dotEdges = dotEdges,
    auraFrames = auraFrames,
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

    it("an UNREADABLE charge count with no estimate degrades to the plain cooldown read", function()
      assert.equals(ID.CB, winner({ conflagrate = cdFar(),
                                    confCharge = { readable = false },
                                    shards = 3 }).cid)
    end)

    ------------------------------------------------------------------------
    -- ⚠ FROM THE FIRST LIVE PASS: the HUD recommended Conflagrate at ZERO charges.
    -- For a charged ability the CDM raises `Available` on every charge RESTORED and
    -- never raises `OnCooldown` (capture: cid 18860 Available x7 / OnCooldown x0), so
    -- State's ready-edge latches true forever and `cd` reads ready — 190 of 194 log
    -- lines said `Conf=R`.  A count, when we have one, must therefore OUTRANK it.
    ------------------------------------------------------------------------
    it("is NOT usable at zero charges even while the cooldown reads READY", function()
      assert.equals(ID.CB, winner({ conflagrate = cdReady(),
                                    confCharge = { readable = true, cur = 0, max = 2,
                                                   charged = true, source = "live" },
                                    shards = 3 }).cid)
    end)

    it("is not usable at zero charges on a NAPKIN count either", function()
      assert.equals(ID.CB, winner({ conflagrate = cdReady(),
                                    confCharge = { readable = false, cur = 0, max = 2,
                                                   charged = true, source = "napkin" },
                                    shards = 3 }).cid)
    end)

    it("a count of 1 IS a press even while the cooldown reads far from ready", function()
      assert.equals(ID.CONF, winner({ conflagrate = cdFar(),
                                      confCharge = { readable = true, cur = 1, max = 2,
                                                     charged = true, source = "live" },
                                      shards = 3 }).cid)
    end)

    it("with NO count at all it still falls back to the cooldown read", function()
      -- The un-seeded case must not become "never pressable".
      assert.equals(ID.CONF, winner({ conflagrate = cdReady(), shards = 3 }).cid)
    end)

    it("an IN-COMBAT napkin estimate counts as banked (field-fix C2)", function()
      -- The exact read is secret in combat, so before C2 a banked charge was invisible for
      -- the whole pull.  The estimate is trusted because it is fenced to UNDERCOUNT: it can
      -- only ever hold a charge we really have, never claim one we do not.
      assert.equals(ID.CONF, winner({ conflagrate = cdFar(),
                                      confCharge = { readable = false, cur = 1, max = 2,
                                                     charged = true, source = "napkin" },
                                      shards = 3 }).cid)
    end)

    it("a napkin estimate of ZERO is still not a press", function()
      assert.equals(ID.CB, winner({ conflagrate = cdFar(),
                                    confCharge = { readable = false, cur = 0, max = 2,
                                                   source = "napkin" },
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

    -- THE PANDEMIC HALF (field-fix C).  Driven by the CDM's own `PandemicTime` alert, not
    -- by an uptime number: the window's endpoints are Secret Values in combat and
    -- IsInPandemicTime THROWS, so the edge is the only signal there is — and it is the
    -- better one, since Blizzard computes the real carry-over per spell.
    it("refreshes when the pandemic ALERT has latched", function()
      local w = winner({ dot = "up", dotEdge = "pandemic", shards = 1 })
      assert.equals(ID.IMMO, w.cid)
      assert.equals("pandemic refresh", w.cue.note)
    end)

    ------------------------------------------------------------------------
    -- THE LATCH EXPIRES.  Field capture 2026-07-30: `Imm=pandemic` was still driving a
    -- Wither cue **13.4s** after it fired, with the DoT near full duration.  The latch is
    -- only ever superseded by a later fresh/absent edge, so a clear that never arrives
    -- pins the cue on forever.  Immolate/Wither is an 18s DoT — its refresh window is
    -- ~5.4s — so a 13.4s-old pandemic claim is arithmetically impossible, not just stale.
    ------------------------------------------------------------------------
    it("still refreshes on a pandemic edge INSIDE the TTL", function()
      local w = winner({ dot = "up", dotEdge = "pandemic", dotEdgeAge = 5, shards = 1 })
      assert.equals(ID.IMMO, w.cid)
      assert.equals("pandemic refresh", w.cue.note)
    end)

    it("STOPS refreshing once the pandemic latch has aged out — the field defect", function()
      -- 13.4s is the age actually observed pinning the cue on.
      local w = winner({ dot = "up", dotEdge = "pandemic", dotEdgeAge = 13.4, shards = 1 })
      assert.are_not.equal(ID.IMMO, w.cid)
    end)

    it("an aged-out latch decays to NO CLAIM, not to 'the DoT is missing'", function()
      -- The failure direction matters: expiring must make us quieter, never turn a
      -- healthy DoT into an "apply it now" press.  ctx.dotState stays `up`.
      local ctx = ns.Specs[267]:Context(
        build({ dot = "up", dotEdge = "pandemic", dotEdgeAge = 30, shards = 1 }), Coach)
      assert.equals("up", ctx.dotState)
      assert.is_nil(ctx.dotEdge)
      assert.is_false(ctx.dotRefreshable)
    end)

    it("a MISSING DoT is unaffected by the TTL — absence stays true until it is applied", function()
      -- Only the `pandemic` claim decays.  An `absent` edge is a fact about the world that
      -- stays true however old it is, until OnAuraApplied says otherwise.
      local w = winner({ dot = "up", dotEdge = "absent", dotEdgeAge = 60, shards = 1 })
      assert.equals(ID.IMMO, w.cid)
    end)

    it("leaves a healthy DoT alone — a `fresh` edge supersedes the pandemic latch", function()
      assert.equals(ID.INC, winner({ dot = "up", dotEdge = "fresh", shards = 1 }).cid)
    end)

    it("an `absent` edge presses it even while the aura read says otherwise", function()
      -- The latch is the COMBAT channel; the aura read is not.  When they disagree the
      -- observed edge wins, because the alternative is trusting a read that went dark.
      local w = winner({ dot = "up", dotEdge = "absent", shards = 1 })
      assert.equals(ID.IMMO, w.cid)
      assert.equals("not up", w.cue.note)
    end)

    it("when BOTH of the DoT's ids have latched, the NEWEST edge decides", function()
      -- Both Immolate rows raise the alerts, and they do not arrive together: the aura row
      -- can still be sitting on a stale `pandemic` when the cast row reports the recast.
      -- Taking the first candidate rather than the freshest would keep cueing a refresh the
      -- player has already done.
      local edges = {
        [ID.IMMO]      = { state = "pandemic", at = NOW - 9 },
        [ID.IMMO_CAST] = { state = "fresh",    at = NOW - 1 },
      }
      assert.equals(ID.INC, winner({ dot = "up", dotEdgesRaw = edges,
                                     immolateAsCast = true, shards = 1 }).cid)
      -- ...and the other way round: a fresh application followed by a real pandemic edge.
      edges[ID.IMMO].at, edges[ID.IMMO_CAST].at = NOW - 1, NOW - 9
      edges[ID.IMMO].state, edges[ID.IMMO_CAST].state = "pandemic", "fresh"
      local w = winner({ dot = "up", dotEdgesRaw = edges, immolateAsCast = true, shards = 1 })
      assert.equals(ID.IMMO_CAST, w.cid)
      assert.equals("pandemic refresh", w.cue.note)
    end)

    it("the latch reaches the brain from EITHER of Immolate's two cooldownIDs", function()
      -- The aura row (157736, Buff-bar) and the cast row (348, Essential) both raise
      -- PandemicTime and both must arrive at one answer.  State keys `dotEdges` by base
      -- spellID, so the brain reads whichever one the pulse carries.
      local w = winner({ dot = "up", dotEdgeOn = ID.IMMO, dotEdge = "pandemic", shards = 1 })
      assert.equals(ID.IMMO, w.cid)
      local w2 = winner({ dot = "up", dotEdgeOn = ID.IMMO_CAST, dotEdge = "pandemic",
                          immolateAsCast = true, shards = 1 })
      assert.equals(ID.IMMO_CAST, w2.cid)
    end)

    it("maintains WITHER instead of Immolate on Hellcaller", function()
      assert.equals(ID.WITHER, winner({ hellcaller = true, dot = "missing", shards = 1 }).cid)
    end)

    it("sits BELOW Shadowburn, per the list order", function()
      assert.equals(ID.SBURN, winner({ dot = "missing", shadowburn = cdReady(),
                                       fiendish = true, shards = 1 }).cid)
    end)

    --------------------------------------------------------------------------
    -- §3.10 — THE PER-FRAME AURA VERDICT, and why it outranks the latch.
    --------------------------------------------------------------------------
    -- The measurement this exists for: across a whole pull, all 169 DoT cues carried
    -- `pandemic_refresh` and ZERO carried `not_up`.  Two causes, both fixed together —
    -- §3.1 jammed the presence read to "up" on a tab-1 row whose `IsActive()` is a
    -- constant, and `PandemicTime` is a one-shot notification that never re-arms, so the
    -- refresh cue fired for exactly one 5.8s window in the whole fight.  `auraDataUnit`
    -- and `PandemicIcon` are recomputed every frame, so they answer BOTH halves and they
    -- clear themselves.
    describe("the DoT's three channels, in trust order (§3.10)", function()
      it("a bound aura on the frame reads UP, and does not press", function()
        assert.equals(ID.INC, winner({ dotFrame = "target", shards = 1 }).cid)
      end)

      it("NO bound aura on a capable frame is the `not up` press", function()
        -- THE ANSWER THAT WAS STRUCTURALLY UNREACHABLE.  Nothing else in the pulse can
        -- produce it in combat: the aura read is secret, tab-1 `IsActive()` is constant,
        -- and OnAuraRemoved only fires if the DoT actually falls off unrefreshed.
        local w = winner({ dotFrame = "none", shards = 1 })
        assert.equals(ID.IMMO, w.cid)
        assert.equals("not up", w.cue.note)
      end)

      it("`PandemicIcon` is the refresh window, with no TTL to age out", function()
        -- It is a POLL of a live predicate, not a latch: it arms on entry and clears on
        -- the refresh.  So a 60-second-old pulse is as trustworthy as a fresh one.
        local w = winner({ dotFrame = "target", dotFramePandemic = true, shards = 1 })
        assert.equals(ID.IMMO, w.cid)
        assert.equals("pandemic refresh", w.cue.note)
      end)

      it("a capable frame saying NOT in the window overrides a stale pandemic latch", function()
        -- The one-shot latch fired at some point and never retracted; the frame is
        -- answering right now.  This is the whole point of the reordering — the field
        -- capture showed a `pandemic` claim still driving a cue 13.4s after it fired.
        local w = winner({ dotFrame = "target", dotFramePandemic = false,
                           dotEdge = "pandemic", dotEdgeAge = 2, shards = 1 })
        assert.equals(ID.INC, w.cid)
      end)

      it("the frame's presence read outranks a stale `absent` latch too", function()
        local ctx = ns.Specs[267]:Context(
          build({ dotFrame = "target", dotEdge = "absent", dotEdgeAge = 40, shards = 1 }), Coach)
        assert.equals("up", ctx.dotState)
        assert.equals("frame", ctx.dotFrom)
      end)

      it("an INCAPABLE frame falls back to the latch — rule 18's documented fallback", function()
        -- The fields are widget internals with no deprecation path.  If Blizzard stops
        -- writing them the row must carry NO opinion, not a silent negative: a
        -- silently-absent field reading as "no DoT" is the confident-wrong-answer failure
        -- that makes this technique a liability.
        local ctx = ns.Specs[267]:Context(
          build({ dotFrameIncapable = true, dotEdge = "pandemic", dotEdgeAge = 2,
                  shards = 1 }), Coach)
        assert.equals("up", ctx.dotState)
        assert.equals("edge", ctx.dotFrom)
        assert.is_true(ctx.dotRefreshable)
      end)

      it("an UNREADABLE frame read is no opinion — never 'the DoT is gone'", function()
        -- Secret or throwing.  It must not become the apply press; it hands over to the
        -- latch, and with no latch either the answer is `unknown` and L8 stays quiet.
        local ctx = ns.Specs[267]:Context(
          build({ dotFrame = "unreadable", shards = 1 }), Coach)
        assert.equals("unknown", ctx.dotState)
        assert.is_false(ctx.dotRefreshable)
        assert.are_not.equal(ID.IMMO, winner({ dotFrame = "unreadable", shards = 1 }).cid)
      end)

      it("reaches the brain from EITHER of Immolate's ids, like the latch", function()
        -- State keys `auraFrames` by base spellID and the signal can sit on the row that
        -- is not pressable, so the brain walks the same candidate list it walks for edges.
        local w = winner({ auraFramesRaw = { [ID.IMMO] = { capable = true,
                                                           unitReadable = true } },
                           immolateAsCast = true, shards = 1 })
        assert.equals(ID.IMMO_CAST, w.cid)
        assert.equals("not up", w.cue.note)
      end)
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

    --------------------------------------------------------------------------
    -- THE BEFORE/AFTER PAIR for the virtual CDM panel (docs/virtual-cdm-plan.md).
    -- The test above is the BEFORE: with no CDM row the list honestly returns nothing, and
    -- the live pass measured what that costs — 59 of 191 decision changes with no winner
    -- (31 %), every one at 0–2 shards.  These are the AFTER: State synthesises the row, and
    -- the floor is back.  Both stay; the pair IS the evidence.
    --------------------------------------------------------------------------
    it("a VIRTUAL Incinerate restores the floor at 1 shard", function()
      local w = winner({ shards = 1, virtualIncinerate = true })
      assert.equals(ID.INC, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)

    it("the Coach cannot tell a virtual row from a real one", function()
      -- The seam's whole claim: a synthesised row is JUST ANOTHER ability.  Same winner,
      -- same emphasis, same note as the tracked case at the same shard count.
      local real    = winner({ shards = 0 })
      local virtual = winner({ shards = 0, virtualIncinerate = true })
      assert.equals(real.cid, virtual.cid)
      assert.equals(real.cue.emphasis, virtual.cue.emphasis)
      assert.equals(real.cue.note, virtual.cue.note)
    end)

    it("an armed Infernal Bolt lights ON the virtual frame — the L12 payoff", function()
      -- The transform rides the Incinerate frame.  With no frame the whole priority line was
      -- dead; with a virtual one it can finally cue.
      local w = winner({ art = "infernal", shards = 1, virtualIncinerate = true })
      assert.equals(ID.INC, w.cid)
      assert.equals("Infernal Bolt — shard refill", w.cue.note)
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
  -- Hero tree + DoT identity (field-fix B) — the two things the first live session
  -- proved wrong.  THE LIVE CONFIGURATION IS THE FIXTURE: a real Hellcaller build
  -- that tracked Malevolence but IMMOLATE (not Wither), with Immolate on its CAST id
  -- 348.  The old code got both answers wrong on exactly this pulse — it inferred
  -- Diabolist from the absent Wither, and keyed L8 on 157736, which is not in
  -- `abilities` at all, so the DoT line could never fire.
  ----------------------------------------------------------------------------
  describe("hero tree + DoT identity", function()
    -- The live build, as observed 2026-07-30.
    local LIVE = { malevolence = cdFar(), immolateAsCast = true }
    local function live(extra)
      local f = {}
      for k, v in pairs(LIVE) do f[k] = v end
      for k, v in pairs(extra or {}) do f[k] = v end
      return f
    end
    local function contextOf(facts) return ns.Specs[267]:Context(build(facts), Coach) end

    ------------------------------------------------------------------------
    -- The pulse carries it.  `state.hero` is State's talent-API read, and it is
    -- AUTHORITATIVE — the brain never re-derives it when the pulse has an answer.
    ------------------------------------------------------------------------
    it("takes the hero tree from the PULSE: hellcaller", function()
      local ctx = contextOf(live({ shards = 1, hero = "hellcaller" }))
      assert.equals("hellcaller", ctx.hero)
      assert.is_true(ctx.hellcaller)
      assert.equals("talent API", ctx.heroHow)
    end)

    it("takes the hero tree from the PULSE: diabolist", function()
      local ctx = contextOf(live({ shards = 1, hero = "diabolist" }))
      assert.equals("diabolist", ctx.hero)
      assert.is_false(ctx.hellcaller)
    end)

    it("the PULSE overrides the tracked set — the exact field failure", function()
      -- Malevolence tracked, Wither NOT tracked, Immolate present, Ritual up: the
      -- structural inference answered "Diabolist" here, confidently and wrongly.
      assert.equals("hellcaller",
        contextOf(live({ shards = 1, ritual = true, hero = "hellcaller" })).hero)
    end)

    it("publishes the resolution for the driver to announce, never printing itself", function()
      local before = #H.printed
      local ctx = contextOf(live({ shards = 1, hero = "hellcaller" }))
      assert.equals("hellcaller|talent API", ns.Specs[267].heroResolution)
      assert.equals(ctx.hero .. "|" .. ctx.heroHow, ns.Specs[267].heroResolution)
      -- Context is PURE by contract: the chat line is HudDriver's job.
      assert.equals(before, #H.printed)
    end)

    ------------------------------------------------------------------------
    -- The inference path — used ONLY when the pulse carries no hero (State's read
    -- refused or is absent).  MULTI-signal, so either Hellcaller tell counts.
    ------------------------------------------------------------------------
    it("falls back to the inference when the pulse carries no hero", function()
      local ctx = contextOf(live({ shards = 1 }))
      assert.equals("hellcaller", ctx.hero)
      assert.equals("inferred from the tracked set", ctx.heroHow)
    end)

    it("infers Hellcaller from MALEVOLENCE alone (no Wither)", function()
      assert.equals("hellcaller", contextOf(live({ shards = 1 })).hero)
    end)

    it("infers Hellcaller from WITHER alone (no Malevolence)", function()
      assert.equals("hellcaller", contextOf({ hellcaller = true, shards = 1 }).hero)
    end)

    ------------------------------------------------------------------------
    -- EVERY alias id of an Art must arm it.  The brain used to branch on `abbr`, which
    -- forced all the Infernal Bolt ids to share one log code and left the decision log
    -- unable to say which numeric override the client actually surfaced.  Semantics moved
    -- to `art` so `abbr` could go per-id; these pin that the move is real — an alias id
    -- resolves to the same ctx frame as the primary, with a DIFFERENT abbr.
    ------------------------------------------------------------------------
    for _, case in ipairs({
      { id = 433891, art = "infernal",  abbr = "IB"  },
      { id = 434506, art = "infernal",  abbr = "IB2" },
      { id = 433885, art = "ruination", abbr = "RU"  },
      { id = 434635, art = "ruination", abbr = "RU2" },
      { id = 434636, art = "ruination", abbr = "RU3" },
    }) do
      it(("arms the %s Art from override id %d (abbr %s)"):format(case.art, case.id, case.abbr),
      function()
        local ctx = contextOf({ art = case.art, artID = case.id, shards = 1,
                                virtualIncinerate = (case.art == "infernal") })
        if case.art == "infernal" then
          assert.equals(ID.INC, ctx.ibFrame)
          assert.is_nil(ctx.ruinationFrame)
        else
          assert.equals(ID.CB, ctx.ruinationFrame)
          assert.is_nil(ctx.ibFrame)
        end
        -- The display code stays per-id, which is the whole point of the split.
        assert.equals(case.abbr, ns.SpecInfo(case.id).abbr)
      end)
    end

    it("infers Diabolist from an armed Ruination", function()
      assert.equals("diabolist", contextOf({ art = "ruination", shards = 1 }).hero)
    end)

    it("infers Diabolist from the Diabolic Ritual container", function()
      assert.equals("diabolist", contextOf({ ritual = true, shards = 1 }).hero)
    end)

    it("defaults to Diabolist on AMBIGUOUS signals, and says why", function()
      local ctx = contextOf(live({ ritual = true, shards = 1 }))
      assert.equals("diabolist", ctx.hero)
      assert.truthy(ctx.heroHow:find("defaulted", 1, true))
    end)

    it("defaults to Diabolist with NO signal at all, and says why", function()
      local ctx = contextOf({ shards = 1 })
      assert.equals("diabolist", ctx.hero)
      assert.truthy(ctx.heroHow:find("defaulted", 1, true))
    end)

    it("a defaulted resolution is published as defaulted, not laundered into 'talent API'",
    function()
      contextOf({ shards = 1 })
      assert.truthy(ns.Specs[267].heroResolution:find("defaulted", 1, true))
    end)

    ------------------------------------------------------------------------
    -- DoT identity: whichever id the pulse actually carries.
    ------------------------------------------------------------------------
    it("resolves the DoT to the CAST id when that is the pressable row", function()
      assert.equals(ID.IMMO_CAST, contextOf(live({ shards = 1 })).dotID)
    end)

    it("L8 targets the CAST id — the line the old key could never fire", function()
      local w = winner(live({ dot = "missing", shards = 1 }))
      assert.equals(ID.IMMO_CAST, w.cid)
      assert.equals("not up", w.cue.note)
    end)

    it("still prefers Wither when a Hellcaller build actually tracks it", function()
      assert.equals(ID.WITHER, contextOf({ hellcaller = true, shards = 1 }).dotID)
    end)

    it("still resolves the aura id when THAT is what a build tracks", function()
      assert.equals(ID.IMMO, contextOf({ shards = 1 }).dotID)
    end)

    it("hero and DoT are now INDEPENDENT — Hellcaller maintaining Immolate", function()
      local ctx = contextOf(live({ dot = "missing", shards = 1, hero = "hellcaller" }))
      assert.equals("hellcaller", ctx.hero)
      assert.equals(ID.IMMO_CAST, ctx.dotID)      -- the pairing the old code could not express
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
