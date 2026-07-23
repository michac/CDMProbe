-- hudqueue_spec.lua — the reusable sequence widget's drain/skip/count/prime
-- mechanics.  Proves the frame stub carries `render` end-to-end: every assertion
-- reads the rendered strip text off the stubbed FontString.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

-- The strip's "bright" colour code (HudQueue TERM = {0.92,0.94,0.98}), derived the
-- same way the module does so the test tracks the palette rather than hardcoding.
local function hex(c)
  return string.format("%02x%02x%02x",
    math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local BRIGHT = "|cff" .. hex({ 0.92, 0.94, 0.98 })

describe("HudQueue", function()
  local Q, viewer

  before_each(function()
    H.fresh()
    H.load("HudQueue.lua")
    Q = H.ns.HudQueue
    viewer = H.newStub()
  end)

  local function ensure() return Q.Ensure(viewer, "t", 8, "horizontal") end
  local function strip(inst) return inst.frame.strip:GetText() or "" end
  local function has(inst, s) return strip(inst):find(s, 1, true) ~= nil end
  local function isBright(inst) return strip(inst):find(BRIGHT, 1, true) ~= nil end

  local function spec3()
    return { header = "OP", steps = {
      { spell = 1, key = "A" }, { spell = 2, key = "B" }, { spell = 3, key = "C" } } }
  end

  ------------------------------------------------------------------------------
  -- The C1 invariant (M4.4)
  ------------------------------------------------------------------------------
  it("C1: an UN-primed queue always brightens the current step, even ready=false", function()
    local inst = ensure()
    inst:Arm(spec3())              -- Arm leaves it un-primed, ready=false
    assert.is_true(isBright(inst)) -- the dim-until-ready gate must NOT bite here
  end)

  it("the dim-until-ready gate only bites while PRIMED", function()
    local inst = ensure()
    inst:Arm(spec3())
    inst:SetPrimed(true)
    inst:SetReady(false)
    assert.is_false(isBright(inst))   -- primed + not ready => fully dim
    inst:SetReady(true)
    assert.is_true(isBright(inst))    -- prereq wall reports in => current brightens
  end)

  ------------------------------------------------------------------------------
  -- prime -> un-prime on the first matching press
  ------------------------------------------------------------------------------
  it("while primed, only a step-1 press un-primes; others are ignored", function()
    local inst = ensure()
    inst:Arm(spec3())
    inst:SetPrimed(true)
    assert.is_false(inst:Advance(2))  -- a later step's spell: ignored while primed
    assert.is_true(inst:Advance(1))   -- step 1: un-primes and advances
  end)

  ------------------------------------------------------------------------------
  -- drop-through on out-of-order presses (never jam)
  ------------------------------------------------------------------------------
  it("matching a later step drops through the earlier un-pressed ones", function()
    local inst = ensure()
    inst:Arm(spec3())                 -- un-primed: drop-through active
    assert.is_true(inst:Advance(2))   -- press B: consumes A and B
    assert.equals("C", inst:Info().current)
  end)

  ------------------------------------------------------------------------------
  -- stepSkipped: an optional step whose ability is on cooldown drops out
  ------------------------------------------------------------------------------
  it("an optional step on cooldown is skipped from the strip, then the rest still show", function()
    local inst = ensure()
    inst.stepReadyFn = function(spell) return spell ~= 2 end  -- B (spell 2) not ready
    inst:Arm({ steps = {
      { spell = 1, key = "A" },
      { spell = 2, key = "B", optional = true },
      { spell = 3, key = "C" } } })
    assert.is_false(has(inst, "[B]"))
    assert.is_true(has(inst, "[A]"))
    assert.is_true(has(inst, "[C]"))
  end)

  ------------------------------------------------------------------------------
  -- +N more overflow past MAX_STEPS (10)
  ------------------------------------------------------------------------------
  it("a script longer than MAX_STEPS renders a +N overflow tail", function()
    local steps = {}
    for i = 1, 13 do steps[i] = { spell = i, key = "K" .. i } end
    local inst = ensure()
    inst:Arm({ steps = steps })
    assert.is_true(has(inst, "+3"))   -- 13 steps, 10 shown -> "+3"
  end)
end)
