-- coverage_spec.lua — the ROSTER COVERAGE JOIN (roster-state-plan Phase 4).
--
-- `ns.Coverage.Build` is pure given its injected deps, so every case below is
-- (hand-built row array + fake roster) -> report.  No client, no frames, no clock.
--
-- WHAT THIS FILE IS ABOUT.  Not "does the readout look nice" — the vocabulary.  A
-- declared roster id is `tracked` / `untracked` / `unreadable`, and an untracked one is
-- `virtual` (we draw our own icon), `expected` (an override-only id, declared BECAUSE it
-- only ever appears as an override) or `blind` — the one that is loud.  Getting that
-- classification wrong in either direction breaks the probe: a false `blind` cries wolf
-- until the report is ignored, a false `ok` is the silent blindness it exists to end.
--
-- ⚠ THE ROW SOURCE IS NOT PROVEN HERE.  A hand-built row array proves the join and
-- nothing about where rows come from; `state_domainview_spec`'s "St.CoverageRows (the
-- coverage probe's row source)" block is the shipped-symbol companion, exactly as
-- `viewers_spec` is for `hudlayout_spec`.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

-- Real Destruction ids, so a verdict reads as the ability it actually is.
local CHAOS_BOLT    = 116858
local INCINERATE    = 29722
local RUINATION     = 433885
local BACKDRAFT     = 117828
local DIABOLIC_RITUAL = 428514
local IMMOLATE_AURA = 157736
local IMMOLATE_CAST = 348

--------------------------------------------------------------------------------
-- A CDM row, shaped exactly as St.CoverageRows emits one.
--------------------------------------------------------------------------------
local function row(cid, base, opts)
  opts = opts or {}
  return {
    cooldownID = cid,
    category   = opts.category or "Essential",
    spellID    = base,
    overrideSpellID = opts.overrideSpellID,
    overrideTooltipSpellID = opts.overrideTooltipSpellID,
    linkedSpellIDs = opts.linkedSpellIDs or {},
    isKnown    = opts.isKnown,
    readable   = opts.readable ~= false,
  }
end

-- The deps, all inert by default.  A case overrides only the one it is about — the same
-- discipline the CDM fixtures use, so a passing case cannot be leaning on an accident.
local function deps(over)
  local d = {
    readAlerts   = function() return {} end,       -- a real answer: "raises nothing"
    known        = function() return true end,
    baseCooldown = function() return 30 end,       -- non-zero ⇒ NOT virtual-eligible
    alertName    = function(v) return "Alert" .. tostring(v) end,
  }
  for k, v in pairs(over or {}) do d[k] = v end
  return d
end

local function entryFor(report, spellID)
  for _, e in ipairs(report.entries) do
    if e.spellID == spellID then return e end
  end
  return nil
end

