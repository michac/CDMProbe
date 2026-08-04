-- coach_apl_spec.lua — the Tier-1 ROTATION-LOGIC gate (W4 Phase 8).
--
-- The single source of truth for the Coach's rotation decision is the flat priority
-- list in apl-prototype/pseudocode.md.  This spec is the INDEPENDENT ORACLE for it:
-- every expected winner / fallback / SOON below is read FROM pseudocode.md, never from
-- Coach.lua.  It replaces the golden-corpus rotation gate (coach_golden_spec, retired)
-- with minimal hand-built State pulses that exercise each BRANCH of the list plus the
-- shard-threshold boundaries (<2 / <3 / <4 / <5, both sides).
--
-- Caveat honored (build-plan): coverage proves a branch FIRED, not that it is right;
-- pseudocode.md stays the authority for each branch's expected press.  Promoted from
-- apl-prototype/apl.lua's 25 self-tests, retargeted from that prototype's plain-boolean
-- input contract onto the real State pulse the Coach consumes.
--
-- The list under test (apl-prototype/pseudocode.md; first castable line = the press):
--   L1  Ruination (Art, not Infernal)
--   L2  if Tyrant window (tct):  IB(<2 & Infernal) · DB(<4 & Core) · SB(<5 pool) ·
--                                stage Dreadstalkers · stage Grimoire · Tyrant
--   L3  Dreadstalkers  (off cd, NOT in the Tyrant window)
--   L4  Implosion      (off cd; secret imp gate)
--   L5  build (shards<3):  Core -> Demonbolt  else  Shadow Bolt
--   L6  Hand of Gul'dan (shards>=cost)  else  Shadow Bolt floor
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

--------------------------------------------------------------------------------
-- Minimal State-pulse builder.  Every field the Coach reads, nothing it doesn't.
--------------------------------------------------------------------------------
local NOW = 1000

-- Base spellIDs (SpecDemonology.SpecIDs) + the two Demonic Art override IDs.  Since the
-- W4 re-layer the Coach consumes the DOMAIN VIEW keyed by base spellID, so these ARE the
-- cue keys (winner/fallback/soon assert against ID.*, not a cooldownID).
local ID = {
  TYRANT = 265187, DREAD = 104316, HOG = 105174, DB = 264178, SB = 686,
  IMPLOSION = 196277, GRIM = 1276452, CORE = 264173, UTILITY = 104773,
  RUINATION = 434635, INFERNAL = 434506,
}
-- Distinct cooldownID display handles, carried on each ability's `display` (decoupled from
-- spellIDs, as in a live pulse — the Binder's anchor, reference only for these Coach tests).
local CID = {
  TYRANT = 2742, DREAD = 671, HOG = 34991, DB = 1979, SB = 34990,
  IMPLOSION = 149122, GRIM = 888, UTILITY = 555,
}

-- cd sub-tables per the W4 Phase-7 3-state contract (state + a trust `source`).
--   ready     — observed up (OOC baseline / Available edge): probably-up, a press.
--   probably  — on-cooldown, napkin estimate ELAPSED (remaining 0): ROTATION-eligible.
--   soon(n)   — on-cooldown, counting down n>0: anticipated (SOON when within the lead).
--   far       — on-cooldown, well out: neither pressable nor SOON.
--   unknown   — genuine no-data (filler/spender entries): not usable off this read.
-- `age` on ready/probably backdates changedAt to control overdue-ness (Escalate).
local function cdReady(age)    return { state = "ready", readable = true, source = "live", changedAt = NOW - (age or 2) } end
local function cdProbably(age) return { state = "on-cooldown", remaining = 0, readable = false, source = "napkin", changedAt = NOW - (age or 2) } end
local function cdSoon(n)       return { state = "on-cooldown", remaining = n, readable = false, source = "napkin", changedAt = NOW - 1 } end
local function cdFar()         return { state = "on-cooldown", remaining = 30, readable = false, source = "napkin", changedAt = NOW - 1 } end
local function cdUnknown()     return { state = "unknown", readable = false, source = "none" } end

