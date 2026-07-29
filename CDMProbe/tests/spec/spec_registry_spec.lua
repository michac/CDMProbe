-- spec_registry_spec.lua — the multi-spec Phase 1 seam.
--
-- Proves the MECHANISM, not just no-regression: SpecDemonology now self-registers a spec
-- OBJECT into ns.Specs and statically activates it, and the SpecRegistry resolver DERIVES
-- the legacy ns.Spec* globals from the active spec.  The other specs cover behaviour
-- preservation; this one asserts the registry + the rebind + the unsupported-spec contract.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local DEMONOLOGY = 266

describe("SpecRegistry (multi-spec Phase 1 seam)", function()
  local ns
  before_each(function()
    ns = H.fresh()
  end)

  it("registers Demonology and makes it the active spec", function()
    assert.is_table(ns.Specs[DEMONOLOGY])
    assert.equals(ns.Specs[DEMONOLOGY], ns.ActiveSpec)
  end)

  it("rebinds the legacy globals reference-equal to the active spec's fields", function()
    for _, k in ipairs(ns.SpecFields) do
      assert.is_not_nil(ns[k], k .. " should be bound after activation")
      assert.equals(ns.ActiveSpec[k], ns[k], k .. " should be the active spec's field")
    end
    -- Spot-check the three fields with external readers (State / Coach / Probe / …).
    assert.equals(ns.ActiveSpec.SpecIDs, ns.SpecIDs)
    assert.equals(ns.ActiveSpec.SpecInfo, ns.SpecInfo)
    assert.equals(ns.ActiveSpec.SpecShardDelta, ns.SpecShardDelta)
  end)

  it("clears every legacy field when the active spec is unknown (unsupported-spec contract)", function()
    ns.SetActiveSpec(999 --[[ no such spec ]])
    assert.is_nil(ns.ActiveSpec)
    for _, k in ipairs(ns.SpecFields) do
      assert.is_nil(ns[k], k .. " should be cleared for an unsupported spec")
    end
    -- Re-activating restores the rebind, so nothing leaks to later specs.
    ns.SetActiveSpec(DEMONOLOGY)
    assert.equals(ns.Specs[DEMONOLOGY], ns.ActiveSpec)
    assert.equals(ns.ActiveSpec.SpecIDs, ns.SpecIDs)
  end)
end)
