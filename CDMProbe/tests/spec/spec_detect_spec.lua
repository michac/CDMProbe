-- spec_detect_spec.lua — ns.ResolveActiveSpec, the live spec detector (multi-spec Phase 5).
--
-- Before Phase 5 the active spec was hardcoded: SpecDemonology.lua ended with a static
-- SetActiveSpec(266).  The resolver replaces that with a read of the player's real spec
-- (GetSpecialization -> GetSpecializationInfo -> specID), activating the matching
-- REGISTERED spec or going PASSIVE (ActiveSpec = nil, every SpecField cleared) when none is
-- registered.  Only Demonology (266) is registered, so every other spec resolves passive —
-- intended.  The mock's GetSpecialization/GetSpecializationInfo fakes (index -> specID) let
-- us drive each path; H.specByIndex maps 1=266 Demo, 2=265 Aff (unregistered), 3=267 Destro.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local DEMONOLOGY = 266
local AFFLICTION = 265   -- deliberately NOT registered — the passive/unsupported fixture

describe("ns.ResolveActiveSpec (live spec detection)", function()
  local ns

  before_each(function()
    ns = (H.fresh())   -- fresh() already resolves to Demonology (index 1) via the real path
  end)

  it("resolves a KNOWN spec: activates the Demo object + rebinds the SpecFields", function()
    assert.equals(DEMONOLOGY, ns.detectedSpecID)
    assert.equals("Demonology", ns.detectedSpecName)
    assert.equals(ns.Specs[DEMONOLOGY], ns.ActiveSpec)
    -- The legacy globals are rebound off the active spec (a couple, as proof).
    assert.is_function(ns.SpecInfo)
    assert.equals(ns.Specs[DEMONOLOGY].SpecInfo, ns.SpecInfo)
    assert.equals(ns.Specs[DEMONOLOGY].SpecIDs, ns.SpecIDs)
  end)

  it("goes PASSIVE on an UNSUPPORTED spec: ActiveSpec nil, SpecFields cleared, name kept", function()
    H.setSpecIndex(2)   -- Affliction (265), not registered
    ns.ResolveActiveSpec()
    assert.is_nil(ns.ActiveSpec)
    assert.is_nil(ns.SpecInfo)   -- the passive contract: legacy fields cleared
    assert.is_nil(ns.SpecIDs)
    -- ...but we still recorded WHAT we saw, for the status line.
    assert.equals(AFFLICTION, ns.detectedSpecID)
    assert.equals("Affliction", ns.detectedSpecName)
  end)

  it("handles NO spec selected (fresh char): leaves state passive without erroring", function()
    -- Put the namespace back to a pristine passive state (no prior resolution), then make
    -- GetSpecialization() return nil — the "no spec chosen yet" case.
    ns.detectedSpecID, ns.detectedSpecName = nil, nil
    ns.SetActiveSpec(nil)   -- ActiveSpec = nil + every SpecField cleared
    H.setSpecIndex(nil)
    assert.has_no.errors(function() ns.ResolveActiveSpec() end)
    -- Early return: nothing activated, nothing detected.
    assert.is_nil(ns.ActiveSpec)
    assert.is_nil(ns.detectedSpecID)
  end)

  it("SWAP 266 -> 265 -> 266 rebinds correctly and clears the napkin ON CHANGE ONLY", function()
    -- Spy on the caches the resolver must clear on a change.
    local napkinResets, bindInvalidations = 0, 0
    ns.HudNapkin = { Reset = function() napkinResets = napkinResets + 1 end }
    ns.HudBinds  = { Invalidate = function() bindInvalidations = bindInvalidations + 1 end }

    -- Re-resolving the SAME spec (still 266) is a no-op: no rebind, no cache clear.
    ns.ResolveActiveSpec()
    assert.equals(0, napkinResets)
    assert.equals(0, bindInvalidations)
    assert.equals(ns.Specs[DEMONOLOGY], ns.ActiveSpec)

    -- 266 -> 265 (unsupported): passive, and the swap clears both caches.
    H.setSpecIndex(2)
    ns.ResolveActiveSpec()
    assert.is_nil(ns.ActiveSpec)
    assert.equals(1, napkinResets)
    assert.equals(1, bindInvalidations)

    -- 265 -> 266 (back to supported): rebinds Demo, clears again.
    H.setSpecIndex(1)
    ns.ResolveActiveSpec()
    assert.equals(ns.Specs[DEMONOLOGY], ns.ActiveSpec)
    assert.equals(2, napkinResets)
    assert.equals(2, bindInvalidations)
  end)
end)
