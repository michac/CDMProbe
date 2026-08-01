-- specdelta_spec.lua — ns.SpecPowerDelta, the SIGNED in-flight POWER projection reader
-- (multi-spec Phase 3; was SpecShardDelta, W4 Phase 6 Part 2).  `ns.Coach.InflightPower`
-- sums this over in-flight 'start's into the per-power `incoming` map; the SIGN is the whole
-- point — a builder credits (+), an in-flight spender (Hand of Gul'dan) subtracts (−cost), so
-- the Coach clears the spender mid-cast instead of re-cuing it.  Phase 3 made the return
-- per-power: `{ power, delta }` — the reader NAMES the power it moves (Demo: "SoulShards"),
-- and a zero net delta returns `{ power = nil, delta = 0 }` (the sum skips nil-power entries).
-- ⚠ Only the CALLER moved in roster-state-plan Phase 6 (State.lua -> the Coach); this reader
-- is unchanged, which is why this spec is untouched by that phase.
-- Cost is read via ns.ShardCost (fixture-settable here).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local HAND_OF_GULDAN = 105174
local DEMONBOLT      = 264178
local SHADOW_BOLT    = 686
local INFERNAL_BOLT  = 434506   -- spends "art", generates 3
local RUINATION      = 434635   -- spends "art", no generates

describe("ns.SpecPowerDelta (signed per-power projection)", function()
  local ns, fx
  before_each(function()
    ns, fx = H.fresh()
    fx.cost[HAND_OF_GULDAN] = 3   -- the live shard cost ns.ShardCost returns
  end)

  it("credits a builder its whole yield onto SoulShards (positive)", function()
    assert.same({ power = "SoulShards", delta = 1 }, ns.SpecPowerDelta(SHADOW_BOLT))
  end)

  it("credits Demonbolt +2 uncosted (spends a CORE, not shards)", function()
    assert.same({ power = "SoulShards", delta = 2 }, ns.SpecPowerDelta(DEMONBOLT))
  end)

  it("credits Infernal Bolt +3 (spends art, refunds 3)", function()
    assert.same({ power = "SoulShards", delta = 3 }, ns.SpecPowerDelta(INFERNAL_BOLT))
  end)

  it("subtracts a shard-spender its live cost (negative)", function()
    assert.same({ power = "SoulShards", delta = -3 }, ns.SpecPowerDelta(HAND_OF_GULDAN))
  end)

  it("reflects the LIVE (talent-dependent) cost", function()
    fx.cost[HAND_OF_GULDAN] = 2
    assert.same({ power = "SoulShards", delta = -2 }, ns.SpecPowerDelta(HAND_OF_GULDAN))
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
