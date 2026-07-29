-- resource_multipower_spec.lua — the multi-spec Phase 3 "FULL SEAM" proof.
--
-- Phase 3 turned the resource path from "one hardcoded Soul Shard bar" into an ARRAY of
-- named powers a spec declares (spec.powers).  The point of the phase is that a
-- DUAL-RESOURCE spec (energy + combo points, runes + runic power, …) is now EXPRESSIBLE
-- end to end.  There is no live second spec yet, so this spec fabricates a synthetic
-- 2-power fake spec and drives the two seam ends off-game:
--
--   * State  — inflightIncoming sums each in-flight cast's { power, delta } onto its OWN
--              named power (a MAP, not a scalar); projectIncoming folds that map onto the
--              live power table walking spec.powers.  (Pure cores of State.Build, exposed
--              as St.InflightIncoming / St.ProjectIncoming for this proof.)
--   * Coach  — the generic shell emits ONE resourceBar per declared power off ctx.powers.
--
-- Plus the behaviour-preserved check: Demonology (one declared power) still emits exactly
-- one shard bar — the phase is a framework change, not a visual one.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local FIRE_ID  = 900001   -- fake builder feeding power A (Energy)
local FROST_ID = 900002   -- fake builder feeding power B (ComboPoints)

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
  -- The bare-minimum brain the shell's Compute delegates to: build ctx.powers off
  -- self.powers × state.power[name] (exactly the shape CoachDemonology fills), no winner.
  function spec:Context(state, _env)
    local ctx = { facts = {}, powers = {} }
    for _, p in ipairs(self.powers) do
      local pw = (state.power or {})[p.name] or {}
      ctx.powers[#ctx.powers + 1] = {
        value = pw.value, max = pw.max, incoming = pw.incoming or 0,
        display = p.display, powerType = p.token,
      }
    end
    return ctx
  end
  function spec:RankWinner() return nil end
  function spec:Escalate(_k, level) return level end
  return spec
end

describe("multi-power resource seam (Phase 3 full-seam proof)", function()
  local ns

  before_each(function()
    ns = H.fresh()
  end)

  describe("State projects incoming onto two named powers", function()
    before_each(function()
      H.load("State.lua")
      ns.RegisterSpec(900, makeDualSpec())
      ns.SetActiveSpec(900)   -- rebinds ns.SpecPowerDelta from the dual spec
    end)

    it("sums each in-flight builder onto its OWN power (a per-power map)", function()
      local hist = {
        { phase = "start", spellID = FIRE_ID,  base = FIRE_ID,  at = 0 },
        { phase = "start", spellID = FROST_ID, base = FROST_ID, at = 0 },
      }
      local sums = ns.State.InflightIncoming(0, nil, hist)
      assert.equals(2, sums.Energy)
      assert.equals(1, sums.ComboPoints)
    end)

    it("folds the per-power sums onto the live power table, walking spec.powers", function()
      local power = {
        Energy      = { value = 40, max = 100 },
        ComboPoints = { value = 3,  max = 5 },
      }
      ns.State.ProjectIncoming(power, { Energy = 2, ComboPoints = 1 }, ns.ActiveSpec.powers)
      assert.equals(2, power.Energy.incoming)
      assert.equals(1, power.ComboPoints.incoming)
    end)

    it("defaults a declared power with nothing in flight to incoming 0", function()
      local power = { Energy = { value = 40, max = 100 }, ComboPoints = { value = 3, max = 5 } }
      ns.State.ProjectIncoming(power, { Energy = 2 }, ns.ActiveSpec.powers)
      assert.equals(2, power.Energy.incoming)
      assert.equals(0, power.ComboPoints.incoming)   -- declared incoming, none in flight
    end)
  end)

  describe("the Coach emits one resourceBar per declared power", function()
    it("emits two resourceBars from a 2-power spec's ctx.powers", function()
      ns.RegisterSpec(900, makeDualSpec())
      ns.SetActiveSpec(900)
      H.load("Coach.lua")

      local state = { at = 0, power = {
        Energy      = { value = 40, max = 100, incoming = 2 },
        ComboPoints = { value = 3,  max = 5,   incoming = 1 },
      } }
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
      local state = { at = 0, abilities = {}, buffs = {},
                      power = { SoulShards = { value = 3, max = 5, incoming = 0, readable = true } } }
      local guidance = ns.Coach.New():Compute(state)
      assert.equals(1, #guidance.resourceBars)
      assert.equals("SOUL_SHARDS", guidance.resourceBars[1].powerType)
      assert.equals(3, guidance.resourceBars[1].value)
      assert.equals("discrete", guidance.resourceBars[1].display)
    end)
  end)
end)
