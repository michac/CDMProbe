-- specdelta_spec.lua — ns.SpecPowerDelta, the SIGNED in-flight POWER projection reader
-- (multi-spec Phase 3; was SpecShardDelta, W4 Phase 6 Part 2).  `ns.Coach.InflightPower`
-- sums this over in-flight 'start's into the per-power `incoming` map; the SIGN is the whole
-- point — a builder credits (+), an in-flight spender (Hand of Gul'dan) subtracts (−cost), so
-- the Coach clears the spender mid-cast instead of re-cuing it.  Phase 3 made the return
-- per-power: `{ power, delta }` — the reader NAMES the power it moves (Demo: "SoulShards"),
-- and a zero net delta returns `{ power = nil, delta = 0 }` (the sum skips nil-power entries).
-- ⚠ Only the CALLER moved in roster-state-plan Phase 6 (State.lua -> the Coach); this reader
-- is unchanged, which is why this spec was untouched by that phase.
--
-- ⚠ EVERY NUMBER HERE IS FRAGMENTS (Phase 6.2).  The game stores Soul Shards as 0-50
-- fragments and displays 0-5 whole shards; the decision layer moved onto the exact rail, so
-- Shadow Bolt credits +10, not +1.  `ns.ShardCost` still speaks WHOLE SHARDS (the client
-- pre-applies the divisor), which makes SpecPowerDelta a UNIT BOUNDARY — the assertions below
-- pin BOTH sides of it, because a missed conversion is a silent 10x error that still looks
-- like a plausible shard count.
-- Cost is read via ns.ShardCost (fixture-settable here, in whole shards).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local HAND_OF_GULDAN = 105174
local DEMONBOLT      = 264178
local SHADOW_BOLT    = 686
local INFERNAL_BOLT  = 434506   -- spends "art", generatesFrags 30
local RUINATION      = 434635   -- spends "art", no yield

describe("ns.SpecPowerDelta (signed per-power projection)", function()
  local ns, fx
  before_each(function()
    ns, fx = H.fresh()
    fx.cost[HAND_OF_GULDAN] = 3   -- the live WHOLE-SHARD cost ns.ShardCost returns
  end)

  it("credits a builder its whole yield onto SoulShards, in FRAGMENTS (positive)", function()
    assert.same({ power = "SoulShards", delta = 10 }, ns.SpecPowerDelta(SHADOW_BOLT))
  end)

  it("credits Demonbolt +20 uncosted (spends a CORE, not shards)", function()
    assert.same({ power = "SoulShards", delta = 20 }, ns.SpecPowerDelta(DEMONBOLT))
  end)

  it("credits Infernal Bolt +30 (spends art, refunds 3 shards)", function()
    assert.same({ power = "SoulShards", delta = 30 }, ns.SpecPowerDelta(INFERNAL_BOLT))
  end)

  -- THE UNIT BOUNDARY, asserted explicitly rather than only through a downstream press: a
  -- fixture cost of 3 WHOLE SHARDS must land as -30 FRAGMENTS.  A 10x error here still reads
  -- as a plausible shard count, which is exactly why the number is pinned and not inferred.
  it("subtracts a shard-spender its live cost, CONVERTED UP to fragments (negative)", function()
    assert.same({ power = "SoulShards", delta = -30 }, ns.SpecPowerDelta(HAND_OF_GULDAN))
  end)

  it("reflects the LIVE (talent-dependent) cost", function()
    fx.cost[HAND_OF_GULDAN] = 2
    assert.same({ power = "SoulShards", delta = -20 }, ns.SpecPowerDelta(HAND_OF_GULDAN))
  end)

  it("drops the spend term when the cost is unreadable (safe direction, no over-deduct)", function()
    fx.cost[HAND_OF_GULDAN] = nil   -- ns.ShardCost returns nil
    -- delta collapses to 0 => a nameless zero-delta entry (State skips it).
    assert.same({ power = nil, delta = 0 }, ns.SpecPowerDelta(HAND_OF_GULDAN))
  end)

  it("is a nameless zero for an art spender with no refund (Ruination)", function()
    assert.same({ power = nil, delta = 0 }, ns.SpecPowerDelta(RUINATION))
  end)

  it("is a nameless zero for an unknown / untracked id", function()
    assert.same({ power = nil, delta = 0 }, ns.SpecPowerDelta(999999))
  end)
end)

--------------------------------------------------------------------------------
-- DESTRUCTION's SpecPowerDelta — the BUILDER half, which did not exist before Phase 6.2.
--------------------------------------------------------------------------------
-- This spec used to project SPENDERS ONLY, and the reason was honest: its builders pay
-- FRAGMENTS (Incinerate 2, Conflagrate 5, Soul Fire 10) into a bar the pipeline could read
-- only in whole shards, so a faked integer `generates` would have lied by up to a full shard
-- on every filler cast.  The exact rail removed the premise, so the yields are real numbers
-- now — and they are BASE values, deliberately: a crit bonus is deterministic given a crit
-- and the crit is not, so Incinerate's +1-on-crit is left out.  Under-crediting delays a cue
-- by one press; over-crediting promises a Chaos Bolt you cannot cast.
describe("SpecDestruction.SpecPowerDelta (the fragment yields)", function()
  local CHAOS_BOLT      = 116858
  local INCINERATE      = 29722
  local CONFLAGRATE     = 17962
  local SOUL_FIRE       = 6353
  local IMMOLATE        = 157736
  local IB_DESTRO       = 433891   -- the Destruction-side Infernal Bolt id
  local DIABOLIC_EMBERS = 387173

  local ns, fx
  before_each(function()
    ns, fx = H.fresh()
    H.setSpecIndex(3)          -- Destruction (267), through the REAL resolver
    ns.ResolveActiveSpec()
    fx.cost[CHAOS_BOLT] = 2    -- whole shards, as ns.ShardCost reports them
  end)

  it("credits Incinerate its BASE 2 fragments (no crit bonus, by design)", function()
    assert.same({ power = "SoulShards", delta = 2 }, ns.SpecPowerDelta(INCINERATE))
  end)

  it("credits Conflagrate 5 and Soul Fire a whole shard's 10", function()
    assert.same({ power = "SoulShards", delta = 5 }, ns.SpecPowerDelta(CONFLAGRATE))
    assert.same({ power = "SoulShards", delta = 10 }, ns.SpecPowerDelta(SOUL_FIRE))
  end)

  -- A DoT's income is 1 fragment PER TICK over 18s, not a lump on cast, and the in-flight
  -- projection answers "what will the bar read when THIS CAST resolves".  Absence here is
  -- the same conservative floor as the crit yields, not an oversight.
  it("credits Immolate NOTHING — its income is per-tick, not on cast", function()
    assert.same({ power = nil, delta = 0 }, ns.SpecPowerDelta(IMMOLATE))
  end)

  it("converts a 2-shard Chaos Bolt cost UP to -20 fragments", function()
    assert.same({ power = "SoulShards", delta = -20 }, ns.SpecPowerDelta(CHAOS_BOLT))
  end)

  it("credits Infernal Bolt 20 (the Destruction figure, the lower of the two readings)", function()
    assert.same({ power = "SoulShards", delta = 20 }, ns.SpecPowerDelta(IB_DESTRO))
  end)

  -- Diabolic Embers is the ONE conditional yield we read, because it doubles the press this
  -- spec makes more than any other.  ⚠ A REFUSED read must assume UNTALENTED — the
  -- conservative floor — which is what `fx.known` defaulting to false already exercises above.
  describe("Diabolic Embers (387173)", function()
    it("doubles Incinerate to 4 when the talent is known", function()
      fx.known[DIABOLIC_EMBERS] = true
      assert.same({ power = "SoulShards", delta = 4 }, ns.SpecPowerDelta(INCINERATE))
    end)

    it("doubles nothing else — Conflagrate is untouched by it", function()
      fx.known[DIABOLIC_EMBERS] = true
      assert.same({ power = "SoulShards", delta = 5 }, ns.SpecPowerDelta(CONFLAGRATE))
    end)

    it("assumes UNTALENTED when the spell-book read throws (the conservative floor)", function()
      fx.known[DIABOLIC_EMBERS] = true
      H.throwOn("C_SpellBook.IsSpellKnown")
      assert.same({ power = "SoulShards", delta = 2 }, ns.SpecPowerDelta(INCINERATE))
    end)

    -- The answer is BUILD-SCOPED, so it is cached — and cleared through the registry's
    -- Invalidate seam, which SpecRegistry wires to TRAIT_CONFIG_UPDATED and to a real spec
    -- swap.  Destruction is the first spec to use that seam; without the clear, a respec
    -- would keep projecting the old yield until relog.
    it("caches the answer, and ns.InvalidateSpecCaches clears it", function()
      assert.same({ power = "SoulShards", delta = 2 }, ns.SpecPowerDelta(INCINERATE))
      fx.known[DIABOLIC_EMBERS] = true
      assert.same({ power = "SoulShards", delta = 2 }, ns.SpecPowerDelta(INCINERATE))  -- cached
      ns.InvalidateSpecCaches()
      assert.same({ power = "SoulShards", delta = 4 }, ns.SpecPowerDelta(INCINERATE))
    end)

    -- A refusal is NOT cached: caching it would freeze "untalented" for the whole session,
    -- where re-asking self-heals the moment the spell book answers.
    it("does not cache a REFUSAL — it re-asks and self-heals", function()
      H.throwOn("C_SpellBook.IsSpellKnown")
      assert.same({ power = "SoulShards", delta = 2 }, ns.SpecPowerDelta(INCINERATE))
      H.throws["C_SpellBook.IsSpellKnown"] = nil
      fx.known[DIABOLIC_EMBERS] = true
      assert.same({ power = "SoulShards", delta = 4 }, ns.SpecPowerDelta(INCINERATE))
    end)
  end)
end)
