-- coach_classify_spec.lua — Stage-2 Classify in ISOLATION (W4 Phase 2b).
--
-- Classify is the pure per-cooldown pass that REUSES HudScore's readable sub-logic
-- re-pointed at the State pulse, and reads the W4 Phase 7 3-state contract
-- (ready | on-cooldown | unknown): an on-cooldown with an ELAPSED napkin estimate
-- is ROTATION-eligible (probablyUp), NOT floored to NEVER, and an observed `ready`
-- is a hard press.  These tests drive it against real golden state.json entries and
-- assert the CANDIDATE RECORD (not a final level — that is the cascade's job,
-- covered by coach_golden_spec).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")
local FIX = dofile(dir .. "../json_fixture.lua")

describe("Coach.Classify", function()
  local ns
  before_each(function()
    ns = H.fresh()
    H.load("Coach.lua")
  end)

  -- Pull the classified record for a base spellID out of a scenario's pulse.
  local function recFor(scenario, base)
    local state = FIX.state(scenario)
    for _, cd in pairs(state.cooldowns) do
      if cd.spellID == base then return ns.Coach.Classify(cd, state), state end
    end
    return nil
  end

  it("returns nil for an aura entry (auras are inputs, never scored)", function()
    -- Demonic Core (264173) is a TrackedBuff aura in every pulse.
    local rec = recFor("demonbolt-proc", 264173)
    assert.is_nil(rec)
  end)

  it("marks an ELAPSED napkin as probably-up (the ROTATION-eligible case)", function()
    -- tyrant-ready: Tyrant cd is on-cooldown/napkin, remaining 0 (estimate elapsed).
    local rec = recFor("tyrant-ready", 265187)
    assert.is_truthy(rec)
    assert.is_true(rec.onCd)
    assert.is_true(rec.probablyUp)
    assert.is_false(rec.ready)
    assert.is_false(rec.anticipated)
  end)

  it("marks a counting-down napkin as anticipated, not probably-up", function()
    -- soon-anticipated: Tyrant is on-cooldown with ~2s remaining.
    local rec = recFor("soon-anticipated", 265187)
    assert.is_true(rec.onCd)
    assert.is_true(rec.anticipated)
    assert.is_false(rec.probablyUp)
    assert.equals(2.0, rec.remaining)
  end)

  it("marks a far cooldown as on-cooldown, anticipated but not probably-up", function()
    -- hand-of-guldan: Dreadstalkers on-cooldown ~7.5s (beyond the lead).
    local rec = recFor("hand-of-guldan", 104316)
    assert.is_true(rec.onCd)
    assert.is_true(rec.anticipated)
    assert.is_false(rec.probablyUp)
  end)

  it("detects a Demonic Art transform on the live override (Ruination on HoG)", function()
    -- ruination: the HoG frame's liveSpellID is Ruination (spends == art).
    local rec = recFor("ruination", 105174)
    assert.is_true(rec.transformed)
    assert.equals(434635, rec.live)
    assert.equals(105174, rec.base)
  end)

  it("does NOT flag a transform on an untransformed frame", function()
    local rec = recFor("hand-of-guldan", 105174)
    assert.is_false(rec.transformed)
    assert.equals(rec.base, rec.live)
  end)

  it("reads a readable glow as an armed proc (Demonbolt Core)", function()
    local rec = recFor("demonbolt-proc", 264178)
    assert.is_true(rec.glowActive)
  end)

  it("flags overdue only for an elapsed-past-the-lead probably-up press", function()
    -- overdue-late: Dreadstalkers probably-up, changedAt ~6s old -> overdue.
    local overdue = recFor("overdue-late", 104316)
    assert.is_true(overdue.probablyUp)
    assert.is_true(overdue.overdue)
    -- dreadstalkers: Dreadstalkers probably-up but freshly so -> not overdue.
    local fresh = recFor("dreadstalkers", 104316)
    assert.is_true(fresh.probablyUp)
    assert.is_false(fresh.overdue)
  end)
end)
