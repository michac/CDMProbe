-- coach_retribution_apl_spec.lua — the Tier-1 ROTATION gate for RETRIBUTION PALADIN (70).
--
-- The independent oracle for CoachRetribution.lua.  Every expected winner / fallback / SOON
-- below is read FROM specs/retribution/rotation.md (the spec of record), never from
-- RankWinner — the same discipline coach_apl_spec.lua and coach_destruction_apl_spec.lua
-- apply to the two Warlock brains.  A suite transcribed from the source it tests is a
-- change-detector wearing a contract's clothes.
--
-- Caveat honored: coverage proves a branch FIRED, not that the branch is RIGHT.
-- rotation.md stays the authority for each line's expected press, and that document is
-- itself DESK-DERIVED (from the Tier-1 simc APL, not yet flown) — so these tests pin the
-- IMPLEMENTATION to the document, not the document to reality.
--
-- The list under test (specs/retribution/rotation.md; first usable line = the press):
--   L1   Execution Sentence   on cooldown
--   L2   Avenging Wrath       on cooldown
--   L3   the spender          at cap, UNLESS Wake of Ashes is ready
--   L4   Wake of Ashes        on cooldown
--   L5   Divine Toll          on cooldown
--   L6   Blade of Justice     on an Art of War / Righteous Cause proc
--   L7   the spender          hp >= cost
--   L8   Blade of Justice     on cooldown
--   L9   Hammer of Wrath      while wings are up
--   L10  Judgment             on cooldown
--   L11  the filler frame     (Crusader Strike / Templar Strike / Templar Slash)
--
-- ⚠ HAMMER OF LIGHT IS NOT A LINE.  It is the SPENDER CHOICE at L3 and L7: simc's
-- `hammer_of_light` heads `actions.finishers`, and the `divine_storm` / `templars_verdict`
-- entries under it are both gated `!buff.hammer_of_light_ready.up`, so "which finisher"
-- resolves to the hammer whenever one is armed.  This suite asserted it as an L1 above every
-- cooldown until 2026-08-03 — a bug it had faithfully transcribed from a rotation.md that
-- was itself wrong, which is exactly the failure mode an oracle authored from the document
-- cannot catch on its own.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

--------------------------------------------------------------------------------
-- Minimal State-pulse builder.  Every field the Retribution brain reads, nothing else.
--------------------------------------------------------------------------------
local NOW = 1000

-- `Enum.PowerType.HolyPower`, per the harness and the client (LuaEnum.lua:5681).  A cost
-- fixture is denominated in a RESOURCE, and using the wrong one is the whole defect this
-- file now pins — see the `SOUL_SHARDS` cases at the bottom.
local HOLY_POWER = 9
local SOUL_SHARDS = 7

-- Base spellIDs (SpecRetribution.SpecIDs).  The Coach consumes the DOMAIN VIEW keyed by base
-- spellID, so these ARE the cue keys.
local ID = {
  TV = 85256, DS = 53385, JUDG = 20271, CS = 35395, BOJ = 184575,
  WOA = 255937, ES = 343527, DT = 375576, AW = 31884, HOW = 24275,
  UTILITY = 96231,
  -- overrides (no icon of their own; they ride a tracked frame)
  HOL = 427453, FV = 383328, TSTRIKE = 407480,
  -- the two Hammer of Wrath ALIASES (24275 is the primary, above)
  HOW_ALT = 326730, HOW_TALENT = 1241288,
  -- buffs
  AOW = 406064, RC = 402912, EP = 326732, EL = 387170, LD = 433674,
  CRUSADE = 1253598,
}

-- Distinct cooldownID display handles, decoupled from spellIDs as in a live pulse.
local CID = {
  TV = 7001, DS = 7002, JUDG = 7003, CS = 7004, BOJ = 7005, WOA = 7006,
  ES = 7007, DT = 7008, AW = 7009, HOW = 7010, UTILITY = 7011,
}

-- cd sub-tables per the 3-state contract (state + a trust `source`).
local function cdReady(age)    return { state = "ready", readable = true, source = "live", changedAt = NOW - (age or 2) } end
local function cdSoon(n)       return { state = "on-cooldown", remaining = n, readable = false, source = "napkin", changedAt = NOW - 1 } end
local function cdFar()         return { state = "on-cooldown", remaining = 30, readable = false, source = "napkin", changedAt = NOW - 1 } end
local function cdUnknown()     return { state = "unknown", readable = false, source = "none" } end

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
    glow = { active = extra.glow or false, readable = true },
    display = { cooldownID = cid, category = category },
  }
end

