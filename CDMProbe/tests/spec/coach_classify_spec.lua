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

  -- Classify one entry against a one-entry domain-view pulse (abilities keyed by base
  -- spellID — Classify reads only the entry + state.at, so the wrapper shape is cosmetic).
  local function classify(entry)
    local state = { at = NOW, abilities = { [entry.spellID] = entry } }
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

  it("keys the record on `identity` when the row DISPLAYS a different spell", function()
    -- The Diabolist hole.  State stamps `identity` (ns.DisplayIdentity) with the spell the
    -- row actually shows; the record must key on THAT, because the brain looks its lines up
    -- as `facts[<ability>]`.  Keying on the raw `spellID` is what made Incinerate
    -- unreachable on Diabolist -- 0 wins across 225 live decisions (2026-07-30).
    local SHADOW_BOLT, DEMONBOLT = 686, 264178
    -- The real shape: the row's own id is 686, but it LIVES and DISPLAYS as the other
    -- spell while no transform is armed.
    local row = cd(SHADOW_BOLT, { live = DEMONBOLT })
    row.identity = DEMONBOLT
    local rec = classify(row)
    assert.equals(DEMONBOLT, rec.base)
    -- ...and `transformed` is judged against that same identity, so a row is no longer
    -- reported as permanently transformed just for displaying another spell.
    assert.is_false(rec.transformed)
  end)

  it("falls back to spellID when no identity is stamped (virtual rows, old fixtures)", function()
    local rec = classify(cd(104316))
    assert.equals(104316, rec.base)
  end)

  ------------------------------------------------------------------------------
  -- KNOWNNESS — the Phase 5 §C5 cap, and the ONLY Coach edit the inversion needed.
  ------------------------------------------------------------------------------
  -- State stopped FILTERING on knownness and started MARKING with it: every declared
  -- ability reaches `abilities` now, carrying three-valued `known`, so the decision about
  -- what an unlearned or unreadable ability may DO is made here, once, for all three
  -- brains.  These are that decision — and the fourth case is the one that matters most,
  -- because it is every fixture in every other suite.
  describe("the three-valued `known` cap", function()
    -- Classify against a pulse whose wholesale-guard field can be varied.
    local function classifyIn(entry, stateFields)
      local state = { at = NOW, abilities = { [entry.spellID] = entry } }
      for k, v in pairs(stateFields or {}) do state[k] = v end
      return ns.Coach.Classify(entry, state)
    end

    -- `false` — the client says the character does not have this spell.  Never a
    -- candidate, exactly as an aura row is not: this is what killed the 216-dropped-
    -- Soul-Fire-cues bug, and it has to keep killing it.
    it("known == false ⇒ nil, the same floor an aura row gets", function()
      local row = cd(265187, { cd = napkin(0, 10) })   -- otherwise a hard ROTATION candidate
      row.known = false
      assert.is_nil(classifyIn(row))
    end)

    -- `"unknown"` — we asked and came away with nothing.  The row STAYS (it is in
    -- ctx.facts, in the decision log, in Coverage) and merely may not win: zeroing the
    -- three readiness flags IS "cap at available", read against guidance-contract.json
    -- where AVAILABLE is "off cooldown but not a call — no cue".
    it('known == "unknown" ⇒ a record whose readiness flags are all false', function()
      local row = cd(265187, { cd = napkin(0, 10) })
      row.known = "unknown"
      local rec = classifyIn(row)
      assert.is_truthy(rec)                    -- the row survives...
      assert.is_true(rec.knownUnknown)         -- ...and says why
      assert.is_false(rec.ready)
      assert.is_false(rec.probablyUp)
      assert.is_false(rec.anticipated)
      assert.is_false(rec.overdue)
    end)

    -- ...but the cap is applied over the FINISHED record, so the trace keeps its honest
    -- readings.  A capped row that reports `remaining = nil` cannot be told from one that
    -- was never read.
    it("the cap does not erase the underlying reading (the trace stays honest)", function()
      local row = cd(104316, { cd = napkin(7.5) })
      row.known = "unknown"
      local rec = classifyIn(row)
      assert.is_true(rec.onCd)                 -- the 3-state contract is untouched
      assert.equals(7.5, rec.remaining)
      assert.equals("napkin", rec.cdSource)
      assert.is_false(rec.anticipated)         -- only the READINESS flags are capped
    end)

    -- ⚠ THE WHOLESALE GUARD OVERRIDES BOTH.  `knownReadable == false` means not one
    -- declared ability answered — a broken read, not a bare character — so barring the
    -- roster would blank the HUD for a whole session.  Knownness is ignored in BOTH
    -- directions: the unlearned row comes back, and the unknown row is uncapped.
    it("state.knownReadable == false ignores knownness in both directions", function()
      local unlearned = cd(265187, { cd = napkin(0, 10) })
      unlearned.known = false
      local rec = classifyIn(unlearned, { knownReadable = false })
      assert.is_truthy(rec)                    -- NOT nil — the guard fired
      assert.is_true(rec.probablyUp)

      local unsure = cd(265187, { cd = napkin(0, 10) })
      unsure.known = "unknown"
      local rec2 = classifyIn(unsure, { knownReadable = false })
      assert.is_nil(rec2.knownUnknown)         -- uncapped, not merely un-nil'd
      assert.is_true(rec2.probablyUp)
    end)

    -- ⚠ AND `nil` MUST KEEP MEANING "NOBODY ASKED".  That is why the third value is the
    -- STRING "unknown" and not nil: every hand-built fixture pulse in every other suite
    -- omits the field, and making absence mean "unreadable" would have capped the entire
    -- Coach corpus at once.
    it("an ABSENT known field changes nothing (the pre-Phase-5 fixture shape)", function()
      local row = cd(265187, { cd = napkin(0, 10) })
      assert.is_nil(row.known)
      local rec = classifyIn(row)
      assert.is_truthy(rec)
      assert.is_true(rec.probablyUp)
      assert.is_nil(rec.knownUnknown)
    end)

    it("known == true is likewise a plain pass-through", function()
      local row = cd(265187, { cd = napkin(0, 10) })
      row.known = true
      local rec = classifyIn(row)
      assert.is_true(rec.probablyUp)
      assert.is_nil(rec.knownUnknown)
    end)
  end)
end)
