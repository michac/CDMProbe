-- renderer_spec.lua — Stage 4 off-game gate (W4 Phase 3).  A hand-authored
-- DrawList drives the Renderer through the RECORDING CreateFrame stub (mock_ns),
-- and we assert on what each frame was TOLD: per-handle colour, position, size,
-- shown-state, and the panel rows.  No real pixels — the harness IS the lift.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

-- Approximate-equality for colour triples (the theme values are exact, but guard
-- against float surprises from any future derivation).
local function near(a, b) return math.abs(a - b) < 1e-6 end
local function colorEq(c, r, g, b)
  return c and near(c[1], r) and near(c[2], g) and near(c[3], b)
end

describe("Renderer", function()
  local Rr, theme, summon

  before_each(function()
    local ns = H.fresh()
    H.load("Renderer.lua")
    Rr = ns.Renderer
    summon = ns.SpecGroups.summon
    theme = {
      ROTATION = { 0.30, 1.00, 0.48 },
      LATE     = { 0.42, 1.00, 0.58 },
      SOON     = { 1.00, 0.86, 0.15 },
      JUDGE    = { 0.27, 0.88, 1.00 },
      SEQUENCE = summon,
    }
  end)

  -- A renderer with N placeholder icon frames registered under "fake1".."fakeN".
  local function rigged(n)
    local r = Rr.New()
    local icons = {}
    for i = 1, n do
      local f = H.newStub()
      icons[i] = f
      r:Register("fake" .. i, f)
    end
    return r, icons
  end

  ------------------------------------------------------------------------------
  -- Factory + theme
  ------------------------------------------------------------------------------
  it("resolves the SEQUENCE token to the summon fel-green from ns.SpecGroups", function()
    local r = Rr.New()
    assert.is_true(colorEq(r.theme.SEQUENCE, summon[1], summon[2], summon[3]))
  end)

  it("takes an injected theme through cfg", function()
    local r = Rr.New({ theme = { ROTATION = { 1, 0, 0, 1 } } })
    assert.is_true(colorEq(r.theme.ROTATION, 1, 0, 0))
  end)

  ------------------------------------------------------------------------------
  -- 3b — cue dots
  ------------------------------------------------------------------------------
  it("paints one ROTATION dot under its handle at the given point + size", function()
    local r, icons = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", point = "CENTER", relPoint = "CENTER",
                        dx = 0, dy = -28, size = 12, emphasis = "ROTATION" } } })
    local dot = r.cueFrames["fake1"]
    assert.is_true(colorEq(dot._color, theme.ROTATION[1], theme.ROTATION[2], theme.ROTATION[3]))
    assert.same({ 12, 12 }, dot._size)
    assert.is_true(dot._shown)
    local pt = dot._points[1]
    assert.equals("CENTER", pt.point)
    assert.equals(icons[1], pt.rel)          -- anchored to the registered frame
    assert.equals(-28, pt.dy)
  end)

  it("colours each cue by its own emphasis token (ROTATION + 2 JUDGE)", function()
    local r = rigged(3)
    r:Draw({ cues = {
      { anchorTo = "fake1", emphasis = "ROTATION" },
      { anchorTo = "fake2", emphasis = "JUDGE" },
      { anchorTo = "fake3", emphasis = "JUDGE" },
    } })
    assert.is_true(colorEq(r.cueFrames["fake1"]._color, theme.ROTATION[1], theme.ROTATION[2], theme.ROTATION[3]))
    assert.is_true(colorEq(r.cueFrames["fake2"]._color, theme.JUDGE[1], theme.JUDGE[2], theme.JUDGE[3]))
    assert.is_true(colorEq(r.cueFrames["fake3"]._color, theme.JUDGE[1], theme.JUDGE[2], theme.JUDGE[3]))
  end)

  it("defaults size to 12 and point to CENTER when omitted", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "SOON" } } })
    local dot = r.cueFrames["fake1"]
    assert.same({ 12, 12 }, dot._size)
    assert.equals("CENTER", dot._points[1].point)
  end)

  it("hides a handle that dropped out of the next DrawList (diff-by-key)", function()
    local r = rigged(2)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" },
                      { anchorTo = "fake2", emphasis = "JUDGE" } } })
    assert.is_true(r.cueFrames["fake1"]._shown)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.is_true(r.cueFrames["fake1"]._shown)
    assert.is_false(r.cueFrames["fake2"]._shown)   -- hidden, not destroyed
  end)

  it("reuses the same dot frame across redraws for a stable handle", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    local first = r.cueFrames["fake1"]
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "SOON" } } })
    assert.equals(first, r.cueFrames["fake1"])
    assert.is_true(colorEq(first._color, theme.SOON[1], theme.SOON[2], theme.SOON[3]))
  end)

  it("draws nothing for an unknown emphasis token (never guess a colour)", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "MADE_UP" } } })
    assert.is_nil(r.cueFrames["fake1"])
  end)

  it("no cues => nothing drawn, no error", function()
    local r = rigged(1)
    assert.has_no.errors(function() r:Draw({}) end)
  end)

  ------------------------------------------------------------------------------
  -- 3c — sequence panel
  ------------------------------------------------------------------------------
  local OPENER = {
    anchorTo = "UIPARENT", point = "TOP", dx = 0, dy = -200, title = "OPENER",
    steps = {
      { label = "Dreadstalkers", keybind = "E",  state = "done" },
      { label = "Summon Demonic Tyrant", keybind = "sQ", state = "active" },
      { label = "Hand of Gul'dan", keybind = "R", state = "pending" },
      { label = "Hand of Gul'dan", keybind = "R", state = "blocked" },
      { label = "Implosion", keybind = "1", state = "skipped" },
    },
  }

  it("shows the panel with a title and one row per step", function()
    local r = rigged(1)
    r:Draw({ panel = OPENER })
    local p = r.panelWidget
    assert.equals("OPENER", p.title:GetText())
    assert.is_true(p.frame._shown)
    assert.equals(5, #p.rows)
    for i = 1, 5 do assert.is_true(p.rows[i]._shown) end
  end)

  it("formats each row as '<state>  <keybind>  <label>' and tints by state", function()
    local r = rigged(1)
    r:Draw({ panel = OPENER })
    local rows = r.panelWidget.rows
    assert.equals("done  E  Dreadstalkers", rows[1]:GetText())
    assert.equals("active  sQ  Summon Demonic Tyrant", rows[2]:GetText())
    assert.is_true(colorEq(rows[2]._textColor, 0.30, 1.00, 0.48))   -- active = bright green
    assert.is_true(colorEq(rows[4]._textColor, 1.00, 0.42, 0.35))   -- blocked = red
  end)

  it("hides the panel when the next DrawList carries none", function()
    local r = rigged(1)
    r:Draw({ panel = OPENER })
    assert.is_true(r.panelWidget.frame._shown)
    r:Draw({})
    assert.is_false(r.panelWidget.frame._shown)
  end)

  it("shrinks the visible row set when a later panel has fewer steps", function()
    local r = rigged(1)
    r:Draw({ panel = OPENER })                                  -- 5 rows
    r:Draw({ panel = { title = "SHORT", steps = {
      { label = "A", keybind = "1", state = "active" } } } })   -- 1 row
    local rows = r.panelWidget.rows
    assert.is_true(rows[1]._shown)
    for i = 2, 5 do assert.is_false(rows[i]._shown) end
  end)

  it("anchors the panel to the UIPARENT root token", function()
    local r = rigged(1)
    r:Draw({ panel = OPENER })
    local pt = r.panelWidget.frame._points[1]
    assert.equals(r.registry.UIPARENT, pt.rel)
    assert.equals("TOP", pt.point)
    assert.equals(-200, pt.dy)
  end)

  ------------------------------------------------------------------------------
  -- 3d — resource bar
  ------------------------------------------------------------------------------
  local function shardCol(r) return r.powerColor.SOUL_SHARDS end

  it("draws `max` pips with `value` filled in the powerType colour", function()
    local r = rigged(1)
    r:Draw({ resourceBar = { anchorTo = "UIPARENT", point = "BOTTOM",
                             value = 3, max = 5, powerType = "SOUL_SHARDS" } })
    assert.equals(5, #r.pips)
    local col, filled = shardCol(r), 0
    for i = 1, 5 do
      if colorEq(r.pips[i]._color, col[1], col[2], col[3]) then filled = filled + 1 end
      assert.is_true(r.pips[i]._shown)
    end
    assert.equals(3, filled)
  end)

  it("hides surplus pips when a later bar has a smaller max", function()
    local r = rigged(1)
    r:Draw({ resourceBar = { value = 3, max = 5, powerType = "SOUL_SHARDS" } })
    r:Draw({ resourceBar = { value = 1, max = 2, powerType = "SOUL_SHARDS" } })
    assert.is_true(r.pips[1]._shown)
    assert.is_true(r.pips[2]._shown)
    for i = 3, 5 do assert.is_false(r.pips[i]._shown) end
  end)

  it("hides the whole bar when the next DrawList carries none", function()
    local r = rigged(1)
    r:Draw({ resourceBar = { value = 3, max = 5, powerType = "SOUL_SHARDS" } })
    r:Draw({})
    for i = 1, 5 do assert.is_false(r.pips[i]._shown) end
  end)

  ------------------------------------------------------------------------------
  -- The whole DrawList together (a burst-hold shape: ROTATION + 2 JUDGE + bar)
  ------------------------------------------------------------------------------
  it("draws cues + bar from one DrawList without cross-talk", function()
    local r = rigged(3)
    r:Draw({
      cues = {
        { anchorTo = "fake1", emphasis = "ROTATION" },
        { anchorTo = "fake2", emphasis = "JUDGE" },
        { anchorTo = "fake3", emphasis = "JUDGE" },
      },
      resourceBar = { value = 3, max = 5, powerType = "SOUL_SHARDS" },
    })
    assert.is_true(r.cueFrames["fake1"]._shown)
    assert.is_true(r.cueFrames["fake2"]._shown)
    assert.is_true(r.cueFrames["fake3"]._shown)
    assert.is_nil(r.panelWidget)          -- no panel authored => never built
    assert.equals(5, #r.pips)
  end)
end)
