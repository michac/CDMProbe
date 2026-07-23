-- hudscore_spec.lua — the dot score, the highest-value target.  Exercises the
-- full `ns` STATE surface (HudState / ShardCost / GetReady / napkin) against the
-- REAL SpecDemonology data, so the scoring rules stay honest by construction.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("HudScore.For", function()
  local Sc, fx, ID

  before_each(function()
    local ns, f = H.fresh()
    H.load("HudScore.lua")
    Sc, fx, ID = ns.HudScore, f, ns.SpecIDs
  end)

  -- Score a tracked spell.  `ready` feeds ns.HudChrome.GetReady (the observed
  -- cooldown edge); nil = never observed.
  local function score(id, ready)
    return Sc.For("k" .. tostring(id), { baseSpellID = id, spellID = id, item = { ready = ready } })
  end

  local function reasons(sc) return Sc.Why(sc) end

  ------------------------------------------------------------------------------
  -- The strictness invariant — §0.5.8.2(c): a NEVER state never lights ROTATION
  ------------------------------------------------------------------------------
  it("a reactive proc-button with no proc up is NEVER in combat, never ROTATION", function()
    H.setCombat(true)
    local sc = score(ID.DEMONBOLT)          -- Demonic Core not present
    assert.equals("NEVER", sc.level)
    assert.is_falsy(sc.candidate)
    assert.is_not.equals("ROTATION", sc.level)
  end)

  it("...but the SAME button with its Core proc up IS a live candidate", function()
    H.setCombat(true)
    fx.present[ID.DEMONIC_CORE] = true
    local sc = score(ID.DEMONBOLT)
    assert.equals("ROTATION", sc.level)
  end)

  ------------------------------------------------------------------------------
  -- judgeable = false caps at AVAILABLE + sets judgeReady (Implosion)
  ------------------------------------------------------------------------------
  it("Implosion (judgeable=false) caps at AVAILABLE and flags judgeReady when up", function()
    fx.baseCD[ID.IMPLOSION] = 15
    local sc = score(ID.IMPLOSION, true)    -- otherwise up: only the imp count is secret
    assert.equals("AVAILABLE", sc.level)
    assert.is_true(sc.judgeReady)
  end)

  it("Implosion on cooldown is NEVER (the edge, not the secret gate, decides)", function()
    fx.baseCD[ID.IMPLOSION] = 15
    local sc = score(ID.IMPLOSION, false)
    assert.equals("NEVER", sc.level)
  end)

  ------------------------------------------------------------------------------
  -- IB > DB > SB builder priority (betterBuilder), while building
  ------------------------------------------------------------------------------
  it("in PREP a pure builder (Shadow Bolt) lights when nothing better is up", function()
    fx.mode = "PREP"
    fx.shards = 2
    local sc = score(ID.SHADOW_BOLT)
    assert.equals("ROTATION", sc.level)
    assert.matches("cap for Tyrant", reasons(sc))
  end)

  it("...but not when a Demonic Core is up — spend the better builder first", function()
    fx.mode = "PREP"
    fx.shards = 2
    fx.present[ID.DEMONIC_CORE] = true      -- betterBuilder
    local sc = score(ID.SHADOW_BOLT)
    assert.is_not.equals("ROTATION", sc.level)
    assert.equals("AVAILABLE", sc.level)
  end)

  ------------------------------------------------------------------------------
  -- emphasis == "burst" for Tyrant, nil for everything else (M4.4-A3)
  ------------------------------------------------------------------------------
  it("carries emphasis=burst on Tyrant and nil elsewhere", function()
    fx.baseCD[ID.TYRANT] = 60
    assert.equals("burst", (score(ID.TYRANT, true)).emphasis)
    assert.is_nil((score(ID.HAND_OF_GULDAN)).emphasis)
  end)

  ------------------------------------------------------------------------------
  -- BURST/PREP build-to-cap + stage-for-Tyrant prunes
  ------------------------------------------------------------------------------
  it("in PREP holds the primary spender (HoG) below cap: build to 5", function()
    fx.mode = "PREP"
    fx.cost[ID.HAND_OF_GULDAN] = 1
    fx.shards = 3
    local sc = score(ID.HAND_OF_GULDAN)
    assert.equals("AVAILABLE", sc.level)
    assert.matches("build to cap for Tyrant", reasons(sc))
  end)

  it("...and greenlights HoG AT cap (never overcap the window entry)", function()
    fx.mode = "PREP"
    fx.cost[ID.HAND_OF_GULDAN] = 1
    fx.shards = 5
    local sc = score(ID.HAND_OF_GULDAN)
    assert.equals("ROTATION", sc.level)
  end)

  it("in BURST stages Dreadstalkers (AVAILABLE, not greenlit on cooldown)", function()
    fx.mode = "BURST"
    fx.cost[ID.DREADSTALKERS] = 2
    fx.shards = 5
    fx.baseCD[ID.DREADSTALKERS] = 20
    local sc = score(ID.DREADSTALKERS, true)
    assert.equals("AVAILABLE", sc.level)
    assert.matches("stage for Tyrant", reasons(sc))
  end)

  ------------------------------------------------------------------------------
  -- shards >= cost gating
  ------------------------------------------------------------------------------
  it("gates a shard-costed spender below cost (NEVER) and opens it at cost", function()
    fx.cost[ID.HAND_OF_GULDAN] = 2          -- mode nil: no build prune, just the gate

    fx.shards = 1
    local low = score(ID.HAND_OF_GULDAN)
    assert.equals("NEVER", low.level)
    assert.matches("shards 1<2", reasons(low))

    fx.shards = 3
    local ok = score(ID.HAND_OF_GULDAN)
    assert.equals("ROTATION", ok.level)
  end)
end)
