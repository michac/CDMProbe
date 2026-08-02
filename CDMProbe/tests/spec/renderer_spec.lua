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
    H.load("HudGeometry.lua")        -- the pip layout + the rig's fixtures read it
    H.load("Renderer.lua")
    H.load("RenderTest.lua")         -- the `/cdmp rt` rig — owns ns.RenderTestFixtures
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
    -- ROTATION_FALLBACK is now INCLUDED.  It used to be excluded as a dim green in
    -- ROTATION's own family (subordinate by brightness, not hue); it is now its own violet,
    -- so it must clear the same separation bound as every other token.
    local t = Rr.New().theme
    local toks = { "ROTATION", "ROTATION_FALLBACK", "LATE", "SOON" }
    for i = 1, #toks do
      for j = i + 1, #toks do
        local a, b = t[toks[i]], t[toks[j]]
        local dist = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3])
        assert.is_true(dist > 0.30, toks[i] .. " and " .. toks[j] .. " are too similar (" .. dist .. ")")
      end
    end
  end)

  it("keeps ROTATION_FALLBACK's violet clear of the SHARD BAR's violet", function()
    -- The constraint that picked this hue.  A fallback cue in the shard colour reads as
    -- "resource" at a glance, because the pips sit in the same frame — so the separation
    -- that matters is against the POWER palette, not just the emphasis palette.
    local r = Rr.New()
    local fb = r.theme.ROTATION_FALLBACK
    assert.is_not_nil(fb, "ROTATION_FALLBACK missing from the theme (would render as an empty cue)")
    local dist = function(a, b)
      return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3])
    end
    local pips = r.powerColor.SOUL_SHARDS
    assert.is_true(dist(fb, pips) > 0.30,
      "fallback is too close to the shard pips (" .. dist(fb, pips) .. ") — it will read as resource")
    -- Blue stays dominant (it is a violet, not a second green/amber).
    assert.is_true(fb[3] > fb[1] and fb[3] > fb[2])
    -- Separated from the pale pips by SATURATION: markedly less green than the lavender.
    assert.is_true(fb[2] < pips[2] - 0.15, "fallback should be more saturated than the pips")
  end)

  it("takes an injected theme through cfg", function()
    local r = Rr.New({ theme = { ROTATION = { 1, 0, 0, 1 } } })
    assert.is_true(colorEq(r.theme.ROTATION, 1, 0, 0))
  end)

  ------------------------------------------------------------------------------
  -- 3b — cue dots
  ------------------------------------------------------------------------------
  -- THE CUE'S GEOMETRY NOW RIDES THE CUE LAYER, not the dot.  The dot is CENTERed on the
  -- layer and the layer carries the entry's point/offsets, so the pop can scale about the
  -- cue's own centre instead of the icon's (Renderer.lua: ensureLayer).  What is asserted
  -- is unchanged in substance: the entry's geometry reaches a frame anchored to the
  -- registered icon, and the dot is where it says.
  it("paints one ROTATION dot under its handle at the given point + size", function()
    local r, icons = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", point = "CENTER", relPoint = "CENTER",
                        dx = 0, dy = -28, size = 12, emphasis = "ROTATION" } } })
    local dot = r.cueFrames["fake1"]
    assert.is_true(colorEq(dot._color, theme.ROTATION[1], theme.ROTATION[2], theme.ROTATION[3]))
    assert.same({ 12, 12 }, dot._size)
    assert.is_true(dot._shown)
    local layer = r.cueLayers["fake1"]
    assert.is_not_nil(layer, "no cue layer — the dot has nothing to pop with")
    assert.same({ 12, 12 }, layer._size)          -- the layer's rect IS the dot's rect
    local lp = layer._points[1]
    assert.equals("CENTER", lp.point)
    assert.equals(r.cueHolders["fake1"], lp.rel)  -- ...on the holder, which IS the icon's rect
    assert.equals(icons[1], r.cueHolderAnchor["fake1"])
    assert.equals(-28, lp.dy)
    assert.equals(layer, dot._points[1].rel)      -- the dot just centres on it
    assert.equals("CENTER", dot._points[1].point)
  end)

  it("re-points the cue layer only when the geometry actually changes", function()
    -- ⚠ The reason the pop lives on a frame at all: a SetSize/SetPoint per tick on the
    -- region being scaled is the fight this structure exists to avoid.  The live cue
    -- geometry is constant (G.DOT), so a steady redraw must re-stamp NOTHING.
    local r = rigged(1)
    local cue = { anchorTo = "fake1", point = "TOPRIGHT", relPoint = "TOPRIGHT",
                  dx = -3, dy = -3, size = 12, emphasis = "ROTATION" }
    r:Draw({ cues = { cue } })
    local layer = r.cueLayers["fake1"]
    assert.equals(1, #layer._points)
    for _ = 1, 5 do r:Draw({ cues = { cue } }) end
    assert.equals(1, #layer._points, "the cue layer is re-anchored on every draw")
  end)

  it("paints a ROTATION_FALLBACK cue in its OWN violet, animating like every other cue", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION_FALLBACK" } } })
    local dot = r.cueFrames["fake1"]
    assert.is_not_nil(dot, "fallback fell into the empty-cue path — no theme colour")
    assert.is_true(dot._shown)
    -- HUE is the tell.  It used to be motion (a STATIC ring), because the runner-up was a
    -- dimmer GREEN and stillness was the only channel left; it has its own violet now, so
    -- the stillness bought nothing and only made the backup look like a dead cue.
    local fb = theme.ROTATION_FALLBACK
    assert.is_true(colorEq(dot._color, fb[1], fb[2], fb[3]))
    assert.is_false(colorEq(dot._color, theme.ROTATION[1], theme.ROTATION[2], theme.ROTATION[3]),
      "fallback is still borrowing ROTATION's green")
    local glow = r.cueGlows["fake1"]
    assert.is_not_nil(glow)
    assert.is_true(glow._shown)
    assert.is_true(colorEq(glow._color, fb[1], fb[2], fb[3]))
    assert.is_true(glow._spinOn)
    assert.is_true(glow._pulseOn)
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

  it("colours each cue by its own emphasis token (ROTATION + 2 SOON)", function()
    local r = rigged(3)
    r:Draw({ cues = {
      { anchorTo = "fake1", emphasis = "ROTATION" },
      { anchorTo = "fake2", emphasis = "SOON" },
      { anchorTo = "fake3", emphasis = "SOON" },
    } })
    assert.is_true(colorEq(r.cueFrames["fake1"]._color, theme.ROTATION[1], theme.ROTATION[2], theme.ROTATION[3]))
    assert.is_true(colorEq(r.cueFrames["fake2"]._color, theme.SOON[1], theme.SOON[2], theme.SOON[3]))
    assert.is_true(colorEq(r.cueFrames["fake3"]._color, theme.SOON[1], theme.SOON[2], theme.SOON[3]))
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
                      { anchorTo = "fake2", emphasis = "SOON" } } })
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
  -- keybind hints — the DrawList's SECOND per-icon channel (Phase 3).  These used to
  -- ride the cue entry; they now arrive on `keybinds[]` and are drawn independently.
  ------------------------------------------------------------------------------
  -- The geometry comes off the ENTRY, not from literals in the Renderer (the Binder
  -- stamps ns.HudGeometry.KEY), so this asserts what it was TOLD.
  it("draws the keybind hint at the entry's own anchor point", function()
    local r, icons = rigged(1)
    r:Draw({ keybinds = { { anchorTo = "fake1", point = "TOPLEFT", relPoint = "TOPLEFT",
                            dx = 2, dy = -2, keybind = "R" } } })
    local fs = r.cueKeys["fake1"]
    assert.equals("R", fs:GetText())
    assert.is_true(fs._shown)
    local pt = fs._points[1]
    assert.equals("TOPLEFT", pt.point)
    assert.equals(icons[1], pt.rel)          -- pinned to the icon, not the dot
    assert.equals("TOPLEFT", pt.relPoint)
    assert.equals(2, pt.dx)
    assert.equals(-2, pt.dy)
  end)

  it("draws no keybind hint for a cue-only icon", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.is_nil(r.cueKeys["fake1"])
  end)

  it("hides the keybind hint when its handle drops out of the keybinds channel", function()
    local r = rigged(2)
    r:Draw({ keybinds = { { anchorTo = "fake1", keybind = "R" },
                          { anchorTo = "fake2", keybind = "E" } } })
    assert.is_true(r.cueKeys["fake2"]._shown)
    r:Draw({ keybinds = { { anchorTo = "fake1", keybind = "R" } } })
    assert.is_false(r.cueKeys["fake2"]._shown)
  end)

  -- The Phase-3 shape: a key hint on an icon with no cue at all draws the hint and NO dot.
  -- (Pre-Phase-3 this was an "empty cue" — a keybind with no emphasis on the cue channel.)
  it("draws a keybind-only icon with no dot and no glow", function()
    local r = rigged(1)
    r:Draw({ cues = {}, keybinds = { { anchorTo = "fake1", keybind = "Q" } } })
    assert.equals("Q", r.cueKeys["fake1"]:GetText())
    assert.is_true(r.cueKeys["fake1"]._shown)
    assert.is_nil(r.cueFrames["fake1"])       -- no dot was ever created
    assert.is_nil(r.glowing["fake1"])
  end)

  ------------------------------------------------------------------------------
  -- CULL INDEPENDENCE — the one real trap in Phase 3.  Both channels share
  -- `cueHolders` (one holder per icon, carrying both decorations), so culling holders
  -- inside either pass would hide the other channel's decoration every frame.  R:Draw
  -- culls on the UNION; these two tests are what pin that, one per direction.
  ------------------------------------------------------------------------------
  it("keeps the key hint when the icon's DOT drops out", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } },
             keybinds = { { anchorTo = "fake1", keybind = "Q" } } })
    assert.is_true(r.cueFrames["fake1"]._shown)
    r:Draw({ cues = {}, keybinds = { { anchorTo = "fake1", keybind = "Q" } } })
    assert.is_false(r.cueFrames["fake1"]._shown)   -- dot hidden...
    assert.is_true(r.cueKeys["fake1"]._shown)      -- ...key hint stays
    assert.is_true(r.cueHolders["fake1"]._shown)   -- ...and so does the holder it rides
  end)

  it("keeps the dot when the icon's KEY HINT drops out", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } },
             keybinds = { { anchorTo = "fake1", keybind = "Q" } } })
    assert.is_true(r.cueKeys["fake1"]._shown)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } }, keybinds = {} })
    assert.is_false(r.cueKeys["fake1"]._shown)     -- hint hidden...
    assert.is_true(r.cueFrames["fake1"]._shown)    -- ...dot stays
    assert.is_true(r.cueHolders["fake1"]._shown)
  end)

  -- …and a THIRD term since the ghost landed: a removed handle leaves both active sets in
  -- the same draw that starts its out-animation, so a two-term union would hide the holder
  -- instantly and the ghost would play invisibly.  Here the ghost is finished first.
  it("hides the holder only when BOTH channels drop the handle", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } },
             keybinds = { { anchorTo = "fake1", keybind = "Q" } } })
    assert.is_true(r.cueHolders["fake1"]._shown)
    r:Draw({})
    r.cueGhosts["fake1"].anim:Fire("OnFinished")   -- the ghost has played out
    r:Draw({})
    assert.is_false(r.cueHolders["fake1"]._shown)
  end)

  ------------------------------------------------------------------------------
  -- proc glow (rides the icon, driven by the cue's `glow` flag)
  ------------------------------------------------------------------------------
  it("shows a spinning + pulsing ring on a ROTATION cue, centred on the still-visible dot", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.is_true(r.glowing["fake1"])
    local glow = r.cueGlows["fake1"]
    assert.is_true(glow._shown)
    assert.equals(r.cueFrames["fake1"], glow._points[1].rel)   -- centred on the solid dot
    -- tinted to the cue's own emphasis hue
    assert.is_true(colorEq(glow._color, theme.ROTATION[1], theme.ROTATION[2], theme.ROTATION[3]))
    assert.is_true(glow._spinOn)     -- both animation groups play
    assert.is_true(glow._pulseOn)
    assert.is_true(r.cueFrames["fake1"]._shown)   -- centre dot stays VISIBLE (no longer ring-only)
  end)

  -- The contract rule, stated against a deliberately UNKNOWN token rather than a
  -- particular one: an emphasis the theme/GLOW_SPEC has no entry for draws NOTHING —
  -- no circle, no ring.  We never guess a colour for a token we don't recognise.
  it("draws neither circle nor ring for an emphasis with no theme/GLOW_SPEC entry", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "NOT_A_TOKEN" } } })
    assert.is_nil(r.glowing["fake1"])
    assert.is_nil(r.cueFrames["fake1"])            -- no dot was ever created
  end)

  it("stops the glow when the cue drops out", function()
    local r = rigged(2)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" },
                      { anchorTo = "fake2", emphasis = "ROTATION" } } })
    assert.is_not_nil(r.glowing["fake2"])
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.is_nil(r.glowing["fake2"])
    assert.is_not_nil(r.glowing["fake1"])
  end)

  it("stops the glow when the cue's emphasis changes to a no-ring one", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.is_not_nil(r.glowing["fake1"])
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "NOT_A_TOKEN" } } })   -- -> no GLOW_SPEC
    assert.is_nil(r.glowing["fake1"])
  end)

  it("a glowing cue draws without error off-game (fallback path)", function()
    local r = rigged(1)
    assert.has_no.errors(function()
      r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    end)
  end)

  ------------------------------------------------------------------------------
  -- THE PROMOTED LOOK (2026-08-01) — the treatment dialled in on `/cdmp rt fx` and
  -- moved into the Renderer proper: a backing disc, an outer counter-rotating echo of
  -- the ring, and the light split between the two.
  ------------------------------------------------------------------------------
  it("backs each cue with a dark disc and an outer echo of its ring", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", size = 12, emphasis = "ROTATION" } } })
    local glow, echo, disc = r.cueGlows["fake1"], r.cueEchoes["fake1"], r.cueDiscs["fake1"]
    assert.is_not_nil(echo, "no echo — the ring has no reach")
    assert.is_not_nil(disc, "no backing disc — the additive ring has nothing to read against")
    assert.is_true(echo._shown)
    assert.is_true(disc._shown)
    -- The echo is BIGGER than the base ring (reach) and the disc smaller than both, sized
    -- off the echo's extent so turning the reach up can never leave it undersized.
    local ring, out, back = glow._size[1], echo._size[1], disc._size[1]
    assert.is_true(out > ring, "the echo must reach past the ring it echoes")
    assert.is_true(back < ring, "the disc must sit BEHIND the dot, not swallow the ring")
    assert.is_true(math.abs(out - ring * 1.5) < 1e-6)
    assert.is_true(math.abs(back - out * 0.35) < 1e-6)
    -- Both rings carry the cue's hue; only the ALPHA differs (the light split).
    local rot = theme.ROTATION
    assert.is_true(colorEq(glow._color, rot[1], rot[2], rot[3]))
    assert.is_true(colorEq(echo._color, rot[1], rot[2], rot[3]))
    assert.is_true(near(glow._color[4] + echo._color[4], 1.0),
      "the light must be SPLIT between ring and echo, not added — adding reach must not add brightness")
    assert.is_true(disc._color[1] == 0 and disc._color[2] == 0 and disc._color[3] == 0)
  end)

  it("counter-rotates the echo at a RATIO of whatever the base ring's period is", function()
    -- The ratio (not an absolute period) is what makes the effect survive a retune and
    -- gives LATE the same relationship for free.  Two copies turning TOGETHER read as one
    -- thicker ring; opposed rotation is what makes the extra reach legible as rays.
    local r = rigged(2)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" },
                      { anchorTo = "fake2", emphasis = "LATE" } } })
    for _, key in ipairs({ "fake1", "fake2" }) do
      local base, echo = r.cueGlows[key].rot, r.cueEchoes[key].rot
      assert.is_true(near(echo._duration, base._duration * 2.5),
        key .. ": the echo is not timed off the base ring's own period")
      assert.is_true(base._degrees * echo._degrees < 0,
        key .. ": the echo turns the SAME way as the base ring — it will read as one ring")
    end
    -- ...and that is a real difference, not both rings sitting at the same number.
    assert.is_not.equals(r.cueGlows["fake1"].rot._duration, r.cueGlows["fake2"].rot._duration)
  end)

  it("keeps LATE's ring ~1.39x the base after the GLOW_SCALE retune", function()
    -- LATE is not a different KIND of press, it is the same press ESCALATED — "a bigger
    -- ring", expressed as a RATIO.  GLOW_SCALE moved 2.3 -> 3.34 when the art changed to
    -- star_07 (it is art-specific), and LATE's ringScale moved with it.  This pins the
    -- ratio rather than either number, which is the thing that must not drift.
    local r = rigged(2)
    r:Draw({ cues = { { anchorTo = "fake1", size = 12, emphasis = "ROTATION" },
                      { anchorTo = "fake2", size = 12, emphasis = "LATE" } } })
    local base, late = r.cueGlows["fake1"]._size[1], r.cueGlows["fake2"]._size[1]
    local ratio = late / base
    assert.is_true(ratio > 1.30 and ratio < 1.50,
      "LATE's escalation ratio drifted to " .. ratio .. " (want ~1.39)")
  end)

  ------------------------------------------------------------------------------
  -- THE CUE LAYER — why the pop can exist at all.  The dot/ring/echo/disc ride a frame
  -- the draw path never resizes; the KEYBIND deliberately does not.
  ------------------------------------------------------------------------------
  it("parents the cue's own art to the cue layer and the key hint to the HOLDER", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } },
             keybinds = { { anchorTo = "fake1", keybind = "Q" } } })
    local holder, layer = r.cueHolders["fake1"], r.cueLayers["fake1"]
    for name, region in pairs({ dot = r.cueFrames["fake1"], ring = r.cueGlows["fake1"],
                               echo = r.cueEchoes["fake1"], disc = r.cueDiscs["fake1"] }) do
      assert.equals(layer, region._parent, name .. " is not on the cue layer — it will not pop")
    end
    -- THE LOAD-BEARING HALF: identity chrome must not grow and shrink every time the
    -- rotation moves, so the key hint is on the holder, OUTSIDE the popped subtree.
    assert.equals(holder, r.cueKeys["fake1"]._parent,
      "the keybind rides the cue layer — it will scale with every pop")
    assert.is_not.equals(layer, r.cueKeys["fake1"]._parent)
  end)

  it("keeps the cue layer level-matched with the holder, so the key hint stays on top", function()
    -- A child frame defaults one level ABOVE its parent, which would put the ring's
    -- ARTWORK over the key hint's OVERLAY.  Level-matched, the draw layer decides.
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", emphasis = "ROTATION" } } })
    assert.equals(r.cueHolders["fake1"]:GetFrameLevel(), r.cueLayers["fake1"]:GetFrameLevel())
  end)

  ------------------------------------------------------------------------------
  -- THE TWO EDGES.  Measured off 504s of real play: the cue set turns over at cast
  -- cadence (120 changes, one every ~4s) and 60 % of those are a SWAP.  So a per-handle
  -- POP/GHOST and a per-SET-CHANGE callback are two different things, and conflating
  -- them would fire twice on every swap.
  ------------------------------------------------------------------------------
  local function watched(n)
    local seen = {}
    local r = Rr.New({ onCueSetChanged = function(kind) seen[#seen + 1] = kind end })
    for i = 1, n do r:Register("fake" .. i, H.newStub()) end
    return r, seen
  end
  local function cue(handle) return { anchorTo = handle, emphasis = "ROTATION" } end

  it("fires NO edge on a steady redraw", function()
    local r, seen = watched(1)
    for _ = 1, 5 do r:Draw({ cues = { cue("fake1") } }) end
    assert.same({ "new" }, seen)   -- the first draw is a real arrival; the other four are not
  end)

  it("fires exactly one 'new' when a cue is added", function()
    local r, seen = watched(2)
    r:Draw({ cues = { cue("fake1") } })
    r:Draw({ cues = { cue("fake1"), cue("fake2") } })
    assert.same({ "new", "new" }, seen)
  end)

  it("fires exactly ONE 'new' on a swap — a cue that moved was not removed", function()
    -- THE LOAD-BEARING CASE.  60 % of real set changes are this shape.  Firing per handle
    -- would make every swap two events: overlapping sounds, and wrong besides.
    local r, seen = watched(2)
    r:Draw({ cues = { cue("fake1") } })              -- the arrival: one "new"
    r:Draw({ cues = { cue("fake2") } })              -- fake1 out + fake2 in, ONE tick
    assert.same({ "new", "new" }, seen)              -- ...and NOT { new, new, gone }
    -- Both halves of the swap still happened visually — they are just not two events.
    assert.equals(1, r.cueLayers["fake2"].pop._plays)
    assert.is_true(r.ghosting["fake1"])
  end)

  it("fires one 'gone' when the board empties", function()
    local r, seen = watched(1)
    r:Draw({ cues = { cue("fake1") } })
    r:Draw({ cues = {} })
    assert.same({ "new", "gone" }, seen)
    r:Draw({ cues = {} })                           -- still empty: not an edge
    assert.same({ "new", "gone" }, seen)
  end)

  it("pops EVERY arriving handle while the set event fires once", function()
    local r, seen = watched(3)
    r:Draw({ cues = { cue("fake1") } })
    local before = r.cueLayers["fake1"].pop._plays
    r:Draw({ cues = { cue("fake1"), cue("fake2"), cue("fake3") } })
    assert.equals(before, r.cueLayers["fake1"].pop._plays, "a steady handle re-popped")
    assert.equals(1, r.cueLayers["fake2"].pop._plays)
    assert.equals(1, r.cueLayers["fake3"].pop._plays)
    assert.same({ "new", "new" }, seen)             -- two draws, two set changes — not four
  end)

  it("ghosts a removed handle in the ring's own size and hue, and keeps its holder alive", function()
    local r = rigged(1)
    r:Draw({ cues = { { anchorTo = "fake1", size = 12, emphasis = "ROTATION" } } })
    local ringSize = r.cueGlows["fake1"]._size[1]
    r:Draw({ cues = {} })
    local ghost = r.cueGhosts["fake1"]
    assert.is_not_nil(ghost, "nothing marks where the cue left")
    assert.is_true(ghost._shown)
    assert.equals(ringSize, ghost._size[1])
    assert.is_true(colorEq(ghost._color, theme.ROTATION[1], theme.ROTATION[2], theme.ROTATION[3]))
    assert.equals(1, ghost.anim._plays)
    -- The ring itself is hidden by the cull the same tick — which is exactly why the
    -- ghost is its own texture, and why the holder must survive the cull.
    assert.is_false(r.cueGlows["fake1"]._shown)
    assert.is_true(r.ghosting["fake1"])
    assert.is_true(r.cueHolders["fake1"]._shown,
      "the holder was culled under a playing ghost — the ghost plays invisibly")
    ghost.anim:Fire("OnFinished")
    assert.is_nil(r.ghosting["fake1"])
    assert.is_false(ghost._shown)
  end)

  it("re-ghosts a handle that leaves twice without stranding its holder", function()
    -- ⚠ ORDERING.  `Stop()` on the previous ghost fires OnFinished, which CLEARS the
    -- "a ghost is playing" flag — so the flag has to be set AFTER the stop.  Set it
    -- before and the second ghost plays under an already-culled holder.
    local r = rigged(1)
    local c = { anchorTo = "fake1", emphasis = "ROTATION" }
    r:Draw({ cues = { c } })
    r:Draw({ cues = {} })          -- ghost 1
    r:Draw({ cues = { c } })       -- ...it comes back
    r:Draw({ cues = {} })          -- ghost 2, over a still-running ghost 1
    assert.equals(2, r.cueGhosts["fake1"].anim._plays)
    assert.is_true(r.ghosting["fake1"], "the second ghost cleared its own flag")
    assert.is_true(r.cueHolders["fake1"]._shown)
  end)

  it("stays silent with no callback injected (the Renderer calls no game function)", function()
    local r = rigged(1)
    assert.has_no.errors(function()
      r:Draw({ cues = { cue("fake1") } })
      r:Draw({ cues = {} })
    end)
  end)

  ------------------------------------------------------------------------------
  -- the shipped fixtures place the dot in the corner + carry keybinds + glow
  ------------------------------------------------------------------------------
  it("fixtures ring the press cue", function()
    local ns = H.ns
    -- Drawn, not read off a retired field: hand-of-guldan is one ROTATION press.
    local hog = Rr.New()
    hog:Register("fake1", H.newStub())
    hog:Draw(ns.RenderTestFixtures["hand-of-guldan"].drawList)
    assert.is_true(hog.glowing["fake1"])
  end)

  -- `states` is the reference card: every VISIBLE cue state the live pipeline can put
  -- on an icon, in one DrawList.  Since Phase 3 the IDLE square is the CHANNEL SEPARATION
  -- made visible — it is in `keybinds` and not in `cues` at all, so there are 8 captions,
  -- 8 keybinds, and only 7 cues.
  it("the states fixture draws the whole live emphasis set, captioned", function()
    local st = H.ns.RenderTestFixtures["states"]
    assert.equals(7, #st.drawList.cues)
    assert.equals(8, #st.drawList.keybinds)
    assert.equals(8, #st.captions)
    local seen = {}
    for _, c in ipairs(st.drawList.cues) do if c.emphasis then seen[c.emphasis] = true end end
    for _, tok in ipairs({ "ROTATION", "ROTATION_FALLBACK", "LATE", "SOON" }) do
      assert.is_true(seen[tok], "states missing " .. tok)
    end
    local r = Rr.New()
    for i = 1, 8 do r:Register("fake" .. i, H.newStub()) end
    r:Draw(st.drawList)
    assert.is_nil(r.cueFrames["fake1"])           -- IDLE: keybind only, no dot
    assert.is_true(r.cueKeys["fake1"]._shown)     -- ...and its hint is still drawn
    assert.is_true(r.glowing["fake2"])            -- SOON glows (moving = anticipation)
    assert.is_true(r.glowing["fake3"])            -- FALLBACK rings
    assert.is_true(r.glowing["fake4"])            -- ROTATION glows
    assert.is_true(r.glowing["fake5"])            -- LATE glows
  end)
  -- The two corners, one per channel: the dot upper-RIGHT, the key hint upper-LEFT, and
  -- the cue carries no key of its own (Phase 3).
  it("fixtures put the dot upper-right and the key hint upper-left", function()
    local ns = H.ns
    local fx = ns.RenderTestFixtures["hand-of-guldan"].drawList
    local hog = fx.cues[1]
    assert.equals("TOPRIGHT", hog.point)
    assert.equals("TOPRIGHT", hog.relPoint)
    assert.is_nil(hog.keybind)
    local key = fx.keybinds[1]
    assert.equals("fake1", key.anchorTo)
    assert.equals("TOPLEFT", key.point)
    assert.equals("R", key.keybind)
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
  -- 3d — resource bars (multi-spec Phase 3: an ARRAY of stacked pip rows)
  ------------------------------------------------------------------------------
  local function shardCol(r) return r.powerColor.SOUL_SHARDS end

  it("draws `max` pips with `value` filled in the powerType colour", function()
    local r = rigged(1)
    r:Draw({ resourceBars = { { anchorTo = "UIPARENT", point = "BOTTOM",
                                value = 3, max = 5, powerType = "SOUL_SHARDS" } } })
    local row = r.pipRows[1]
    assert.equals(5, #row)
    local col, filled = shardCol(r), 0
    for i = 1, 5 do
      if colorEq(row[i]._color, col[1], col[2], col[3]) then filled = filled + 1 end
      assert.is_true(row[i]._shown)
    end
    assert.equals(3, filled)
  end)

  it("hides surplus pips when a later bar has a smaller max", function()
    local r = rigged(1)
    r:Draw({ resourceBars = { { value = 3, max = 5, powerType = "SOUL_SHARDS" } } })
    r:Draw({ resourceBars = { { value = 1, max = 2, powerType = "SOUL_SHARDS" } } })
    local row = r.pipRows[1]
    assert.is_true(row[1]._shown)
    assert.is_true(row[2]._shown)
    for i = 3, 5 do assert.is_false(row[i]._shown) end
  end)

  it("hides the whole bar when the next DrawList carries none", function()
    local r = rigged(1)
    r:Draw({ resourceBars = { { value = 3, max = 5, powerType = "SOUL_SHARDS" } } })
    r:Draw({})
    for i = 1, 5 do assert.is_false(r.pipRows[1][i]._shown) end
  end)

  -- The full-seam proof at the Renderer's own layer: two stacked bars, each with its OWN
  -- pip-row pool, so bar 2's pips never stomp bar 1's (a dual-resource spec is drawable).
  it("draws two stacked bars in independent pip-row pools", function()
    local r = rigged(1)
    r:Draw({ resourceBars = {
      { value = 3, max = 5, powerType = "SOUL_SHARDS", display = "discrete" },
      { value = 2, max = 4, powerType = "SOUL_SHARDS", display = "discrete" },
    } })
    assert.equals(5, #r.pipRows[1])
    assert.equals(4, #r.pipRows[2])
    -- Independent pools: bar 1 keeps all 5 pips shown while bar 2 owns its own 4.
    for i = 1, 5 do assert.is_true(r.pipRows[1][i]._shown) end
    for i = 1, 4 do assert.is_true(r.pipRows[2][i]._shown) end
  end)

  -- Only the discrete path is implemented; a `continuous` bar draws nothing (stub).
  it("draws nothing for a continuous bar (Phase-when-needed stub)", function()
    local r = rigged(1)
    r:Draw({ resourceBars = { { value = 50, max = 100, powerType = "MANA", display = "continuous" } } })
    assert.same({}, r.pipRows[1])   -- no pips created for the continuous path
  end)

  it("hides a former discrete row when its bar goes continuous", function()
    local r = rigged(1)
    r:Draw({ resourceBars = { { value = 3, max = 5, powerType = "SOUL_SHARDS", display = "discrete" } } })
    assert.is_true(r.pipRows[1][1]._shown)
    r:Draw({ resourceBars = { { value = 3, max = 5, powerType = "SOUL_SHARDS", display = "continuous" } } })
    for i = 1, 5 do assert.is_false(r.pipRows[1][i]._shown) end
  end)

  ------------------------------------------------------------------------------
  -- The whole DrawList together (ROTATION + LATE + SOON + bar)
  ------------------------------------------------------------------------------
  it("draws cues + bar from one DrawList without cross-talk", function()
    local r = rigged(3)
    r:Draw({
      cues = {
        { anchorTo = "fake1", emphasis = "ROTATION" },
        { anchorTo = "fake2", emphasis = "LATE" },
        { anchorTo = "fake3", emphasis = "SOON" },
      },
      resourceBars = { { value = 3, max = 5, powerType = "SOUL_SHARDS" } },
    })
    assert.is_true(r.cueFrames["fake1"]._shown)
    assert.is_true(r.cueFrames["fake2"]._shown)
    assert.is_true(r.cueFrames["fake3"]._shown)
    assert.is_nil(r.panelWidget)          -- no panel authored => never built
    assert.equals(5, #r.pipRows[1])
  end)
end)
