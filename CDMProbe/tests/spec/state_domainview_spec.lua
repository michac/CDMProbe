-- state_domainview_spec.lua — State's DOMAIN VIEW: the ROSTER ANCHOR (Phase 5), the
-- aura-lifecycle latch (C) and the charge napkin (C2).
--
-- WHY THIS FILE EXISTS.  The first live session proved `state.abilities` was NOT what its
-- own contract says it is.  State anchored on the CDM database with `allowUnlearned = true`,
-- so the fold promoted rows for spells the character has not talented and rows the Layout
-- can never draw; both read `ready` forever, so they won the priority list every GCD.  One
-- session logged **216 dropped Soul Fire cues** from an untalented Soul Fire outranking the
-- whole rotation.
--
-- ⚠ ROSTER-STATE-PLAN PHASE 5 CHANGED THE ANSWER, NOT THE QUESTION.  The fix used to be a
-- FILTER — remove rows we cannot trust — and a filter's failure mode is that it silently
-- deletes a REAL button.  The domain view is now anchored on the SPEC'S DECLARED ROSTER, so
-- the phantom never enters in the first place (it is not declared, or it is declared and
-- marked `known = false`, which `Coach.Classify` refuses), and NOTHING is deleted: every
-- declared ability is present and visible in the pulse, the decision log and Coverage.  The
-- tests below therefore pin BOTH directions of the new contract — the phantom cannot win,
-- AND the survivor is still there, AND the knownness verdict is on the row where a capture
-- can see it.
--
-- It loads the REAL State.lua and stubs only what genuinely needs a live client (the
-- C_CooldownViewer database and frame discovery) — the `viewers_spec` doctrine: a stub
-- proves the caller works GIVEN the collaborator, never that the collaborator exists.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

-- Real Destruction ids, so a verdict reads as the ability it actually is.  ⚠ AND THE SPEC
-- MUST BE DESTRUCTION EVERYWHERE IN THIS FILE: under the roster anchor an id the active spec
-- does not declare gets no row at all, so running these under the harness's default
-- Demonology would assert absences that are true for the wrong reason.
local SOUL_FIRE   = 6353
local INCINERATE  = 29722
local CHAOS_BOLT  = 116858
local CONFLAGRATE = 17962
local IMMOLATE_AURA = 157736   -- cid 133441, the BuffBar row
local IMMOLATE_CAST = 348      -- cid 164597, the Essential row

--------------------------------------------------------------------------------
-- A raw CDM row, shaped exactly as St.Build emits one into `cooldowns`.
--------------------------------------------------------------------------------
local function row(cid, base, opts)
  opts = opts or {}
  return {
    cooldownID = cid,
    category   = opts.category or "Essential",
    spellID    = base,
    identity   = opts.identity or base,
    liveSpellID = opts.live or base,
    isKnown    = opts.isKnown,           -- nil = unreadable, and NOT a verdict
    displayable = opts.displayable ~= false,
    cd = opts.cd or { state = "unknown", readable = false, source = "none" },
    charge = opts.charge,
    aura = opts.aura,
    glow = { active = false, readable = true },
  }
end

