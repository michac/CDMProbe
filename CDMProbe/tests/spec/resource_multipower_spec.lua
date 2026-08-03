-- resource_multipower_spec.lua — the multi-spec Phase 3 "FULL SEAM" proof.
--
-- Phase 3 turned the resource path from "one hardcoded Soul Shard bar" into an ARRAY of
-- named powers a spec declares (spec.powers).  The point of the phase is that a
-- DUAL-RESOURCE spec (energy + combo points, runes + runic power, …) is now EXPRESSIBLE
-- end to end.  There is no live second spec yet, so this spec fabricates a synthetic
-- 2-power fake spec and drives the seam off-game:
--
--   * ns.Coach.InflightPower sums each in-flight cast's { power, delta } onto its OWN
--     named power (a MAP, not a scalar) — the proof the PER-POWER map survived
--     roster-state-plan Phase 6, which moved this derivation out of State.lua (where it
--     was `inflightIncoming`/`projectIncoming` folding `incoming` onto the pulse) and into
--     the Coach, as a pure function of the pulse's cast history.
--   * the spec brain's Context folds that map onto its declared powers, and the generic
--     shell emits ONE resourceBar per declared power off ctx.powers.
--
-- Plus the behaviour-preserved check: Demonology (one declared power) still emits exactly
-- one shard bar — the phase is a framework change, not a visual one.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local FIRE_ID  = 900001   -- fake builder feeding power A (Energy)
local FROST_ID = 900002   -- fake builder feeding power B (ComboPoints)

-- The live namespace, re-minted per test by the before_each below.  File-scope so the
-- synthetic spec's Context (defined here, invoked from inside a test) closes over it.
local ns

-- A synthetic dual-resource spec: two builders, each crediting its own named power.
local function makeDualSpec()
  local spec = {}
  spec.powers = {
    { name = "Energy",      display = "continuous", incoming = true, token = "ENERGY" },
    { name = "ComboPoints", display = "discrete",   incoming = true, token = "COMBO_POINTS" },
  }
  spec.SpecPowerDelta = function(id)
    if id == FIRE_ID  then return { power = "Energy",      delta = 2 } end
    if id == FROST_ID then return { power = "ComboPoints", delta = 1 } end
    return { power = nil, delta = 0 }
  end
  -- The bare-minimum brain the shell's Compute delegates to: derive the in-flight map off
  -- the pulse, then build ctx.powers off self.powers × state.power[name] (exactly the
  -- shape CoachDemonology/CoachDestruction fill), no winner.
  function spec:Context(state, _env)
    local sums = ns.Coach.InflightPower(state, ns.SpecPowerDelta)
    local ctx = { facts = {}, powers = {} }
    for _, p in ipairs(self.powers) do
      local pw = (state.power or {})[p.name] or {}
      ctx.powers[#ctx.powers + 1] = {
        value = pw.value, max = pw.max, incoming = (p.incoming and sums[p.name]) or 0,
        display = p.display, powerType = p.token,
      }
    end
    return ctx
  end
  function spec:RankWinner() return nil end
  function spec:Escalate(_k, level) return level end
  return spec
end

-- An in-flight cast of `id`: a 'start' with no later terminal phase.
local function inflight(id, at)
  return { phase = "start", spellID = id, base = id, at = at or 0 }
end

