-- derived_resource_spec.lua — THE CLASS-RESOURCE CHANNEL (2026-08-02).
--
-- WHAT IT COVERS, in two layers:
--   1. `ns.ReadCastCount` / `ns.ReadAuraApplications` / `ns.ReadMaxAuraApplications` against
--      the REAL Util.lua, with only the client APIs faked — the guarded-read ladder itself.
--   2. State's declarative `derived` block: `spec.derived` in, `state.derived` out.
--
-- WHY THE CHANNEL EXISTS.  `state.power` iterates `Enum.PowerType` and is therefore
-- structurally blind to anything not in that enum.  Demon Hunter Soul Fragments are exactly
-- that: no `Enum.PowerType.SoulFragments` member exists, so no amount of care in `readPower`
-- can ever surface them.  oUF calls them class powers with NEGATIVE pseudo-IDs, commented
-- `-- these are not real class powers` [oUF classpower.lua:70-77]; Blizzard's own Devourer
-- bar synthesizes the same numbers off ordinary spell APIs
-- [Blizzard_UnitFrame/DemonHunterSoulFragmentsBar.lua:150-177].  A spec that wants one has
-- to ASK, which is what `spec.derived` does.
--
-- ⚠ THE PROPERTY THIS FILE EXISTS TO PIN: ABSENT IS NEVER ZERO.  Every one of these readers
-- can refuse, and 0 is a real, actionable answer ("you have no fragments").  A refusal that
-- came back as 0 would tell a tank it has nothing to spend at the exact moment the read went
-- secret — so the ladder returns nil, `readable` goes false, and the brain declines to
-- claim.  Several cases below are ONLY about that distinction.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

