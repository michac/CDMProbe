-- viewers_spec.lua — the item -> identity resolvers in Viewers.lua.
--
-- WHY THIS FILE EXISTS: a TOTAL HUD OUTAGE that every other gate missed (2026-07-30).
--
-- `ns.ItemCooldownID` lived in HudCore.lua, which was deleted at the W4 cutover (d824557).
-- Its two call sites — `HudLayout.Scan` and `ns.ItemBaseSpellID` — both invoked it through
-- an `ns.ItemCooldownID and ns.ItemCooldownID(item)` nil guard, so the missing definition
-- did not throw: it evaluated to nil for every icon. HudLayout.Build drops any entry whose
-- cooldownID is not a number, so the Layout came back EMPTY, the Binder dropped every cue,
-- and the HUD drew nothing at all on any spec while `/cdmp hud status` still said ON.
--
-- luacheck could not see it (the guard is valid Lua). busted could not see it either, and
-- that is the important part: `hudlayout_spec` STUBS `ns.ItemCooldownID` to drive Scan's
-- pure logic, so the suite was green against a function the addon no longer shipped. A
-- stub can only prove the caller works GIVEN the collaborator — never that the
-- collaborator EXISTS.
--
-- So this file deliberately loads the REAL Viewers.lua and stubs nothing but frame
-- DISCOVERY (`GetViewer`/`GetItemFrames`, which genuinely need a live client). The last
-- test is the one that matters: real resolvers, real HudLayout, non-empty Layout.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

