-- Coverage.lua — THE ROSTER COVERAGE PROBE (roster-state-plan Phase 4).
--
-- THE QUESTION.  Each spec hand-writes a ROSTER: the table of spellIDs it cares about,
-- buttons and auras alike (`SpecDestruction.lua`, `SpecDemonology.lua`).  Nothing checked
-- that Blizzard's Cooldown Manager actually TRACKS each of those ids.  When it does not,
-- the HUD is silently blind to that spell — no error, no log line, it just quietly never
-- works.  This asks the question OUT OF COMBAT, where it is cheap and answerable, and
-- prints the answer.
--
-- IT IS ALSO A REQUIRED REPLACEMENT, not a nice-to-have.  Phase 5 removes `pulse.dropped`
-- — the per-pulse "the filter removed a real button, and why" that made the Soul Fire bug
-- findable — and §8 says its visibility must be replaced by three-valued knownness riding
-- the row AND by this report, "or a loud failure is traded for a quiet one".
--
-- DIAGNOSTIC ONLY, DELIBERATELY.  §5 lists a second payoff — State distinguishing "no ready
-- edge yet" from "this row is not reported eligible for one".  We did NOT build that.
-- `GetValidAlertTypes` was MEASURED under-reporting (cid 164597 listed `PandemicTime` only,
-- then raised an `OnAuraApplied` in the same session), so it is a LOWER BOUND.  Branching
-- readiness on a lower bound produces confident false negatives in the one place a wrong
-- answer reaches the screen.  Revisit only if a `TriggerAlertEvent` hook ever gives a
-- complete observation.  Hence every alert list here renders as
-- "reported eligible: …", never "cannot fire".
--
-- THE VOCABULARY (the load-bearing part).  Per declared roster id, a COVERAGE fact and a
-- VERDICT:
--
--   coverage  tracked      >=1 CDM row carries this id (as base, overrideSpellID,
--                          overrideTooltipSpellID, or a linkedSpellIDs member)
--             untracked    no enumerated row carries it
--             unreadable   a row was found but its fields refused
--
--   verdict   ok           tracked                                         quiet
--             virtual      untracked, but the REAL VirtualCandidates fences say we draw
--                          our own icon (Incinerate, Shadow Bolt)          quiet
--             expected     untracked and `expect == false` — the override-only ids and
--                          cast aliases, declared BECAUSE they only ever appear as an
--                          override                                        quiet
--             unlearned    untracked and the client says the character does NOT HAVE it.
--                          Not a finding: there is nothing to be blind TO   quiet
--             blind        untracked, `expect ~= false`, not virtual-covered, and the
--                          character DEMONSTRABLY HAS IT                    LOUD
--             unknown      fields refused, or untracked with knownness unreadable  mild
--
-- ⚠ `unlearned` AND THE KNOWNNESS FENCE ON `blind` ARE FIELD-DRIVEN (2026-08-01, the first
-- flight).  As first shipped, `blind` did not consult knownness at all — and EVERY blind
-- row the flight produced was a false alarm of exactly that shape: Axe Toss 119914 on both
-- specs (no Felguard, so the character has no such ability) and Wither 445468 on Diabolist
-- (untalented on that hero tree).  Three loud rows, zero real findings, which is precisely
-- how a report earns being ignored.  `blind` now means "you HAVE this ability and we cannot
-- see it" — the only version of the claim that is worth shouting.  §5.1 pre-registered this
-- as the nuance to watch; the field settled it on the first pass.
--
-- ⚠ THE WHOLESALE GUARD IS THE ONE WAY THIS GOES WRONG.  If the scan returns nothing
-- (viewers not up yet, CDM unavailable, a login race) the report is `ok = false` with a
-- reason and reports NO entry as untracked.  An empty database means "the read refused",
-- not "your whole roster is blind".  This is the deliberate twin of `domainView`'s
-- existing `next(items) ~= nil` refusal and of §6.1's knownness guard: without it the
-- probe cries wolf on every login and gets ignored, which is worse than not existing.
-- Same for combat — `Get()` returns the cached report marked stale rather than rescanning.
--
-- ⚠ REUSE, NOT RE-DERIVATION.  Virtual eligibility comes from calling the REAL fence list,
-- `St.VirtualCandidates(specTable, {}, nil, known, baseCooldown)`, with an EMPTY abilities
-- map — i.e. "if nothing were on screen, which of these would we synthesise?", which is
-- exactly the question the untracked branch is asking.  Do NOT hand-copy the fences here;
-- that is how the two drift and the report starts calling a drawn ability blind.
local ADDON, ns = ...

ns.Coverage = {}
local C = ns.Coverage

-- Loudest first, so the readout leads with what needs acting on and a test can assert the
-- order without depending on `pairs`.
local VERDICT_RANK = { blind = 1, unknown = 2, virtual = 3, expected = 4,
                       unlearned = 5, ok = 6 }

local function zeroCounts()
  return { ok = 0, virtual = 0, expected = 0, blind = 0, unknown = 0, unlearned = 0,
           total = 0 }
