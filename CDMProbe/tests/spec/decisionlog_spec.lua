-- decisionlog_spec.lua — the decision-log RENDER gate, plus Record's EDGE MARKERS.
--
-- ns.DecisionLog.Render (PURE) is the bulk of it: hand-built pulse/guidance/drawList in,
-- the `S{…} G{…} B{…}` string out.
--
-- ⚠ RECORD IS NOW PARTLY TESTED TOO, and the reason it was not is worth stating because it
-- expired rather than being wrong.  The old note here said Record is "session push, date(),
-- ns.version, the ring" — pure bookkeeping deliberately kept OUT of Render so this spec
-- needed no `date`/`ns.db` fakes.  That held until Record grew a **correctness rule**: the
-- combat-edge marker must be stamped ABOVE the change-only dedup, because a pull that starts
-- while the decision happens not to move would otherwise be swallowed.  A rule whose whole
-- content is "this code is above that code" is exactly the kind a refactor silently breaks,
-- so it gets a test — and the harness gaps turned out to be one `date` fake and a table.
--
-- What it asserts: a normal winner line, the no-winner (`w:-`) case, the dropped-cue
-- (`×`) case, shard/proc/cast/readiness encodings, and DETERMINISM (two pairs()-orders
-- of the same decision render the identical string — the guard the change-only dedup
-- stands on).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

-- Base spellIDs (SpecDemonology) + the two Demonic Art override ids.
local ID = {
  TYRANT = 265187, DREAD = 104316, IMPLOSION = 196277, GRIM = 1276452,
  HOG = 105174, DB = 264178, SB = 686, CORE = 264173,
  RUINATION = 434635, INFERNAL = 434506,
}
-- cooldownID handles, decoupled from spellIDs as in a live pulse.
local CID = {
  TYRANT = 2742, DREAD = 671, IMPLOSION = 149122, GRIM = 888,
  HOG = 34991, DB = 1979, SB = 34990, CORE = 777,
}

local function cdReady()   return { state = "ready", remaining = 0 } end
local function cdProbably() return { state = "on-cooldown", remaining = 0 } end
local function cdSoon(n)   return { state = "on-cooldown", remaining = n } end
local function cdUnknown() return { state = "unknown" } end

