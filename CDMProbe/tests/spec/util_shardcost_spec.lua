-- util_shardcost_spec.lua — ns.PowerCost / ns.ShardCost against the REAL Util.lua, with only
-- `C_Spell.GetSpellPowerCost` faked.
--
-- WHY THIS FILE EXISTS AT ALL.  Every other spec in this suite reads costs through the
-- harness's `ns.ShardCost = function(id) return fx.cost[id] end` override, which proves the
-- CALLERS work given a cost and nothing whatsoever about the reader itself.  Two things in it
-- are load-bearing and were untested:
--
--   1. THE TYPE FILTER (ns.PowerCost's v0.10.0 banner).  Before it, the reader returned the
--      first non-zero cost of ANY power type — and most of the tracked set costs MANA, so
--      Demonbolt's 5000 mana became a "shard" cost compared against a rail that maxes at 5,
--      a gate that could never open.  An UNFILTERED cost is not a slightly-worse answer; it
--      is a different resource silently wearing the right units.
--
--   2. THE FRAGMENT HEURISTIC, DELETED IN PHASE 6.2.  `if raw >= 10 and raw % 10 == 0 then
--      return raw / 10` guessed that a clean multiple of ten "must be" fragments.  The
--      in-game measurement settled the units the other way — `C_Spell.GetSpellPowerCost`
--      PRE-APPLIES the display divisor, so Chaos Bolt's DB2 cost of 20 fragments arrives as
--      2 whole shards — which makes the branch unreachable by construction (no ability costs
--      ten shards against a five-shard cap) and silently destructive if it ever did fire.
--      The `raw = 20` case below is that deletion's regression test: it must come back 20,
--      not 2.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local SHARDS = 7    -- Enum.PowerType.SoulShards, per the harness
local MANA   = 0

describe("ns.ShardCost / ns.PowerCost (the REAL Util reader)", function()
  local ns, fx
  before_each(function()
    ns, fx = H.fresh()
    -- The harness overrides ns.ShardCost for every OTHER spec; this one wants the shipping
    -- implementation, so put it back by re-loading Util into this namespace.
    H.load("Util.lua")
  end)

  it("returns the client's number UNTOUCHED — 2 shards stays 2", function()
    fx.powerCost[116858] = { { type = SHARDS, cost = 2, name = "SOUL_SHARDS" } }
    local shards, raw = ns.ShardCost(116858)
    assert.equals(2, shards)
    assert.equals(2, raw)
  end)

  -- THE REGRESSION THE DELETION IS ABOUT.  Under the old heuristic this returned 2.
  it("does NOT divide a clean multiple of ten — a raw 20 comes back 20", function()
    fx.powerCost[116858] = { { type = SHARDS, cost = 20, name = "SOUL_SHARDS" } }
    assert.equals(20, ns.ShardCost(116858))
  end)

  it("still filters by power type: a MANA cost is not a shard cost", function()
    fx.powerCost[264178] = { { type = MANA, cost = 5000, name = "MANA" } }
    -- 0 = "no cost in the resource we asked about" (ns.PowerCost's documented ambiguity).
    assert.equals(0, ns.ShardCost(264178))
  end)

  it("picks the SHARD entry out of a mixed list, whatever its position", function()
    fx.powerCost[105174] = {
      { type = MANA,   cost = 5000, name = "MANA" },
      { type = SHARDS, cost = 3,    name = "SOUL_SHARDS" },
    }
    assert.equals(3, ns.ShardCost(105174))
  end)

  it("refuses a SECRET cost rather than reading through it", function()
    fx.powerCost[116858] = { { type = SHARDS, cost = H.secretValue(), name = "SOUL_SHARDS" } }
    assert.equals(0, ns.ShardCost(116858))
  end)

  it("refuses a SECRET type rather than assuming it is the one we asked for", function()
    fx.powerCost[116858] = { { type = H.secretValue(), cost = 2, name = "SOUL_SHARDS" } }
    assert.equals(0, ns.ShardCost(116858))
  end)

  it("is nil for a secret / non-number spellID", function()
    assert.is_nil(ns.ShardCost(H.secretValue()))
    assert.is_nil(ns.ShardCost("116858"))
  end)
end)
