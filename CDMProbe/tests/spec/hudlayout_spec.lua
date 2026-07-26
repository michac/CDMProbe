-- hudlayout_spec.lua — the W4 Phase-5a arbiter for the live Layout + registry
-- producer (HudLayout).  Two halves:
--
--   * Build (pure)  — a list of resolved { cooldownID, spellID, frame } records ->
--                     (layout, registry): number-keyed, base spellID + side carried,
--                     unreadable cid dropped, first cid wins.
--   * Scan (impure) — the icon-viewer walk, driven through stubbed ns accessors, so
--                     the two-viewer sweep + id resolution are exercised off-game.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("HudLayout.Build — records -> (layout, registry)", function()
  local ns, L

  before_each(function()
    ns = H.fresh()
    H.load("HudLayout.lua")
    L = ns.HudLayout
  end)

  it("stamps { spellID, side } into layout and the frame into registry", function()
    local f1 = {}
    local layout, registry = L.Build({
      { cooldownID = 34991, spellID = 105174, frame = f1 },
    })
    assert.are.same({ [34991] = { spellID = 105174, side = "TOPRIGHT" } }, layout)
    assert.are.equal(f1, registry[34991])
  end)

  it("keys by NUMBER, not string (key-type consistency #5)", function()
    local layout = L.Build({ { cooldownID = 671, spellID = 104316, frame = {} } })
    assert.is_not_nil(layout[671])       -- the number key
    assert.is_nil(layout["671"])         -- never a string key
  end)

  it("drops an entry whose cooldownID is not a number (secret/unreadable)", function()
    local layout, registry = L.Build({
      { cooldownID = nil, spellID = 105174, frame = {} },      -- unreadable id
      { cooldownID = "cd", spellID = 104316, frame = {} },     -- string (never happens live, guarded anyway)
      { cooldownID = 42, spellID = 265187, frame = {} },       -- good
    })
    local n = 0
    for _ in pairs(layout) do n = n + 1 end
    assert.are.equal(1, n)
    assert.is_not_nil(layout[42])
    assert.is_nil(registry["cd"])
  end)

  it("keeps the FIRST cooldownID when one repeats (dedup, first frame wins)", function()
    local first, second = { tag = "first" }, { tag = "second" }
    local layout, registry = L.Build({
      { cooldownID = 100, spellID = 111, frame = first },
      { cooldownID = 100, spellID = 111, frame = second },
    })
    assert.are.equal("first", registry[100].tag)
    assert.are.equal(111, layout[100].spellID)
  end)

  it("carries a nil spellID through (an item whose base id read unreadable)", function()
    local layout = L.Build({ { cooldownID = 7, spellID = nil, frame = {} } })
    assert.is_not_nil(layout[7])
    assert.is_nil(layout[7].spellID)
    assert.are.equal("TOPRIGHT", layout[7].side)
  end)

  it("returns empty tables for no entries", function()
    local layout, registry = L.Build()
    assert.are.same({}, layout)
    assert.are.same({}, registry)
  end)
end)

describe("HudLayout.Scan — the live icon-viewer walk (stubbed accessors)", function()
  local ns, L

  before_each(function()
    ns = H.fresh()
    H.load("HudLayout.lua")
    L = ns.HudLayout
  end)

  it("sweeps BOTH icon viewers and resolves base ids, number-keyed", function()
    -- Two fake viewers, each with one item; ids resolved off the item's own fields.
    local essItem = { cd = 34991, base = 105174 }   -- Hand of Gul'dan
    local utItem  = { cd = 119910, base = 48018 }   -- a Utility icon
    local viewers = {
      EssentialCooldownViewer = { essItem },
      UtilityCooldownViewer   = { utItem },
      BuffIconCooldownViewer  = { { cd = 777, base = 264173 } },  -- must be IGNORED
    }
    ns.GetViewer      = function(name) return viewers[name] and { name = name } or nil end
    ns.GetItemFrames  = function(v) return viewers[v.name] or {} end
    ns.ItemCooldownID = function(it) return it.cd end
    ns.ItemBaseSpellID = function(it) return it.base end

    local layout, registry = L.Scan()

    -- Essential + Utility present; the buff-viewer item is not.
    assert.are.same({ spellID = 105174, side = "TOPRIGHT" }, layout[34991])
    assert.are.same({ spellID = 48018, side = "TOPRIGHT" }, layout[119910])
    assert.is_nil(layout[777])
    assert.are.equal(essItem, registry[34991])
    assert.are.equal(utItem, registry[119910])
  end)

  it("skips an item whose cooldownID does not resolve", function()
    ns.GetViewer      = function(name) return name == "EssentialCooldownViewer" and {} or nil end
    ns.GetItemFrames  = function() return { { }, { good = true } } end
    ns.ItemCooldownID = function(it) return it.good and 55 or nil end
    ns.ItemBaseSpellID = function() return 999 end

    local layout = L.Scan()
    assert.is_not_nil(layout[55])
    local n = 0
    for _ in pairs(layout) do n = n + 1 end
    assert.are.equal(1, n)
  end)
end)