-- An `abilities` domain-view row keyed by base spellID, carrying a `display` cooldownID
-- (the Binder's anchor — what B{} checks the DrawList against).
local function ability(base, cid, cd, extra)
  extra = extra or {}
  return {
    cooldownID = cid, spellID = base,
    liveSpellID = extra.live or base,
    cd = cd or cdUnknown(),
    glow = { active = extra.glow or false, readable = true },
    display = { cooldownID = cid, category = extra.category or "Essential" },
  }
end

-- A pulse with the four summons + HoG/DB/SB fillers, defaults "not usable".  The DOMAIN
-- VIEW: `abilities` keyed by base spellID (folded), `buffs` by spellID, `power` keyed by
-- Enum.PowerType name (the SoulShards bar the log's PW field reads).
local function build(f)
  f = f or {}
  local abilities = {}
  abilities[ID.TYRANT]    = ability(ID.TYRANT, CID.TYRANT, f.tyrant or cdSoon(30))
  abilities[ID.DREAD]     = ability(ID.DREAD, CID.DREAD, f.dread or cdSoon(30))
  abilities[ID.IMPLOSION] = ability(ID.IMPLOSION, CID.IMPLOSION, f.implosion or cdSoon(30))
  abilities[ID.GRIM]      = ability(ID.GRIM, CID.GRIM, f.grimoire or cdSoon(30))

  local hogExtra, sbExtra = {}, {}
  if f.art == "ruination" then hogExtra = { live = ID.RUINATION, glow = true } end
  if f.art == "infernal"  then sbExtra  = { live = ID.INFERNAL, glow = true } end
  abilities[ID.HOG] = ability(ID.HOG, CID.HOG, cdUnknown(), hogExtra)
  abilities[ID.SB]  = ability(ID.SB, CID.SB, cdUnknown(), sbExtra)
  abilities[ID.DB]  = ability(ID.DB, CID.DB, cdUnknown(), { glow = f.core or false })

  -- Demonic Core is tracked-only (no pressable twin): presence rides `buffs`, keyed by
  -- spellID, not `abilities`.
  local buffs = {}
  if f.core then buffs[ID.CORE] = true end

  return {
    -- `f.combat` defaults TRUE, so every existing call site is unchanged; the Record block
    -- at the bottom of this file drives it both ways for the combat-edge marker.
    at = 1000, combat = (f.combat ~= false),
    -- Raw power, as State emits it.  ⚠ The log's PW field does NOT read this any more —
    -- since roster-state-plan Phase 6 it reads guidance.resourceBars, the one place that
    -- carries BOTH halves of the string (see `bars` on the guidance helper below).
    power = { SoulShards = { value = f.shards or 0, max = 5 } },
    buffs = buffs,
    history = f.history or {},
    abilities = abilities,
    -- The DoT's two observation channels, base-spellID-keyed exactly as State emits them.
    dotEdges   = f.dotEdges,
    auraFrames = f.auraFrames,
  }
end

-- A guidance whose cues carry an emphasis per BASE spellID.  `cues = { [spellID] = "ROTATION", … }`.
-- `bars` is the resourceBars channel the PW field reads (Phase 6); omit it for the passive
-- shape — an empty array is what EmptyGuidance emits.
local function guidance(cues, notes, bars)
  notes = notes or {}
  local out = {}
  for spellID, emph in pairs(cues) do
    out[spellID] = { draw = true, emphasis = emph, note = notes[spellID] }
  end
  return { cues = out, resourceBars = bars or {} }
end

-- The one shard meter Demo/Destro emit, in guidance terms.
local function bar(value, incoming)
  return { { value = value, incoming = incoming or 0, max = 5,
             display = "discrete", powerType = "SOUL_SHARDS" } }
end

-- The same bar carrying the EXACT rail too (Phase 6.2): integers in the game's internal
-- units (Soul Shards: 0-50 fragments) plus the `modifier` that relates them to the pips.
local function exactBar(frags, incomingFrags)
  local b = bar(math.floor(frags / 10), math.floor((incomingFrags or 0) / 10))
  b[1].valueExact    = frags
  b[1].incomingExact = incomingFrags or 0
  b[1].maxExact      = 50
  b[1].modifier      = 10
  return b
end

-- A drawList that anchors the given cids (i.e. the Binder DREW them).
local function drawList(anchoredCids)
  local cues = {}
  for _, cid in ipairs(anchoredCids or {}) do
    cues[#cues + 1] = { anchorTo = cid }
  end
  return { cues = cues }
end

describe("DecisionLog.Render", function()
  local ns
  before_each(function()
    ns = H.fresh()
    H.load("DecisionLog.lua")
  end)

  it("renders a normal winner line: w:SB + note, B{SB:ROT}", function()
    local pulse = build{ shards = 2 }
    local g = guidance({ [ID.SB] = "ROTATION" }, { [ID.SB] = "pool to 5" })   -- cue keyed by spellID
    local s = ns.DecisionLog.Render(pulse, g, drawList{ CID.SB })                 -- Binder anchors the cid
    assert.truthy(s:find("G{w:SB:pool_to_5", 1, true), s)
    assert.truthy(s:find("B{SB:ROT}", 1, true), s)
    assert.is_nil(s:find("×", 1, true))          -- SB was drawn, not dropped
  end)

  it("no winner ⇒ w:-", function()
    local pulse = build{}
    local s = ns.DecisionLog.Render(pulse, { cues = {} }, { cues = {} })
    assert.truthy(s:find("G{w:-}", 1, true), s)
  end)

  it("dropped cue (in guidance, absent from drawList) ⇒ ×", function()
    local pulse = build{ shards = 1 }
    local g = guidance({ [ID.SB] = "ROTATION" })
    local s = ns.DecisionLog.Render(pulse, g, drawList{})   -- Binder anchored nothing
    assert.truthy(s:find("B{SB:ROT×}", 1, true), s)
  end)

  it("LATE winner renders w! ; fallback and sorted soon list", function()
    local pulse = build{ shards = 5 }
    local g = guidance({
      [ID.TYRANT] = "LATE",
      [ID.HOG]    = "ROTATION_FALLBACK",
      [ID.DREAD]  = "SOON",
      [ID.IMPLOSION] = "SOON",
    })
    local s = ns.DecisionLog.Render(pulse, g, drawList{ CID.TYRANT, CID.HOG, CID.DREAD, CID.IMPLOSION })
    assert.truthy(s:find("w!T", 1, true), s)
    assert.truthy(s:find("fb:HoG", 1, true), s)
    assert.truthy(s:find("soon:D,I", 1, true), s)   -- sorted: D before I
  end)

  it("encodes shards value/incoming, procs, readiness tokens", function()
    local pulse = build{
      shards = 3, core = true, art = "infernal",
      tyrant = cdReady(), dread = cdSoon(8), implosion = cdProbably(), grimoire = cdUnknown(),
    }
    -- PW is sourced from the GUIDANCE bar (Phase 6), not the pulse.
    local s = ns.DecisionLog.Render(pulse, guidance({}, nil, bar(3, -3)), { cues = {} })
    assert.truthy(s:find("PW:3/-3", 1, true), s)
    assert.truthy(s:find("PR:core,IB", 1, true), s)
    assert.truthy(s:find("T=R", 1, true), s)         -- ready
    assert.truthy(s:find("D=c8", 1, true), s)        -- counting down 8s
    assert.truthy(s:find("I=P", 1, true), s)         -- probably-up (napkin elapsed)
    assert.truthy(s:find("G=?", 1, true), s)         -- unknown
  end)

  -- ⚠ Since Phase 6 the SECRET DEGRADATION happens at the COACH boundary, not here:
  -- Coach:ResourceBars already coerces a non-numeric value to 0.  The log keeps its own
  -- guard anyway — it is a formatter over a channel it does not own, and a `?` is the only
  -- honest render of a value it cannot floor.
  it("guards a non-numeric (<secret>) bar value → ?", function()
    local g = guidance({}, nil, bar("<secret>", 0))
    local s = ns.DecisionLog.Render(build{}, g, { cues = {} })
    assert.truthy(s:find("PW:?/", 1, true), s)
  end)

  -- ⚠ THE EXACT RAIL IS WHAT MAKES `PW:` A USABLE INSTRUMENT (Phase 6.2).  The whole point
  -- of the phase is that the brain can tell 1.8 shards from 1.7; a trace that renders both
  -- as `1` cannot show whether it did.  The division happens HERE, at the very edge, in a
  -- string — no float ever reaches a gate.
  it("renders the EXACT rail fractionally when the bar carries it: PW:1.8/+0.2", function()
    local s = ns.DecisionLog.Render(build{}, guidance({}, nil, exactBar(18, 2)), { cues = {} })
    assert.truthy(s:find("PW:1.8/+0.2", 1, true), s)
  end)

  it("renders an in-flight spender's exact minus: PW:3.0/-2.0", function()
    local s = ns.DecisionLog.Render(build{}, guidance({}, nil, exactBar(30, -20)), { cues = {} })
    assert.truthy(s:find("PW:3.0/-2.0", 1, true), s)
  end)

  -- An all-integer PW column in a live capture therefore means the exact read is not wired
  -- (State) or not being passed through (Coach:ResourceBars) — which is exactly the signal
  -- the in-flight verification of Phase 6.2 greps for.
  it("falls back to the whole-unit integers when the bar carries no exact rail", function()
    local s = ns.DecisionLog.Render(build{}, guidance({}, nil, bar(3, -2)), { cues = {} })
    assert.truthy(s:find("PW:3/-2", 1, true), s)
  end)

  it("a modifier of 1 (mana, energy) renders as a plain integer, not 3.0", function()
    local b = bar(3, -2)
    b[1].valueExact, b[1].incomingExact, b[1].modifier = 3, -2, 1
    local s = ns.DecisionLog.Render(build{}, guidance({}, nil, b), { cues = {} })
    assert.truthy(s:find("PW:3/-2", 1, true), s)
  end)

  -- A PASSIVE spec's EmptyGuidance carries resourceBars = {}, so there IS no bar.  `?/?`
  -- is the honest render; reading through to the pulse would invent one.
  it("renders PW:?/? when guidance emits no resource bar (a passive spec)", function()
    local s = ns.DecisionLog.Render(build{ shards = 3 }, guidance({}), { cues = {} })
    assert.truthy(s:find("PW:?/?", 1, true), s)
  end)

  it("in-flight cast: newest start with no later terminal ⇒ CS code", function()
    local pulse = build{ history = {
      { phase = "start", spellID = ID.HOG, base = ID.HOG, at = 999 },
    } }
    local s = ns.DecisionLog.Render(pulse, { cues = {} }, { cues = {} })
    assert.truthy(s:find("CS:HoG", 1, true), s)
  end)

  it("in-flight cast cleared by a later succeeded ⇒ CS:-", function()
    local pulse = build{ history = {
      { phase = "start",     spellID = ID.HOG, base = ID.HOG, at = 998 },
      { phase = "succeeded", spellID = ID.HOG, base = ID.HOG, at = 999 },
    } }
    local s = ns.DecisionLog.Render(pulse, { cues = {} }, { cues = {} })
    assert.truthy(s:find("CS:-", 1, true), s)
  end)

  ------------------------------------------------------------------------------
  -- DOT — both of the DoT's observation channels, `<code>=<frame>/<edge>`.
  --
  -- This field is two-sided BECAUSE the brain consults the per-frame verdict first and the
  -- latch only where that has no opinion (§3.10).  A trace showing one channel cannot say
  -- which one decided, and the field capture that motivated the whole fix is exactly that
  -- shape: a live frame reading beside a 43-second-old notification.
  ------------------------------------------------------------------------------
  describe("the DOT field", function()
    local function dotOf(pulse)
      return ns.DecisionLog.Render(pulse, { cues = {} }, { cues = {} }):match("DOT:([^|]*)|")
    end

    it("no channel at all ⇒ -", function()
      assert.equals("-", dotOf(build{}):gsub("%s+$", ""))
    end)

    it("renders the bound-aura side and the pandemic mirror", function()
      local s = dotOf(build{ auraFrames = { [ID.TYRANT] =
        { capable = true, unitReadable = true, unit = "target", pandemic = true } } })
      assert.truthy(s:find("T=tgt+p/-", 1, true), s)
    end)

    it("`off` is the MISSING answer — capable, readable, nothing bound", function()
      local s = dotOf(build{ auraFrames = { [ID.TYRANT] =
        { capable = true, unitReadable = true, pandemic = false } } })
      assert.truthy(s:find("T=off/-", 1, true), s)
    end)

    it("a refused read is `?` and a vanished mechanism is `X` — never `off`", function()
      -- The distinction the whole rule-17b fence exists for: "we could not read it" and
      -- "Blizzard stopped writing it" must both be visible, and neither may look like the
      -- positive claim that the DoT is down.
      assert.truthy(dotOf(build{ auraFrames = { [ID.TYRANT] =
        { capable = true, unitReadable = false } } }):find("T=?/-", 1, true))
      assert.truthy(dotOf(build{ auraFrames = { [ID.TYRANT] =
        { capable = false } } }):find("T=X/-", 1, true))
    end)

    it("shows a live frame reading BESIDE a stale latch — the field-capture shape", function()
      local s = dotOf(build{
        auraFrames = { [ID.TYRANT] = { capable = true, unitReadable = true,
                                       unit = "target", pandemic = false } },
        dotEdges   = { [ID.TYRANT] = { state = "pandemic", at = 1000 - 43.8 } } })
      assert.truthy(s:find("T=tgt/pandemic@43.8", 1, true), s)
    end)

    it("an edge with no frame still renders, on the other side of the slash", function()
      local s = dotOf(build{ dotEdges = { [ID.TYRANT] = { state = "absent", at = 998 } } })
      assert.truthy(s:find("T=-/absent@2.0", 1, true), s)
    end)
  end)

  it("is DETERMINISTIC across pairs() orderings (the dedup guard)", function()
    -- Two guidances with the SAME cues inserted in opposite order must render identical
    -- strings — otherwise the change-only dedup misfires and the log fills with dupes.
    local pulse = build{ shards = 4 }
    local g1 = guidance({ [ID.DREAD] = "SOON", [ID.IMPLOSION] = "SOON", [ID.TYRANT] = "ROTATION" })
    local g2 = { cues = {} }
    g2.cues[ID.TYRANT]    = { draw = true, emphasis = "ROTATION" }
    g2.cues[ID.IMPLOSION] = { draw = true, emphasis = "SOON" }
    g2.cues[ID.DREAD]     = { draw = true, emphasis = "SOON" }
    local dl = drawList{ CID.TYRANT, CID.DREAD, CID.IMPLOSION }
    assert.are.equal(ns.DecisionLog.Render(pulse, g1, dl), ns.DecisionLog.Render(pulse, g2, dl))
  end)
end)

--------------------------------------------------------------------------------
-- DecisionLog.Record — the EDGE MARKERS (`# combat`, `# config`) and the ring.
--------------------------------------------------------------------------------
-- The v0.32.36 re-fly's acceptance is `w:-` (no winner) ≈ 0 % **in a pull**, and out of
-- combat "no winner" is the CORRECT answer — so without a combat split the ratio is
-- unreadable, which is exactly what happened to the 2026-08-01 capture (53.6 % across
-- 21,048 lines, meaningless). These markers are the split.
describe("DecisionLog.Record (the edge markers)", function()
  local ns, DL

  -- The entries of the one live session.
  local function entries()
    return ns.db.decisionlog[#ns.db.decisionlog].entries
  end

  local function combatMarks()
    local out = {}
    for _, e in ipairs(entries()) do
      local m = e:match("# combat (%a+)")
      if m then out[#out + 1] = m end
    end
    return out
  end

  -- Drive one tick. `content` varies the decision so a caller can hold it FIXED on purpose.
  local function tick(facts, cues)
    DL.Record(build(facts), guidance(cues or { [ID.SB] = "ROTATION" }), { cues = {} })
  end

  before_each(function()
    ns = H.fresh()
    ns.db = {}                 -- Record refuses to run without it (pre-ADDON_LOADED guard)
    H.load("DecisionLog.lua")
    DL = ns.DecisionLog
    DL.session, DL.t0, DL.lastContent, DL.lastConfig, DL.lastCombat = nil, nil, nil, nil, nil
  end)

  it("stamps the session's opening combat state as a BASELINE, not an edge", function()
    tick({ combat = false })
    assert.same({ "end" }, combatMarks())   -- "from here, out of combat"
  end)

  it("says so when a session BEGINS in combat (a login inside a pull)", function()
    tick({ combat = true })
    assert.same({ "start" }, combatMarks())
  end)

  -- ⚠ THE LOAD-BEARING ONE, AND THE MUTATION CHECK FOR THE WHOLE FEATURE.  Both ticks below
  -- render byte-identical content (same facts, same cues, fixed clock), so the change-only
  -- dedup drops the second one entirely. If the combat stamp is ever moved BELOW that dedup,
  -- the edge vanishes and this goes red — which is the only thing standing between the
  -- marker and the failure mode it exists to prevent: pulling from an idle bar, where the
  -- recommended press does not change at the moment combat begins.
  it("stamps a combat edge even when the DECISION does not change", function()
    tick({ combat = false })
    local before = #entries()
    tick({ combat = true })                 -- identical decision, different combat state
    assert.same({ "end", "start" }, combatMarks())
    -- ...and it really was deduped: the edge marker is the ONLY thing appended.
    assert.equals(before + 1, #entries())
    assert.truthy(entries()[#entries()]:find("# combat start", 1, true))
  end)

  it("stamps the exit edge too", function()
    tick({ combat = true })
    tick({ combat = false })
    assert.same({ "start", "end" }, combatMarks())
  end)

  it("does not re-stamp while the combat state holds", function()
    tick({ combat = true })
    tick({ combat = true, shards = 1 })     -- content moves, combat does not
    tick({ combat = true, shards = 2 })
    assert.same({ "start" }, combatMarks())
  end)

  it("marks a full pull cycle in order, so a reader can slice the session", function()
    tick({ combat = false })
    tick({ combat = true,  shards = 1 })
    tick({ combat = false, shards = 2 })
    tick({ combat = true,  shards = 3 })
    assert.same({ "end", "start", "end", "start" }, combatMarks())
  end)

  it("still stamps the config line, and the decision line, around it", function()
    tick({ combat = true })
    local joined = table.concat(entries(), "\n")
    assert.truthy(joined:find("# combat start", 1, true))
    assert.truthy(joined:find("# config", 1, true))
    assert.truthy(joined:find("S{CD:", 1, true))
  end)

  -- The ring is bounded, and the marker path appends too — so it has to trim as well, or a
  -- long session with many combat edges grows past the cap on a path nobody was watching.
  it("keeps the entry ring bounded across the marker path", function()
    for i = 1, 40 do tick({ combat = (i % 2 == 0), shards = i % 5 }) end
    assert.is_true(#entries() <= 5000)
    assert.is_true(#entries() > 0)
  end)
end)
