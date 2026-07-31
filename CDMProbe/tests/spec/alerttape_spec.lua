-- alerttape_spec.lua — ⚠ DELETE WITH AlertTape.lua.
--
-- Scoped deliberately to ONE property: that a build swap cannot merge two builds' rows.
-- This is not a full spec for the tape (it is a temporary instrument on its way out); it
-- exists because the capture it is about to take is meant to be its LAST, and an ambiguous
-- capture means re-flying rather than deleting the file.
--
-- THE BUG IT PINS.  Both channels dedup by a key built from `cid`, and the tape keeps
-- recording across a spec swap when there is no /reload — so a cooldownID shared between
-- two specs had its counts SUMMED ACROSS BUILDS under one row, silently.  "Fired 14x" would
-- be 9 on one build plus 5 on the other, and nothing said so.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("AlertTape build separation", function()
  local ns, T
  local CID = 133441

  local function rowsOf(store)
    local out = {}
    for _, r in pairs(store) do out[#out + 1] = r end
    table.sort(out, function(a, b) return tostring(a.build) < tostring(b.build) end)
    return out
  end

  before_each(function()
    ns = H.fresh()
    H.load("State.lua")        -- the tape reads the hero tree through State
    H.load("AlertTape.lua")
    T = ns.AlertTape
    ns.db = { alerttape = {}, alerttape_on = true }
    T.session = nil
    _G.date = function() return "2026-07-31 20:00:00" end
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return 58 end }
  end)
  after_each(function() _G.C_ClassTalents = nil end)

  -- Drive Record the way State's hook does: a resolved cid + a non-secret event.
  local function alert(cid)
    T.Record({ cooldownID = cid }, _G.Enum.CooldownViewerAlertEventType.PandemicTime, cid)
  end

  -- Swap the hero tree the way the client does, and let State's always-on cache frame see
  -- it — the same path a real respec takes.
  local function swapHero(sub)
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return sub end }
    for _, f in ipairs(H.frames) do f:Fire("OnEvent", "TRAIT_CONFIG_UPDATED") end
  end

  it("stamps the build on every event row", function()
    alert(CID)
    local rows = rowsOf(T.session.events)
    assert.equals(1, #rows)
    assert.equals("Demonology/hellcaller", rows[1].build)
  end)

  it("does NOT merge one cooldownID's counts across two hero trees", function()
    -- The whole point.  Same cid, same event, same combat state — and before the build went
    -- into the dedup key these collapsed into a single row reading n=3.
    alert(CID); alert(CID)
    swapHero(59)
    alert(CID)
    local rows = rowsOf(T.session.events)
    assert.equals(2, #rows)
    assert.equals("Demonology/diabolist", rows[1].build)
    assert.equals(1, rows[1].n)
    assert.equals("Demonology/hellcaller", rows[2].build)
    assert.equals(2, rows[2].n)
  end)

  it("does NOT merge across a SPEC swap either", function()
    alert(CID)
    H.setSpecIndex(3); ns.ResolveActiveSpec()      -- Demonology -> Destruction
    alert(CID)
    local rows = rowsOf(T.session.events)
    assert.equals(2, #rows)
    assert.equals("Demonology/hellcaller", rows[1].build)   -- sorted: "Demo" < "Dest"
    assert.equals("Destruction/hellcaller", rows[2].build)
  end)

  it("keeps the field-probe channel separated the same way", function()
    alert(CID)
    swapHero(59)
    alert(CID)
    local builds = {}
    for _, r in pairs(T.session.fields) do builds[r.build] = true end
    assert.is_true(builds["Demonology/hellcaller"])
    assert.is_true(builds["Demonology/diabolist"])
  end)

  it("re-takes the eligibility baseline when the build changes, unprompted", function()
    -- Without a baseline for the NEW build, "PandemicTime never appeared" is unreadable
    -- there — you cannot tell "it fired and we missed it" from "never eligible".  The step
    -- you have to remember is the step you skip, so it is automatic.
    ns.VIEWERS = { { frame = "EssentialCooldownViewer", label = "Essential" } }
    ns.GetViewer     = function() return { n = 1 } end
    ns.GetItemFrames = function() return { { cooldownID = CID } } end
    _G.C_CooldownViewer = { GetValidAlertTypes = function() return { 2 } end,
                            GetCooldownViewerCooldownInfo = function() return { spellID = 157736 } end }
    alert(CID)
    swapHero(59)
    alert(CID)
    local builds = {}
    for _, r in pairs(T.session.elig) do builds[r.build] = true end
    assert.is_true(builds["Demonology/hellcaller"])
    assert.is_true(builds["Demonology/diabolist"], "the new build got no eligibility baseline")
    _G.C_CooldownViewer = nil
  end)

  it("records nothing at all while the tape is off", function()
    -- The control: shipping this costs one boolean test per alert, and that has to be true.
    ns.db.alerttape_on = nil
    T.session = nil
    alert(CID)
    assert.is_nil(T.session)
  end)
end)
