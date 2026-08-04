-- coach_havoc_apl_spec.lua — the Tier-1 ROTATION gate for HAVOC DEMON HUNTER (577).
--
-- The independent oracle for CoachHavoc.lua.  Every expected winner / fallback / SOON below
-- is read FROM specs/havoc/rotation.md (the spec of record), never from RankWinner — the
-- same discipline the three older oracles apply.  A suite transcribed from the source it
-- tests is a change-detector wearing a contract's clothes.
--
-- Caveat honored: coverage proves a branch FIRED, not that the branch is RIGHT.  rotation.md
-- stays the authority for each line's expected press, and that document is itself
-- DESK-DERIVED (from the Tier-1 simc APL, not yet flown) — so these tests pin the
-- IMPLEMENTATION to the document, not the document to reality.  The Havoc in-game pass is
-- what arbitrates the document, and it is a hard deliverable (observability-map.md ->
-- THE FLIGHT'S JOB).
--
-- ⚠⚠ THE FURY GATES ARE GONE, AND THAT IS THE 2026-08-03 REMEDIATION.  This suite was 100
-- cases green over a HUD that could not cast its own rotation: `UnitPower("player", Fury)`
-- returns a SECRET VALUE (Fury is the DH's PRIMARY resource, and primary resources are secret
-- forever), so every `projected >= cost` gate compared against a fabricated zero.  The flight
-- read `PW:0/+0` on all 2380 lines, with Chaos Strike / Eye Beam / Blade Dance /
-- Metamorphosis winning ZERO and Throw Glaive 770.  ⚠ THE SUITE PASSED BECAUSE THE FIXTURE
-- SUPPLIED THE NUMBER THE CLIENT REFUSES — it could not express the only state the game ever
-- produces.  Affordability is now the client's own per-spell `insufficientPower` verdict, and
-- the pulse's Fury rail is RESTRICTED by default.  See `build`'s affordability banner.
--
-- The list under test (specs/havoc/rotation.md; first usable line = the press):
--   L1   Reaver's Glaive     whenever the Throw Glaive frame shows it
--   L2   Metamorphosis       Inner Demon down
--   L3   The Hunt            outside an Essence Break window, no glaive armed
--   L4   Immolation Aura     [AoE]
--   L5   Vengeful Retreat    Eye Beam up-or-nearly, Initiative down
--   L6   Essence Break       [META]
--   L7   Blade Dance         [META] -> Death Sweep, affordable
--   L8   the spender         inside an Essence Break window, affordable
--   L9   Eye Beam            -> Abyssal Gaze, affordable
--   L10  Blade Dance         [NO META], affordable
--   L11  Felblade            whenever usable
--   L13  the spender         the main dump (-> Annihilation in meta), affordable
--   L12  Immolation Aura     whenever usable
--   L14  Fel Rush            [AoE]
--   L15  Throw Glaive        affordable — the floor
--
-- ⚠ L13 IS EVALUATED BETWEEN L11 AND L12 and the labels stay put — Blizzard's own
-- generator/spender/generator shape, adopted because the two generator lines lost their
-- Fury-deficit gates and would otherwise starve the spender.  rotation.md says why.
--
-- ⚠ THE META FORK IS NOT A SECOND CASCADE.  Demon form is a DISPLAY OVERRIDE on frames the
-- list already presses (Chaos Strike -> Annihilation, Blade Dance -> Death Sweep), so the
-- Coach cues the BASE spellID either way.  What the fork genuinely changes is ORDER, in
-- exactly two places — L6 is meta-only, and L7-vs-L10 inverts Blade Dance against Eye Beam.
-- Both halves are pinned below, and `ctx.inMeta`'s TWO independent sources are pinned
-- separately as well as together.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

--------------------------------------------------------------------------------
-- Minimal State-pulse builder.  Every field the Havoc brain reads, nothing else.
--------------------------------------------------------------------------------
local NOW = 1000

-- `Enum.PowerType.Fury`, per the harness and the client (LuaEnum.lua:5681).  Still needed for
-- `CostPowerType` and for the refused-rail block, even though NO gate compares a Fury number
-- any more.  ⚠ The `SOUL_SHARDS` companion went with the cost cases: `ns.PowerCost`'s type
-- filter is still shipped and still pinned, by the three oracles whose specs actually consume
-- a cost — Havoc no longer does.
local FURY = 17

-- Base spellIDs (SpecHavoc.SpecIDs).  The Coach consumes the DOMAIN VIEW keyed by base
-- spellID, so these ARE the cue keys.
local ID = {
  CS = 162794, BD = 188499, IA = 258920, EB = 198013, TG = 185123,
  FR = 195072, HUNT = 370965, META = 191427, ESSB = 258860, RFA = 206803,
  -- the three rotational presses Blizzard filed as CDM-UTILITY
  FB = 232893, VR = 198793,
  -- overrides (no icon of their own; they ride a tracked frame)
  ANNI = 201427, DSWEEP = 210152, AGAZE = 452497, CFIRE = 452487, RG = 442294,
  -- buffs
  INNER_DEMON = 389693, INITIATIVE = 388108, AOTG = 442290,
  -- a plain utility, for the SOON exclusion
  UTILITY = 198589,   -- Blur
}

-- Distinct cooldownID display handles, decoupled from spellIDs as in a live pulse.
local CID = {
  CS = 8001, BD = 8002, IA = 8003, EB = 8004, TG = 8005, FR = 8006,
  HUNT = 8007, META = 8008, ESSB = 8009, RFA = 8010, FB = 8011, VR = 8012,
  UTILITY = 8013,
}

-- cd sub-tables per the 3-state contract (state + a trust `source`).
local function cdReady(age)  return { state = "ready", readable = true, source = "live", changedAt = NOW - (age or 2) } end
local function cdSoon(n)     return { state = "on-cooldown", remaining = n, readable = false, source = "napkin", changedAt = NOW - 1 } end
local function cdFar()       return { state = "on-cooldown", remaining = 30, readable = false, source = "napkin", changedAt = NOW - 1 } end
local function cdUnknown()   return { state = "unknown", readable = false, source = "none" } end

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
-- usable — the safe reading); the spender is always present with an `unknown` cd, since it
-- has no cooldown at all and its only gate is affordability.
--   broke / afford / affordUnreadable   the AFFORDABILITY fixture — see its banner below
--   furyMax           the readable half of the rail (UnitPowerMax is not secret)
--   furyReadable      a hypothetical readable VALUE.  ⚠ No in-game pulse can produce one
--   mode "st"|"aoe"   the manual target-mode toggle (`active_enemies` has no channel)
--   meta/hunt/eyeBeam/essenceBreak/bladeDance/immo/felblade/vr/felRush/throwGlaive/rfa
--                     a cd sub-table per button
--   *Charge           a `charge` sub-table on that button (Havoc's four charge categories)
--   metaXform "cs"|"bd"|"both"   which meta override is visibly live on its base frame
--   agaze / cfire     the two Fel-Scarred display overrides
--   rgXform           show Reaver's Glaive on the Throw Glaive frame (Aldrachi Reaver)
--   metaBuff          the Metamorphosis TrackedBuff row (191427) reporting IsActive()
--   innerDemon / initiative / aotg   buff presence
--   ebCast            put an Essence Break cast in history (`ebCastAge` seconds ago)
--   noSpender         omit Chaos Strike entirely (the untracked degradation)
--   noImmo            omit Immolation Aura entirely
--   utility           a cd sub-table on a CDM-Utility, cadence-utility row
--   hero              the pulse's hero tree
local function build(f)
  f = f or {}
  local abilities = {}

  abilities[ID.META] = ability(ID.META, CID.META, f.meta or cdFar())
  abilities[ID.HUNT] = ability(ID.HUNT, CID.HUNT, f.hunt or cdFar())
  abilities[ID.ESSB] = ability(ID.ESSB, CID.ESSB, f.essenceBreak or cdFar())

  -- Eye Beam and Blade Dance carry the two meta-relevant overrides; Eye Beam's is
  -- Fel-Scarred's Abyssal Gaze, which changes the LABEL and not the cue key.
  local ebExtra = f.agaze and { live = ID.AGAZE, override = ID.AGAZE } or {}
  abilities[ID.EB] = ability(ID.EB, CID.EB, f.eyeBeam or cdFar(), ebExtra)

  local bdExtra = { charge = f.bdCharge }
  if f.metaXform == "bd" or f.metaXform == "both" then
    bdExtra.live, bdExtra.override = ID.DSWEEP, ID.DSWEEP
  end
  abilities[ID.BD] = ability(ID.BD, CID.BD, f.bladeDance or cdFar(), bdExtra)

  -- The spender: no cooldown at all, gated only by Fury.  In demon form the frame casts
  -- ANNIHILATION, which is the entire readable channel for half the fork.
  if not f.noSpender then
    local csExtra = {}
    if f.metaXform == "cs" or f.metaXform == "both" then
      csExtra.live, csExtra.override = ID.ANNI, ID.ANNI
    end
    abilities[ID.CS] = ability(ID.CS, CID.CS, cdUnknown(), csExtra)
  end

  -- ── The charge-category buttons (THE LYING COOLDOWNS) ────────────────────────
  -- All four are ONE-charge categories in game; the fixtures below drive the count
  -- explicitly because on this spec the count is what keeps the press honest.
  if not f.noImmo then
    local iaExtra = { charge = f.immoCharge }
    if f.cfire then iaExtra.live, iaExtra.override = ID.CFIRE, ID.CFIRE end
    abilities[ID.IA] = ability(ID.IA, CID.IA, f.immo or cdFar(), iaExtra)
  end
  local tgExtra = { charge = f.tgCharge }
  if f.rgXform then tgExtra.live, tgExtra.override = ID.RG, ID.RG end
  abilities[ID.TG] = ability(ID.TG, CID.TG, f.throwGlaive or cdFar(), tgExtra)

  -- ⚠ FEL RUSH, VENGEFUL RETREAT and FELBLADE are filed CDM-**UTILITY** by Blizzard, and the
  -- fixture says so.  The brain must cue them anyway: both fences that could block them read
  -- the SPEC-AUTHORED `cadence`, never the row's category.  A fixture that quietly filed them
  -- Essential would assert nothing about the finding this spec exists to record.
  abilities[ID.FR] = ability(ID.FR, CID.FR, f.felRush or cdFar(),
                             { charge = f.frCharge, category = "Utility" })
  abilities[ID.VR] = ability(ID.VR, CID.VR, f.vr or cdFar(),
                             { charge = f.vrCharge, category = "Utility" })
  abilities[ID.FB] = ability(ID.FB, CID.FB, f.felblade or cdFar(), { category = "Utility" })

  -- Rain from Above: a tracked Essential with a real 90 s cooldown that appears NOWHERE in
  -- the APL.  Registered so the log can name it, cued by nothing, and `cadence = "utility"`
  -- keeps it out of the SOON decoration.
  if f.rfa then abilities[ID.RFA] = ability(ID.RFA, CID.RFA, f.rfa) end

  if f.utility then
    abilities[ID.UTILITY] = ability(ID.UTILITY, CID.UTILITY, f.utility, { category = "Utility" })
  end

  -- Buff PRESENCE — spellID-keyed, exactly as State's domain view emits it, and keyed on the
  -- TRACKED id rather than the real aura id (State.lua:2304 writes `buffs[baseOf(entry)]`).
  -- ⚠ Presence only: every Havoc buff that matters has a secret duration, and every stacking
  -- one sits behind a talent id whose CDM row reads CumulativeAura = 0.
  local buffs = {}
  if f.metaBuff   then buffs[ID.META] = true end
  if f.innerDemon then buffs[ID.INNER_DEMON] = true end
  if f.initiative then buffs[ID.INITIATIVE] = true end
  if f.aotg       then buffs[ID.AOTG] = true end

  -- ── AFFORDABILITY, the channel that replaced every Fury comparison ──────────
  -- ⚠⚠ THE WHOLE FIXTURE CHANGED SHAPE ON 2026-08-03, AND IT IS NOT A REFACTOR.  This used
  -- to drive a Fury NUMBER (`f.fury`) and four live COSTS through `fx.powerCost`, because
  -- the brain compared `projected >= cost`.  `UnitPower("player", Fury)` returns a SECRET
  -- VALUE — Fury is the DH's PRIMARY resource and primary resources are secret forever — so
  -- that number never existed in game, `ctx.fury or 0` fabricated a zero, and the flight cued
  -- Throw Glaive 770 times and Chaos Strike never.  100 green cases over a HUD that could
  -- not cast its own rotation.  ⚠ THE OLD FIXTURE IS WHY: it SUPPLIED the number the client
  -- refuses, so the suite could not express the only state the game ever produces.
  --
  -- The pulse now carries what State actually attaches: `abilities[base].usable`, the
  -- client's per-spell `C_Spell.IsSpellUsable` verdict.  Three shapes, and the difference
  -- between the second and third is the entire lesson:
  --   { readable = true,  insufficientPower = false }  affordable — the client said so
  --   { readable = true,  insufficientPower = true  }  BROKE — the client said so
  --   { readable = false }                             COULD NOT ASK — must NOT block
  --
  --   broke              every Fury-costing button reports insufficientPower (the old
  --                      `broke = true`), i.e. the state that used to be unrepresentable
  --   afford = {[ID]=b}  per-ability override, so one spell can be broke while another in
  --                      the SAME pulse is fine (the per-spell discrimination the in-game
  --                      macro proved: Throw Glaive read FREE while three others read broke)
  --   affordUnreadable   the client refuses for every id -> the fall-through-to-allowed rule
  --
  -- ⚠ ONLY THE FOUR ABILITIES THE LIST GATES ON RESOURCE GET A VERDICT.  Felblade,
  -- Immolation Aura, Fel Rush, Vengeful Retreat, The Hunt and Metamorphosis are generators or
  -- free presses, and Essence Break has NO Fury cost at all — State fences the read on the
  -- spec's `spends`, so a fixture that handed them verdicts would be testing a read the
  -- pipeline never makes.
  local COSTED = { ID.CS, ID.BD, ID.EB, ID.TG }
  for _, id in ipairs(COSTED) do
    local row = abilities[id]
    if row then
      local ok = true
      if f.broke then ok = false end
      if f.afford ~= nil and f.afford[id] ~= nil then ok = f.afford[id] end
      if f.affordUnreadable then
        row.usable = { readable = false }
      else
        row.usable = { readable = true, usable = ok, insufficientPower = not ok }
      end
    end
  end

  -- The ESSENCE BREAK WINDOW (ns.Coach.CommittedWithin against 258860) — the debuff 320338
  -- has no CDM row, so the window is derived from the CAST.
  -- ⚠ THE IN-FLIGHT PROJECTION IS GONE from this fixture: `spec.SpecPowerDelta` is deleted
  -- (there is no rail to project onto), so history now drives exactly one channel.
  local history = {}
  if f.ebCast then
    history[#history + 1] = { phase = "succeeded", spellID = ID.ESSB, base = ID.ESSB,
                              at = NOW - (f.ebCastAge or 2) }
  end

  -- ⚠ THE FURY RAIL IS **RESTRICTED BY DEFAULT**, because that is what the game does.  State
  -- omits `value` on a refusal and marks `restricted` off
  -- `C_Secrets.ShouldUnitPowerBeSecret`, which for Fury answers true in a city AND mid-pull.
  -- `max` survives — `UnitPowerMax` is a DIFFERENT secrecy predicate and is readable (170,
  -- measured).  `f.furyReadable` exists ONLY to prove the pipeline would carry a value if
  -- one ever arrived; no in-game pulse can produce it.
  local bar = { max = f.furyMax or 170, type = FURY, readable = false, restricted = true }
  if f.furyReadable then
    bar.readable, bar.restricted = true, nil
    bar.value, bar.unmodified = f.furyReadable, f.furyReadable
    bar.unmodifiedMax, bar.modifier = bar.max, 1
  end

  return {
    at = NOW, combat = (f.combat ~= false), combatStartedAt = NOW - 60,
    mode = f.mode or "st",
    hero = f.hero,
    power = { Fury = bar },
    buffs = buffs,
    history = history,
    abilities = abilities,
  }
end

--------------------------------------------------------------------------------
-- Guidance readers (identical contract to the other three oracles).
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
describe("Havoc rotation list (from specs/havoc/rotation.md)", function()
  local ns, Coach
  before_each(function()
    ns = H.fresh()
    -- The harness activates Demonology by default; drive spec 577 through the REAL resolver
    -- (index 5 -> 577), exactly as a live respec would.
    H.setSpecIndex(5)
    ns.ResolveActiveSpec()
    H.load("Coach.lua")
    -- ⚠ WIRED WITH THE REAL `ns.PowerCost`, exactly as the live driver does.  Without it
    -- `env.powerCostFn` is nil and every cost silently falls back to the spec's constant, so
    -- the "resolved live, never hardcoded" rule would be untested — the fixture would agree
    -- with the fallback whatever the client said.  And it must NOT be the harness's ShardCost
    -- stub: that has no type filter and answers nil where the shipping reader answers 0, which
    -- is how 76 green Retribution cases sat over a HUD cueing a spender at zero resource.
    Coach = ns.Coach.New({ powerCost = ns.PowerCost })
  end)

  local function guidance(facts) return Coach:Compute(build(facts)) end
  local function winner(facts) return pressOf(guidance(facts)) end
  local function ctxOf(facts) return ns.Specs[577]:Context(build(facts), Coach) end

  ----------------------------------------------------------------------------
  it("activates spec 577 with the Havoc data bound", function()
    assert.equals(ns.Specs[577], ns.ActiveSpec)
    assert.equals(ID.CS, ns.SpecIDs.CHAOS_STRIKE)
    assert.equals(ID.ANNI, ns.SpecIDs.ANNIHILATION)
    -- The dormant Tier-3 fields Demonology carries are deliberately absent here.
    assert.is_nil(ns.SpecOpener)
    assert.is_nil(ns.SpecBurst)
    -- ⚠ AND NO `derived` BLOCK — a DECISION, not an omission.  The Phase-0.3 class-resource
    -- channel exists for Demon Hunter Soul Fragments, so a DH spec is exactly where a reader
    -- expects one; Havoc's resource is Fury, and Vengeance/Devourer remain the first
    -- consumers (SpecHavoc.lua's header carries the three Tier-1 checks).
    assert.is_nil(ns.Specs[577].derived)
  end)

  -- THE ACTION-BAR / CDM ID SPLIT.  SkillLine 1848 teaches WRAPPER spells the CDM does not
  -- track, so the rung ladder asks the action bar about the tracked id and finds nothing.
  -- Without these two aliases both abilities silently lose their keybind hint.
  it("aliases the two wrapper spellIDs for the keybind ladder", function()
    assert.equals(344862, ns.SpecBindAlias[ID.CS])   -- Chaos Strike wrapper
    assert.equals(344865, ns.SpecBindAlias[ID.FR])   -- Fel Rush wrapper (trigger -> 195072)
  end)

  ----------------------------------------------------------------------------
  -- The resource rail: TRACKED, and deliberately NOT DRAWN.
  ----------------------------------------------------------------------------
  describe("Fury rides the whole rail with display = \"none\" — and it is RESTRICTED", function()
    it("emits exactly one resourceBar, marked `none`", function()
      local bars = guidance({}).resourceBars
      assert.equals(1, #bars)
      assert.equals("none", bars[1].display)
      assert.equals("FURY", bars[1].powerType)
    end)

    -- ⚠⚠ THE CASE THAT WOULD HAVE CAUGHT THE FLIGHT.  `Coach:ResourceBars` read
    -- `value = p.value or 0` until 2026-08-03, so an UNREADABLE rail reached every consumer
    -- as a confident ZERO — the project's own absent-is-never-zero rule broken in the one
    -- place nothing tested.  `nil` and `0` are different findings and only one of them is
    -- true.  ⚠ `assert.is_nil` here, never `assert.equals(0, …)`.
    it("carries NO value on a restricted rail — nil, not 0", function()
      local bar = guidance({}).resourceBars[1]
      assert.is_nil(bar.value)
      assert.is_nil(bar.valueExact)
      -- ⚠ `incoming` IS a real 0 and must not be confused with the above: `spec.powers`
      -- declares `incoming = false`, so "nothing is in flight" is a FACT about this bar
      -- rather than a measurement we failed to take.  Absent-is-never-zero cuts both ways.
      assert.equals(0, bar.incoming)
      assert.is_true(bar.restricted)
      -- The MAX survives: `UnitPowerMax` is a different secrecy predicate and IS readable.
      assert.equals(170, bar.max)
    end)

    -- The brain must not fabricate one either — `ctx.fury` was `furyRail.value or 0`.
    it("leaves ctx.fury nil and says WHY, rather than reading zero", function()
      local ctx = ctxOf({})
      assert.is_nil(ctx.fury)
      assert.is_false(ctx.powerReadable)
      assert.is_true(ctx.furyRestricted)
    end)

    -- ⚠ THE POINT OF THE WHOLE PHASE: a restricted rail must still produce a CORRECT cascade.
    -- The failed flight's rail was restricted too — what broke was that the gates read it.
    it("still ranks the full list with the rail unreadable", function()
      assert.equals(ID.META, winner({ meta = cdReady(), hunt = cdReady() }).cid)
      assert.equals(ID.EB, winner({ eyeBeam = cdReady() }).cid)
      assert.equals(ID.CS, winner({}).cid)
    end)

    -- ⚠ THE END OF THE CHAIN, and the whole argument for `none` over an empty `spec.powers`.
    -- An empty powers array emits no bar at all and DecisionLog's `PW:` renders `?/?` for the
    -- entire spec — losing the one instrument that can explain a decision nobody watched.
    -- Asserting the bar is not enough; this asserts the COLUMN.
    --
    -- ⚠ AND IT MUST READ `restricted`, NEVER `0`.  The flight rendered `PW:0/+0` on all 2380
    -- lines while Fury was in fact unreadable, so the one instrument that could have named
    -- the problem instead corroborated the wrong answer.  A reader seeing `PW:0` has to be
    -- able to trust it means zero.
    it("reaches the decision log's PW column as `restricted`, never a number", function()
      H.load("DecisionLog.lua")
      local pulse = build({})
      local line = ns.DecisionLog.Render(pulse, Coach:Compute(pulse), { cues = {} })
      assert.is_truthy(line:match("PW:restricted"), "PW column read: " .. tostring(line:match("PW:%S+")))
      assert.is_nil(line:match("PW:0"))
    end)

    -- The rail is not BROKEN, only secret: if a value ever did arrive it must travel intact.
    -- ⚠ This is the ONLY case in the file that supplies a Fury value, and no in-game pulse can
    -- produce one — do not reach for it to set up a rotation case.
    it("would carry a value intact if one ever arrived (modifier 1, no unit games)", function()
      local bar = guidance({ furyReadable = 40 }).resourceBars[1]
      assert.equals(40, bar.value)
      assert.equals(40, bar.valueExact)
      assert.equals(1, bar.modifier)
      assert.is_falsy(bar.restricted)
    end)

    -- The decision log must be able to say WHICH source forked the list — a fork nobody can
    -- explain is exactly the hole the Destruction field capture fell into.
    it("names Metamorphosis in the PR column when the buff row is up", function()
      H.load("DecisionLog.lua")
      local pulse = build({ metaBuff = true })
      local line = ns.DecisionLog.Render(pulse, Coach:Compute(pulse), { cues = {} })
      assert.is_truthy(line:match("PR:[^|]*Meta"), "PR column read: " .. tostring(line:match("PR:%S+")))
    end)
  end)

  ----------------------------------------------------------------------------
  -- THE METAMORPHOSIS FORK — two ORed sources, and the two lines it moves.
  ----------------------------------------------------------------------------
  describe("ctx.inMeta reads two independent sources", function()
    it("is false with neither", function()
      local ctx = ctxOf({})
      assert.is_false(ctx.metaFromBuff)
      assert.is_false(ctx.metaFromTransform)
      assert.is_false(ctx.inMeta)
    end)

    -- ⚠ 191427 is the CAST id; the aura that actually grants the overrides is 162264, which
    -- the CDM does not track.  So this is the row we have, not the aura we would pick — and
    -- that is precisely why there are two sources.
    it("forks on the TrackedBuff row alone", function()
      local ctx = ctxOf({ metaBuff = true })
      assert.is_true(ctx.metaFromBuff)
      assert.is_false(ctx.metaFromTransform)
      assert.is_true(ctx.inMeta)
    end)

    it("forks on the Chaos Strike transform alone", function()
      local ctx = ctxOf({ metaXform = "cs" })
      assert.is_false(ctx.metaFromBuff)
      assert.is_true(ctx.metaFromTransform)
      assert.is_true(ctx.inMeta)
    end)

    -- Metamorphosis 162264 carries TWO `EffectAura 332` effects, so demon form always
    -- transforms BOTH frames — seeing either is sufficient.
    it("forks on the Blade Dance transform alone", function()
      local ctx = ctxOf({ metaXform = "bd" })
      assert.is_true(ctx.metaFromTransform)
      assert.is_true(ctx.inMeta)
    end)

    it("forks on both together, and publishes both flags", function()
      local ctx = ctxOf({ metaBuff = true, metaXform = "both" })
      assert.is_true(ctx.metaFromBuff)
      assert.is_true(ctx.metaFromTransform)
      assert.is_true(ctx.inMeta)
    end)

    -- A transform to something that is NOT a meta override must not fork the list: the
    -- Fel-Scarred Abyssal Gaze override rides the Eye Beam frame all the time.
    it("is not forked by an unrelated display override", function()
      assert.is_false(ctxOf({ agaze = true, cfire = true }).inMeta)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L1 — Reaver's Glaive (Aldrachi Reaver).
  ----------------------------------------------------------------------------
  describe("L1 — Reaver's Glaive", function()
    -- ⚠ Gated on the TRANSFORM alone, not on Throw Glaive's cooldown — Destruction's
    -- Ruination precedent exactly: a granted free press that REPLACES the button on its own
    -- frame, so sitting on it blocks nothing and gains nothing.
    it("wins off the Throw Glaive transform, above every cooldown", function()
      local w = winner({ rgXform = true, throwGlaive = cdFar(), broke = true,
                         meta = cdReady(), hunt = cdReady() })
      assert.equals(ID.TG, w.cid)        -- keyed by the BASE frame it rides
      assert.equals("Reaver's Glaive", w.cue.note)
    end)

    it("is simply absent with no transform (Fel-Scarred, and every non-armed moment)", function()
      local w = winner({ meta = cdReady() })
      assert.equals(ID.META, w.cid)
    end)

    -- It also vetoes L3 (`!buff.reavers_glaive.up` — the one surviving readable term of The
    -- Hunt's nine-term gate).
    it("vetoes The Hunt while a glaive is armed", function()
      local w = winner({ rgXform = true, hunt = cdReady() })
      assert.equals(ID.TG, w.cid)
      assert.equals("Reaver's Glaive", w.cue.note)
    end)

    -- HAVOC_RG_FROM_BUFF, the spec's one parked switch, defaults OFF.  Art of the Glaive is
    -- the 80-stack FRAGMENT COUNTER that arms the glaive, and the count is unreachable — so
    -- treating its presence as "armed" would pin L1 above everything permanently.  That is
    -- the Light's Deliverance shape verbatim, and that one was answered NO by measurement.
    it("is NOT armed by the Art of the Glaive buff alone (switch defaults off)", function()
      local w = winner({ aotg = true, hunt = cdReady() })
      assert.equals(ID.HUNT, w.cid)
    end)

    it("IS armed by the buff once HAVOC_RG_FROM_BUFF is flipped on (documented, not endorsed)", function()
      ns.Specs[577].HAVOC_RG_FROM_BUFF = true
      local w = winner({ aotg = true, hunt = cdReady(), throwGlaive = cdFar() })
      assert.equals(ID.TG, w.cid)
      assert.equals("Reaver's Glaive", w.cue.note)
      ns.Specs[577].HAVOC_RG_FROM_BUFF = false
    end)
  end)

  ----------------------------------------------------------------------------
  -- L2 / L3 — the two burst lines.
  ----------------------------------------------------------------------------
  describe("L2 — Metamorphosis", function()
    it("wins on cooldown, above The Hunt", function()
      assert.equals(ID.META, winner({ meta = cdReady(), hunt = cdReady() }).cid)
    end)

    -- simc:103 is the longest single line in the APL and only ONE of its terms survives.
    it("is vetoed by Inner Demon", function()
      local w = winner({ meta = cdReady(), hunt = cdReady(), innerDemon = true })
      assert.equals(ID.HUNT, w.cid)
    end)

    -- ⚠⚠ THE INVERTED CASE.  This asserted the OPPOSITE until 2026-08-03 ("is vetoed by an
    -- AVAILABLE Blade Dance"), transcribing `cooldown.blade_dance.remains` as a boolean.  It
    -- was a MISREADING OF THE CLAUSE, not of the fragment: in full the term is
    --   ( bd.remains & (bd.remains > gcd.max*3 | prev_gcd.{1,2,3}.death_sweep) )
    --   | !talent.chaotic_transformation
    -- and with simc's precedence (`&` over `|`) the whole thing is TRUE for anyone without
    -- Chaotic Transformation — a talent we cannot read, so the escape hatch was invisible.
    -- MEASURED: the veto suppressed Metamorphosis on all 2374 in-combat lines of the flight.
    -- Dropped on the same rule as the Eye Beam alignment block: a 2-minute cooldown is not
    -- held on a gate we cannot evaluate.  rotation.md Deviation 12.
    it("is NOT vetoed by an available Blade Dance (Dev. 12 — the term was a misreading)", function()
      local w = winner({ meta = cdReady(), bladeDance = cdReady() })
      assert.equals(ID.META, w.cid)      -- L2 keeps it; Blade Dance is only the runner-up
    end)

    -- The napkin's "probably up" is ROTATION-eligible, not "never" — the shell's contract.
    it("fires on a probably-up napkin read", function()
      local probably = { state = "on-cooldown", remaining = 0, readable = false,
                         source = "napkin", changedAt = NOW - 2 }
      assert.equals(ID.META, winner({ meta = probably }).cid)
    end)
  end)

  describe("L3 — The Hunt", function()
    it("wins on cooldown", function()
      assert.equals(ID.HUNT, winner({ hunt = cdReady() }).cid)
    end)

    -- `debuff.essence_break.down`, readable through CAST HISTORY rather than an aura.
    it("is vetoed inside an Essence Break window", function()
      -- `broke` clears the spender out of L8/L13 so the assertion is about L3's veto alone.
      assert.is_nil(winner({ hunt = cdReady(), ebCast = true, broke = true }))
    end)

    it("fires again once the window has elapsed", function()
      assert.equals(ID.HUNT, winner({ hunt = cdReady(), ebCast = true, ebCastAge = 5 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L4 / L14 — the two mode-gated lines.  `active_enemies` has no channel at all, so it
  -- collapses to the manual toggle: a player DECLARATION, never an observation.
  ----------------------------------------------------------------------------
  describe("the AoE-gated lines", function()
    it("L4 — Immolation Aura fires in AoE mode, above everything below it", function()
      local w = winner({ mode = "aoe", immo = cdReady(), eyeBeam = cdReady() })
      assert.equals(ID.IA, w.cid)
      assert.equals("AoE", w.cue.note)
    end)

    -- ⚠ In single-target L4 is shut, and L12 now sits BELOW the spender — so a ready
    -- Immolation Aura loses the press to L13 rather than to a deficit threshold.  That
    -- ordering is what stops an ungated 30 s charge category taking the press on every
    -- recharge, and it is the thing to check first if the HUD starts under-spending.
    it("...and not in single-target, where the spender (L13) outranks L12", function()
      local w = winner({ mode = "st", immo = cdReady() })
      assert.equals(ID.CS, w.cid)        -- L13, evaluated above L12
    end)

    it("L14 — Fel Rush fires in AoE mode, below the spender", function()
      -- `broke` keeps L13 shut, so the AoE filler is reachable.
      local w = winner({ mode = "aoe", broke = true, felRush = cdReady(),
                         frCharge = { charged = true, cur = 1, max = 1 } })
      assert.equals(ID.FR, w.cid)
      assert.equals("AoE", w.cue.note)
    end)

    it("...and never in single-target", function()
      assert.is_nil(winner({ mode = "st", broke = true, felRush = cdReady(),
                             frCharge = { charged = true, cur = 1, max = 1 } }))
    end)
  end)

  ----------------------------------------------------------------------------
  -- L5 — Vengeful Retreat, the one CROSS-ABILITY TIMING READ in the file.
  ----------------------------------------------------------------------------
  -- ⚠ NEW VOCABULARY, flagged as such in three places.  Every other `cooldown.X.remains`
  -- gate in the APL is dropped because a CLIENT cooldown read is secret in combat — but this
  -- reads OUR OWN NAPKIN, and Eye Beam's 30 s lives on the SPELL row so the napkin counts it
  -- honestly.  The rule: a cross-ability timing gate is allowed when the OTHER ability's
  -- cooldown is one the napkin can honestly count.  If the flight shows VR cueing at wrong
  -- moments, this line is the first suspect.
  describe("L5 — Vengeful Retreat before Eye Beam", function()
    it("fires with Eye Beam already up", function()
      local w = winner({ vr = cdReady(), eyeBeam = cdReady() })
      assert.equals(ID.VR, w.cid)
      assert.equals("before Eye Beam", w.cue.note)
    end)

    -- simc: `cooldown.eye_beam.remains <= gcd.remains`, i.e. about one GCD out.
    it("fires on the eyeBeamSoon napkin gate, inside the lead", function()
      local w = winner({ vr = cdReady(), eyeBeam = cdSoon(1.0) })
      assert.equals(ID.VR, w.cid)
    end)

    it("does NOT fire when Eye Beam is still outside the lead", function()
      assert.is_nil(winner({ vr = cdReady(), eyeBeam = cdSoon(2.5), broke = true }))
      assert.is_false(ctxOf({ eyeBeam = cdSoon(2.5) }).eyeBeamSoon)
    end)

    -- Vengeful Retreat exists to PROC Initiative, so pressing it while the buff is already
    -- up wastes the retreat (simc's `!buff.initiative.up`).
    it("is vetoed while Initiative is up", function()
      local w = winner({ vr = cdReady(), eyeBeam = cdReady(), initiative = true })
      assert.equals(ID.EB, w.cid)        -- L9 takes it instead
    end)
  end)

  ----------------------------------------------------------------------------
  -- L6 / L7 / L10 — THE TWO ORDERINGS THE FORK GENUINELY CHANGES.
  ----------------------------------------------------------------------------
  describe("L6 — Essence Break is META-ONLY", function()
    -- ⚠ That is what the APL SAYS, not an inference: the top-level `essence_break` action at
    -- simc:87 sits inside a `#` comment, so `actions.meta`:121 is its only surviving home.
    -- Possibly an authoring accident; taking the file literally is the Tier-1-faithful call
    -- and it fails safe (a missed press, never a wrong one).
    it("fires in demon form", function()
      local w = winner({ metaBuff = true, essenceBreak = cdReady() })
      assert.equals(ID.ESSB, w.cid)
    end)

    it("does NOT fire outside demon form, however ready it is", function()
      local w = winner({ essenceBreak = cdReady() })
      assert.equals(ID.CS, w.cid)        -- falls through to L13
    end)

    -- ⚠⚠ THE INVERTED CASE, and it is the ONE GENUINE ROTATIONAL REGRESSION of the secrecy
    -- finding.  This asserted `is_nil` below 35 Fury until 2026-08-03.  simc's `fury>=35` is
    -- a POOLING rule — the 4 s window wants Fury behind it to flood — and NOT a press cost:
    -- Essence Break 258860 has no PowerType-17 row in DB2 `SpellPower`, so it is free and
    -- `IsSpellUsable` has nothing to report.  With Fury secret there is no replacement gate,
    -- so the window can now open on an empty bar.  Every other dropped gate loses a nuance on
    -- a press that stays correct; this one can waste a 40 s cooldown.  rotation.md Dev. 13 —
    -- and it is the strongest single argument for Phase 2.
    it("fires even with every spender unaffordable (Dev. 13 — the pooling rule is gone)", function()
      local w = winner({ metaBuff = true, essenceBreak = cdReady(), broke = true })
      assert.equals(ID.ESSB, w.cid)
    end)

    -- It forks on the TRANSFORM source just as well as on the buff row.
    it("fires off the transform source alone", function()
      local w = winner({ metaXform = "cs", essenceBreak = cdReady() })
      assert.equals(ID.ESSB, w.cid)
    end)
  end)

  describe("L7 vs L10 — the Blade Dance / Eye Beam inversion", function()
    -- In demon form Death Sweep heads the meta list (actions.meta:118 / :122 / :130, all
    -- above eye_beam at :129); out of it Eye Beam comes first (:86 above :88).
    it("in meta, Blade Dance OUTRANKS Eye Beam", function()
      local g = guidance({ metaBuff = true, bladeDance = cdReady(), eyeBeam = cdReady(),
                            })
      local w = pressOf(g)
      assert.equals(ID.BD, w.cid)
      assert.equals("Death Sweep", w.cue.note)
      assert.equals(ID.EB, fallbackOf(g).cid)
    end)

    it("outside meta, Eye Beam OUTRANKS Blade Dance", function()
      local g = guidance({ bladeDance = cdReady(), eyeBeam = cdReady() })
      assert.equals(ID.EB, pressOf(g).cid)
      assert.is_nil(pressOf(g).cue.note)
      assert.equals(ID.BD, fallbackOf(g).cid)
    end)

    it("L10 is silent in meta and L7 is silent outside it", function()
      -- Eye Beam absent from the board on both sides, so only the Blade Dance line can fire
      -- and the NOTE says which one did.
      local inMeta = winner({ metaBuff = true, bladeDance = cdReady() })
      assert.equals("Death Sweep", inMeta.cue.note)
      local outside = winner({ bladeDance = cdReady() })
      assert.is_nil(outside.cue.note)
    end)

    -- ⚠ `variable.use_blade_dance` IS TREATED AS TRUE — the one place this list deliberately
    -- chooses OVER-pressing.  simc gates it on three unreadable talents, and First Blood (the
    -- standard single-target pick) makes Blade Dance a full ST spender; gating on `mode ==
    -- "aoe"` would make it invisible for the whole single-target rotation of that build.
    it("offers Blade Dance in SINGLE-TARGET, not only in AoE", function()
      assert.equals(ID.BD, winner({ mode = "st", bladeDance = cdReady() }).cid)
    end)

    it("holds Blade Dance below its cost", function()
      assert.is_nil(winner({ bladeDance = cdReady(), broke = true }))
    end)
  end)

  ----------------------------------------------------------------------------
  -- L8 — the spender inside an Essence Break window, from CAST HISTORY.
  ----------------------------------------------------------------------------
  describe("L8 — the Essence Break window", function()
    -- The 320338 debuff has no CDM row, so the window is derived from the 258860 CAST —
    -- `UNIT_SPELLCAST_SUCCEEDED` spellIDs are a settled readable channel — against the
    -- debuff's flat 4000 ms DB2 duration.
    it("promotes the spender above Eye Beam inside the window", function()
      local g = guidance({ ebCast = true, eyeBeam = cdReady() })
      local w = pressOf(g)
      assert.equals(ID.CS, w.cid)
      assert.equals("Essence Break window", w.cue.note)
    end)

    it("does not, once the window has elapsed", function()
      local w = winner({ ebCast = true, ebCastAge = 5, eyeBeam = cdReady() })
      assert.equals(ID.EB, w.cid)
    end)

    it("does not, with no Essence Break cast at all", function()
      local w = winner({ eyeBeam = cdReady() })
      assert.equals(ID.EB, w.cid)
      assert.is_false(ctxOf({}).ebWindow)
    end)

    it("still respects affordability inside the window", function()
      -- Only the SPENDER is unaffordable, so L8 holds and L9 — which the client says we can
      -- still pay for — takes the press.  Blanket `broke` would shut L9 too and assert
      -- nothing about the window.
      local w = winner({ ebCast = true, eyeBeam = cdReady(), afford = { [ID.CS] = false } })
      assert.equals(ID.EB, w.cid)
    end)

    -- The window boundary itself: `CommittedWithin` is inclusive at EB_WINDOW.
    it("holds the window open for exactly EB_WINDOW seconds", function()
      assert.is_true(ctxOf({ ebCast = true, ebCastAge = 4.0 }).ebWindow)
      assert.is_false(ctxOf({ ebCast = true, ebCastAge = 4.1 }).ebWindow)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L9 / L15 — the rest of the body (L11/L13/L12 have their own ordering block below).
  ----------------------------------------------------------------------------
  it("L9 — Eye Beam on cooldown, once affordable", function()
    assert.equals(ID.EB, winner({ eyeBeam = cdReady() }).cid)
    assert.is_nil(winner({ eyeBeam = cdReady(), broke = true }))
  end)

  -- Fel-Scarred draws this frame as ABYSSAL GAZE, and the cue key is unchanged — the icon
  -- already shows the right art, which is the whole reason the fork needs no second cascade.
  it("L9 — the Abyssal Gaze override does not move the cue key", function()
    local w = winner({ eyeBeam = cdReady(), agaze = true })
    assert.equals(ID.EB, w.cid)
  end)

  -- ⚠⚠ THE ORDERING BLOCK, REWRITTEN 2026-08-03.  Both lines used to carry a Fury DEFICIT
  -- gate (`deficit >= 40` / `>= 20`), and a deficit is `max - value` where `value` is SECRET.
  -- With no threshold available the lines could only be dropped or repositioned, and dropping
  -- them where they sat — BOTH above the main dump — would have jammed two generators on and
  -- starved the spender, i.e. the flight failure by a different mechanism.  So the evaluation
  -- order is Blizzard's own from `assisted_combat/demonhunter_havoc.simc`:
  --     L11 Felblade  ->  L13 spender  ->  L12 Immolation Aura
  -- These four cases exist to pin that order; if any of them goes red the list has been
  -- "tidied" back into numeric sequence and the spender is being starved again.
  describe("L11 / L13 / L12 — the generator/spender/generator order", function()
    -- Felblade is above the dump, so a ready Felblade takes the press even when the spender
    -- is affordable.  Its real 12 s cooldown is what makes "whenever usable" self-limiting.
    it("L11 — Felblade fires whenever usable, ABOVE the spender", function()
      assert.equals(ID.FB, winner({ felblade = cdReady() }).cid)
      -- ...and the spender is genuinely the runner-up, not merely absent.
      assert.equals(ID.CS, fallbackOf(guidance({ felblade = cdReady() })).cid)
    end)

    -- Immolation Aura is BELOW it: a 30 s charge category left ungated above the dump would
    -- take the press on every recharge.  It only wins when the spender cannot pay.
    it("L12 — Immolation Aura yields to the spender, and takes the press when it cannot pay", function()
      assert.equals(ID.CS, winner({ immo = cdReady() }).cid)
      assert.equals(ID.IA, winner({ immo = cdReady(), broke = true }).cid)
    end)

    -- The whole order in one pulse.
    it("ranks Felblade > spender > Immolation Aura with all three available", function()
      local g = guidance({ felblade = cdReady(), immo = cdReady() })
      assert.equals(ID.FB, pressOf(g).cid)
      assert.equals(ID.CS, fallbackOf(g).cid)
    end)

    it("Felblade outranks Immolation Aura when the spender cannot pay", function()
      local g = guidance({ felblade = cdReady(), immo = cdReady(), broke = true })
      assert.equals(ID.FB, pressOf(g).cid)
      assert.equals(ID.IA, fallbackOf(g).cid)
    end)

    -- ⚠ THE FINDING THIS SPEC EXISTS TO RECORD: Felblade / Vengeful Retreat / Fel Rush are
    -- filed CDM-**UTILITY** by Blizzard and the fixture files them that way.  Both fences
    -- that could have blocked them read the SPEC-AUTHORED `cadence`, not the row's category,
    -- so declaring them "filler"/"oncd" is the whole fix — no pipeline edit.
    it("cues a CDM-Utility row because the SPEC's cadence says so", function()
      assert.equals("Utility", build({}).abilities[ID.FB].category)
      assert.equals(ID.FB, winner({ felblade = cdReady(), broke = true }).cid)
    end)
  end)

  describe("L13 — the main Fury dump", function()
    -- ⚠ THE GATE IS THE CLIENT'S VERDICT, NOT A NUMBER.  `broke` means the client answered
    -- `insufficientPower = true` for Chaos Strike; nothing here knows or asks how much Fury
    -- that corresponds to, and nothing may.
    it("presses when the client says affordable, and holds when it says broke", function()
      assert.equals(ID.CS, winner({}).cid)
      assert.is_nil(winner({ broke = true }))
    end)

    -- In demon form the frame casts Annihilation, and the NOTE says so — the label is the
    -- pipeline's, the cue key stays the base.
    it("keys on the base frame in demon form, and says Annihilation", function()
      local w = winner({ metaXform = "cs" })
      assert.equals(ID.CS, w.cid)
      assert.equals("Annihilation", w.cue.note)
    end)

    it("carries no note outside demon form", function()
      assert.is_nil(winner({}).cue.note)
    end)

    -- Degradation: an untracked Chaos Strike yields a nil spenderKey and BOTH spend lines
    -- simply find nothing rather than cueing a ghost.
    it("finds nothing when Chaos Strike is untracked, and the list continues", function()
      local w = winner({ noSpender = true, throwGlaive = cdReady() })
      assert.equals(ID.TG, w.cid)        -- straight through to L15
      assert.is_nil(ctxOf({ noSpender = true }).spenderKey)
    end)
  end)

  it("L15 — Throw Glaive is the floor", function()
    -- ⚠ THE SPENDER SITS ABOVE IT (L13), so reaching the floor at all needs L13 shut.
    assert.equals(ID.TG, winner({ throwGlaive = cdReady(), afford = { [ID.CS] = false } }).cid)
    assert.is_nil(winner({ throwGlaive = cdReady(), broke = true }))
  end)

  -- Honest silence: every cooldown down and not enough Fury to spend is a REAL state, not a
  -- bug.  It shows in the decision log as `w:-`.  ⚠ On this spec a HIGH in-combat `w:-` means
  -- the Fury rail is not being read — Chaos Strike has no cooldown at all, so L13 is
  -- reachable on every tick the bar carries 40 Fury.
  it("returns no press when nothing is castable", function()
    assert.is_nil(winner({ broke = true }))
  end)

  ----------------------------------------------------------------------------
  -- Rain from Above — the knowingly DEAD icon.
  ----------------------------------------------------------------------------
  -- A tracked Essential with a real 90 s cooldown that appears NOWHERE in the 140-line APL.
  -- Registered so the decision log can name it and Coverage does not report it blind; cued by
  -- nothing, and `cadence = "utility"` keeps an anticipation glow off a button the HUD will
  -- never recommend.
  describe("Rain from Above", function()
    it("is never the press, however ready it is", function()
      local g = guidance({ rfa = cdReady(), broke = true })
      assert.is_nil(pressOf(g))
      assert.is_nil(g.cues[ID.RFA])
    end)

    it("never takes a SOON decoration either", function()
      local g = guidance({ rfa = cdSoon(1), throwGlaive = cdReady() })
      assert.is_nil(soonSet(g)[ID.RFA])
    end)
  end)

  ----------------------------------------------------------------------------
  -- CHARGES — the count outranks the cooldown read, and on THIS spec it is the mitigation.
  ----------------------------------------------------------------------------
  -- ⚠ THREE OF HAVOC'S BUTTONS REPORT A BASE COOLDOWN THAT IS **WRONG**, not merely absent:
  -- Fel Rush 1 s against a real 10 s, Immolation Aura 2 s against 30 s, Vengeful Retreat
  -- 0.5 s against 25 s (T1 DB2 @ 12.0.7 — a short shared-category lockout on the spell row
  -- masking the real charge recovery).  A LIE defeats the mitigation an honest zero gets:
  -- HudNapkin's declared-`chargeCD` fallback is gated on `not (len > 0)`, which a lying 1
  -- passes.  What saves the press is that all three are ONE-charge categories and
  -- `usable()`'s one-charge rule requires BOTH a banked charge AND `probablyUp` — so the
  -- count, which only restores on the `ChargeGained` alert at the REAL recovery, vetoes the
  -- early cooldown read for the whole duration.  These are the cases that pin it.
  -- ⚠ EVERY CASE BELOW CARRIES `broke = true`, and it is load-bearing rather than noise: the
  -- fixture's Fury default INVERTED on 2026-08-03.  It used to be `fury = 0` (nothing
  -- affordable), so a case that omitted the field got a silent spender-free board; the
  -- affordability fixture defaults to AFFORDABLE, so L13 would take every press below and
  -- these cases would assert the spender rather than the charge rule.
  describe("charge-aware readiness on a 1-charge pool", function()
    it("a count of ZERO vetoes a cooldown that reads READY", function()
      -- The lying-napkin shape exactly: the base cooldown expired after ~1 s, the charge is
      -- still recharging for another 9.  The COUNT decides.
      assert.is_nil(winner({ mode = "aoe", broke = true, felRush = cdReady(),
                             frCharge = { charged = true, cur = 0, max = 1 } }))
    end)

    it("both agreeing is usable", function()
      local w = winner({ mode = "aoe", broke = true, felRush = cdReady(),
                         frCharge = { charged = true, cur = 1, max = 1 } })
      assert.equals(ID.FR, w.cid)
    end)

    it("a banked charge does NOT outrank a cooldown that reads down", function()
      assert.is_nil(winner({ mode = "aoe", broke = true, felRush = cdSoon(9),
                             frCharge = { charged = true, cur = 1, max = 1 } }))
    end)

    -- ⚠ THE RESIDUAL HOLE, and it is flight question #1: with NO count at all — `ch.charged`
    -- false, or no out-of-combat seed, since `C_Spell.GetSpellCharges` is combat-gated —
    -- `usable()` falls through to the cooldown read and the early napkin wins.  This case
    -- documents today's behaviour so the flight can arbitrate it; it is NOT an endorsement,
    -- and the one-line fix is recorded in specs/havoc/rotation.md.
    it("an ABSENT count falls back to the cooldown read (the documented residual hole)", function()
      local w = winner({ mode = "aoe", broke = true, felRush = cdReady(),
                         frCharge = { charged = true, cur = nil, max = 1 } })
      assert.equals(ID.FR, w.cid)
    end)

    it("...and that fallback still respects a cooldown that is NOT ready", function()
      assert.is_nil(winner({ mode = "aoe", broke = true, felRush = cdFar(),
                             frCharge = { charged = true, cur = nil, max = 1 } }))
    end)

    it("no charge pool at all falls back to the cooldown read", function()
      assert.equals(ID.VR, winner({ vr = cdReady(), eyeBeam = cdReady(), broke = true }).cid)
    end)

    -- ⚠ THE CONFLAGRATE RULE IS UNTOUCHED.  With A Fire Inside, Immolation Aura is a 2-charge
    -- pool, and one banked charge while the second recharges is the NORMAL state — so there
    -- the count still outranks the cooldown.  If this goes red, the one-charge rule has been
    -- over-generalised.
    it("a 2-charge pool still lets a banked charge outrank the cooldown", function()
      local w = winner({ mode = "aoe", broke = true, immo = cdSoon(10),
                         immoCharge = { charged = true, cur = 1, max = 2 } })
      assert.equals(ID.IA, w.cid)
    end)

    it("...and a 2-charge pool at ZERO is still vetoed", function()
      assert.is_nil(winner({ mode = "aoe", broke = true, immo = cdReady(),
                             immoCharge = { charged = true, cur = 0, max = 2 } }))
    end)
  end)

  ----------------------------------------------------------------------------
  -- AFFORDABILITY — the client's per-spell verdict, which REPLACED the Fury comparison.
  ----------------------------------------------------------------------------
  -- ⚠⚠ THIS BLOCK REPLACED "the spender cost is resolved live" ON 2026-08-03.  That block
  -- drove four live COSTS through `fx.powerCost` and compared them against a Fury number the
  -- fixture supplied — nine cases, all green, over a rotation that could not fire in game,
  -- because `UnitPower("player", Fury)` is SECRET and the number never existed.  The cost
  -- READER (`ns.PowerCost`) is still shipped and still tested by the three other oracles;
  -- what is gone is any Havoc gate that consumes a cost.  ⚠ DB2 COSTS ARE NOT THE CLIENT'S
  -- COSTS EITHER: Throw Glaive's DB2 cost of 25 was measured FREE in game, which is why the
  -- old fallback made L15 win 770 of 2380 flight lines.
  describe("affordability replaces the Fury comparison", function()
    -- ⚠ THE CASE THE IN-GAME MACRO PROVED, and the one no Fury-number fixture could express:
    -- at ONE Fury level, Chaos Strike / Eye Beam / Blade Dance all reported
    -- `insufficientPower = true` while Throw Glaive reported FALSE — because the flag is
    -- computed PER SPELL against its own cost.  Both halves must hold in the SAME pulse.
    it("blocks L13 while letting L15 through, in one pulse", function()
      local g = guidance({ throwGlaive = cdReady(),
                           afford = { [ID.CS] = false, [ID.TG] = true } })
      assert.equals(ID.TG, pressOf(g).cid)
    end)

    it("...and the reverse, so the discrimination is not an ordering accident", function()
      local g = guidance({ throwGlaive = cdReady(),
                           afford = { [ID.CS] = true, [ID.TG] = false } })
      assert.equals(ID.CS, pressOf(g).cid)
    end)

    -- ⚠⚠ AN UNREADABLE VERDICT MUST NOT BLOCK THE PRESS, and the direction is the whole
    -- lesson of the flight.  `{ readable = false }` means "we could not ask" — a DIFFERENT
    -- fact from "you cannot afford it" — and defaulting it to unaffordable is exactly what
    -- `ctx.fury or 0` did: it made every spender unaffordable forever.  The safe default here
    -- is ALLOW, because the CDM / napkin / charge readiness gate still sits in front of every
    -- line, so the worst case is a cue for a press that fails.
    it("does not block on an UNREADABLE verdict — absent is not `broke`", function()
      assert.equals(ID.CS, winner({ affordUnreadable = true }).cid)
      assert.equals(ID.EB, winner({ affordUnreadable = true, eyeBeam = cdReady() }).cid)
    end)

    -- The three non-spender gates ride the same channel, so each is pinned.
    it("gates Blade Dance (L7/L10), Eye Beam (L9) and Throw Glaive (L15) too", function()
      assert.equals(ID.CS, winner({ bladeDance = cdReady(), afford = { [ID.BD] = false } }).cid)
      assert.equals(ID.BD, winner({ bladeDance = cdReady() }).cid)
      assert.equals(ID.CS, winner({ eyeBeam = cdReady(), afford = { [ID.EB] = false } }).cid)
      assert.is_nil(winner({ throwGlaive = cdReady(), afford = { [ID.TG] = false, [ID.CS] = false } }))
    end)

    -- L8 rides the SAME verdict as L13 — one ability, one answer, two lines.
    it("gates both spender lines off one verdict", function()
      assert.equals(ID.EB, winner({ ebCast = true, eyeBeam = cdReady(),
                                    afford = { [ID.CS] = false } }).cid)
    end)

    -- ⚠ THE GATES THE LIST DELIBERATELY DOES **NOT** ASK.  Felblade, Immolation Aura, Fel
    -- Rush and Vengeful Retreat are generators, and Essence Break has no Fury cost at all —
    -- State fences the read on the spec's `spends`, so `broke` must leave every one of them
    -- pressable.  A regression here means an affordability gate has crept onto a generator,
    -- which would jam the whole list shut the moment the client says "broke".
    it("never gates a GENERATOR on affordability", function()
      assert.equals(ID.FB, winner({ felblade = cdReady(), broke = true }).cid)
      assert.equals(ID.IA, winner({ immo = cdReady(), broke = true }).cid)
      assert.equals(ID.META, winner({ meta = cdReady(), broke = true }).cid)
      assert.equals(ID.HUNT, winner({ hunt = cdReady(), broke = true }).cid)
      assert.equals(ID.ESSB, winner({ metaBuff = true, essenceBreak = cdReady(), broke = true }).cid)
    end)

    -- The published flags, so the decision log and a future reader can see the verdict that
    -- decided the line rather than re-deriving it.
    it("publishes the four verdicts on the context", function()
      local ctx = ctxOf({ afford = { [ID.CS] = false } })
      assert.is_false(ctx.spenderAfford)
      assert.is_true(ctx.danceAfford)
      assert.is_true(ctx.eyeBeamAfford)
      assert.is_true(ctx.glaiveAfford)
    end)

    -- The spec still DECLARES Fury as its cost resource — the rail is published even though
    -- nothing compares it, which is what keeps `PW:` alive (`display = "none"`'s argument).
    it("resolves Fury as the spec\'s cost resource, off its own powers block", function()
      assert.equals(FURY, ns.Coach.CostPowerType(ns.ActiveSpec))
    end)
  end)

  ----------------------------------------------------------------------------
  -- The honest SECOND PLACE — the winner's ability removed, the list re-run.
  ----------------------------------------------------------------------------
  -- ⚠ THE EXCLUSION IS BY BASE SPELLID, so it drops EVERY line that names the ability.
  -- Immolation Aura sits on L4 and L12, Blade Dance on L7 and L10, the spender on L8 and L13
  -- — each pair keyed on ONE base spellID, so the runner-up is a genuine re-run and never
  -- "the same button one line down".
  describe("the runner-up", function()
    it("re-runs the whole list with the winner's ability excluded", function()
      local g = guidance({ meta = cdReady(), hunt = cdReady() })
      assert.equals(ID.META, pressOf(g).cid)
      assert.equals(ID.HUNT, fallbackOf(g).cid)
    end)

    it("drops Immolation Aura from BOTH of its lines at once", function()
      local g = guidance({ mode = "aoe", immo = cdReady(), felblade = cdReady(), broke = true })
      assert.equals(ID.IA, pressOf(g).cid)           -- L4
      local fb = fallbackOf(g)
      assert.is_not_nil(fb)
      assert.are_not.equals(ID.IA, fb.cid)           -- NOT L12's Immolation Aura again
      assert.equals(ID.FB, fb.cid)                   -- L11
    end)

    it("drops the spender from BOTH of its lines at once", function()
      local g = guidance({ ebCast = true, throwGlaive = cdReady() })
      assert.equals(ID.CS, pressOf(g).cid)           -- L8
      local fb = fallbackOf(g)
      assert.is_not_nil(fb)
      assert.are_not.equals(ID.CS, fb.cid)           -- NOT L13's spender again
      assert.equals(ID.TG, fb.cid)                   -- L15
    end)

    it("drops Blade Dance from whichever line named it", function()
      local inMeta = guidance({ metaBuff = true, bladeDance = cdReady() })
      assert.equals(ID.BD, pressOf(inMeta).cid)      -- L7
      assert.are_not.equals(ID.BD, fallbackOf(inMeta).cid)
      local outside = guidance({ bladeDance = cdReady() })
      assert.equals(ID.BD, pressOf(outside).cid)     -- L10
      assert.are_not.equals(ID.BD, fallbackOf(outside).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- SOON — a DUMB per-ability decoration, independent of the winner.
  ----------------------------------------------------------------------------
  describe("SOON", function()
    it("decorates a tracked cooldown coming up within the lead", function()
      local g = guidance({ throwGlaive = cdReady(), meta = cdSoon(2),
                           afford = { [ID.CS] = false } })
      assert.equals(ID.TG, pressOf(g).cid)
      assert.is_true(soonSet(g)[ID.META])
    end)

    -- ⚠ THE SAME FINDING FROM THE OTHER SIDE: the SOON fence tests the SPEC-AUTHORED cadence,
    -- so a CDM-Utility ROW with a rotational cadence still decorates, while a spec-declared
    -- `cadence = "utility"` never does.
    it("decorates a CDM-Utility row whose spec cadence is rotational", function()
      local g = guidance({ throwGlaive = cdReady(), felblade = cdSoon(2) })
      assert.is_true(soonSet(g)[ID.FB])
    end)

    it("never decorates a spec-declared utility", function()
      local g = guidance({ throwGlaive = cdReady(), utility = cdSoon(1) })
      assert.is_nil(soonSet(g)[ID.UTILITY])
    end)

    it("does not decorate something far out", function()
      local g = guidance({ throwGlaive = cdReady(), meta = cdFar() })
      assert.is_nil(soonSet(g)[ID.META])
    end)
  end)

  ----------------------------------------------------------------------------
  -- Escalate — ROTATION -> LATE, from READABLE overdue-ness only.
  ----------------------------------------------------------------------------
  describe("Escalate", function()
    local function overdue() return cdReady(10) end   -- ready, and sat there past LATE_LEAD

    -- ⚠ ONLY THE FOUR SPELL-ROW COOLDOWNS.  Metamorphosis (120 s), The Hunt (90 s), Eye Beam
    -- (30 s) and Blade Dance (15 s) carry their cooldown as `CategoryRecoveryTime` on the
    -- SPELL row, so ns.BaseCooldown reads them and the ready-edge means something.
    it("calls Metamorphosis LATE once it has sat past the lead", function()
      local w = winner({ meta = overdue() })
      assert.equals(ID.META, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("does the same for The Hunt, Eye Beam and Blade Dance", function()
      assert.equals("LATE", winner({ hunt = overdue() }).cue.emphasis)
      assert.equals("LATE", winner({ eyeBeam = overdue() }).cue.emphasis)
      assert.equals("LATE", winner({ bladeDance = overdue() }).cue.emphasis)
    end)

    -- ⚠ EVERY ABILITY ON A CHARGE CATEGORY IS DELIBERATELY ABSENT: a charged ability raises
    -- `Available` on every charge restore and never `OnCooldown`, so its edge latches and
    -- `overdue` would fire constantly.  Escalating on a signal we cannot trust is exactly
    -- what this method is forbidden to do.
    it("never escalates Vengeful Retreat — its readiness edge is untrustworthy", function()
      local w = winner({ vr = overdue(), eyeBeam = cdReady() })
      assert.equals(ID.VR, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)

    it("never escalates Immolation Aura or Fel Rush either", function()
      assert.equals("ROTATION", winner({ mode = "aoe", immo = overdue() }).cue.emphasis)
      assert.equals("ROTATION", winner({ mode = "aoe", felRush = overdue(),
                                         frCharge = { charged = true, cur = 1, max = 1 } })
                                  .cue.emphasis)
    end)

    -- Essence Break is absent for a DIFFERENT reason: its RecoveryTime is honest, but it is
    -- META-GATED (L6), so a ready Essence Break outside demon form is correctly idle rather
    -- than late — and escalating it would nag for a press the list refuses to make.
    it("never escalates Essence Break, whose gate is the fork rather than the cooldown", function()
      local w = winner({ metaBuff = true, essenceBreak = overdue() })
      assert.equals(ID.ESSB, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)

    -- ⚠⚠ THE "SPENDER PARKED AT A FULL FURY BAR" RULE IS **DELETED**, AND THE CASE THAT
    -- PINNED IT WITH IT (2026-08-03).  It was Destruction's Chaos-Bolt-at-full-bar analogue
    -- and it read `ctx.fury >= ctx.furyMax` — a comparison against a value that does not
    -- exist.  In game it fired on `0 >= 120`, i.e. never; restoring it against any fabricated
    -- number would make it fire ALWAYS, which is worse.  ⚠ IT IS ALSO NOT RECOVERABLE through
    -- `IsSpellUsable`, which is BINARY — a spender is equally "affordable" at 40 Fury and at
    -- 170, so overcap is invisible to it BY CONSTRUCTION.  This is the one thing Phase 1
    -- knowingly gives up; Phase 2's LuaCurveObject is the only route back.
    -- This case replaces both, and asserts the ABSENCE so nobody quietly re-adds the rule.
    it("never calls the spender LATE — overcap is unreadable, not merely unread", function()
      local w = winner({})
      assert.equals(ID.CS, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)

    it("never escalates a filler", function()
      local w = winner({ throwGlaive = overdue(), afford = { [ID.CS] = false } })
      assert.equals(ID.TG, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)
  end)

  ----------------------------------------------------------------------------
  -- END TO END, THROUGH THE REAL `St.Build` — the case that would have caught the flight.
  ----------------------------------------------------------------------------
  -- ⚠⚠ NOTHING TESTED State -> resourceBars -> the BRAIN for a **REFUSED** rail before
  -- 2026-08-03, and that is the hole the whole flight fell through.  Every case above hands
  -- the Coach a hand-built pulse, so the rail arrived exactly as the fixture wrote it — and
  -- the fixture always wrote a number the client refuses.  This block drives the SHIPPING
  -- State with `UnitPower` refusing (the only thing Fury ever does) and asserts the three
  -- places the old code manufactured a zero.
  describe("a REFUSED Fury rail, driven through the real State", function()
    local FURY_TYPE = 17
    local realShouldBeSecret
    local function pulse()
      H.load("State.lua")
      -- The rail the game actually presents: MAX readable (a different secrecy predicate),
      -- VALUE refused.  `unmodified` is omitted too — the exact read is just as secret.
      H.fx.power[FURY_TYPE] = { max = 170 }
      realShouldBeSecret = _G.C_Secrets
      _G.C_Secrets = { ShouldUnitPowerBeSecret = function(_, t) return t == FURY_TYPE end }
      -- ⚠ `OnLogin` builds the Enum.PowerType name cache; without it `readPower` walks an
      -- empty map and the pulse carries NO rail at all — which is a different (and much
      -- quieter) failure than the refused one under test.
      ns.OnLogin()
      return ns.State.Build(false)
    end
    after_each(function() _G.C_Secrets = realShouldBeSecret end)

    it("State reports the rail unreadable AND says it is restricted", function()
      local p = pulse().power.Fury
      assert.is_false(p.readable)
      assert.is_true(p.restricted)
      -- ⚠ `is_nil`, never `equals(0, …)`.  This half was always correct; the two coercions
      -- downstream are what undid it.
      assert.is_nil(p.value)
      assert.is_nil(p.unmodified)
      assert.equals(170, p.max)
    end)

    it("the bar carries the absence through to the Coach, not a zero", function()
      local bar = Coach:Compute(pulse()).resourceBars[1]
      assert.is_nil(bar.value)
      assert.is_nil(bar.valueExact)
      assert.is_true(bar.restricted)
    end)

    it("and the brain does not behave as though Fury were 0", function()
      local ctx = ns.Specs[577]:Context(pulse(), Coach)
      assert.is_nil(ctx.fury)
      assert.is_true(ctx.furyRestricted)
      -- The flight's signature, asserted as an ABSENCE: at a fabricated zero every spender
      -- was unaffordable and every generator maximally urgent.  With no verdict available
      -- the affordability gates fall through to ALLOWED instead.
      assert.is_true(ctx.spenderAfford)
      assert.is_true(ctx.eyeBeamAfford)
    end)

    it("...and the decision log says `restricted` rather than a number", function()
      H.load("DecisionLog.lua")
      local p = pulse()
      local line = ns.DecisionLog.Render(p, Coach:Compute(p), { cues = {} })
      assert.is_truthy(line:match("PW:restricted"), "PW column read: " .. tostring(line:match("PW:%S+")))
    end)
  end)

  ----------------------------------------------------------------------------
  -- The hero tree rides the PULSE, and is never inferred (field-fix B).
  ----------------------------------------------------------------------------
  describe("hero tree", function()
    it("carries the pulse's answer through", function()
      local ctx = ctxOf({ hero = "aldrachi-reaver" })
      assert.equals("aldrachi-reaver", ctx.hero)
      assert.is_true(ctx.aldrachi)
    end)

    it("stays nil when State could not read it — never a guess", function()
      local ctx = ctxOf({})
      assert.is_nil(ctx.hero)
      assert.is_false(ctx.aldrachi)
    end)

    -- ⚠ NO INFERENCE FALLBACK, and that is deliberate.  L1 fires because the Throw Glaive
    -- frame is VISIBLY transformed — an Aldrachi Reaver fact that announces itself — and
    -- every Fel-Scarred addition is a display override on a frame the list already presses.
    -- So the tree gates NOTHING, and a Fel-Scarred pulse simply never sees an armed L1.
    it("gates no line: Fel-Scarred plays the same list", function()
      local w = winner({ hero = "fel-scarred", meta = cdReady(), hunt = cdReady() })
      assert.equals(ID.META, w.cid)
    end)

    it("...and an armed L1 fires regardless of what the pulse says the tree is", function()
      local w = winner({ hero = nil, rgXform = true, meta = cdReady() })
      assert.equals(ID.TG, w.cid)
      assert.equals("Reaver's Glaive", w.cue.note)
    end)
  end)
end)