--------------------------------------------------------------------------------
describe("State domain view — the ROSTER ANCHOR (Phase 5)", function()
  local ns, St, fx
  before_each(function()
    ns, fx = H.fresh()
    H.setSpecIndex(3)            -- Destruction: every id in this file is one of its own
    ns.ResolveActiveSpec()
    H.load("State.lua")
    St = ns.State
  end)

  ------------------------------------------------------------------------------
  -- `St.RosterView` is PURE given its injected `known` reader, which is what lets the
  -- whole anchor be arbitrated off-game.  Signature:
  --   (cooldowns, foldKey, roster, edges, drawable, known)
  --     -> abilities, dotEdges, auraFrames, virtual, knownReadable
  ------------------------------------------------------------------------------
  describe("St.RosterView (pure)", function()
    local function view(cooldowns, opts)
      opts = opts or {}
      local knownMap = opts.known or {}
      return St.RosterView(cooldowns, opts.fold, ns.Spec, opts.edges,
                           opts.drawable ~= false,
                           function(id) return knownMap[id] end)
    end

    it("a declared ability finds its row and is keyed by the id the SPEC named", function()
      local abilities = view({ [901] = row(901, CHAOS_BOLT) }, { known = { [CHAOS_BOLT] = true } })
      assert.is_not_nil(abilities[CHAOS_BOLT])
      assert.equals(901, abilities[CHAOS_BOLT].display.cooldownID)
      assert.equals(CHAOS_BOLT, abilities[CHAOS_BOLT].identity)
      assert.is_true(abilities[CHAOS_BOLT].known)
    end)

    it("a row NO declared ability claims never reaches abilities at all", function()
      -- 999999 is not in any roster.  Before Phase 5 the CDM database decided what existed,
      -- so this row would have become a pressable ability nobody asked for.
      local abilities = view({ [901] = row(901, 999999) })
      assert.is_nil(abilities[999999])
      assert.is_nil(next(abilities))
    end)

    it("an UNLEARNED ability is MARKED, not deleted — the §6.1 decision", function()
      local abilities = view({ [902] = row(902, SOUL_FIRE, { isKnown = false }) },
                             { known = { [SOUL_FIRE] = false } })
      assert.is_not_nil(abilities[SOUL_FIRE], "the row must still be visible in the pulse")
      assert.is_false(abilities[SOUL_FIRE].known)
    end)

    it("an UNREADABLE knownness is the STRING \"unknown\", never nil and never a guess", function()
      -- nil has to keep meaning "nobody asked", which is what a hand-built fixture carries;
      -- "we asked and came away with nothing" needs a positive value of its own.
      local abilities = view({ [904] = row(904, CHAOS_BOLT, { isKnown = nil }) })
      assert.is_not_nil(abilities[CHAOS_BOLT])
      assert.equals("unknown", abilities[CHAOS_BOLT].known)
    end)

    it("the SPELLBOOK outranks the row's isKnown — it asks about the ABILITY", function()
      -- The Hellcaller shape: cid 66181's base (Shadow Bolt) is unlearned while the ability
      -- it draws is pressed every GCD.  Letting the row's flag win bars the floor press.
      local abilities = view({ [905] = row(905, CHAOS_BOLT, { isKnown = false }) },
                             { known = { [CHAOS_BOLT] = true } })
      assert.is_true(abilities[CHAOS_BOLT].known)
    end)

    it("...and the row's isKnown is the FALLBACK when the spellbook refuses", function()
      local abilities = view({ [906] = row(906, CHAOS_BOLT, { isKnown = false }) })
      assert.is_false(abilities[CHAOS_BOLT].known)
    end)

    it("Essential outranks Utility for the same ability", function()
      local abilities = view({
        [907] = row(907, CHAOS_BOLT, { category = "Utility" }),
        [908] = row(908, CHAOS_BOLT, { category = "Essential" }),
      }, { known = { [CHAOS_BOLT] = true } })
      assert.equals(908, abilities[CHAOS_BOLT].display.cooldownID)
    end)

    it("ONE ROW, ONE ABILITY — a contested row goes to the identity match", function()
      -- cid 66181 carries Incinerate on rung 3 and Chaos Bolt on rung 4, so both declared
      -- ids match it.  Letting both claim it is how one ability's cooldown ends up filed
      -- under another's key, which is the whole defect family Phase 5 removes.
      local contested = row(66181, 686, { identity = INCINERATE })
      contested.overrideSpellID = CHAOS_BOLT
      contested.overrideTooltipSpellID = INCINERATE
      local abilities = view({ [66181] = contested },
                             { known = { [INCINERATE] = true, [CHAOS_BOLT] = true } })
      assert.is_not_nil(abilities[INCINERATE])
      assert.equals(686, abilities[INCINERATE].spellID)   -- the raw base is still carried
      assert.is_nil(abilities[CHAOS_BOLT])
    end)

    it("an UNDRAWABLE row keeps its readings and takes OUR display handle", function()
      -- The Hellcaller shape again, from the drawing side.  Before Phase 5 this was a
      -- `no-icon` DROP followed by a from-scratch static row, throwing the readings away.
      local abilities, _, _, virtual = view({
        [903] = row(903, CHAOS_BOLT),                                   -- something IS drawn
        [909] = row(909, INCINERATE, { displayable = false,
                                       cd = { state = "on-cooldown", remaining = 4,
                                              readable = true, source = "live" } }),
      }, { known = { [INCINERATE] = true, [CHAOS_BOLT] = true } })
      assert.is_not_nil(abilities[INCINERATE])
      assert.equals("on-cooldown", abilities[INCINERATE].cd.state)      -- the real reading
      assert.equals(4, abilities[INCINERATE].cd.remaining)
      -- …and ours to draw.  (Membership, not equality: with only two rows on this synthetic
      -- board every other declared button is untracked too, which is correct and beside the
      -- point here — `exactly one virtual row per spec` below is where that is pinned.)
      local drawnByUs = false
      for _, id in ipairs(virtual) do if id == INCINERATE then drawnByUs = true end end
      assert.is_true(drawnByUs)
    end)

    it("NO FRAME MAP ⇒ nothing is synthesised (the v0.32.25 wholesale shape)", function()
      local _, _, _, virtual = view(
        { [905] = row(905, CHAOS_BOLT, { displayable = false }) },
        { drawable = false, known = { [CHAOS_BOLT] = true, [INCINERATE] = true } })
      assert.are.same({}, virtual)
    end)

    it("folds by the OOC-cached base when a combat row's spellID is unreadable", function()
      local r = row(910, nil)
      r.spellID, r.identity, r.liveSpellID = nil, nil, nil
      local abilities = view({ [910] = r },
        { fold = { [910] = CONFLAGRATE }, known = { [CONFLAGRATE] = true } })
      -- The join is by ID, so a row with no readable id claims nothing — but the fold key
      -- still resolves it for the SIGNAL folds, and its unreadability is what suppresses
      -- synthesis (an unprovable negative is not a licence to draw a second icon).
      assert.is_nil(abilities[CONFLAGRATE])
    end)

    ----------------------------------------------------------------------------
    -- THE KNOWNNESS WHOLESALE GUARD (§6.1).  ⚠ MUTATION-CHECKED: delete the
    -- `(asked == 0) or sawReadable` term in State.lua's rosterView and this goes red.
    ----------------------------------------------------------------------------
    it("knownReadable is TRUE when at least one ability answered", function()
      local _, _, _, _, ok = view({ [901] = row(901, CHAOS_BOLT) },
                                  { known = { [CHAOS_BOLT] = true } })
      assert.is_true(ok)
    end)

    it("knownReadable is FALSE when the whole roster refused — a broken read, not a bare character", function()
      -- No spellbook answer and no struct flag anywhere: every declared ability reads
      -- "unknown".  Left unguarded that bars the ENTIRE roster from winning at once, which
      -- is the v0.32.25 total-outage shape with no CDM breadth left to fall back on.
      local _, _, _, _, ok = view({ [901] = row(901, CHAOS_BOLT, { isKnown = nil }) })
      assert.is_false(ok)
    end)

    it("an EMPTY roster is not a refused read — there was nothing to ask", function()
      local _, _, _, _, ok = St.RosterView({}, nil, {}, nil, true, function() return nil end)
      assert.is_true(ok)
    end)
  end)

  ------------------------------------------------------------------------------
  -- The live path: a REAL St.Build against a faked CDM database + viewers.
  ------------------------------------------------------------------------------
  describe("St.Build end to end", function()
    local CID = { sf = 901, inc = 902, cb = 903 }

    before_each(function()
      _G.Enum.CooldownViewerCategory = { Essential = 0, Utility = 1 }
      _G.C_CooldownViewer = {
        GetCooldownViewerCategorySet = function(value)
          if value == 0 then return { CID.sf, CID.inc, CID.cb } end
          return {}
        end,
        GetCooldownViewerCooldownInfo = function(cid)
          if cid == CID.sf  then return { spellID = SOUL_FIRE,  isKnown = false } end
          if cid == CID.inc then return { spellID = INCINERATE, isKnown = true } end
          if cid == CID.cb  then return { spellID = CHAOS_BOLT, isKnown = true } end
        end,
      }
      -- Frame discovery: Chaos Bolt has an icon, Incinerate does not.
      ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
      local items = { { cooldownID = CID.sf }, { cooldownID = CID.cb } }
      ns.GetViewer     = function(name) return name == "EssentialCooldownViewer" and { n = 1 } or nil end
      ns.GetItemFrames = function() return items end
      -- The spellbook is the AUTHORITY for knownness (Phase 5), so the world has to state
      -- it: Chaos Bolt and Incinerate are talented, Soul Fire is not.  The CDM struct above
      -- agrees, which is the normal case — where they disagree is its own test.
      fx.known[CHAOS_BOLT] = true
      fx.known[INCINERATE] = true
      ns.OnLogin()   -- builds the category/power name caches
    end)

    after_each(function()
      _G.C_CooldownViewer = nil
      _G.Enum.CooldownViewerCategory = nil
    end)

    it("the RAW cooldowns view still holds every row — it is the diagnostic view", function()
      local pulse = St.Build(false)
      assert.is_not_nil(pulse.cooldowns[CID.sf])
      assert.is_not_nil(pulse.cooldowns[CID.inc])
      assert.is_not_nil(pulse.cooldowns[CID.cb])
      assert.is_false(pulse.cooldowns[CID.inc].displayable)
      assert.is_true(pulse.cooldowns[CID.cb].displayable)
    end)

    it("abilities carries every declared ability, MARKED rather than filtered", function()
      -- The Phase-5 inversion, end to end.  All three rows survive; what tells them apart is
      -- `known`, and it is `Coach.Classify` — not this stage — that refuses a `false` one.
      local pulse = St.Build(false)
      assert.is_not_nil(pulse.abilities[CHAOS_BOLT])
      assert.is_not_nil(pulse.abilities[INCINERATE])
      assert.is_not_nil(pulse.abilities[SOUL_FIRE])
      assert.is_true(pulse.abilities[CHAOS_BOLT].known)
      assert.is_false(pulse.abilities[SOUL_FIRE].known)   -- the spellbook default
    end)

    it("the knownness verdict rides the ROW, where a capture can see it", function()
      -- The replacement for `pulse.dropped`: the reason an ability will not be picked is on
      -- the pulse rather than inferable only from its absence.  (The decision log's `DR:`
      -- column reads exactly this.)
      local pulse = St.Build(false)
      assert.is_false(pulse.abilities[SOUL_FIRE].known)
      assert.is_true(pulse.knownReadable)
    end)

    it("an UNDRAWABLE declared ability keeps its row and becomes ours to draw", function()
      -- Incinerate: known, talented, pressed constantly — and with no live item frame.  That
      -- is a DISPLAY limit, and Phase 5 stops it being enforced at the decision layer.
      local pulse = St.Build(false)
      assert.is_false(pulse.cooldowns[CID.inc].displayable)
      assert.is_true(pulse.abilities[INCINERATE].virtual)
      assert.equals(-INCINERATE, pulse.abilities[INCINERATE].display.cooldownID)
    end)

    it("NO viewers at all ⇒ abilities is NOT empty, and nothing is synthesised", function()
      -- The guard with the largest blast radius, asserted where it is actually DECIDED (a
      -- pure-function test of the flag proves nothing about how Build computes it).  Viewers
      -- absent — login, CDM off, a relayout mid-pulse — must never empty `abilities`, which
      -- is precisely the shape of the v0.32.25 total outage; and it must not put OUR icon on
      -- screen for the whole rotation on the strength of a read that refused either.
      ns.GetItemFrames = function() return {} end
      local pulse = St.Build(false)
      assert.is_not_nil(pulse.abilities[INCINERATE])
      assert.is_not_nil(pulse.abilities[CHAOS_BOLT])
      assert.is_nil(pulse.abilities[INCINERATE].virtual)
      assert.are.same({}, pulse.virtual)
    end)
  end)

  ------------------------------------------------------------------------------
  -- `usable` — THE AFFORDABILITY VERDICT (2026-08-03).  State's third per-ability read,
  -- added after the Havoc flight, where every Fury gate compared against a fabricated zero
  -- because `UnitPower(player, Fury)` is a SECRET VALUE and always will be (Fury is a
  -- PRIMARY resource; primary resources are secret, per Blizzard's own blue post).
  -- `C_Spell.IsSpellUsable` answers "can I pay for this" per spell without exposing the
  -- resource, and this block proves the PLUMBING — that it is read at all, about the right
  -- id, and that a refusal stays absent rather than becoming `false`.
  --
  -- ⚠ DELIBERATELY SPEC-AGNOSTIC, AND ON DESTRUCTION LIKE THE REST OF THIS FILE.  Fury's
  -- secrecy is what MOTIVATED the read but nothing here is Fury-specific: the rule is "an
  -- ability the spec declares with `spends` gets asked about its LIVE id", which Chaos Bolt
  -- (spends = "shards") and its Ruination override state exactly.  The Fury-specific
  -- behaviour — which gates consume the verdict — belongs to coach_havoc_apl_spec.
  --
  -- ⚠ IT DRIVES THE **CLIENT-LEVEL** FAKE, never a stub of `ns.SpellUsable`.  A harness that
  -- stubs the reader cannot catch a mis-wired one: that is how Retribution's cost bug
  -- survived 76 green cases and how the Fury bug survived 100.
  ------------------------------------------------------------------------------
  describe("St.Build affordability reads", function()
    local CID_CB, RUINATION = 920, 433885
    -- Same RESTORE discipline as the charge block below — see its banner.  A deletion that
    -- outlives its file is exactly the leak H.installGlobals() exists to close.
    local realIsSpellUsable
    -- `live` optionally overrides the row's display identity (the Ruination transform).
    local function withUsable(live)
      realIsSpellUsable = _G.C_Spell.IsSpellUsable
      _G.Enum.CooldownViewerCategory = { Essential = 0 }
      _G.C_CooldownViewer = {
        GetCooldownViewerCategorySet = function(v) return v == 0 and { CID_CB } or {} end,
        GetCooldownViewerCooldownInfo = function()
          return { spellID = CHAOS_BOLT, isKnown = true,
                   overrideSpellID = live, linkedSpellIDs = {} }
        end,
      }
      ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
      ns.GetViewer     = function() return { n = 1 } end
      ns.GetItemFrames = function() return { { cooldownID = CID_CB } } end
      ns.OnLogin()
    end

    after_each(function()
      _G.C_CooldownViewer = nil
      _G.Enum.CooldownViewerCategory = nil
      _G.C_Spell.IsSpellUsable = realIsSpellUsable
    end)

    it("puts the verdict on the ability record, asked about the ROSTER spellID", function()
      withUsable()
      fx.usable[CHAOS_BOLT] = { usable = false, insufficientPower = true }
      local u = St.Build(false).abilities[CHAOS_BOLT].usable
      assert.is_true(u.readable)
      assert.is_false(u.usable)
      assert.is_true(u.insufficientPower)
      -- ⚠ ASSERT WHICH ID WAS ASKED, not just the outcome.  "One ability's fact filed under
      -- another ability's key" is the bug class the roster anchor exists to prevent, and an
      -- outcome-only assertion cannot see it.
      assert.equals(CHAOS_BOLT, u.asked)
      assert.equals(CHAOS_BOLT, H.asked.usable[1])
    end)

    -- ⚠ THE LIVE ID, NOT THE BASE.  A transformed frame casts the OVERRIDE, and it is the
    -- override's own cost the client is checking — asking about the base answers about a
    -- spell we are not about to press.  On Havoc this is Annihilation riding Chaos Strike;
    -- here it is Ruination riding Chaos Bolt, which is the same shape and spec-agnostic.
    it("asks about the LIVE id when the row is transformed", function()
      withUsable(RUINATION)
      fx.usable[RUINATION]  = { usable = true,  insufficientPower = false }
      fx.usable[CHAOS_BOLT] = { usable = false, insufficientPower = true }
      local u = St.Build(false).abilities[CHAOS_BOLT].usable
      assert.equals(RUINATION, u.asked)
      assert.is_false(u.insufficientPower)      -- Ruination's answer, not Chaos Bolt's
      assert.equals(RUINATION, H.asked.usable[1])
      assert.equals(1, #H.asked.usable)         -- and the base was never asked at all
    end)

    -- ⚠⚠ ABSENT IS NEVER `false`.  A refusal carries NO `insufficientPower` member at all, so
    -- "we could not ask" and "you cannot afford it" stay distinguishable.  Collapsing them is
    -- the absent-is-never-zero rule broken one level up — and it is the entire lesson of the
    -- 2026-08-03 flight, where `value or 0` turned an unreadable rail into a confident zero.
    it("a refused read is ABSENT, never a false verdict", function()
      withUsable()
      _G.C_Spell.IsSpellUsable = function() return nil end
      local u = St.Build(false).abilities[CHAOS_BOLT].usable
      assert.is_false(u.readable)
      assert.is_nil(u.usable)
      assert.is_nil(u.insufficientPower)
    end)

    -- The read is FENCED ON THE SPEC'S `spends`: this is a guarded call per ability per pulse
    -- at 10 Hz, and the roster anchor's sizing win came precisely from not making reads for
    -- rows nothing claims.  Conflagrate GENERATES shards, so it can never report
    -- insufficient power and is never asked.
    it("never asks about an ability the spec does not declare as spending", function()
      realIsSpellUsable = _G.C_Spell.IsSpellUsable
      _G.Enum.CooldownViewerCategory = { Essential = 0 }
      _G.C_CooldownViewer = {
        GetCooldownViewerCategorySet = function(v) return v == 0 and { CID_CB } or {} end,
        GetCooldownViewerCooldownInfo = function()
          return { spellID = CONFLAGRATE, isKnown = true, linkedSpellIDs = {} }
        end,
      }
      ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
      ns.GetViewer     = function() return { n = 1 } end
      ns.GetItemFrames = function() return { { cooldownID = CID_CB } } end
      ns.OnLogin()
      fx.usable[CONFLAGRATE] = { usable = true, insufficientPower = false }
      local u = St.Build(false).abilities[CONFLAGRATE].usable
      assert.is_false(u.readable)
      assert.equals(0, #H.asked.usable)
    end)
  end)

  ------------------------------------------------------------------------------
  -- `charge.charged` — the MEASURED "does this have a charge pool", which is what the
  -- brain keys on.  It used to be gated on the CDM struct's `charges` flag, making the
  -- whole napkin depend on one flag being right, with no symptom if it was not: a
  -- never-seeded napkin is indistinguishable from an ability with no charges.
  ------------------------------------------------------------------------------
  describe("St.Build charge reads", function()
    local CID_CONF = 910
    -- ⚠ RESTORE, don't delete.  This block replaces a `_G` fake, and the after_each used to
    -- set it to nil — which is not "put it back", it is "remove the harness's own client
    -- surface for whatever runs next".  Globals are installed at file scope AND from
    -- H.fresh(), but a deletion that outlives its file is exactly the leak
    -- H.installGlobals() exists to close; don't hand it a fresh one.
    local realGetSpellCharges
    local function withCharges(cur, max)
      realGetSpellCharges = _G.C_Spell.GetSpellCharges
      _G.Enum.CooldownViewerCategory = { Essential = 0 }
      _G.C_CooldownViewer = {
        GetCooldownViewerCategorySet = function(v) return v == 0 and { CID_CONF } or {} end,
        -- ⚠ `charges = false` ON PURPOSE: Conflagrate genuinely has 2 charges, so this is
        -- the struct flag being wrong/absent — the case the old gate turned into silence.
        GetCooldownViewerCooldownInfo = function() return { spellID = CONFLAGRATE,
                                                            isKnown = true, charges = false } end,
      }
      _G.C_Spell.GetSpellCharges = function()
        return { currentCharges = cur, maxCharges = max }
      end
      ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
      ns.GetViewer     = function() return { n = 1 } end
      ns.GetItemFrames = function() return { { cooldownID = CID_CONF } } end
      ns.OnLogin()
    end

    after_each(function()
      _G.C_CooldownViewer = nil
      _G.Enum.CooldownViewerCategory = nil
      _G.C_Spell.GetSpellCharges = realGetSpellCharges
    end)

    it("reports a real charge pool even when the struct flag says otherwise", function()
      withCharges(1, 2)
      local ch = St.Build(false).abilities[CONFLAGRATE].charge
      assert.is_true(ch.charged)
      assert.equals(1, ch.cur)
      assert.equals(2, ch.max)
      assert.equals("live", ch.source)
    end)

    -- ⚠ INVERTED 2026-08-03, on a measurement.  This asserted `is_nil(ch.charged)` and that
    -- was the defect: a ONE-charge charge category renders like an ordinary cooldown in the
    -- CDM, so "max of 1 means no charges" looked right and silently disabled the whole
    -- readiness model on those rows.  Blade of Justice read ready on 4419 lines of one
    -- flight because of it.  §3.3's GetSpellCastCount fallback, which the old expectation
    -- cited, governs the RENDERED ChargeCount string — not what GetSpellCharges returns.
    --     184575 Blade of Justice 1/1 rc=9.312 · 20271 Judgment 1/1 rc=10.243
    --     31884  Avenging Wrath   nil  (ordinary cooldown — the API refuses)
    it("a max of 1 IS a charge pool — the client answered, so believe it", function()
      withCharges(1, 1)
      local ch = St.Build(false).abilities[CONFLAGRATE].charge
      assert.is_true(ch.charged)
      assert.equals(1, ch.cur)
      assert.equals(1, ch.max)
      assert.equals("live", ch.source)
    end)

    -- THE CONTROL: an ordinary cooldown is excluded by the API REFUSING, not by its max.
    -- This is what makes `max >= 1` safe rather than roster-swallowing.
    it("an ordinary cooldown (the read refuses) is still NOT a charge pool", function()
      withCharges(1, 1)                                        -- builds the row + CDM fakes
      _G.C_Spell.GetSpellCharges = function() return nil end    -- ...then the API refuses
      local ch = St.Build(false).abilities[CONFLAGRATE].charge
      assert.is_nil(ch.charged)
      assert.equals(0, ch.max)
    end)

    -- ⚠ THE KEY IS THE POOL, NOT THE COOLDOWN ID (2026-08-03).  Conflagrate declares no
    -- `chargePool`, so its pool key is its own roster spellID — which is the point: an
    -- ability that is nobody's override keys on itself and nothing about it changed.  This
    -- read was `CID_CONF` until the Havoc flight; see State.lua's `chargeEst` header.
    it("seeds the napkin off the exact read, and binds it for the spend", function()
      withCharges(2, 2)
      St.Build(false)
      assert.equals(2, (St.Charges.Read(CONFLAGRATE)))
      St.Charges.Spend(CONFLAGRATE)          -- the binding must have happened in Build
      assert.equals(1, (St.Charges.Read(CONFLAGRATE)))
    end)

    -- Build must wire the ALERT path too, not just the spend path — they are two different
    -- maps and only the spend one was ever asserted here.
    it("binds the row's cooldownID to the pool, so a recharge alert lands", function()
      withCharges(2, 2)
      St.Build(false)
      assert.equals(CONFLAGRATE, St.Charges.PoolOfCid(CID_CONF))
      St.Charges.Spend(CONFLAGRATE)
      St.Acquire()                           -- onAlert drops everything at zero consumers
      St.OnAlert({ cooldownID = CID_CONF },
                 _G.Enum.CooldownViewerAlertEventType.ChargeGained)
      St.Release()
      assert.equals(2, (St.Charges.Read(CONFLAGRATE)))
    end)

    it("falls back to the napkin estimate once the live read goes dark", function()
      withCharges(2, 2)
      St.Build(false)                        -- seed OOC
      _G.C_Spell.GetSpellCharges = nil       -- combat: the read refuses
      St.Charges.Spend(CONFLAGRATE)
      local ch = St.Build(false).abilities[CONFLAGRATE].charge
      assert.is_true(ch.charged)
      assert.equals(1, ch.cur)
      assert.equals("napkin", ch.source)
      assert.is_false(ch.readable)           -- an estimate is never laundered as a read
    end)

    -- ── THE `chargePool` WIRING, ON HAVOC (2026-08-03) ──────────────────────────────────
    -- The cases above run Destruction, where every charged ability is its own pool — so
    -- they pass whether or not Build reads `chargePool` at all.  MUTATION-CHECKED: replace
    -- `(specInfo and specInfo.chargePool) or rid` with a bare `rid` and this block goes red
    -- while the rest of the suite stays green, which is exactly why it exists.
    --
    -- Consuming Fire 452487 is Immolation Aura 258920 in demon form: one button, one shared
    -- in-game charge pool (confirmed in game), two CDM rows.  Its row must resolve to the
    -- BASE's pool, or a press in Meta debits an estimate the base form never reads.
    describe("a declared chargePool joins two rows to one estimate", function()
      local IA, CFIRE = 258920, 452487
      local CID_CFIRE = 911

      local function havocConsumingFireRow()
        realGetSpellCharges = _G.C_Spell.GetSpellCharges
        H.setSpecIndex(5); ns.ResolveActiveSpec()        -- Havoc 577
        _G.Enum.CooldownViewerCategory = { Essential = 0 }
        _G.C_CooldownViewer = {
          GetCooldownViewerCategorySet = function(v) return v == 0 and { CID_CFIRE } or {} end,
          GetCooldownViewerCooldownInfo = function() return { spellID = CFIRE,
                                                              isKnown = true, charges = true } end,
        }
        _G.C_Spell.GetSpellCharges = function()
          return { currentCharges = 2, maxCharges = 2 }
        end
        ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
        ns.GetViewer     = function() return { n = 1 } end
        ns.GetItemFrames = function() return { { cooldownID = CID_CFIRE } } end
        ns.OnLogin()
      end

      it("the override's row files its charges under the BASE's pool", function()
        havocConsumingFireRow()
        St.Build(false)
        assert.equals(IA, St.Charges.PoolOfCid(CID_CFIRE))
        assert.equals(2, (St.Charges.Read(IA)))
      end)

      -- The defect verbatim: press it in demon form, and the count the base form reads
      -- must have moved.  Keyed by cooldownID this left IA's estimate untouched.
      it("a press on the override debits the count the base form reads", function()
        havocConsumingFireRow()
        St.Build(false)
        St.Charges.Spend(CFIRE)
        assert.equals(1, (St.Charges.Read(IA)))
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- The point of the whole phase: the ROTATION falls through instead of vanishing.
  --
  -- ⚠ THE MECHANISM MOVED IN PHASE 5, THE OUTCOME DID NOT.  It used to be State's filter
  -- that stopped an untalented Soul Fire winning; now State MARKS the row and
  -- `Coach.Classify` refuses it.  These run the real pipeline end to end — the real
  -- `St.RosterView`, then the real Coach — so the seam between the two is under test rather
  -- than either half in isolation.
  ------------------------------------------------------------------------------
  describe("the Coach falls through to the next line", function()
    local Coach
    local NOW = 1000
    local function cdReady() return { state = "ready", readable = true, source = "live",
                                      changedAt = NOW - 2 } end

    before_each(function()
      H.load("Coach.lua")
      Coach = ns.Coach.New()
    end)

    local function pulseFrom(cooldowns, known)
      local abilities, _, _, _, knownReadable =
        St.RosterView(cooldowns, nil, ns.Spec, nil, true, function(id) return known[id] end)
      return {
        at = NOW, combat = true, combatStartedAt = NOW - 60, mode = "st",
        power = { SoulShards = { value = 3, max = 5, readable = true } },
        buffs = {}, history = {}, abilities = abilities, knownReadable = knownReadable,
      }
    end

    local function press(g)
      for spellID, cue in pairs(g.cues) do
        if cue.emphasis == "ROTATION" or cue.emphasis == "LATE" then return spellID end
      end
    end

    local function rows()
      return {
        [901] = row(901, SOUL_FIRE, { cd = cdReady() }),
        [902] = row(902, CONFLAGRATE, { cd = cdReady() }),
        [903] = row(903, CHAOS_BOLT),
      }
    end

    it("an UNLEARNED Soul Fire does not win — Conflagrate does", function()
      -- The live bug in miniature: untalented Soul Fire reads `ready` forever, so before any
      -- of this it took L2 every single GCD and the cue was then dropped by the Binder.
      local g = Coach:Compute(pulseFrom(rows(),
        { [SOUL_FIRE] = false, [CONFLAGRATE] = true, [CHAOS_BOLT] = true }))
      assert.equals(CONFLAGRATE, press(g))
    end)

    it("a TALENTED Soul Fire still wins L2 — the cap removes phantoms, not presses", function()
      local g = Coach:Compute(pulseFrom(rows(),
        { [SOUL_FIRE] = true, [CONFLAGRATE] = true, [CHAOS_BOLT] = true }))
      assert.equals(SOUL_FIRE, press(g))
    end)

    it("an UNREADABLE Soul Fire does not win either — it caps at available", function()
      -- §6.1's third value.  The row is present and in `ctx.facts`; it simply may not be the
      -- call.  AVAILABLE renders as nothing (guidance-contract.json), so "cap at available"
      -- and "never cue" are the same pixels.
      local g = Coach:Compute(pulseFrom(rows(),
        { [CONFLAGRATE] = true, [CHAOS_BOLT] = true }))     -- Soul Fire: no answer at all
      assert.equals(CONFLAGRATE, press(g))
    end)

    it("...but the WHOLESALE guard overrides that — a refused channel bars nobody", function()
      -- Nothing answered, so `knownReadable` is false and knownness is ignored entirely.
      -- Without this a single load-order slip empties the rotation instead of one ability.
      local g = Coach:Compute(pulseFrom(rows(), {}))
      assert.equals(SOUL_FIRE, press(g))
    end)
  end)
end)

--------------------------------------------------------------------------------
-- VIRTUAL ROWS — the other direction: putting back a row State cannot observe.
--
-- ⚠ THIS IS THE RISKIEST TEST FILE IN THE ADDON, because this feature and the knownness cap
-- pull in OPPOSITE directions over the same table.  The cap is "refuse a row we cannot
-- trust"; this is "add a row we never saw".  So EVERY fence below is mutation-checked: drop
-- it in State.lua and one of these must go red.  A fence that passes both ways is exactly
-- the failure mode that shipped the phantom-ability bug in the first place.
--
-- ⚠ PHASE 5 RETIRED THREE OF THE SEVEN FENCES (§C7) — the zero-base-cooldown one, the
-- dropped-as-unlearned one and the knownness one — because the ROSTER already answers "is
-- this a press this spec cares about".  What survives is `kind == "button"`, `cadence ~=
-- "utility"`, `expect ~= false` and "Blizzard is not already drawing it".  Knownness did not
-- vanish: it moved to the DRAW LIST (`pulse.virtual`), because a row buys visibility for
-- free while an icon on screen does not.
--
-- The walk is DETECTION, not declaration: `ns.Spec` already IS the spec's ability library,
-- so there is no per-ability flag to forget.  That makes the "exactly one" tests at the
-- bottom load-bearing — they are what stops a future spec-table edit from quietly growing a
-- second icon.
--------------------------------------------------------------------------------
describe("State virtual rows (the untracked floor press)", function()
  local ns, St, fx, realSpellBook

  before_each(function()
    ns, fx = H.fresh()
    H.setSpecIndex(3)            -- Destruction: Incinerate is its untracked floor press
    ns.ResolveActiveSpec()
    H.load("State.lua")
    St = ns.State
    realSpellBook = _G.C_SpellBook
  end)
  -- The refused-read tests below REPLACE the spellbook API; restore it, or every later test
  -- silently sees no candidates at all and passes for the wrong reason.
  after_each(function() _G.C_SpellBook = realSpellBook end)

  local function known(...)
    for _, id in ipairs({ ... }) do fx.known[id] = true end
  end
  local function zeroCD(...)
    for _, id in ipairs({ ... }) do fx.baseCD[id] = 0 end
  end
  local function candidates(abilities)
    return St.VirtualCandidates(ns.Spec, abilities or {}, true)
  end

  -- ⚠ THE REALISTIC WORLD, and it is what makes the "exactly one" claim mean anything now.
  -- The fence list asks "which declared buttons is Blizzard NOT drawing", so asking it
  -- against an EMPTY board answers "all of them" — true, and useless as a guard.  This
  -- builds the board the live CDM actually presents: every declared entry on screen except
  -- the ones named.  It reads the roster rather than listing ids, so a spec-table edit
  -- cannot silently fall out of the fixture.
  local function onScreenExcept(...)
    local except = {}
    for _, id in ipairs({ ... }) do except[id] = true end
    local abilities = {}
    for _, e in ipairs(St.RosterEntries(ns.Spec)) do
      if not except[e.spellID] then
        abilities[e.spellID] = { spellID = e.spellID, displayable = true }
      end
    end
    return abilities
  end

  ------------------------------------------------------------------------------
  describe("the positive case", function()
    before_each(function() known(INCINERATE); zeroCD(INCINERATE) end)

    it("nominates the spec's untracked floor press", function()
      assert.are.same({ INCINERATE }, candidates(onScreenExcept(INCINERATE)))
    end)

    it("the synthesised row is keyed by base spellID and marked virtual", function()
      local r = St.VirtualRow(INCINERATE, true)
      assert.is_true(r.virtual)
      assert.are.equal(INCINERATE, r.spellID)
      assert.are.equal(INCINERATE, r.identity)
    end)

    it("carries the NEGATIVE display handle — no collision with a real cooldownID", function()
      assert.are.equal(-INCINERATE, St.VirtualRow(INCINERATE, true).display.cooldownID)
      assert.is_true(St.VirtualRow(INCINERATE, true).display.cooldownID < 0)
    end)

    it("says READY, and says WHY — `source = static`, never laundered as a read", function()
      -- A 0-cooldown spell has no cooldown to be unsure about, so `ready` is a statement
      -- about the spell's NATURE.  Calling it "live" would claim an observation we never
      -- made, which is the one thing this project refuses to do.
      local cd = St.VirtualRow(INCINERATE, true).cd
      assert.are.equal("ready", cd.state)
      assert.are.equal("static", cd.source)
      assert.are.equal(0, cd.remaining)
    end)

    it("carries the three-valued `known` it was handed, not an assumed `true`", function()
      assert.are.equal("unknown", St.VirtualRow(INCINERATE, "unknown").known)
      assert.is_false(St.VirtualRow(INCINERATE, false).known)
    end)
  end)

  ----------------------------------------------------------------------------
  -- THE COOLDOWN OF A ROW WITH NO CDM ENTRY — Phase 5's replacement for the retired
  -- zero-base-cooldown FENCE.  The fence was the honesty guard: a synthesised `ready` on
  -- an ability with a real cooldown is an invention, and inventions win priority lists.
  -- Dropping the fence without replacing the guard would have re-shipped that; instead the
  -- static `ready` narrowed to the case it was ever true for, and everything else takes
  -- the ordinary read ladder.
  ----------------------------------------------------------------------------
  describe("the virtual row's cd", function()
    it("a REAL base cooldown ⇒ the honest read, never a static `ready`", function()
      known(SOUL_FIRE); fx.baseCD[SOUL_FIRE] = 45
      fx.cd[SOUL_FIRE] = { duration = 45, startTime = H.clock - 10 }
      fx.cd[61304] = { duration = 0, startTime = 0 }
      local cd = St.VirtualRow(SOUL_FIRE, true).cd
      assert.are.equal("on-cooldown", cd.state)
      assert.are.equal("live", cd.source)
    end)

    it("an UNREADABLE base cooldown is NOT treated as zero", function()
      -- `ns.BaseCooldown` returns nil when the read refuses, and nil ~= 0.  Under the old
      -- fence that meant NO ROW; now it means no STATIC claim — the read ladder answers, and
      -- with nothing to read the answer is `unknown`, which can never win a line.
      known(SOUL_FIRE)                                   -- baseCD left nil
      local cd = St.VirtualRow(SOUL_FIRE, true).cd
      assert.are.equal("unknown", cd.state)
      assert.are.equal("none", cd.source)
    end)

    it("HAMMER OF WRATH: a row exists whatever its base cooldown turns out to be", function()
      -- `specs/retribution/observability-map.md` open question 1 is whether
      -- `ns.BaseCooldown(24275)` reads 0 for a charge-category spell.  Under the old fences
      -- the answer decided whether the ability existed at all, so `CoachRetribution`'s L9 was
      -- dead code pending a live pass.  It is now live by construction.
      local HAMMER_OF_WRATH = 24275
      H.setSpecIndex(4)                                  -- Retribution
      ns.ResolveActiveSpec()
      known(HAMMER_OF_WRATH)                             -- baseCD deliberately unreadable
      local nominated = candidates(onScreenExcept(HAMMER_OF_WRATH))
      local found = false
      for _, id in ipairs(nominated) do if id == HAMMER_OF_WRATH then found = true end end
      assert.is_true(found, "Hammer of Wrath must be nominated with no base-cooldown read")
    end)
  end)

  ------------------------------------------------------------------------------
  -- One test per fence.  Each names the mutation it guards.
  ------------------------------------------------------------------------------
  describe("the fences", function()
    it("NOT KNOWN ⇒ a row, but NOT an icon (knownness moved to the draw list)", function()
      -- ⚠ THE PHASE-5 SPLIT.  Candidacy no longer consults knownness — the row exists so it
      -- is visible in the pulse, the decision log and Coverage — but `pulse.virtual`, which
      -- is what pools a frame and lights an icon, still requires an affirmative `true`.
      zeroCD(INCINERATE)                       -- known deliberately not set
      assert.are.same({ INCINERATE }, candidates(onScreenExcept(INCINERATE)))
      assert.is_false(St.SpellKnown(INCINERATE))
    end)

    it("ALREADY PRESENT in abilities ⇒ no row (additive only, never a duplicate)", function()
      known(INCINERATE); zeroCD(INCINERATE)
      assert.are.same({}, candidates(onScreenExcept()))
    end)

    ----------------------------------------------------------------------------
    -- THE DISPLAY-IDENTITY FENCE (the v0.32.32 Diabolist duplicate).
    --
    -- Blizzard's cid 66181 is SHADOW BOLT 686 with its DISPLAY overridden to Incinerate
    -- 29722, and its `isKnown` is hero-tree dependent (false on Hellcaller, true on
    -- Diabolist).  The old fence asked `abilities[29722] == nil` — which stays true while
    -- Blizzard is visibly drawing the ability — so we synthesised a SECOND Incinerate icon.
    -- The fence therefore has to be asked of the DISPLAYED identities, not the base keys.
    ----------------------------------------------------------------------------
    describe("already DISPLAYED by Blizzard (under another base) ⇒ no row", function()
      local SHADOW_BOLT = 686

      -- The board with Incinerate's own key absent but SOME row displaying it.
      local function boardShowing(shadowBoltRow)
        local ab = onScreenExcept(INCINERATE)
        ab[SHADOW_BOLT] = shadowBoltRow
        return ab
      end

      before_each(function() known(INCINERATE); zeroCD(INCINERATE) end)

      it("a row keyed 686 whose overrideTooltipSpellID is 29722 suppresses ours", function()
        assert.are.same({}, candidates(boardShowing(
          { spellID = SHADOW_BOLT, liveSpellID = SHADOW_BOLT,
            overrideTooltipSpellID = INCINERATE })))
      end)

      it("...and via overrideSpellID alone (the other static field)", function()
        assert.are.same({}, candidates(boardShowing(
          { spellID = SHADOW_BOLT, overrideSpellID = INCINERATE })))
      end)

      it("THE FLICKER REGRESSION: still no row while the Demonic Art is ARMED", function()
        -- With the Art up, that row's `liveSpellID` becomes Infernal Bolt 433891 — so a
        -- liveSpellID-ONLY union would let our duplicate icon flicker back MID-COMBAT,
        -- exactly when the ability is most active.  The STATIC override fields carry 29722
        -- throughout, which is why unioning all three is load-bearing rather than tidy.
        local INFERNAL_BOLT = 433891
        assert.are.same({}, candidates(boardShowing(
          { spellID = SHADOW_BOLT, liveSpellID = INFERNAL_BOLT,
            overrideSpellID = INCINERATE, overrideTooltipSpellID = INCINERATE })))
      end)

      it("...and a row displaying it under its OWN base (liveSpellID) suppresses ours too", function()
        assert.are.same({}, candidates(boardShowing(
          { spellID = SHADOW_BOLT, liveSpellID = INCINERATE })))
      end)

      it("HELLCALLER: the same row UNDRAWABLE ⇒ we DO draw ours", function()
        -- 686 is unlearned on Hellcaller, so Blizzard hides the frame — nothing is on
        -- screen, and the 31 %→0 % win from Phase 1 has to survive intact.  ⚠ Phase 5 states
        -- this through DRAWABILITY rather than through a `dropped` reason: the row may still
        -- be in `abilities` (marked, not deleted), and what decides whether we draw is
        -- whether the CDM is drawing.
        local ab = onScreenExcept(INCINERATE)
        ab[SHADOW_BOLT] = { spellID = SHADOW_BOLT, overrideSpellID = INCINERATE,
                            overrideTooltipSpellID = INCINERATE, displayable = false }
        assert.are.same({ INCINERATE }, candidates(ab))
      end)

      it("a row displaying something ELSE does not suppress us", function()
        -- The fence must be a lookup, not a blanket "any override present" test.
        assert.are.same({ INCINERATE }, candidates(boardShowing(
          { spellID = SHADOW_BOLT, overrideTooltipSpellID = 433891 })))
      end)

      it("St.DisplayedIdentities unions base + live + BOTH static override fields", function()
        local on = St.DisplayedIdentities({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, liveSpellID = 433891,
                            overrideSpellID = 1, overrideTooltipSpellID = INCINERATE },
        }, true)
        assert.is_true(on[SHADOW_BOLT])
        assert.is_true(on[433891])
        assert.is_true(on[1])
        assert.is_true(on[INCINERATE])
      end)

      it("...and an UNDRAWABLE row contributes none of them", function()
        local on = St.DisplayedIdentities({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, overrideTooltipSpellID = INCINERATE,
                            displayable = false },
        }, true)
        assert.is_nil(on[SHADOW_BOLT])
        assert.is_nil(on[INCINERATE])
      end)

      it("...unless there is NO frame map, in which case drawability is not asked", function()
        -- The wholesale guard: with the viewers down, "undrawable" is a statement about the
        -- viewers, not about the row.
        local on = St.DisplayedIdentities({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, overrideTooltipSpellID = INCINERATE,
                            displayable = false },
        }, false)
        assert.is_true(on[INCINERATE])
      end)

      it("a SECRET display id is never keyed (the standing secret-value rule)", function()
        H.markSecret(INCINERATE)
        local on = St.DisplayedIdentities({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, overrideTooltipSpellID = INCINERATE },
        }, true)
        assert.is_nil(on[INCINERATE])
      end)
    end)

    it("NOT SPEC-DECLARED ⇒ no row, however known and cooldownless", function()
      local NOT_OURS = 999999
      known(NOT_OURS); zeroCD(NOT_OURS)
      assert.are.same({}, candidates(onScreenExcept()))
    end)

    it("a UTILITY ⇒ no row (defensives are never cued, and never ours to draw)", function()
      local UNENDING_RESOLVE = 104773
      known(UNENDING_RESOLVE); zeroCD(UNENDING_RESOLVE)
      assert.are.same({}, candidates(onScreenExcept(UNENDING_RESOLVE)))
    end)

    it("an AURA row ⇒ no row (an input to a decision, never a press)", function()
      local BACKDRAFT = 117828
      known(BACKDRAFT); zeroCD(BACKDRAFT)
      assert.are.same({}, candidates(onScreenExcept(BACKDRAFT)))
    end)

    it("EXPECT=FALSE ⇒ no row — a transform is not a second ability", function()
      local INFERNAL_BOLT = 433891   -- an override on the Incinerate frame, never its own icon
      known(INFERNAL_BOLT); zeroCD(INFERNAL_BOLT)
      assert.are.same({}, candidates(onScreenExcept(INFERNAL_BOLT)))
    end)

    it("EXPECT=FALSE ⇒ no row — nor is a cast-id ALIAS", function()
      -- 348 is Immolate's cast id; the CDM tracks the DoT aura 157736.  Immolate has no base
      -- cooldown, so without `expect = false` on the alias this would be drawn as a SECOND
      -- Immolate icon beside the real one.
      known(IMMOLATE_CAST); zeroCD(IMMOLATE_CAST)
      assert.are.same({}, candidates(onScreenExcept(IMMOLATE_CAST)))
    end)
  end)

  ------------------------------------------------------------------------------
  -- THE GUARD.  Detection means no per-ability flag to forget — and no per-ability flag
  -- stopping a spec-table edit from admitting something new.  These pin the whole result.
  --
  -- ⚠ THEY READ THE ROSTER RATHER THAN LISTING IDS (Phase 5).  The fence list asks "which
  -- declared buttons is Blizzard NOT drawing", so the board it is asked against IS the
  -- assertion: `onScreenExcept(X)` says "everything the spec declares is on screen except
  -- X", and the answer must be exactly X.  Listing the board by hand — which is what these
  -- used to do — quietly stopped covering any entry added to the spec table afterwards.
  ------------------------------------------------------------------------------
  describe("exactly one virtual row per spec", function()
    it("Destruction yields EXACTLY Incinerate", function()
      known(INCINERATE); zeroCD(INCINERATE)
      assert.are.same({ INCINERATE }, candidates(onScreenExcept(INCINERATE)))
    end)

    it("...and the cast-id ALIAS beside it changes nothing", function()
      -- 348 is Immolate's cast id; the CDM tracks the DoT aura 157736.  Both absent from the
      -- board, and only `expect = false` keeps the alias out — remove that fence and this
      -- goes red rather than being silently protected by the alias's own cooldown.
      known(INCINERATE, IMMOLATE_CAST); zeroCD(INCINERATE, IMMOLATE_CAST)
      assert.are.same({ INCINERATE }, candidates(onScreenExcept(INCINERATE, IMMOLATE_CAST)))
    end)

    it("Demonology yields EXACTLY Shadow Bolt (the seam is per-spec DATA, not code)", function()
      H.setSpecIndex(1)
      ns.ResolveActiveSpec()
      local SHADOW_BOLT, IMP_LORD_ALIAS = 686, 136726
      known(SHADOW_BOLT, IMP_LORD_ALIAS)
      -- ⚠ The Imp Lord ALIAS is absent from the board DELIBERATELY, alongside Shadow Bolt.
      -- Only `expect = false` can keep it out, so removing that fence turns this test red
      -- instead of leaving it silently protected by its own 120 s cooldown.
      assert.are.same({ SHADOW_BOLT },
                      candidates(onScreenExcept(SHADOW_BOLT, IMP_LORD_ALIAS)))
    end)

    it("no active spec ⇒ nothing at all (the passive path stays silent)", function()
      known(INCINERATE); zeroCD(INCINERATE)
      H.setSpecIndex(2)          -- Affliction: registered nowhere, HUD goes passive
      ns.ResolveActiveSpec()
      assert.are.same({}, St.VirtualCandidates(ns.Spec, {}, true))
    end)
  end)

  ------------------------------------------------------------------------------
  -- The live path: a REAL St.Build, so the wiring is under test and not just the walk.
  ------------------------------------------------------------------------------
  describe("St.Build end to end", function()
    before_each(function()
      known(INCINERATE); zeroCD(INCINERATE)
      _G.Enum.CooldownViewerCategory = { Essential = 0 }
      _G.C_CooldownViewer = {
        GetCooldownViewerCategorySet = function(v) return v == 0 and { 903 } or {} end,
        GetCooldownViewerCooldownInfo = function() return { spellID = CHAOS_BOLT, isKnown = true } end,
      }
      ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
      ns.GetViewer     = function() return { n = 1 } end
      ns.GetItemFrames = function() return { { cooldownID = 903 } } end
      ns.OnLogin()
    end)
    after_each(function()
      _G.C_CooldownViewer = nil
      _G.Enum.CooldownViewerCategory = nil
    end)

    it("the virtual row lands in abilities beside the real ones", function()
      local pulse = St.Build(false)
      assert.is_not_nil(pulse.abilities[CHAOS_BOLT])     -- Blizzard's row, untouched
      assert.is_true(pulse.abilities[INCINERATE].virtual)
      assert.are.equal(-INCINERATE, pulse.abilities[INCINERATE].display.cooldownID)
    end)

    it("pulse.virtual lists it, sorted, for HudVirtual to pool frames from", function()
      assert.are.same({ INCINERATE }, St.Build(false).virtual)
    end)

    it("the RAW cooldowns view is NOT polluted — it stays the CDM diagnostic view", function()
      local pulse = St.Build(false)
      assert.is_nil(pulse.cooldowns[-INCINERATE])
      assert.is_nil(pulse.cooldowns[INCINERATE])
    end)

    it("DIABOLIST: a row based on 686 but DISPLAYING 29722 stops us drawing ours", function()
      -- The end-to-end proof that the three display fields actually reach the fence: Build
      -- fills them from the info struct, domainView promotes the same table into `abilities`,
      -- and the walk reads them there.  This is the v0.32.32 duplicate icon, in full.
      local SHADOW_BOLT = 686
      _G.C_CooldownViewer.GetCooldownViewerCooldownInfo = function()
        return { spellID = SHADOW_BOLT, isKnown = true, overrideSpellID = INCINERATE,
                 overrideTooltipSpellID = INCINERATE }
      end
      local pulse = St.Build(false)
      assert.are.same({}, pulse.virtual)                  -- ours was never synthesised
      -- ...and the row is keyed by what it DISPLAYS, not by its own spellID.  Keying it at
      -- 686 is what made the Coach blind on Diabolist: `facts[29722]` was nil, so the
      -- Incinerate line could never win (0 wins in 225 live decisions, 2026-07-30) and the
      -- Binder's `cues[entry.spellID]` join missed, costing the icon its keybind too.
      assert.is_nil(pulse.abilities[SHADOW_BOLT])
      local shown = pulse.abilities[INCINERATE]
      assert.is_not_nil(shown, "the displayed row must be reachable at the id it displays")
      assert.equals(INCINERATE, shown.liveSpellID)          -- Blizzard draws it
      assert.equals(INCINERATE, shown.identity)
      assert.equals(686, shown.spellID)                     -- the raw base is still carried
    end)

    it("HELLCALLER: the same row UNDRAWN ⇒ ours is drawn instead, readings intact", function()
      -- 686 is unlearned on Hellcaller, so Blizzard hides the frame and the row draws
      -- nothing — and Incinerate is still pressed every GCD (0 % w:- , cued 10x and drawn
      -- 50x in the field, 2026-07-30).  ⚠ Phase 5 states this through DRAWABILITY rather
      -- than through a `dropped` reason, and the row is no longer replaced: it keeps its
      -- cooldownID and every reading, and merely takes our negative display handle.  The
      -- ROW's own `isKnown = false` describes Shadow Bolt, not the ability the row draws,
      -- which is exactly why the spellbook outranks it.
      local SHADOW_BOLT = 686
      _G.C_CooldownViewer.GetCooldownViewerCooldownInfo = function()
        return { spellID = SHADOW_BOLT, isKnown = false, overrideSpellID = INCINERATE,
                 overrideTooltipSpellID = INCINERATE }
      end
      ns.GetItemFrames = function() return {} end             -- …but SOMETHING is drawn:
      ns.VIEWERS = { { frame = "EssentialCooldownViewer" }, { frame = "UtilityCooldownViewer" } }
      local other = { { cooldownID = 999 } }
      ns.GetViewer = function(name)
        return name == "UtilityCooldownViewer" and { n = 2 } or { n = 1 }
      end
      ns.GetItemFrames = function(v) return v.n == 2 and other or {} end
      local pulse = St.Build(false)
      local shown = pulse.abilities[INCINERATE]
      assert.is_not_nil(shown)
      assert.is_true(shown.known)                             -- the spellbook, not the row
      assert.is_false(shown.displayable)
      assert.is_true(shown.virtual)                           -- …so ours is the icon
      assert.equals(-INCINERATE, shown.display.cooldownID)
      assert.equals(903, shown.cooldownID)                    -- …over the REAL row
      assert.are.same({ INCINERATE }, pulse.virtual)
    end)

    it("stops synthesising the moment Blizzard starts tracking it", function()
      _G.C_CooldownViewer.GetCooldownViewerCategorySet = function(v) return v == 0 and { 903, 904 } or {} end
      _G.C_CooldownViewer.GetCooldownViewerCooldownInfo = function(cid)
        if cid == 903 then return { spellID = CHAOS_BOLT, isKnown = true } end
        return { spellID = INCINERATE, isKnown = true }
      end
      ns.GetItemFrames = function() return { { cooldownID = 903 }, { cooldownID = 904 } } end
      local pulse = St.Build(false)
      assert.are.same({}, pulse.virtual)
      assert.is_nil(pulse.abilities[INCINERATE].virtual)   -- Blizzard's row, not ours
      assert.are.equal(904, pulse.abilities[INCINERATE].display.cooldownID)
    end)
  end)
end)

--------------------------------------------------------------------------------
describe("State aura-lifecycle latch (field-fix C)", function()
  local ns, St, A
  local IMM_AURA_CID, IMM_CAST_CID = 133441, 164597

  before_each(function()
    ns = H.fresh()
    H.setSpecIndex(3)            -- Destruction: Immolate is one of its own
    ns.ResolveActiveSpec()
    H.load("State.lua")
    St = ns.State
    St.Acquire()                 -- the latch is gated on a live consumer, like readyEdge
    A = _G.Enum.CooldownViewerAlertEventType
  end)
  after_each(function() St.Release() end)

  local function alert(cid, event) St.OnAlert({ cooldownID = cid }, event) end

  it("PandemicTime latches the refresh window", function()
    alert(IMM_CAST_CID, A.PandemicTime)
    assert.equals("pandemic", St.dotEdge[IMM_CAST_CID].state)
  end)

  it("OnAuraRemoved clears it to absent", function()
    alert(IMM_CAST_CID, A.PandemicTime)
    alert(IMM_CAST_CID, A.OnAuraRemoved)
    assert.equals("absent", St.dotEdge[IMM_CAST_CID].state)
  end)

  it("OnAuraApplied clears it to fresh", function()
    alert(IMM_CAST_CID, A.PandemicTime)
    alert(IMM_CAST_CID, A.OnAuraApplied)
    assert.equals("fresh", St.dotEdge[IMM_CAST_CID].state)
  end)

  -- ⚠ FROM THE FIELD (2026-07-30).  A DoT REFRESH raises OnAuraRemoved AND OnAuraApplied
  -- with the IDENTICAL timestamp — the live capture has both on cid 133441 and 164597 at
  -- 131184.611.  Last-write-wins would let Blizzard's dispatch ORDER decide whether the HUD
  -- thinks the DoT is up or gone.  A re-application supersedes the removal it replaces.
  describe("a same-frame refresh (removed + applied at one timestamp)", function()
    it("resolves to fresh when applied arrives LAST", function()
      alert(IMM_CAST_CID, A.OnAuraRemoved)
      alert(IMM_CAST_CID, A.OnAuraApplied)
      assert.equals("fresh", St.dotEdge[IMM_CAST_CID].state)
    end)

    it("resolves to fresh when applied arrives FIRST, too", function()
      alert(IMM_CAST_CID, A.OnAuraApplied)
      alert(IMM_CAST_CID, A.OnAuraRemoved)   -- must NOT clobber the re-application
      assert.equals("fresh", St.dotEdge[IMM_CAST_CID].state)
    end)

    it("a removal in a LATER frame still clears it — the DoT really did fall off", function()
      alert(IMM_CAST_CID, A.OnAuraApplied)
      H.advance(0.1)
      alert(IMM_CAST_CID, A.OnAuraRemoved)
      assert.equals("absent", St.dotEdge[IMM_CAST_CID].state)
    end)
  end)

  it("ignores the alert while no consumer holds ingestion", function()
    St.Release()
    alert(IMM_CAST_CID, A.PandemicTime)
    assert.is_nil(St.dotEdge[IMM_CAST_CID])
    St.Acquire()
  end)

  -- ⚠ THE TWO-COOLDOWNID CASE.  Immolate occupies cid 133441 (spellID 157736, the DoT aura,
  -- on the Buff-bar viewer) AND cid 164597 (spellID 348, the cast, on Essential), and BOTH
  -- raised PandemicTime in the live capture.  Either must resolve to ONE answer per base.
  describe("resolved to base spellIDs by the fold", function()
    local function rows()
      return {
        [IMM_AURA_CID] = row(IMM_AURA_CID, IMMOLATE_AURA, { category = "TrackedBuff" }),
        [IMM_CAST_CID] = row(IMM_CAST_CID, IMMOLATE_CAST, { category = "Essential" }),
      }
    end

    -- ⚠ `St.FoldSignals` is the fold, split out of the old `St.DomainView` in Phase 5.  It is
    -- a property of the ROWS, not of the roster — an ability's aura signal can live on a row
    -- no declared id claims — so it survived the inversion unchanged and keeps its own seam.
    it("either cooldownID's latch surfaces under its own base spellID", function()
      alert(IMM_AURA_CID, A.PandemicTime)
      local edges = St.FoldSignals(rows(), nil, St.dotEdge)
      assert.equals("pandemic", edges[IMMOLATE_AURA].state)

      H.advance(1)
      alert(IMM_CAST_CID, A.PandemicTime)
      local edges2 = St.FoldSignals(rows(), nil, St.dotEdge)
      assert.equals("pandemic", edges2[IMMOLATE_CAST].state)
    end)

    it("rides the declared ability's row so the brain never sees a cooldownID", function()
      alert(IMM_CAST_CID, A.PandemicTime)
      local abilities = St.RosterView(rows(), nil, ns.Spec, St.dotEdge, true,
                                      function() return true end)
      assert.equals("pandemic", abilities[IMMOLATE_CAST].dot.state)
    end)

    it("the NEWEST edge wins when both of an ability's rows have latched", function()
      -- Two rows of ONE base id: the fold must not let a stale latch beat a fresh one.
      local twoRows = {
        [770] = row(770, CONFLAGRATE, { category = "TrackedBuff" }),
        [771] = row(771, CONFLAGRATE, { category = "Essential" }),
      }
      alert(770, A.PandemicTime)
      H.advance(5)
      alert(771, A.OnAuraRemoved)
      local edges = St.FoldSignals(twoRows, nil, St.dotEdge)
      assert.equals("absent", edges[CONFLAGRATE].state)
    end)

    it("no alert seen ⇒ no latch, and the brain stays silent", function()
      local edges = St.FoldSignals(rows(), nil, St.dotEdge)
      local abilities = St.RosterView(rows(), nil, ns.Spec, St.dotEdge, true,
                                      function() return true end)
      assert.is_nil(edges[IMMOLATE_CAST])
      assert.is_nil(abilities[IMMOLATE_CAST].dot)
    end)
  end)
end)

--------------------------------------------------------------------------------
describe("State charge napkin (field-fix C2)", function()
  local ns, St, A
  local CONF_CID = 671

  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    St = ns.State
    St.Charges.Reset()
    St.Acquire()
    A = _G.Enum.CooldownViewerAlertEventType
  end)
  after_each(function() St.Release() end)

  it("reads nothing before it has been seeded", function()
    assert.is_nil(St.Charges.Read(CONF_CID))
  end)

  it("seeds exactly from an OOC read", function()
    St.Charges.Seed(CONF_CID, 2, 2)
    local cur, max = St.Charges.Read(CONF_CID)
    assert.equals(2, cur); assert.equals(2, max)
  end)

  it("decrements on a cast that landed", function()
    St.Charges.Seed(CONF_CID, 2, 2)
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Spend(17962)
    assert.equals(1, (St.Charges.Read(CONF_CID)))
  end)

  it("increments on the ChargeGained alert", function()
    St.Charges.Seed(CONF_CID, 0, 2)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(1, (St.Charges.Read(CONF_CID)))
  end)

  -- ── ONE POOL, TWO ROWS (2026-08-03) ────────────────────────────────────────────────────
  -- The Havoc AoE flight's defect, as a unit: Metamorphosis swaps Immolation Aura's CDM row
  -- for Consuming Fire, a SEPARATE cooldownID drawing on the SAME in-game charge pool.  The
  -- napkin used to key on the cooldownID, so each row kept its own count, neither saw the
  -- other's presses, and leaving demon form restored a stale 2/2 that the Coach then cued
  -- with nothing to press.  The pool key is what joins them.
  describe("a base and its display override share ONE pool", function()
    local IA, CFIRE = 258920, 452487        -- the roster ids
    local IA_CID, CFIRE_CID = 40653, 40999  -- two rows, two cooldownIDs

    before_each(function()
      -- Both rows bound to Immolation Aura's pool, which is what the spec's `chargePool`
      -- declaration makes Build do.
      St.Charges.Seed(IA, 2, 2)
      St.Charges.Bind(IA, IA); St.Charges.BindCid(IA_CID, IA)
      St.Charges.Bind(CFIRE, IA); St.Charges.BindCid(CFIRE_CID, IA)
    end)

    it("a press in demon form debits the count the BASE form reads", function()
      St.Charges.Spend(CFIRE)
      assert.equals(1, (St.Charges.Read(IA)))
    end)

    it("a recharge alert on the OVERRIDE's row credits the shared pool", function()
      St.Charges.Spend(CFIRE); St.Charges.Spend(CFIRE)
      assert.equals(0, (St.Charges.Read(IA)))
      St.OnAlert({ cooldownID = CFIRE_CID }, A.ChargeGained)
      assert.equals(1, (St.Charges.Read(IA)))
    end)

    -- THE REGRESSION ITSELF.  Spend both charges in demon form, drop out, and the base must
    -- report zero.  Keyed by cooldownID this read 2 — the exact line that cued Immolation
    -- Aura at no charges for 118 of L12's 452 `charge_cap` cues.
    it("leaving demon form does NOT restore a stale count", function()
      St.Charges.Spend(CFIRE); St.Charges.Spend(CFIRE)
      assert.equals(0, (St.Charges.Read(IA)))
    end)

    -- The other direction, so the join cannot be one-way: an ability that declares no pool
    -- keys on itself and stays completely independent.
    it("an unrelated charged ability is untouched by either", function()
      St.Charges.Seed(CONF_CID, 2, 2)
      St.Charges.Bind(17962, CONF_CID)
      St.Charges.Spend(CFIRE)
      assert.equals(2, (St.Charges.Read(CONF_CID)))
    end)
  end)

  it("clamps at max — a gain past the cap cannot invent a charge", function()
    St.Charges.Seed(CONF_CID, 2, 2)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(2, (St.Charges.Read(CONF_CID)))
  end)

  it("clamps at zero — the undercount direction, never a negative", function()
    St.Charges.Seed(CONF_CID, 0, 2)
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Spend(17962)
    St.Charges.Spend(17962)
    assert.equals(0, (St.Charges.Read(CONF_CID)))
  end)

  it("ignores a spend for an ability it has no seed for", function()
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Spend(17962)
    assert.is_nil(St.Charges.Read(CONF_CID))
  end)

  it("an exact OOC re-read overrides a drifted estimate", function()
    St.Charges.Seed(CONF_CID, 2, 2)
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Spend(17962); St.Charges.Spend(17962)
    assert.equals(0, (St.Charges.Read(CONF_CID)))
    St.Charges.Seed(CONF_CID, 2, 2)          -- combat ended, the client answers again
    assert.equals(2, (St.Charges.Read(CONF_CID)))
  end)

  it("the full loop: seed, press, press, recharge, recharge", function()
    -- ⚠ CONTRACT CHANGE 2026-07-31: the two gains are now separated by a real recharge
    -- interval.  They used to be back-to-back with no clock advance, which is precisely
    -- the DUPLICATE-DRAIN shape the gain floor refuses — `ChargeGained` is an edge on
    -- Blizzard's prediction queue, not on a charge (see State.lua's chargeGain).  A test
    -- that credits two charges in zero elapsed time was asserting the bug.
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2, 12)
    St.Charges.Spend(17962);                                   assert.equals(1, (St.Charges.Read(CONF_CID)))
    St.Charges.Spend(17962);                                   assert.equals(0, (St.Charges.Read(CONF_CID)))
    H.advance(12)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(1, (St.Charges.Read(CONF_CID)))
    H.advance(12)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(2, (St.Charges.Read(CONF_CID)))
  end)

  it("a DUPLICATE queue drain does not credit a charge it did not gain", function()
    -- The live defect, reduced: Blizzard drains at most one due entry per frame from a
    -- table two producers write, so one real restore can raise ChargeGained twice on
    -- consecutive frames.  Measured 2026-07-31: a 0 -> 1 -> 2 climb in 200 ms.
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2, 12)      -- 12 s recharge -> a 6 s floor
    St.Charges.Spend(17962); St.Charges.Spend(17962)
    assert.equals(0, (St.Charges.Read(CONF_CID)))

    H.advance(12)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(1, (St.Charges.Read(CONF_CID)))   -- the real restore lands

    H.advance(0.2)                                  -- the consecutive-frame duplicate
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(1, (St.Charges.Read(CONF_CID)))   -- REFUSED — this is the whole fix
  end)

  it("a burst of duplicates cannot ratchet the window past a real later gain", function()
    -- `lastGain` deliberately does not advance on a refusal.  If it did, a stream of
    -- drains would keep pushing the window forward and starve the next genuine restore —
    -- trading an overcount for an unbounded undercount.
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2, 12)
    St.Charges.Spend(17962); St.Charges.Spend(17962)
    H.advance(12)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(1, (St.Charges.Read(CONF_CID)))
    for _ = 1, 5 do
      H.advance(0.5)
      St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    end
    assert.equals(1, (St.Charges.Read(CONF_CID)))   -- all five refused (2.5 s < 6 s floor)
    H.advance(4)                                    -- now 6.5 s past the REAL gain
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(2, (St.Charges.Read(CONF_CID)))   -- and the genuine one still lands
  end)

  it("an exact OOC re-read clears the debounce as well as the count", function()
    -- Ground truth outranks the estimate in both fields: after a measurement there is
    -- nothing left to guard against, so the next edge must not be refused as a duplicate.
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2, 12)
    St.Charges.Spend(17962); St.Charges.Spend(17962)
    H.advance(12)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(1, (St.Charges.Read(CONF_CID)))
    St.Charges.Seed(CONF_CID, 0, 2)                            -- combat exit, exact read
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(1, (St.Charges.Read(CONF_CID)))              -- credited, not debounced
  end)

  it("a seed with no duration KEEPS the last measured recharge", function()
    -- `cooldownDuration` reads 0 at full charges, and the OOC re-seed most often happens
    -- exactly there.  Overwriting would erase the floor right before combat entry.
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2, 12)   -- floor measured at 6 s
    St.Charges.Seed(CONF_CID, 2, 2)       -- full charges: no duration this time
    St.Charges.Spend(17962); St.Charges.Spend(17962)
    H.advance(12)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(1, (St.Charges.Read(CONF_CID)))
    H.advance(2)                                               -- inside the RETAINED 6 s
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(1, (St.Charges.Read(CONF_CID)))
  end)

  it("with NO recharge ever measured, only the pathological drain is refused", function()
    -- The unseeded-floor case: 1 s, deliberately below any real charge recharge, so it
    -- catches the consecutive-frame duplicate without suppressing a legitimate gain.
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2)       -- no duration, ever
    St.Charges.Spend(17962); St.Charges.Spend(17962)
    H.advance(5)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(1, (St.Charges.Read(CONF_CID)))
    H.advance(0.2)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(1, (St.Charges.Read(CONF_CID)))
    H.advance(2)                                               -- clears the 1 s floor
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(2, (St.Charges.Read(CONF_CID)))
  end)

  it("a UNIT_SPELLCAST_SUCCEEDED event debits through the real handler", function()
    -- Not the seam: the shipped event handler, so the wiring itself is under test.
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2)
    local eframe = H.lastFrame()
    eframe:Fire("OnEvent", "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 17962)
    assert.equals(1, (St.Charges.Read(CONF_CID)))
  end)
end)

--------------------------------------------------------------------------------
-- THE HERO TALENT TREE — a client read, so it lives in Stage 1 and rides the pulse.
--
-- It used to be resolved inside the Destruction brain's Context, which meant the Coach
-- called a game API at 10 Hz AND that the hero tree — which gates real rotation lines —
-- never appeared on the pulse, so a captured pulse could not reproduce a Hellcaller
-- decision.  These pin the resolution path itself; the brain's INFERENCE fallback (for
-- when this returns nil) is pinned in coach_destruction_apl_spec.
--------------------------------------------------------------------------------
describe("State hero tree", function()
  local ns, St
  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    St = ns.State
  end)
  after_each(function() _G.C_ClassTalents = nil end)

  it("maps SubTreeID 58 to hellcaller, carrying the raw id too", function()
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return 58 end }
    local name, id = St.ReadHero()
    assert.equals("hellcaller", name)
    assert.equals(58, id)
  end)

  it("maps SubTreeID 59 to diabolist", function()
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return 59 end }
    assert.equals("diabolist", (St.ReadHero()))
  end)

  -- The Demon Hunter + Paladin vocabulary (2026-08-02).  Tier-1: wago `TraitSubTree` @
  -- 12.0.7.  Pinned per id rather than as a spot check because the numbers are NOT
  -- contiguous per class — the DH pair 34/35 predates 124/126 by two expansions — so a
  -- transposed digit would map a real tree to the wrong NAME, which is the silent version of
  -- the field-fix-B failure (a confidently wrong hero tree gating real rotation lines).
  for id, name in pairs({
    [34]  = "fel-scarred",       [35]  = "aldrachi-reaver",     -- Demon Hunter
    [124] = "annihilator",       [126] = "void-scarred",
    [48]  = "templar",           [49]  = "lightsmith",          -- Paladin
    [50]  = "herald-of-the-sun",
  }) do
    it("maps SubTreeID " .. id .. " to " .. name, function()
      _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return id end }
      local got, raw = St.ReadHero()
      assert.equals(name, got)
      assert.equals(id, raw)
    end)
  end

  it("an UNKNOWN SubTreeID yields no name but still reports the raw id", function()
    -- So a capture from a class we have not mapped is self-describing rather than blank.
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return 999 end }
    local name, id = St.ReadHero()
    assert.is_nil(name)
    assert.equals(999, id)
  end)

  it("an API that THROWS yields nil, not a crash — the brain's inference takes over", function()
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() error("restricted") end }
    assert.is_nil((St.ReadHero()))
  end)

  it("an ABSENT API yields nil", function()
    _G.C_ClassTalents = nil
    assert.is_nil((St.ReadHero()))
  end)

  it("a SECRET SubTreeID is refused — never a poisoned value on the pulse", function()
    local secret = {}
    H.secret[secret] = true
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return secret end }
    assert.is_nil((St.ReadHero()))
  end)

  it("caches the read — one API call, not one per pulse", function()
    local calls = 0
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() calls = calls + 1; return 58 end }
    St.ReadHero(); St.ReadHero(); St.ReadHero()
    assert.equals(1, calls)
  end)

  it("caches a REFUSED read too, so a broken API is not re-asked every tick", function()
    local calls = 0
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() calls = calls + 1; error("no") end }
    St.ReadHero(); St.ReadHero()
    assert.equals(1, calls)
  end)

  -- ⚠ THE HUD-OFF HOLE.  Both build caches used to be invalidated only from the
  -- Acquire-gated event frame, so with no consumer holding ingestion a respec left the hero
  -- tree holding the PREVIOUS answer — and Acquire could not fix it afterwards, because
  -- re-registering an event does not replay the one that was missed.  The Coach then gated
  -- Destruction's rotation on the wrong tree.  `cacheFrame` is always on; these pin that.
  it("TRAIT_CONFIG_UPDATED drops the cache with NO consumer — a hero swap fires only this", function()
    local sub = 58
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return sub end }
    assert.equals("hellcaller", (St.ReadHero()))
    sub = 59
    -- No St.Acquire() anywhere in this test: the HUD is off, exactly as it is when you
    -- respec at a trainer.  A hero-tree swap does NOT fire PLAYER_SPECIALIZATION_CHANGED.
    assert.equals(0, St.consumers)
    for _, f in ipairs(H.frames) do f:Fire("OnEvent", "TRAIT_CONFIG_UPDATED") end
    assert.equals("diabolist", (St.ReadHero()))
  end)

  it("PLAYER_SPECIALIZATION_CHANGED drops it too — a full spec swap moves it as well", function()
    local sub = 58
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return sub end }
    assert.equals("hellcaller", (St.ReadHero()))
    sub = 59
    for _, f in ipairs(H.frames) do f:Fire("OnEvent", "PLAYER_SPECIALIZATION_CHANGED") end
    assert.equals("diabolist", (St.ReadHero()))
  end)

  it("SPELLS_CHANGED drops the cache — a hero swap moves the answer", function()
    local sub = 58
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return sub end }
    assert.equals("hellcaller", (St.ReadHero()))
    sub = 59
    assert.equals("hellcaller", (St.ReadHero()))   -- still cached
    for _, f in ipairs(H.frames) do f:Fire("OnEvent", "SPELLS_CHANGED") end
    assert.equals("diabolist", (St.ReadHero()))
  end)

  it("rides the PULSE, as name + raw id", function()
    _G.C_ClassTalents = { GetActiveHeroTalentSpec = function() return 58 end }
    _G.Enum.CooldownViewerCategory = { Essential = 0 }
    _G.C_CooldownViewer = {
      GetCooldownViewerCategorySet = function() return {} end,
      GetCooldownViewerCooldownInfo = function() return nil end,
    }
    ns.OnLogin()
    local pulse = St.Build(false)
    assert.equals("hellcaller", pulse.hero)
    assert.equals(58, pulse.heroSubTreeID)
    _G.C_CooldownViewer = nil
    _G.Enum.CooldownViewerCategory = nil
  end)

  it("carries nil hero when the read refuses — never a fabricated tree", function()
    _G.C_ClassTalents = nil
    _G.Enum.CooldownViewerCategory = { Essential = 0 }
    _G.C_CooldownViewer = {
      GetCooldownViewerCategorySet = function() return {} end,
      GetCooldownViewerCooldownInfo = function() return nil end,
    }
    ns.OnLogin()
    local pulse = St.Build(false)
    assert.is_nil(pulse.hero)
    assert.is_nil(pulse.heroSubTreeID)
    _G.C_CooldownViewer = nil
    _G.Enum.CooldownViewerCategory = nil
  end)
end)

--------------------------------------------------------------------------------
-- READINESS KEYS ON THE DISPLAY IDENTITY, NOT ON A FOREIGN LIVE OVERRIDE.
--
-- The field failure (Demonology, 2026-07-30): Grimoire: Imp Lord was ranked as a top
-- press while sitting on its 2-minute cooldown.  While the summoned imp is out, ITS
-- dispel takes over the Grimoire button — the client fires
-- COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED with `base=1276452 -> over=132411` — so
-- `liveSpellID` became Singe Magic.  State then read SINGE MAGIC's cooldown (ready) and
-- filed it under Imp Lord's key.  The Felhunter's Devour Magic does the same thing to the
-- Fel Ravager button.  Both are declared `expect = false` in the spec table precisely
-- because they only ever appear as an override, and ns.DisplayIdentity already refuses
-- them — the live reads just weren't using it.
--------------------------------------------------------------------------------
describe("State readiness vs a foreign live override", function()
  local ns, St
  local IMP_LORD, SINGE_MAGIC, TYRANT = 1276452, 132411, 265187
  local CID = { imp = 801, tyrant = 802 }

  before_each(function()
    ns = H.fresh()                 -- Demonology (266) is the active spec here
    H.load("State.lua")
    St = ns.State
    _G.Enum.CooldownViewerCategory = { Essential = 0 }
    _G.C_CooldownViewer = {
      GetCooldownViewerCategorySet = function(v)
        if v == 0 then return { CID.imp, CID.tyrant } end
        return {}
      end,
      GetCooldownViewerCooldownInfo = function(cid)
        if cid == CID.imp    then return { spellID = IMP_LORD, isKnown = true } end
        if cid == CID.tyrant then return { spellID = TYRANT,   isKnown = true } end
      end,
    }
    ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
    ns.GetViewer     = function(name) return name == "EssentialCooldownViewer" and { n = 1 } or nil end
    ns.GetItemFrames = function() return { { cooldownID = CID.imp }, { cooldownID = CID.tyrant } } end
    ns.OnLogin()
  end)

  after_each(function()
    _G.C_CooldownViewer = nil
    _G.Enum.CooldownViewerCategory = nil
  end)

  -- The whole ability set reads READY except Imp Lord, which is genuinely on cooldown.
  -- Recording which id each read was asked about is the direct assertion.
  local function stubReads()
    local asked = {}
    ns.ReadCooldown = function(id)
      asked[#asked + 1] = id
      if id == IMP_LORD then return false, 90, 120, 0 end   -- 90s left on the real ability
      return true, 0, 0, 0                                  -- everything else: ready
    end
    return asked
  end

  it("reads the BASE's cooldown when a pet spell has taken over the button", function()
    local asked = stubReads()
    St.override[IMP_LORD] = SINGE_MAGIC          -- the imp's dispel owns the frame now
    local pulse = St.Build(false)

    -- The row still SHOWS Singe Magic...
    assert.equals(SINGE_MAGIC, pulse.cooldowns[CID.imp].liveSpellID)
    -- ...but readiness is Imp Lord's, because that is what the row IS.
    assert.equals("on-cooldown", pulse.abilities[IMP_LORD].cd.state)
    assert.equals(90, pulse.abilities[IMP_LORD].cd.remaining)

    -- And the read was never even asked about the foreign spell.
    local sawImp, sawSinge = false, false
    for _, id in ipairs(asked) do
      if id == IMP_LORD then sawImp = true end
      if id == SINGE_MAGIC then sawSinge = true end
    end
    assert.is_true(sawImp)
    assert.is_false(sawSinge)
  end)

  it("does not stash the foreign spell's readiness as the OOC baseline either", function()
    -- The baseline is what gets projected forward across combat entry, so a wrong OOC
    -- answer here outlives the override that caused it.
    stubReads()
    St.override[IMP_LORD] = SINGE_MAGIC
    St.Build(false)
    H.combat = true                              -- the live read now refuses
    local pulse = St.Build(false)
    assert.are_not.equal("ready", pulse.abilities[IMP_LORD].cd.state)
  end)

  it("a row with no override is unaffected — it reads its own id", function()
    local asked = stubReads()
    local pulse = St.Build(false)
    assert.equals("ready", pulse.abilities[TYRANT].cd.state)
    local sawTyrant = false
    for _, id in ipairs(asked) do if id == TYRANT then sawTyrant = true end end
    assert.is_true(sawTyrant)
  end)
end)

--------------------------------------------------------------------------------
-- St.CoverageRows — the SHIPPED-SYMBOL gate for the Phase-4 coverage probe.
--
-- `coverage_spec` drives `ns.Coverage.Build` as a pure function over hand-built row
-- arrays, which proves the JOIN and proves nothing at all about where the rows come
-- from.  That is the v0.32.25 outage shape exactly (`viewers_spec`'s doctrine: a stub
-- proves the caller works GIVEN the collaborator, never that the collaborator exists),
-- so this asserts the real symbol off the real State.lua, against the real
-- C_CooldownViewer read path — the record SHAPE included, since Coverage joins on
-- fields a fold could quietly stop carrying.
--------------------------------------------------------------------------------
describe("St.CoverageRows (the coverage probe's row source)", function()
  local ns, St
  local CID = { cb = 701, ritual = 702, refused = 703 }

  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    St = ns.State
    _G.Enum.CooldownViewerCategory = { Essential = 0, TrackedBuff = 2 }
    _G.C_CooldownViewer = {
      GetCooldownViewerCategorySet = function(value)
        if value == 0 then return { CID.cb, CID.refused } end
        if value == 2 then return { CID.ritual } end
        return {}
      end,
      GetCooldownViewerCooldownInfo = function(cid)
        if cid == CID.cb then
          return { spellID = CHAOS_BOLT, isKnown = true,
                   overrideSpellID = 433885,          -- Ruination, the Art transform
                   linkedSpellIDs = { 434635, 434636 } }
        end
        if cid == CID.ritual then return { spellID = 428514, isKnown = true } end
        if cid == CID.refused then return H.poison({ spellID = SOUL_FIRE }, { "spellID" }) end
      end,
    }
    ns.OnLogin()   -- builds the category-name cache
  end)

  after_each(function()
    _G.C_CooldownViewer = nil
    _G.Enum.CooldownViewerCategory = nil
  end)

  it("ships, and returns one record per enumerated cooldownID, sorted", function()
    local rows = St.CoverageRows()
    assert.equals(3, #rows)
    assert.equals(CID.cb, rows[1].cooldownID)
    assert.equals(CID.ritual, rows[2].cooldownID)
    assert.equals(CID.refused, rows[3].cooldownID)
  end)

  it("carries every id field the coverage join needs, and the category", function()
    local rows = St.CoverageRows()
    assert.equals("Essential", rows[1].category)
    assert.equals(CHAOS_BOLT, rows[1].spellID)
    assert.equals(433885, rows[1].overrideSpellID)
    assert.same({ 434635, 434636 }, rows[1].linkedSpellIDs)
    assert.is_true(rows[1].isKnown)
    assert.is_true(rows[1].readable)
    assert.equals("TrackedBuff", rows[2].category)
  end)

  it("a row whose fields RAISE is present and marked unreadable, not dropped", function()
    -- Dropping it would turn "we could not read this row" into "this row does not exist",
    -- which is precisely the negative Coverage must never assert on.
    local rows = St.CoverageRows()
    assert.equals(CID.refused, rows[3].cooldownID)
    assert.is_false(rows[3].readable)
    assert.is_nil(rows[3].spellID)
  end)

  it("an empty CDM database yields NO rows — the wholesale guard's input", function()
    _G.C_CooldownViewer.GetCooldownViewerCategorySet = function() return {} end
    assert.equals(0, #St.CoverageRows())
  end)
end)

--------------------------------------------------------------------------------
-- THE EXACT POWER RAIL (Phase 6.2) — `UnitPower(unit, type, unmodified)`.
--------------------------------------------------------------------------------
-- The game stores Soul Shards as 0-50 FRAGMENTS and displays them as 0-5 whole shards;
-- the flagged read returns the internal units (measured in-game 2026-08-01: max 50 vs 5,
-- and it WORKS IN COMBAT, because `ShouldUnitPowerBeSecret` takes (unit, powerType) and the
-- flag is not a parameter of the verdict).  Until this landed, the whole pipeline saw whole
-- shards only, so a true 1.9 arrived as `1` and "you are one Incinerate from a Chaos Bolt"
-- was unsayable.
--
-- WHAT THESE PIN, in the order they can break:
--   * the read is PURELY ADDITIVE — `value`/`max`/`readable` are byte-identical to before;
--   * `modifier` is DERIVED from the two maxes, not assumed, so a power that gains or loses
--     a divisor needs no code edit;
--   * a refused exact read leaves the fields ABSENT, never zero — the project's standing
--     rule that absence of a read must never become a positive claim, applied here.  Zero
--     would read as "you have no shards", which is a different and actionable sentence.
--------------------------------------------------------------------------------
describe("State power — the exact (unmodified) rail", function()
  local ns, St, fx
  local SHARDS, MANA = 7, 0    -- Enum.PowerType members, per the harness

  before_each(function()
    ns, fx = H.fresh()
    H.load("State.lua")
    St = ns.State
    ns.OnLogin()          -- builds the Enum.PowerType name cache
  end)

  local function shards()
    return St.Build(false).power.SoulShards
  end

  it("carries BOTH rails plus the modifier that relates them", function()
    fx.power[SHARDS] = { value = 3, max = 5, unmodified = 30, unmodifiedMax = 50 }
    local p = shards()
    assert.equals(3, p.value)             -- display units, unchanged
    assert.equals(5, p.max)
    assert.is_true(p.readable)
    assert.equals(30, p.unmodified)       -- exact units
    assert.equals(50, p.unmodifiedMax)
    assert.equals(10, p.modifier)
  end)

  it("reports a FRACTIONAL shard exactly — 18 fragments, which the display rail rounds to 1", function()
    fx.power[SHARDS] = { value = 1, max = 5, unmodified = 18, unmodifiedMax = 50 }
    local p = shards()
    assert.equals(1, p.value)             -- what the pipeline used to see, and all it saw
    assert.equals(18, p.unmodified)       -- what it can see now
  end)

  it("modifier is 1 for a power whose rails agree (mana) — a no-op, not a special case", function()
    fx.power[MANA] = { value = 4000, max = 100000, unmodified = 4000, unmodifiedMax = 100000 }
    local p = St.Build(false).power.Mana
    assert.equals(1, p.modifier)
    assert.equals(4000, p.unmodified)
  end)

  it("ABSENT, never zero, when the exact VALUE refuses", function()
    fx.power[SHARDS] = { value = 3, max = 5, unmodifiedMax = 50 }   -- no `unmodified`
    local p = shards()
    assert.equals(3, p.value)             -- the display rail is untouched by the refusal
    assert.is_nil(p.unmodified)
    assert.equals(50, p.unmodifiedMax)    -- the max half still answered
    assert.equals(10, p.modifier)
  end)

  it("ABSENT, never zero, when the exact MAX refuses — no modifier is invented", function()
    fx.power[SHARDS] = { value = 3, max = 5, unmodified = 30 }      -- no `unmodifiedMax`
    local p = shards()
    assert.equals(3, p.value)
    assert.is_nil(p.unmodifiedMax)
    assert.is_nil(p.modifier)
    assert.is_nil(p.unmodified)           -- not asked: the ladder stops at the refused max
  end)

  it("a SECRET exact value degrades to absence rather than reaching the pulse", function()
    fx.power[SHARDS] = { value = 3, max = 5, unmodified = H.secretValue(), unmodifiedMax = 50 }
    local p = shards()
    assert.is_nil(p.unmodified)
    assert.equals(10, p.modifier)         -- the max pair was readable, so this still answers
  end)

  it("the DISPLAY rail refusing does not take the exact rail with it", function()
    -- `readable = false` is State's "we asked and could not tell" for the display value.
    -- The exact read is a separate call and gets its own verdict.
    fx.power[SHARDS] = { value = H.secretValue(), max = 5, unmodified = 30, unmodifiedMax = 50 }
    local p = shards()
    assert.is_false(p.readable)
    assert.is_nil(p.value)
    assert.equals(30, p.unmodified)
  end)

  it("a power with max 0 is still not reported at all (the pre-existing gate)", function()
    fx.power[SHARDS] = { value = 0, max = 0, unmodified = 0, unmodifiedMax = 0 }
    assert.is_nil(St.Build(false).power.SoulShards)
  end)
end)
