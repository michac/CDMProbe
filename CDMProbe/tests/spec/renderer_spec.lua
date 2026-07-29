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
  local Rr, theme

  before_each(function()
    local ns = H.fresh()
    H.load("HudGeometry.lua")        -- Renderer's fixtures + pip layout read it
    H.load("Renderer.lua")
    Rr = ns.Renderer
    theme = Rr.New().theme          -- the real defaults, so assertions never drift
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
  it("resolves the DISTINCT emphasis tokens to glanceable, separable colours", function()
    -- ROTATION_FALLBACK is DELIBERATELY excluded: it is a dim green in ROTATION's own
    -- family (subordinate by brightness, not a distinct hue), so it must NOT satisfy the
    -- separation bound below.  Its subordination is asserted by its own test instead.
    local t = Rr.New().theme
    local toks = { "ROTATION", "LATE", "SOON", "JUDGE", "SEQUENCE" }
    for i = 1, #toks do
      for j = i + 1, #toks do
        local a, b = t[toks[i]], t[toks[j]]
        local dist = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3])
        assert.is_true(dist > 0.30, toks[i] .. " and " .. toks[j] .. " are too similar (" .. dist .. ")")
      end
    end
  end)

  it("gives ROTATION_FALLBACK a dim green in ROTATION's family (subordinate, not distinct)", function()
    local t = Rr.New().theme
    local rot, fb = t.ROTATION, t.ROTATION_FALLBACK
    assert.is_not_nil(fb, "ROTATION_FALLBACK missing from the theme (would render as an empty cue)")
    -- Same hue family: close to ROTATION (the opposite of the >0.30 separation bound).
    local dist = math.abs(rot[1] - fb[1]) + math.abs(rot[2] - fb[2]) + math.abs(rot[3] - fb[3])
    assert.is_true(dist < 0.75, "fallback should read as related to ROTATION, not a new hue")
    -- Subordinate: dimmer overall than the real press.
    assert.is_true(fb[1] + fb[2] + fb[3] < rot[1] + rot[2] + rot[3], "fallback should be dimmer than ROTATION")
    -- Green stays dominant so it still reads as a press-family cue.
    assert.is_true(fb[2] > fb[1] and fb[2] > fb[3])
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

  it("paints a ROTATION_FALLBACK dot (dim green) and does NOT glow it", function()
    local r = rigged(1)
    -- The Binder never sets glow on a fallback (glow is press-only), so no glow flag here.
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION_FALLBACK" } } })
    local dot = r.cueFrames["fake1"]
    assert.is_not_nil(dot, "fallback fell into the empty-cue path — no theme colour")
    assert.is_true(dot._shown)
    assert.is_true(colorEq(dot._color, theme.ROTATION_FALLBACK[1],
                           theme.ROTATION_FALLBACK[2], theme.ROTATION_FALLBACK[3]))
    assert.is_falsy(r.glowing["fake1"])   -- a runner-up never glows
  end)

  -- P5d strata fix: decorations ride a per-icon holder that sits ABOVE the icon (so a
  -- higher-strata panel covers them), not the old global DIALOG root.
  it("parents the cue to a per-icon holder a few frame-levels above the icon", function()
    local r, icons = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    local holder = r.cueHolders["fake1"]
    assert.is_not_nil(holder)
    assert.is_true(holder._shown)
    assert.is_true(holder:GetFrameLevel() > icons[1]:GetFrameLevel())  -- clears the swipe
  end)

  it("re-parents the holder when an icon is repooled to a new frame", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    local holder = r.cueHolders["fake1"]
    local newIcon = H.newStub()
    r:Register("fake1", newIcon)               -- the CDM repooled this handle's frame
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.equals(holder, r.cueHolders["fake1"])   -- same holder object, reparented
    assert.equals(newIcon, r.cueHolderAnchor["fake1"])
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
  -- keybind hint (upper-left inside the icon)
  ------------------------------------------------------------------------------
  it("draws the keybind hint at the icon's TOPLEFT when the cue carries one", function()
    local r, icons = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", keybind = "R" } } })
    local fs = r.cueKeys["fake1"]
    assert.equals("R", fs:GetText())
    assert.is_true(fs._shown)
    local pt = fs._points[1]
    assert.equals("TOPLEFT", pt.point)
    assert.equals(icons[1], pt.rel)          -- pinned to the icon, not the dot
    assert.equals("TOPLEFT", pt.relPoint)
  end)

  it("draws no keybind hint when the cue omits one", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.is_nil(r.cueKeys["fake1"])
  end)

  it("hides the keybind hint when its handle drops out", function()
    local r = rigged(2)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", keybind = "R" },
                      { anchorTo = "fake2", emphasis = "JUDGE", keybind = "E" } } })
    assert.is_true(r.cueKeys["fake2"]._shown)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", keybind = "R" } } })
    assert.is_false(r.cueKeys["fake2"]._shown)
  end)

  -- P5d: an EMPTY CUE (keybind, no emphasis) draws the key hint but NO dot/glow.
  it("draws the keybind on an empty cue (no emphasis) with no dot", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", keybind = "Q" } } })   -- no emphasis
    assert.equals("Q", r.cueKeys["fake1"]:GetText())
    assert.is_true(r.cueKeys["fake1"]._shown)
    assert.is_nil(r.cueFrames["fake1"])       -- no dot was ever created
    assert.is_nil(r.glowing["fake1"])
  end)

  -- The dot hides but the key hint survives when a cued icon loses its emphasis.
  it("keeps the key hint but drops the dot when a cue goes empty", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", keybind = "Q" } } })
    assert.is_true(r.cueFrames["fake1"]._shown)
    r:Draw({ cues = { { anchorTo = "fake1", keybind = "Q" } } })   -- emphasis gone
    assert.is_false(r.cueFrames["fake1"]._shown) -- dot hidden...
    assert.is_true(r.cueKeys["fake1"]._shown)    -- ...key hint stays
  end)

  ------------------------------------------------------------------------------
  -- proc glow (rides the icon, driven by the cue's `glow` flag)
  ------------------------------------------------------------------------------
  it("glows around the ICON (proc-style) when the cue asks for it", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", glow = true } } })
    assert.is_true(r.glowing["fake1"])
    local glow = r.cueGlows["fake1"]
    assert.is_true(glow._shown)
    assert.equals(r.registry["fake1"], glow._points[1].rel)   -- centred on the icon (proc-style)
    -- tinted to the cue's own emphasis hue
    assert.is_true(colorEq(glow._color, theme.ROTATION[1], theme.ROTATION[2], theme.ROTATION[3]))
  end)

  it("does not glow a cue without the flag", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "JUDGE" } } })
    assert.is_nil(r.glowing["fake1"])
  end)

  it("stops the glow when the cue drops out", function()
    local r = rigged(2)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", glow = true },
                      { anchorTo = "fake2", emphasis = "ROTATION", glow = true } } })
    assert.is_not_nil(r.glowing["fake2"])
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", glow = true } } })
    assert.is_nil(r.glowing["fake2"])
    assert.is_not_nil(r.glowing["fake1"])
  end)

  it("stops the glow when the cue stays but no longer asks to glow", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", glow = true } } })
    assert.is_not_nil(r.glowing["fake1"])
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.is_nil(r.glowing["fake1"])
  end)

  it("a glowing cue draws without error off-game (fallback path)", function()
    local r = rigged(1)
    assert.has_no.errors(function()
      r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION", glow = true } } })
    end)
  end)

  ------------------------------------------------------------------------------
  -- the shipped fixtures place the dot in the corner + carry keybinds + glow
  ------------------------------------------------------------------------------
  it("fixtures glow the press cue but not the softer JUDGE/SOON cues", function()
    local ns = H.ns
    assert.is_true(ns.RenderTestFixtures["hand-of-guldan"].drawList.cues[1].glow)
    local burst = ns.RenderTestFixtures["burst-hold"].drawList.cues
    assert.is_true(burst[1].glow)        -- ROTATION
    assert.is_nil(burst[2].glow)         -- JUDGE
  end)

  it("the inventory fixture carries one dot of every emphasis token, captioned", function()
    local inv = H.ns.RenderTestFixtures["inventory"]
    assert.equals(5, #inv.drawList.cues)
    local seen = {}
    for _, c in ipairs(inv.drawList.cues) do seen[c.emphasis] = true end
    for _, tok in ipairs({ "ROTATION", "LATE", "SOON", "JUDGE", "SEQUENCE" }) do
      assert.is_true(seen[tok], "inventory missing " .. tok)
    end
    assert.equals(5, #inv.captions)
    -- rendered together, all five draw + only the press cues glow
    local r = Rr.New()
    for i = 1, 5 do r:Register("fake" .. i, H.newStub()) end
    r:Draw(inv.drawList)
    assert.is_true(r.cueFrames["fake1"]._shown)   -- ROTATION
    assert.is_true(r.glowing["fake1"])            -- ROTATION glows
    assert.is_true(r.glowing["fake2"])            -- LATE glows
    assert.is_nil(r.glowing["fake3"])             -- SOON does not
  end)
  it("fixtures anchor the cue dot to the icon's upper-right corner with a keybind", function()
    local ns = H.ns
    local hog = ns.RenderTestFixtures["hand-of-guldan"].drawList.cues[1]
    assert.equals("TOPRIGHT", hog.point)
    assert.equals("TOPRIGHT", hog.relPoint)
    assert.equals("R", hog.keybind)
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
