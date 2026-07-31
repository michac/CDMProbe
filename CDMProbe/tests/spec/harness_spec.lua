-- harness_spec.lua — the harness is a COLLABORATOR, and gets the same treatment as any
-- other one.
--
-- This file is not ceremony.  `issecrettable` sat hardcoded `false` in mock_ns.lua for the
-- whole life of the addon, which made six real refusal branches unreachable in tests while
-- every suite stayed green — the v0.32.25 shape exactly (a stub proves the caller works
-- GIVEN the collaborator, never that the collaborator does what it claims).  A
-- harness_spec is what would have caught it, so each knob the CDM edge inventory leans on
-- is proved to work HERE, before ~70 fixture cases start trusting it.
--
-- The proof is always taken through the SHIPPING code where there is any — ns.IsSecret /
-- ns.IsSecretTable are Util.lua:62-80, and the harness supplies only the two globals they
-- ask (`issecretvalue` / `issecrettable`).
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("mock_ns harness", function()
  local ns, fx
  before_each(function() ns, fx = H.fresh() end)

  ------------------------------------------------------------------------------
  describe("H.secretTable — the table-refuses-indexing axis", function()
    it("drives the REAL ns.IsSecretTable", function()
      local t = {}
      assert.is_false(ns.IsSecretTable(t))
      H.markSecretTable(t)
      assert.is_true(ns.IsSecretTable(t))
    end)

    it("is keyed by IDENTITY — a same-shaped twin is not marked", function()
      -- The trap the fixture corpus has to design around: a fake that rebuilds its return
      -- table per call can never be marked, and would pass a secret-struct case for the
      -- wrong reason.
      local marked = H.markSecretTable({ spellID = 1 })
      assert.is_false(ns.IsSecretTable({ spellID = 1 }))
      assert.is_true(ns.IsSecretTable(marked))
    end)

    it("is independent of H.secret — a secret VALUE is a different verdict", function()
      local t = H.markSecretTable({})
      assert.is_false(ns.IsSecret(t))         -- issecretvalue says no
      assert.is_true(ns.IsSecretTable(t))
    end)

    it("resets on H.fresh()", function()
      local t = H.markSecretTable({})
      ns = H.fresh()
      assert.is_false(ns.IsSecretTable(t))
    end)
  end)

  ------------------------------------------------------------------------------
  describe("H.throws / H.guard — the call-raises axis", function()
    it("a guarded call is transparent until armed", function()
      local f = H.guard("Some.Call", function(a) return a + 1 end)
      assert.equals(3, f(2))
      H.throwOn("Some.Call")
      assert.is_false((pcall(f, 2)))
    end)

    it("arms a REAL client fake, and the addon's pcall absorbs it", function()
      -- ns.ReadCharges pcalls C_Spell.GetSpellCharges; a throw must yield nil ("we don't
      -- know"), never a crash and never a fabricated count.
      fx.charges[116858] = { currentCharges = 2, maxCharges = 2 }
      local cur, max = ns.ReadCharges(116858)
      assert.equals(2, cur); assert.equals(2, max)
      H.throwOn("C_Spell.GetSpellCharges")
      assert.is_nil((ns.ReadCharges(116858)))
    end)

    it("resets on H.fresh()", function()
      H.throwOn("C_Spell.GetSpellCharges")
      ns, fx = H.fresh()
      fx.charges[1] = { currentCharges = 1, maxCharges = 2 }
      assert.equals(1, (ns.ReadCharges(1)))
    end)
  end)

  ------------------------------------------------------------------------------
  describe("H.poison — the table-indexes-but-a-field-raises axis", function()
    it("reads clean fields and raises on the named ones", function()
      local t = H.poison({ spellID = 348, isKnown = true }, { "isKnown" })
      assert.equals(348, t.spellID)
      assert.is_false((pcall(function() return t.isKnown end)))
    end)

    it("preserves table IDENTITY, so it composes with H.markSecretTable", function()
      local t = { spellID = 348 }
      assert.are.equal(t, H.poison(t, { "isKnown" }))
    end)

    it("still passes type() and ns.IsSecretTable — that is the whole point", function()
      -- Util.lua:160-163's claim in one assertion: a table that clears BOTH prior guards
      -- can still throw on access, which is why the index itself is pcall'd there.
      local t = H.poison({ duration = 5, startTime = 100 }, { "startTime" })
      assert.equals("table", type(t))
      assert.is_false(ns.IsSecretTable(t))
      assert.is_false((pcall(function() return t.startTime end)))
    end)

    it("survives the rawCooldown ladder as a nil, not a crash", function()
      fx.cd[116858] = H.poison({ duration = 5, startTime = 100 }, { "startTime" })
      assert.is_nil((ns.ReadCooldown(116858)))
    end)
  end)

  ------------------------------------------------------------------------------
  describe("H.installGlobals — the leak between spec FILES", function()
    it("H.fresh() puts back a deleted fake", function()
      _G.C_Spell.GetSpellCharges = nil
      ns, fx = H.fresh()
      assert.equals("function", type(_G.C_Spell.GetSpellCharges))
    end)

    it("rebinds the fakes to THIS H's fixture handle", function()
      -- The subtler half: the closures capture `H`, and read `H.fx` at call time.  A fake
      -- left bound to another file's H would read a stale (or nil) fixture table.
      fx.known[29722] = true
      assert.is_true(_G.C_SpellBook.IsSpellKnown(29722))
      local _, fx2 = H.fresh()
      assert.is_false(_G.C_SpellBook.IsSpellKnown(29722))
      fx2.known[29722] = true
      assert.is_true(_G.C_SpellBook.IsSpellKnown(29722))
    end)
  end)

  ------------------------------------------------------------------------------
  describe("the client fakes are default-INERT", function()
    it("an unregistered cooldown id reads exactly like an absent API", function()
      assert.is_nil((ns.ReadCooldown(999999)))
    end)

    it("an unregistered charges id likewise", function()
      assert.is_nil((ns.ReadCharges(999999)))
    end)

    it("the aura walk yields nothing until fx.auras is filled", function()
      local seen = 0
      _G.AuraUtil.ForEachAura("player", "HELPFUL", nil, function() seen = seen + 1 end, true)
      assert.equals(0, seen)
      fx.auras = { { spellId = 264173, name = "Demonic Core" } }
      _G.AuraUtil.ForEachAura("player", "HELPFUL", nil, function() seen = seen + 1 end, true)
      assert.equals(1, seen)
    end)

    it("IsSpellOverlayed answers FALSE, not nil — 'not glowing' is an answer", function()
      assert.is_false(_G.C_SpellActivationOverlay.IsSpellOverlayed(264178))
      fx.glow[264178] = true
      assert.is_true(_G.C_SpellActivationOverlay.IsSpellOverlayed(264178))
    end)

    it("fx.auraThrows refuses ONE id while the others answer", function()
      fx.auraThrows[1] = true
      fx.auraByID[2] = { spellId = 2 }
      assert.is_false((pcall(_G.C_UnitAuras.GetPlayerAuraBySpellID, 1)))
      assert.is_not_nil(_G.C_UnitAuras.GetPlayerAuraBySpellID(2))
    end)
  end)

  ------------------------------------------------------------------------------
  describe("H.asked — which id was the client asked about", function()
    it("records the cooldown read, including the GCD's own", function()
      fx.cd[116858] = { duration = 0, startTime = 0 }
      fx.cd[61304]  = { duration = 0, startTime = 0 }
      ns.ReadCooldown(116858)
      -- The spell, then the GCD — Util.lua:219 then :230.  That SECOND entry is the
      -- per-entry GCD read the plan's §3.3 hoist removes, and this is how a fixture sees it.
      assert.are.same({ 116858, 61304 }, H.asked.cooldown)
      assert.are.same({ 116858 }, H.asked.charges)   -- the banked-charge short-circuit's read
    end)

    it("resets on H.fresh()", function()
      fx.cd[1] = { duration = 0, startTime = 0 }
      ns.ReadCooldown(1)
      assert.is_true(#H.asked.cooldown > 0)
      ns, fx = H.fresh()
      assert.are.same({}, H.asked.cooldown)
    end)
  end)

  ------------------------------------------------------------------------------
  describe("H.secretValue — a sentinel, because H.secret is keyed BY VALUE", function()
    it("marks one object, not every occurrence of a number", function()
      local v = H.secretValue()
      assert.is_true(ns.IsSecret(v))
      assert.is_false(ns.IsSecret(1))
    end)

    it("is truthy in Lua, which is the whole reason §3.4 exists", function()
      -- A secret value passes `x and true or false`.  That is not a harness quirk; it is
      -- the trap State.lua:1363 falls into.
      local v = H.secretValue()
      assert.is_true(v and true or false)
    end)
  end)
end)