end

local function emptyReport(reason)
  return { ok = false, reason = reason, scanned = 0, entries = {},
           counts = zeroCounts(), unreadableRows = 0 }
end

--------------------------------------------------------------------------------
-- The join index — every id ANY enumerated row carries, and how it carries it.
--------------------------------------------------------------------------------
-- Four separate joins, because they are four separate facts about a row and a roster id
-- can arrive on any of them: Immolate is declared as the DoT aura and the CDM tracks it as
-- the base; Ruination is declared as itself and the CDM only ever surfaces it as Chaos
-- Bolt's override.  One id can hit several rows (Diabolic Ritual is tracked four times),
-- so the value is a LIST — collapsing it would hide the multiplicity the readout shows.
--
-- UNREADABLE ROWS ARE COUNTED, NOT INDEXED.  A row that refused its fields could be
-- carrying any spellID at all, so its existence makes every UNTRACKED answer unprovable —
-- see `unreadableRows` at the classification below.
local VIA = { "spellID", "overrideSpellID", "overrideTooltipSpellID" }

local function buildIndex(rows)
  local index, unreadable = {}, 0
  for _, row in ipairs(rows) do
    if row.readable == false then
      unreadable = unreadable + 1
    else
      local function add(id, via)
        if type(id) ~= "number" then return end
        local list = index[id]
        if not list then list = {}; index[id] = list end
        list[#list + 1] = { cooldownID = row.cooldownID, category = row.category, via = via }
      end
      for _, field in ipairs(VIA) do add(row[field], field) end
      for _, id in ipairs(row.linkedSpellIDs or {}) do add(id, "linkedSpellIDs") end
    end
  end
  return index, unreadable
end

--------------------------------------------------------------------------------
-- The alert-type read, per matched row.
--------------------------------------------------------------------------------
-- Three OUTCOMES and they are all different answers, so none may collapse into another:
--   * a list of names  — the lower bound the API reported
--   * an EMPTY list    — a real answer ("this row raises nothing"), NOT a refusal
--   * `err`            — the read refused, and the reason is carried verbatim
-- A member that reads SECRET renders as "SECRET" rather than being dropped: dropping it
-- would shorten the list silently, and `tostring` on a secret taints the string.
local function readRowAlerts(cooldownID, readAlerts, alertName)
  local types, err = readAlerts(cooldownID)
  if not types then return nil, err or "unreadable" end
  local names = {}
  for _, t in ipairs(types) do
    names[#names + 1] = ns.IsSecret(t) and "SECRET" or alertName(t)
  end
  return names, nil
end

--------------------------------------------------------------------------------
-- C.Build(rows, specTable, deps) -> report        PURE (given its injected deps)
--------------------------------------------------------------------------------
-- `rows`      — St.CoverageRows()'s output (or a hand-built array, in the tests)
-- `specTable` — the active spec's roster (`ns.Spec`), spellID -> signal bucket
-- `deps`      — { readAlerts, known, baseCooldown, alertName }, all injected so busted
--               drives the whole join with no client.
--
-- Returns { ok, reason, scanned, unreadableRows, entries[], counts }.  `entries` is sorted
-- LOUDEST FIRST then by spellID, so both the readout and the tests are order-stable.
function C.Build(rows, specTable, deps)
  deps = deps or {}
  local readAlerts   = deps.readAlerts   or ns.ReadValidAlertTypes
  local known        = deps.known        or ns.State.SpellKnown
  local alertName    = deps.alertName    or ns.AlertEventName

  -- No roster ⇒ nothing to ask about.  Checked FIRST because it is the more specific
  -- answer: a passive spec on a login race would otherwise report "cdm-empty", which
  -- sends the reader hunting a CDM problem that is not there.
  if type(specTable) ~= "table" or next(specTable) == nil then
    return emptyReport("no-spec")
  end
  -- THE WHOLESALE GUARD.  See the header: an empty scan is a refused read, never a blind
  -- roster.  Nothing below runs, so no entry can read `untracked`.
  if type(rows) ~= "table" or #rows == 0 then
    return emptyReport("cdm-empty")
  end

  local index, unreadableRows = buildIndex(rows)
  -- The REAL fences, asked with an empty `abilities` map: "if nothing were on screen,
  -- which of these would we synthesise?"
  --
  -- ⚠ PHASE 5 WIDENED THIS ANSWER, and it narrows `blind` as a consequence — deliberately,
  -- not by accident.  The fence list used to require a ZERO BASE COOLDOWN and a `true`
  -- knownness read, so most untracked buttons fell through to `blind`.  Under the roster
  -- anchor every declared, non-utility, non-alias button gets a row of our own whatever its
  -- cooldown, so the HUD is no longer blind to a BUTTON at all.  What `blind` still means —
  -- and it is the only version worth shouting — is an `kind = "aura"` entry the CDM tracks
  -- nowhere: State has no synthesis path for auras, so those really are invisible
  -- (roster-state-plan Phase 5, "Roster gaps the anchor exposes" #2).
  local virtual = {}
  for _, id in ipairs(ns.State.VirtualCandidates(specTable, {}, false)) do
    virtual[id] = true
  end

  local entries, counts = {}, zeroCounts()
  -- ⚠ ONE ROSTER WALK, and it is `ns.State.RosterEntries` (Phase 5 §C1) — the same call the
  -- domain view anchors on.  This loop used to open the predicate inline, which meant two
  -- copies of "what counts as a roster entry" and no way to tell them apart when they
  -- drifted.  Same doctrine as the virtual fences above: reuse, never re-derivation.
  for _, e in ipairs(ns.State.RosterEntries(specTable)) do
    local spellID, info = e.spellID, e.info
    do
      local entry = {
        spellID = spellID,
        kind    = info.kind,
        cadence = info.cadence,
        label   = info.label,
        expect  = info.expect,
        known   = known(spellID),     -- three-valued: true | false | nil, carried as-is
        rows    = {},
      }
      local matches = index[spellID]
      if matches then
        entry.coverage, entry.verdict = "tracked", "ok"
        for _, m in ipairs(matches) do
          local names, err = readRowAlerts(m.cooldownID, readAlerts, alertName)
          entry.rows[#entry.rows + 1] = {
            cooldownID = m.cooldownID, category = m.category, via = m.via,
            alerts = names, alertsError = err,
          }
        end
      elseif unreadableRows > 0 then
        -- A refused row could be carrying THIS id.  "Untracked" is a negative, and a
        -- negative over an incomplete scan is a guess — so it degrades to `unknown` rather
        -- than joining the alarm.
        entry.coverage, entry.verdict = "unreadable", "unknown"
      else
        entry.coverage = "untracked"
        -- ORDER MATTERS, and each rung is a different KIND of "not a problem":
        --   virtual    we draw it ourselves (the fence list said so)
        --   expected   the author declared it BECAUSE it is override-only
        --   unlearned  the character does not have the ability at all
        --   unknown    we could not find out whether they have it — so we cannot claim
        --              blindness either; an unprovable alarm is not an alarm
        -- Only what survives all four is loud.
        if virtual[spellID] then entry.verdict = "virtual"
        elseif info.expect == false then entry.verdict = "expected"
        elseif entry.known == false then entry.verdict = "unlearned"
        elseif entry.known == nil then entry.verdict = "unknown"
        else entry.verdict = "blind" end
      end
      counts[entry.verdict] = counts[entry.verdict] + 1
      counts.total = counts.total + 1
      entries[#entries + 1] = entry
    end
  end

  table.sort(entries, function(a, b)
    local ra, rb = VERDICT_RANK[a.verdict] or 9, VERDICT_RANK[b.verdict] or 9
    if ra ~= rb then return ra < rb end
    return a.spellID < b.spellID
  end)

  return { ok = true, reason = nil, scanned = #rows, unreadableRows = unreadableRows,
           entries = entries, counts = counts }
end

--------------------------------------------------------------------------------
-- C.Get() — compute once, cache, hand the cached report back.
--------------------------------------------------------------------------------
-- The roster is static and the CDM's tracked set moves only with the build, so this is a
-- once-per-build answer, not a per-tick one.
--
-- ⚠ IN COMBAT WE DO NOT RESCAN.  The struct reads go secret and `enumerate` can come back
-- short, which would turn a mid-pull `/cdmp hud status` into "your roster is blind" — the
-- exact false alarm the wholesale guard exists to prevent.  A cached report is returned
-- marked `stale`; with no cache the answer is an honest refusal.
local cache

function C.Get()
  if InCombatLockdown() then
    if cache then cache.stale = true; return cache end
    local r = emptyReport("in-combat")
    r.stale = true
    return r
  end
  if cache then return cache end
  -- `ns.Spec` is the ACTIVE spec's roster, rebound by the resolver; `ns.ActiveSpec` nil is
  -- the passive contract (no profile for this spec), which Build reports as "no-spec".
  -- Read live at call time, so load order against the spec files is a non-issue.
  local specTable = ns.ActiveSpec and ns.Spec or nil
  cache = C.Build(ns.State.CoverageRows(), specTable, {})
  cache.stale = false
  return cache
end

function C.Invalidate() cache = nil end

--------------------------------------------------------------------------------
-- Invalidation — our own small event frame (SpecRegistry's precedent).
--------------------------------------------------------------------------------
-- Three rarely-firing events, and owning the frame here keeps the State -> Coverage
-- dependency ONE-WAY: State knows nothing about coverage, which is what lets
-- `St.CoverageRows` stay a plain reader.
--   SPELLS_CHANGED               the spellbook moved, so knownness moved
--   TRAIT_CONFIG_UPDATED         a hero/talent swap changes the tracked set without
--                                changing the spec
--   PLAYER_SPECIALIZATION_CHANGED   a different roster entirely
local ev = CreateFrame("Frame")
ev:RegisterEvent("SPELLS_CHANGED")
ev:RegisterEvent("TRAIT_CONFIG_UPDATED")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:SetScript("OnEvent", function() C.Invalidate() end)
