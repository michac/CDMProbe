-- huddriver_cadence_spec.lua — THE SPLIT CADENCE (roster-state-plan Phase 5 §C8).
--
-- WHY THIS FILE EXISTS.  §C8 is the one place in Phase 5 where the sizing win and
-- correctness pull in OPPOSITE directions, and the plan says so in as many words.  Out of
-- combat `State.Build`'s per-row client reads were ~7,000 guarded calls a second, re-asking
-- questions that cannot change between two frames of standing still — so the pulse throttles
-- to ~2 Hz there.  But `installAlertHooks` used to run INSIDE Build, and it is what wires the
-- CDM's alert choke point onto every re-pooled or newly created item frame; throttle Build
-- with the hooks still inside it and a new frame stays unhooked for up to half a second.
--
-- That is not a decoration loss.  FOUR of Retribution's Essential buttons keep their cooldown
-- on a charge category, so `ns.BaseCooldown` reads 0 and the napkin has nothing to count
-- down — the alert edges are the only in-combat readiness channel they have.  A silent
-- half-second hole in that channel is precisely the class of failure this project keeps
-- re-learning, so it gets a test rather than a comment.
--
-- ⚠ THREE PROPERTIES, and all three are the SAME decision seen from different sides:
--   1. out of combat the pulse is REUSED inside the period,
--   2. IN COMBAT it never is,
--   3. the frame pump runs regardless of either.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("HudDriver — the OOC build throttle", function()
  local ns, D, builds

  before_each(function()
    ns = H.fresh()
    H.setSpecIndex(3)
    ns.ResolveActiveSpec()
    H.load("State.lua")

    -- Count Builds without running one: the cadence is the subject, not the fold.  (The
    -- pump is left REAL — a stub of it could not prove the thing this file is about.)
    builds = 0
    local realBuild = ns.State.Build
    ns.State.Build = function(...) builds = builds + 1; return realBuild(...) end

    H.load("HudDriver.lua")
    D = ns.HudDriver
    D.lastPulse, D.lastBuild = nil, 0
  end)

  it("the FIRST tick always builds — there is nothing to reuse", function()
    D.PulseNow()
    assert.equals(1, builds)
  end)

  it("out of combat, a second tick inside the period REUSES the pulse", function()
    local first = D.PulseNow()
    H.advance(0.1)                      -- one 10 Hz tick
    local second = D.PulseNow()
    assert.equals(1, builds)
    assert.are.equal(first, second, "the same pulse table, not an equal one")
  end)

  it("...and rebuilds once the period has elapsed", function()
    D.PulseNow()
    H.advance(0.5)
    D.PulseNow()
    assert.equals(2, builds)
  end)

  it("IN COMBAT there is no throttle at all — every tick is a fresh pulse", function()
    -- Everything that moves a decision in a pull — the napkin countdown, the alert edges,
    -- power, the cast history — moves on the 10 Hz rhythm.  And the reads that were
    -- expensive out of combat are exactly the ones that short-circuit on InCombatLockdown,
    -- so there is nothing to save here anyway: the saving is where the cost is.
    H.setCombat(true)
    D.PulseNow()
    H.advance(0.1)
    D.PulseNow()
    H.advance(0.1)
    D.PulseNow()
    assert.equals(3, builds)
  end)

  -- ⚠ NOT COVERED HERE, and stated so the gap stays visible: `ns.SetHud` clears
  -- `D.lastPulse` on every toggle (a pulse captured before the HUD went off may describe a
  -- world that has since moved — a respec, a spec swap, a whole session).  Reaching it from
  -- a test means standing up the Coach, Binder and Renderer instances, which is a
  -- whole-pipeline fixture this file has no other use for.  The clear is one line, beside
  -- the `D.on = on` it belongs to.
end)

describe("St.PumpFrames — the 10 Hz half", function()
  local ns, St

  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    St = ns.State
  end)

  it("hooks a frame the throttled Build has not seen yet", function()
    -- The whole point of hoisting it out of Build: a frame created between two OOC refreshes
    -- must still get its alert hook, because those edges are the only in-combat readiness
    -- channel a charge-category ability has.
    local item = { cooldownID = 903, TriggerAlertEvent = function() end }
    ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
    ns.GetViewer     = function() return { n = 1 } end
    ns.GetItemFrames = function() return { item } end
    St.PumpFrames()
    assert.is_true(item.__stateAlertHooked)
  end)

  it("is idempotent — a second pump does not re-hook an already-hooked frame", function()
    -- `hooksecurefunc` can never be undone, so a pump that re-hooked would stack callbacks
    -- ten times a second for the life of the session.
    local hooks = 0
    local realHook = _G.hooksecurefunc
    _G.hooksecurefunc = function(...) hooks = hooks + 1; return realHook(...) end
    local item = { cooldownID = 903, TriggerAlertEvent = function() end }
    ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
    ns.GetViewer     = function() return { n = 1 } end
    ns.GetItemFrames = function() return { item } end
    St.PumpFrames(); St.PumpFrames(); St.PumpFrames()
    _G.hooksecurefunc = realHook
    assert.equals(1, hooks)
  end)
end)
