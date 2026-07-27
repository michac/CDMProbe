-- binder_spec.lua — the W4 Phase-4 arbiter for the Binder (Guidance + Layout ->
-- DrawList).  Three families:
--
--   * cues (4b)         — the layout-gated geometry/keybind merge: corner geometry,
--                         emphasis pass-through, keybind-by-spellID, glow rule, and
--                         the DROP of a cue whose cooldownID isn't displayed.
--   * panel/bar (4c)    — sequence -> panel rows, resourceBar -> centred pip bar.
--   * close-the-loop (4d) — the payoff: feed each golden's guidance.json + a Layout
--                         and keybind map DERIVED FROM the same golden's state.json
--                         through Binder:Bind, and assert the DrawList EQUALS the
--                         Renderer's `/cdmp rendertest` fixture for that scenario.
--                         Coach golden -> Binder -> the exact DrawList the Renderer
--                         was dialled in against.  The fixture uses "fake1..N" icon
--                         handles; the Binder uses cooldownIDs, so cues are matched
--                         as a SET keyed by anchorTo through a per-scenario handle
--                         map (the Renderer keys by anchorTo too — order is moot).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")
local FIX = dofile(dir .. "../json_fixture.lua")

--------------------------------------------------------------------------------
-- Deep equality that reports the first-divergence PATH (a RED points at the field).
--------------------------------------------------------------------------------
local function fmt(v)
  if v == nil then return "nil" end
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

