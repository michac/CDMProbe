-- hudburst_spec.lua — the isBurstStep scoping one-liner (M4.4-E).  Confirms the
-- floating reward text stays scoped to burst-window presses.  Reads the real
-- ns.SpecBurst.steps + SpecInfo(...).burstAlign via the B._isBurstStep test seam.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("HudBurst.isBurstStep", function()
  local isBurstStep, ID

  before_each(function()
    local ns = H.fresh()
    H.load("HudBurst.lua")
    isBurstStep, ID = ns.HudBurst._isBurstStep, ns.SpecIDs
  end)

  it("accepts the burst-window sequence steps", function()
    assert.is_true(isBurstStep(ID.TYRANT))
    assert.is_true(isBurstStep(ID.DREADSTALKERS))
    assert.is_true(isBurstStep(ID.HAND_OF_GULDAN))
    assert.is_true(isBurstStep(ID.DEMONBOLT))
    assert.is_true(isBurstStep(ID.IMPLOSION))
  end)

  it("rejects a non-burst utility (Shadowfury)", function()
    assert.is_false(isBurstStep(30283))
  end)

  it("rejects a non-number spellID", function()
    assert.is_false(isBurstStep(nil))
    assert.is_false(isBurstStep("265187"))
  end)
end)
