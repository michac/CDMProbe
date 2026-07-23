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
