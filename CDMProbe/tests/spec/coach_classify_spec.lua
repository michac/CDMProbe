-- coach_classify_spec.lua — Stage-2 Classify in ISOLATION (W4 Phase 2b).
--
-- Classify is the pure per-cooldown pass that REUSES HudScore's readable sub-logic
-- re-pointed at the State pulse, and reads the W4 Phase 7 3-state contract
-- (ready | on-cooldown | unknown): an on-cooldown with an ELAPSED napkin estimate
-- is ROTATION-eligible (probablyUp), NOT floored to NEVER, and an observed `ready`
-- is a hard press.  These tests drive it against INLINE State-pulse fragments (the
-- golden corpus retired in W4 Phase 8) and assert the CANDIDATE RECORD (not a final
-- level — that is the cascade's job, covered by coach_apl_spec).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local NOW = 1000

-- One cooldown entry carrying only the fields Classify reads.
local function cd(spellID, opts)
  opts = opts or {}
  return {
    cooldownID = opts.cid or spellID,
    spellID = spellID,
    liveSpellID = opts.live or spellID,
    overrideSpellID = opts.live or spellID,
    category = opts.category or "Essential",
    cd = opts.cd or { state = "unknown", readable = false, source = "none" },
    glow = { active = opts.glow or false, readable = true },
    buff = opts.buff,
  }
end

-- A napkin cooldown: `remaining` 0 => estimate elapsed (probably-up); >0 => counting
-- down (anticipated).  `age` backdates changedAt to control overdue-ness.
local function napkin(remaining, age)
  return { state = "on-cooldown", remaining = remaining, readable = false,
           source = "napkin", changedAt = NOW - (age or 1) }
end

describe("Coach.Classify", function()
  local ns
  before_each(function()
    ns = H.fresh()
    H.load("Coach.lua")
  end)

  -- Classify one entry against a one-entry pulse.
  local function classify(entry)
    local state = { at = NOW, cooldowns = { [entry.cooldownID] = entry } }
    return ns.Coach.Classify(entry, state)
  end

  it("returns nil for an aura entry (auras are inputs, never scored)", function()
    -- Demonic Core (264173) is a TrackedBuff aura.
    local rec = classify(cd(264173, { category = "TrackedBuff", buff = { isActive = true } }))
    assert.is_nil(rec)
  end)

  it("marks an ELAPSED napkin as probably-up (the ROTATION-eligible case)", function()
    -- Tyrant cd on-cooldown/napkin, remaining 0 (estimate elapsed).
    local rec = classify(cd(265187, { cd = napkin(0, 10) }))
    assert.is_truthy(rec)
    assert.is_true(rec.onCd)
    assert.is_true(rec.probablyUp)
    assert.is_false(rec.ready)
    assert.is_false(rec.anticipated)
  end)

  it("marks a counting-down napkin as anticipated, not probably-up", function()
    -- Tyrant on-cooldown with ~2s remaining.
    local rec = classify(cd(265187, { cd = napkin(2.0) }))
    assert.is_true(rec.onCd)
    assert.is_true(rec.anticipated)
    assert.is_false(rec.probablyUp)
    assert.equals(2.0, rec.remaining)
  end)

  it("marks a far cooldown as on-cooldown, anticipated but not probably-up", function()
    -- Dreadstalkers on-cooldown ~7.5s (beyond the lead).
    local rec = classify(cd(104316, { cd = napkin(7.5) }))
    assert.is_true(rec.onCd)
    assert.is_true(rec.anticipated)
    assert.is_false(rec.probablyUp)
  end)

  it("detects a Demonic Art transform on the live override (Ruination on HoG)", function()
    -- The HoG frame's liveSpellID is Ruination (spends == art).
    local rec = classify(cd(105174, { live = 434635, glow = true }))
    assert.is_true(rec.transformed)
    assert.equals(434635, rec.live)
    assert.equals(105174, rec.base)
  end)

  it("does NOT flag a transform on an untransformed frame", function()
    local rec = classify(cd(105174))
    assert.is_false(rec.transformed)
    assert.equals(rec.base, rec.live)
  end)

  it("reads a readable glow as an armed proc (Demonbolt Core)", function()
    local rec = classify(cd(264178, { glow = true }))
    assert.is_true(rec.glowActive)
  end)

  it("flags overdue only for an elapsed-past-the-lead probably-up press", function()
    -- Dreadstalkers probably-up, changedAt ~6s old -> overdue.
    local overdue = classify(cd(104316, { cd = napkin(0, 6) }))
    assert.is_true(overdue.probablyUp)
    assert.is_true(overdue.overdue)
    -- Dreadstalkers probably-up but freshly so -> not overdue.
    local fresh = classify(cd(104316, { cd = napkin(0, 1) }))
    assert.is_true(fresh.probablyUp)
    assert.is_false(fresh.overdue)
  end)
end)
