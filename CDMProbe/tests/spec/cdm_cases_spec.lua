-- cdm_cases_spec.lua — the driver for the CDM EDGE INVENTORY.
--
-- One parametrised spec over `tests/fixtures/cdm-cases.lua`: a declarative corpus of
-- "CDM input -> expected State row" cases, authored from `knowledge/addon-dev/
-- cooldown-manager.md` (the client study) rather than from State.lua.  Read the fixture
-- file's header for the case schema and for what is deliberately NOT covered.
--
-- WHY A SECOND STATE SPEC AT ALL.  `state_domainview_spec` is REGRESSION-shaped — every
-- `describe` in it is named after a past bug, so its coverage tracks what has already
-- bitten us.  This file is INPUT-shaped: it asks what the Cooldown Manager can actually
-- hand us, and what State must answer.  Both are wanted; neither replaces the other.
--
-- ⚠ A SUITE THAT IS 100 % GREEN AGAINST THE CURRENT CODE IS, BY CONSTRUCTION, A SNAPSHOT.
-- The `pinned-defect` status below is what makes that structurally impossible: such a case
-- runs INVERTED — it asserts the CONTRACT answer under pcall and FAILS IF IT PASSES.  So a
-- known defect proves it is still live, and the day Phase 2 fixes it the case goes red and
-- the fix commit flips the status in its own diff.
--
-- The fixture-driven shape (a SCENARIOS table + a fmt/diff/assertEqual differ) is
-- binder_spec.lua:23-53 / :271-357.  Deliberately FORKED rather than shared: a
-- shared-helper change landing in the same commit as ~70 new cases would give any red two
-- possible causes.  Three things differ here — the ABSENT sentinel, PARTIAL descent
-- (binder_spec's key-union stays available as the `exact` opt-in), and dotted-path keys.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H  = dofile(dir .. "../mock_ns.lua")
local FX = dofile(dir .. "../fixtures/cdm-cases.lua")
local ABSENT = FX.ABSENT

--------------------------------------------------------------------------------
-- Blizzard's real category enum.  ⚠ Install the REAL VALUES, not invented ones:
-- State's `enumerate()` is first-wins over an unstable `pairs(CATEGORY_NAME)`, so which
-- name a dual-category cid lands under is decided by the numbers.  Hidden* are negative
-- and State skips them by sign (State.lua:61), which only means anything with the real
-- values in place.
--------------------------------------------------------------------------------
local CATEGORY_VALUE = {
  Essential = 0, Utility = 1, TrackedBuff = 2, TrackedBar = 3,
  HiddenSpell = -1, HiddenAura = -2,
}

--------------------------------------------------------------------------------
-- Deep, PARTIAL equality that reports the first-divergence PATH.
--------------------------------------------------------------------------------
local function fmt(v)
  if v == ABSENT then return "ABSENT" end
  if v == nil then return "nil" end
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "table" then return "<table>" end
  return tostring(v)
end

local function step(path, k)
  if type(k) == "number" then return path .. "[" .. tostring(k) .. "]" end
  return path .. "." .. tostring(k)
end

-- Resolve a dotted key ("1276452.cd.state") against the actual table.  Segments are tried
-- as strings first and then as numbers, because spellIDs are numeric keys but a fixture
-- writes them inside a string.
local function resolve(t, dotted)
  local cur = t
  for seg in string.gmatch(dotted, "[^.]+") do
    if type(cur) ~= "table" then return nil end
    local v = cur[seg]
    if v == nil then v = cur[tonumber(seg)] end
    if v == nil then return nil end
    cur = v
  end
  return cur
end

-- PARTIAL by default: only the keys the case names are compared.  Full-table equality on
-- a 20-field row makes the suite a change-detector, so equality is opt-in per view
-- (`case.exact = { raw = true }`).
local function diff(expected, actual, path, out, exact)
  if expected == ABSENT then
    -- Lua cannot distinguish an absent key from a nil value, and "we must not fabricate a
    -- value" is most of this project's contract — so the sentinel is load-bearing.
    if actual ~= nil then
      out[#out + 1] = string.format("%s: expected ABSENT, got %s", path, fmt(actual))
    end
    return out
  end
  if type(expected) ~= "table" then
    if expected ~= actual then
      out[#out + 1] = string.format("%s: expected %s, got %s", path, fmt(expected), fmt(actual))
    end
    return out
  end
  if type(actual) ~= "table" then
    out[#out + 1] = string.format("%s: expected a table, got %s", path, fmt(actual))
    return out
  end
  local keys, seen = {}, {}
  for k in pairs(expected) do keys[#keys + 1] = k; seen[k] = true end
  if exact then
    for k in pairs(actual) do if not seen[k] then keys[#keys + 1] = k end end
  end
  for _, k in ipairs(keys) do
    if type(k) == "string" and string.find(k, ".", 1, true) then
      diff(expected[k], resolve(actual, k), path .. "[" .. k .. "]", out, exact)
    else
      diff(expected[k], actual[k], step(path, k), out, exact)
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- The world -> harness installer.
--------------------------------------------------------------------------------
-- A membership map that answers FALSE (not nil) for an unasked id, so a case can write
-- `asked.cooldown = { [132411] = false }` — "you must never have asked about this one",
-- which is the only way to state defects §3.2 / §3.3 / §3.8 at all.
local FALSE_DEFAULT = { __index = function() return false end }
local function membership(list)
  local m = setmetatable({}, FALSE_DEFAULT)
  for _, v in ipairs(list) do m[v] = true end
  return m
end

local function count(list, needle)
  local n = 0
  for _, v in ipairs(list) do if v == needle then n = n + 1 end end
  return n
end

local GCD_SPELLID = 61304

local function askedView()
  return {
    -- The §3.3 assertion, whole: how many times did one pulse re-read the GCD?
    gcdCount      = count(H.asked.cooldown, GCD_SPELLID),
    cooldownCount = #H.asked.cooldown,
    chargesCount  = #H.asked.charges,
    cooldown = membership(H.asked.cooldown),
    charges  = membership(H.asked.charges),
    glow     = membership(H.asked.glow),
    auraByID = membership(H.asked.auraByID),
    known    = membership(H.asked.known),
    info     = membership(H.asked.info),
  }
end

-- One CDM item frame.  Deliberately a plain table, not H.newStub(): State probes it with
-- ns.HasMethod, so "this row does not expose IsActive at all" has to be expressible.
local function buildItem(cid, f)
  local it = {}
  if f.cooldownIDSecret then it.cooldownID = H.secretValue()
  elseif f.noCooldownID ~= true then it.cooldownID = cid end
  if f.getCooldownID ~= false then
    it.GetCooldownID = function()
      if f.getCooldownIDThrows then error("mock: GetCooldownID refused", 0) end
      return cid
    end
  end
  if f.isActive ~= nil then
    local secret = H.secretValue()
    it.IsActive = function()
      if f.isActive == "throws" then error("mock: IsActive refused", 0) end
      if f.isActive == "secret" then return secret end
      return f.isActive
    end
  end
  if f.isShown ~= nil then
    it.IsShown = function()
      if f.isShown == "throws" then error("mock: IsShown refused", 0) end
      return f.isShown
    end
  end
  if f.hideWhenInactive ~= nil and f.hideWhenInactive ~= "throws" then
    it.hideWhenInactive = f.hideWhenInactive
  end
  -- The alert choke point.  hooksecurefunc is a no-op off-game, so the hook installs and
  -- does nothing; the script drives St.OnAlert directly, exactly as the shipped hook does.
  it.TriggerAlertEvent = function() end
  if f.hideWhenInactive == "throws" then H.poison(it, { "hideWhenInactive" }) end
  return it
end

local function installCase(case)
  local ns, fx = H.fresh()
  local world = case.world or {}

  -- ⚠ SPEC ACTIVATION MUST PRECEDE H.load("State.lua").  Not because State reads the spec
  -- at load, but because activating after gives Demonology's identity opinions with
  -- Destruction's virtual candidates — a silently wrong world.  (H.setSpecIndex does not
  -- survive H.fresh(), so it has to be set here, per case.)
  H.setSpecIndex(case.spec or 1)
  ns.ResolveActiveSpec()

  H.load("State.lua")
  local St = ns.State
  local eframe = H.lastFrame()      -- State.lua's own CreateFrame("Frame"), for cast steps

  -- The live client, at client-API level.
  H.setClock(world.now or 1000)
  H.setCombat(world.combat)
  for _, name in ipairs(world.throws or {}) do H.throwOn(name) end
  for _, v in ipairs(world.secret or {}) do H.markSecret(v) end
  for k, v in pairs(world.cd or {})         do fx.cd[k] = v end
  for k, v in pairs(world.charges or {})    do fx.charges[k] = v end
  for k, v in pairs(world.auraByID or {})   do fx.auraByID[k] = v end
  for k, v in pairs(world.auraThrows or {}) do fx.auraThrows[k] = v end
  for k, v in pairs(world.glow or {})       do fx.glow[k] = v end
  for k, v in pairs(world.known or {})      do fx.known[k] = v end
  for k, v in pairs(world.baseCD or {})     do fx.baseCD[k] = v end
  for k, v in pairs(world.keybind or {})    do fx.keybind[k] = v end
  for k, v in pairs(world.napkin or {})     do fx.remain[k] = v end
  if world.auras then fx.auras = world.auras end

  _G.Enum.CooldownViewerCategory = CATEGORY_VALUE

  -- The CDM database.  ⚠ ONE memoised info table per cid — a fake building a fresh table
  -- per call could never be marked by H.markSecretTable / H.poison (both key on identity)
  -- and a secret-struct case would pass for the wrong reason.  It also happens to match
  -- Blizzard's single cached record per cooldownID (cooldown-manager.md §2.5).
  local infoByCid, byCategory, throwCids, items = {}, {}, {}, {}
  for _, r in ipairs(case.rows or {}) do
    if r.infoThrows then throwCids[r.cid] = true end
    if r.info ~= false then
      local info = {}
      for k, v in pairs(r.info or {}) do
        -- The fixture is pure data, so it marks a secret field with a shared sentinel and
        -- the driver mints the real one here.  (H.secret is keyed BY VALUE, so a per-field
        -- sentinel table is the only way to mark one field without marking every
        -- occurrence of some number across the whole case.)
        if v == FX.SECRET then v = H.secretValue()
        elseif type(v) == "table" then
          local copy = {}
          for i, e in ipairs(v) do copy[i] = (e == FX.SECRET) and H.secretValue() or e end
          v = copy
        end
        info[k] = v
      end
      if info.cooldownID == nil then info.cooldownID = r.cid end
      if r.infoSecretTable then H.markSecretTable(info) end
      if r.infoPoison then H.poison(info, r.infoPoison) end
      infoByCid[r.cid] = info
    end
    for _, name in ipairs(r.categories or { r.category }) do
      local value = CATEGORY_VALUE[name]
        or error("cdm-cases: unknown category '" .. tostring(name) .. "'")
      byCategory[value] = byCategory[value] or {}
      table.insert(byCategory[value], r.cid)
    end
    if r.frame then items[#items + 1] = buildItem(r.cid, r.frame) end
  end

  _G.C_CooldownViewer = {
    IsCooldownViewerAvailable = H.guard("C_CooldownViewer.IsCooldownViewerAvailable",
      function() return world.cdmUnavailable ~= true end),
    GetCooldownViewerCategorySet = H.guard("C_CooldownViewer.GetCooldownViewerCategorySet",
      function(value) return byCategory[value] or {} end),
    GetCooldownViewerCooldownInfo = H.guard("C_CooldownViewer.GetCooldownViewerCooldownInfo",
      function(cid)
        H.asked.info[#H.asked.info + 1] = cid
        if throwCids[cid] then error("mock: GetCooldownViewerCooldownInfo refused", 0) end
        return infoByCid[cid]
      end),
  }

  ns.VIEWERS = { { frame = "EssentialCooldownViewer", key = "essential" } }
  ns.GetViewer     = function(name)
    return name == "EssentialCooldownViewer" and { n = 1 } or nil
  end
  ns.GetItemFrames = function() return items end

  -- ⚠ GUARD 1.  ns.OnLogin() builds CATEGORY_NAME (State.lua:1596) and `enumerate()`
  -- iterates it.  Without this `cooldowns` is empty and EVERY `ABSENT` assertion passes —
  -- a green suite proving nothing.
  ns.OnLogin()
  -- ⚠ GUARD 2.  onAlert returns immediately on `St.consumers <= 0` (State.lua:654), so a
  -- case scripting six alerts without a consumer asserts six absences and passes.
  if not case.noAcquire then St.Acquire() end
  -- After Acquire, which wipes St.override (State.lua:1562).
  for k, v in pairs(world.override or {}) do St.override[k] = v end

  return ns, fx, St, eframe
end

--------------------------------------------------------------------------------
-- The script — ORDERED, because ordering is the assertion in three places.
--------------------------------------------------------------------------------
-- The same-frame refresh tie is DEFINED by the absence of an `advance` between two alerts
-- (State.lua:678-681), and napkin-vs-edge precedence by which happened last.  A
-- declarative set cannot express either.
local function runScript(case, ns, St, eframe)
  local A = _G.Enum.CooldownViewerAlertEventType
  local pulse
  for i, s in ipairs(case.script or {}) do
    if s.alert then
      local event = A[s.alert] or error("cdm-cases: unknown alert '" .. tostring(s.alert) .. "'")
      St.OnAlert({ cooldownID = s.cid }, event)
    elseif s.advance then
      H.advance(s.advance)
    elseif s.combat ~= nil then
      H.setCombat(s.combat)
    elseif s.build then
      pulse = St.Build(s.drain == true)
    elseif s.cast then
      eframe:Fire("OnEvent", s.phase == "start" and "UNIT_SPELLCAST_START"
        or "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-" .. i, s.cast)
    elseif s.override then
      eframe:Fire("OnEvent", "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED", s.override.base,
        s.override.to)
    elseif s.release then
      St.Release()
    elseif s.acquire then
      St.Acquire()
    else
      error("cdm-cases: unrecognised script step " .. i)
    end
  end
  return pulse
end

--------------------------------------------------------------------------------
-- Run one case: install, script, Build, diff every named view.
--------------------------------------------------------------------------------
local VIEWS = {
  raw       = function(p) return p.cooldowns end,
  abilities = function(p) return p.abilities end,
  dropped   = function(p) return p.dropped end,
  buffs     = function(p) return p.buffs end,
  dotEdges  = function(p) return p.dotEdges end,
  virtual   = function(p) return p.virtual end,
  edges     = function(p, St) return St.dotEdge end,   -- the RAW cid-keyed alert latch
  asked     = function() return askedView() end,
  pulse     = function(p) return p end,                -- escape hatch: combat / hero / at
}
local VIEW_ORDER = { "raw", "abilities", "dropped", "buffs", "dotEdges", "virtual",
                     "edges", "asked", "pulse" }

local function runCase(case)
  local ns, _, St, eframe = installCase(case)
  local pulse = runScript(case, ns, St, eframe)
  if pulse == nil then pulse = St.Build(false) end

  -- GUARD 1, asserted rather than assumed (see installCase).
  if #(case.rows or {}) > 0 and not case.expectsEmptyEnumeration then
    assert(next(pulse.cooldowns) ~= nil,
      "cdm-cases: the CDM database enumerated EMPTY — every ABSENT assertion below would "
      .. "pass for the wrong reason.  (ns.OnLogin / the category set / IsCooldownViewerAvailable)")
  end

  local out = {}
  local exact = case.exact or {}
  for _, view in ipairs(VIEW_ORDER) do
    local want = (case.expect or {})[view]
    if want ~= nil then
      diff(want, VIEWS[view](pulse, St), case.name .. " · " .. view, out, exact[view])
    end
  end
  if #out > 0 then
    table.sort(out)
    error("\n    " .. table.concat(out, "\n    ")
      .. "\n\n    WHY: " .. case.pins .. "\n    REF: " .. case.ref .. "\n", 2)
  end
  return pulse
end

--------------------------------------------------------------------------------
-- Meta-tests — a coverage floor a later commit cannot quietly gut.
--------------------------------------------------------------------------------
describe("cdm-cases corpus", function()
  local all = {}
  for _, group in ipairs(FX.groups) do
    for _, c in ipairs(group.cases) do all[#all + 1] = { group = group, case = c } end
  end

  it("every case name is unique", function()
    local seen = {}
    for _, e in ipairs(all) do
      assert.is_nil(seen[e.case.name], "duplicate case name: " .. tostring(e.case.name))
      seen[e.case.name] = true
    end
  end)

  it("every case carries a non-empty `pins` and `ref`", function()
    for _, e in ipairs(all) do
      assert.is_true(type(e.case.pins) == "string" and #e.case.pins > 0,
        (e.case.name or "?") .. " has no pins")
      assert.is_true(type(e.case.ref) == "string" and #e.case.ref > 0,
        (e.case.name or "?") .. " has no ref")
    end
  end)

  it("no `ref` points at State.lua — that would be characterisation wearing a contract's clothes", function()
    -- A case justified only by State's own code is characterisation; `pins` must say so in
    -- words, and `ref` still has to name the external thing it is measured against.
    for _, e in ipairs(all) do
      assert.is_nil(string.find(e.case.ref, "State.lua", 1, true),
        e.case.name .. " refs State.lua")
    end
  end)

  it("every pinned-defect names the Phase-2 section that fixes it", function()
    for _, e in ipairs(all) do
      if e.case.status == "pinned-defect" then
        assert.is_true(type(e.case.fixes) == "string" and #e.case.fixes > 0,
          e.case.name .. " is a pinned-defect with no `fixes`")
      end
    end
  end)

  it("every case has a known status", function()
    local ok = { green = true, ["pinned-defect"] = true, unreachable = true }
    for _, e in ipairs(all) do
      assert.is_true(ok[e.case.status] == true,
        (e.case.name or "?") .. " has status " .. tostring(e.case.status))
    end
  end)

  it("cooldownIDs are unique WITHIN a case", function()
    for _, e in ipairs(all) do
      local seen = {}
      for _, r in ipairs(e.case.rows or {}) do
        assert.is_nil(seen[r.cid], e.case.name .. " reuses cid " .. tostring(r.cid))
        seen[r.cid] = true
      end
    end
  end)

  it("a case carrying an override field names its spec", function()
    -- ns.DisplayIdentity consults ns.SpecInfo (Viewers.lua:151-165), so the expected
    -- identity depends on which spec is active.  A silent default is a case passing for
    -- the wrong reason.
    for _, e in ipairs(all) do
      local needsSpec = next(e.case.world and e.case.world.override or {}) ~= nil
      for _, r in ipairs(e.case.rows or {}) do
        local i = r.info
        if type(i) == "table" and (i.overrideSpellID or i.overrideTooltipSpellID) then
          needsSpec = true
        end
      end
      if needsSpec then
        assert.is_true(type(e.case.spec) == "number", e.case.name .. " has an override but no `spec`")
      end
    end
  end)

  it("each axis meets its coverage floor", function()
    -- The floor exists so a later commit cannot quietly gut an axis.  Raise a number when
    -- an axis genuinely grows; never lower one to make a red go away.
    local FLOOR = { A = 6, B = 11, G = 5 }
    local n = {}
    for _, group in ipairs(FX.groups) do
      local axis = string.sub(group.name, 1, 1)
      n[axis] = (n[axis] or 0) + #group.cases
    end
    for axis, floor in pairs(FLOOR) do
      assert.is_true((n[axis] or 0) >= floor,
        "axis " .. axis .. " has " .. tostring(n[axis] or 0) .. " cases, floor is " .. floor)
    end
  end)

  it("at least one case FAILS today — a 100%-green corpus is a snapshot", function()
    local pinned = 0
    for _, e in ipairs(all) do
      if e.case.status == "pinned-defect" then pinned = pinned + 1 end
    end
    assert.is_true(pinned >= 4, "only " .. pinned .. " pinned defects")
  end)
end)

--------------------------------------------------------------------------------
-- The inventory itself.  busted's output IS the table.
--------------------------------------------------------------------------------
for _, group in ipairs(FX.groups) do
  describe(group.name, function()
    after_each(function()
      -- Both ends of the leak: H.fresh() re-installs the globals AND the driver restores
      -- what it added.  Neither alone (mock_ns' installGlobals header).
      _G.C_CooldownViewer = nil
      _G.Enum.CooldownViewerCategory = nil
    end)

    for _, case in ipairs(group.cases) do
      if case.status == "unreachable" then
        pending(case.name .. " — " .. case.pins .. " [" .. case.ref .. "]")
      elseif case.status == "pinned-defect" then
        -- INVERTED.  The case asserts the CONTRACT answer; the defect is live, so it must
        -- fail.  If it PASSES, either Phase 2 landed (flip the status in that same diff)
        -- or the defect analysis was wrong and has to be re-derived.
        it(case.name .. "  [pinned-defect → " .. case.fixes .. "]", function()
          local ok = pcall(runCase, case)
          if ok then
            error("\n    PINNED DEFECT PASSED — it no longer reproduces.\n"
              .. "    If " .. case.fixes .. " just landed, flip this case's status to"
              .. " \"green\" in the same diff.\n"
              .. "    Otherwise the defect analysis is wrong and must be re-derived before"
              .. " Phase 2 is written.\n\n"
              .. "    WHY: " .. case.pins .. "\n    REF: " .. case.ref .. "\n", 2)
          end
        end)
      else
        it(case.name, function() runCase(case) end)
      end
    end
  end)
end
