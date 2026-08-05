-- curvelab_spec.lua — ⚠ DELETE WITH CurveLab.lua.
--
-- CHEAP BY DESIGN (the assist_spec precedent).  The instrument is temporary and outside the
-- pipeline, so this asserts only the properties that would make it WORSE THAN NOT EXISTING —
-- that is, DISHONEST.  A lab that reports "the channel is dead" when the truth is "we never
-- had a secret to send", or that collapses "the call threw" into "the call did nothing",
-- would send the whole open question the wrong way, and the question is the only reason the
-- file is in the .toc.
--
-- ⚠ WHAT IS IRREDUCIBLY IN-CLIENT, and cannot be faked here at any price: WHETHER A PIXEL
-- MOVED.  The five aspect-less setters have no aspect, no getter and no readback of any
-- kind, and every INERT cell is by definition one where nothing observable changed.  Those
-- are settled by `/cdmp curve card` and a human eye, in game.  What CAN be settled here is
-- that the instrument classifies honestly, refuses safely, and never formats a secret — so
-- that when the eye disagrees with the matrix, the matrix is the thing that gets believed.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("CurveLab — the curve / secret-display lab", function()
  local ns, fx, L

  ------------------------------------------------------------------------------
  -- A minimal client for the two namespaces the lab talks to.  Supplied by the SPEC rather
  -- than by mock_ns, deliberately: nothing in this workspace has ever called these APIs, so
  -- a harness-wide fake would be a model of an API nobody has validated — exactly the shape
  -- the addon's CLAUDE.md warns about.  It lives here, with the file it serves, and dies
  -- with it.
  ------------------------------------------------------------------------------
  local function fakeCurve(kind)
    local c = { _points = {}, _type = 0, _kind = kind }
    function c:SetType(v) self._type = v end
    function c:GetType() return self._type end
    function c:GetPointCount() return #self._points end
    function c:HasSecretValues() return false end
    function c:AddPoint(x, y)
      -- `AllowedWhenUntainted` [LuaCurveObjectAPIDocumentation.lua:12] — a tainted caller
      -- passing a secret is refused.  Modelled, because it is a NEGATIVE CONTROL.
      if H.secret[x] or H.secret[y] then error("AllowedWhenUntainted", 0) end
      self._points[#self._points + 1] = { x, y }
    end
    function c:Evaluate(x)
      -- ⚠ THE LOAD-BEARING REFUSAL.  If this ever succeeds in game, the Tier-1 model the
      -- whole file is built on is wrong [:46-49].
      if H.secret[x] then error("AllowedWhenUntainted", 0) end
      return (kind == "color") and { r = 0.4, g = 0.9, b = 0.5, a = 1 } or 0.5
    end
    return c
  end

  local function fakeDuration(carriesSecret)
    local d = { _secret = carriesSecret and true or false }
    function d:HasSecretValues() return self._secret end
    function d:SetTimeFromStart() end
    function d:IsActive() return true end
    return d
  end

  local function installClient()
    _G.C_CurveUtil = {
      CreateCurve      = function() return fakeCurve("number") end,
      CreateColorCurve = function() return fakeCurve("color") end,
      EvaluateGameCurve = function(_, x)
        if H.secret[x] then error("AllowedWhenUntainted", 0) end
        return 1
      end,
    }
    _G.C_DurationUtil = {
      CreateDuration = function() return fakeDuration(false) end,
      CreateDurationTextBinding = function()
        local b = { _secret = false }
        function b:SetFontString(fs) self._fs = fs end
        function b:SetDuration(d) self._dur = d; self._secret = d and d:HasSecretValues() end
        function b:SetUpdateInterval() end
        function b:Enable() self._on = true end
        function b:HasSecretValues() return self._secret and true or false end
        return b
      end,
      CreateManualClock = function() return {} end,
    }
  end

  local function clearClient()
    _G.C_CurveUtil, _G.C_DurationUtil = nil, nil
    _G.UnitPowerPercent, _G.UnitHealthPercent, _G.UnitExists = nil, nil, nil
    _G.C_Spell.GetSpellCooldownDuration = nil
    _G.C_Spell.GetSpellChargeDuration   = nil
    _G.C_UnitAuras.GetAuraDataByIndex               = nil
    _G.C_UnitAuras.GetAuraDuration                  = nil
    _G.C_UnitAuras.GetAuraDispelTypeColor           = nil
    _G.C_UnitAuras.GetAuraApplicationDisplayCount   = nil
  end

  local function sinkByKey(key)
    for _, s in ipairs(L.Sinks()) do if s.key == key then return s end end
  end

  before_each(function()
    ns, fx = H.fresh()
    H.load("CurveLab.lua")
    L = ns.CurveLab
    ns.db = { curvelab = {} }
  end)
  after_each(clearClient)

  ------------------------------------------------------------------------------
  -- 1. ABSENT is a finding, not a crash.
  ------------------------------------------------------------------------------
  it("degrades to `absent` when the constructors are not there at all", function()
    -- ABSENT and "it refused" are different findings: one says this client has no curve
    -- machinery, the other says the machinery declined.  Collapsing them would answer the
    -- open question with an artefact of our own guard.
    local c = L.Constructors()
    assert.equals("absent", c.CreateCurve.class)
    assert.equals("absent", c.CreateDuration.class)
    assert.equals("absent", c.CreateDurationTextBinding.class)
    local p = L.Probe()                      -- and the whole pass survives it
    assert.is_table(p.cells)
    assert.is_table(L.Lines(p))
  end)

  ------------------------------------------------------------------------------
  -- 2 + 3. A secret renders as a CLASS.  A secret TABLE is named, not indexed.
  ------------------------------------------------------------------------------
  it("a SECRET source renders as a class and never reaches a format", function()
    installClient()
    local s = H.secretValue()
    _G.UnitPowerPercent = function() return s end
    local p = L.Probe()
    assert.equals("SECRET", p.sources.S1.class)
    for _, line in ipairs(L.Lines(p)) do
      assert.is_string(line)
      -- The raw sentinel never reaches text.  `tostring` on a real Secret Value taints the
      -- string it lands in and poisons every row it touches.
      assert.is_nil(line:find("table:", 1, true))
    end
  end)

  it("a SECRET-TABLE colour is NAMED, not indexed", function()
    -- A secret table cannot be indexed AT ALL — a distinct verdict from a readable table
    -- with secret members, which is why `color4` asks both questions before any `.r`.  This
    -- one read decides whether the colour column has any sink at all.
    installClient()
    local t = H.markSecretTable({})
    _G.C_UnitAuras.GetAuraDataByIndex = function() return { auraInstanceID = 4242 } end
    _G.C_UnitAuras.GetAuraDispelTypeColor = function() return t end
    local p = L.Probe()
    assert.equals("SECRET-table", p.sources.S4c.class)
    -- …and the cell REFUSES rather than crashing or silently reporting success.
    local cell = p.cells["S4c|vertex"]
    assert.equals("REFUSED", cell.verdict)
    assert.equals("threw", cell.call)
  end)

  ------------------------------------------------------------------------------
  -- 4. THE TEST THE FILE EXISTS FOR: `threw` ≠ `absent` ≠ `INERT`.
  ------------------------------------------------------------------------------
  it("keeps `absent`, `threw` and INERT as three distinct verdicts", function()
    -- Three fixtures, three outcomes.  Merging any two of these is how an instrument starts
    -- reporting "the channel is dead" for three completely different reasons — and only one
    -- of the three is about the channel.
    installClient()
    local sink = sinkByKey("alpha")
    local s = H.secretValue()

    -- (a) THE SOURCE never produced anything: UNSOURCED, call = absent.  Not a channel fact.
    local a = L.RunCell(sink, { key = "A", kind = "number", call = "absent", class = "absent" },
                        L.Cell("alpha", "A", sink))
    assert.equals("UNSOURCED", a.verdict)
    assert.equals("absent", a.call)

    -- (b) THE SINK refused the call: REFUSED, call = threw.
    local cb = L.Cell("alpha", "B", sink)
    cb.subject.SetAlpha = function() error("refused", 0) end
    local b = L.RunCell(sink, { key = "B", kind = "number", call = "ok", class = "SECRET",
                                value = s }, cb)
    assert.equals("REFUSED", b.verdict)
    assert.equals("threw", b.call)

    -- (c) THE SINK TOOK THE SECRET AND NOTHING FLIPPED: INERT, call = ok.  ⚠ The dangerous
    -- cell — the pixel may or may not have moved, and only the card can say.
    local cc = L.Cell("alpha", "C", sink)
    cc.subject.SetAlpha = function() end       -- accepts, records nothing, flips nothing
    local c = L.RunCell(sink, { key = "C", kind = "number", call = "ok", class = "SECRET",
                                value = s }, cc)
    assert.equals("INERT", c.verdict)
    assert.equals("ok", c.call)

    -- (d) …and the shipping setter, which DOES declare an aspect, is the fourth outcome.
    local cd = L.Cell("alpha", "D", sink)
    local d = L.RunCell(sink, { key = "D", kind = "number", call = "ok", class = "SECRET",
                                value = s }, cd)
    assert.equals("WORKED", d.verdict)
    assert.equals("aspect+", d.landed)
  end)

  it("never drives a nil value into a sink — that REFUSED would be OUR error", function()
    -- ⚠ Found by the first live capture: aimed at Eye Beam, which has NO CHARGES,
    -- `GetSpellChargeDuration` returned nothing and all three duration sinks recorded
    -- REFUSED, carrying a Lua *usage* error raised by our own nil argument.  REFUSED means
    -- "the channel rejected a secret"; here it meant "we asked about a spell with no
    -- charges" — our mistake wearing the client's clothes, in the one column whose result
    -- we most wanted to believe.
    installClient()
    local sink = sinkByKey("cdDur")
    local rec = L.RunCell(sink, { key = "S2c", kind = "duration", call = "ok",
                                  class = "nil", value = nil },
                          L.Cell("cdDur", "S2c", sink))
    assert.equals("UNSOURCED", rec.verdict)
    assert.equals("ok", rec.call)
    assert.not_equal("REFUSED", rec.verdict)
  end)

  it("a THROW from the access-getter is a POSITIVE result, not a failure", function()
    -- `GetEffectiveAlpha` / `IsDesaturated` carry an access precondition, so once the aspect
    -- is on the object they REFUSE — and that refusal IS the proof the aspect landed.  An
    -- instrument that scored it as failure would report the working channel as broken.
    installClient()
    local sink = sinkByKey("desat")          -- the channel with NO non-throwing readback
    local cell = L.Cell("desat", "S", sink)
    local rec = L.RunCell(sink, { key = "S", kind = "number", call = "ok", class = "SECRET",
                                  value = H.secretValue() }, cell)
    assert.equals("threw", rec.access)
    assert.equals("WORKED", rec.verdict)
  end)

  ------------------------------------------------------------------------------
  -- WHICH SPELL THE DURATION COLUMN ASKS ABOUT.
  ------------------------------------------------------------------------------
  describe("L.SpellID", function()
    -- ⚠ THE DEFECT THIS PINS, found by the first live capture: the first cut read
    -- `ns.ActiveSpec.abilities`, which does not exist — the roster IS the spec table,
    -- keyed by spellID (State.lua:218 walks `pairs(specTable)`; :2261 passes `ns.Spec`).
    -- So it silently returned the GCD on every spec and the whole DURATION COLUMN, the
    -- likeliest real win in the file, spent a capture asking about spell 61304 and came
    -- back `clean` on every row. A wrong spellID here does not produce a wrong answer, it
    -- produces UNSOURCED — "we never had a secret to send" — which reads exactly like "the
    -- channel is dead". Hence the second return, and hence this case.
    local ROSTER = {
      [100] = { kind = "button", cadence = "utility" },   -- utility: skipped
      [200] = { kind = "aura" },                          -- not a press: skipped
      [300] = { kind = "button", cadence = "cooldown" },  -- no base CD: not preferred
      [400] = { kind = "button", cadence = "cooldown" },  -- ← the pick
    }

    it("prefers a rotational button whose cooldown the client reports", function()
      ns.Spec = ROSTER
      fx.baseCD[400] = 30
      local id, src = L.SpellID()
      assert.equals(400, id)
      assert.equals("roster", src)
    end)

    it("falls back to any button, and SAYS it fell back", function()
      ns.Spec = ROSTER                       -- no baseCD registered for anything
      local id, src = L.SpellID()
      assert.equals(300, id)                 -- lowest non-aura, non-... first button
      assert.equals("roster-any", src)
    end)

    it("reports `gcd` — never a bare id — when the spec is PASSIVE", function()
      -- Every spec outside the registered four (Vengeance, for one) leaves `ns.Spec` nil,
      -- and there the GCD really is all there is. It must be LOUD, not silent.
      ns.Spec = nil
      local id, src = L.SpellID()
      assert.equals(61304, id)
      assert.equals("gcd", src)
      local p = L.Probe()
      assert.equals("gcd", p.spellSource)
      assert.is_not_nil(table.concat(L.Lines(p), "\n"):find("GLOBAL COOLDOWN", 1, true))
    end)

    it("honours the override above everything", function()
      ns.Spec = ROSTER
      fx.baseCD[400] = 30
      L.spellOverride = 198013
      local id, src = L.SpellID()
      assert.equals(198013, id)
      assert.equals("override", src)
    end)

    it("is DETERMINISTIC — never a pairs()-order pick", function()
      -- An order-dependent choice would make the ring's verdict key differ between sessions
      -- for a reason nobody could see from the capture.
      ns.Spec = ROSTER
      fx.baseCD[300], fx.baseCD[400] = 30, 30
      local first = L.SpellID()
      for _ = 1, 20 do assert.equals(first, (L.SpellID())) end
      assert.equals(300, first)              -- the LOWEST qualifying id, by sort
    end)
  end)

  ------------------------------------------------------------------------------
  -- THE STACK CUE — a threshold cue on a count nothing here is allowed to read.
  ------------------------------------------------------------------------------
  describe("the stack cue", function()
    -- The technique: `GetAuraApplicationDisplayCount(unit, id, min, max)` returns an EMPTY
    -- STRING below `min` [UnitAuraDocumentation.lua:112-128], so a FontString fed it is
    -- invisible below the threshold and shows the count at or above it — the comparison
    -- happens in C and we consume only the visual difference.  What must be true for that
    -- to be honest rather than merely pretty is what this block asserts.
    local IMPS = 296553

    local function fakeItem(id)
      local it = H.newStub()
      it.auraSpellID, it.auraInstanceID, it.auraDataUnit = IMPS, id, "player"
      return it
    end

    local function installViewer(item)
      ns.VIEWERS = { { key = "bufficon", frame = "BuffIconCooldownViewer", label = "Buff (icon)" } }
      ns.GetViewer     = function() return { n = 1 } end
      ns.GetItemFrames = function() return { item } end
      ns.ItemBaseSpellID = function() return nil end
    end

    it("passes the THRESHOLD to the client and never compares anything itself", function()
      local seen
      installViewer(fakeItem(4242))
      _G.C_UnitAuras.GetAuraApplicationDisplayCount = function(unit, id, min, max)
        seen = { unit = unit, id = id, min = min, max = max }
        return ""                              -- below the threshold: the empty string
      end
      L.SetStackThreshold("imps", 7)
      local rec = L.StackRead(L.StackTargets()[1])
      assert.equals("ok", rec.state)
      assert.are.same({ unit = "player", id = 4242, min = 7, max = nil }, seen)
    end)

    it("⚠ reports `id-unreadable` when item.auraInstanceID reads SECRET", function()
      -- THE MEASUREMENT THIS CUE EXISTS TO TAKE.  `GetAuraApplicationDisplayCount` is
      -- `SecretArguments = "AllowedWhenUntainted"`, so a secret instance id cannot be passed
      -- on at all — the technique is CLOSED for that aura.  It must say so loudly, because
      -- the alternative ("no text appeared") is indistinguishable from "you had 3 imps".
      local it = fakeItem(H.secretValue())
      installViewer(it)
      local called = false
      _G.C_UnitAuras.GetAuraApplicationDisplayCount = function() called = true; return "" end
      local rec = L.StackRead(L.StackTargets()[1])
      assert.equals("id-unreadable", rec.state)
      assert.equals("SECRET", rec.idClass)
      assert.is_false(called)                  -- and it must not even try
      assert.is_not_nil(table.concat(L.StackLines({ imps = rec }), "\n")
        :find("CLOSED", 1, true))
    end)

    it("keeps `aura-down` and `id-unreadable` as different findings", function()
      -- Both draw nothing.  One means "you do not have the buff", the other means "we are
      -- not allowed to ask" — opposite implications for whether the cue works at all.
      installViewer(fakeItem(nil))
      assert.equals("aura-down", L.StackRead(L.StackTargets()[1]).state)
      installViewer(fakeItem(4242))
      _G.C_UnitAuras.GetAuraApplicationDisplayCount = function() return "" end
      assert.equals("ok", L.StackRead(L.StackTargets()[1]).state)
    end)

    it("reports `no-frame` rather than silently drawing nothing", function()
      ns.VIEWERS = { { key = "bufficon", frame = "BuffIconCooldownViewer", label = "B" } }
      ns.GetViewer     = function() return { n = 1 } end
      ns.GetItemFrames = function() return {} end
      assert.equals("no-frame", L.StackRead(L.StackTargets()[1]).state)
    end)

    it("never formats the count — it goes to SetText and nowhere else", function()
      -- The count is a SECRET STRING by design.  It must reach the FontString and never a
      -- format, a comparison or SavedVariables.
      local s = H.secretValue()
      installViewer(fakeItem(4242))
      _G.C_UnitAuras.GetAuraApplicationDisplayCount = function() return s end
      local rec = L.StackRead(L.StackTargets()[1])
      assert.equals("SECRET", rec.textClass)
      for _, line in ipairs(L.StackLines({ imps = rec })) do
        assert.is_nil(line:find("table:", 1, true))
      end
      -- …and the ring records the CLASS, never the value.
      local row = L.RingRow({ at = 1, combat = true, cells = {}, sources = {},
                              negatives = {}, constructors = {} })
      assert.is_nil(row.stack and row.stack.imps and row.stack.imps.value)
    end)

    it("⚠ CLEARS a stale number when the aura's frame goes away", function()
      -- MEASURED IN PLAY 2026-08-04: a "4" appeared and never went away.  `paintStack`
      -- painted only the frames the search CURRENTLY returned, so the `no-frame` state ran
      -- the paint loop zero times and the last number stayed on screen forever.  A threshold
      -- cue that stays lit after the buff drops is the worst lie it can tell — its entire
      -- signal is the PRESENCE of text, so stale text reports a threshold that is not met,
      -- which is strictly worse than drawing nothing.
      local item = fakeItem(4242)
      installViewer(item)
      _G.C_UnitAuras.GetAuraApplicationDisplayCount = function() return "4" end
      ns.db.curvelab_stack = true
      L.StackRefresh()
      local drawn
      for _, h in ipairs(L.FindAuraItems(IMPS)) do drawn = h end
      assert.is_not_nil(drawn)
      -- The frame stops carrying the aura entirely — `no-frame`, the paint loop's zero case.
      ns.GetItemFrames = function() return {} end
      L.StackRefresh()
      assert.equals("no-frame", L.stackLast.imps.state)
      -- …and nothing anywhere is still showing a number.
      for _, fs in ipairs(H.frames) do
        local txt = fs.GetText and fs:GetText()
        if type(txt) == "string" then assert.equals("", txt) end
      end
    end)

    it("its STATE is part of the ring's dedup key", function()
      -- ⚠ It was NOT, and a 13-row Demonology capture carried exactly TWO stack rows: the
      -- cue's transitions (`aura-down` -> `ok` -> `id-unreadable`) are invisible to the
      -- matrix's verdicts, so the ring only sampled the cue when something unrelated moved.
      -- A recorder that cannot see its own subject change is the AlertTape lesson restated.
      installViewer(fakeItem(4242))
      _G.C_UnitAuras.GetAuraApplicationDisplayCount = function() return "" end
      ns.db.curvelab_stack = true
      L.StackRefresh()
      local withAura = L.VerdictKey(L.Probe())
      installViewer(fakeItem(nil))          -- the aura drops
      L.StackRefresh()
      assert.are_not.equal(withAura, L.VerdictKey(L.Probe()))
    end)

    it("the thresholds default to what Demonology actually needs", function()
      -- Wild Imps >6 (Implosion's gate is >=6, so 7 is the strict reading) and Demonic
      -- Core's CAP of 4 — different constants, and crossing them is a known trap
      -- (docs/notes.md:149).
      local byKey = {}
      for _, t in ipairs(L.StackTargets()) do byKey[t.key] = t end
      assert.equals(296553, byKey.imps.spellID)
      assert.equals(264173, byKey.core.spellID)
      assert.equals(4, byKey.core.min)
      assert.equals(7, L.SetStackThreshold("imps", 7).min)
      assert.is_nil(L.SetStackThreshold("nope", 3))
    end)
  end)

  ------------------------------------------------------------------------------
  -- POISONED, and — the part that bit — that it STAYS poisoned.
  ------------------------------------------------------------------------------
  describe("anchor contagion", function()
    it("reports POISONED when an aspect-less setter marks the anchor chain", function()
      -- The five aspect-less setters are the only contagion candidates: no aspect means the
      -- object is marked WHOLESALE, which marks its anchoring data secret and propagates
      -- down to its dependents (§4.6(b)).  The dependent CHILD is why each cell has one.
      installClient()
      local sink = sinkByKey("colorTex")
      local rec = L.RunCell(sink, { key = "S1", kind = "number", call = "ok",
                                    class = "SECRET", value = H.secretValue() },
                            L.Cell("colorTex", "S1", sink))
      assert.equals("POISONED", rec.verdict)
      assert.equals("ok", rec.call)            -- ⚠ a finding REGARDLESS of "did it work"
      assert.equals("0>1/0>1", rec.anchor)     -- subject AND its dependent child
    end)

    it("STILL reports POISONED on the next sample — contagion cannot be cleared", function()
      -- ⚠ THE BUG THIS PINS, found by the ring's own dedup: written as an EDGE test the cell
      -- read POISONED once and INERT forever after, so the ring's second row said the
      -- contagion had stopped.  It cannot stop — `SetToDefaults` is IsProtectedFunction and
      -- the widget is memoised — so this is the single most dangerous claim the instrument
      -- could make.  Same reasoning as `landed`'s state test.
      installClient()
      local sink = sinkByKey("colorTex")
      local cell = L.Cell("colorTex", "S1", sink)
      local arg = { key = "S1", kind = "number", call = "ok", class = "SECRET",
                    value = H.secretValue() }
      L.RunCell(sink, arg, cell)
      local again = L.RunCell(sink, arg, cell)
      assert.equals("POISONED", again.verdict)
      assert.equals("1>1/1>1", again.anchor)
    end)

    it("leaves an ASPECT-DECLARING setter's anchor chain clean", function()
      -- The control for the case above, and the correction of a standing worry: `SetAlpha`
      -- was suspected of poisoning the anchor chain and it does NOT — it declares {Alpha}
      -- [SimpleRegionAPIDocumentation.lua:125].  Aim the contagion test at the five.
      installClient()
      local sink = sinkByKey("alpha")
      local rec = L.RunCell(sink, { key = "S1", kind = "number", call = "ok",
                                    class = "SECRET", value = H.secretValue() },
                            L.Cell("alpha", "S1", sink))
      assert.equals("WORKED", rec.verdict)
      assert.equals("0>0/0>0", rec.anchor)
    end)
  end)

  ------------------------------------------------------------------------------
  -- 5. UNSOURCED IS NEVER A PASS.  ⚠ MUTATION-CHECKED.
  ------------------------------------------------------------------------------
  describe("UNSOURCED", function()
    -- ⚠ THE MUTATION: delete the `elseif not L.CarriesSecret(arg)` clause in RunCell's
    -- verdict ladder and ALL THREE cases below go red (they score INERT), while nothing
    -- outside this block moves.  Verified 2026-08-04.  Run it before trusting the block.
    it("is what a CONTROL scores, even though the call succeeded", function()
      installClient()
      local sink = sinkByKey("alpha")
      local rec = L.RunCell(sink, { key = "C2", kind = "number", call = "ok", class = "num",
                                    value = 0.5, control = true },
                            L.Cell("alpha", "C2", sink))
      assert.equals("ok", rec.call)            -- the setter WORKED…
      assert.equals("UNSOURCED", rec.verdict)  -- …and it still proves nothing about secrets
      assert.not_equal("INERT", rec.verdict)
      assert.not_equal("WORKED", rec.verdict)
    end)

    it("turns on what the DURATION OBJECT carries, not on its class", function()
      -- A duration object is NEVER itself secret; it CARRIES the secret.  Class alone would
      -- score every duration cell UNSOURCED (never SECRET) — hiding the column's whole
      -- finding — or every duration cell as sourced, which fakes it for the C3 control.
      installClient()
      local sink = sinkByKey("cdDur")
      local clean = L.RunCell(sink, { key = "C3", kind = "duration", call = "ok",
                                      class = "table", value = fakeDuration(false),
                                      control = true }, L.Cell("cdDur", "C3", sink))
      assert.equals("UNSOURCED", clean.verdict)
      local hot = L.RunCell(sink, { key = "S2", kind = "duration", call = "ok",
                                    class = "table", value = fakeDuration(true) },
                            L.Cell("cdDur", "S2", sink))
      assert.not_equal("UNSOURCED", hot.verdict)
      -- ⚠ `1>1`, not `0>1`: this sink's oracle is asked of the ARGUMENT, so there is no edge
      -- to see.  "The sink accepted an object that carries a secret" IS the §4.8 mechanism
      -- working — the number never enters Lua, so there is nothing else to observe.
      assert.equals("1>1", hot.hsv)            -- the free, always-readable oracle
      assert.equals("WORKED", hot.verdict)
    end)

    it("sees a secret MEMBER inside a readable colour table", function()
      -- ⚠ THE COLOUR COLUMN'S MOST LIKELY REAL SHAPE, and a class test alone gets it wrong:
      -- `GetAuraDispelTypeColor` returns a ColorMixin, and a READABLE table with SECRET
      -- MEMBERS classes as plain `table`.  Scoring that UNSOURCED would report "we never had
      -- a secret to send" about the one source most likely to be sending one.
      installClient()
      local sink = sinkByKey("vertex")
      local c = { r = H.secretValue(), g = 0.2, b = 0.3, a = 1 }
      local rec = L.RunCell(sink, { key = "S4c", kind = "color", call = "ok",
                                    class = "table", value = c },
                            L.Cell("vertex", "S4c", sink))
      assert.not_equal("UNSOURCED", rec.verdict)
      assert.equals("WORKED", rec.verdict)
      -- …and a genuinely clean colour still scores UNSOURCED.
      local clean = L.RunCell(sink, { key = "C2c", kind = "color", call = "ok",
                                      class = "table", value = { r = 1, g = 1, b = 1, a = 1 },
                                      control = true }, L.Cell("vertex", "C2c", sink))
      assert.equals("UNSOURCED", clean.verdict)
    end)
  end)

  ------------------------------------------------------------------------------
  -- 6. ns.Stash on the way to disk.
  ------------------------------------------------------------------------------
  it("degrades a secret to the string \"<secret>\" on the way to SavedVariables", function()
    -- Serializing a Secret Value writes garbage at best and taints the writer at worst, and
    -- an ERROR STRING the client built out of the secret we passed in is still a secret —
    -- which is why the err field goes through ns.Stash too, not just the values.
    local s = H.secretValue()
    local row = L.RingRow({
      at = 1, combat = false, cells = { ["S1|alpha"] = { verdict = "INERT", err = s } },
      sources = { S1 = { class = "SECRET", err = s } },
      negatives = {}, constructors = {},
    })
    assert.equals("<secret>", row.cells["S1|alpha"].err)
    assert.equals("<secret>", row.sources.S1.err)
  end)

  ------------------------------------------------------------------------------
  -- 7 + 8. The ring: dedup by VERDICT with combat in the key, and CAP honoured.
  ------------------------------------------------------------------------------
  describe("the watch ring", function()
    before_each(function()
      installClient()
      _G.UnitPowerPercent = function() return H.secretValue() end
    end)

    it("records nothing while disarmed", function()
      L.Sample()
      assert.equals(0, #ns.db.curvelab)
    end)

    it("dedups by VERDICT, and combat is part of the key", function()
      ns.db.curvelab_on = true
      L.Sample()
      assert.equals(1, #ns.db.curvelab)
      L.Sample()
      assert.equals(1, #ns.db.curvelab)       -- same verdicts ⇒ no new row
      H.setCombat(true)
      L.Sample()
      assert.equals(2, #ns.db.curvelab)       -- combat is in the key
    end)

    it("keeps the BUILD in the key, so a spec swap cannot merge two builds' rows", function()
      -- The AlertTape correction, and a correctness point here rather than a labelling one:
      -- the duration column asks about a spellID resolved off the ACTIVE SPEC, so a swap
      -- with no /reload would file two different measurements under one verdict key and
      -- "the duration sink went inert" would really be "you respecced".
      ns.db.curvelab_on = true
      L.Sample()
      assert.equals(1, #ns.db.curvelab)
      ns.detectedSpecName = "Havoc"
      L.Sample()
      assert.equals(2, #ns.db.curvelab)
      assert.are_not.equal(ns.db.curvelab[1].build, ns.db.curvelab[2].build)
    end)

    it("honours the CAP rather than growing without bound", function()
      ns.db.curvelab_on = true
      for i = 1, 200 do ns.db.curvelab[i] = { key = "filler" .. i } end
      L.Sample()
      assert.equals(200, #ns.db.curvelab)
    end)
  end)

  ------------------------------------------------------------------------------
  -- 9. THE SINK DESCRIPTOR TABLE MATCHES TIER 1.
  ------------------------------------------------------------------------------
  describe("the sink table", function()
    -- ⚠ HAND-TRANSCRIBED FROM THE GENERATED DOCS @ 12.0.7.68887, NEVER FROM `L.Sinks()`.
    -- A table copied out of the code under test is a change-detector wearing a contract's
    -- clothes; the whole value of this case is that it is an INDEPENDENT reading of the
    -- source.  `false` means the setter declares no aspect at all.
    local TIER1 = {
      -- SimpleRegionAPIDocumentation.lua:125, :136, :193, :207
      alpha      = { "Alpha" },
      alphaBool  = { "Alpha" },
      vertex     = { "VertexColor", "Alpha" },
      vertexBool = { "VertexColor", "Alpha" },
      -- SimpleTextureBaseAPIDocumentation.lua:328, :339, :382
      desat      = { "Desaturation" },
      desatBool  = { "Desaturation" },
      rotation   = { "Rotation" },
      -- SimpleStatusBarAPIDocumentation.lua:333, :218, :261
      barValue   = { "BarValue" },
      barMinMax  = { "BarValue" },
      barColor   = { "VertexColor", "Alpha" },
      -- SimpleFontStringAPIDocumentation.lua:655, :530
      text       = { "Text" },
      textFmt    = { "Text" },
      -- The DURATION sinks take an OBJECT, never a secret argument: no aspect, by
      -- construction rather than by omission.
      timerDur = false, cdDur = false, textBind = false,
      -- ⚠ THE FIVE ASPECT-LESS SETTERS.  SimpleTextureBaseAPIDocumentation.lua:441 (SetTexture),
      -- :278 (SetAtlas), :313 (SetColorTexture); SimpleAnimVertexColorAPIDocumentation.lua:46
      -- (SetStartColor), :36 (SetEndColor).
      texture = false, atlas = false, colorTex = false, animStart = false, animEnd = false,
    }
    local ASPECTLESS = { texture = true, atlas = true, colorTex = true,
                         animStart = true, animEnd = true }

    it("declares exactly the Tier-1 aspects, by NAME", function()
      local seen = {}
      for _, sink in ipairs(L.Sinks()) do
        local want = TIER1[sink.key]
        assert.is_not_nil(want, "sink '" .. sink.key .. "' is not in the Tier-1 transcription")
        seen[sink.key] = true
        if want == false then
          assert.is_nil(sink.expectAspect, sink.key .. " must declare NO aspect")
        else
          assert.are.same(want, sink.expectAspect, sink.key .. "'s aspects")
        end
      end
      for key in pairs(TIER1) do
        assert.is_true(seen[key] == true, "sink '" .. key .. "' has gone missing")
      end
    end)

    it("flags EXACTLY the five aspect-less setters", function()
      -- The five are the only anchor-contagion candidates and the only cells with no
      -- readback of any kind.  Flagging a sixth would put a harmless cell on the contagion
      -- watch list; missing one would hide a real risk.
      local flagged = {}
      for _, sink in ipairs(L.Sinks()) do
        if sink.aspectless then flagged[sink.key] = true end
      end
      assert.are.same(ASPECTLESS, flagged)
    end)

    it("never keys an aspect on a literal — seven names share 0x1", function()
      -- `Enum.SecretAspect` reports ObjectDebug/ObjectName/ObjectType/ObjectSecrets/
      -- ObjectSecurity/Attributes/Hierarchy ALL as 1 in the shipped file, so a literal is a
      -- question about seven things at once.  Every declared name must resolve.
      for _, sink in ipairs(L.Sinks()) do
        for _, name in ipairs(sink.expectAspect or {}) do
          assert.is_string(name)
          assert.is_number(_G.Enum.SecretAspect[name], name .. " is not a SecretAspect member")
        end
      end
      assert.equals("Attributes+6", ns.SecretAspectName(1))   -- the alias, named honestly
      assert.equals("Alpha", ns.SecretAspectName(128))
    end)
  end)

  ------------------------------------------------------------------------------
  -- 10 + 11. The sandbox: rooted safely, and refuses to build in combat.
  ------------------------------------------------------------------------------
  describe("the sandbox", function()
    it("is rooted at UIParent and never enters the HUD's Layout", function()
      -- Contagion propagates DOWN the anchor chain, so the only safe parent is one whose
      -- dependents do not matter.  It must never be HudVirtual's panel, a CDM item frame,
      -- or anything ns.GetItemFrames can return — and it must never acquire a cooldownID.
      local sb = L.Sandbox()
      assert.is_table(sb)
      assert.are.equal(_G.UIParent, sb.root:GetParent())
      assert.is_nil(ns.Layout)
      assert.is_nil(sb.root.cooldownID)
      assert.is_false(sb.root:IsShown())     -- hidden by default; the CARD makes it visible
    end)

    it("gives every cell its OWN widget — aspects are sticky and cannot be cleared", function()
      -- `SetToDefaults` is IsProtectedFunction, so a reused widget makes every cell after
      -- the first unfalsifiable: it would be measuring the previous cell's aspect.
      local sink = sinkByKey("alpha")
      local a, b = L.Cell("alpha", "S1", sink), L.Cell("alpha", "S3", sink)
      assert.are_not.equal(a.subject, b.subject)
      assert.are.equal(a, L.Cell("alpha", "S1", sink))   -- …but memoised per (source, sink)
    end)

    it("refuses to CREATE in combat, and says why", function()
      H.setCombat(true)
      local sb, why = L.Sandbox()
      assert.is_nil(sb)
      assert.is_string(why)
      -- …and an ALREADY-BUILT sandbox runs fine in combat, which is where the samples matter.
      H.setCombat(false)
      assert.is_table(L.Sandbox())
      H.setCombat(true)
      assert.is_table(L.Sandbox())
    end)
  end)

  ------------------------------------------------------------------------------
  -- 12. THE CANARY.  ⚠ MUTATION-CHECKED.
  ------------------------------------------------------------------------------
  describe("the UIParent canary", function()
    -- ⚠ THE MUTATION: delete the `if canary.call == "ok" and canary.value and not
    -- L.sandbox.canaryAtBuild` block in RunCell and BOTH cases below go red, and nothing
    -- else moves.  This is the most important safety property in the file: "contagion
    -- propagates down only" is TIER 2, not the generated docs, and if it is wrong this
    -- sandbox poisons the entire UI rather than a hidden corner of it.
    it("halts the run and marks the cell POISONED", function()
      installClient()
      local sink = sinkByKey("alpha")
      local cell = L.Cell("alpha", "S1", sink)     -- builds the sandbox with a clean canary
      _G.UIParent._anchoringSecret = true          -- …and now the real UI goes secret
      local rec = L.RunCell(sink, { key = "S1", kind = "number", call = "ok",
                                    class = "SECRET", value = H.secretValue() }, cell)
      assert.is_true(rec.canary)
      assert.equals("POISONED", rec.verdict)
      assert.is_true(L.halted)
    end)

    it("refuses every further cell once halted", function()
      installClient()
      local sink = sinkByKey("alpha")
      local cell = L.Cell("alpha", "S1", sink)
      _G.UIParent._anchoringSecret = true
      L.RunCell(sink, { key = "S1", kind = "number", call = "ok", class = "SECRET",
                        value = H.secretValue() }, cell)
      local next_ = L.RunCell(sink, { key = "S3", kind = "number", call = "ok",
                                      class = "SECRET", value = H.secretValue() },
                              L.Cell("alpha", "S3", sink))
      assert.equals("REFUSED", next_.verdict)
      assert.equals("refused", next_.call)
    end)
  end)

  ------------------------------------------------------------------------------
  -- The negative controls: a refusal is the PASS, and the model check comes first.
  ------------------------------------------------------------------------------
  describe("the negative controls", function()
    it("scores a REFUSAL as the pass — these exist to fail", function()
      installClient()
      _G.UnitPowerPercent = function() return H.secretValue() end
      local p = L.Probe()
      assert.equals("REFUSED", p.negatives.curveEvaluate.verdict)
      assert.equals("REFUSED", p.negatives.curveAddPoint.verdict)
      assert.equals("REFUSED", p.negatives.gameCurve.verdict)
      assert.equals("REFUSED", p.negatives.cooldownSetCooldown.verdict)
      assert.is_false(p.modelBroken)
    end)

    it("STOPS the whole matrix if curve:Evaluate(secret) SUCCEEDS", function()
      -- If the Tier-1 model is wrong, every other verdict in the capture is suspect and the
      -- honest thing is to say so rather than publish a matrix nobody can trust.
      installClient()
      _G.UnitPowerPercent = function() return H.secretValue() end
      _G.C_CurveUtil.CreateCurve = function()
        local c = fakeCurve("number")
        c.Evaluate = function() return 0.5 end      -- the model breaks
        return c
      end
      local p = L.Probe()
      assert.is_true(p.modelBroken)
      assert.equals("WORKED", p.negatives.curveEvaluate.verdict)   -- inverted: this is BAD
      assert.are.same({}, p.cells)                                 -- …so no matrix was run
      assert.is_not_nil(table.concat(L.Lines(p), "\n"):find("WRONG", 1, true))
    end)

    it("reports UNSOURCED rather than a pass when there was no secret to refuse", function()
      installClient()                                -- no UnitPowerPercent ⇒ no secret scalar
      local p = L.Probe()
      assert.equals("UNSOURCED", p.negatives.curveEvaluate.verdict)
      assert.is_false(p.modelBroken)
    end)
  end)
end)