-- An `abilities` entry keyed by BASE spellID — the domain-view row the Coach classifies:
-- every field Classify reads, plus `display` (the cooldownID/category the Binder anchors).
local function ability(base, cid, cd, extra)
  extra = extra or {}
  local category = extra.category or "Essential"
  return {
    cooldownID = cid, spellID = base,
    overrideSpellID = extra.override or base,
    liveSpellID = extra.live or base,
    category = category,
    cd = cd or cdUnknown(),
    glow = { active = extra.glow or false, readable = true },
    display = { cooldownID = cid, category = category },
  }
end

-- Build a pulse from high-level facts.  Abilities default to "not usable" (cdFar /
-- unknown), the safe reading, so a test only sets what its branch needs.
--   shards                  the live bar value
--   incoming                the IN-FLIGHT projection (projected = shards + incoming),
--                           synthesised as a real in-flight HoG — see the builder
--   core (bool)             a Demonic Core proc (Demonbolt glow + Core buff present)
--   art  "ruination"|"infernal"  the armed Demonic Art (override on HoG / SB frame)
--   tyrant/dread/grimoire/implosion   a cd sub-table (ready/probably/soon/far/unknown)
--   dreadCommitted/grimoireCommitted  a fresh cast-start in history (staging walk)
--   utility                 a cd for a utility button (SOON-exclusion check)
local function build(f)
  f = f or {}
  local abilities = {}
  abilities[ID.TYRANT]    = ability(ID.TYRANT, CID.TYRANT, f.tyrant or cdFar())
  abilities[ID.DREAD]     = ability(ID.DREAD, CID.DREAD, f.dread or cdFar())
  abilities[ID.IMPLOSION] = ability(ID.IMPLOSION, CID.IMPLOSION, f.implosion or cdFar())
  abilities[ID.GRIM]      = ability(ID.GRIM, CID.GRIM, f.grimoire or cdFar())

  local hogExtra, sbExtra = {}, {}
  if f.art == "ruination" then hogExtra = { override = ID.RUINATION, live = ID.RUINATION, glow = true } end
  if f.art == "infernal"  then sbExtra  = { override = ID.INFERNAL, live = ID.INFERNAL, glow = true } end
  abilities[ID.HOG] = ability(ID.HOG, CID.HOG, cdUnknown(), hogExtra)
  abilities[ID.SB]  = ability(ID.SB, CID.SB, cdUnknown(), sbExtra)
  abilities[ID.DB]  = ability(ID.DB, CID.DB, cdUnknown(), { glow = f.core or false })
  if f.utility then abilities[ID.UTILITY] = ability(ID.UTILITY, CID.UTILITY, f.utility) end

  -- Demonic Core is a TRACKED-ONLY ability (no pressable twin): it lives in `buffs`, keyed
  -- by its spellID, NOT in `abilities`.  Its proc is the window-active/presence signal.
  local buffs = {}
  if f.core then buffs[ID.CORE] = true end

  local history = {}
  if f.dreadCommitted then history[#history + 1] = { phase = "start", base = ID.DREAD, at = NOW - 1 } end
  if f.grimoireCommitted then history[#history + 1] = { phase = "start", base = ID.GRIM, at = NOW - 1 } end

  -- `f.incoming` is the IN-FLIGHT PROJECTION, and since roster-state-plan Phase 6 the pulse
  -- no longer carries it — the Coach derives it from cast history via ns.SpecPowerDelta.  So
  -- the fixture drives the REAL path: an in-flight Hand of Gul'dan (a 'start' with no
  -- terminal phase) plus the live shard cost SpecPowerDelta reads, chosen so its −cost IS
  -- f.incoming.  Placed outside CAST_FRESH (1.0) but inside the flight window (3.0), so it
  -- is in flight without also raising the cast_started EDGE — a different question.
  -- ⚠ HoG is Demo's only shard spender, so this necessarily also sets ctx.hogCost (the
  -- brain reads the same live cost).  Harmless while every hogCost case leaves f.incoming
  -- unset; a case that wants both must expect cost == -incoming.
  if f.incoming and f.incoming ~= 0 then
    H.fx.cost[ID.HOG] = -f.incoming
    history[#history + 1] = { phase = "start", spellID = ID.HOG, base = ID.HOG, at = NOW - 2 }
  end

  -- ⚠ UNITS (Phase 6.2).  The brain decides in FRAGMENTS (0-50); `f.shards` stays in WHOLE
  -- SHARDS and is multiplied here, so every existing `shards = N` call site keeps meaning
  -- what it always meant.  `f.frags` is the escape hatch for a fractional case, and
  -- `f.exactRefused` drops the exact read to exercise the value x modifier fallback.
  local frags = f.frags or ((f.shards or 0) * 10)
  local shardBar = { value = math.floor(frags / 10), max = 5, readable = true }
  if not f.exactRefused then
    shardBar.unmodified    = frags
    shardBar.unmodifiedMax = 50
    shardBar.modifier      = 10
  end
  return {
    at = NOW, combat = (f.combat ~= false), combatStartedAt = NOW - 60,
    mode = f.mode or "st",
    power = { SoulShards = shardBar },
    resources = { shards = shardBar },
    buffs = buffs,
    history = history,
    abilities = abilities,
  }
end

--------------------------------------------------------------------------------
-- Guidance readers.  A cue is keyed by BASE spellID (the re-layer); these pull the
-- decision surface.  `.cid` holds that base-spellID key (asserts against ID.*).
--------------------------------------------------------------------------------
local function pressOf(g)  -- the single ROTATION/LATE cue (cid, cue) — asserts exactly one
  local found
  for spellID, cue in pairs(g.cues) do
    if cue.emphasis == "ROTATION" or cue.emphasis == "LATE" then
      assert.is_nil(found, "more than one top press emitted")
      found = { cid = spellID, cue = cue }
    end
  end
  return found
end

local function fallbackOf(g)  -- the ROTATION_FALLBACK cue (base spellID, cue) or nil
  for spellID, cue in pairs(g.cues) do
    if cue.emphasis == "ROTATION_FALLBACK" then return { cid = spellID, cue = cue } end
  end
end

local function soonSet(g)  -- set of base spellIDs carrying SOON
  local t = {}
  for spellID, cue in pairs(g.cues) do if cue.emphasis == "SOON" then t[spellID] = true end end
  return t
end

--------------------------------------------------------------------------------
describe("Coach rotation list (Tier-1, from apl-prototype/pseudocode.md)", function()
  local ns, Coach
  before_each(function()
    ns = H.fresh()
    H.load("Coach.lua")
    Coach = ns.Coach.New()
  end)

  local function winner(facts) return pressOf(Coach:Compute(build(facts))) end

  ----------------------------------------------------------------------------
  -- L1 — Ruination: the free triple-imp Art, top press whenever armed.
  ----------------------------------------------------------------------------
  describe("L1 Ruination", function()
    it("wins outright whenever the Ruination Art is armed", function()
      local w = winner({ art = "ruination", shards = 3, dread = cdProbably() })
      assert.equals(ID.HOG, w.cid)  -- Ruination rides the HoG frame
      assert.equals("ROTATION", w.cue.emphasis)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L2 — the Tyrant-window setup block (SETUP-sense tct).
  ----------------------------------------------------------------------------
  describe("L2 Tyrant-window setup block", function()
    it("IB leads the block when shard-starved and the Infernal Art is armed", function()
      local w = winner({ tyrant = cdReady(), art = "infernal", shards = 1 })
      assert.equals(ID.SB, w.cid)  -- Infernal Bolt rides the Shadow-Bolt frame
      assert.equals("Infernal Bolt", w.cue.note)
    end)

    it("dumps a Core with Demonbolt below 4 shards inside the window", function()
      local w = winner({ tyrant = cdReady(), shards = 3, core = true })
      assert.equals(ID.DB, w.cid)
    end)

    it("pools with Shadow Bolt below the cap (note: pool to 5)", function()
      local w = winner({ tyrant = cdReady(), shards = 4 })
      assert.equals(ID.SB, w.cid)
      assert.equals("pool to 5 for the flood", w.cue.note)
    end)

    it("stages Dreadstalkers once capped, before Tyrant", function()
      local w = winner({ tyrant = cdReady(), shards = 5, dread = cdReady() })
      assert.equals(ID.DREAD, w.cid)
      assert.equals("stage — last summon before Tyrant", w.cue.note)
    end)

    it("does NOT re-stage a Dreadstalkers already committed (advances to Grimoire)", function()
      local w = winner({ tyrant = cdReady(), shards = 5,
                         dread = cdReady(), dreadCommitted = true, grimoire = cdReady() })
      assert.equals(ID.GRIM, w.cid)
    end)

    it("stages the Grimoire when Dreadstalkers is down", function()
      local w = winner({ tyrant = cdReady(), shards = 5, grimoire = cdReady() })
      assert.equals(ID.GRIM, w.cid)
    end)

    it("casts Tyrant once the board is staged", function()
      local w = winner({ tyrant = cdReady(), shards = 5 })
      assert.equals(ID.TYRANT, w.cid)
    end)

    it("window open but Tyrant ~3s out and nothing to pool -> Hand of Gul'dan", function()
      -- tct via a 2s napkin (anticipated, NOT probably-up): the Tyrant cast step is
      -- gated on tyrantProbablyUp, so the block falls through to the HoG floor.
      local w = winner({ tyrant = cdSoon(2), shards = 5 })
      assert.equals(ID.HOG, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L3/L4 — steady-state cooldowns OUTSIDE the window (beat the build).
  ----------------------------------------------------------------------------
  describe("L3/L4 steady-state cooldowns", function()
    it("Dreadstalkers off cd outside the window is the press", function()
      local w = winner({ dread = cdProbably(), shards = 3 })
      assert.equals(ID.DREAD, w.cid)
    end)

    it("Implosion off cd (below Dreadstalkers) is the press", function()
      local w = winner({ implosion = cdProbably(), shards = 3 })
      assert.equals(ID.IMPLOSION, w.cid)
    end)

    it("Dreadstalkers outranks Implosion when both are up", function()
      local w = winner({ dread = cdProbably(), implosion = cdProbably(), shards = 3 })
      assert.equals(ID.DREAD, w.cid)
    end)

    it("a no-shard-cost cooldown beats the build outside the window", function()
      -- shards 2 (< 3) with Implosion up: the build would fire, but Implosion (L4)
      -- outranks it per pseudocode.md.
      local w = winner({ implosion = cdProbably(), shards = 2 })
      assert.equals(ID.IMPLOSION, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L5 — the low-shard builder (Core -> Demonbolt, else Shadow Bolt).
  ----------------------------------------------------------------------------
  describe("L5 build", function()
    it("dumps a Core with Demonbolt below 3 shards", function()
      local w = winner({ shards = 2, core = true })
      assert.equals(ID.DB, w.cid)
    end)

    it("builds with Shadow Bolt below 3 shards with no Core", function()
      local w = winner({ shards = 2, core = false })
      assert.equals(ID.SB, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L6 — Hand of Gul'dan spender / the Shadow Bolt floor.
  ----------------------------------------------------------------------------
  describe("L6 Hand of Gul'dan / floor", function()
    it("Hand of Gul'dan is the spender at/above cost with nothing higher", function()
      local w = winner({ shards = 3 })
      assert.equals(ID.HOG, w.cid)
    end)

    it("Shadow Bolt is the floor when HoG is unaffordable (higher-cost talent)", function()
      -- cfg.shardCost forces HoG's cost to 4; at 3 shards HoG can't fire -> SB floor.
      -- ⚠ a LOCAL re-mint (this case wants its own cost injection), renamed so it does not
      -- shadow the suite-level `ns` the look-ahead cases read.
      local ns2 = H.fresh(); H.load("Coach.lua")
      local coach = ns2.Coach.New({ shardCost = function() return 4 end })
      local w = pressOf(coach:Compute(build({ shards = 3 })))
      assert.equals(ID.SB, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- Shard-threshold boundaries — both sides of each gate.
  ----------------------------------------------------------------------------
  describe("shard boundaries", function()
    it("<2 (block IB): 1 shard fires IB, 2 shards does not", function()
      assert.equals(ID.SB, winner({ tyrant = cdReady(), art = "infernal", shards = 1 }).cid)  -- IB on SB frame
      -- at 2 shards the IB branch is skipped; with a Core the DB dump takes it.
      assert.equals(ID.DB, winner({ tyrant = cdReady(), art = "infernal", shards = 2, core = true }).cid)
    end)

    it("<3 (build): 2 shards builds, 3 shards spends HoG", function()
      assert.equals(ID.SB, winner({ shards = 2 }).cid)
      assert.equals(ID.HOG, winner({ shards = 3 }).cid)
    end)

    it("<4 (block DB): 3 shards+Core dumps, 4 shards pools SB", function()
      assert.equals(ID.DB, winner({ tyrant = cdReady(), shards = 3, core = true }).cid)
      assert.equals(ID.SB, winner({ tyrant = cdReady(), shards = 4, core = true }).cid)
    end)

    it("<5 (block SB pool): 4 shards pools, 5 shards stages/casts", function()
      assert.equals(ID.SB, winner({ tyrant = cdReady(), shards = 4 }).cid)
      assert.equals(ID.TYRANT, winner({ tyrant = cdReady(), shards = 5 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- ROTATION_FALLBACK — THE LOOK-AHEAD since 2026-08-03 (was: the honest second place).
  ----------------------------------------------------------------------------
  -- ⚠⚠ THE TOKEN'S MEANING CHANGED, SO THESE CASES CHANGED WITH IT.  It used to be "re-run
  -- the list with the winner's ability EXCLUDED" — a substitute at the same instant ("if I
  -- am wrong, press this"). It is now "advance the board one GCD as if you pressed the
  -- winner, and re-rank" — a SEQUENCE hint. Two consequences show up all over this block:
  --   * an ability with NO cooldown is legitimately the next press too, so the look-ahead
  --     lands on the WINNER and there is no second cue at all — the winner's cue carries
  --     `next = true` and the Renderer draws a companion dot (the double-tap hint);
  --   * the EXCLUSION machinery (`RankWinner(ctx, excluded)`) no longer has a shell caller.
  --     It is still exercised below, directly, because it is a real cascade property.
  local function repeats(g, key)   -- did the look-ahead land back on the winner?
    return g.cues[key] ~= nil and g.cues[key].next == true
  end

  describe("look-ahead (ROTATION_FALLBACK)", function()
    -- ⚠ INVERTED 2026-08-03. This asserted Dreadstalkers as the runner-up. Hand of Gul'dan
    -- has NO cooldown (SpecDemonology declares no baseCD, correctly — it is a shard
    -- spender), so one GCD later it is still the top castable line and the honest answer to
    -- "what next" is HoG again.
    it("Ruination winner -> HoG has no cooldown, so the next press is HoG again", function()
      local g = Coach:Compute(build({ art = "ruination", shards = 3, dread = cdProbably() }))
      assert.equals(ID.HOG, pressOf(g).cid)
      assert.is_true(repeats(g, ID.HOG))
      assert.is_nil(fallbackOf(g))          -- no SECOND icon; the repeat rides the winner's
    end)

    it("Demonbolt (L5) winner -> also cooldown-less, so it repeats", function()
      local g = Coach:Compute(build({ shards = 2, core = true }))
      assert.equals(ID.DB, pressOf(g).cid)
      assert.is_true(repeats(g, ID.DB))
    end)

    it("Dreadstalkers winner -> Implosion is the fallback when both are up", function()
      local g = Coach:Compute(build({ dread = cdProbably(), implosion = cdProbably(), shards = 3 }))
      assert.equals(ID.DREAD, pressOf(g).cid)
      assert.equals(ID.IMPLOSION, fallbackOf(g).cid)
    end)

    it("Hand of Gul'dan winner -> repeats, because it has no cooldown to start", function()
      local g = Coach:Compute(build({ shards = 3 }))
      assert.equals(ID.HOG, pressOf(g).cid)
      assert.is_true(repeats(g, ID.HOG))
    end)

    it("no next cue when the winner is the floor and nothing else is castable", function()
      -- Shadow Bolt has no cooldown either, so the honest answer is "press it again".
      local g = Coach:Compute(build({ shards = 2, core = false }))
      assert.equals(ID.SB, pressOf(g).cid)
      assert.is_nil(fallbackOf(g))
      assert.is_true(repeats(g, ID.SB))
    end)

    -- ⚠⚠ THE PROPERTY THE WHOLE FEATURE RESTS ON, and the one a spec-table omission would
    -- silently break: an ability WITH a declared cooldown must NOT repeat, because pressing
    -- it starts that cooldown.  `spec.Spec[id].baseCD` / `.chargeCD` is the only source
    -- ns.Coach.Advance has — a rotational button with a real cooldown and no declared number
    -- would stay "ready" in the hypothetical and be re-offered forever.
    it("an ability WITH a cooldown does not repeat — it goes on cooldown", function()
      local g = Coach:Compute(build({ dread = cdProbably(), implosion = cdProbably(), shards = 3 }))
      assert.equals(ID.DREAD, pressOf(g).cid)
      assert.is_falsy(repeats(g, ID.DREAD))
      assert.equals(ID.IMPLOSION, fallbackOf(g).cid)   -- a DIFFERENT icon carries the next
    end)

    -- ⚠ THE EXCLUSION MACHINERY SURVIVES WITHOUT A SHELL CALLER, and is tested directly
    -- rather than through the guidance.  `RankWinner(ctx, excluded)` is still part of the
    -- brain contract; Emit stopped calling it when the runner-up became a look-ahead.
    it("RankWinner still honours an explicit exclusion", function()
      local state = build({ dread = cdProbably(), implosion = cdProbably(), shards = 3 })
      local ctx = ns.ActiveSpec:Context(state, Coach)
      assert.equals(ID.DREAD, (ns.ActiveSpec:RankWinner(ctx)))
      assert.equals(ID.IMPLOSION, (ns.ActiveSpec:RankWinner(ctx, ID.DREAD)))
    end)
  end)

  ----------------------------------------------------------------------------
  -- SOON — the dumb per-ability "coming off cooldown" decoration.
  ----------------------------------------------------------------------------
  describe("SOON decoration", function()
    it("a tracked cooldown anticipated within the lead lights SOON", function()
      local g = Coach:Compute(build({ shards = 3, implosion = cdSoon(2) }))
      assert.equals(ID.HOG, pressOf(g).cid)
      assert.is_true(soonSet(g)[ID.IMPLOSION])
    end)

    it("multiple cooldowns can show SOON at once", function()
      local g = Coach:Compute(build({ shards = 3, implosion = cdSoon(2), dread = cdSoon(2) }))
      local s = soonSet(g)
      assert.is_true(s[ID.IMPLOSION])
      assert.is_true(s[ID.DREAD])
    end)

    it("does NOT show SOON beyond the lead", function()
      local g = Coach:Compute(build({ shards = 3, implosion = cdSoon(5) }))
      assert.is_nil(soonSet(g)[ID.IMPLOSION])
    end)

    it("excludes utility buttons from SOON (out of the damage rotation)", function()
      local g = Coach:Compute(build({ shards = 3, utility = cdSoon(2) }))
      assert.is_nil(soonSet(g)[ID.UTILITY])
    end)

    it("Tyrant shows SOON while a staged summon is the press inside the window", function()
      -- tct via a 2s napkin; capped with Dreadstalkers ready -> stage Dreadstalkers,
      -- and Tyrant (anticipated within the lead) rides along as SOON.
      local g = Coach:Compute(build({ tyrant = cdSoon(2), shards = 5, dread = cdReady() }))
      assert.equals(ID.DREAD, pressOf(g).cid)
      assert.is_true(soonSet(g)[ID.TYRANT])
    end)
  end)

  ----------------------------------------------------------------------------
  -- Escalate — ROTATION -> LATE only from readable overdue-ness.
  ----------------------------------------------------------------------------
  describe("Escalate LATE", function()
    it("a Dreadstalkers left sitting past the lead outside the window goes LATE", function()
      local g = Coach:Compute(build({ dread = cdProbably(6), shards = 3 }))
      local w = pressOf(g)
      assert.equals(ID.DREAD, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("Hand of Gul'dan parked at a full bar goes LATE", function()
      local g = Coach:Compute(build({ shards = 5 }))
      local w = pressOf(g)
      assert.equals(ID.HOG, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("a staged summon inside the window is NOT escalated to LATE", function()
      -- Ready-off-baseline Dreadstalkers (old changedAt) staged in the window stays
      -- ROTATION — the burst suppresses the overdue clock.
      local g = Coach:Compute(build({ tyrant = cdReady(), shards = 5, dread = cdProbably(6) }))
      local w = pressOf(g)
      assert.equals(ID.DREAD, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)
  end)
end)
