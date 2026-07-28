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

-- Base spellIDs (SpecDemonology.SpecIDs) + the two Demonic Art override IDs.
local ID = {
  TYRANT = 265187, DREAD = 104316, HOG = 105174, DB = 264178, SB = 686,
  IMPLOSION = 196277, GRIM = 1276452, CORE = 264173, UTILITY = 104773,
  RUINATION = 434635, INFERNAL = 434506,
}
-- Distinct cooldownID frame handles (decoupled from spellIDs, as in a live pulse).
local CID = {
  TYRANT = 2742, DREAD = 671, HOG = 34991, DB = 1979, SB = 34990,
  IMPLOSION = 149122, GRIM = 888, CORE = 777, UTILITY = 555,
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

local function frame(cid, spellID, cd, extra)
  extra = extra or {}
  return {
    cooldownID = cid, spellID = spellID,
    overrideSpellID = extra.override or spellID,
    liveSpellID = extra.live or spellID,
    category = extra.category or "Essential",
    cd = cd or cdUnknown(),
    glow = { active = extra.glow or false, readable = true },
    buff = extra.buff,
  }
end

-- Build a pulse from high-level facts.  Abilities default to "not usable" (cdFar /
-- unknown), the safe reading, so a test only sets what its branch needs.
--   shards, incoming        projected = shards + incoming
--   core (bool)             a Demonic Core proc (Demonbolt glow + Core buff)
--   art  "ruination"|"infernal"  the armed Demonic Art (override on HoG / SB frame)
--   tyrant/dread/grimoire/implosion   a cd sub-table (ready/probably/soon/far/unknown)
--   dreadCommitted/grimoireCommitted  a fresh cast-start in history (staging walk)
--   utility                 a cd for a utility button (SOON-exclusion check)
local function build(f)
  f = f or {}
  local cds = {}
  cds[CID.TYRANT]    = frame(CID.TYRANT, ID.TYRANT, f.tyrant or cdFar())
  cds[CID.DREAD]     = frame(CID.DREAD, ID.DREAD, f.dread or cdFar())
  cds[CID.IMPLOSION] = frame(CID.IMPLOSION, ID.IMPLOSION, f.implosion or cdFar())
  cds[CID.GRIM]      = frame(CID.GRIM, ID.GRIM, f.grimoire or cdFar())

  local hogExtra, sbExtra = {}, {}
  if f.art == "ruination" then hogExtra = { override = ID.RUINATION, live = ID.RUINATION, glow = true } end
  if f.art == "infernal"  then sbExtra  = { override = ID.INFERNAL, live = ID.INFERNAL, glow = true } end
  cds[CID.HOG] = frame(CID.HOG, ID.HOG, cdUnknown(), hogExtra)
  cds[CID.SB]  = frame(CID.SB, ID.SB, cdUnknown(), sbExtra)
  cds[CID.DB]  = frame(CID.DB, ID.DB, cdUnknown(), { glow = f.core or false })
  cds[CID.CORE] = frame(CID.CORE, ID.CORE, cdUnknown(),
                        { category = "TrackedBuff", buff = { isActive = f.core or false } })
  if f.utility then cds[CID.UTILITY] = frame(CID.UTILITY, ID.UTILITY, f.utility) end

  local history = {}
  if f.dreadCommitted then history[#history + 1] = { phase = "start", base = ID.DREAD, at = NOW - 1 } end
  if f.grimoireCommitted then history[#history + 1] = { phase = "start", base = ID.GRIM, at = NOW - 1 } end

  return {
    at = NOW, combat = (f.combat ~= false), combatStartedAt = NOW - 60,
    mode = f.mode or "st",
    power = { SoulShards = { value = f.shards or 0, incoming = f.incoming or 0, max = 5, readable = true } },
    history = history,
    cooldowns = cds,
  }
end

--------------------------------------------------------------------------------
-- Guidance readers.  A cue is keyed by cooldownID; these pull the decision surface.
--------------------------------------------------------------------------------
local function pressOf(g)  -- the single ROTATION/LATE cue (cid, cue) — asserts exactly one
  local found
  for cid, cue in pairs(g.cues) do
    if cue.emphasis == "ROTATION" or cue.emphasis == "LATE" then
      assert.is_nil(found, "more than one top press emitted")
      found = { cid = cid, cue = cue }
    end
  end
  return found
end

local function fallbackOf(g)  -- the ROTATION_FALLBACK cue (cid, cue) or nil
  for cid, cue in pairs(g.cues) do
    if cue.emphasis == "ROTATION_FALLBACK" then return { cid = cid, cue = cue } end
  end
end

local function soonSet(g)  -- set of cooldownIDs carrying SOON
  local t = {}
  for cid, cue in pairs(g.cues) do if cue.emphasis == "SOON" then t[cid] = true end end
  return t
end

--------------------------------------------------------------------------------
describe("Coach rotation list (Tier-1, from apl-prototype/pseudocode.md)", function()
  local Coach
  before_each(function()
    local ns = H.fresh()
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
      assert.equals(CID.HOG, w.cid)  -- Ruination rides the HoG frame
      assert.equals("ROTATION", w.cue.emphasis)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L2 — the Tyrant-window setup block (SETUP-sense tct).
  ----------------------------------------------------------------------------
  describe("L2 Tyrant-window setup block", function()
    it("IB leads the block when shard-starved and the Infernal Art is armed", function()
      local w = winner({ tyrant = cdReady(), art = "infernal", shards = 1 })
      assert.equals(CID.SB, w.cid)  -- Infernal Bolt rides the Shadow-Bolt frame
      assert.equals("Infernal Bolt", w.cue.note)
    end)

    it("dumps a Core with Demonbolt below 4 shards inside the window", function()
      local w = winner({ tyrant = cdReady(), shards = 3, core = true })
      assert.equals(CID.DB, w.cid)
    end)

    it("pools with Shadow Bolt below the cap (note: pool to 5)", function()
      local w = winner({ tyrant = cdReady(), shards = 4 })
      assert.equals(CID.SB, w.cid)
      assert.equals("pool to 5 for the flood", w.cue.note)
    end)

    it("stages Dreadstalkers once capped, before Tyrant", function()
      local w = winner({ tyrant = cdReady(), shards = 5, dread = cdReady() })
      assert.equals(CID.DREAD, w.cid)
      assert.equals("stage — last summon before Tyrant", w.cue.note)
    end)

    it("does NOT re-stage a Dreadstalkers already committed (advances to Grimoire)", function()
      local w = winner({ tyrant = cdReady(), shards = 5,
                         dread = cdReady(), dreadCommitted = true, grimoire = cdReady() })
      assert.equals(CID.GRIM, w.cid)
    end)

    it("stages the Grimoire when Dreadstalkers is down", function()
      local w = winner({ tyrant = cdReady(), shards = 5, grimoire = cdReady() })
      assert.equals(CID.GRIM, w.cid)
    end)

    it("casts Tyrant once the board is staged", function()
      local w = winner({ tyrant = cdReady(), shards = 5 })
      assert.equals(CID.TYRANT, w.cid)
    end)

    it("window open but Tyrant ~3s out and nothing to pool -> Hand of Gul'dan", function()
      -- tct via a 2s napkin (anticipated, NOT probably-up): the Tyrant cast step is
      -- gated on tyrantProbablyUp, so the block falls through to the HoG floor.
      local w = winner({ tyrant = cdSoon(2), shards = 5 })
      assert.equals(CID.HOG, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L3/L4 — steady-state cooldowns OUTSIDE the window (beat the build).
  ----------------------------------------------------------------------------
  describe("L3/L4 steady-state cooldowns", function()
    it("Dreadstalkers off cd outside the window is the press", function()
      local w = winner({ dread = cdProbably(), shards = 3 })
      assert.equals(CID.DREAD, w.cid)
    end)

    it("Implosion off cd (below Dreadstalkers) is the press", function()
      local w = winner({ implosion = cdProbably(), shards = 3 })
      assert.equals(CID.IMPLOSION, w.cid)
    end)

    it("Dreadstalkers outranks Implosion when both are up", function()
      local w = winner({ dread = cdProbably(), implosion = cdProbably(), shards = 3 })
      assert.equals(CID.DREAD, w.cid)
    end)

    it("a no-shard-cost cooldown beats the build outside the window", function()
      -- shards 2 (< 3) with Implosion up: the build would fire, but Implosion (L4)
      -- outranks it per pseudocode.md.
      local w = winner({ implosion = cdProbably(), shards = 2 })
      assert.equals(CID.IMPLOSION, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L5 — the low-shard builder (Core -> Demonbolt, else Shadow Bolt).
  ----------------------------------------------------------------------------
  describe("L5 build", function()
    it("dumps a Core with Demonbolt below 3 shards", function()
      local w = winner({ shards = 2, core = true })
      assert.equals(CID.DB, w.cid)
    end)

    it("builds with Shadow Bolt below 3 shards with no Core", function()
      local w = winner({ shards = 2, core = false })
      assert.equals(CID.SB, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- L6 — Hand of Gul'dan spender / the Shadow Bolt floor.
  ----------------------------------------------------------------------------
  describe("L6 Hand of Gul'dan / floor", function()
    it("Hand of Gul'dan is the spender at/above cost with nothing higher", function()
      local w = winner({ shards = 3 })
      assert.equals(CID.HOG, w.cid)
    end)

    it("Shadow Bolt is the floor when HoG is unaffordable (higher-cost talent)", function()
      -- cfg.shardCost forces HoG's cost to 4; at 3 shards HoG can't fire -> SB floor.
      local ns = H.fresh(); H.load("Coach.lua")
      local coach = ns.Coach.New({ shardCost = function() return 4 end })
      local w = pressOf(coach:Compute(build({ shards = 3 })))
      assert.equals(CID.SB, w.cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- Shard-threshold boundaries — both sides of each gate.
  ----------------------------------------------------------------------------
  describe("shard boundaries", function()
    it("<2 (block IB): 1 shard fires IB, 2 shards does not", function()
      assert.equals(CID.SB, winner({ tyrant = cdReady(), art = "infernal", shards = 1 }).cid)  -- IB on SB frame
      -- at 2 shards the IB branch is skipped; with a Core the DB dump takes it.
      assert.equals(CID.DB, winner({ tyrant = cdReady(), art = "infernal", shards = 2, core = true }).cid)
    end)

    it("<3 (build): 2 shards builds, 3 shards spends HoG", function()
      assert.equals(CID.SB, winner({ shards = 2 }).cid)
      assert.equals(CID.HOG, winner({ shards = 3 }).cid)
    end)

    it("<4 (block DB): 3 shards+Core dumps, 4 shards pools SB", function()
      assert.equals(CID.DB, winner({ tyrant = cdReady(), shards = 3, core = true }).cid)
      assert.equals(CID.SB, winner({ tyrant = cdReady(), shards = 4, core = true }).cid)
    end)

    it("<5 (block SB pool): 4 shards pools, 5 shards stages/casts", function()
      assert.equals(CID.SB, winner({ tyrant = cdReady(), shards = 4 }).cid)
      assert.equals(CID.TYRANT, winner({ tyrant = cdReady(), shards = 5 }).cid)
    end)
  end)

  ----------------------------------------------------------------------------
  -- ROTATION_FALLBACK — the honest second place (winner's ability removed, list
  -- re-run from the top).  Always shown when a castable alternative exists.
  ----------------------------------------------------------------------------
  describe("fallback (ROTATION_FALLBACK)", function()
    it("Ruination winner -> Dreadstalkers surfaces as the fallback", function()
      local g = Coach:Compute(build({ art = "ruination", shards = 3, dread = cdProbably() }))
      assert.equals(CID.HOG, pressOf(g).cid)
      assert.equals(CID.DREAD, fallbackOf(g).cid)
    end)

    it("Demonbolt (L5) winner -> the Shadow Bolt build branch is the fallback", function()
      local g = Coach:Compute(build({ shards = 2, core = true }))
      assert.equals(CID.DB, pressOf(g).cid)
      assert.equals(CID.SB, fallbackOf(g).cid)  -- the skipped-then-reachable L5 SB
    end)

    it("Dreadstalkers winner -> Implosion is the fallback when both are up", function()
      local g = Coach:Compute(build({ dread = cdProbably(), implosion = cdProbably(), shards = 3 }))
      assert.equals(CID.DREAD, pressOf(g).cid)
      assert.equals(CID.IMPLOSION, fallbackOf(g).cid)
    end)

    it("Hand of Gul'dan winner -> the Shadow Bolt floor is shown as the fallback", function()
      -- Always-show-any-castable: even a filler<->filler pairing surfaces.
      local g = Coach:Compute(build({ shards = 3 }))
      assert.equals(CID.HOG, pressOf(g).cid)
      assert.equals(CID.SB, fallbackOf(g).cid)
    end)

    it("no fallback when removing the winner leaves nothing castable", function()
      -- Winner is the Shadow Bolt floor itself; removing it, no line fires.
      local g = Coach:Compute(build({ shards = 2, core = false }))
      assert.equals(CID.SB, pressOf(g).cid)
      assert.is_nil(fallbackOf(g))
    end)
  end)

  ----------------------------------------------------------------------------
  -- SOON — the dumb per-ability "coming off cooldown" decoration.
  ----------------------------------------------------------------------------
  describe("SOON decoration", function()
    it("a tracked cooldown anticipated within the lead lights SOON", function()
      local g = Coach:Compute(build({ shards = 3, implosion = cdSoon(2) }))
      assert.equals(CID.HOG, pressOf(g).cid)
      assert.is_true(soonSet(g)[CID.IMPLOSION])
    end)

    it("multiple cooldowns can show SOON at once", function()
      local g = Coach:Compute(build({ shards = 3, implosion = cdSoon(2), dread = cdSoon(2) }))
      local s = soonSet(g)
      assert.is_true(s[CID.IMPLOSION])
      assert.is_true(s[CID.DREAD])
    end)

    it("does NOT show SOON beyond the lead", function()
      local g = Coach:Compute(build({ shards = 3, implosion = cdSoon(5) }))
      assert.is_nil(soonSet(g)[CID.IMPLOSION])
    end)

    it("excludes utility buttons from SOON (out of the damage rotation)", function()
      local g = Coach:Compute(build({ shards = 3, utility = cdSoon(2) }))
      assert.is_nil(soonSet(g)[CID.UTILITY])
    end)

    it("Tyrant shows SOON while a staged summon is the press inside the window", function()
      -- tct via a 2s napkin; capped with Dreadstalkers ready -> stage Dreadstalkers,
      -- and Tyrant (anticipated within the lead) rides along as SOON.
      local g = Coach:Compute(build({ tyrant = cdSoon(2), shards = 5, dread = cdReady() }))
      assert.equals(CID.DREAD, pressOf(g).cid)
      assert.is_true(soonSet(g)[CID.TYRANT])
    end)
  end)

  ----------------------------------------------------------------------------
  -- Escalate — ROTATION -> LATE only from readable overdue-ness.
  ----------------------------------------------------------------------------
  describe("Escalate LATE", function()
    it("a Dreadstalkers left sitting past the lead outside the window goes LATE", function()
      local g = Coach:Compute(build({ dread = cdProbably(6), shards = 3 }))
      local w = pressOf(g)
      assert.equals(CID.DREAD, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("Hand of Gul'dan parked at a full bar goes LATE", function()
      local g = Coach:Compute(build({ shards = 5 }))
      local w = pressOf(g)
      assert.equals(CID.HOG, w.cid)
      assert.equals("LATE", w.cue.emphasis)
    end)

    it("a staged summon inside the window is NOT escalated to LATE", function()
      -- Ready-off-baseline Dreadstalkers (old changedAt) staged in the window stays
      -- ROTATION — the burst suppresses the overdue clock.
      local g = Coach:Compute(build({ tyrant = cdReady(), shards = 5, dread = cdProbably(6) }))
      local w = pressOf(g)
      assert.equals(CID.DREAD, w.cid)
      assert.equals("ROTATION", w.cue.emphasis)
    end)
  end)
end)
