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
-- The list under test (specs/havoc/rotation.md; first usable line = the press):
--   L1   Reaver's Glaive     whenever the Throw Glaive frame shows it
--   L2   Metamorphosis       Inner Demon down, Blade Dance not available
--   L3   The Hunt            outside an Essence Break window, no glaive armed
--   L4   Immolation Aura     [AoE]
--   L5   Vengeful Retreat    Eye Beam up-or-nearly, Initiative down
--   L6   Essence Break       [META] fury >= 35
--   L7   Blade Dance         [META] -> Death Sweep
--   L8   the spender         inside an Essence Break window
--   L9   Eye Beam            -> Abyssal Gaze
--   L10  Blade Dance         [NO META]
--   L11  Felblade            fury deficit >= 40
--   L12  Immolation Aura     fury deficit >= 20
--   L13  the spender         the main dump (-> Annihilation in meta)
--   L14  Fel Rush            [AoE]
--   L15  Throw Glaive        the floor
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

-- `Enum.PowerType.Fury`, per the harness and the client (LuaEnum.lua:5681).  A cost fixture
-- is denominated in a RESOURCE; SOUL_SHARDS is here to prove the type filter REJECTS a cost
-- that is not this spec's — the exact shape that shipped a Retribution defect.
local FURY = 17
local SOUL_SHARDS = 7

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
-- usable — the safe reading); the spender is always present with an `unknown` cd, since its
-- gate is Fury and nothing else.
--   fury / furyMax    the live rail (0-120, modifier 1 — no unit games)
--   exactRefused      drop the exact read, exercising the value x modifier fallback
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
--   inflightSpender   put the spender in flight, so `projected = fury - cost`
--   spenderCost / danceCost / eyeBeamCost / glaiveCost   the LIVE costs the client reports
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

  -- The live costs, driven at CLIENT level (`fx.powerCost` fakes C_Spell.GetSpellPowerCost),
  -- so the shipping `ns.PowerCost` ladder runs for real — the type filter, the secret guards
  -- and the three-valued return.
  -- ⚠ ASSIGNED UNCONDITIONALLY, INCLUDING nil.  `H.fx` is minted once per test, not once per
  -- build, so a cost set by an earlier build() in the SAME test would leak into the next one,
  -- invisibly (a stale cost still produces a plausible press).
  -- ⚠ AND BOTH IDS OF EACH PAIR, because `costOf` asks about the LIVE spell: in demon form
  -- the spender's cost comes from Annihilation's own id, not Chaos Strike's.
  local function setCost(id, cost)
    H.fx.powerCost[id] = cost ~= nil
      and { { type = FURY, cost = cost, name = "FURY" } } or nil
  end
  setCost(ID.CS, f.spenderCost);  setCost(ID.ANNI, f.spenderCost)
  setCost(ID.BD, f.danceCost);    setCost(ID.DSWEEP, f.danceCost)
  setCost(ID.EB, f.eyeBeamCost);  setCost(ID.AGAZE, f.eyeBeamCost)
  setCost(ID.TG, f.glaiveCost);   setCost(ID.RG, f.glaiveCost)

  -- History drives TWO independent channels, and neither is an aura read:
  --   * the ESSENCE BREAK WINDOW (ns.Coach.CommittedWithin against 258860) — the debuff
  --     320338 has no CDM row, so the window is derived from the CAST.
  --   * the IN-FLIGHT PROJECTION (ns.Coach.InflightPower x ns.SpecPowerDelta).
  local history = {}
  if f.ebCast then
    history[#history + 1] = { phase = "succeeded", spellID = ID.ESSB, base = ID.ESSB,
                              at = NOW - (f.ebCastAge or 2) }
  end
  if f.inflightSpender then
    -- ⚠ A COST IS REQUIRED FOR A PROJECTION TO EXIST.  SpecPowerDelta reads the cost and
    -- declines (delta 0) when the client has no answer — the documented safe direction, since
    -- it never pre-deducts Fury we are not sure will be spent.  A fixture that forgot this
    -- would be asserting the refusal path while believing it asserted the projection.
    setCost(ID.CS, f.spenderCost or 40)
    -- Placed outside CAST_FRESH (1.0) but inside the flight window (3.0), so it is in flight
    -- without also raising the cast_started EDGE (a different question, tested elsewhere).
    history[#history + 1] = { phase = "start", spellID = ID.CS, base = ID.CS, at = NOW - 2 }
  end

  -- ⚠ FURY'S MODIFIER IS 1, so the exact rail and the display rail are the SAME integer.
  -- This is the fixture's cheapest statement that none of Destruction's fragment arithmetic
  -- applies: `unmodified` == `value`, `unmodifiedMax` == `max`.  `f.exactRefused` drops the
  -- exact read, exercising the value x modifier fallback (which, at modifier 1, must produce
  -- the identical number).
  local fury, furyMax = f.fury or 0, f.furyMax or 120
  local bar = { value = fury, max = furyMax, readable = true }
  if not f.exactRefused then
    bar.unmodified, bar.unmodifiedMax, bar.modifier = fury, furyMax, 1
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
  describe("Fury rides the whole rail with display = \"none\"", function()
    it("emits exactly one resourceBar, marked `none`", function()
      local bars = guidance({ fury = 40 }).resourceBars
      assert.equals(1, #bars)
      assert.equals("none", bars[1].display)
      assert.equals("FURY", bars[1].powerType)
    end)

    it("carries real numbers, not a placeholder", function()
      local bar = guidance({ fury = 40 }).resourceBars[1]
      assert.equals(40, bar.value)
      assert.equals(120, bar.max)
      assert.equals(40, bar.valueExact)
      assert.equals(1, bar.modifier)
    end)

    -- Fury's modifier is 1, so the fallback path (display x modifier) must produce the SAME
    -- number the exact read would have.  This is the case that would catch a stray
    -- Destruction-style x10 conversion copied into this spec.
    it("reads the same value when the exact rail refuses (modifier 1)", function()
      assert.equals(ID.CS, winner({ fury = 40, exactRefused = true }).cid)
      assert.is_nil(winner({ fury = 39, exactRefused = true }))
    end)

    -- ⚠ THE END OF THE CHAIN, and the whole argument for `none` over an empty `spec.powers`.
    -- An empty powers array emits no bar at all and DecisionLog's `PW:` renders `?/?` for the
    -- entire spec — losing the one instrument that can explain a decision nobody watched.
    -- Asserting the bar is not enough; this asserts the COLUMN.
    it("reaches the decision log's PW column as real numbers, not `?/?`", function()
      H.load("DecisionLog.lua")
      local pulse = build({ fury = 40 })
      local line = ns.DecisionLog.Render(pulse, Coach:Compute(pulse), { cues = {} })
      assert.is_truthy(line:match("PW:40/%+0"), "PW column read: " .. tostring(line:match("PW:%S+")))
    end)

    -- The decision log must be able to say WHICH source forked the list — a fork nobody can
    -- explain is exactly the hole the Destruction field capture fell into.
    it("names Metamorphosis in the PR column when the buff row is up", function()
      H.load("DecisionLog.lua")
      local pulse = build({ fury = 40, metaBuff = true })
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
      local w = winner({ rgXform = true, throwGlaive = cdFar(), fury = 0,
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

    -- simc:103 is the longest single line in the APL and only THREE of its terms survive.
    it("is vetoed by Inner Demon", function()
      local w = winner({ meta = cdReady(), hunt = cdReady(), innerDemon = true })
      assert.equals(ID.HUNT, w.cid)
    end)

    -- `cooldown.blade_dance.remains` means "Blade Dance is ON cooldown" — one of the few
    -- cooldown-remains terms in this APL that survives as a BOOLEAN rather than a duration.
    it("is vetoed by an AVAILABLE Blade Dance", function()
      local w = winner({ meta = cdReady(), bladeDance = cdReady(), fury = 40 })
      assert.equals(ID.BD, w.cid)        -- L10 takes it instead
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
      assert.is_nil(winner({ hunt = cdReady(), ebCast = true }))
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
      local w = winner({ mode = "aoe", immo = cdReady(), eyeBeam = cdReady(), fury = 40 })
      assert.equals(ID.IA, w.cid)
      assert.equals("AoE", w.cue.note)
    end)

    it("...and not in single-target, where L12's deficit gate governs instead", function()
      -- fury 110 => deficit 10, below IMMO_DEFICIT (20): no Immolation Aura at all.
      local w = winner({ mode = "st", immo = cdReady(), fury = 110 })
      assert.equals(ID.CS, w.cid)        -- straight to L13
    end)

    it("L14 — Fel Rush fires in AoE mode, below the spender", function()
      -- fury 0 keeps L13 shut, so the AoE filler is reachable.
      local w = winner({ mode = "aoe", felRush = cdReady(),
                         frCharge = { charged = true, cur = 1, max = 1 } })
      assert.equals(ID.FR, w.cid)
      assert.equals("AoE", w.cue.note)
    end)

    it("...and never in single-target", function()
      assert.is_nil(winner({ mode = "st", felRush = cdReady(),
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
      local w = winner({ vr = cdReady(), eyeBeam = cdReady(), fury = 40 })
      assert.equals(ID.VR, w.cid)
      assert.equals("before Eye Beam", w.cue.note)
    end)

    -- simc: `cooldown.eye_beam.remains <= gcd.remains`, i.e. about one GCD out.
    it("fires on the eyeBeamSoon napkin gate, inside the lead", function()
      local w = winner({ vr = cdReady(), eyeBeam = cdSoon(1.0) })
      assert.equals(ID.VR, w.cid)
    end)

    it("does NOT fire when Eye Beam is still outside the lead", function()
      assert.is_nil(winner({ vr = cdReady(), eyeBeam = cdSoon(2.5) }))
      assert.is_false(ctxOf({ eyeBeam = cdSoon(2.5) }).eyeBeamSoon)
    end)

    -- Vengeful Retreat exists to PROC Initiative, so pressing it while the buff is already
    -- up wastes the retreat (simc's `!buff.initiative.up`).
    it("is vetoed while Initiative is up", function()
      local w = winner({ vr = cdReady(), eyeBeam = cdReady(), fury = 40, initiative = true })
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
    it("fires in demon form at 35 Fury", function()
      local w = winner({ metaBuff = true, essenceBreak = cdReady(), fury = 35 })
      assert.equals(ID.ESSB, w.cid)
    end)

    it("does NOT fire outside demon form, however ready it is", function()
      local w = winner({ essenceBreak = cdReady(), fury = 40 })
      assert.equals(ID.CS, w.cid)        -- falls through to L13
    end)

    -- `fury >= 35` is simc's own number, and it reads the LIVE rail (a press gate, not a
    -- pooling rule).
    it("holds below 35 Fury", function()
      local w = winner({ metaBuff = true, essenceBreak = cdReady(), fury = 34 })
      assert.is_nil(w)
    end)

    -- It forks on the TRANSFORM source just as well as on the buff row.
    it("fires off the transform source alone", function()
      local w = winner({ metaXform = "cs", essenceBreak = cdReady(), fury = 35 })
      assert.equals(ID.ESSB, w.cid)
    end)
  end)

  describe("L7 vs L10 — the Blade Dance / Eye Beam inversion", function()
    -- In demon form Death Sweep heads the meta list (actions.meta:118 / :122 / :130, all
    -- above eye_beam at :129); out of it Eye Beam comes first (:86 above :88).
    it("in meta, Blade Dance OUTRANKS Eye Beam", function()
      local g = guidance({ metaBuff = true, bladeDance = cdReady(), eyeBeam = cdReady(),
                           fury = 40 })
      local w = pressOf(g)
      assert.equals(ID.BD, w.cid)
      assert.equals("Death Sweep", w.cue.note)
      assert.equals(ID.EB, fallbackOf(g).cid)
    end)

    it("outside meta, Eye Beam OUTRANKS Blade Dance", function()
      local g = guidance({ bladeDance = cdReady(), eyeBeam = cdReady(), fury = 40 })
      assert.equals(ID.EB, pressOf(g).cid)
      assert.is_nil(pressOf(g).cue.note)
      assert.equals(ID.BD, fallbackOf(g).cid)
    end)

    it("L10 is silent in meta and L7 is silent outside it", function()
      -- Eye Beam absent from the board on both sides, so only the Blade Dance line can fire
      -- and the NOTE says which one did.
      local inMeta = winner({ metaBuff = true, bladeDance = cdReady(), fury = 40 })
      assert.equals("Death Sweep", inMeta.cue.note)
      local outside = winner({ bladeDance = cdReady(), fury = 40 })
      assert.is_nil(outside.cue.note)
    end)

    -- ⚠ `variable.use_blade_dance` IS TREATED AS TRUE — the one place this list deliberately
    -- chooses OVER-pressing.  simc gates it on three unreadable talents, and First Blood (the
    -- standard single-target pick) makes Blade Dance a full ST spender; gating on `mode ==
    -- "aoe"` would make it invisible for the whole single-target rotation of that build.
    it("offers Blade Dance in SINGLE-TARGET, not only in AoE", function()
      assert.equals(ID.BD, winner({ mode = "st", bladeDance = cdReady(), fury = 40 }).cid)
    end)

    it("holds Blade Dance below its cost", function()
      assert.is_nil(winner({ bladeDance = cdReady(), fury = 34 }))
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
      local g = guidance({ ebCast = true, eyeBeam = cdReady(), fury = 40 })
      local w = pressOf(g)
      assert.equals(ID.CS, w.cid)
      assert.equals("Essence Break window", w.cue.note)
    end)

    it("does not, once the window has elapsed", function()
      local w = winner({ ebCast = true, ebCastAge = 5, eyeBeam = cdReady(), fury = 40 })
      assert.equals(ID.EB, w.cid)
    end)

    it("does not, with no Essence Break cast at all", function()
      local w = winner({ eyeBeam = cdReady(), fury = 40 })
      assert.equals(ID.EB, w.cid)
      assert.is_false(ctxOf({}).ebWindow)
    end)

    it("still respects affordability inside the window", function()
      local w = winner({ ebCast = true, eyeBeam = cdReady(), fury = 39 })
      assert.equals(ID.EB, w.cid)        -- 39 < 40: L8 holds, L9 takes it
    end)

    -- The window boundary itself: `CommittedWithin` is inclusive at EB_WINDOW.
    it("holds the window open for exactly EB_WINDOW seconds", function()
      assert.is_true(ctxOf({ ebCast = true, ebCastAge = 4.0 }).ebWindow)
      assert.is_false(ctxOf({ ebCast = true, ebCastAge = 4.1 }).ebWindow)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L9 / L11 / L12 / L13 / L15 — the body of the list.
  ----------------------------------------------------------------------------
  it("L9 — Eye Beam on cooldown, once affordable", function()
    assert.equals(ID.EB, winner({ eyeBeam = cdReady(), fury = 30 }).cid)
    assert.is_nil(winner({ eyeBeam = cdReady(), fury = 29 }))
  end)

  -- Fel-Scarred draws this frame as ABYSSAL GAZE, and the cue key is unchanged — the icon
  -- already shows the right art, which is the whole reason the fork needs no second cascade.
  it("L9 — the Abyssal Gaze override does not move the cue key", function()
    local w = winner({ eyeBeam = cdReady(), agaze = true, fury = 30 })
    assert.equals(ID.EB, w.cid)
  end)

  describe("L11 / L12 — the two Fury generator lines", function()
    -- simc's `fury.deficit>=15+gen*0.5` becomes a flat threshold: `fury_gen_per_sec` is a
    -- six-term expression including haste and three stack counts, none of it on the pulse,
    -- and a fabricated generation rate would be a guess dressed as arithmetic.
    -- ⚠ ONE FURY EITHER SIDE OF THE THRESHOLD, and the "not below it" half asserts the press
    -- the list DOES make rather than silence: at 81 Fury the spender is affordable, so L13
    -- takes it.  Asserting nil there would have been asserting a different fixture.
    it("L11 — Felblade at a deficit of 40, and not below it", function()
      assert.equals(ID.FB, winner({ felblade = cdReady(), fury = 80 }).cid)
      assert.equals(ID.CS, winner({ felblade = cdReady(), fury = 81 }).cid)
    end)

    it("L12 — Immolation Aura at a deficit of 20, and not below it", function()
      assert.equals(ID.IA, winner({ immo = cdReady(), fury = 100 }).cid)
      assert.equals(ID.CS, winner({ immo = cdReady(), fury = 101 }).cid)
    end)

    it("Felblade outranks Immolation Aura when both qualify", function()
      local g = guidance({ felblade = cdReady(), immo = cdReady(), fury = 0 })
      assert.equals(ID.FB, pressOf(g).cid)
      assert.equals(ID.IA, fallbackOf(g).cid)
    end)

    -- ⚠ THE FINDING THIS SPEC EXISTS TO RECORD: Felblade / Vengeful Retreat / Fel Rush are
    -- filed CDM-**UTILITY** by Blizzard and the fixture files them that way.  Both fences
    -- that could have blocked them read the SPEC-AUTHORED `cadence`, not the row's category,
    -- so declaring them "filler"/"oncd" is the whole fix — no pipeline edit.
    it("cues a CDM-Utility row because the SPEC's cadence says so", function()
      assert.equals("Utility", build({}).abilities[ID.FB].category)
      assert.equals(ID.FB, winner({ felblade = cdReady(), fury = 0 }).cid)
    end)
  end)

  describe("L13 — the main Fury dump", function()
    it("spends at the cost and holds below it", function()
      assert.equals(ID.CS, winner({ fury = 40 }).cid)
      assert.is_nil(winner({ fury = 39 }))
    end)

    -- In demon form the frame casts Annihilation, and the NOTE says so — the label is the
    -- pipeline's, the cue key stays the base.
    it("keys on the base frame in demon form, and says Annihilation", function()
      local w = winner({ metaXform = "cs", fury = 40 })
      assert.equals(ID.CS, w.cid)
      assert.equals("Annihilation", w.cue.note)
    end)

    it("carries no note outside demon form", function()
      assert.is_nil(winner({ fury = 40 }).cue.note)
    end)

    -- Degradation: an untracked Chaos Strike yields a nil spenderKey and BOTH spend lines
    -- simply find nothing rather than cueing a ghost.
    it("finds nothing when Chaos Strike is untracked, and the list continues", function()
      local w = winner({ noSpender = true, fury = 120, throwGlaive = cdReady() })
      assert.equals(ID.TG, w.cid)        -- straight through to L15
      assert.is_nil(ctxOf({ noSpender = true }).spenderKey)
    end)
  end)

  it("L15 — Throw Glaive is the floor", function()
    assert.equals(ID.TG, winner({ throwGlaive = cdReady(), fury = 25 }).cid)
    assert.is_nil(winner({ throwGlaive = cdReady(), fury = 24 }))
  end)

  -- Honest silence: every cooldown down and not enough Fury to spend is a REAL state, not a
  -- bug.  It shows in the decision log as `w:-`.  ⚠ On this spec a HIGH in-combat `w:-` means
  -- the Fury rail is not being read — Chaos Strike has no cooldown at all, so L13 is
  -- reachable on every tick the bar carries 40 Fury.
  it("returns no press when nothing is castable", function()
    assert.is_nil(winner({ fury = 39 }))
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
      local g = guidance({ rfa = cdReady(), fury = 0 })
      assert.is_nil(pressOf(g))
      assert.is_nil(g.cues[ID.RFA])
    end)

    it("never takes a SOON decoration either", function()
      local g = guidance({ rfa = cdSoon(1), throwGlaive = cdReady(), fury = 25 })
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
  describe("charge-aware readiness on a 1-charge pool", function()
    it("a count of ZERO vetoes a cooldown that reads READY", function()
      -- The lying-napkin shape exactly: the base cooldown expired after ~1 s, the charge is
      -- still recharging for another 9.  The COUNT decides.
      assert.is_nil(winner({ mode = "aoe", felRush = cdReady(),
                             frCharge = { charged = true, cur = 0, max = 1 } }))
    end)

    it("both agreeing is usable", function()
      local w = winner({ mode = "aoe", felRush = cdReady(),
                         frCharge = { charged = true, cur = 1, max = 1 } })
      assert.equals(ID.FR, w.cid)
    end)

    it("a banked charge does NOT outrank a cooldown that reads down", function()
      assert.is_nil(winner({ mode = "aoe", felRush = cdSoon(9),
                             frCharge = { charged = true, cur = 1, max = 1 } }))
    end)

    -- ⚠ THE RESIDUAL HOLE, and it is flight question #1: with NO count at all — `ch.charged`
    -- false, or no out-of-combat seed, since `C_Spell.GetSpellCharges` is combat-gated —
    -- `usable()` falls through to the cooldown read and the early napkin wins.  This case
    -- documents today's behaviour so the flight can arbitrate it; it is NOT an endorsement,
    -- and the one-line fix is recorded in specs/havoc/rotation.md.
    it("an ABSENT count falls back to the cooldown read (the documented residual hole)", function()
      local w = winner({ mode = "aoe", felRush = cdReady(),
                         frCharge = { charged = true, cur = nil, max = 1 } })
      assert.equals(ID.FR, w.cid)
    end)

    it("...and that fallback still respects a cooldown that is NOT ready", function()
      assert.is_nil(winner({ mode = "aoe", felRush = cdFar(),
                             frCharge = { charged = true, cur = nil, max = 1 } }))
    end)

    it("no charge pool at all falls back to the cooldown read", function()
      assert.equals(ID.VR, winner({ vr = cdReady(), eyeBeam = cdReady() }).cid)
    end)

    -- ⚠ THE CONFLAGRATE RULE IS UNTOUCHED.  With A Fire Inside, Immolation Aura is a 2-charge
    -- pool, and one banked charge while the second recharges is the NORMAL state — so there
    -- the count still outranks the cooldown.  If this goes red, the one-charge rule has been
    -- over-generalised.
    it("a 2-charge pool still lets a banked charge outrank the cooldown", function()
      local w = winner({ mode = "aoe", immo = cdSoon(10),
                         immoCharge = { charged = true, cur = 1, max = 2 } })
      assert.equals(ID.IA, w.cid)
    end)

    it("...and a 2-charge pool at ZERO is still vetoed", function()
      assert.is_nil(winner({ mode = "aoe", immo = cdReady(),
                             immoCharge = { charged = true, cur = 0, max = 2 } }))
    end)
  end)

  ----------------------------------------------------------------------------
  -- The LIVE cost — of the spell we will actually PRESS, never hardcoded.
  ----------------------------------------------------------------------------
  describe("the spender cost is resolved live, off the LIVE spell id", function()
    -- ⚠ THE COST IS OF THE SPELL WE WILL ACTUALLY PRESS.  In demon form the frame casts
    -- Annihilation, and only the LIVE id carries Annihilation's own cost — identical today
    -- (40) and not to be assumed to stay so.
    it("reads Annihilation's id in demon form, not Chaos Strike's", function()
      local base = build({ metaXform = "cs", fury = 44 })
      H.fx.powerCost[ID.CS]   = { { type = FURY, cost = 40, name = "FURY" } }
      H.fx.powerCost[ID.ANNI] = { { type = FURY, cost = 45, name = "FURY" } }
      assert.is_nil(pressOf(Coach:Compute(base)))          -- 44 < Annihilation's 45
      local rich = build({ metaXform = "cs", fury = 45 })
      H.fx.powerCost[ID.CS]   = { { type = FURY, cost = 40, name = "FURY" } }
      H.fx.powerCost[ID.ANNI] = { { type = FURY, cost = 45, name = "FURY" } }
      assert.equals(ID.CS, pressOf(Coach:Compute(rich)).cid)
    end)

    it("uses the client's cost over the fallback", function()
      assert.is_nil(winner({ fury = 40, spenderCost = 50 }))
      assert.equals(ID.CS, winner({ fury = 40 }).cid)   -- same pulse, fallback cost of 40
    end)

    -- THE RULE, in one line: A COST WE CANNOT READ MUST FALL BACK TO THE DECLARED CONSTANT,
    -- NEVER TO ZERO.  Under-promising costs a press of latency; over-promising cues a button
    -- that cannot be pressed, which is the failure this project cares most about.
    it("falls back to the declared 40 when the client has no answer", function()
      assert.is_nil(winner({ fury = 39, spenderCost = nil }))
      assert.equals(ID.CS, winner({ fury = 40, spenderCost = nil }).cid)
    end)

    -- A cost denominated in SOMEONE ELSE'S resource is not this spec's cost.  `ns.PowerCost`'s
    -- type filter must reject it and the brain must fall back — never read the non-match as
    -- free.  This is the exact shape that shipped the Retribution defect.
    it("rejects a cost denominated in a DIFFERENT resource", function()
      local g = build({ fury = 39 })
      H.fx.powerCost[ID.CS] = { { type = SOUL_SHARDS, cost = 2, name = "SOUL_SHARDS" } }
      assert.is_nil(pressOf(Coach:Compute(g)))
    end)

    -- A SECRET cost is the worst case of all: the state where we know least would otherwise
    -- promise the cheapest possible press.
    it("treats a SECRET cost as unreadable, not as free", function()
      local g = build({ fury = 0 })
      H.fx.powerCost[ID.CS] = { { type = FURY, cost = H.secretValue(), name = "FURY" } }
      assert.is_nil(pressOf(Coach:Compute(g)))
    end)

    -- ⚠ A COST OF **0** IS AN ANSWER, NOT A REFUSAL — `ns.PowerCost` is three-valued.  The
    -- project's own ABSENT-IS-NEVER-ZERO rule, run in reverse.
    it("cues a genuinely FREE spender at zero Fury", function()
      assert.equals(ID.CS, winner({ fury = 0, spenderCost = 0 }).cid)
    end)

    -- The other three costs ride the same reader, so one of them is pinned too.
    it("applies to Blade Dance as well", function()
      -- At a client cost of 45, 40 Fury cannot afford L10 — so the list falls through to the
      -- spender, whose own (fallback) cost of 40 it CAN afford.
      assert.equals(ID.CS, winner({ bladeDance = cdReady(), fury = 40, danceCost = 45 }).cid)
      assert.equals(ID.BD, winner({ bladeDance = cdReady(), fury = 40 }).cid)
    end)

    it("resolves Fury as the spec's cost resource, off its own powers block", function()
      assert.equals(FURY, ns.Coach.CostPowerType(ns.ActiveSpec))
    end)
  end)

  ----------------------------------------------------------------------------
  -- The in-flight projection — a spender mid-GCD must not be re-cued.
  ----------------------------------------------------------------------------
  describe("the in-flight projection", function()
    it("subtracts an in-flight spender, so L13 does not re-cue it", function()
      assert.is_nil(winner({ fury = 40, inflightSpender = true }))
      assert.equals(ID.CS, winner({ fury = 80, inflightSpender = true }).cid)
    end)

    it("projects nothing when the cost is unreadable", function()
      assert.equals(0, ctxOf({ fury = 40 }).furyIncoming)
    end)

    -- ⚠ THE DEFICIT GATES READ THE **LIVE** VALUE, NOT THE PROJECTION.  A spender already in
    -- flight has committed to draining the bar, and crediting that drain toward "I need Fury"
    -- would fire the generator lines a GCD early on every single spend.
    it("does not credit an in-flight spend toward the generator deficits", function()
      -- live 90 => deficit 30, below FELBLADE_DEFICIT (40).  Projected 50 would read a
      -- deficit of 70 and fire Felblade, which is the bug this pins.
      local w = winner({ fury = 90, felblade = cdReady(), inflightSpender = true })
      assert.equals(ID.CS, w.cid)
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
      local g = guidance({ mode = "aoe", immo = cdReady(), felblade = cdReady(), fury = 0 })
      assert.equals(ID.IA, pressOf(g).cid)           -- L4
      local fb = fallbackOf(g)
      assert.is_not_nil(fb)
      assert.are_not.equals(ID.IA, fb.cid)           -- NOT L12's Immolation Aura again
      assert.equals(ID.FB, fb.cid)                   -- L11
    end)

    it("drops the spender from BOTH of its lines at once", function()
      local g = guidance({ ebCast = true, throwGlaive = cdReady(), fury = 40 })
      assert.equals(ID.CS, pressOf(g).cid)           -- L8
      local fb = fallbackOf(g)
      assert.is_not_nil(fb)
      assert.are_not.equals(ID.CS, fb.cid)           -- NOT L13's spender again
      assert.equals(ID.TG, fb.cid)                   -- L15
    end)

    it("drops Blade Dance from whichever line named it", function()
      local inMeta = guidance({ metaBuff = true, bladeDance = cdReady(), fury = 40 })
      assert.equals(ID.BD, pressOf(inMeta).cid)      -- L7
      assert.are_not.equals(ID.BD, fallbackOf(inMeta).cid)
      local outside = guidance({ bladeDance = cdReady(), fury = 40 })
      assert.equals(ID.BD, pressOf(outside).cid)     -- L10
      assert.are_not.equals(ID.BD, fallbackOf(outside).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- SOON — a DUMB per-ability decoration, independent of the winner.
  ----------------------------------------------------------------------------
  describe("SOON", function()
    it("decorates a tracked cooldown coming up within the lead", function()
      local g = guidance({ throwGlaive = cdReady(), fury = 25, meta = cdSoon(2) })
      assert.equals(ID.TG, pressOf(g).cid)
      assert.is_true(soonSet(g)[ID.META])
    end)

    -- ⚠ THE SAME FINDING FROM THE OTHER SIDE: the SOON fence tests the SPEC-AUTHORED cadence,
    -- so a CDM-Utility ROW with a rotational cadence still decorates, while a spec-declared
    -- `cadence = "utility"` never does.
    it("decorates a CDM-Utility row whose spec cadence is rotational", function()
      local g = guidance({ throwGlaive = cdReady(), fury = 25, felblade = cdSoon(2) })
      assert.is_true(soonSet(g)[ID.FB])
    end)

    it("never decorates a spec-declared utility", function()
      local g = guidance({ throwGlaive = cdReady(), fury = 25, utility = cdSoon(1) })
      assert.is_nil(soonSet(g)[ID.UTILITY])
    end)

    it("does not decorate something far out", function()
      local g = guidance({ throwGlaive = cdReady(), fury = 25, meta = cdFar() })
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
      assert.equals("LATE", winner({ eyeBeam = overdue(), fury = 30 }).cue.emphasis)
      assert.equals("LATE", winner({ bladeDance = overdue(), fury = 35 }).cue.emphasis)
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
      local w = winner({ metaBuff = true, essenceBreak = overdue(), fury = 40 })
      assert.equals(ID.ESSB, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)

    -- The readable overcap dump — the analogue of Destruction's Chaos-Bolt-at-full-bar.
    it("calls the spender LATE at a FULL Fury bar", function()
      local w = winner({ fury = 120 })
      assert.equals(ID.CS, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    -- Gated on ACTUAL Fury, not the projection: an in-flight spender has already committed to
    -- draining the bar, so projecting it would call you late for something you are mid-way
    -- through fixing.
    it("does not call it LATE below the cap", function()
      assert.equals("ROTATION", winner({ fury = 119 }).cue.emphasis)
    end)

    it("never escalates a filler", function()
      local w = winner({ throwGlaive = overdue(), fury = 25 })
      assert.equals(ID.TG, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
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