-- Build a pulse from high-level facts.  Cooldown-bearing abilities default to cdFar (not
-- usable — the safe reading); the spenders are always present with an `unknown` cd, since
-- their gate is cost, never readiness.
--   hp                the live Holy Power (0-5).  modifier 1, so no unit games.
--   hpMax             override the cap (default 5)
--   inflightSpender   put the spender in flight, so `projected = hp - cost`
--   hol "tv"|"ds"     which tracked spender frame shows the Hammer of Light override
--   fv                show the Final Verdict override on the TV frame instead
--   execution/wings/woa/toll/boj/judgment/how/filler   a cd sub-table
--   csCharge          a `charge` sub-table on the filler frame (2 charges, category 1627)
--   bojCharge         a `charge` sub-table on Blade of Justice
--   aow/rc/ep/el/ld   buff presence
--   mode "st"|"aoe"   the manual target-mode toggle
--   targetHp          target health percent (nil = no target channel, today's reality)
--   noWings           omit Avenging Wrath entirely (the Radiant Glory build)
--   noHow             omit Hammer of Wrath (today's reality — it is not in the tracked set)
--   noStorm           omit Divine Storm
--   spenderCost       the LIVE cost ns.ShardCost reports (default: none => the fallback 3)
--   hero              the pulse's hero tree
local function build(f)
  f = f or {}
  local abilities = {}

  -- Cooldown-bearing rotation buttons.
  abilities[ID.ES]   = ability(ID.ES,   CID.ES,   f.execution or cdFar())
  abilities[ID.DT]   = ability(ID.DT,   CID.DT,   f.toll or cdFar())
  abilities[ID.WOA]  = ability(ID.WOA,  CID.WOA,  f.woa or cdFar())
  abilities[ID.BOJ]  = ability(ID.BOJ,  CID.BOJ,  f.boj or cdFar(), { charge = f.bojCharge })
  abilities[ID.JUDG] = ability(ID.JUDG, CID.JUDG, f.judgment or cdFar())
  abilities[ID.CS]   = ability(ID.CS,   CID.CS,   f.filler or cdFar(), { charge = f.csCharge })
  if not f.noWings then abilities[ID.AW] = ability(ID.AW, CID.AW, f.wings or cdFar()) end
  -- `howID` puts a DIFFERENT Hammer of Wrath candidate on the board (24275 / 326730 /
  -- 1241288), which is what exercises the brain's candidate walk rather than a constant.
  if not f.noHow then
    local hid = f.howID or ID.HOW
    abilities[hid] = ability(hid, CID.HOW, f.how or cdFar())
  end

  -- The spenders: no cooldown at all, gated only by Holy Power.  The OVERRIDE rides one of
  -- these frames — that is the entire readable channel for Hammer of Light.
  local tvExtra, dsExtra = {}, {}
  if f.hol == "tv" then tvExtra = { override = ID.HOL, live = ID.HOL } end
  if f.hol == "ds" then dsExtra = { override = ID.HOL, live = ID.HOL } end
  if f.fv then tvExtra = { override = ID.FV, live = ID.FV } end
  abilities[ID.TV] = ability(ID.TV, CID.TV, cdUnknown(), tvExtra)
  if not f.noStorm then abilities[ID.DS] = ability(ID.DS, CID.DS, cdUnknown(), dsExtra) end

  if f.utility then
    abilities[ID.UTILITY] = ability(ID.UTILITY, CID.UTILITY, f.utility, { category = "Utility" })
  end

  -- Buff PRESENCE — spellID-keyed, exactly as State's domain view emits it.  ⚠ Presence
  -- only: every Retribution proc has a secret stack count and a secret duration.
  local buffs = {}
  if f.aow then buffs[ID.AOW] = true end
  if f.rc  then buffs[ID.RC]  = true end
  if f.ep  then buffs[ID.EP]  = true end
  if f.el  then buffs[ID.EL]  = true end
  if f.ld  then buffs[ID.LD]  = true end
  if f.wingsUp then buffs[ID.AW] = true end
  if f.crusadeUp then buffs[ID.CRUSADE] = true end

  -- The live spender cost, driven at CLIENT level (`fx.powerCost` fakes
  -- `C_Spell.GetSpellPowerCost`), so the shipping `ns.PowerCost` ladder runs for real.
  -- ⚠ ASSIGNED UNCONDITIONALLY, INCLUDING nil.  `H.fx` is minted once per test, not once per
  -- build, so a `spenderCost` set by an earlier build() in the SAME test would leak into the
  -- next one — and the leak is invisible, because a stale cost still produces a plausible
  -- press.  Clearing here is what lets one test compare "the client's cost" against "the
  -- fallback" on two consecutive pulses.
  -- ⚠ DRIVEN THROUGH `powerCost`, THE CLIENT-LEVEL FAKE, not the old `fx.cost` ShardCost
  -- stub — so the shipping type filter runs and a fixture cost has to be denominated in the
  -- resource the brain actually asks about.  `f.spenderCost = nil` now means what it says
  -- in game: the client offers NO Holy Power entry, the read refuses, and the brain must
  -- fall back to its declared 3 rather than treating the absence as free.
  local function setCost(id, cost)
    H.fx.powerCost[id] = cost ~= nil
      and { { type = HOLY_POWER, cost = cost, name = "HOLY_POWER" } } or nil
  end
  setCost(ID.TV, f.spenderCost)
  setCost(ID.DS, f.spenderCost)

  -- The IN-FLIGHT projection.  Since roster-state-plan Phase 6 the pulse does not carry it —
  -- the Coach derives it from cast history via ns.SpecPowerDelta.  So the fixture drives the
  -- REAL path: an in-flight spender ('start' with no terminal phase), placed outside
  -- CAST_FRESH (1.0) but inside the flight window (3.0) so it is in flight without also
  -- raising the cast_started EDGE (a different question, tested elsewhere).
  local history = {}
  if f.inflightSpender then
    -- ⚠ A COST IS REQUIRED FOR A PROJECTION TO EXIST.  SpecPowerDelta reads the cost and
    -- declines (delta 0) when the client has no answer — the documented safe direction, since
    -- it never pre-deducts power we are not sure will be spent.  So an in-flight spender with
    -- no readable cost projects NOTHING, and a fixture that forgot this would be asserting
    -- the refusal path while believing it was asserting the projection.
    setCost(ID.TV, f.spenderCost or 3)
    history[#history + 1] = { phase = "start", spellID = ID.TV, base = ID.TV, at = NOW - 2 }
  end

  -- ⚠ HOLY POWER'S MODIFIER IS 1, so the exact rail and the display rail are the SAME
  -- integer.  This is the fixture's cheapest statement of the fact that none of Destruction's
  -- fragment arithmetic applies here: `unmodified` == `value`, `unmodifiedMax` == `max`.
  -- `f.exactRefused` drops the exact read, exercising the value x modifier fallback (which,
  -- at modifier 1, must produce the identical number).
  local hp, hpMax = f.hp or 0, f.hpMax or 5
  local bar = { value = hp, max = hpMax, readable = true }
  if not f.exactRefused then
    bar.unmodified, bar.unmodifiedMax, bar.modifier = hp, hpMax, 1
  end

  return {
    at = NOW, combat = (f.combat ~= false), combatStartedAt = NOW - 60,
    mode = f.mode or "st",
    hero = f.hero,
    power = { HolyPower = bar },
    buffs = buffs,
    history = history,
    abilities = abilities,
    target = f.targetHp and { healthPct = f.targetHp } or nil,
  }
end

--------------------------------------------------------------------------------
-- Guidance readers (identical contract to the other two oracles).
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
describe("Retribution rotation list (from specs/retribution/rotation.md)", function()
  local ns, Coach
  before_each(function()
    ns = H.fresh()
    -- The harness activates Demonology by default; drive spec 70 through the REAL resolver
    -- (index 4 -> 70), exactly as a live respec would.
    H.setSpecIndex(4)
    ns.ResolveActiveSpec()
    H.load("Coach.lua")
    -- ⚠ WIRED WITH THE COST READER, exactly as the live driver does (`HudDriver.lua`).
    -- Without it `env.powerCostFn` is nil and every cost silently falls back to the spec's
    -- constant, so the "resolved live, never hardcoded" rule would be untested — the fixture
    -- would agree with the fallback whatever the client said.
    --
    -- ⚠⚠ AND IT MUST BE THE **REAL** `ns.PowerCost`, NOT THE HARNESS'S ShardCost STUB.  This
    -- file wired `{ shardCost = ns.ShardCost }` until 2026-08-03 and its comment claimed
    -- that "exercises the REAL cost path, not a shortcut".  It did not: `mock_ns.lua`
    -- REPLACES `ns.ShardCost` with a fixture lookup that has no type filter and answers nil
    -- where the shipping reader answered 0.  So the one behaviour that mattered — what the
    -- brain does when the client gives it no cost for its resource — was unreachable, and 76
    -- green cases sat over a HUD that cued Final Verdict at 0 Holy Power.  `ns.PowerCost` is
    -- NOT stubbed by the harness, so driving `fx.powerCost` runs the shipping ladder: the
    -- type filter, the secret guards and the three-valued return.
    Coach = ns.Coach.New({ powerCost = ns.PowerCost, shardCost = ns.ShardCost })
  end)

  local function guidance(facts) return Coach:Compute(build(facts)) end
  local function winner(facts) return pressOf(guidance(facts)) end

  ----------------------------------------------------------------------------
  it("activates spec 70 with the Retribution data bound", function()
    assert.equals(ns.Specs[70], ns.ActiveSpec)
    assert.equals(ID.TV, ns.SpecIDs.TEMPLARS_VERDICT)
    assert.equals(ID.HOL, ns.SpecIDs.HAMMER_OF_LIGHT)
    -- The dormant Tier-3 fields Demonology carries are deliberately absent here.
    assert.is_nil(ns.SpecOpener)
    assert.is_nil(ns.SpecBurst)
  end)

  ----------------------------------------------------------------------------
  -- The resource rail: TRACKED, and deliberately NOT DRAWN (D1).
  ----------------------------------------------------------------------------
  describe("Holy Power rides the whole rail with display = \"none\"", function()
    it("emits exactly one resourceBar, marked `none`", function()
      local bars = guidance({ hp = 3 }).resourceBars
      assert.equals(1, #bars)
      assert.equals("none", bars[1].display)
      assert.equals("HOLY_POWER", bars[1].powerType)
    end)

    -- THE WHOLE POINT of `none` over an empty spec.powers: the numbers still reach the
    -- decision log's PW: column.  An empty powers array would emit no bar and PW: would
    -- render `?/?` for the entire spec — losing the primary instrument for debugging a brain
    -- nobody can watch live.
    it("carries real numbers, not a placeholder", function()
      local bar = guidance({ hp = 3, hpMax = 5 }).resourceBars[1]
      assert.equals(3, bar.value)
      assert.equals(5, bar.max)
      assert.equals(3, bar.valueExact)
      assert.equals(1, bar.modifier)
    end)

    -- Holy Power's modifier is 1, so the fallback path (display x modifier) must produce the
    -- SAME number the exact read would have.  This is the case that would catch a stray
    -- Destruction-style x10 conversion copied into this spec.
    it("reads the same value when the exact rail refuses (modifier 1)", function()
      local w = winner({ hp = 3, exactRefused = true })
      assert.equals(ID.TV, w.cid)          -- 3 >= the fallback cost of 3: it spends
      local w2 = winner({ hp = 2, exactRefused = true })
      assert.is_nil(w2)                    -- ...and 2 does not
    end)

    -- ⚠ THE END OF THE CHAIN, and the reason `none` exists at all.  D1's whole argument is
    -- that an empty `spec.powers` would emit no bar and DecisionLog's `PW:` would render
    -- `?/?` for the entire spec — losing the one instrument that can explain a decision
    -- nobody watched.  Asserting the bar is not enough; this asserts the COLUMN.
    it("reaches the decision log's PW column as real numbers, not `?/?`", function()
      H.load("DecisionLog.lua")
      local pulse = build({ hp = 3, woa = cdFar() })
      local line = ns.DecisionLog.Render(pulse, Coach:Compute(pulse), { cues = {} })
      assert.is_truthy(line:match("PW:3/%+0"), "PW column read: " .. tostring(line:match("PW:%S+")))
    end)
  end)

  ----------------------------------------------------------------------------
  -- L1 — Hammer of Light, whenever armed.
  ----------------------------------------------------------------------------
  describe("Hammer of Light — the spender CHOICE, not a line", function()
    -- ⚠ THE CORRECTION OF 2026-08-03.  `actions.cooldowns` (execution_sentence,
    -- avenging_wrath) is called BEFORE `actions.generators`, and `finishers` — where
    -- hammer_of_light lives — is only ever entered FROM generators.  So an armed hammer does
    -- NOT outrank the burst buttons; it only decides which finisher the spend lines press.
    it("does NOT outrank Execution Sentence or Avenging Wrath", function()
      local w = winner({ hp = 5, hol = "tv", execution = cdReady(), wings = cdReady() })
      assert.equals(ID.ES, w.cid)
      local w2 = winner({ hp = 5, hol = "tv", execution = cdFar(), wings = cdReady() })
      assert.equals(ID.AW, w2.cid)
    end)

    it("IS the spender once the cooldowns are down — at cap (L3)", function()
      local w = winner({ hp = 5, hol = "tv", woa = cdFar(), toll = cdReady() })
      assert.equals(ID.TV, w.cid)          -- keyed by the BASE frame it rides
      assert.equals("Hammer of Light", w.cue.note)
    end)

    it("...and at the ordinary spend line (L7)", function()
      local w = winner({ hp = 3, hol = "tv" })
      assert.equals(ID.TV, w.cid)
      assert.equals("Hammer of Light", w.cue.note)
    end)

    -- ⚠ It OUTRANKS the ordinary finishers, which is simc's
    -- `!buff.hammer_of_light_ready.up` gate on divine_storm/templars_verdict: while a hammer
    -- is armed, no plain finisher may be pressed.  So even in AoE mode with the Divine Storm
    -- conditions met, an armed hammer on the TV frame is the press.
    it("suppresses Divine Storm while it is armed", function()
      local w = winner({ hp = 3, hol = "tv", mode = "aoe" })
      assert.equals(ID.TV, w.cid)
      assert.equals("Hammer of Light", w.cue.note)
    end)

    -- It costs 3 Holy Power like every finisher, so affordability still gates it.
    it("does not fire when the spender is unaffordable", function()
      local w = winner({ hp = 2, hol = "tv", execution = cdReady() })
      assert.equals(ID.ES, w.cid)
    end)

    it("rides the Divine Storm frame just as well", function()
      local w = winner({ hp = 5, hol = "ds", woa = cdFar(), toll = cdReady() })
      assert.equals(ID.DS, w.cid)
    end)

    -- The Final Verdict override is NOT Hammer of Light: same frame, different `spender`.
    -- The brain keys on the semantic field, so a transformed-but-not-HoL frame must fall
    -- through to the ordinary spender lines.
    it("is not armed by the Final Verdict override (a different `spender`)", function()
      local w = winner({ hp = 5, fv = true, execution = cdReady() })
      assert.equals(ID.ES, w.cid)          -- L2, not L1
    end)

    -- RET_HOL_FROM_BUFF, the spec's one parked switch, defaults OFF.
    it("is NOT armed by the Light's Deliverance buff alone (switch defaults off)", function()
      local w = winner({ hp = 5, ld = true, execution = cdReady() })
      assert.equals(ID.ES, w.cid)
    end)

    -- ⚠ AND FLIPPING IT ON IS A TRAP, measured: Light's Deliverance is a 60-STACK buff
    -- (`SpellAuraOptions.CumulativeAura` = 60 @ 12.0.7).  It is present for essentially the
    -- whole fight and only the 60th stack grants the free hammer — a count that is a Secret
    -- Value in combat.  So the switch can never be safely turned on, and this case exists to
    -- document the behaviour, not to endorse it.
    it("IS armed by the buff once RET_HOL_FROM_BUFF is flipped on (documented, not endorsed)", function()
      ns.Specs[70].RET_HOL_FROM_BUFF = true
      local w = winner({ hp = 5, ld = true, woa = cdFar(), toll = cdReady() })
      assert.equals(ID.TV, w.cid)
      assert.equals("Hammer of Light", w.cue.note)
      ns.Specs[70].RET_HOL_FROM_BUFF = false
    end)
  end)

  ----------------------------------------------------------------------------
  -- A FREE spender — the `cost == 0` fix.
  ----------------------------------------------------------------------------
  -- ⚠ The guard used to read `type(c) == "number" and c > 0`, so a genuinely free finisher
  -- (Divine Purpose, an Empyrean Power Divine Storm, a Light's Deliverance hammer) reported 0,
  -- was mistaken for "unreadable", and fell through to the fallback of 3 — refusing to cue a
  -- free press at 0-2 Holy Power, exactly when it is worth most.  This is the project's own
  -- ABSENT-IS-NEVER-ZERO rule run in reverse.
  describe("a free spender (cost 0)", function()
    it("is cued at ZERO Holy Power", function()
      local w = winner({ hp = 0, spenderCost = 0 })
      assert.equals(ID.TV, w.cid)
    end)

    it("still respects a real cost on the same fixture", function()
      assert.is_nil(winner({ hp = 0, spenderCost = 3 }))
    end)
  end)

  ----------------------------------------------------------------------------
  -- THE DEFECT THAT SHIPPED — an UNREADABLE cost must never read as FREE.
  ----------------------------------------------------------------------------
  -- ⚠ THIS IS THE BLOCK THE 2026-08-03 FLIGHT BOUGHT, and the reason the other 76 cases
  -- could not have caught it.  Every one of them SETS a cost, so all of them exercised the
  -- happy path; the shipped bug lived entirely in what happens when the client offers no
  -- cost for the resource we asked about.  In game that was the normal case, not an edge:
  -- the shell wired the SOUL-SHARD-filtered reader for every spec, so no Paladin spender
  -- ever matched, `ns.PowerCost` answered 0-for-absent, `costOf` took the 0 as a fact, and
  -- L7's `projected >= cost` became `projected >= 0` — a tautology.  Result: Final Verdict
  -- won at 0 Holy Power on 95 lines of one flight, with 274 more at 1 and 429 at 2.
  --
  -- The rule these pin, in one line: A COST WE CANNOT READ MUST FALL BACK TO THE DECLARED
  -- CONSTANT, NEVER TO ZERO.  Under-promising costs a press of latency; over-promising cues
  -- a button that cannot be pressed, which is the failure this project cares most about.
  describe("an UNREADABLE spender cost (the v0.32.87 defect)", function()
    -- The direct reproduction: the client has no Holy Power entry for the spender.
    it("falls back to the declared 3 — no spender below 3 Holy Power", function()
      assert.is_nil(winner({ hp = 0, spenderCost = nil }))
      assert.is_nil(winner({ hp = 1, spenderCost = nil }))
      assert.is_nil(winner({ hp = 2, spenderCost = nil }))
    end)

    it("and still cues the spender AT the fallback cost", function()
      local w = winner({ hp = 3, spenderCost = nil })
      assert.equals(ID.TV, w.cid)
    end)

    -- THE ORIGINAL MIS-WIRING, pinned directly: a cost denominated in SOMEONE ELSE'S
    -- resource is not this spec's cost.  `ns.PowerCost`'s type filter must reject it and the
    -- brain must fall back — never read the non-match as free.  This is the exact shape
    -- `ns.ShardCost` produced for every Paladin spell.
    it("rejects a cost denominated in a DIFFERENT resource", function()
      local f = { hp = 0 }
      local g = build(f)
      H.fx.powerCost[ID.TV] = { { type = SOUL_SHARDS, cost = 2, name = "SOUL_SHARDS" } }
      H.fx.powerCost[ID.DS] = { { type = SOUL_SHARDS, cost = 2, name = "SOUL_SHARDS" } }
      assert.is_nil(pressOf(Coach:Compute(g)))
    end)

    -- A SECRET cost is the worst case of all: the state where we know least would otherwise
    -- promise the cheapest possible press.
    it("treats a SECRET cost as unreadable, not as free", function()
      local f = { hp = 0 }
      local g = build(f)
      H.fx.powerCost[ID.TV] = { { type = HOLY_POWER, cost = H.secretValue(), name = "HP" } }
      H.fx.powerCost[ID.DS] = { { type = HOLY_POWER, cost = H.secretValue(), name = "HP" } }
      assert.is_nil(pressOf(Coach:Compute(g)))
    end)
  end)

  ----------------------------------------------------------------------------
  -- The resource a cost is asked about is RESOLVED FROM THE SPEC, not hardcoded.
  ----------------------------------------------------------------------------
  -- ns.Coach.CostPowerType is the seam that replaced the Soul-Shard hardwire.  If it ever
  -- silently returns nil for this spec, every cost degrades to the fallback and the "resolved
  -- live" rule quietly stops holding — green tests, dead feature.  So pin it directly.
  describe("ns.Coach.CostPowerType", function()
    it("resolves Holy Power for spec 70, off the spec's own powers block", function()
      assert.equals(HOLY_POWER, ns.Coach.CostPowerType(ns.ActiveSpec))
    end)

    it("prefers an entry explicitly flagged costPower over the first declared", function()
      local fake = { powers = { { name = "SoulShards" }, { name = "HolyPower", costPower = true } } }
      assert.equals(HOLY_POWER, ns.Coach.CostPowerType(fake))
    end)

    it("refuses (nil) rather than guessing when nothing resolves", function()
      assert.is_nil(ns.Coach.CostPowerType({ powers = { { name = "NotAResource" } } }))
      assert.is_nil(ns.Coach.CostPowerType({}))
      assert.is_nil(ns.Coach.CostPowerType(nil))
    end)
  end)

  ----------------------------------------------------------------------------
  -- L2 / L3 — the two on-cooldown burst lines.
  ----------------------------------------------------------------------------
  describe("L2 — Execution Sentence", function()
    it("wins on cooldown, above Avenging Wrath", function()
      assert.equals(ID.ES, winner({ execution = cdReady(), wings = cdReady() }).cid)
    end)

    -- The napkin's "probably up" is ROTATION-eligible, not "never" — the shell's contract.
    it("fires on a probably-up napkin read", function()
      local probably = { state = "on-cooldown", remaining = 0, readable = false,
                         source = "napkin", changedAt = NOW - 2 }
      assert.equals(ID.ES, winner({ execution = probably }).cid)
    end)

    it("steps aside when it is on cooldown", function()
      assert.equals(ID.AW, winner({ execution = cdFar(), wings = cdReady() }).cid)
    end)
  end)

  describe("L3 — Avenging Wrath", function()
    it("wins on cooldown", function()
      assert.equals(ID.AW, winner({ wings = cdReady() }).cid)
    end)

    -- THE RADIANT GLORY DEGRADATION, and it is free: on that build the button does not
    -- exist, the line finds nothing tracked, and evaluation continues.  No talent read.
    it("simply finds nothing on a build with no Avenging Wrath button", function()
      local w = winner({ noWings = true, woa = cdReady() })
      assert.equals(ID.WOA, w.cid)         -- straight through to L5
    end)
  end)

  ----------------------------------------------------------------------------
  -- L4 — spend at cap, UNLESS Wake of Ashes is ready.
  ----------------------------------------------------------------------------
  describe("L4 — the anti-overcap dump", function()
    it("spends at cap when Wake of Ashes is on cooldown", function()
      local w = winner({ hp = 5, woa = cdFar(), toll = cdReady() })
      assert.equals(ID.TV, w.cid)
      assert.equals("at cap", w.cue.note)
      -- ...and it outranks Divine Toll, which sits at L6.
    end)

    -- ⚠ THE CLAUSE THAT IS NOT A DETAIL.  At cap with Wake of Ashes READY you press WoA
    -- anyway, because WoA ARMS HAMMER OF LIGHT and the armed spender is worth more than the
    -- overcap.  simc: `if=holy_power=5&cooldown.wake_of_ashes.remains`.
    it("YIELDS to Wake of Ashes at cap — WoA arms Hammer of Light", function()
      local w = winner({ hp = 5, woa = cdReady() })
      assert.equals(ID.WOA, w.cid)
    end)

    it("does not fire below cap", function()
      local w = winner({ hp = 4, woa = cdFar(), toll = cdReady() })
      assert.equals(ID.DT, w.cid)          -- L6 wins; the spender waits for L8
    end)

    -- The cap is read off the PULSE, not assumed to be 5.
    it("respects a cap the pulse reports", function()
      local w = winner({ hp = 4, hpMax = 4, woa = cdFar(), toll = cdReady() })
      assert.equals(ID.TV, w.cid)
      assert.equals("at cap", w.cue.note)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L5 / L6 — the remaining on-cooldown builders.
  ----------------------------------------------------------------------------
  it("L5 — Wake of Ashes on cooldown", function()
    assert.equals(ID.WOA, winner({ woa = cdReady(), toll = cdReady() }).cid)
  end)

  it("L6 — Divine Toll on cooldown", function()
    assert.equals(ID.DT, winner({ toll = cdReady(), boj = cdReady(), aow = true }).cid)
  end)

  ----------------------------------------------------------------------------
  -- L7 — Blade of Justice on a proc.
  ----------------------------------------------------------------------------
  describe("L7 — procced Blade of Justice", function()
    it("fires on Art of War", function()
      local w = winner({ hp = 3, boj = cdReady(), aow = true, woa = cdFar() })
      assert.equals(ID.BOJ, w.cid)
      assert.equals("Art of War", w.cue.note)
    end)

    it("fires on Righteous Cause", function()
      local w = winner({ hp = 3, boj = cdReady(), rc = true, woa = cdFar() })
      assert.equals(ID.BOJ, w.cid)
      assert.equals("Righteous Cause", w.cue.note)
    end)

    -- ⚠ IT SITS BELOW THE AT-CAP DUMP.  At a FULL bar with Wake of Ashes on cooldown, L4
    -- takes the press even though a free Blade of Justice is sitting there — because the
    -- Holy Power about to be wasted is worth more than the proc.  This is the ordering that
    -- is easiest to get backwards, so it is pinned in both directions.
    it("yields to the at-cap dump at a full bar", function()
      local w = winner({ hp = 5, boj = cdReady(), aow = true, woa = cdFar(), toll = cdFar() })
      assert.equals(ID.TV, w.cid)
      assert.equals("at cap", w.cue.note)
    end)

    it("...but takes the press one Holy Power below cap", function()
      local w = winner({ hp = 4, boj = cdReady(), aow = true, woa = cdFar(), toll = cdFar() })
      assert.equals(ID.BOJ, w.cid)
      assert.equals("Art of War", w.cue.note)
    end)

    it("does not fire without a proc", function()
      local w = winner({ hp = 0, boj = cdReady() })
      assert.equals(ID.BOJ, w.cid)         -- L10 catches it instead, with no note
      assert.is_nil(w.cue.note)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L8 — the main spend, and WHICH spender.
  ----------------------------------------------------------------------------
  describe("L8 — the spender", function()
    it("spends Templar's Verdict in single-target", function()
      local w = winner({ hp = 3 })
      assert.equals(ID.TV, w.cid)
      assert.is_nil(w.cue.note)
    end)

    it("holds below the cost", function()
      assert.is_nil(winner({ hp = 2 }))
    end)

    it("spends Divine Storm in AoE mode", function()
      local w = winner({ hp = 3, mode = "aoe" })
      assert.equals(ID.DS, w.cid)
      assert.equals("Divine Storm", w.cue.note)
    end)

    -- simc's `variable.ds_castable`: an Empyrean Power proc flips a single-target press into
    -- Divine Storm, because the proc makes it free.
    it("spends Divine Storm on an Empyrean Power proc even in single-target", function()
      assert.equals(ID.DS, winner({ hp = 3, ep = true }).cid)
    end)

    -- ...and Empyrean Legacy SUPPRESSES it: it makes the next Templar's Verdict cleave, so
    -- the Verdict is the AoE press.  `& !buff.empyrean_legacy.up` in simc.
    it("Empyrean Legacy suppresses Divine Storm, even in AoE mode", function()
      assert.equals(ID.TV, winner({ hp = 3, mode = "aoe", el = true }).cid)
      assert.equals(ID.TV, winner({ hp = 3, ep = true, el = true }).cid)
    end)

    -- Degradation: an untracked Divine Storm must not cost us the press entirely.
    it("falls back to Templar's Verdict when Divine Storm is untracked", function()
      assert.equals(ID.TV, winner({ hp = 3, mode = "aoe", noStorm = true }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- The LIVE cost — never hardcoded at a call site.
  ----------------------------------------------------------------------------
  describe("the spender cost is resolved live", function()
    -- ⚠ This is the case that proves the cost is READ, not assumed.  With the fallback (3),
    -- 4 Holy Power spends; with the client reporting 5, it must not.
    it("uses the client's cost over the fallback", function()
      assert.is_nil(winner({ hp = 4, spenderCost = 5 }))
      assert.equals(ID.TV, winner({ hp = 4 }).cid)   -- same pulse, fallback cost of 3
    end)

    it("still spends at the client's higher cost once the bar reaches it", function()
      local w = winner({ hp = 5, spenderCost = 5, woa = cdFar() })
      assert.equals(ID.TV, w.cid)
    end)

    it("falls back to 3 when the client has no answer", function()
      assert.equals(ID.TV, winner({ hp = 3 }).cid)
      assert.is_nil(winner({ hp = 2 }))
    end)
  end)

  ----------------------------------------------------------------------------
  -- The in-flight projection — a spender mid-cast must not be re-cued.
  ----------------------------------------------------------------------------
  describe("the in-flight projection", function()
    it("subtracts an in-flight spender, so L8 does not re-cue it", function()
      -- 3 Holy Power with a spender already in flight projects to 0.
      assert.is_nil(winner({ hp = 3, inflightSpender = true }))
    end)

    it("still spends when the projection clears the cost", function()
      -- 5 in the bar, 3 committed => 2 projected: short of the 3-cost, so no press.
      assert.is_nil(winner({ hp = 5, inflightSpender = true, woa = cdFar() }))
      -- ...and without the in-flight cast the same bar dumps at cap.
      assert.equals(ID.TV, winner({ hp = 5, woa = cdFar() }).cid)
    end)

    -- ⚠ NO PROJECTION WITHOUT A READABLE COST.  SpecPowerDelta declines rather than guessing,
    -- which is the safe direction: it never pre-deducts power we are not sure will be spent.
    it("projects nothing when the cost is unreadable", function()
      local ctx = ns.Specs[70]:Context(build({ hp = 3 }), Coach)
      assert.equals(0, ctx.hpIncoming)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L9 — Hammer of Wrath, and its half-readable gate.
  ----------------------------------------------------------------------------
  describe("L9 — Hammer of Wrath", function()
    it("fires while Avenging Wrath is up", function()
      local w = winner({ hp = 0, how = cdReady(), wingsUp = true, wings = cdFar() })
      assert.equals(ID.HOW, w.cid)
      assert.equals("wings", w.cue.note)
    end)

    -- ⚠ THE ORDERING CASE THAT WAS MISSING, and its absence is why the L8/L9 inversion
    -- survived review: every Hammer of Wrath case left Blade of Justice on cooldown, so the
    -- relative order was never exercised.  simc's generator tail is
    -- `hammer_of_wrath,if=talent.walk_into_light` / `blade_of_justice` / `hammer_of_wrath`,
    -- and we cannot read the talent — so we take the LOWER placement, and BLADE OF JUSTICE
    -- WINS when both are up.  (The code had this backwards, contradicting its own
    -- rotation.md Deviation 5, until 2026-08-03.)
    it("sits BELOW a ready Blade of Justice", function()
      local w = winner({ hp = 0, how = cdReady(), boj = cdReady(), wingsUp = true,
                         wings = cdFar() })
      assert.equals(ID.BOJ, w.cid)
    end)

    -- CRUSADE counts as wings.  It is the Avenging Wrath alternative, and `wingsUp` is the
    -- ONLY readable half of this line's gate — so reading 31884 alone would leave L9
    -- permanently dark on that build.
    it("fires on CRUSADE too, not just Avenging Wrath", function()
      local w = winner({ hp = 0, how = cdReady(), crusadeUp = true, wings = cdFar() })
      assert.equals(ID.HOW, w.cid)
      assert.equals("wings", w.cue.note)
    end)

    -- ⚠ WHICH Hammer of Wrath id.  Three exist and they are not interchangeable; the brain
    -- resolves whichever the pulse actually carries (the ctx.dotID pattern).  Before this,
    -- notes.md claimed "whichever the client surfaces resolves the same cue" and nothing
    -- implemented it — so a client surfacing the talent-node id would have killed the line.
    it("resolves whichever candidate ID the pulse actually carries", function()
      local w = winner({ hp = 0, howID = ID.HOW_TALENT, how = cdReady(), wingsUp = true,
                         wings = cdFar() })
      assert.equals(ID.HOW_TALENT, w.cid)
    end)

    -- ⚠ Deviation 4: outside wings we MISS the press rather than making a wrong one.  Target
    -- health is not on the pulse at all, so the execute half is structurally unreachable.
    it("stays silent outside wings, even when it is off cooldown", function()
      local w = winner({ hp = 0, how = cdReady(), boj = cdFar(), judgment = cdReady() })
      assert.equals(ID.JUDG, w.cid)        -- L11, not L9
    end)

    -- ...and the execute half is written against the shape a target channel WOULD take, so
    -- it is already correct the day State grows one.
    it("would fire in execute range once a target channel exists", function()
      local w = winner({ hp = 0, how = cdReady(), targetHp = 15 })
      assert.equals(ID.HOW, w.cid)
      assert.equals("execute", w.cue.note)
    end)

    it("is simply absent when Hammer of Wrath has no row at all (today's reality)", function()
      local w = winner({ hp = 0, noHow = true, wingsUp = true, wings = cdFar(),
                         judgment = cdReady() })
      assert.equals(ID.JUDG, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L10 / L11 / L12 — the floor.
  ----------------------------------------------------------------------------
  it("L10 — Blade of Justice on cooldown, no proc", function()
    local w = winner({ hp = 0, boj = cdReady(), judgment = cdReady() })
    assert.equals(ID.BOJ, w.cid)
    assert.is_nil(w.cue.note)
  end)

  it("L11 — Judgment on cooldown", function()
    assert.equals(ID.JUDG, winner({ hp = 0, judgment = cdReady(), filler = cdReady() }).cid)
  end)

  it("L12 — the filler frame is the floor", function()
    assert.equals(ID.CS, winner({ hp = 0, filler = cdReady() }).cid)
  end)

  -- Honest silence: every builder on cooldown and not enough Holy Power to spend is a REAL
  -- state, not a bug.  It shows in the decision log as `w:-`.
  it("returns no press when nothing is castable", function()
    assert.is_nil(winner({ hp = 2 }))
  end)

  ----------------------------------------------------------------------------
  -- CHARGES — the count outranks the cooldown read.
  ----------------------------------------------------------------------------
  -- This is the rule a live pass once found the HUD violating on 190 of 194 log lines
  -- (Conflagrate cued at zero charges).  On Retribution it matters far more: SIX of the nine
  -- Essential buttons keep their cooldown on a SpellCategory with RecoveryTime = 0, so the
  -- napkin is blind on them and the CDM's charge-restore `Available` edge can latch `ready`
  -- forever.
  describe("charge-aware readiness", function()
    it("a banked charge is usable even while the recharge runs", function()
      local w = winner({ hp = 0, filler = cdFar(),
                         csCharge = { charged = true, cur = 1, max = 2 } })
      assert.equals(ID.CS, w.cid)
    end)

    -- ⚠ THE DIRECTION THAT MATTERS: `cd` reads ready and the count says zero.  The COUNT
    -- decides.  Flip this and the HUD starts recommending a press that fails.
    it("ZERO charges is NOT usable even when the cooldown reads ready", function()
      local w = winner({ hp = 0, filler = cdReady(),
                         csCharge = { charged = true, cur = 0, max = 2 } })
      assert.is_nil(w)
    end)

    it("falls back to the cooldown read when there is no charge pool", function()
      assert.equals(ID.CS, winner({ hp = 0, filler = cdReady() }).cid)
    end)

    ------------------------------------------------------------------------
    -- A ONE-charge pool: the count and the cooldown are THE SAME FACT.
    ------------------------------------------------------------------------
    -- ⚠ FIELD-FOUND 2026-08-03, and the reason the max is consulted at all.  On 191 lines of
    -- one flight Judgment read `c10` (ten seconds of cooldown left) beside a charge count of
    -- `1/1`, and won on the count.  The two readings are of DIFFERENT SPELLS: the cooldown
    -- uses the display identity, charges use `overrideSpellID or spellID` (rungs 4+5, what
    -- Blizzard reads), and Judgment's row alternates identity with Hammer of Wrath.  A pool
    -- of one cannot legitimately disagree with its own cooldown, so require both — it needs
    -- no guess about which ladder was right and fails toward not promising a press.
    -- ⚠ `cdSoon(10)`, with a REAL remaining: `cdSoon()` leaves `remaining` nil, which
    -- Classify reads as an EXPIRED napkin ("probably up, unconfirmed") — a different state
    -- and not the one this case is about.
    it("a 1-charge pool is NOT usable when the cooldown says on cooldown", function()
      local w = winner({ hp = 0, filler = cdSoon(10),
                         csCharge = { charged = true, cur = 1, max = 1 } })
      assert.is_nil(w)
    end)

    it("a 1-charge pool IS usable when BOTH agree it is up", function()
      local w = winner({ hp = 0, filler = cdReady(),
                         csCharge = { charged = true, cur = 1, max = 1 } })
      assert.equals(ID.CS, w.cid)
    end)

    -- The other half, and the original Blade-of-Justice latch: a charge-category cooldown
    -- read can stay `ready` forever, so a count of ZERO must still veto it.
    it("a 1-charge pool at ZERO vetoes a latched-ready cooldown", function()
      local w = winner({ hp = 0, filler = cdReady(),
                         csCharge = { charged = true, cur = 0, max = 1 } })
      assert.is_nil(w)
    end)

    -- ⚠ AND THE CONFLAGRATE RULE IS UNTOUCHED: for a pool of TWO, one banked charge while
    -- the second recharges is the NORMAL state, so the count still outranks the cooldown.
    -- If this ever goes red, the fix above has been over-generalised.
    it("a 2-charge pool still lets a banked charge outrank the cooldown", function()
      local w = winner({ hp = 0, filler = cdSoon(10),
                         csCharge = { charged = true, cur = 1, max = 2 } })
      assert.equals(ID.CS, w.cid)
    end)

    -- An ABSENT count (a charge pool the napkin has not seeded yet) falls back to the
    -- cooldown read — "only when there is no count at all do we fall back".  ⚠ This is NOT
    -- the same as a count of zero, and the asymmetry is deliberate: a zero is a MEASUREMENT
    -- that must veto the press, while an absence is no measurement at all and must not veto
    -- a cooldown read that IS one.  The pair of cases above and below pins both halves.
    it("an absent count falls back to the cooldown read", function()
      local w = winner({ hp = 0, filler = cdReady(),
                         csCharge = { charged = true, cur = nil, max = 2 } })
      assert.equals(ID.CS, w.cid)
    end)

    it("...and that fallback still respects a cooldown that is NOT ready", function()
      local w = winner({ hp = 0, filler = cdFar(),
                         csCharge = { charged = true, cur = nil, max = 2 } })
      assert.is_nil(w)
    end)

    it("applies to Blade of Justice too", function()
      local w = winner({ hp = 0, boj = cdReady(), judgment = cdReady(),
                         bojCharge = { charged = true, cur = 0, max = 1 } })
      assert.equals(ID.JUDG, w.cid)        -- BoJ held at zero charges; L11 takes it
    end)
  end)

  ----------------------------------------------------------------------------
  -- The honest SECOND PLACE — the winner's ability removed, the list re-run.
  ----------------------------------------------------------------------------
  describe("the runner-up", function()
    it("re-runs the whole list with the winner's ability excluded", function()
      local g = guidance({ execution = cdReady(), wings = cdReady() })
      assert.equals(ID.ES, pressOf(g).cid)
      assert.equals(ID.AW, fallbackOf(g).cid)
    end)

    -- ⚠ THE EXCLUSION IS BY BASE SPELLID, so it drops EVERY line that names the ability.
    -- The spender sits on three lines (L1 / L4 / L8) and they all key on the same base, so
    -- excluding the winner must not simply re-offer it one line lower.
    -- ⚠ REWRITTEN 2026-08-03: the shell no longer calls RankWinner with an exclusion (the
    -- runner-up became a one-GCD LOOK-AHEAD), so the property is asserted DIRECTLY against
    -- the cascade instead of through the guidance.  It is still real and still worth
    -- pinning — the spender keys on one base id across L1 / L4 / L8.
    it("RankWinner's exclusion drops the spender from all three lines at once", function()
      local ctx = ns.ActiveSpec:Context(build({ hp = 5, woa = cdFar(), toll = cdReady() }), Coach)
      assert.equals(ID.TV, (ns.ActiveSpec:RankWinner(ctx)))        -- L4
      local second = (ns.ActiveSpec:RankWinner(ctx, ID.TV))
      assert.are_not.equals(ID.TV, second)                          -- not one line down
      assert.equals(ID.DT, second)                                  -- L6
    end)

    it("drops Blade of Justice from both of its lines at once", function()
      local g = guidance({ hp = 0, boj = cdReady(), aow = true, judgment = cdReady() })
      assert.equals(ID.BOJ, pressOf(g).cid)         -- L7
      assert.equals(ID.JUDG, fallbackOf(g).cid)     -- not L10's Blade of Justice again
    end)
  end)

  ----------------------------------------------------------------------------
  -- SOON — a DUMB per-ability decoration, independent of the winner.
  ----------------------------------------------------------------------------
  describe("SOON", function()
    it("decorates a tracked cooldown coming up within the lead", function()
      local g = guidance({ hp = 0, filler = cdReady(), wings = cdSoon(2) })
      assert.equals(ID.CS, pressOf(g).cid)
      assert.is_true(soonSet(g)[ID.AW])
    end)

    it("never decorates a utility", function()
      local g = guidance({ hp = 0, filler = cdReady(), utility = cdSoon(1) })
      assert.is_nil(soonSet(g)[ID.UTILITY])
    end)

    it("does not decorate something far out", function()
      local g = guidance({ hp = 0, filler = cdReady(), wings = cdFar() })
      assert.is_nil(soonSet(g)[ID.AW])
    end)
  end)

  ----------------------------------------------------------------------------
  -- Escalate — ROTATION -> LATE, from READABLE overdue-ness only.
  ----------------------------------------------------------------------------
  describe("Escalate", function()
    local function overdue() return cdReady(10) end   -- ready, and sat there past LATE_LEAD

    it("calls a burst cooldown LATE once it has sat past the lead", function()
      local w = winner({ execution = overdue() })
      assert.equals(ID.ES, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("does the same for Avenging Wrath and Divine Toll", function()
      assert.equals("LATE", winner({ wings = overdue() }).cue.emphasis)
      assert.equals("LATE", winner({ toll = overdue() }).cue.emphasis)
    end)

    -- ⚠ WAKE OF ASHES IS DELIBERATELY NOT IN THE LIST.  Its cooldown lives on a charge
    -- category, so its readiness edge is the charge-restore `Available` — which fires on
    -- every recharge and would make `overdue` meaningless.  Escalating on a signal we cannot
    -- trust is exactly what this method is forbidden to do.
    it("never escalates Wake of Ashes — its readiness edge is untrustworthy", function()
      local w = winner({ woa = overdue() })
      assert.equals(ID.WOA, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)

    it("calls the spender LATE at a full Holy Power bar", function()
      local w = winner({ hp = 5, woa = cdFar(), toll = cdFar() })
      assert.equals(ID.TV, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    -- Gated on ACTUAL Holy Power, not the projection: an in-flight spender has already
    -- committed to draining the bar, so projecting it would call you late for something you
    -- are mid-way through fixing.
    it("does not call it LATE below the cap", function()
      local w = winner({ hp = 4, woa = cdFar(), toll = cdFar(), judgment = cdReady() })
      assert.equals("ROTATION", w.cue.emphasis)
    end)

    it("never escalates a filler", function()
      local w = winner({ hp = 0, filler = overdue() })
      assert.equals(ID.CS, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)
  end)

  ----------------------------------------------------------------------------
  -- The hero tree rides the PULSE, and is never inferred (field-fix B).
  ----------------------------------------------------------------------------
  describe("hero tree", function()
    it("carries the pulse's answer through", function()
      local ctx = ns.Specs[70]:Context(build({ hero = "templar" }), Coach)
      assert.equals("templar", ctx.hero)
      assert.is_true(ctx.templar)
    end)

    it("stays nil when State could not read it — never a guess", function()
      local ctx = ns.Specs[70]:Context(build({}), Coach)
      assert.is_nil(ctx.hero)
      assert.is_false(ctx.templar)
    end)

    -- Herald of the Sun: no Hammer of Light exists, so L1 is self-gating.  No branch needed.
    it("Herald of the Sun simply never sees an armed L1", function()
      local w = winner({ hero = "herald-of-the-sun", hp = 5, woa = cdFar(), toll = cdReady() })
      assert.equals(ID.TV, w.cid)          -- the ordinary L4 dump
      assert.equals("at cap", w.cue.note)
    end)
  end)
end)
