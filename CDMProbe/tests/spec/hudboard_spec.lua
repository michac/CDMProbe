-- hudboard_spec.lua — the BOARD RESOLVER (W4b, A1+A2).  This is the coverage the
-- audit says the old Recompute middle layer never had: filler board-resolution,
-- LATE promotion + its combat-gated clock, the SOON treatment, SpecNoCue
-- suppression, and the Tyrant-yellow-until-real hold — plus the level->colorKey /
-- emphasis->fill decisions pulled out of HudChrome.
--
-- Scores are HAND-BUILT here on purpose: HudBoard's contract is "a score with
-- level/candidate/soon/projected/judgeReady/emphasis/cadence/reasons in, a cue
-- descriptor out", so these tests are independent of HudScore's scoring RULES
-- (those are hudscore_spec's job).  The board is built with FIXTURE cfg, which
-- also exercises the factory / polymorphism seam (New(cfg) -> instance).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("HudBoard.Compute", function()
  local ns, Board

  local TYRANT, GRIMOIRE = 265187, 999

  before_each(function()
    ns = H.fresh()
    H.load("HudScore.lua")     -- provides the default Stabilise the board injects
    H.load("HudBoard.lua")
    Board = ns.HudBoard.New({
      specNoCue = { [GRIMOIRE] = true },
      tyrantID  = TYRANT,
      shardCap  = 5,
      lateAfter = 3.0,
    })
  end)

  -- A score table: only the fields the board reads, reasons always present.
  local function sc(t)
    t = t or {}
    t.reasons = t.reasons or {}
    return t
  end

  -- Assemble a ctx from a sparse override.
  local function ctx(o)
    o = o or {}
    return {
      scores = o.scores or {}, live = o.live or {},
      prevScore = o.prevScore or {},
      prevCueLevel = o.prevCueLevel or {}, prevCueProjected = o.prevCueProjected or {},
      candidateSince = o.candidateSince or {},
      now = o.now or 0, inCombat = o.inCombat or false, shards = o.shards,
    }
  end

  ------------------------------------------------------------------------------
  -- Filler board-resolution (needs the whole board — the per-item scorer can't)
  ------------------------------------------------------------------------------
  it("blanks the filler when a real call is up", function()
    local b = Board:Compute(ctx({ scores = {
      hog = sc({ level = "ROTATION" }),
      sb  = sc({ level = "AVAILABLE", cadence = "filler" }),
    } }))
    assert.is_false(b.cues.sb.draw)   -- filler blanked when a real call is up
  end)

  it("promotes the filler to ROTATION in combat when nothing better is up", function()
    local b = Board:Compute(ctx({ inCombat = true, scores = {
      sb = sc({ level = "AVAILABLE", cadence = "filler" }),
    } }))
    assert.is_true(b.cues.sb.draw)
    assert.equals("ROTATION", b.cues.sb.colorKey)
    assert.equals(1, b.lit)
  end)

  it("leaves the filler AVAILABLE (no cue) out of combat", function()
    local b = Board:Compute(ctx({ inCombat = false, scores = {
      sb = sc({ level = "AVAILABLE", cadence = "filler" }),
    } }))
    assert.is_false(b.cues.sb.draw)
    assert.equals(0, b.lit)
  end)

  ------------------------------------------------------------------------------
  -- LATE — combat-gated clock AND promotion (one decision, one gate)
  ------------------------------------------------------------------------------
  it("promotes a long-standing candidate to LATE in combat", function()
    local b = Board:Compute(ctx({
      inCombat = true, now = 5,
      scores = { d = sc({ level = "ROTATION", candidate = true }) },
      candidateSince = { d = 1 },       -- 4s >= lateAfter(3)
    }))
    assert.equals("LATE", b.cues.d.colorKey)
    assert.equals(1, b.lit)
  end)

  it("holds ROTATION and keeps the clock while still under lateAfter", function()
    local b = Board:Compute(ctx({
      inCombat = true, now = 2,
      scores = { d = sc({ level = "ROTATION", candidate = true }) },
      candidateSince = { d = 1 },       -- 1s < 3
    }))
    assert.equals("ROTATION", b.cues.d.colorKey)
    assert.equals(1, b.candidateSinceNext.d)
  end)

  it("stamps `now` as the clock start on a fresh candidate", function()
    local b = Board:Compute(ctx({
      inCombat = true, now = 10,
      scores = { d = sc({ level = "ROTATION", candidate = true }) },
    }))
    assert.equals(10, b.candidateSinceNext.d)
  end)

  it("runs NO clock out of combat (the M3e stale-stamp bug)", function()
    local b = Board:Compute(ctx({
      inCombat = false, now = 100,
      scores = { d = sc({ level = "ROTATION", candidate = true }) },
      candidateSince = { d = 1 },
    }))
    assert.is_nil(b.candidateSinceNext.d)
    assert.equals("ROTATION", b.cues.d.colorKey)   -- never LATE out of combat
  end)

  ------------------------------------------------------------------------------
  -- SOON — a treatment on NEVER, never a level of its own
  ------------------------------------------------------------------------------
  it("draws SOON on a NEVER dot that is anticipating", function()
    local b = Board:Compute(ctx({ scores = {
      t = sc({ level = "NEVER", soon = true }),
    } }))
    assert.is_true(b.cues.t.draw)
    assert.equals("SOON", b.cues.t.colorKey)
  end)

  it("does not draw a plain NEVER", function()
    local b = Board:Compute(ctx({ scores = { t = sc({ level = "NEVER" }) } }))
    assert.is_false(b.cues.t.draw)
  end)

  ------------------------------------------------------------------------------
  -- SpecNoCue suppression (Grimoires) — resolved, but never drawn
  ------------------------------------------------------------------------------
  it("suppresses the cue on a SpecNoCue ability even at ROTATION", function()
    local b = Board:Compute(ctx({
      scores = { g = sc({ level = "ROTATION", candidate = true }) },
      live   = { g = GRIMOIRE },
    }))
    assert.is_false(b.cues.g.draw)
    assert.equals(1, b.lit)   -- still counted / logged; only the CUE is muted
  end)

  ------------------------------------------------------------------------------
  -- Tyrant yellow-until-real
  ------------------------------------------------------------------------------
  it("holds Tyrant at SOON with shardHold when shards are not capped", function()
    local b = Board:Compute(ctx({
      scores = { ty = sc({ level = "ROTATION", emphasis = "burst" }) },
      live   = { ty = TYRANT }, shards = 3,
    }))
    assert.equals("SOON", b.cues.ty.colorKey)
    assert.is_true(b.cues.ty.shardHold)
    assert.is_true(b.tyrantShardHold)
  end)

  it("greenlights Tyrant at capped shards", function()
    local b = Board:Compute(ctx({
      scores = { ty = sc({ level = "ROTATION", emphasis = "burst" }) },
      live   = { ty = TYRANT }, shards = 5,
    }))
    assert.equals("ROTATION", b.cues.ty.colorKey)
    assert.is_false(b.cues.ty.shardHold)
    assert.is_false(b.tyrantShardHold)
  end)

  it("treats unreadable shards as NOT full (a green we can't justify)", function()
    local b = Board:Compute(ctx({
      scores = { ty = sc({ level = "ROTATION", emphasis = "burst" }) },
      live   = { ty = TYRANT }, shards = nil,
    }))
    assert.equals("SOON", b.cues.ty.colorKey)
    assert.is_true(b.cues.ty.shardHold)
  end)

  ------------------------------------------------------------------------------
  -- colorKey mapping + fill (the decisions pulled out of HudChrome)
  ------------------------------------------------------------------------------
  it("maps AVAILABLE+judgeReady to the JUDGE key, plain AVAILABLE to nothing", function()
    local j = Board:Compute(ctx({ scores = { i = sc({ level = "AVAILABLE", judgeReady = true }) } }))
    assert.equals("JUDGE", j.cues.i.colorKey)
    local a = Board:Compute(ctx({ scores = { u = sc({ level = "AVAILABLE" }) } }))
    assert.is_false(a.cues.u.draw)
  end)

  it("fills burst emphasis to 1.0 regardless of level, else the level's fill", function()
    local burst = Board:Compute(ctx({
      scores = { ty = sc({ level = "ROTATION", emphasis = "burst" }) },
      live = { ty = TYRANT }, shards = 5,
    }))
    assert.equals(1.00, burst.cues.ty.fill)
    local rot = Board:Compute(ctx({ scores = { d = sc({ level = "ROTATION" }) } }))
    assert.equals(0.80, rot.cues.d.fill)          -- DEFAULT_FILL.ROTATION
  end)

  it("carries the pulse period for pulsing keys and nil for steady ones", function()
    local soon = Board:Compute(ctx({ scores = { t = sc({ level = "NEVER", soon = true }) } }))
    assert.equals(0.85, soon.cues.t.pulse)        -- DEFAULT_PULSE.SOON
    local rot = Board:Compute(ctx({ scores = { d = sc({ level = "ROTATION" }) } }))
    assert.is_nil(rot.cues.d.pulse)               -- ROTATION steady
  end)

  ------------------------------------------------------------------------------
  -- Stabilise integration (the churn gate, injected default = HudScore.Stabilise)
  ------------------------------------------------------------------------------
  it("holds a real-painted cue against a projection-derived flip", function()
    -- HoG painted ROTATION off a real reading; a cast projects it below its gate.
    local b = Board:Compute(ctx({
      scores = { hog = sc({ level = "NEVER", projected = true }) },
      prevCueLevel = { hog = "ROTATION" }, prevCueProjected = { hog = false },
    }))
    assert.equals("ROTATION", b.cues.hog.colorKey)   -- damped, not blanked
    assert.equals("ROTATION", b.cueLevelNext.hog)
  end)

  ------------------------------------------------------------------------------
  -- Transitions + clears
  ------------------------------------------------------------------------------
  it("emits a transition on a level move and none on an unchanged one", function()
    local moved = Board:Compute(ctx({
      scores = { d = sc({ level = "ROTATION" }) },
      prevScore = { d = { level = "NEVER" } },
    }))
    assert.equals(1, #moved.transitions)
    assert.equals("ROTATION", moved.transitions[1].to)

    local same = Board:Compute(ctx({
      scores = { d = sc({ level = "ROTATION" }) },
      prevScore = { d = { level = "ROTATION" } },
    }))
    assert.equals(0, #same.transitions)
  end)

  it("emits a cleared transition + no draw when a scored dot vanishes", function()
    local b = Board:Compute(ctx({
      scores = { g = false },
      prevScore = { g = { level = "ROTATION" } },
    }))
    assert.is_false(b.cues.g.draw)
    assert.equals(1, #b.transitions)
    assert.is_true(b.transitions[1].cleared)
  end)
end)
