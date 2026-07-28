-- hud2log_spec.lua — the HUD2 decision-log RENDER gate.
--
-- Only ns.Hud2Log.Render (PURE) is unit-tested: it takes hand-built pulse/guidance/
-- drawList and emits the `S{…} G{…} B{…}` string.  Record (session push, date(),
-- ns.version, the ring) is NOT tested — mock_ns provides no `date` and doesn't load
-- Core.lua, so ns.version is unset; all that clock/db/version logic lives in Record,
-- out of Render, precisely so this spec needs none of it.
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
-- VIEW: `abilities` keyed by base spellID (folded), `buffs` by spellID, `resources.shards`.
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
    at = 1000, combat = true,
    resources = { shards = { value = f.shards or 0, incoming = f.incoming or 0, max = 5 } },
    buffs = buffs,
    history = f.history or {},
    abilities = abilities,
  }
end

-- A guidance whose cues carry an emphasis per BASE spellID.  `cues = { [spellID] = "ROTATION", … }`.
local function guidance(cues, notes)
  notes = notes or {}
  local out = {}
  for spellID, emph in pairs(cues) do
    out[spellID] = { draw = true, emphasis = emph, note = notes[spellID] }
  end
  return { cues = out }
end

-- A drawList that anchors the given cids (i.e. the Binder DREW them).
local function drawList(anchoredCids)
  local cues = {}
  for _, cid in ipairs(anchoredCids or {}) do
    cues[#cues + 1] = { anchorTo = cid }
  end
  return { cues = cues }
end

describe("Hud2Log.Render", function()
  local ns
  before_each(function()
    ns = H.fresh()
    H.load("Hud2Log.lua")
  end)

  it("renders a normal winner line: w:SB + note, B{SB:ROT}", function()
    local pulse = build{ shards = 2 }
    local g = guidance({ [ID.SB] = "ROTATION" }, { [ID.SB] = "pool to 5" })   -- cue keyed by spellID
    local s = ns.Hud2Log.Render(pulse, g, drawList{ CID.SB })                 -- Binder anchors the cid
    assert.truthy(s:find("G{w:SB:pool_to_5", 1, true), s)
    assert.truthy(s:find("B{SB:ROT}", 1, true), s)
    assert.is_nil(s:find("×", 1, true))          -- SB was drawn, not dropped
  end)

  it("no winner ⇒ w:-", function()
    local pulse = build{}
    local s = ns.Hud2Log.Render(pulse, { cues = {} }, { cues = {} })
    assert.truthy(s:find("G{w:-}", 1, true), s)
  end)

  it("dropped cue (in guidance, absent from drawList) ⇒ ×", function()
    local pulse = build{ shards = 1 }
    local g = guidance({ [ID.SB] = "ROTATION" })
    local s = ns.Hud2Log.Render(pulse, g, drawList{})   -- Binder anchored nothing
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
    local s = ns.Hud2Log.Render(pulse, g, drawList{ CID.TYRANT, CID.HOG, CID.DREAD, CID.IMPLOSION })
    assert.truthy(s:find("w!T", 1, true), s)
    assert.truthy(s:find("fb:HoG", 1, true), s)
    assert.truthy(s:find("soon:D,I", 1, true), s)   -- sorted: D before I
  end)

  it("encodes shards value/incoming, procs, readiness tokens", function()
    local pulse = build{
      shards = 3, incoming = -3, core = true, art = "infernal",
      tyrant = cdReady(), dread = cdSoon(8), implosion = cdProbably(), grimoire = cdUnknown(),
    }
    local s = ns.Hud2Log.Render(pulse, { cues = {} }, { cues = {} })
    assert.truthy(s:find("PW:3/-3", 1, true), s)
    assert.truthy(s:find("PR:core,IB", 1, true), s)
    assert.truthy(s:find("T=R", 1, true), s)         -- ready
    assert.truthy(s:find("D=c8", 1, true), s)        -- counting down 8s
    assert.truthy(s:find("I=P", 1, true), s)         -- probably-up (napkin elapsed)
    assert.truthy(s:find("G=?", 1, true), s)         -- unknown
  end)

  it("guards a <secret> shard value → ?", function()
    local pulse = build{}
    pulse.resources.shards.value = "<secret>"
    local s = ns.Hud2Log.Render(pulse, { cues = {} }, { cues = {} })
    assert.truthy(s:find("PW:?/", 1, true), s)
  end)

  it("in-flight cast: newest start with no later terminal ⇒ CS code", function()
    local pulse = build{ history = {
      { phase = "start", spellID = ID.HOG, base = ID.HOG, at = 999 },
    } }
    local s = ns.Hud2Log.Render(pulse, { cues = {} }, { cues = {} })
    assert.truthy(s:find("CS:HoG", 1, true), s)
  end)

  it("in-flight cast cleared by a later succeeded ⇒ CS:-", function()
    local pulse = build{ history = {
      { phase = "start",     spellID = ID.HOG, base = ID.HOG, at = 998 },
      { phase = "succeeded", spellID = ID.HOG, base = ID.HOG, at = 999 },
    } }
    local s = ns.Hud2Log.Render(pulse, { cues = {} }, { cues = {} })
    assert.truthy(s:find("CS:-", 1, true), s)
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
    assert.are.equal(ns.Hud2Log.Render(pulse, g1, dl), ns.Hud2Log.Render(pulse, g2, dl))
  end)
end)
