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

--------------------------------------------------------------------------------
-- PHASE 2 — the moveable panel.
--
-- The drag/save/restore shape is BucketBinds' console verbatim, so what is worth pinning
-- here is the two things that are OURS: that a saved position round-trips through
-- `ns.db.virtualPanel` (and that its ABSENCE falls back to the default anchor rather than
-- to a nil point), and that the lock state governs BOTH halves of "does this frame exist as
-- far as the mouse is concerned" — the mouse surface and the visible affordance.
--------------------------------------------------------------------------------
describe("HudVirtual — the moveable panel (Phase 2)", function()
  local ns, V

  before_each(function()
    ns = H.fresh()
    H.load("HudLayout.lua")
    H.load("HudVirtual.lua")
    V = ns.HudVirtual
    ns.db = { virtualPanel = {} }      -- Core's DEFAULTS entry, as ADDON_LOADED leaves it
  end)

  ------------------------------------------------------------------------------
  describe("saved position", function()
    it("round-trips a dragged position through ns.db.virtualPanel", function()
      local root = V.ensureRoot()
      root:ClearAllPoints()
      root:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -340)
      V.SavePosition()
      assert.are.same({ point = "TOPLEFT", relPoint = "TOPLEFT", x = 120, y = -340 },
                      ns.db.virtualPanel)

      root:ClearAllPoints()
      V.RestorePosition()
      local point, _, relPoint, x, y = root:GetPoint()
      assert.are.same({ "TOPLEFT", "TOPLEFT", 120, -340 }, { point, relPoint, x, y })
    end)

    it("saves against UIParent, never the relativeTo frame it read back", function()
      -- BucketBinds' one subtlety, copied deliberately: a stored frame reference could go
      -- stale across a reload, so restore always re-anchors to UIParent.
      local root = V.ensureRoot()
      root:ClearAllPoints()
      root:SetPoint("CENTER", UIParent, "CENTER", 5, 5)
      V.SavePosition()
      assert.is_nil(ns.db.virtualPanel.relativeTo)
      root:ClearAllPoints()
      V.RestorePosition()
      local _, rel = root:GetPoint()
      assert.are.equal(UIParent, rel)
    end)

    it("NO saved position ⇒ the default anchor (below the resource bar)", function()
      local root = V.ensureRoot()          -- ensureRoot restores as part of creation
      local point, _, relPoint, x, y = root:GetPoint()
      assert.are.same({ "CENTER", "CENTER", 0, -52 }, { point, relPoint, x, y })
    end)

    it("`reset` clears the saved position and snaps back to the default", function()
      local root = V.ensureRoot()
      root:ClearAllPoints()
      root:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -340)
      V.SavePosition()
      H.run("panel", "reset")
      assert.are.same({}, ns.db.virtualPanel)
      local point, _, relPoint, x, y = root:GetPoint()
      assert.are.same({ "CENTER", "CENTER", 0, -52 }, { point, relPoint, x, y })
    end)

    it("tolerates no db at all (the panel still positions itself)", function()
      ns.db = nil
      local root = V.ensureRoot()
      V.SavePosition()                     -- must not throw
      assert.are.equal("CENTER", (root:GetPoint()))
    end)

    it("an OnDragStop saves — the drag wiring is actually connected", function()
      local root = V.ensureRoot()
      root:ClearAllPoints()
      root:SetPoint("BOTTOM", UIParent, "BOTTOM", -8, 200)
      root:Fire("OnDragStop")
      assert.are.same({ point = "BOTTOM", relPoint = "BOTTOM", x = -8, y = 200 },
                      ns.db.virtualPanel)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("lock / unlock", function()
    it("locked is the resting state: no mouse surface, no chrome", function()
      local root = V.ensureRoot()
      assert.is_false(root:IsMouseEnabled())
      for _, t in ipairs(V.chrome) do assert.is_false(t:IsShown()) end
      assert.is_false(V.caption:IsShown())
    end)

    it("unlock shows the border + caption and takes the mouse", function()
      local root = V.ensureRoot()
      H.run("panel", "unlock")
      assert.is_true(V.unlocked)
      assert.is_true(root:IsMouseEnabled())
      for _, t in ipairs(V.chrome) do assert.is_true(t:IsShown()) end
      assert.is_true(V.caption:IsShown())
    end)

    it("lock puts every one of those back", function()
      local root = V.ensureRoot()
      H.run("panel", "unlock")
      H.run("panel", "lock")
      assert.is_false(V.unlocked)
      assert.is_false(root:IsMouseEnabled())
      for _, t in ipairs(V.chrome) do assert.is_false(t:IsShown()) end
      assert.is_false(V.caption:IsShown())
    end)

    it("bare `/cdmp panel` toggles", function()
      V.ensureRoot()
      H.run("panel", nil)
      assert.is_true(V.unlocked)
      H.run("panel", "")
      assert.is_false(V.unlocked)
    end)

    it("`lock` is not matched INSIDE `unlock` (the strict token parse)", function()
      V.ensureRoot()
      H.run("panel", "unlock")
      assert.is_true(V.unlocked)          -- a substring `find` would have locked it
    end)

    it("icons are held LIT while unlocked, so you can see what you are dragging", function()
      V.Sync({ virtual = { INCINERATE } })
      H.run("panel", "unlock")
      assert.are.equal(1.00, V.buttons[INCINERATE]:GetAlpha())
      V.Reflect({ cues = {} })            -- an uncued tick must NOT dim it back
      assert.are.equal(1.00, V.buttons[INCINERATE]:GetAlpha())
      H.run("panel", "lock")
      assert.is_true(V.buttons[INCINERATE]:GetAlpha() < 1)
    end)

    it("REFUSES to create the panel mid-combat (the standing frame-discipline rule)", function()
      H.setCombat(true)
      H.run("panel", "unlock")
      assert.is_nil(V.root)
      assert.is_false(V.unlocked)
      assert.is_truthy(H.printed[#H.printed]:find("combat"))
    end)

    it("an EXISTING panel unlocks fine in combat — nothing is created", function()
      V.ensureRoot()
      H.setCombat(true)
      H.run("panel", "unlock")
      assert.is_true(V.unlocked)
    end)

    it("HUD off locks it too — an unlock affordance you cannot see is a trap", function()
      V.ensureRoot()
      H.run("panel", "unlock")
      V.Clear()
      assert.is_false(V.unlocked)
      assert.is_false(V.root:IsShown())
    end)
  end)

  ------------------------------------------------------------------------------
  describe("extents — the frame must be grabbable", function()
    local SIZE, GAP, MIN_ICONS = 40, 6, 3
    local function row(n) return n * SIZE + (n - 1) * GAP end

    it("tracks the icon count once past the floor", function()
      assert.are.equal(row(4), (V.RootSize(4)))
      assert.are.equal(row(8), (V.RootSize(8)))
      local _, h = V.RootSize(4)
      assert.are.equal(SIZE, h)
    end)

    it("never falls below the minimum — the ZERO-rows case stays draggable", function()
      assert.are.equal(row(MIN_ICONS), (V.RootSize(0)))
      assert.are.equal(row(MIN_ICONS), (V.RootSize(1)))
      assert.are.equal(row(MIN_ICONS), (V.RootSize(nil)))
    end)

    it("Sync resizes the root to this pulse's row", function()
      V.Sync({ virtual = { INCINERATE, SHADOW_BOLT, 1, 2 } })
      assert.are.equal(row(4), V.root:GetWidth())
      V.Sync({ virtual = { INCINERATE } })
      assert.are.equal(row(MIN_ICONS), V.root:GetWidth())
    end)

    it("a zero-row spec still gets a root, so it can be pre-positioned", function()
      V.Sync({ virtual = {} })
      assert.is_not_nil(V.root)
      assert.are.equal(row(MIN_ICONS), V.root:GetWidth())
    end)

    it("a lone icon stays CENTRED on the anchor despite the wider frame", function()
      -- The floor pads the row rather than left-aligning it, so Phase 1's on-screen position
      -- is unchanged: LEFT edge + pad == the frame's centre minus half an icon.
      V.Sync({ virtual = { INCINERATE } })
      local p = V.buttons[INCINERATE]._points[1]
      assert.are.equal("LEFT", p.point)
      assert.are.equal("LEFT", p.relPoint)
      assert.are.equal((row(MIN_ICONS) - SIZE) / 2, p.dx)
    end)

    it("a full row lays out from the LEFT edge, gap-spaced", function()
      V.Sync({ virtual = { 1, 2, 3, 4 } })
      assert.are.equal(0, V.buttons[1]._points[1].dx)
      assert.are.equal(SIZE + GAP, V.buttons[2]._points[1].dx)
      assert.are.equal(3 * (SIZE + GAP), V.buttons[4]._points[1].dx)
    end)
  end)
end)
