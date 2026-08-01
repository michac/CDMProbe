-- assist_spec.lua — the C_AssistedCombat discovery probe (the Phase-4 rider).
--
-- Cheap by design: the instrument is temporary and outside the pipeline, so this asserts
-- only the property that would make it WORSE than not existing — dishonesty.  A readout
-- that says "nil" when the namespace is absent, or prints a value that read secret, would
-- send the whole open question the wrong way, and the question is the only reason the file
-- is in the .toc.
--
-- ⚠ The measurement itself is IN-GAME and cannot be faked here: whether
-- `GetNextCastSpell` returns a readable spellID in combat is the answer we are after.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("Assist — the C_AssistedCombat readability probe", function()
  local ns, A
  before_each(function()
    ns = H.fresh()
    H.load("Assist.lua")
    A = ns.Assist
  end)
  after_each(function() _G.C_AssistedCombat = nil end)

  it("degrades to `absent` when the namespace is not there at all", function()
    -- ABSENT and nil are different findings: one says the API does not exist on this
    -- client, the other says it answered "nothing".  Collapsing them would answer the
    -- open question with an artefact of our own guard.
    local p = A.Probe()
    assert.equals("absent", p.available.class)
    assert.equals("absent", p.next0.class)
    assert.equals("absent", p.rotation.class)
  end)

  it("reports `threw` when the call raises, and does not propagate the error", function()
    _G.C_AssistedCombat = { GetNextCastSpell = function() error("restricted", 0) end }
    local p = A.Probe()
    assert.equals("threw", p.next0.class)
    assert.equals("absent", p.actionSpell.class)   -- a sibling's absence is its own answer
  end)

  it("a SECRET return renders as a CLASS and is never compared or printed", function()
    local s = H.secretValue()
    _G.C_AssistedCombat = { GetNextCastSpell = function() return s end }
    local p = A.Probe()
    assert.equals("SECRET", p.next0.class)
    for _, line in ipairs(A.Lines(p)) do
      assert.is_string(line)
      assert.is_nil(line:find("table:", 1, true))   -- the raw sentinel never reaches text
    end
  end)

  it("a plain-number return is named, because it read plainly", function()
    _G.C_AssistedCombat = { GetNextCastSpell = function() return 116858 end }
    local p = A.Probe()
    assert.equals("num", p.next0.class)
    assert.equals(116858, p.next0.value)
    local joined = table.concat(A.Lines(p), "\n")
    assert.is_not_nil(joined:find("116858", 1, true))
  end)

  it("IsAvailable carries its failureReason alongside the bool", function()
    _G.C_AssistedCombat = { IsAvailable = function() return false, "no rotation spells" end }
    local p = A.Probe()
    assert.equals("bool", p.available.class)
    assert.is_false(p.available.value)
    assert.is_not_nil(table.concat(A.Lines(p), "\n"):find("no rotation spells", 1, true))
  end)

  it("a SECRET rotation TABLE is named as such, not indexed", function()
    -- A secret table cannot be indexed at all — a distinct verdict from a readable table
    -- with secret members, which is why both questions get asked.
    local t = H.markSecretTable({})
    _G.C_AssistedCombat = { GetRotationSpells = function() return t end }
    local p = A.Probe()
    assert.equals("SECRET-table", p.rotation.class)
  end)

  it("a readable rotation table with a SECRET member keeps the member as SECRET", function()
    local s = H.secretValue()
    _G.C_AssistedCombat = { GetRotationSpells = function() return { 116858, s } end }
    local joined = table.concat(A.Lines(A.Probe()), "\n")
    assert.is_not_nil(joined:find("SECRET", 1, true))
    assert.is_not_nil(joined:find("116858", 1, true))
  end)

  ------------------------------------------------------------------------------
  describe("the watch ring", function()
    before_each(function()
      ns.db = { assist = {} }
      _G.C_AssistedCombat = { GetNextCastSpell = function() return 116858 end }
    end)

    it("records nothing while disarmed", function()
      A.Sample()
      assert.equals(0, #ns.db.assist)
    end)

    it("dedups by CLASS, not by value — a value change is noise here", function()
      ns.db.assist_on = true
      A.Sample()
      assert.equals(1, #ns.db.assist)
      _G.C_AssistedCombat.GetNextCastSpell = function() return 29722 end
      A.Sample()
      assert.equals(1, #ns.db.assist)          -- same classes ⇒ no new row
      H.setCombat(true)
      A.Sample()
      assert.equals(2, #ns.db.assist)          -- combat is part of the key
    end)

    it("a SECRET value degrades to the string \"<secret>\" on the way to disk", function()
      ns.db.assist_on = true
      _G.C_AssistedCombat.GetNextCastSpell = function() return H.secretValue() end
      A.Sample()
      assert.equals("<secret>", ns.db.assist[1].next0)
    end)
  end)
end)
