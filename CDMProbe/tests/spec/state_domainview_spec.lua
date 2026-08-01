-- state_domainview_spec.lua — State's DOMAIN VIEW: the pressable filter (field-fix A), the
-- aura-lifecycle latch (C) and the charge napkin (C2).
--
-- WHY THIS FILE EXISTS.  The first live session proved `state.abilities` was NOT what its
-- own contract says it is.  State anchors on the CDM database with `allowUnlearned = true`,
-- so the fold promoted rows for spells the character has not talented and rows the Layout
-- can never draw; both read `ready` forever, so they won the priority list every GCD.  One
-- session logged **216 dropped Soul Fire cues** from an untalented Soul Fire outranking the
-- whole rotation.  The fix removes rows — which is exactly the kind of change that can
-- silently delete a REAL button, so the tests below pin both directions: the phantom is
-- gone, AND the survivor is still there, AND the drop was reported.
--
-- It loads the REAL State.lua and stubs only what genuinely needs a live client (the
-- C_CooldownViewer database and frame discovery) — the `viewers_spec` doctrine: a stub
-- proves the caller works GIVEN the collaborator, never that the collaborator exists.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

-- Real Destruction ids, so a drop reads as the ability it actually is.
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
    liveSpellID = opts.live or base,
    isKnown    = opts.isKnown,           -- nil = unreadable, and NOT a drop
    displayable = opts.displayable ~= false,
    cd = opts.cd or { state = "unknown", readable = false, source = "none" },
    charge = opts.charge,
    aura = opts.aura,
    glow = { active = false, readable = true },
  }
end