describe("multi-power resource seam (Phase 3 full-seam proof)", function()
  before_each(function()
    ns = H.fresh()
  end)

  describe("the Coach projects incoming onto two named powers", function()
    before_each(function()
      H.load("Coach.lua")
      ns.RegisterSpec(900, makeDualSpec())
      ns.SetActiveSpec(900)   -- rebinds ns.SpecPowerDelta from the dual spec
    end)

    it("sums each in-flight builder onto its OWN power (a per-power map)", function()
      local state = { at = 0, history = { inflight(FIRE_ID), inflight(FROST_ID) } }
      local sums = ns.Coach.InflightPower(state, ns.SpecPowerDelta)
      assert.equals(2, sums.Energy)
      assert.equals(1, sums.ComboPoints)
    end)

    it("folds the per-power sums onto each declared bar, walking spec.powers", function()
      local state = { at = 0,
        power = { Energy = { value = 40, max = 100 }, ComboPoints = { value = 3, max = 5 } },
        history = { inflight(FIRE_ID), inflight(FROST_ID) } }
      local byToken = {}
      for _, b in ipairs(ns.Coach.New():Compute(state).resourceBars) do byToken[b.powerType] = b end
      assert.equals(2, byToken.ENERGY.incoming)
      assert.equals(1, byToken.COMBO_POINTS.incoming)
    end)

    it("defaults a declared power with nothing in flight to incoming 0", function()
      local state = { at = 0,
        power = { Energy = { value = 40, max = 100 }, ComboPoints = { value = 3, max = 5 } },
        history = { inflight(FIRE_ID) } }
      local byToken = {}
      for _, b in ipairs(ns.Coach.New():Compute(state).resourceBars) do byToken[b.powerType] = b end
      assert.equals(2, byToken.ENERGY.incoming)
      assert.equals(0, byToken.COMBO_POINTS.incoming)   -- declared incoming, none in flight
    end)

    -- THE RULE THAT WAS NEVER TESTED IN STATE, and the one most likely to be broken
    -- silently by the Phase-6 move: a TERMINAL phase for the same base supersedes the
    -- 'start', so the projection stops.  'stopped' is why State registers the four
    -- terminal cast events at all — without it a cancelled spender keeps projecting.
    it("a later 'succeeded' for the same base supersedes the in-flight start", function()
      local state = { at = 1, history = {
        inflight(FIRE_ID, 0),
        { phase = "succeeded", spellID = FIRE_ID, base = FIRE_ID, at = 0.5 },
      } }
      assert.is_nil(ns.Coach.InflightPower(state, ns.SpecPowerDelta).Energy)
    end)

    it("a later 'stopped' (the cancelled cast) supersedes it too", function()
      local state = { at = 1, history = {
        inflight(FIRE_ID, 0),
        { phase = "stopped", spellID = FIRE_ID, base = FIRE_ID, at = 0.5 },
        inflight(FROST_ID, 0),
      } }
      local sums = ns.Coach.InflightPower(state, ns.SpecPowerDelta)
      assert.is_nil(sums.Energy)              -- cancelled: no longer projected
      assert.equals(1, sums.ComboPoints)      -- its sibling is untouched
    end)

    it("a RE-cast after a terminal phase projects again (latest phase wins, not 'ever terminal')", function()
      local state = { at = 2, history = {
        inflight(FIRE_ID, 0),
        { phase = "stopped", spellID = FIRE_ID, base = FIRE_ID, at = 0.5 },
        inflight(FIRE_ID, 1.5),
      } }
      assert.equals(2, ns.Coach.InflightPower(state, ns.SpecPowerDelta).Energy)
    end)

    it("drops a start that has aged out of the flight window", function()
      local state = { at = 10, history = { inflight(FIRE_ID, 0) } }
      assert.is_nil(ns.Coach.InflightPower(state, ns.SpecPowerDelta).Energy)
    end)

    it("returns an empty map with no delta reader (a passive/unknown spec)", function()
      local state = { at = 0, history = { inflight(FIRE_ID) } }
      assert.same({}, ns.Coach.InflightPower(state, nil))
    end)
  end)

  describe("the Coach emits one resourceBar per declared power", function()
    it("emits two resourceBars from a 2-power spec's ctx.powers", function()
      ns.RegisterSpec(900, makeDualSpec())
      ns.SetActiveSpec(900)
      H.load("Coach.lua")

      local state = { at = 0,
        power = {
          Energy      = { value = 40, max = 100 },
          ComboPoints = { value = 3,  max = 5 },
        },
        history = { inflight(FIRE_ID), inflight(FROST_ID) } }
      local guidance = ns.Coach.New():Compute(state)
      assert.equals(2, #guidance.resourceBars)

      local byToken = {}
      for _, b in ipairs(guidance.resourceBars) do byToken[b.powerType] = b end
      assert.is_not_nil(byToken.ENERGY, "no Energy bar emitted")
      assert.equals(40, byToken.ENERGY.value)
      assert.equals(2,  byToken.ENERGY.incoming)
      assert.equals("continuous", byToken.ENERGY.display)
      assert.is_not_nil(byToken.COMBO_POINTS, "no ComboPoints bar emitted")
      assert.equals(3, byToken.COMBO_POINTS.value)
      assert.equals(5, byToken.COMBO_POINTS.max)
      assert.equals("discrete", byToken.COMBO_POINTS.display)
    end)

    it("still emits exactly one shard bar for Demonology (behaviour preserved)", function()
      -- Demo is the spec H.fresh() activated; drive the shell with a minimal SoulShards
      -- pulse.  One declared power => one resourceBar, identical to the pre-Phase-3 shape.
      H.load("Coach.lua")
      local state = { at = 0, abilities = {}, buffs = {}, history = {},
                      power = { SoulShards = { value = 3, max = 5, readable = true } } }
      local guidance = ns.Coach.New():Compute(state)
      assert.equals(1, #guidance.resourceBars)
      assert.equals("SOUL_SHARDS", guidance.resourceBars[1].powerType)
      assert.equals(3, guidance.resourceBars[1].value)
      assert.equals("discrete", guidance.resourceBars[1].display)
    end)
  end)

  ----------------------------------------------------------------------------
  -- THE EXACT RAIL IS ADDITIVE AND OPT-IN (Phase 6.2).
  ----------------------------------------------------------------------------
  -- Soul Shards have a display divisor of 10 (0-50 fragments drawn as 0-5 pips); most powers
  -- have none.  The seam must stay neutral about that: a spec that carries no exact rail
  -- must come out of the shell exactly as it went in, with the fields ABSENT rather than
  -- defaulted to zero — zero would read as a measurement nobody took.
  describe("a spec with no exact rail (modifier 1) is a no-op", function()
    before_each(function()
      ns.RegisterSpec(900, makeDualSpec())
      ns.SetActiveSpec(900)
      H.load("Coach.lua")
    end)

    it("passes the exact fields through as ABSENT, never zero", function()
      local state = { at = 0,
        power = { Energy = { value = 40, max = 100 }, ComboPoints = { value = 3, max = 5 } },
        history = { inflight(FIRE_ID) } }
      local byToken = {}
      for _, b in ipairs(ns.Coach.New():Compute(state).resourceBars) do byToken[b.powerType] = b end
      assert.is_nil(byToken.ENERGY.valueExact)
      assert.is_nil(byToken.ENERGY.maxExact)
      assert.is_nil(byToken.ENERGY.modifier)
    end)

    it("leaves `incoming` unscaled — no divisor, no division", function()
      local state = { at = 0,
        power = { Energy = { value = 40, max = 100 }, ComboPoints = { value = 3, max = 5 } },
        history = { inflight(FIRE_ID) } }
      local byToken = {}
      for _, b in ipairs(ns.Coach.New():Compute(state).resourceBars) do byToken[b.powerType] = b end
      assert.equals(2, byToken.ENERGY.incoming)   -- the spec's own delta, verbatim
      assert.equals(40, byToken.ENERGY.value)
      assert.equals(100, byToken.ENERGY.max)
    end)
  end)

  ----------------------------------------------------------------------------
  -- ns.Coach.PowerContext — THE SHARED RAIL (the 2026-08-02 hoist).
  ----------------------------------------------------------------------------
  -- The two Warlock brains opened Context with a byte-identical ~15-line block and five more
  -- brains were about to copy it.  It now lives in the shell beside C.CommittedWithin /
  -- C.InflightPower, and this block is its contract — asserted DIRECTLY rather than through
  -- a brain, because the properties that matter (which rail is a measurement and which is a
  -- fallback) are invisible once a brain has renamed them.
  --
  -- ⚠ THE TWO RAILS ARE NOT THE SAME NUMBER, and that asymmetry is the load-bearing part:
  -- `rails[].value` FALLS BACK (a gate needs a number) while `bars[].valueExact` does NOT
  -- (a bar must be able to say "the client refused").  Collapsing them would make a scaled
  -- guess indistinguishable from a measurement.
  describe("ns.Coach.PowerContext", function()
    before_each(function() H.load("Coach.lua") end)

    -- The shard-shaped power: exact rail present, divisor 10.
    local SHARDS = { powers = { { name = "SoulShards", display = "discrete", incoming = true,
                                  token = "SOUL_SHARDS", modifier = 10,
                                  exactMax = 50, barMax = 5 } } }

    local function shardState(pw, sums)
      return { at = 0, power = { SoulShards = pw } }, sums or {}
    end

    it("reads the EXACT rail when the client gave one, and projects on it", function()
      local st, sums = shardState({ value = 1, max = 5, readable = true,
                                    unmodified = 18, unmodifiedMax = 50, modifier = 10 },
                                  { SoulShards = 4 })
      local bars, rails = ns.Coach.PowerContext(st, SHARDS, sums)
      assert.equals(18, rails.SoulShards.value)
      assert.equals(4,  rails.SoulShards.incoming)
      assert.equals(22, rails.SoulShards.projected)   -- gates compare THIS
      assert.equals(50, rails.SoulShards.max)
      assert.is_true(rails.SoulShards.readable)
      -- The bar stays in DISPLAY units, and the projection is truncated toward zero:
      -- +4 fragments is +0.4 shards, which is not a pip.
      assert.equals(1, bars[1].value)
      assert.equals(5, bars[1].max)
      assert.equals(0, bars[1].incoming)
      assert.equals(4, bars[1].incomingExact)
    end)

    -- THE FALLBACK LADDER, and the asymmetry.  A refused exact read still has to yield a
    -- gate number (display x modifier — coarse, never wrong in units) while the bar's
    -- MEASUREMENT fields stay absent.
    it("falls back to display x modifier for the gate rail, leaving the bar's exact fields ABSENT", function()
      local st, sums = shardState({ value = 3, max = 5, readable = true }, {})
      local bars, rails = ns.Coach.PowerContext(st, SHARDS, sums)
      assert.equals(30, rails.SoulShards.value)      -- 3 shards x 10, a derived gate number
      assert.equals(50, rails.SoulShards.max)        -- the spec's declared exactMax
      assert.is_nil(bars[1].valueExact)              -- ...but nothing was MEASURED
      assert.is_nil(bars[1].maxExact)
    end)

    -- Absence of a read must never become "you have none": nil stays nil so a brain's
    -- `powerReadable` can tell the two apart, exactly as the shard brains do today.
    it("leaves the gate rail nil when there is no power at all — never 0", function()
      local bars, rails = ns.Coach.PowerContext({ at = 0, power = {} }, SHARDS, {})
      assert.is_nil(rails.SoulShards.value)
      assert.is_nil(rails.SoulShards.projected)
      assert.is_false(rails.SoulShards.readable)
      assert.is_false(rails.SoulShards.atCap)
      assert.is_nil(bars[1].value)
    end)

    it("reports atCap off the PROJECTION, in exact units", function()
      local st = shardState({ value = 4, max = 5, readable = true,
                              unmodified = 46, unmodifiedMax = 50, modifier = 10 })
      local _, rails = ns.Coach.PowerContext(st, SHARDS, { SoulShards = 4 })
      assert.is_true(rails.SoulShards.atCap)          -- 46 + 4 = 50
      local _, under = ns.Coach.PowerContext(st, SHARDS, { SoulShards = 3 })
      assert.is_false(under.SoulShards.atCap)         -- 49 is not a full bar
    end)

    -- A spec that declared the power but not the projection must not receive one.
    it("ignores the in-flight sum for a power that did not declare `incoming`", function()
      local noProj = { powers = { { name = "SoulShards", display = "discrete",
                                    token = "SOUL_SHARDS", modifier = 10, exactMax = 50 } } }
      local st = shardState({ value = 1, unmodified = 18, unmodifiedMax = 50, modifier = 10 })
      local _, rails = ns.Coach.PowerContext(st, noProj, { SoulShards = 4 })
      assert.equals(0,  rails.SoulShards.incoming)
      assert.equals(18, rails.SoulShards.projected)
    end)

    -- THE `display = "none"` CASE (D1) — the mechanism the five new specs ride.  A power the
    -- HUD does not draw is still a FULL rail entry: the brain gates on it and the decision
    -- log's PW column reads it.  Only the Renderer skips it, and it does that off `display`.
    it("carries a `display = \"none\"` power through both rails intact", function()
      local hidden = { powers = { { name = "HolyPower", display = "none", incoming = true,
                                    token = "HOLY_POWER", barMax = 5 } } }
      local st = { at = 0, power = { HolyPower = { value = 3, max = 5, readable = true } } }
      local bars, rails = ns.Coach.PowerContext(st, hidden, { HolyPower = 1 })
      assert.equals(3, rails.HolyPower.value)         -- modifier 1: display units ARE exact
      assert.equals(4, rails.HolyPower.projected)
      assert.equals(5, rails.HolyPower.max)
      assert.equals(1, #bars)                         -- the bar EXISTS...
      assert.equals("none", bars[1].display)          -- ...and says "do not draw me"
      assert.equals(3, bars[1].value)
      assert.equals(1, bars[1].incoming)
    end)

    it("walks spec.powers in declaration order, one rail entry per name", function()
      local dual = { powers = {
        { name = "Fury",      display = "none",     incoming = true, token = "FURY", barMax = 120 },
        { name = "SoulShards", display = "discrete", incoming = true, token = "SOUL_SHARDS",
          modifier = 10, exactMax = 50, barMax = 5 },
      } }
      local st = { at = 0, power = { Fury = { value = 70, max = 120, readable = true },
                                     SoulShards = { value = 2, max = 5, readable = true } } }
      local bars, rails = ns.Coach.PowerContext(st, dual, {})
      assert.equals(2, #bars)
      assert.equals("FURY", bars[1].powerType)
      assert.equals("SOUL_SHARDS", bars[2].powerType)
      assert.equals(70, rails.Fury.value)
      assert.equals(20, rails.SoulShards.value)
    end)

    it("is a no-op for a spec that declares no powers", function()
      local bars, rails = ns.Coach.PowerContext({ at = 0, power = {} }, { powers = {} }, {})
      assert.same({}, bars)
      assert.same({}, rails)
    end)

    -- The LIVE modifier outranks the spec's declared fallback: the fallback exists for a
    -- refused read, not as a second opinion about a number the client gave us.
    it("prefers the live modifier over the spec's declared fallback", function()
      local st = shardState({ value = 2, max = 5, unmodified = 10, unmodifiedMax = 25,
                              modifier = 5, readable = true })
      local bars, rails = ns.Coach.PowerContext(st, SHARDS, { SoulShards = 10 })
      assert.equals(5, rails.SoulShards.modifier)     -- live 5, not the declared 10
      assert.equals(25, rails.SoulShards.max)
      assert.equals(2, bars[1].incoming)              -- 10 exact / 5 = 2 display units
    end)
  end)
end)
