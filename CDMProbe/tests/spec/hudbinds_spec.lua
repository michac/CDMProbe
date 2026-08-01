-- hudbinds_spec.lua — the KEYBIND LADDER (roster-state-plan.md §4.1, Phase 3).
--
-- Loaded from the REAL HudBinds.lua, so this is also the companion that proves
-- `B.Resolve` actually SHIPS — the same lesson viewers_spec exists for: a stub proves the
-- caller works given the collaborator, never that the collaborator exists.
--
-- The 180-slot action-bar scan is NOT exercised here.  It reads `GetActionInfo` /
-- `GetBindingKey`, and the ladder is a question about ORDER over an already-resolved map,
-- so the map is set directly — the fixture is the cache, which is exactly the surface
-- `B.Get` reads live.
--
-- WHAT THE LADDER IS.  State passes three PLAIN STRUCT FIELDS in rung order:
--   rung 3  overrideTooltipSpellID   (what Blizzard's GetSpellID tries first)
--   rung 4  overrideSpellID          (Hellcaller's Wither arrives here)
--   rung 5  spellID                  (the base — the only rung before Phase 3)
-- FIRST ID WITH A REAL BINDING WINS.  Rung 1 (the live aura instance) and the observed
-- live override are the v0.7.0 Demonic-Art transform fence and are deliberately absent;
-- rung 2 (the elected linkedSpellID) was MEASURED ABSENT on 2026-07-31, 0 of 72 rows.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

-- Real ids, so a failure reads as the ability it actually is (cooldown-manager.md §2.7).
local IMMOLATE  = 348        -- the Destruction row's BASE on both hero trees
local WITHER    = 445468     -- Hellcaller's replacement, arriving as overrideSpellID
local INCINERATE = 29722
local IMP_LORD  = 1276452    -- cast id; the bar may hold talent id 136726 instead
local IMP_TALENT = 136726

describe("HudBinds — B.Resolve, the keybind rung ladder", function()
  local ns, B

  before_each(function()
    ns = H.fresh()
    H.load("HudBinds.lua")       -- REPLACES the harness stub with the shipping module
    B = ns.HudBinds
    B.map = {}                   -- the resolved action-bar cache, set per test
    B.dirty = false
  end)

  it("ships Resolve at all", function()
    assert.is_function(B.Resolve)
  end)

  ------------------------------------------------------------------------------
  -- The order.
  ------------------------------------------------------------------------------
  it("takes rung 3 (tooltip override) over rung 4 and the base", function()
    B.map = { [INCINERATE] = "1", [WITHER] = "2", [IMMOLATE] = "3" }
    assert.equals("1", B.Resolve(INCINERATE, WITHER, IMMOLATE))
  end)

  it("takes rung 4 (override) over the base", function()
    B.map = { [WITHER] = "2", [IMMOLATE] = "3" }
    assert.equals("2", B.Resolve(nil, WITHER, IMMOLATE))
  end)

  it("falls through an UNBOUND rung rather than stopping at it", function()
    -- The self-correcting property, and the reason the ladder needs no spec fences: a
    -- candidate that is not on any bar has no binding to return, so a wrong guess costs
    -- nothing.  Here rung 3 exists as an id but is not bound.
    B.map = { [IMMOLATE] = "3" }
    assert.equals("3", B.Resolve(INCINERATE, WITHER, IMMOLATE))
  end)

  -- THE MOTIVATING DEFECT, at the unit level.  On Hellcaller the row's base is Immolate
  -- 348 while the bar holds Wither; base-only resolution returned nothing at all, so the
  -- icon showed no key hint.
  it("resolves the HELLCALLER shape — base unbound, override bound", function()
    B.map = { [WITHER] = "4" }
    assert.equals("4", B.Resolve(nil, WITHER, IMMOLATE))
    assert.is_nil(B.Get(IMMOLATE), "base-only resolution is what missed this")
  end)

  it("resolves the DIABOLIST shape — no override, base bound", function()
    B.map = { [IMMOLATE] = "3" }
    assert.equals("3", B.Resolve(nil, nil, IMMOLATE))
  end)

  ------------------------------------------------------------------------------
  -- Refusals — the rules B.Get owns and the ladder must not launder.
  ------------------------------------------------------------------------------
  it("refuses a SECRET candidate and keeps walking", function()
    -- Never index the cache with a Secret Value (that taints); an unreadable id is simply
    -- an unbound one as far as the chrome is concerned.  ⚠ H.markSecret keys BY VALUE, so
    -- the marked number is secret everywhere — which is why the bound-but-secret id must
    -- still not win.
    H.markSecret(WITHER)
    B.map = { [WITHER] = "2", [IMMOLATE] = "3" }
    assert.equals("3", B.Resolve(nil, WITHER, IMMOLATE))
  end)

  it("refuses a non-number candidate", function()
    B.map = { [IMMOLATE] = "3" }
    assert.equals("3", B.Resolve("not-an-id", {}, IMMOLATE))
  end)

  it("returns nil — never a placeholder — when nothing is bound", function()
    B.map = {}
    assert.is_nil(B.Resolve(INCINERATE, WITHER, IMMOLATE))
  end)

  it("returns nil for an empty ladder", function()
    B.map = { [IMMOLATE] = "3" }
    assert.is_nil(B.Resolve())
    assert.is_nil(B.Resolve(nil, nil, nil))
  end)

  ------------------------------------------------------------------------------
  -- The alias fallback survives the ladder (it lives inside B.Get, and must keep
  -- working for every rung, not just the base).
  ------------------------------------------------------------------------------
  it("keeps the SpecBindAlias fallback on a ladder rung", function()
    -- Imp Lord: the CDM tracks cast id 1276452 while the bar may hold talent id 136726.
    -- SpecDemonology declares the alias and the resolver activated 266 in H.fresh().
    assert.equals(IMP_TALENT, ns.SpecBindAlias[IMP_LORD], "harness lost the alias table")
    B.map = { [IMP_TALENT] = "sE" }
    assert.equals("sE", B.Resolve(nil, IMP_LORD, IMMOLATE))
  end)

  it("still prefers an EARLIER rung's direct hit over a later rung's alias", function()
    B.map = { [WITHER] = "2", [IMP_TALENT] = "sE" }
    assert.equals("2", B.Resolve(nil, WITHER, IMP_LORD))
  end)
end)

--------------------------------------------------------------------------------
-- THE CACHE'S TWO FENCES.  The 2026-07-31 field session ran entirely keyless, and the
-- cause was the COMBAT GATE (`0 scan(s)` — a target-dummy session is continuous combat, so
-- the scan never ran once).  The EMPTY-SCAN fence below was written for that report before
-- the status line pinned it down, and has never been observed firing in the field — it is
-- kept because caching an empty scan as authoritative is a real hole regardless, and the
-- cold-cache exemption relies on it to keep retrying.  Both are pinned here; only the
-- second is a fix for something we measured.
--
-- These drive the REAL 180-slot scan through the harness's default-inert action-bar fake.
-- ⚠ `C_Timer.After` is a no-op in the harness, so the retry does not recurse here — what
-- is asserted is the STATE the retry is armed from (`dirty` kept, `retried` counted),
-- which is the half that was wrong.
--------------------------------------------------------------------------------
describe("HudBinds — the login race", function()
  local ns, B

  before_each(function()
    ns = H.fresh()
    H.load("HudBinds.lua")
    B = ns.HudBinds
  end)

  it("does NOT accept an empty scan as the answer", function()
    -- Bars not populated yet: every slot empty.
    B.Start()
    assert.equals(0, B.stats.bound)
    assert.is_true(B.dirty, "an empty scan must stay dirty so a rescan is owed")
    assert.equals(1, B.stats.retried)
  end)

  it("accepts a scan that resolved something, and stops retrying", function()
    H.bar[1] = { id = IMMOLATE }
    H.bindings["ACTIONBUTTON1"] = "3"
    B.Start()
    assert.equals("3", B.Get(IMMOLATE))
    assert.equals(1, B.stats.bound)
    assert.is_false(B.dirty)
    assert.equals(0, B.stats.retried)
  end)

  -- The BAR IS POPULATED BUT THE BINDINGS ARE NOT — the specific half-loaded shape, and
  -- the one that produces the confusing symptom (a slot is seen, no key comes back).
  it("treats bound=0 as unresolved even when slots were seen", function()
    H.bar[1] = { id = IMMOLATE }        -- ...but no binding for ACTIONBUTTON1 yet
    B.Start()
    assert.equals(1, B.stats.slots)
    assert.equals(0, B.stats.bound)
    assert.is_true(B.dirty)
    assert.equals(1, B.stats.retried)
  end)

  it("resolves through the ladder once the bar finally arrives", function()
    B.Start()                            -- the early, empty scan
    assert.is_nil(B.Resolve(nil, WITHER, IMMOLATE))
    H.bar[5] = { id = WITHER }           -- Hellcaller's Wither lands on the bar
    H.bindings["ACTIONBUTTON5"] = "F"
    B.Start()                            -- stands in for the rescan the retry/event drives
    assert.equals("F", B.Resolve(nil, WITHER, IMMOLATE))
  end)

  -- THE COLD-CACHE EXEMPTION.  Field-found straight after the login-race fix: a
  -- target-dummy session is CONTINUOUS COMBAT, so `/cdmp hud status` read
  -- `0 bound / 0 slot(s), 0 scan(s), deferred 3x` — the scan had never run once and the
  -- combat exit it was waiting for was never coming.  The combat fence is a COST rule
  -- (v0.6.0 burned ~2000 scans in a city session); an empty cache has no churn to prevent.
  it("DOES scan in combat when the cache is cold — keyless beats the cost", function()
    H.bar[1] = { id = IMMOLATE }
    H.bindings["ACTIONBUTTON1"] = "3"
    H.setCombat(true)
    B.Start()
    assert.equals("3", B.Get(IMMOLATE), "a cold cache must not wait for a combat exit")
    assert.equals(1, B.stats.scans)
    assert.equals(1, B.stats.cold)
    assert.is_false(B.dirty)
  end)

  it("still defers in combat once the cache is WARM", function()
    H.bar[1] = { id = IMMOLATE }
    H.bindings["ACTIONBUTTON1"] = "3"
    B.Start()                                  -- warm it out of combat
    assert.equals(1, B.stats.scans)
    H.setCombat(true)
    H.bindings["ACTIONBUTTON1"] = "9"          -- a change we must NOT burn a scan on
    B.Start()
    assert.equals(1, B.stats.scans, "a warm cache defers — the v0.6.0 cost rule stands")
    assert.equals(0, B.stats.cold)
    assert.equals(1, B.stats.deferred)
    assert.equals("3", B.Get(IMMOLATE), "and serves the stale value meanwhile")
    assert.is_true(B.dirty)
  end)

  -- Leaving combat has to re-arm even when `dirty` was cleared by an exhausted retry run,
  -- or a session that started keyless stays keyless.
  it("re-arms on leaving combat while the cache is still cold", function()
    H.setCombat(true)
    B.Start()                                   -- cold + combat: scans, finds nothing
    B.dirty = false                             -- stand in for the retry budget running out
    H.setCombat(false)
    H.bar[1] = { id = IMMOLATE }
    H.bindings["ACTIONBUTTON1"] = "3"
    H.lastFrame():Fire("OnEvent", "PLAYER_REGEN_ENABLED")
    assert.is_true(B.dirty, "combat exit on a cold cache must owe a rescan")
  end)
end)