local function diff(expected, actual, path, out)
  path = path or ""
  out = out or {}
  if type(expected) ~= "table" or type(actual) ~= "table" then
    if expected ~= actual then
      out[#out + 1] = string.format("%s: expected %s, got %s", path, fmt(expected), fmt(actual))
    end
    return out
  end
  local seen = {}
  for k in pairs(expected) do seen[k] = true end
  for k in pairs(actual) do seen[k] = true end
  for k in pairs(seen) do
    diff(expected[k], actual[k], path .. "." .. tostring(k), out)
  end
  return out
end

local function assertEqual(expected, actual, label)
  local out = diff(expected, actual, label or "")
  if #out > 0 then
    table.sort(out)
    error("\n    " .. table.concat(out, "\n    "), 2)
  end
end

-- Cues are an unordered SET keyed by anchorTo (the Renderer consumes them that way).
local function byAnchor(cues)
  local m = {}
  for _, c in ipairs(cues or {}) do m[c.anchorTo] = c end
  return m
end

describe("Binder:Bind — Guidance + Layout -> DrawList", function()
  local ns, Binder

  -- A keybind seam from a plain spellID->key map (the fixture stand-in for HudBinds).
  local function keybindsFrom(map)
    return function(spellID) return map[spellID] end
  end

  before_each(function()
    ns = H.fresh()
    H.load("HudGeometry.lua")
    H.load("Binder.lua")
    Binder = ns.Binder
  end)

  ------------------------------------------------------------------------------
  -- 4b — cues
  ------------------------------------------------------------------------------
  describe("cues", function()
    it("stamps corner geometry + emphasis + keybind + glow for a displayed cue", function()
      local b = Binder.New({ keybindFor = keybindsFrom({ [105174] = "R" }) })
      local drawList = b:Bind(
        { cues = { ["34991"] = { draw = true, emphasis = "ROTATION" } } },
        { ["34991"] = { spellID = 105174 } })

      assert.are.equal(1, #drawList.cues)
      assertEqual({
        anchorTo = "34991", point = "TOPRIGHT", relPoint = "TOPRIGHT",
        dx = -3, dy = -3, size = 12, emphasis = "ROTATION", keybind = "R", glow = true,
      }, drawList.cues[1], "cue")
    end)

    it("drops a cue whose cooldownID is not in the layout", function()
      local b = Binder.New({ keybindFor = keybindsFrom({}) })
      local drawList = b:Bind(
        { cues = {
            ["34991"] = { draw = true, emphasis = "ROTATION" },   -- displayed
            ["671"]   = { draw = true, emphasis = "JUDGE" },      -- NOT in layout
          } },
        { ["34991"] = { spellID = 105174 } })

      local m = byAnchor(drawList.cues)
      assert.is_not_nil(m["34991"])
      assert.is_nil(m["671"])          -- dropped: the CDM isn't showing that icon
    end)

    it("glows only the press-level emphases (ROTATION/LATE), not JUDGE/SOON/SEQUENCE", function()
      local b = Binder.New({ keybindFor = keybindsFrom({}) })
      local layout = {
        ["1"] = { spellID = 1 }, ["2"] = { spellID = 2 }, ["3"] = { spellID = 3 },
        ["4"] = { spellID = 4 }, ["5"] = { spellID = 5 },
      }
      local drawList = b:Bind({ cues = {
        ["1"] = { draw = true, emphasis = "ROTATION" },
        ["2"] = { draw = true, emphasis = "LATE" },
        ["3"] = { draw = true, emphasis = "SOON" },
        ["4"] = { draw = true, emphasis = "JUDGE" },
        ["5"] = { draw = true, emphasis = "SEQUENCE" },
      } }, layout)
      local m = byAnchor(drawList.cues)
      assert.is_true(m["1"].glow)
      assert.is_true(m["2"].glow)
      assert.is_nil(m["3"].glow)
      assert.is_nil(m["4"].glow)
      assert.is_nil(m["5"].glow)
    end)

    it("carries no keybind when the spell is unbound (never a placeholder)", function()
      local b = Binder.New({ keybindFor = keybindsFrom({}) })   -- nothing bound
      local drawList = b:Bind(
        { cues = { ["34991"] = { draw = true, emphasis = "ROTATION" } } },
        { ["34991"] = { spellID = 105174 } })
      assert.is_nil(drawList.cues[1].keybind)
    end)

    it("passes the emphasis token through without resolving colour", function()
      local b = Binder.New({ keybindFor = keybindsFrom({}) })
      local drawList = b:Bind(
        { cues = { ["671"] = { draw = true, emphasis = "JUDGE" } } },
        { ["671"] = { spellID = 104316 } })
      assert.are.equal("JUDGE", drawList.cues[1].emphasis)
      assert.is_nil(drawList.cues[1].color)   -- colour stays the Renderer's job
    end)

    it("respects an explicit draw=false", function()
      local b = Binder.New({ keybindFor = keybindsFrom({}) })   -- nothing bound
      local drawList = b:Bind(
        { cues = { ["34991"] = { draw = false, emphasis = "ROTATION" } } },
        { ["34991"] = { spellID = 105174 } })
      assert.are.equal(0, #drawList.cues)   -- no emphasis, no keybind -> nothing
    end)

    -- P5d — empty cues: a keybind rides EVERY displayed icon, cued or not.
    it("emits a keybind-only (empty) cue for a displayed icon the Coach didn't signal", function()
      local b = Binder.New({ keybindFor = keybindsFrom({ [686] = "Q", [105174] = "R" }) })
      local drawList = b:Bind(
        { cues = { ["34991"] = { draw = true, emphasis = "ROTATION" } } },   -- only HoG cued
        { ["34991"] = { spellID = 105174 }, ["34990"] = { spellID = 686 } }) -- SB displayed too
      local m = byAnchor(drawList.cues)
      -- HoG: a full cue.
      assert.are.equal("ROTATION", m["34991"].emphasis)
      assert.are.equal("R", m["34991"].keybind)
      -- SB: an empty cue — key hint, no emphasis, no glow.
      assert.is_not_nil(m["34990"])
      assert.is_nil(m["34990"].emphasis)
      assert.is_nil(m["34990"].glow)
      assert.are.equal("Q", m["34990"].keybind)
    end)

    it("still draws a keybind-only cue for an icon whose Coach cue is draw=false", function()
      local b = Binder.New({ keybindFor = keybindsFrom({ [105174] = "R" }) })
      local drawList = b:Bind(
        { cues = { ["34991"] = { draw = false, emphasis = "ROTATION" } } },
        { ["34991"] = { spellID = 105174 } })
      assert.are.equal(1, #drawList.cues)
      assert.is_nil(drawList.cues[1].emphasis)     -- draw=false demotes to no dot...
      assert.are.equal("R", drawList.cues[1].keybind)  -- ...but the key still rides
    end)

    it("omits a displayed icon with neither emphasis nor keybind", function()
      local b = Binder.New({ keybindFor = keybindsFrom({}) })   -- unbound
      local drawList = b:Bind({ cues = {} }, { ["34990"] = { spellID = 686 } })
      assert.are.equal(0, #drawList.cues)
    end)

    -- P5d fix — the layout's OWN keybind (State-resolved, stitched by the driver) wins
    -- over the cfg seam, so a divergent re-lookup can't override State's correct value.
    it("prefers the layout's State-resolved keybind over the cfg seam", function()
      local b = Binder.New({ keybindFor = keybindsFrom({ [105174] = "WRONG" }) })
      local drawList = b:Bind(
        { cues = { ["34991"] = { draw = true, emphasis = "ROTATION" } } },
        { ["34991"] = { spellID = 105174, keybind = "R" } })   -- State said R
      assert.are.equal("R", byAnchor(drawList.cues)["34991"].keybind)
    end)

    it("draws a keybind-only cue straight from the layout keybind (no seam, no emphasis)", function()
      local b = Binder.New({})   -- no seam at all, mirroring the live driver
      local drawList = b:Bind(
        { cues = {} },
        { ["671"] = { spellID = 104316, keybind = "E" } })   -- State-stitched Dreadstalkers
      local m = byAnchor(drawList.cues)
      assert.is_nil(m["671"].emphasis)
      assert.are.equal("E", m["671"].keybind)
    end)
  end)

  ------------------------------------------------------------------------------
  -- 4c — panel + resourceBar
  ------------------------------------------------------------------------------
  describe("panel", function()
    it("maps a shown sequence to a self-anchored titled step list", function()
      local b = Binder.New({})
      local drawList = b:Bind({ sequence = {
        show = true, title = "OPENER", cursor = 1,
        steps = {
          { spellID = 104316, label = "Dreadstalkers", keybind = "E", state = "done" },
          { spellID = 265187, label = "Tyrant", keybind = "sQ", state = "active", note = "now" },
        },
      } }, {})

      local p = drawList.panel
      assert.is_not_nil(p)
      assert.are.equal("UIPARENT", p.anchorTo)
      assert.are.equal("TOP", p.point)
      assert.are.equal(0, p.dx)
      assert.are.equal(-200, p.dy)
      assert.are.equal("OPENER", p.title)
      assertEqual({
        { label = "Dreadstalkers", keybind = "E", state = "done" },
        { label = "Tyrant", keybind = "sQ", state = "active" },   -- note NOT carried (v1)
      }, p.steps, "panel.steps")
    end)

    it("omits the panel when the sequence is not shown", function()
      local b = Binder.New({})
      assert.is_nil(b:Bind({ sequence = { show = false } }, {}).panel)
      assert.is_nil(b:Bind({}, {}).panel)
    end)
  end)

  describe("resourceBar", function()
    it("passes value/max/powerType through and centres the pip row", function()
      local b = Binder.New({})
      local bar = b:Bind({ resourceBar = {
        value = 3, max = 5, incoming = 0, display = "discrete", powerType = "SOUL_SHARDS",
      } }, {}).resourceBar

      assert.are.equal("UIPARENT", bar.anchorTo)
      assert.are.equal("CENTER", bar.point)
      assert.are.equal(3, bar.value)
      assert.are.equal(5, bar.max)
      assert.are.equal("SOUL_SHARDS", bar.powerType)
      -- centred: width = 5*14 + 4*4 = 86, dx = -43; dy = -18.
      assert.are.equal(-43, bar.dx)
      assert.are.equal(-18, bar.dy)
      assert.is_nil(bar.incoming)   -- v1 pip bar doesn't render a projection yet
      assert.is_nil(bar.display)
    end)

    it("omits the bar when Guidance carries none", function()
      assert.is_nil(Binder.New({}):Bind({}, {}).resourceBar)
    end)
  end)

  ------------------------------------------------------------------------------
  -- 4d — close the loop: golden Guidance -> Binder -> the rendertest fixture.
  ------------------------------------------------------------------------------
  describe("closes the loop against the rendertest fixtures", function()
    local Fixtures

    before_each(function()
      H.load("Renderer.lua")           -- defines ns.RenderTestFixtures
      Fixtures = ns.RenderTestFixtures
    end)

    -- Displayed handles = the Essential-category icons (the CDM's pressable row).
    -- The Layout carries each displayed cooldownID -> its spellID (the id bridge).
    local function layoutFromState(state)
      local layout = {}
      for cid, cd in pairs(state.cooldowns or {}) do
        if cd.category == "Essential" then layout[cid] = { spellID = cd.spellID } end
      end
      return layout
    end

    -- The keybind seam, built from the SAME golden state (spellID -> keybind).
    local function keybindsFromState(state)
      local map = {}
      for _, cd in pairs(state.cooldowns or {}) do
        if cd.spellID and cd.keybind then map[cd.spellID] = cd.keybind end
      end
      return keybindsFrom(map)
    end

    -- fake<N> (fixture handle) -> cooldownID (Binder handle), per scenario.  The
    -- fixture author mapped each golden cue onto an icon; this is the inverse.
    local HANDLE_MAP = {
      ["opener-midflight"] = { fake1 = "34990", fake2 = "2742" },
      ["burst-hold"]       = { fake1 = "34991", fake2 = "671", fake3 = "149122" },
      ["secrecy-combat"]   = { fake1 = "1979", fake2 = "2742" },
    }

    -- The fixture cues keyed by their MAPPED cooldownID, so they line up with the
    -- Binder's anchorTo.
    local function expectedCues(scenario)
      local map = HANDLE_MAP[scenario]
      local m = {}
      for _, c in ipairs(Fixtures[scenario].drawList.cues or {}) do
        local cid = map[c.anchorTo] or error("no handle map for " .. tostring(c.anchorTo))
        local copy = {}
        for k, v in pairs(c) do copy[k] = v end
        copy.anchorTo = cid
        m[cid] = copy
      end
      return m
    end

    for _, scenario in ipairs({ "opener-midflight", "burst-hold", "secrecy-combat" }) do
      it(scenario, function()
        local state = FIX.state(scenario)
        local guidance = FIX.guidance(scenario)
        local b = Binder.New({ keybindFor = keybindsFromState(state) })

        local drawList = b:Bind(guidance, layoutFromState(state))
        local fixture = Fixtures[scenario].drawList

        -- The Binder now also emits keybind-only (empty) cues for displayed icons the
        -- Coach didn't signal (P5d); the rendertest fixtures carry only the emphasis-
        -- bearing dots, so compare that subset. (The empty-cue path has its own tests.)
        local dots = {}
        for _, c in ipairs(drawList.cues) do if c.emphasis then dots[#dots + 1] = c end end
        assertEqual(expectedCues(scenario), byAnchor(dots), scenario .. ".cues")
        assertEqual(fixture.panel, drawList.panel, scenario .. ".panel")
        assertEqual(fixture.resourceBar, drawList.resourceBar, scenario .. ".resourceBar")
      end)
    end
  end)
end)