--------------------------------------------------------------------------------
describe("State domain view — the pressable filter (field-fix A)", function()
  local ns, St
  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    St = ns.State
  end)

  ------------------------------------------------------------------------------
  describe("St.DomainView (pure)", function()
    it("keeps a known, displayable row", function()
      local abilities, dropped = St.DomainView({ [901] = row(901, CHAOS_BOLT) }, nil, true, nil)
      assert.is_not_nil(abilities[CHAOS_BOLT])
      assert.equals(901, abilities[CHAOS_BOLT].display.cooldownID)
      assert.is_nil(dropped[CHAOS_BOLT])
    end)

    it("an UNLEARNED row never reaches abilities, and says so", function()
      local abilities, dropped = St.DomainView(
        { [902] = row(902, SOUL_FIRE, { isKnown = false }) }, nil, true, nil)
      assert.is_nil(abilities[SOUL_FIRE])
      assert.equals("unlearned", dropped[SOUL_FIRE])
    end)

    it("an UNDISPLAYABLE row never reaches abilities, and says so", function()
      -- Incinerate: known, talented, pressed constantly — and absent from the live CDM set,
      -- so there is no frame to anchor a cue to.  `isKnown` alone cannot catch this.
      local abilities, dropped = St.DomainView(
        { [903] = row(903, INCINERATE, { isKnown = true, displayable = false }) }, nil, true, nil)
      assert.is_nil(abilities[INCINERATE])
      assert.equals("no-icon", dropped[INCINERATE])
    end)

    it("an UNREADABLE isKnown is not a drop — absence of a read is not evidence", function()
      local abilities, dropped = St.DomainView(
        { [904] = row(904, CHAOS_BOLT, { isKnown = nil }) }, nil, true, nil)
      assert.is_not_nil(abilities[CHAOS_BOLT])
      assert.is_nil(dropped[CHAOS_BOLT])
    end)

    it("SKIPS the displayable filter entirely when no frame map exists", function()
      -- The v0.32.25 outage shape: an empty frame map must never mean "nothing is drawable".
      local abilities, dropped = St.DomainView(
        { [905] = row(905, INCINERATE, { isKnown = true, displayable = false }) },
        nil, false --[[ no frame map ]], nil)
      assert.is_not_nil(abilities[INCINERATE])
      assert.is_nil(dropped[INCINERATE])
    end)

    it("still drops an unlearned row when the frame map is absent (isKnown is independent)", function()
      local abilities, dropped = St.DomainView(
        { [906] = row(906, SOUL_FIRE, { isKnown = false }) }, nil, false, nil)
      assert.is_nil(abilities[SOUL_FIRE])
      assert.equals("unlearned", dropped[SOUL_FIRE])
    end)

    it("keeps the ability when only ONE of its rows is filtered", function()
      local abilities, dropped = St.DomainView({
        [907] = row(907, CHAOS_BOLT, { isKnown = true, displayable = false }),
        [908] = row(908, CHAOS_BOLT, { isKnown = true, category = "Utility" }),
      }, nil, true, nil)
      assert.is_not_nil(abilities[CHAOS_BOLT])
      assert.equals(908, abilities[CHAOS_BOLT].display.cooldownID)
      assert.is_nil(dropped[CHAOS_BOLT])
    end)

    it("does NOT report a tracked-only row as dropped (it was never a press)", function()
      -- A BuffBar/TrackedBuff row has no pressable member by construction — the pre-existing
      -- exclusion, not a filter drop.  Reporting it would drown the real signal.
      local abilities, dropped = St.DomainView(
        { [909] = row(909, IMMOLATE_AURA, { category = "TrackedBuff", displayable = false }) },
        nil, true, nil)
      assert.is_nil(abilities[IMMOLATE_AURA])
      assert.is_nil(dropped[IMMOLATE_AURA])
    end)

    it("folds by the OOC-cached base when a combat row's spellID is unreadable", function()
      local r = row(910, nil)
      r.spellID = nil
      local abilities = St.DomainView({ [910] = r }, { [910] = CONFLAGRATE }, true, nil)
      assert.is_not_nil(abilities[CONFLAGRATE])
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

    it("abilities carries ONLY the row that is both known and drawable", function()
      local pulse = St.Build(false)
      assert.is_nil(pulse.abilities[SOUL_FIRE])    -- unlearned
      assert.is_nil(pulse.abilities[INCINERATE])   -- no CDM icon
      assert.is_not_nil(pulse.abilities[CHAOS_BOLT])
    end)

    it("reports both drops on the pulse, with their reasons", function()
      local pulse = St.Build(false)
      assert.equals("unlearned", pulse.dropped[SOUL_FIRE])
      assert.equals("no-icon", pulse.dropped[INCINERATE])
      assert.is_nil(pulse.dropped[CHAOS_BOLT])
    end)

    it("NO viewers at all ⇒ Build does not filter on displayability", function()
      -- The guard with the largest blast radius, asserted where it is actually DECIDED (a
      -- pure-function test of the flag proves nothing about how Build computes it).  Viewers
      -- absent — login, CDM off, a relayout mid-pulse — must never empty `abilities`, which
      -- is precisely the shape of the v0.32.25 total outage.
      ns.GetItemFrames = function() return {} end
      local pulse = St.Build(false)
      assert.is_not_nil(pulse.abilities[INCINERATE])
      assert.is_not_nil(pulse.abilities[CHAOS_BOLT])
      assert.is_nil(pulse.dropped[INCINERATE])
      assert.is_nil(pulse.abilities[SOUL_FIRE])       -- isKnown is independent of the map
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

    it("a max of 1 is NOT a charge pool", function()
      withCharges(1, 1)
      local ch = St.Build(false).abilities[CONFLAGRATE].charge
      assert.is_nil(ch.charged)
      assert.equals(0, ch.max)
    end)

    it("seeds the napkin off the exact read, and binds it for the spend", function()
      withCharges(2, 2)
      St.Build(false)
      assert.equals(2, (St.Charges.Read(CID_CONF)))
      St.Charges.Spend(CONFLAGRATE)          -- the binding must have happened in Build
      assert.equals(1, (St.Charges.Read(CID_CONF)))
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
  end)

  ------------------------------------------------------------------------------
  -- The point of the whole phase: the ROTATION falls through instead of vanishing.
  ------------------------------------------------------------------------------
  describe("the Coach falls through to the next line", function()
    local Coach
    local NOW = 1000
    local function cdReady() return { state = "ready", readable = true, source = "live",
                                      changedAt = NOW - 2 } end

    before_each(function()
      H.setSpecIndex(3)          -- Destruction
      ns.ResolveActiveSpec()
      H.load("Coach.lua")
      Coach = ns.Coach.New()
    end)

    -- A pulse whose `abilities` came through the REAL fold, so the filter is in the path.
    local function pulseFrom(cooldowns)
      local abilities, dropped = St.DomainView(cooldowns, nil, true, nil)
      return {
        at = NOW, combat = true, combatStartedAt = NOW - 60, mode = "st",
        power = { SoulShards = { value = 3, incoming = 0, max = 5, readable = true } },
        buffs = {}, history = {}, abilities = abilities, dropped = dropped,
      }
    end

    local function press(g)
      for spellID, cue in pairs(g.cues) do
        if cue.emphasis == "ROTATION" or cue.emphasis == "LATE" then return spellID end
      end
    end

    it("an UNLEARNED Soul Fire does not win — Conflagrate does", function()
      -- The live bug in miniature: untalented Soul Fire reads `ready` forever, so before the
      -- filter it took L2 every single GCD and the cue was then dropped by the Binder.
      local g = Coach:Compute(pulseFrom({
        [901] = row(901, SOUL_FIRE, { isKnown = false, cd = cdReady() }),
        [902] = row(902, CONFLAGRATE, { isKnown = true, cd = cdReady() }),
        [903] = row(903, CHAOS_BOLT, { isKnown = true }),
      }))
      assert.equals(CONFLAGRATE, press(g))
    end)

    it("a TALENTED Soul Fire still wins L2 — the filter removes phantoms, not presses", function()
      local g = Coach:Compute(pulseFrom({
        [901] = row(901, SOUL_FIRE, { isKnown = true, cd = cdReady() }),
        [902] = row(902, CONFLAGRATE, { isKnown = true, cd = cdReady() }),
        [903] = row(903, CHAOS_BOLT, { isKnown = true }),
      }))
      assert.equals(SOUL_FIRE, press(g))
    end)

    it("an UNDISPLAYABLE Soul Fire does not win either", function()
      local g = Coach:Compute(pulseFrom({
        [901] = row(901, SOUL_FIRE, { isKnown = true, displayable = false, cd = cdReady() }),
        [902] = row(902, CONFLAGRATE, { isKnown = true, cd = cdReady() }),
        [903] = row(903, CHAOS_BOLT, { isKnown = true }),
      }))
      assert.equals(CONFLAGRATE, press(g))
    end)
  end)
end)

--------------------------------------------------------------------------------
-- VIRTUAL ROWS — the other direction: putting back a row State cannot observe.
--
-- ⚠ THIS IS THE RISKIEST TEST FILE IN THE ADDON, because this feature and field-fix A pull
-- in OPPOSITE directions over the same table.  A is "remove rows we cannot trust"; this is
-- "add a row we never saw".  So EVERY fence below is mutation-checked: drop it in State.lua
-- and one of these must go red.  A fence that passes both ways is exactly the failure mode
-- that shipped the phantom-ability bug in the first place.
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

  -- The permissive world: Incinerate known, no base cooldown, nothing tracked.
  local function known(...)
    for _, id in ipairs({ ... }) do fx.known[id] = true end
  end
  local function zeroCD(...)
    for _, id in ipairs({ ... }) do fx.baseCD[id] = 0 end
  end
  local function candidates(abilities, dropped)
    return St.VirtualCandidates(ns.Spec, abilities or {}, dropped,
                                St.SpellKnown, ns.BaseCooldown)
  end

  ------------------------------------------------------------------------------
  describe("the positive case", function()
    before_each(function() known(INCINERATE); zeroCD(INCINERATE) end)

    it("nominates the spec's untracked floor press", function()
      assert.are.same({ INCINERATE }, candidates())
    end)

    it("the synthesised row is keyed by base spellID and marked virtual", function()
      local r = St.VirtualRow(INCINERATE)
      assert.is_true(r.virtual)
      assert.are.equal(INCINERATE, r.spellID)
    end)

    it("carries the NEGATIVE display handle — no collision with a real cooldownID", function()
      assert.are.equal(-INCINERATE, St.VirtualRow(INCINERATE).display.cooldownID)
      assert.is_true(St.VirtualRow(INCINERATE).display.cooldownID < 0)
    end)

    it("says READY, and says WHY — `source = static`, never laundered as a read", function()
      -- A 0-cooldown spell has no cooldown to be unsure about, so `ready` is a statement
      -- about the spell's NATURE.  Calling it "live" would claim an observation we never
      -- made, which is the one thing this project refuses to do.
      local cd = St.VirtualRow(INCINERATE).cd
      assert.are.equal("ready", cd.state)
      assert.are.equal("static", cd.source)
      assert.are.equal(0, cd.remaining)
    end)
  end)

  ------------------------------------------------------------------------------
  -- One test per fence.  Each names the mutation it guards.
  ------------------------------------------------------------------------------
  describe("the fences", function()
    it("NOT KNOWN ⇒ no row (the surviving half of field-fix A)", function()
      zeroCD(INCINERATE)                       -- known deliberately not set
      assert.are.same({}, candidates())
    end)

    it("a REFUSED knownness read ⇒ no row (under-show, never a guess)", function()
      zeroCD(INCINERATE)
      _G.C_SpellBook = { IsSpellKnown = function() error("secret") end }
      assert.are.same({}, candidates())
      _G.C_SpellBook = nil
      assert.are.same({}, candidates())        -- API absent entirely: same answer
    end)

    it("a NON-ZERO base cooldown ⇒ no row", function()
      -- The load-bearing fence: with a real cooldown there is no alert channel, no OOC
      -- baseline and no napkin, so `ready` would be an invention.
      known(INCINERATE); fx.baseCD[INCINERATE] = 45
      assert.are.same({}, candidates())
    end)

    it("an UNREADABLE base cooldown ⇒ no row (nil is not zero)", function()
      known(INCINERATE)                        -- baseCD left nil
      assert.are.same({}, candidates())
    end)

    it("ALREADY PRESENT in abilities ⇒ no row (additive only, never a duplicate)", function()
      known(INCINERATE); zeroCD(INCINERATE)
      assert.are.same({}, candidates({ [INCINERATE] = { spellID = INCINERATE } }))
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

      before_each(function() known(INCINERATE); zeroCD(INCINERATE) end)

      it("a row keyed 686 whose overrideTooltipSpellID is 29722 suppresses ours", function()
        assert.are.same({}, candidates({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, liveSpellID = SHADOW_BOLT,
                            overrideTooltipSpellID = INCINERATE },
        }))
      end)

      it("...and via overrideSpellID alone (the other static field)", function()
        assert.are.same({}, candidates({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, overrideSpellID = INCINERATE },
        }))
      end)

      it("THE FLICKER REGRESSION: still no row while the Demonic Art is ARMED", function()
        -- With the Art up, that row's `liveSpellID` becomes Infernal Bolt 433891 — so a
        -- liveSpellID-ONLY union would let our duplicate icon flicker back MID-COMBAT,
        -- exactly when the ability is most active.  The STATIC override fields carry 29722
        -- throughout, which is why unioning all three is load-bearing rather than tidy.
        local INFERNAL_BOLT = 433891
        assert.are.same({}, candidates({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, liveSpellID = INFERNAL_BOLT,
                            overrideSpellID = INCINERATE,
                            overrideTooltipSpellID = INCINERATE },
        }))
      end)

      it("...and a row displaying it under its OWN base (liveSpellID) suppresses ours too", function()
        assert.are.same({}, candidates({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, liveSpellID = INCINERATE },
        }))
      end)

      it("HELLCALLER: the same row DROPPED as unlearned ⇒ we DO draw ours", function()
        -- 686 is unlearned on Hellcaller, so it never enters `abilities` at all — nothing is
        -- on screen, and the 31 %→0 % win from Phase 1 has to survive intact.
        assert.are.same({ INCINERATE }, candidates({}, { [SHADOW_BOLT] = "unlearned" }))
      end)

      it("a row displaying something ELSE does not suppress us", function()
        -- The fence must be a lookup, not a blanket "any override present" test.
        assert.are.same({ INCINERATE }, candidates({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, overrideTooltipSpellID = 433891 },
        }))
      end)

      it("St.DisplayedIdentities unions base + live + BOTH static override fields", function()
        local on = St.DisplayedIdentities({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, liveSpellID = 433891,
                            overrideSpellID = 1, overrideTooltipSpellID = INCINERATE },
        })
        assert.is_true(on[SHADOW_BOLT])
        assert.is_true(on[433891])
        assert.is_true(on[1])
        assert.is_true(on[INCINERATE])
      end)

      it("a SECRET display id is never keyed (the standing secret-value rule)", function()
        H.markSecret(INCINERATE)
        local on = St.DisplayedIdentities({
          [SHADOW_BOLT] = { spellID = SHADOW_BOLT, overrideTooltipSpellID = INCINERATE },
        })
        assert.is_nil(on[INCINERATE])
      end)
    end)

    it("DROPPED AS UNLEARNED ⇒ no row, even when the spellbook disagrees", function()
      -- A conflict between the CDM struct and the spellbook resolves to NOT DRAWING.
      known(INCINERATE); zeroCD(INCINERATE)
      assert.are.same({}, candidates({}, { [INCINERATE] = "unlearned" }))
    end)

    it("dropped as NO-ICON is NOT a bar — that is exactly what we are here to fix", function()
      known(INCINERATE); zeroCD(INCINERATE)
      assert.are.same({ INCINERATE }, candidates({}, { [INCINERATE] = "no-icon" }))
    end)

    it("NOT SPEC-DECLARED ⇒ no row, however known and cooldownless", function()
      local NOT_OURS = 999999
      known(NOT_OURS); zeroCD(NOT_OURS)
      assert.are.same({}, candidates())
    end)

    it("a UTILITY ⇒ no row (defensives are never cued, and never ours to draw)", function()
      local UNENDING_RESOLVE = 104773
      known(UNENDING_RESOLVE); zeroCD(UNENDING_RESOLVE)
      assert.are.same({}, candidates())
    end)

    it("an AURA row ⇒ no row (an input to a decision, never a press)", function()
      local BACKDRAFT = 117828
      known(BACKDRAFT); zeroCD(BACKDRAFT)
      assert.are.same({}, candidates())
    end)

    it("EXPECT=FALSE ⇒ no row — a transform is not a second ability", function()
      local INFERNAL_BOLT = 433891   -- an override on the Incinerate frame, never its own icon
      known(INFERNAL_BOLT); zeroCD(INFERNAL_BOLT)
      assert.are.same({}, candidates())
    end)

    it("EXPECT=FALSE ⇒ no row — nor is a cast-id ALIAS", function()
      -- 348 is Immolate's cast id; the CDM tracks the DoT aura 157736.  Immolate has no base
      -- cooldown, so without `expect = false` on the alias this would be drawn as a SECOND
      -- Immolate icon beside the real one.
      known(IMMOLATE_CAST); zeroCD(IMMOLATE_CAST)
      assert.are.same({}, candidates({ [IMMOLATE_AURA] = { spellID = IMMOLATE_AURA } }))
    end)
  end)

  ------------------------------------------------------------------------------
  -- THE GUARD.  Detection means no per-ability flag to forget — and no per-ability flag
  -- stopping a spec-table edit from admitting something new.  These pin the whole result.
  ------------------------------------------------------------------------------
  describe("exactly one virtual row per spec", function()
    it("Destruction yields EXACTLY Incinerate", function()
      -- A realistic world: every 0-cooldown button of the spec, with the ones the live CDM
      -- actually tracks present in `abilities`.  Incinerate and the cast-id alias are the
      -- two absentees; only Incinerate may be drawn.
      local CHAOS_BOLT_, RAIN_OF_FIRE = 116858, 5740
      known(INCINERATE, IMMOLATE_CAST, CHAOS_BOLT_, RAIN_OF_FIRE, IMMOLATE_AURA)
      zeroCD(INCINERATE, IMMOLATE_CAST, CHAOS_BOLT_, RAIN_OF_FIRE, IMMOLATE_AURA)
      assert.are.same({ INCINERATE }, candidates({
        [CHAOS_BOLT_]   = { spellID = CHAOS_BOLT_ },
        [RAIN_OF_FIRE]  = { spellID = RAIN_OF_FIRE },
        [IMMOLATE_AURA] = { spellID = IMMOLATE_AURA },
      }))
    end)

    it("Demonology yields EXACTLY Shadow Bolt (the seam is per-spec DATA, not code)", function()
      H.setSpecIndex(1)
      ns.ResolveActiveSpec()
      local SHADOW_BOLT, HAND_OF_GULDAN, DEMONBOLT, IMPLOSION = 686, 105174, 264178, 196277
      local IMP_LORD_ALIAS = 136726
      known(SHADOW_BOLT, HAND_OF_GULDAN, DEMONBOLT, IMPLOSION, IMP_LORD_ALIAS)
      -- ⚠ The Imp Lord ALIAS is given a zero cooldown DELIBERATELY, though the real ability
      -- has 120s.  Its real cooldown would exclude it anyway — and that is the problem: it
      -- would be excluded by ACCIDENT rather than by being an alias.  Zeroing it here means
      -- only `expect = false` can keep it out, so removing that fence turns this test red
      -- instead of leaving it silently protected.
      zeroCD(SHADOW_BOLT, HAND_OF_GULDAN, DEMONBOLT, IMPLOSION, IMP_LORD_ALIAS)
      assert.are.same({ SHADOW_BOLT }, candidates({
        [HAND_OF_GULDAN] = { spellID = HAND_OF_GULDAN },
        [DEMONBOLT]      = { spellID = DEMONBOLT },
        [IMPLOSION]      = { spellID = IMPLOSION },
      }))
    end)

    it("no active spec ⇒ nothing at all (the passive path stays silent)", function()
      known(INCINERATE); zeroCD(INCINERATE)
      H.setSpecIndex(2)          -- Affliction: registered nowhere, HUD goes passive
      ns.ResolveActiveSpec()
      assert.are.same({}, St.VirtualCandidates(ns.Spec, {}, nil, St.SpellKnown, ns.BaseCooldown))
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

    it("HELLCALLER: an UNLEARNED 686 row keeps its base, so ours still synthesises", function()
      -- The fence on the fence.  Re-keying a DROPPED row onto Incinerate would make
      -- `virtualCandidates`' "not dropped-unlearned" test see Incinerate as unlearned and
      -- refuse to draw ours — silently killing the one path that already works in the field
      -- (Hellcaller: 0 % w:- , Incinerate cued 10x and drawn 50x, 2026-07-30).  Only a row
      -- that SURVIVED the filter may claim a display identity.
      local SHADOW_BOLT = 686
      _G.C_CooldownViewer.GetCooldownViewerCooldownInfo = function()
        return { spellID = SHADOW_BOLT, isKnown = false, overrideSpellID = INCINERATE,
                 overrideTooltipSpellID = INCINERATE }
      end
      local pulse = St.Build(false)
      assert.equals("unlearned", pulse.dropped[SHADOW_BOLT])  -- the DROP keeps the raw base
      assert.is_nil(pulse.dropped[INCINERATE])
      assert.is_not_nil(pulse.abilities[INCINERATE])          -- ...so ours is synthesised
      assert.is_true(pulse.abilities[INCINERATE].virtual)
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

    it("either cooldownID's latch surfaces under its own base spellID", function()
      alert(IMM_AURA_CID, A.PandemicTime)
      local _, _, edges = St.DomainView(rows(), nil, true, St.dotEdge)
      assert.equals("pandemic", edges[IMMOLATE_AURA].state)

      H.advance(1)
      alert(IMM_CAST_CID, A.PandemicTime)
      local _, _, edges2 = St.DomainView(rows(), nil, true, St.dotEdge)
      assert.equals("pandemic", edges2[IMMOLATE_CAST].state)
    end)

    it("rides the pressable row so the brain never sees a cooldownID", function()
      alert(IMM_CAST_CID, A.PandemicTime)
      local abilities = St.DomainView(rows(), nil, true, St.dotEdge)
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
      local _, _, edges = St.DomainView(twoRows, nil, true, St.dotEdge)
      assert.equals("absent", edges[CONFLAGRATE].state)
    end)

    it("no alert seen ⇒ no latch, and the brain stays silent", function()
      local abilities, _, edges = St.DomainView(rows(), nil, true, St.dotEdge)
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