--------------------------------------------------------------------------------
describe("Coverage.Build — the roster/CDM join", function()
  local ns, Cov
  before_each(function()
    ns = H.fresh()
    H.load("State.lua")          -- the REAL VirtualCandidates fences
    Cov = H.load("Coverage.lua")
    Cov = ns.Coverage
  end)

  ------------------------------------------------------------------------------
  -- The four joins.  Four cases, not one parametrised case, because they are four
  -- separate facts about a row and each has its own way of going missing.
  ------------------------------------------------------------------------------
  describe("tracked — the four ways a row can carry a declared id", function()
    local roster = { [CHAOS_BOLT] = { kind = "button", cadence = "gated", label = "Chaos Bolt" } }

    it("on the BASE spellID", function()
      local r = Cov.Build({ row(11, CHAOS_BOLT) }, roster, deps())
      local e = entryFor(r, CHAOS_BOLT)
      assert.equals("tracked", e.coverage)
      assert.equals("ok", e.verdict)
      assert.equals(11, e.rows[1].cooldownID)
      assert.equals("spellID", e.rows[1].via)
    end)

    it("on overrideSpellID — the Demonic Art transform's only surface", function()
      local r = Cov.Build({ row(12, 99999, { overrideSpellID = CHAOS_BOLT }) }, roster, deps())
      local e = entryFor(r, CHAOS_BOLT)
      assert.equals("tracked", e.coverage)
      assert.equals("overrideSpellID", e.rows[1].via)
    end)

    it("on overrideTooltipSpellID", function()
      local r = Cov.Build({ row(13, 99999, { overrideTooltipSpellID = CHAOS_BOLT }) },
                          roster, deps())
      assert.equals("tracked", entryFor(r, CHAOS_BOLT).coverage)
      assert.equals("overrideTooltipSpellID", entryFor(r, CHAOS_BOLT).rows[1].via)
    end)

    it("on a linkedSpellIDs MEMBER", function()
      local r = Cov.Build({ row(14, 99999, { linkedSpellIDs = { 5, CHAOS_BOLT } }) },
                          roster, deps())
      assert.equals("tracked", entryFor(r, CHAOS_BOLT).coverage)
      assert.equals("linkedSpellIDs", entryFor(r, CHAOS_BOLT).rows[1].via)
    end)

    it("one id tracked by SEVERAL rows keeps them all (Diabolic Ritual's four)", function()
      local r = Cov.Build({ row(21, DIABOLIC_RITUAL, { category = "TrackedBuff" }),
                            row(22, DIABOLIC_RITUAL, { category = "TrackedBuff" }),
                            row(23, DIABOLIC_RITUAL, { category = "TrackedBuff" }) },
                          { [DIABOLIC_RITUAL] = { kind = "aura", label = "Diabolic Ritual" } },
                          deps())
      assert.equals(3, #entryFor(r, DIABOLIC_RITUAL).rows)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("untracked — the three verdicts", function()
    it("an AURA the CDM tracks nowhere is BLIND — the loud one", function()
      -- Crashing Chaos's shape: declared, zero rows, and in combat there is no readable
      -- channel for it at all (C_UnitAuras fully secret, the combat log unregisterable).
      local r = Cov.Build({ row(31, CHAOS_BOLT) },
                          { [417234] = { kind = "aura", label = "Crashing Chaos" } },
                          deps())   -- deps().known says TRUE: the character HAS it
      local e = entryFor(r, 417234)
      assert.equals("untracked", e.coverage)
      assert.equals("blind", e.verdict)
      assert.equals(1, r.counts.blind)
    end)

    it("an untracked BUTTON with no base cooldown is VIRTUAL — we draw our own icon", function()
      -- Incinerate's shape.  The verdict comes from the REAL St.VirtualCandidates fences,
      -- not from a copy of them here; `baseCooldown == 0` is the fence that decides it.
      local r = Cov.Build({ row(32, CHAOS_BOLT) },
                          { [INCINERATE] = { kind = "button", cadence = "filler",
                                             label = "Incinerate" } },
                          deps({ baseCooldown = function() return 0 end }))
      local e = entryFor(r, INCINERATE)
      assert.equals("untracked", e.coverage)
      assert.equals("virtual", e.verdict)
      assert.equals(0, r.counts.blind)
    end)

    it("an untracked `expect = false` alias is EXPECTED, never blind", function()
      -- Ruination / Singe Magic / the Immolate cast id: declared BECAUSE they only ever
      -- appear as an override.  Reporting them would drown the one entry that matters.
      local r = Cov.Build({ row(33, CHAOS_BOLT) },
                          { [RUINATION] = { kind = "button", cadence = "reactive",
                                            expect = false, label = "Ruination" } },
                          deps())
      local e = entryFor(r, RUINATION)
      assert.equals("untracked", e.coverage)
      assert.equals("expected", e.verdict)
      assert.equals(0, r.counts.blind)
    end)

    it("an untracked id the character DOES NOT HAVE is `unlearned`, never blind", function()
      -- ⚠ FIELD-DRIVEN (2026-08-01).  As first shipped, `blind` ignored knownness — and
      -- every blind row the first flight produced was this shape: Axe Toss 119914 with no
      -- Felguard on the character, and Wither 445468 untalented on Diabolist.  Three loud
      -- rows, zero real findings.  There is nothing to be blind TO.
      local r = Cov.Build({ row(35, CHAOS_BOLT) },
                          { [119914] = { kind = "button", cadence = "utility",
                                         label = "Axe Toss" } },
                          deps({ known = function() return false end }))
      local e = entryFor(r, 119914)
      assert.equals("untracked", e.coverage)
      assert.equals("unlearned", e.verdict)
      assert.equals(0, r.counts.blind)
      assert.equals(1, r.counts.unlearned)
    end)

    it("an untracked id whose knownness REFUSED is `unknown`, never blind", function()
      -- We cannot claim they have it, so we cannot claim blindness either — an unprovable
      -- alarm is not an alarm.  The same direction as the wholesale guard, per row.
      local r = Cov.Build({ row(36, CHAOS_BOLT) },
                          { [119914] = { kind = "button", cadence = "utility",
                                         label = "Axe Toss" } },
                          deps({ known = function() return nil end }))
      assert.equals("unknown", entryFor(r, 119914).verdict)
      assert.equals(0, r.counts.blind)
    end)

    it("`blind` therefore means: the character HAS it and the CDM tracks it nowhere", function()
      -- The positive control for the two cases above — the same roster entry, the only
      -- difference being that knownness now reads TRUE, must still be loud.
      local r = Cov.Build({ row(37, CHAOS_BOLT) },
                          { [119914] = { kind = "button", cadence = "utility",
                                         label = "Axe Toss" } },
                          deps({ known = function() return true end }))
      assert.equals("blind", entryFor(r, 119914).verdict)
      assert.equals(1, r.counts.blind)
    end)

    it("entries are sorted LOUDEST first — blind before the quiet verdicts", function()
      local r = Cov.Build({ row(34, CHAOS_BOLT) }, {
        [CHAOS_BOLT] = { kind = "button", cadence = "gated", label = "Chaos Bolt" },
        [RUINATION]  = { kind = "button", cadence = "reactive", expect = false, label = "Ru" },
        [417234]     = { kind = "aura", label = "Crashing Chaos" },
      }, deps())
      assert.equals("blind", r.entries[1].verdict)
      assert.equals(417234, r.entries[1].spellID)
    end)
  end)

  ------------------------------------------------------------------------------
  -- THE WHOLESALE GUARD.  The single most important case in the file.
  ------------------------------------------------------------------------------
  describe("the wholesale guard", function()
    local roster = {
      [CHAOS_BOLT]      = { kind = "button", cadence = "gated", label = "Chaos Bolt" },
      [BACKDRAFT]       = { kind = "aura", label = "Backdraft" },
      [DIABOLIC_RITUAL] = { kind = "aura", label = "Diabolic Ritual" },
    }

    it("zero scanned rows ⇒ ok = false, reason cdm-empty, and NOT ONE entry", function()
      -- An empty database means "the read refused" (viewers not up, CDM unavailable, a
      -- login race), never "your whole roster is blind".  Without this the probe cries
      -- wolf on every login and gets ignored — worse than not existing at all.
      --
      -- ⚠ MUTATION CHECK.  Delete the `#rows == 0` guard in Coverage.lua and this case
      -- MUST go red: with the guard gone the join runs over an empty index and every one
      -- of these three ids reads `blind`.  If it stays green, it is not testing the guard.
      local r = Cov.Build({}, roster, deps())
      assert.is_false(r.ok)
      assert.equals("cdm-empty", r.reason)
      assert.equals(0, #r.entries)
      assert.equals(0, r.counts.blind)
      assert.equals(0, r.scanned)
    end)

    it("nil rows are the same refusal, not a crash", function()
      local r = Cov.Build(nil, roster, deps())
      assert.is_false(r.ok)
      assert.equals("cdm-empty", r.reason)
    end)

    it("no spec active ⇒ an empty report reading no-spec", function()
      -- Checked BEFORE the row count, because it is the more specific answer: a passive
      -- spec would otherwise report cdm-empty and send the reader hunting a CDM problem.
      assert.equals("no-spec", Cov.Build({}, nil, deps()).reason)
      assert.equals("no-spec", Cov.Build({ row(41, CHAOS_BOLT) }, {}, deps()).reason)
      assert.equals(0, #Cov.Build({ row(41, CHAOS_BOLT) }, {}, deps()).entries)
    end)

    it("a row that REFUSED its fields makes untracked unprovable, not blind", function()
      -- The per-row twin of the wholesale guard: an unreadable row could be carrying any
      -- id, so a negative over it is a guess.  It degrades to `unknown` (mild), and the
      -- refused count is reported so the reader knows why.
      local r = Cov.Build({ row(42, nil, { readable = false }) }, roster, deps())
      assert.is_true(r.ok)
      assert.equals(1, r.unreadableRows)
      assert.equals("unreadable", entryFor(r, BACKDRAFT).coverage)
      assert.equals("unknown", entryFor(r, BACKDRAFT).verdict)
      assert.equals(0, r.counts.blind)
      assert.equals(3, r.counts.unknown)
    end)

    it("...but a readable row still TRACKS its own id alongside the refused one", function()
      local r = Cov.Build({ row(43, CHAOS_BOLT), row(44, nil, { readable = false }) },
                          roster, deps())
      assert.equals("tracked", entryFor(r, CHAOS_BOLT).coverage)
      assert.equals("unknown", entryFor(r, BACKDRAFT).verdict)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("alert types — a lower bound, reported honestly", function()
    local roster = { [IMMOLATE_AURA] = { kind = "button", cadence = "gated", label = "Immolate" } }

    it("a REFUSED read carries the reason string, and no list", function()
      local r = Cov.Build({ row(51, IMMOLATE_AURA) }, roster,
        deps({ readAlerts = function() return nil, "GetValidAlertTypes raised" end }))
      local rw = entryFor(r, IMMOLATE_AURA).rows[1]
      assert.is_nil(rw.alerts)
      assert.equals("GetValidAlertTypes raised", rw.alertsError)
    end)

    it("an EMPTY list is a distinct real answer — 'this row raises nothing'", function()
      local r = Cov.Build({ row(52, IMMOLATE_AURA) }, roster,
        deps({ readAlerts = function() return {} end }))
      local rw = entryFor(r, IMMOLATE_AURA).rows[1]
      assert.same({}, rw.alerts)
      assert.is_nil(rw.alertsError)
    end)

    it("names come through the enum map", function()
      local r = Cov.Build({ row(53, IMMOLATE_AURA) }, roster,
        deps({ readAlerts = function() return { 2 } end,
               alertName = function(v) return v == 2 and "PandemicTime" or "?" end }))
      assert.same({ "PandemicTime" }, entryFor(r, IMMOLATE_AURA).rows[1].alerts)
    end)

    it("a SECRET member renders as SECRET rather than being dropped", function()
      -- Dropping it would shorten the list silently, and tostring on a secret taints the
      -- string it lands in.
      local s = H.secretValue()
      local r = Cov.Build({ row(54, IMMOLATE_AURA) }, roster,
        deps({ readAlerts = function() return { 2, s } end,
               alertName = function(v) return v == 2 and "PandemicTime" or "?" end }))
      assert.same({ "PandemicTime", "SECRET" }, entryFor(r, IMMOLATE_AURA).rows[1].alerts)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("three-valued knownness rides the entry", function()
    local roster = { [IMMOLATE_CAST] = { kind = "button", cadence = "gated", label = "Immolate" } }

    it("carries TRUE", function()
      local r = Cov.Build({ row(61, IMMOLATE_CAST) }, roster,
                          deps({ known = function() return true end }))
      assert.is_true(entryFor(r, IMMOLATE_CAST).known)
    end)

    it("carries FALSE — untalented in this build", function()
      local r = Cov.Build({ row(62, IMMOLATE_CAST) }, roster,
                          deps({ known = function() return false end }))
      assert.is_false(entryFor(r, IMMOLATE_CAST).known)
    end)

    it("carries NIL — the read refused, and that is not a `false`", function()
      local r = Cov.Build({ row(63, IMMOLATE_CAST) }, roster,
                          deps({ known = function() return nil end }))
      local e = entryFor(r, IMMOLATE_CAST)
      assert.is_not_nil(e)
      assert.is_nil(e.known)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("the report envelope", function()
    it("counts every verdict, and totals them", function()
      local r = Cov.Build({ row(71, CHAOS_BOLT) }, {
        [CHAOS_BOLT] = { kind = "button", cadence = "gated", label = "Chaos Bolt" },
        [RUINATION]  = { kind = "button", cadence = "reactive", expect = false, label = "Ru" },
        [417234]     = { kind = "aura", label = "Crashing Chaos" },
      }, deps())
      assert.equals(1, r.counts.ok)
      assert.equals(1, r.counts.expected)
      assert.equals(1, r.counts.blind)
      assert.equals(3, r.counts.total)
      assert.equals(1, r.scanned)
      assert.is_true(r.ok)
    end)

    it("ignores non-numeric roster keys (SpecBindAlias-style helpers)", function()
      local r = Cov.Build({ row(72, CHAOS_BOLT) },
                          { [CHAOS_BOLT] = { kind = "button", label = "CB" },
                            helper = { kind = "button" } },
                          deps())
      assert.equals(1, r.counts.total)
    end)
  end)
end)

--------------------------------------------------------------------------------
-- C.Get — the cache, and the combat half of the wholesale guard.
--
-- The guard's live path.  In combat the struct reads go secret and `enumerate` can come
-- back short, so a mid-pull rescan is exactly how the report would announce a blind
-- roster during the one moment the player is looking at the HUD.
--------------------------------------------------------------------------------
describe("Coverage.Get — cache + the combat refusal", function()
  local ns, Cov, scans
  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    H.load("Coverage.lua")
    Cov = ns.Coverage
    scans = 0
    local real = ns.State.CoverageRows
    ns.State.CoverageRows = function() scans = scans + 1; return real() end
    -- A roster, so "no-spec" is not what we end up measuring.
    ns.ActiveSpec = {}
    ns.Spec = { [116858] = { kind = "button", cadence = "gated", label = "Chaos Bolt" } }
  end)

  it("in combat with NO cache refuses honestly rather than scanning", function()
    H.setCombat(true)
    local r = Cov.Get()
    assert.is_false(r.ok)
    assert.equals("in-combat", r.reason)
    assert.is_true(r.stale)
    assert.equals(0, scans)
  end)

  it("computes once out of combat and serves the cache after", function()
    Cov.Get()
    Cov.Get()
    assert.equals(1, scans)
  end)

  it("in combat with a cache hands the CACHED report back, marked stale", function()
    local first = Cov.Get()
    assert.is_false(first.stale)
    H.setCombat(true)
    local r = Cov.Get()
    assert.is_true(r.stale)
    assert.equals(1, scans)          -- no rescan under the lockdown
  end)

  it("Invalidate forces the next call to rescan (the build moved)", function()
    Cov.Get()
    Cov.Invalidate()
    Cov.Get()
    assert.equals(2, scans)
  end)
end)
