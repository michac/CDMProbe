-- census_spec.lua — the CDM struct census (`/cdmp census`), a TEMPORARY instrument.
--
-- ⚠ DELETE THIS FILE WITH Census.lua.  It exists for the same reason `harness_spec.lua`
-- does: an instrument that cannot observe its subject must SAY SO, and an instrument whose
-- classification is wrong is worse than no instrument — it produces a confident answer to a
-- question it never asked, and we then design against it.
--
-- The census's whole job is the FIVE-WAY distinction: `threw` vs `SECRET` vs
-- `SECRET-TABLE` vs `nil` vs a value.  Collapsing any two of those is precisely how one
-- concludes "Blizzard does not populate this field" when the truth is "we are not allowed
-- to read it" — opposite implications for every fix it is meant to gate.  So each of the
-- five is proved separately, against the REAL Util.lua guards.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local CHAOS_BOLT    = 116858
local INCINERATE    = 29722
local SHADOW_BOLT   = 686
local IMMOLATE_AURA = 157736
local TYRANT        = 265187

describe("CDM struct census", function()
  local ns, Cs

  -- A CDM database + viewers, built per case.  `rows` is cid -> { cats = {...},
  -- info = <table|false>, frame = <table|nil> }.
  local function world(rows)
    _G.Enum.CooldownViewerCategory = { Essential = 0, Utility = 1, TrackedBuff = 2,
                                       TrackedBar = 3, HiddenSpell = -1, HiddenAura = -2 }
    local VALUE = { Essential = 0, Utility = 1, TrackedBuff = 2, TrackedBar = 3,
                    HiddenSpell = -1, HiddenAura = -2 }
    local byCategory, items = {}, {}
    for cid, r in pairs(rows) do
      for _, name in ipairs(r.cats) do
        local v = VALUE[name]
        byCategory[v] = byCategory[v] or {}
        table.insert(byCategory[v], cid)
      end
      if r.frame then r.frame.cooldownID = cid; items[#items + 1] = r.frame end
    end
    _G.C_CooldownViewer = {
      IsCooldownViewerAvailable = function() return true end,
      GetCooldownViewerCategorySet = function(value) return byCategory[value] or {} end,
      GetCooldownViewerCooldownInfo = function(cid)
        local r = rows[cid]
        if r and r.throws then error("refused", 0) end
        return r and r.info or nil
      end,
    }
    ns.VIEWERS = { { frame = "EssentialCooldownViewer", label = "Essential" } }
    ns.GetViewer     = function(n) return n == "EssentialCooldownViewer" and { n = 1 } or nil end
    ns.GetItemFrames = function() return items end
  end

  -- One row of the capture, by cooldownID.
  local function rowFor(cap, cid)
    for _, r in ipairs(cap.rows) do if r.cid == cid then return r end end
  end

  before_each(function()
    ns = H.fresh()
    H.load("Census.lua")
    -- The REAL State.lua: the capture cross-checks its cached hero tree against a fresh
    -- read, and that comparison is only meaningful against the shipping cache.
    H.load("State.lua")
    Cs = ns.Census
    ns.db = {}
    _G.date = function() return "2026-07-31 20:00:00" end
  end)
  after_each(function()
    _G.C_CooldownViewer = nil
    _G.C_ClassTalents = nil
    _G.Enum.CooldownViewerCategory = nil
  end)

  ------------------------------------------------------------------------------
  -- THE LABEL.  Every question is answered PER BUILD, so a capture with the wrong label is
  -- worse than a missing one: it answers a different question and never says so.
  ------------------------------------------------------------------------------
  describe("labelling the build", function()
    it("carries a WALL CLOCK, not just GetTime()", function()
      -- GetTime() is seconds since client start: not comparable across sessions, and the
      -- ring outlives one.  "Which of these is tonight's" must be answerable from the file.
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      assert.equals("2026-07-31 20:00:00", Cs.Capture().when)
    end)

    it("names the spec by id as well as name, and whether it is registered", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      H.setSpecIndex(3); ns.ResolveActiveSpec()
      local cap = Cs.Capture()
      assert.equals("Destruction", cap.spec)
      assert.equals(267, cap.specID)
      assert.is_true(cap.active)
    end)

    it("an UNREGISTERED spec is still named — a passive capture says which one", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      H.setSpecIndex(2); ns.ResolveActiveSpec()      -- Affliction: registered nowhere
      local cap = Cs.Capture()
      assert.equals("Affliction", cap.spec)
      assert.is_false(cap.active)
    end)

    it("reads the hero tree FRESH, not through State's cache", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      local sub = 58
      _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return sub end,
                            GetActiveConfigID = function() return 12345 end }
      assert.equals(58, Cs.Capture().heroID)
      sub = 59                                        -- swapped, and nothing invalidated
      assert.equals(59, Cs.Capture().heroID)          -- the capture still tells the truth
    end)

    it("FLAGS a stale pipeline hero tree — that is a live bug, not a census artefact", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      local sub = 58
      _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return sub end }
      ns.State.ReadHero()                             -- prime State's cache at 58
      sub = 59                                        -- swap, WITHOUT invalidating
      local cap = Cs.Capture()
      assert.equals(59, cap.heroID)                   -- live
      assert.equals("hellcaller", cap.hero)           -- what the pipeline still believes
      assert.is_true(cap.heroStale)
    end)

    it("does NOT cry stale when the pipeline agrees", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return 58 end }
      ns.State.ReadHero()
      assert.is_nil(Cs.Capture().heroStale)
    end)

    it("carries the talent CONFIG id, so two builds in one hero tree are distinguishable", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return 58 end,
                            GetActiveConfigID = function() return 98765 end }
      assert.equals(98765, Cs.Capture().config)
    end)

    it("survives C_ClassTalents being absent entirely", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      local cap = Cs.Capture()
      assert.equals("absent", cap.heroClass)
      assert.is_nil(cap.heroStale)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("the five-way classification — the reason it exists", function()
    it("a readable value reports its type AND its value", function()
      world({ [903] = { cats = { "Essential" },
                        info = { spellID = CHAOS_BOLT, isKnown = true, hasAura = false } } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals("table", r.struct)
      assert.equals("number", r.f.spellID.c)
      assert.equals(CHAOS_BOLT, r.f.spellID.v)
      assert.equals("boolean", r.f.isKnown.c)
      assert.is_true(r.f.isKnown.v)
      assert.equals("boolean", r.f.hasAura.c)
      assert.is_false(r.f.hasAura.v)      -- ⚠ `false` is a VALUE, not an absence
    end)

    it("an ABSENT field is `nil`, distinct from every refusal", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals("nil", r.f.isKnown.c)
      assert.is_nil(r.f.isKnown.v)
    end)

    it("a SECRET field is SECRET, never nil and never a value", function()
      -- This is the distinction the whole instrument turns on: reported as `nil` it would
      -- read "Blizzard does not populate this", which is the opposite conclusion.
      world({ [903] = { cats = { "Essential" },
                        info = { spellID = CHAOS_BOLT, isKnown = H.secretValue() } } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals("SECRET", r.f.isKnown.c)
      assert.equals("<secret>", r.f.isKnown.v)
    end)

    it("a field whose INDEX raises is `threw` — Q4, the §3.9 trigger", function()
      local info = H.poison({ spellID = CHAOS_BOLT, isKnown = true }, { "isKnown" })
      world({ [903] = { cats = { "Essential" }, info = info } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals("table", r.struct)          -- the table itself was fine…
      assert.equals("number", r.f.spellID.c)    -- …and other fields still read…
      assert.equals("threw", r.f.isKnown.c)     -- …but this one raised, and we say so
    end)

    it("a SECRET TABLE struct is refused whole, without indexing it", function()
      local info = H.markSecretTable({ spellID = CHAOS_BOLT })
      world({ [903] = { cats = { "Essential" }, info = info } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals("SECRET-TABLE", r.struct)
      assert.is_nil(r.f)
    end)

    it("a THROWING struct call is `threw`, and the walk continues past it", function()
      world({
        [903] = { cats = { "Essential" }, throws = true, info = { spellID = CHAOS_BOLT } },
        [904] = { cats = { "Essential" }, info = { spellID = INCINERATE } },
      })
      local cap = Cs.Capture()
      assert.equals("threw", rowFor(cap, 903).struct)
      assert.equals(INCINERATE, rowFor(cap, 904).f.spellID.v)   -- not condemned by its neighbour
    end)

    it("an ABSENT struct is `nil`, distinct from a throw", function()
      world({ [903] = { cats = { "Essential" }, info = false } })
      assert.equals("nil", rowFor(Cs.Capture(), 903).struct)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("the six questions it is here to answer", function()
    it("Q1 — a tab-1 row carrying an aura flag is visible in the capture", function()
      world({ [903] = { cats = { "Essential" }, frame = {},
                        info = { spellID = TYRANT, isKnown = true, selfAura = true } } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals("Essential", r.cats)
      assert.is_true(r.f.selfAura.v)
    end)

    it("Q2 — both static override fields on one row are both captured", function()
      world({ [66181] = { cats = { "Essential" }, frame = {},
                          info = { spellID = SHADOW_BOLT, overrideSpellID = CHAOS_BOLT,
                                   overrideTooltipSpellID = INCINERATE } } })
      local r = rowFor(Cs.Capture(), 66181)
      assert.equals(CHAOS_BOLT, r.f.overrideSpellID.v)
      assert.equals(INCINERATE, r.f.overrideTooltipSpellID.v)
    end)

    it("Q3 — the elected SINGULAR link and the static POOL are captured separately", function()
      -- The whole point: `linkedSpellIDs` (plural, static) is documented; `linkedSpellID`
      -- (singular, elected) is not, and whether a FRESH read carries it blocks Phase 3.
      world({ [164597] = { cats = { "Essential" }, frame = {},
                           info = { spellID = 348, linkedSpellIDs = { IMMOLATE_AURA, 445474 } } } })
      local r = rowFor(Cs.Capture(), 164597)
      assert.equals("nil", r.f.linkedSpellID.c)         -- not carried by this (fake) read
      assert.equals("table", r.pool.c)
      assert.equals(2, r.pool.n)
      assert.equals("157736,445474", r.pool.v)
    end)

    it("Q3 — one unreadable pool member does not hide the readable ones", function()
      world({ [164597] = { cats = { "Essential" },
                           info = { spellID = 348,
                                    linkedSpellIDs = { IMMOLATE_AURA, H.secretValue() } } } })
      local r = rowFor(Cs.Capture(), 164597)
      assert.equals("157736,<secret>", r.pool.v)
    end)

    it("Q5 — a cid in TWO category sets is recorded as such", function()
      world({ [903] = { cats = { "Essential", "TrackedBuff" },
                        info = { spellID = CHAOS_BOLT } } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals(2, r.nCats)
      assert.is_not_nil(string.find(r.cats, "Essential", 1, true))
      assert.is_not_nil(string.find(r.cats, "TrackedBuff", 1, true))
    end)

    it("Q6 — the frame-cached source flags and auraDataUnit are read per field", function()
      world({ [903] = { cats = { "Essential" },
                        frame = { wasSetFromCooldown = true, auraDataUnit = "target" },
                        info = { spellID = CHAOS_BOLT } } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals("boolean", r.ff.wasSetFromCooldown.c)
      assert.is_true(r.ff.wasSetFromCooldown.v)
      assert.equals("string", r.ff.auraDataUnit.c)
      assert.equals("target", r.ff.auraDataUnit.v)
      assert.equals("nil", r.ff.wasSetFromAura.c)      -- absent, not refused
    end)

    it("a method Blizzard never defined is `absent`, not `threw`", function()
      -- A capability gap and a restriction are different findings; conflating them would
      -- report the live client as locked down when it simply has no such method.
      world({ [903] = { cats = { "Essential" }, frame = {},
                        info = { spellID = CHAOS_BOLT } } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals("absent", r.m.GetLinkedSpell.c)
    end)

    it("a method that RAISES is `threw`, and one that answers is captured", function()
      world({ [903] = { cats = { "Essential" },
                        frame = { GetLinkedSpell = function() return 445474 end,
                                  GetAuraSpellID = function() error("restricted", 0) end },
                        info = { spellID = CHAOS_BOLT } } })
      local r = rowFor(Cs.Capture(), 903)
      assert.equals(445474, r.m.GetLinkedSpell.v)
      assert.equals("threw", r.m.GetAuraSpellID.c)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("the capture itself", function()
    it("labels combat state, and both labels are reachable", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      assert.equals("OOC", Cs.Capture().combat)
      H.setCombat(true)
      assert.equals("CMB", Cs.Capture().combat)
    end)

    it("NEVER writes a raw secret to SavedVariables", function()
      -- A Secret Value reaching disk writes garbage at best and taints the writer at worst.
      -- Walked exhaustively rather than spot-checked: one missed field is the whole risk.
      world({ [903] = { cats = { "Essential" },
                        info = { spellID = H.secretValue(), isKnown = H.secretValue(),
                                 flags = H.secretValue() } } })
      Cs.Capture()
      local seen = 0
      local function walk(t)
        for k, v in pairs(t) do
          assert.is_false(ns.IsSecret(k), "a secret reached disk as a KEY")
          assert.is_false(ns.IsSecret(v), "a secret reached disk as a VALUE")
          if v == "<secret>" then seen = seen + 1 end
          if type(v) == "table" then walk(v) end
        end
      end
      walk(ns.db.census)
      assert.equals(3, seen)          -- and each one is REPORTED, not silently dropped
    end)

    it("keeps a FULL session's worth: 2 specs x 2 hero trees x OOC/CMB, with headroom", function()
      -- At 8 the ring held exactly one full session and no more, so a single extra manual
      -- capture evicted the OOC baseline everything else is compared against.
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      for _ = 1, 8 do Cs.Capture() end
      assert.equals(8, #ns.db.census)
      for _ = 1, 20 do Cs.Capture() end
      assert.equals(16, #ns.db.census)
    end)

    it("sorts rows by cooldownID, so two captures diff cleanly", function()
      world({
        [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } },
        [111] = { cats = { "Essential" }, info = { spellID = INCINERATE } },
        [500] = { cats = { "Utility" },   info = { spellID = SHADOW_BOLT } },
      })
      local cap = Cs.Capture()
      assert.are.same({ 111, 500, 903 },
        { cap.rows[1].cid, cap.rows[2].cid, cap.rows[3].cid })
    end)

    it("survives an empty database rather than erroring", function()
      world({})
      local cap = Cs.Capture()
      assert.equals(0, cap.cids)
      assert.are.same({}, cap.rows)
    end)

    it("the chat summary runs end to end and names every question", function()
      -- The summary formats values, which is where a secret would taint a whole string —
      -- so it is exercised against a row carrying one.
      world({ [903] = { cats = { "Essential" }, frame = { auraDataUnit = "player" },
                        info = { spellID = TYRANT, selfAura = true,
                                 isKnown = H.secretValue() } } })
      H.printed = {}
      H.run("census", "")
      local all = table.concat(H.printed, "\n")
      for _, q in ipairs({ "Q1", "Q2", "Q3", "Q4", "Q5", "Q6" }) do
        assert.is_not_nil(string.find(all, q, 1, true), "summary never mentioned " .. q)
      end
      assert.is_not_nil(string.find(all, "wowkb.cdmp census", 1, true))
    end)

    it("`clear` empties the ring", function()
      world({ [903] = { cats = { "Essential" }, info = { spellID = CHAOS_BOLT } } })
      Cs.Capture()
      H.run("census", "clear")
      assert.are.same({}, ns.db.census)
    end)
  end)
end)
