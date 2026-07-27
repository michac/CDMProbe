-- coach_golden_spec.lua — the ⛔ DECISION-GATE ARBITER (W4 Phase 2).
--
-- Loads each frozen golden's state.json, runs the REAL Coach.Compute(state), and
-- DIFFS the result against guidance.json (the oracle, reasoned from the Demonology
-- rotation source, never from code — corpus/goldens/README.md).  29/29 green is the
-- proof that the redesigned single-top-press Coach reproduces the independent
-- corpus.  A RED here is the gate doing its job.
--
-- The goldens are the SIBLING wow-repo corpus, loaded through dkjson via
-- json_fixture (configurable path).  The diff compares the DECISION surface — the
-- resourceBar numbers, each drawn cue's draw/emphasis/transient/note, and the
-- sequence panel's show/title/cursor/steps — i.e. everything the contract defines,
-- including the pass-through note/label strings the Coach authors verbatim.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")
local FIX = dofile(dir .. "../json_fixture.lua")

-- The frozen corpus (corpus/goldens/coverage.md).  Hard-listed so a dropped or
-- renamed scenario is a loud failure, not a silent skip.
local SCENARIOS = {
  "burst-hold", "cast-ended-edge", "demonbolt-proc", "dreadstalkers",
  "grimoire-available", "hand-of-guldan", "hog-inflight", "hog-overcap-late",
  "implosion", "implosion-primed", "in-tyrant-window", "incoming-overcap", "infernal-bolt",
  "opener-midflight", "opener-ooc", "opener-ooc-casting", "overcap-soften",
  "overdue-late", "resource-states", "ruination", "secrecy-combat",
  "shadow-bolt-filler", "soon-anticipated", "soon-incoming", "transient-edges",
  "tyrant-hog-spam", "tyrant-pool", "tyrant-ready", "tyrant-stage-dread",
  "tyrant-stage-grimoire",
}

--------------------------------------------------------------------------------
-- A deep diff that reports the first-divergence PATHS (so a RED points at the
-- exact field).  Skips `_`-prefixed meta keys (the goldens' _scenario/_expected
-- documentation).  Absent == nil; arrays compared by length + element.
--------------------------------------------------------------------------------
local function keys(t)
  local set = {}
  for k in pairs(t) do
    if not (type(k) == "string" and k:sub(1, 1) == "_") then set[k] = true end
  end
  return set
end

local function fmt(v)
  if v == nil then return "nil" end
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

local function diff(expected, actual, path, out)
  path = path or ""
  out = out or {}
  if type(expected) ~= "table" or type(actual) ~= "table" then
    if expected ~= actual then
      out[#out + 1] = string.format("%s: expected %s, got %s", path, fmt(expected), fmt(actual))
    end
    return out
  end
  -- union of keys on both sides (so extra AND missing keys are reported)
  local seen = {}
  for k in pairs(keys(expected)) do seen[k] = true end
  for k in pairs(keys(actual)) do seen[k] = true end
  for k in pairs(seen) do
    local kp = path .. "." .. tostring(k)
    diff(expected[k], actual[k], kp, out)
  end
  return out
end

describe("Coach.Compute vs the golden corpus", function()
  local ns, Coach

  before_each(function()
    ns = H.fresh()
    H.load("Coach.lua")
    Coach = ns.Coach.New()
  end)

  for _, scenario in ipairs(SCENARIOS) do
    it("reproduces " .. scenario, function()
      local state = FIX.state(scenario)
      local expected = FIX.guidance(scenario)
      local got = Coach:Compute(state)

      local mismatches = {}
      diff(expected.resourceBar, got.resourceBar, "resourceBar", mismatches)
      diff(expected.cues, got.cues or {}, "cues", mismatches)
      diff(expected.sequence, got.sequence, "sequence", mismatches)

      if #mismatches > 0 then
        table.sort(mismatches)
        error("\n  " .. scenario .. " diverged from the golden:\n    "
          .. table.concat(mismatches, "\n    "))
      end
    end)
  end
end)
