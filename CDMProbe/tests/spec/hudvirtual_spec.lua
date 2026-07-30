-- hudvirtual_spec.lua — OUR OWN icons for the abilities the CDM tracks nowhere.
--
-- The claim under test is narrow and structural: a virtual row must arrive downstream as
-- *just another Layout entry plus a frame in the registry*, so that `Binder.lua` and
-- `Renderer.lua` need no edit to handle it.  That is the seam's success criterion
-- (docs/virtual-cdm-plan.md), so it is what these tests pin — the SHAPE of the fragments and
-- the impossibility of a handle collision, not any drawing.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local INCINERATE = 29722
local SHADOW_BOLT = 686

describe("HudVirtual.Build — base spellIDs -> (layout, registry)", function()
  local ns, V

  before_each(function()
    ns = H.fresh()
    H.load("HudLayout.lua")     -- Build delegates to it: the shape agrees by construction
    H.load("HudVirtual.lua")
    V = ns.HudVirtual
  end)

  -- A frame provider that hands back a distinguishable stub per spellID.
  local function frames()
    local made = {}
    return made, function(id) local f = { tag = id }; made[id] = f; return f end
  end

  it("emits a layout entry keyed by the NEGATIVE handle, in HudLayout.Build's shape", function()
    local made, frameFor = frames()
    local layout, registry = V.Build({ INCINERATE }, frameFor)
    assert.are.same({ spellID = INCINERATE, side = "TOPRIGHT" }, layout[-INCINERATE])
    assert.are.equal(made[INCINERATE], registry[-INCINERATE])
  end)

  it("produces EXACTLY the shape the live viewer walk does", function()
    -- Not a re-statement of the previous test: this compares against HudLayout.Build's own
    -- output for an equivalent record, so a future change to the Layout shape cannot leave
    -- virtual entries behind (the Binder would start dropping them silently).
    local f = {}
    local mine = V.Build({ INCINERATE }, function() return f end)
    local theirs = ns.HudLayout.Build({ { cooldownID = -INCINERATE, spellID = INCINERATE, frame = f } })
    assert.are.same(theirs, mine)
  end)

  it("a negative handle can never collide with a real cooldownID", function()
    -- The whole reason the handle is `-spellID`: real cooldownIDs are positive, so collision
    -- is impossible BY CONSTRUCTION rather than by luck.  Merging the two must never lose a
    -- Blizzard row.
    local realLayout = ns.HudLayout.Build({
      { cooldownID = 29722, spellID = 105174, frame = { tag = "blizzard" } },  -- same NUMBER
      { cooldownID = 686, spellID = 686, frame = { tag = "blizzard2" } },
    })
    local mine = V.Build({ INCINERATE, SHADOW_BOLT }, function(id) return { tag = id } end)
    for handle in pairs(mine) do
      assert.is_true(handle < 0)
      assert.is_nil(realLayout[handle])
    end
    -- ...and the merge the driver performs keeps all four.
    local merged = {}
    for k, v in pairs(realLayout) do merged[k] = v end
    for k, v in pairs(mine) do merged[k] = v end
    local n = 0
    for _ in pairs(merged) do n = n + 1 end
    assert.are.equal(4, n)
  end)

  it("keeps one entry per ability, laid out in order", function()
    local seen = {}
    local layout = V.Build({ SHADOW_BOLT, INCINERATE }, function(id, index, total)
      seen[#seen + 1] = { id = id, index = index, total = total }
      return { tag = id }
    end)
    assert.is_not_nil(layout[-SHADOW_BOLT])
    assert.is_not_nil(layout[-INCINERATE])
    assert.are.same({ id = SHADOW_BOLT, index = 1, total = 2 }, seen[1])
    assert.are.same({ id = INCINERATE, index = 2, total = 2 }, seen[2])
  end)

  it("DROPS a candidate with no frame rather than carrying a nil one", function()
    -- The in-combat case (frames are only created out of combat).  A Layout entry the
    -- Renderer cannot anchor would let the Binder report the cue as BOUND while nothing drew
    -- — the silent failure the decision log exists to expose.  No frame => no entry => the
    -- cue is honestly dropped and shows as `×`.
    local layout, registry = V.Build({ INCINERATE }, function() return nil end)
    assert.are.same({}, layout)
    assert.are.same({}, registry)
  end)

  it("skips a secret / non-numeric id rather than keying on it", function()
    H.markSecret(INCINERATE)
    local layout = V.Build({ INCINERATE, "nope" }, function(id) return { tag = id } end)
    assert.are.same({}, layout)
  end)

  it("returns empty tables for no candidates", function()
    local layout, registry = V.Build({}, function() return {} end)
    assert.are.same({}, layout)
    assert.are.same({}, registry)
  end)
end)

describe("HudVirtual.Sync / Reflect — the live half", function()
  local ns, V

  before_each(function()
    ns = H.fresh()
    H.load("HudLayout.lua")
    H.load("HudVirtual.lua")
    V = ns.HudVirtual
  end)

  it("pools one button per virtual row off pulse.virtual", function()
    local layout, registry = V.Sync({ virtual = { INCINERATE } })
    assert.is_not_nil(layout[-INCINERATE])
    assert.is_not_nil(registry[-INCINERATE])
    assert.is_not_nil(V.buttons[INCINERATE])
    assert.is_true(V.buttons[INCINERATE]:IsShown())
  end)

  it("REUSES the pooled button across ticks — no frame churn", function()
    V.Sync({ virtual = { INCINERATE } })
    local first = V.buttons[INCINERATE]
    V.Sync({ virtual = { INCINERATE } })
    assert.are.equal(first, V.buttons[INCINERATE])
  end)

  it("creates no frame in combat, so nothing is drawn or falsely bound", function()
    H.setCombat(true)
    local layout = V.Sync({ virtual = { INCINERATE } })
    assert.are.same({}, layout)
    assert.is_nil(V.buttons[INCINERATE])
  end)

  it("stitches the keybind off the BASE spellID (HudBinds never saw the CDM)", function()
    ns.HudBinds = { Get = function(id) return id == INCINERATE and "S-3" or nil end }
    local layout = V.Sync({ virtual = { INCINERATE } })
    assert.are.equal("S-3", layout[-INCINERATE].keybind)
  end)

  it("hides a button whose ability stopped being virtual", function()
    V.Sync({ virtual = { INCINERATE } })
    assert.is_true(V.buttons[INCINERATE]:IsShown())
    V.Sync({ virtual = {} })                    -- the CDM started tracking it / respec
    assert.is_false(V.buttons[INCINERATE]:IsShown())
  end)

  it("tolerates a pulse with no virtual list at all", function()
    local layout, registry = V.Sync({})
    assert.are.same({}, layout)
    assert.are.same({}, registry)
  end)

  ------------------------------------------------------------------------------
  describe("Reflect — dimmed when uncued, raised when cued", function()
    before_each(function() V.Sync({ virtual = { INCINERATE } }) end)

    it("rests dim with an empty DrawList", function()
      V.Reflect({ cues = {} })
      assert.is_true(V.buttons[INCINERATE]:GetAlpha() < 1)
    end)

    it("lights when the DrawList carries an emphasis on its handle", function()
      V.Reflect({ cues = { { anchorTo = -INCINERATE, emphasis = "ROTATION" } } })
      assert.are.equal(1.00, V.buttons[INCINERATE]:GetAlpha())
    end)

    it("a keybind-only cue (no emphasis) does NOT light it", function()
      -- The Binder puts a keybind on every displayed icon, cued or not.  That is identity
      -- chrome, not a press call, and must not read as "press this".
      V.Reflect({ cues = { { anchorTo = -INCINERATE, keybind = "3" } } })
      assert.is_true(V.buttons[INCINERATE]:GetAlpha() < 1)
    end)

    it("ignores cues on POSITIVE handles — those are Blizzard's icons", function()
      V.Reflect({ cues = { { anchorTo = 34991, emphasis = "ROTATION" } } })
      assert.is_true(V.buttons[INCINERATE]:GetAlpha() < 1)
    end)
  end)

  it("Clear hides every button, leaving the screen pixel-clean", function()
    V.Sync({ virtual = { INCINERATE } })
    V.Clear()
    assert.is_false(V.buttons[INCINERATE]:IsShown())
  end)
end)
