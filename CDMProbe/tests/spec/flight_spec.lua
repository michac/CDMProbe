-- flight_spec.lua — the ACCEPTANCE RECORDER (`/cdmp flight`).
--
-- The recorder's whole value is that a human no longer eyeballs the acceptance criteria,
-- so the properties worth pinning are the ones that would silently make the report LIE:
-- a ring that dedups away a transition it should have kept, a ring that grows without
-- bound, an arm that appends to the last flight's rows, and a sampler that reads anything
-- other than the SHIPPING code path (a private copy could pass while the shipped path
-- fails, which is the entire failure mode this instrument is supposed to catch).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("Flight — the acceptance recorder", function()
  local ns, F

  before_each(function()
    ns = H.fresh()
    H.setSpecIndex(3); ns.ResolveActiveSpec()      -- Destruction
    H.load("State.lua")
    H.load("Coverage.lua")
    H.load("Assist.lua")
    H.load("HudLayout.lua")
    H.load("HudDriver.lua")
    H.load("Flight.lua")
    F = ns.Flight
    ns.db = {}
    -- The HUD's enable path pokes the renderer/ticker; the recorder only needs it not to
    -- throw, and `SetHud` is already pcall-safe off-game.
    ns.SetHud = function() end
    ns.HudOn = function() return true end
    -- A CDM database, so coverage has something real to answer with.
    _G.Enum.CooldownViewerCategory = { Essential = 0 }
    _G.C_CooldownViewer = {
      GetCooldownViewerCategorySet = function(v) return v == 0 and { 901 } or {} end,
      GetCooldownViewerCooldownInfo = function() return { spellID = 116858, isKnown = true } end,
    }
    ns.OnLogin()
  end)

  after_each(function()
    F.Disarm()
    _G.C_CooldownViewer = nil
    _G.Enum.CooldownViewerCategory = nil
  end)

  it("records nothing until armed", function()
    ns.db.flight = { samples = {} }
    F.Sample("tick")
    assert.equals(0, #ns.db.flight.samples)
  end)

  it("arming takes an immediate sample", function()
    F.Arm()
    assert.equals(1, #ns.db.flight.samples)
    assert.equals("arm", ns.db.flight.samples[1].reason)
  end)

  it("arming WIPES the previous flight — a flight is one session", function()
    -- An extractor that has to guess where the last pass ended is the ambiguity the
    -- recorder exists to remove.
    F.Arm()
    F.Arm()
    assert.equals(1, #ns.db.flight.samples)
  end)

  it("a tick with an unchanged answer adds NO row", function()
    F.Arm()
    F.Sample("tick")
    F.Sample("tick")
    assert.equals(1, #ns.db.flight.samples)
  end)

  it("entering combat is a new row, and the coverage answer is UNCHANGED", function()
    -- The single most important transition in the file.  In combat `Coverage.Get()` must
    -- hand back the CACHED out-of-combat report marked stale — never a rescan, whose
    -- secret-shortened enumeration would invent blind rows mid-pull.  So the assertion is
    -- INVARIANCE, not a fixed number: whatever the roster read out of combat, it must read
    -- identically in combat.
    F.Arm()
    local ooc = ns.db.flight.samples[1].cov
    H.setCombat(true)
    F.Sample("PLAYER_REGEN_DISABLED")
    assert.equals(2, #ns.db.flight.samples)
    local s = ns.db.flight.samples[2]
    assert.is_true(s.combat)
    assert.is_true(s.cov.stale)              -- the cached report, NOT a rescan
    assert.is_false(ooc.stale)
    assert.equals(ooc.blind, s.cov.blind)    -- combat invented no blind rows
    assert.equals(ooc.scanned, s.cov.scanned)
    assert.equals(ooc.total, s.cov.total)
  end)

  it("...and in combat from a COLD start it refuses rather than scanning", function()
    -- No cache to fall back on (armed mid-pull, or a login race): the honest answer is a
    -- refusal, not a roster read through secret-shortened enumeration.
    H.setCombat(true)
    F.Arm()
    local s = ns.db.flight.samples[1]
    assert.is_false(s.cov.ok)
    assert.equals("in-combat", s.cov.reason)
    assert.equals(0, s.cov.blind)
  end)

  it("a spec swap is a new row, and carries the new specID", function()
    F.Arm()
    H.setSpecIndex(1); ns.ResolveActiveSpec()      -- Demonology
    F.Sample("PLAYER_SPECIALIZATION_CHANGED")
    assert.equals(2, #ns.db.flight.samples)
    assert.equals(266, ns.db.flight.samples[2].specID)
  end)

  it("carries the PER-ID verdicts on every row, not just a count", function()
    -- The acceptance criteria are per-id ("Incinerate reads virtual, not blind"); a
    -- summary count cannot answer them, so a row that only counted would be useless.
    F.Arm()
    local v = ns.db.flight.samples[1].cov.verdicts
    assert.is_true(#v > 0)
    local seen = {}
    for _, e in ipairs(v) do seen[e.id] = e.v end
    assert.equals("ok", seen[116858])              -- Chaos Bolt, the one tracked row
    assert.is_nil(seen[417234])                    -- Crashing Chaos is gone from the roster
  end)

  it("records the layout on a transition but NOT on a plain tick", function()
    F.Arm()
    assert.is_not_nil(ns.db.flight.samples[1].layout)
    H.setCombat(true)
    F.Sample("tick")
    assert.equals(2, #ns.db.flight.samples)
    assert.is_nil(ns.db.flight.samples[2].layout)  -- 17 unchanged rows every second
  end)

  it("a SECRET assist return reaches the ring as a class, never a value", function()
    _G.C_AssistedCombat = { GetNextCastSpell = function() return H.secretValue() end }
    F.Arm()
    local s = ns.db.flight.samples[1]
    assert.equals("SECRET", s.assist.next0)
    assert.equals("<secret>", s.assist.next0Value)
    _G.C_AssistedCombat = nil
  end)

  it("the ring is capped — a long session cannot grow without bound", function()
    F.Arm()
    local n = 0
    for i = 1, 200 do
      -- Force a distinct answer shape each time by flipping combat.
      H.setCombat(i % 2 == 0)
      F.Sample("tick")
      n = #ns.db.flight.samples
    end
    assert.is_true(n <= 120)
  end)
end)
