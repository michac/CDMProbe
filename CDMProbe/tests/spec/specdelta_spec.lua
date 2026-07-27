-- specdelta_spec.lua — ns.SpecShardDelta, the SIGNED in-flight shard projection reader
-- (W4 Phase 6 Part 2).  State.lua sums this over in-flight 'start's to emit
-- power.SoulShards.incoming; the SIGN is the whole point — a builder credits (+), an
-- in-flight spender (Hand of Gul'dan) subtracts (−cost), so the Coach clears the spender
-- mid-cast instead of re-cuing it.  Cost is read via ns.ShardCost (fixture-settable here).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local HAND_OF_GULDAN = 105174
local DEMONBOLT      = 264178
local SHADOW_BOLT    = 686
local INFERNAL_BOLT  = 434506   -- spends "art", generates 3
local RUINATION      = 434635   -- spends "art", no generates

describe("ns.SpecShardDelta (signed shard projection)", function()
  local ns, fx
  before_each(function()
    ns, fx = H.fresh()
    fx.cost[HAND_OF_GULDAN] = 3   -- the live shard cost ns.ShardCost returns
  end)

  it("credits a builder its whole yield (positive)", function()
    assert.equals(1, ns.SpecShardDelta(SHADOW_BOLT))    -- generates 1, no spend
  end)

  it("credits Demonbolt +2 uncosted (spends a CORE, not shards)", function()
    assert.equals(2, ns.SpecShardDelta(DEMONBOLT))      -- generates 2, spends "core"
  end)

  it("credits Infernal Bolt +3 (spends art, refunds 3)", function()
    assert.equals(3, ns.SpecShardDelta(INFERNAL_BOLT))
  end)

  it("subtracts a shard-spender its live cost (negative)", function()
    assert.equals(-3, ns.SpecShardDelta(HAND_OF_GULDAN))  -- generates 0 − cost 3
  end)

  it("reflects the LIVE (talent-dependent) cost", function()
    fx.cost[HAND_OF_GULDAN] = 2
    assert.equals(-2, ns.SpecShardDelta(HAND_OF_GULDAN))
  end)

  it("drops the spend term when the cost is unreadable (safe direction, no over-deduct)", function()
    fx.cost[HAND_OF_GULDAN] = nil   -- ns.ShardCost returns nil
    assert.equals(0, ns.SpecShardDelta(HAND_OF_GULDAN))
  end)

  it("is 0 for an art spender with no refund (Ruination)", function()
    assert.equals(0, ns.SpecShardDelta(RUINATION))
  end)

  it("is 0 for an unknown / untracked id", function()
    assert.equals(0, ns.SpecShardDelta(999999))
  end)
end)