describe("Viewers — item identity resolvers", function()
  local ns
  before_each(function()
    ns = H.fresh()
    H.load("Viewers.lua")
  end)

  describe("ns.ItemCooldownID", function()
    it("is SHIPPED by the addon, not supplied by a test", function()
      -- The regression guard proper.  If this function ever goes missing again — deleted
      -- with its module, renamed, moved behind a load-order change — this fails loudly
      -- instead of the HUD silently drawing nothing.
      assert.equals("function", type(ns.ItemCooldownID))
    end)

    it("reads the item's own cooldownID field", function()
      assert.equals(34991, ns.ItemCooldownID({ cooldownID = 34991 }))
    end)

    it("falls back to GetCooldownID() when the field is absent", function()
      local item = { GetCooldownID = function() return 671 end }
      assert.equals(671, ns.ItemCooldownID(item))
    end)

    it("prefers the field over the method when both are present", function()
      local item = { cooldownID = 11, GetCooldownID = function() return 22 end }
      assert.equals(11, ns.ItemCooldownID(item))
    end)

    it("REFUSES a secret field and falls through to the method", function()
      -- type(secret) == "number" is TRUE, so an unguarded read would return a Secret Value
      -- that then keys the Layout and the registry — tainting every table it touches.
      local secret = 999001
      H.markSecret(secret)
      local item = { cooldownID = secret, GetCooldownID = function() return 777 end }
      assert.equals(777, ns.ItemCooldownID(item))
    end)

    it("returns nil — never a poisoned number — when every read is secret", function()
      local a, b = 999002, 999003
      H.markSecret(a); H.markSecret(b)
      local item = { cooldownID = a, GetCooldownID = function() return b end }
      assert.is_nil(ns.ItemCooldownID(item))
    end)

    it("returns nil for an item that exposes neither", function()
      assert.is_nil(ns.ItemCooldownID({}))
      assert.is_nil(ns.ItemCooldownID(nil))
    end)

    it("survives a GetCooldownID that throws", function()
      local item = { GetCooldownID = function() error("restricted") end }
      assert.is_nil(ns.ItemCooldownID(item))
    end)
  end)

  describe("ns.ItemBaseSpellID", function()
    it("prefers GetBaseSpellID()", function()
      assert.equals(105174, ns.ItemBaseSpellID({ GetBaseSpellID = function() return 105174 end }))
    end)

    it("falls back to the cooldown info's UN-overridden spellID", function()
      -- The transform trap: item:GetSpellID() flips to the override while a Demonic Art is
      -- armed, so identity (keybinds, cue keys) must come off the base.
      _G.C_CooldownViewer = {
        GetCooldownViewerCooldownInfo = function(cid)
          if cid == 34991 then return { spellID = 105174 } end
        end,
      }
      assert.equals(105174, ns.ItemBaseSpellID({ cooldownID = 34991 }))
      _G.C_CooldownViewer = nil
    end)
  end)

  describe("ns.ItemDisplaySpellID (the display-identity resolver)", function()
    -- Loaded from the REAL Viewers.lua.  hudlayout_spec STUBS this function, so without a
    -- test here nothing would prove it ships -- the exact shape of the v0.32.25 outage,
    -- where a stubbed `ns.ItemCooldownID` kept busted green against a function the addon
    -- no longer had.  A stub proves the caller works GIVEN the collaborator, never that the
    -- collaborator EXISTS.
    local INCINERATE, SHADOW_BOLT = 29722, 686

    -- Incinerate is a DESTRUCTION ability, and the rule only adopts an override the ACTIVE
    -- spec declares -- so this must run with 267 active, not the harness's default 266.
    -- (That is itself the guarantee under test: on Demonology the same row keeps its base.)
    before_each(function()
      H.setSpecIndex(3)
      ns.ResolveActiveSpec()
    end)

    local function withInfo(info)
      _G.C_CooldownViewer = { GetCooldownViewerCooldownInfo = function(cid)
        if cid == 66181 then return info end
      end }
    end

    after_each(function() _G.C_CooldownViewer = nil end)

    it("adopts a STATIC display override (the Diabolist Incinerate row)", function()
      withInfo({ spellID = SHADOW_BOLT, overrideSpellID = INCINERATE,
                 overrideTooltipSpellID = INCINERATE })
      assert.equals(INCINERATE, ns.ItemDisplaySpellID({ cooldownID = 66181 }))
    end)

    it("keeps the base when there is no override", function()
      withInfo({ spellID = SHADOW_BOLT })
      assert.equals(SHADOW_BOLT, ns.ItemDisplaySpellID({ cooldownID = 66181 }))
    end)

    it("IGNORES liveSpellID, so an armed Art never moves an icon's identity", function()
      -- The whole reason the rule reads the STATIC fields: keying on `liveSpellID` would
      -- re-key the icon to Infernal Bolt mid-combat and the Incinerate cue would vanish
      -- exactly when the ability is most active.
      withInfo({ spellID = SHADOW_BOLT, liveSpellID = 433891,
                 overrideSpellID = INCINERATE, overrideTooltipSpellID = INCINERATE })
      assert.equals(INCINERATE, ns.ItemDisplaySpellID({ cooldownID = 66181 }))
    end)
  end)

  ------------------------------------------------------------------------------
  -- THE OUTAGE TEST.  Real resolvers + real HudLayout; only frame DISCOVERY faked.
  ------------------------------------------------------------------------------
  describe("HudLayout.Scan with the REAL resolvers (no id stubs)", function()
    it("produces a non-empty, number-keyed Layout", function()
      H.load("HudLayout.lua")
      _G.C_CooldownViewer = {
        GetCooldownViewerCooldownInfo = function(cid)
          local byCid = { [34991] = 105174, [119910] = 48018 }
          if byCid[cid] then return { spellID = byCid[cid] } end
        end,
      }
      -- Items shaped like the live CDM's: a cooldownID field, no GetBaseSpellID, so both
      -- resolvers have to do real work.
      local essItem = { cooldownID = 34991 }
      local utItem  = { cooldownID = 119910 }
      local viewers = {
        EssentialCooldownViewer = { essItem },
        UtilityCooldownViewer   = { utItem },
      }
      ns.GetViewer     = function(name) return viewers[name] and { name = name } or nil end
      ns.GetItemFrames = function(v) return viewers[v.name] or {} end

      local layout, registry = ns.HudLayout.Scan()

      local n = 0
      for _ in pairs(layout) do n = n + 1 end
      assert.equals(2, n)   -- the outage produced 0 here
      assert.are.same({ spellID = 105174, side = "TOPRIGHT" }, layout[34991])
      assert.are.same({ spellID = 48018, side = "TOPRIGHT" }, layout[119910])
      assert.equals(essItem, registry[34991])
      assert.equals(utItem, registry[119910])
      _G.C_CooldownViewer = nil
    end)
  end)
end)
