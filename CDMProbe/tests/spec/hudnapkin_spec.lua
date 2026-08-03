-- hudnapkin_spec.lua — the anticipation engine's countdown + honesty rules.
-- Smallest surface, so it also proves the harness: the CreateFrame stub (napkin's
-- module-level `ev = CreateFrame(...)`) and the settable fake clock.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("HudNapkin", function()
  local N, ev
  local SP = 100          -- a stand-in cast spellID with a cooldown

  before_each(function()
    H.fresh()
    H.load("HudNapkin.lua")
    N = H.ns.HudNapkin
    N.Start()             -- registers the OnEvent handler on the module frame
    ev = H.lastFrame()    -- ...which is the last frame CreateFrame handed out
    H.setClock(1000)
  end)

  -- Drive a SUCCEEDED event the way WoW would: (self, event, unit, castGUID, spellID).
  local function succeed(spellID)
    ev:Fire("OnEvent", "UNIT_SPELLCAST_SUCCEEDED", "player", "guid", spellID)
  end

  it("files a cast estimate and counts it down against the fake clock", function()
    H.fx.baseCD[SP] = 60
    succeed(SP)
    assert.equals(60, N.Remaining(SP))
    assert.equals("cast", N.SourceOf(SP))
    H.advance(10)
    assert.equals(50, N.Remaining(SP))
  end)

  ----------------------------------------------------------------------------
  -- THE CHARGE-CATEGORY FALLBACK — a cooldown GetSpellBaseCooldown cannot see.
  ----------------------------------------------------------------------------
  -- ⚠ WHY: a spell whose cooldown lives on a SpellCategory reads base-cooldown 0, so the
  -- napkin stored nothing, State fell through to the alert edge, and for a CHARGED ability
  -- that edge is a latch that never clears (the CDM raises `Available` on every charge
  -- restore and never `OnCooldown`).  Blade of Justice read `ready` on 4419 lines of one
  -- flight and starved every line below it.
  describe("the declared charge-category fallback", function()
    -- `chargeCD` lives on the ACTIVE spec's signal bucket; stub SpecInfo so this file stays
    -- about the napkin rather than about any one spec's data.
    local function withDeclared(id, seconds)
      H.ns.SpecInfo = function(q)
        if q == id then return { chargeCD = seconds }, true end
        return { kind = "button" }, false
      end
    end

    it("files a countdown when the base cooldown reads 0", function()
      H.fx.baseCD[SP] = 0
      withDeclared(SP, 12)
      succeed(SP)
      assert.equals(12, N.Remaining(SP))
      H.advance(5)
      assert.equals(7, N.Remaining(SP))
    end)

    -- PROVENANCE STAYS HONEST.  A spec-authored constant is not an observation and must
    -- never be able to pass for one.
    it("marks it `declared`, never `cast` or `read`", function()
      H.fx.baseCD[SP] = 0
      withDeclared(SP, 12)
      succeed(SP)
      assert.equals("declared", N.SourceOf(SP))
    end)

    -- The live number is a MEASUREMENT and outranks the declaration; the fallback must only
    -- fill a hole, never overwrite a real read.
    it("does NOT override a real base cooldown", function()
      H.fx.baseCD[SP] = 60
      withDeclared(SP, 12)
      succeed(SP)
      assert.equals(60, N.Remaining(SP))
      assert.equals("cast", N.SourceOf(SP))
    end)

    -- The Hand-of-Gul'dan case must survive: genuinely no cooldown => still store nothing.
    it("stores nothing when there is no cooldown and no declaration", function()
      H.fx.baseCD[SP] = 0
      withDeclared(999, 12)
      succeed(SP)
      assert.is_nil(N.Remaining(SP))
    end)

    -- An OBSERVED edge still wins outright — the fence that makes a constant safe.
    it("is cleared by an observed Available edge, like any other record", function()
      H.fx.baseCD[SP] = 0
      withDeclared(SP, 12)
      succeed(SP)
      N.Clear(SP)
      assert.is_nil(N.Remaining(SP))
    end)
  end)

  it("a read seed overwrites a cast estimate (precedence 2)", function()
    H.fx.baseCD[SP] = 60
    succeed(SP)
    assert.equals("cast", N.SourceOf(SP))
    N.Seed(SP, 1000, 42)          -- the client's own number
    assert.equals("read", N.SourceOf(SP))
    assert.equals(42, N.Remaining(SP))
  end)

  it("an observed Available edge (Clear) retires the estimate — ground truth wins", function()
    H.fx.baseCD[SP] = 60
    succeed(SP)
    assert.is_not_nil(N.Remaining(SP))
    N.Clear(SP)
    assert.is_nil(N.Remaining(SP))
  end)

  it("an expired estimate reads 0 (should be up, unconfirmed) and never promotes", function()
    H.fx.baseCD[SP] = 60
    succeed(SP)
    H.advance(70)                 -- past the estimate, no edge seen
    assert.equals(0, N.Remaining(SP))   -- 0, NOT nil and NOT negative
    assert.is_true(N.Unconfirmed(SP))
  end)

  it("a secret SUCCEEDED spellID marks the channel unreadable and files nothing", function()
    H.markSecret(999)
    succeed(999)
    assert.is_false(N.readable)
    assert.is_true(N.secret >= 1)
    assert.is_nil(N.Remaining(999))     -- no countdown filed for a secret cast
  end)

  it("reports nil source for a spell never cast", function()
    assert.is_nil(N.SourceOf(SP))
    assert.is_nil(N.Remaining(SP))
  end)
end)