local SOUL_CLEAVE   = 228477    -- Vengeance: fragments read as a CAST COUNT (oUF's channel)
local DARK_HEART    = 1225789   -- Devourer: fragments read as AURA STACKS
local SILENCE       = 1227702   -- Devourer, inside Void Metamorphosis

describe("the derived class-resource channel", function()
  local ns, fx

  ----------------------------------------------------------------------------
  -- Layer 1 — the guarded readers (the REAL Util.lua)
  ----------------------------------------------------------------------------
  describe("ns.ReadCastCount", function()
    before_each(function() ns, fx = H.fresh(); H.load("Util.lua") end)

    it("returns the client's count", function()
      fx.castCount[SOUL_CLEAVE] = 4
      assert.equals(4, ns.ReadCastCount(SOUL_CLEAVE))
    end)

    -- ZERO IS A REAL ANSWER and must survive the ladder untouched: "you have spent every
    -- fragment" is a sentence the brain acts on (stop cueing Soul Cleave), and it is not
    -- the same sentence as "we could not ask".
    it("passes a real 0 through — it is an answer, not a refusal", function()
      fx.castCount[SOUL_CLEAVE] = 0
      assert.equals(0, ns.ReadCastCount(SOUL_CLEAVE))
    end)

    it("returns nil when the client has no answer", function()
      assert.is_nil(ns.ReadCastCount(SOUL_CLEAVE))
    end)

    it("returns nil when the call throws", function()
      H.throwOn("C_Spell.GetSpellCastCount")
      fx.castCount[SOUL_CLEAVE] = 4
      assert.is_nil(ns.ReadCastCount(SOUL_CLEAVE))
    end)

    it("returns nil for a SECRET count rather than a poisoned number", function()
      fx.castCount[SOUL_CLEAVE] = H.secretValue()
      assert.is_nil(ns.ReadCastCount(SOUL_CLEAVE))
    end)

    it("refuses a secret or non-number spellID without indexing on it", function()
      assert.is_nil(ns.ReadCastCount(H.secretValue()))
      assert.is_nil(ns.ReadCastCount("228477"))
      assert.is_nil(ns.ReadCastCount(nil))
    end)

    it("returns nil when the API is absent entirely", function()
      _G.C_Spell.GetSpellCastCount = nil
      assert.is_nil(ns.ReadCastCount(SOUL_CLEAVE))
    end)

    -- ⚠ NO COMBAT GATE, AND THAT IS THE POINT.  `ns.ReadCharges` short-circuits on
    -- InCombatLockdown because `GetSpellCharges` was MEASURED secret in restricted combat —
    -- a record of a measurement, not a house style.  This API has never been measured, and
    -- pre-emptively gating it would make the measurement impossible: every in-combat read
    -- would return nil for a reason WE chose.  If it turns out secret, the gate gets added
    -- with the capture cited, exactly as ReadCharges' was.  Mutation-check: add the gate and
    -- this case goes red.
    it("still reads IN COMBAT — the gate ReadCharges carries is not copied down", function()
      H.setCombat(true)
      fx.castCount[SOUL_CLEAVE] = 3
      assert.equals(3, ns.ReadCastCount(SOUL_CLEAVE))
      -- ...and the contrast that makes it meaningful, on the same fixture:
      fx.charges[SOUL_CLEAVE] = { currentCharges = 3, maxCharges = 3 }
      assert.is_nil(ns.ReadCharges(SOUL_CLEAVE))
    end)
  end)

  describe("ns.ReadAuraApplications", function()
    before_each(function() ns, fx = H.fresh(); H.load("Util.lua") end)

    it("returns the aura's stack count", function()
      fx.auraByID[DARK_HEART] = { applications = 5 }
      assert.equals(5, ns.ReadAuraApplications(DARK_HEART))
    end)

    it("returns nil when the aura is absent — NOT 0", function()
      -- The distinction the brain needs: "the buff is not up" reaches it as `nil` here and
      -- becomes `readable = false`, so a rotation line gated on stacks stays silent rather
      -- than firing on a fabricated zero.
      assert.is_nil(ns.ReadAuraApplications(DARK_HEART))
    end)

    it("returns nil for a SECRET aura record (the KB's predicted in-combat answer)", function()
      -- knowledge/addon-dev/cooldown-manager.md:517 — the ENTIRE AuraData record is secret
      -- when restricted, "including GetPlayerAuraBySpellID. Your own auras are as sealed as
      -- the target's."  This is that case, and it must degrade rather than taint.
      fx.auraByID[DARK_HEART] = H.markSecretTable({ applications = 5 })
      assert.is_nil(ns.ReadAuraApplications(DARK_HEART))
    end)

    it("returns nil for a secret `applications` on an otherwise readable record", function()
      fx.auraByID[DARK_HEART] = { applications = H.secretValue() }
      assert.is_nil(ns.ReadAuraApplications(DARK_HEART))
    end)

    it("returns nil when the read throws", function()
      fx.auraByID[DARK_HEART] = { applications = 5 }
      fx.auraThrows[DARK_HEART] = true
      assert.is_nil(ns.ReadAuraApplications(DARK_HEART))
    end)

    it("returns nil when the namespace is absent", function()
      _G.C_UnitAuras = nil
      assert.is_nil(ns.ReadAuraApplications(DARK_HEART))
    end)
  end)

  describe("ns.ReadMaxAuraApplications", function()
    before_each(function() ns, fx = H.fresh(); H.load("Util.lua") end)

    it("returns the spell-data cap", function()
      fx.maxStacks[DARK_HEART] = 6
      assert.equals(6, ns.ReadMaxAuraApplications(DARK_HEART))
    end)

    -- A cap of 0 is nonsense, not a measurement: it would make every "at cap" test true.
    it("refuses a 0 cap", function()
      fx.maxStacks[DARK_HEART] = 0
      assert.is_nil(ns.ReadMaxAuraApplications(DARK_HEART))
    end)

    it("returns nil on a secret or absent answer", function()
      assert.is_nil(ns.ReadMaxAuraApplications(DARK_HEART))
      fx.maxStacks[DARK_HEART] = H.secretValue()
      assert.is_nil(ns.ReadMaxAuraApplications(DARK_HEART))
    end)
  end)

  ----------------------------------------------------------------------------
  -- Layer 2 — State's declarative `derived` block
  ----------------------------------------------------------------------------
  -- Driven through the REAL State.lua with a synthetic spec, because the point is that State
  -- carries NO spec opinion: it reads a declaration and reports the answer.  A spec that
  -- declares nothing must cost nothing.
  describe("State.Build's `derived` emission", function()
    local St

    local function withSpec(derived)
      ns, fx = H.fresh()
      local spec = { SpecIDs = {}, Spec = {}, powers = {}, log = {}, derived = derived,
                     SpecInfo = function() return { kind = "button" }, false end,
                     SpecPowerDelta = function() return { power = nil, delta = 0 } end }
      ns.RegisterSpec(901, spec)
      ns.SetActiveSpec(901)
      H.load("State.lua"); St = ns.State
      return St.Build()
    end

    it("emits nil for a spec that declares no derived resources", function()
      -- 35 of 40 specs.  The pulse must not carry an empty table for all of them.
      local pulse = withSpec(nil)
      assert.is_nil(pulse.derived)
    end)

    it("emits nil for an EMPTY declaration list too", function()
      local pulse = withSpec({})
      assert.is_nil(pulse.derived)
    end)

    it("reads a castCount resource and carries the declared max", function()
      ns, fx = H.fresh()
      local pulse
      do
        local spec = { SpecIDs = {}, Spec = {}, powers = {}, log = {},
                       derived = { { name = "SoulFragments", kind = "castCount",
                                     spellID = SOUL_CLEAVE, max = 6 } },
                       SpecInfo = function() return { kind = "button" }, false end,
                       SpecPowerDelta = function() return { power = nil, delta = 0 } end }
        ns.RegisterSpec(901, spec)
        ns.SetActiveSpec(901)
        fx.castCount[SOUL_CLEAVE] = 4
        H.load("State.lua"); St = ns.State
        pulse = St.Build()
      end
      local d = pulse.derived.SoulFragments
      assert.equals(4, d.value)
      assert.equals(6, d.max)          -- no live cap API for a cast count: the declaration
      assert.is_true(d.readable)
      assert.equals("castCount", d.source)   -- WHICH channel produced the number
    end)

    -- THE REFUSAL SHAPE, which is the whole reason `readable` exists as a separate field.
    it("reports a refused read as readable=false with value ABSENT, never 0", function()
      local pulse = withSpec({ { name = "SoulFragments", kind = "castCount",
                                 spellID = SOUL_CLEAVE, max = 6 } })
      local d = pulse.derived.SoulFragments
      assert.is_nil(d.value)
      assert.is_false(d.readable)
      assert.equals(6, d.max)          -- the declared cap survives a refused VALUE
    end)

    it("prefers the LIVE cap over the declared one for an aura-stack resource", function()
      ns, fx = H.fresh()
      local spec = { SpecIDs = {}, Spec = {}, powers = {}, log = {},
                     derived = { { name = "Souls", kind = "auraStacks",
                                   spellID = DARK_HEART, max = 99 } },
                     SpecInfo = function() return { kind = "button" }, false end,
                     SpecPowerDelta = function() return { power = nil, delta = 0 } end }
      ns.RegisterSpec(901, spec)
      ns.SetActiveSpec(901)
      fx.auraByID[DARK_HEART] = { applications = 3 }
      fx.maxStacks[DARK_HEART] = 6
      H.load("State.lua"); St = ns.State
      local d = St.Build().derived.Souls
      assert.equals(3, d.value)
      assert.equals(6, d.max)          -- the client's 6, not the declaration's 99
      assert.equals("auraStacks", d.source)
    end)

    -- `maxSpellID` — the cap and the stacks can live on DIFFERENT spells (Devourer reads
    -- Silence the Whispers' stacks against a cap that is not Silence's own).
    it("honours `maxSpellID` when the cap lives on another spell", function()
      ns, fx = H.fresh()
      local spec = { SpecIDs = {}, Spec = {}, powers = {}, log = {},
                     derived = { { name = "Souls", kind = "auraStacks",
                                   spellID = SILENCE, maxSpellID = DARK_HEART } },
                     SpecInfo = function() return { kind = "button" }, false end,
                     SpecPowerDelta = function() return { power = nil, delta = 0 } end }
      ns.RegisterSpec(901, spec)
      ns.SetActiveSpec(901)
      fx.auraByID[SILENCE] = { applications = 2 }
      fx.maxStacks[DARK_HEART] = 6
      H.load("State.lua"); St = ns.State
      local d = St.Build().derived.Souls
      assert.equals(2, d.value)
      assert.equals(6, d.max)
      -- The cap was asked of DARK_HEART, not of SILENCE — the question, not just the answer.
      assert.equals(DARK_HEART, H.asked.maxStacks[1])
    end)

    it("emits every declared resource, keyed by NAME", function()
      ns, fx = H.fresh()
      local spec = { SpecIDs = {}, Spec = {}, powers = {}, log = {},
                     derived = {
                       { name = "DarkHeart", kind = "auraStacks", spellID = DARK_HEART },
                       { name = "Silence",   kind = "auraStacks", spellID = SILENCE },
                     },
                     SpecInfo = function() return { kind = "button" }, false end,
                     SpecPowerDelta = function() return { power = nil, delta = 0 } end }
      ns.RegisterSpec(901, spec)
      ns.SetActiveSpec(901)
      fx.auraByID[DARK_HEART] = { applications = 3 }
      H.load("State.lua"); St = ns.State
      local d = St.Build().derived
      -- Both present; the one whose aura is down reports honestly rather than vanishing —
      -- Devourer's Void-Metamorphosis switch needs to see BOTH candidates every pulse to
      -- decide which is the live resource.
      assert.equals(3, d.DarkHeart.value)
      assert.is_nil(d.Silence.value)
      assert.is_false(d.Silence.readable)
    end)

    -- A malformed declaration must not take the pulse down — the same tolerance every other
    -- spec-data read in State has.
    it("skips a declaration with an unknown kind or no name", function()
      local pulse = withSpec({
        { name = "Bogus", kind = "telepathy", spellID = 1 },
        { kind = "castCount", spellID = SOUL_CLEAVE },
        { name = "Good", kind = "castCount", spellID = SOUL_CLEAVE, max = 6 },
      })
      assert.is_nil(pulse.derived.Bogus)
      assert.is_not_nil(pulse.derived.Good)
    end)
  end)
end)
