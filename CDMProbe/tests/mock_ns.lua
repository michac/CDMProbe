-- mock_ns.lua — the busted harness for CDMProbe's pure-logic modules (M4.5 T2).
--
-- THE HARNESS IS THE LIFT, not the specs (m4.5-plan.md).  The target modules are
-- frame-*light*, not frame-*free*, and HudScore is pure of frames but NOT pure of
-- the `ns` surface.  This file provides the three things needed to load and drive
-- them off-game (see the plan's T2 breakdown):
--
--   1. A minimal `CreateFrame` stub — a table whose methods (Create*, SetPoint,
--      SetText, Show/Hide, Register*Event, animation builders, …) are chainable
--      no-ops.  HudQueue's buildFrame/render and HudNapkin's module-level
--      `ev = CreateFrame(...)` both need it.  Methods are pre-populated (NOT a
--      catch-all __index) so an UNSET field like `frame.pop` reads nil — a
--      catch-all that returned a function for every key would spring HudQueue's
--      `if not pop then …create… end` guard and then index a function value.
--   2. Global fakes: a SETTABLE `GetTime` fake clock (the napkin and LATE both
--      advance time), `wipe`, `InCombatLockdown`, `C_Timer`, `CreateColor`, `Enum`,
--      `issecretvalue` (drives `ns.IsSecret`), `UnitPower`/`UnitPowerMax`, a
--      `C_Spell.GetSpellName`.
--   3. The REAL data, loaded as-is: `Util.lua` + `SpecDemonology.lua` through the
--      `local ADDON, ns = ...` vararg shim, so `ns.SpecInfo`/`SpecColor`/`IsSecret`/
--      `SpellName`/`SHARD_CAP`/… are the SHIPPING implementations.  Then a
--      fixture-settable STATE surface for HudScore: fake `ns.HudState`
--      (override / Mode / ProjectedShards / shards / SourcePresent / aoe),
--      `ns.ShardCost`, `ns.BaseCooldown`, `ns.HudChrome.GetReady`, and a fake
--      `ns.HudNapkin` (Remaining / SourceOf / SOON_LEAD).  A spec that tests the
--      REAL napkin (hudnapkin_spec) simply loads HudNapkin.lua, which overwrites
--      the fake in place.
--
-- Usage from a spec:
--     local H = dofile((...):gsub("spec/[^/]*$", "") .. "mock_ns.lua")  -- or the
--     -- source-relative dofile the specs use; then:
--     local ns, fx = H.fresh()          -- fresh namespace + fixture handle
--     H.load("HudScore.lua")            -- load the module under test into `ns`

local H = {}

-- Where this file lives, so loadfile can reach ../CDMProbe/*.lua regardless of the
-- cwd busted is invoked from (repo root, per the CLAUDE.md invocation).
local HERE = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local MODULES = HERE .. "../"   -- CDMProbe/tests/ -> CDMProbe/

--------------------------------------------------------------------------------
-- Fake clock + secret registry + combat flag (settable by specs)
--------------------------------------------------------------------------------
H.clock  = 0
H.combat = false
H.secret = {}          -- value -> true means issecretvalue() reports it secret
H.frames = {}          -- every CreateFrame result, in order (napkin grabs its ev)

function H.setClock(t) H.clock = t end
function H.advance(dt) H.clock = H.clock + dt end
function H.setCombat(v) H.combat = v and true or false end
function H.markSecret(v) H.secret[v] = true end
function H.lastFrame() return H.frames[#H.frames] end

--------------------------------------------------------------------------------
-- The frame / fontstring / animation stub
--------------------------------------------------------------------------------
-- One shape covers all three (a fontstring is never asked to CreateFrame, a frame
-- is never Play()ed — over-providing methods is harmless; MISSING one surfaces as
-- a clear "attempt to call nil", which is the honest failure we want).
local function newStub()
  local t = { _scripts = {}, _level = 1 }
  local function chain(self) return self end
  for _, m in ipairs({
    "SetPoint", "ClearAllPoints", "SetAllPoints", "Show", "Hide",
    "SetSize", "SetWidth", "SetHeight", "SetScale",
    "SetJustifyH", "SetJustifyV", "SetTextColor", "SetVertexColor",
    "SetAlpha", "SetColorTexture", "SetTexture", "SetMask", "SetDrawLayer",
    "SetFrameStrata", "EnableMouse", "SetShown", "SetParent", "SetAtlas",
    "RegisterEvent", "RegisterUnitEvent", "UnregisterEvent", "UnregisterAllEvents",
    "SetLooping", "Play", "Stop", "Pause", "Finish",
    "SetDuration", "SetSmoothing", "SetOffset", "SetFromAlpha", "SetToAlpha",
    "SetOrder", "SetStartDelay", "SetChildKey", "SetTarget", "SetTargetKey",
  }) do t[m] = chain end
  function t:SetFrameLevel(n) self._level = n or self._level; return self end
  function t:GetFrameLevel() return self._level or 1 end
  function t:SetFont(...) return true end                 -- ns.SetFont branches on this
  function t:GetFont() return "font", 12, "" end
  function t:SetText(s) self._text = s; return self end
  function t:GetText() return self._text end
  function t:GetAlpha() return self._alpha or 1 end
  function t:IsShown() return self._shown and true or false end
  function t:SetScript(ev, fn) self._scripts[ev] = fn; return self end
  function t:HookScript(ev, fn) self._scripts[ev] = fn; return self end
  function t:GetScript(ev) return self._scripts[ev] end
  -- Test-only: invoke a stored handler as WoW would (self, ...).
  function t:Fire(ev, ...) local f = self._scripts[ev]; if f then return f(self, ...) end end
  function t:CreateFontString(...) return newStub() end
  function t:CreateTexture(...) return newStub() end
  function t:CreateMaskTexture(...) return newStub() end
  function t:CreateAnimationGroup(...) return newStub() end
  function t:CreateAnimation(...) return newStub() end
  return t
end
H.newStub = newStub

--------------------------------------------------------------------------------
-- Global fakes (installed once; re-installing on a re-dofile is harmless)
--------------------------------------------------------------------------------
_G.GetTime          = function() return H.clock end
_G.wipe             = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.InCombatLockdown = function() return H.combat end
_G.issecretvalue    = function(v) return H.secret[v] == true end
_G.issecrettable    = function(_) return false end
_G.hooksecurefunc   = function() end
_G.UnitPower        = function() return 0 end
_G.UnitPowerMax     = function() return 0 end
_G.CreateColor      = function(r, g, b, a)
  return { r = r, g = g, b = b, a = a, GetRGB = function() return r, g, b end }
end
_G.Enum   = { PowerType = { SoulShards = 7, Mana = 0, Energy = 3 } }
_G.C_Timer = { After = function() end,
               NewTimer = function() return { Cancel = function() end } end }
_G.C_Spell = { GetSpellName = function(id) return "Spell:" .. tostring(id) end }
_G.CreateFrame = function(_, name, _, _)
  local f = newStub()
  H.frames[#H.frames + 1] = f
  if type(name) == "string" then _G[name] = f end
  return f
end

--------------------------------------------------------------------------------
-- Load a module file into the current namespace through the vararg shim.
--------------------------------------------------------------------------------
function H.load(file)
  local chunk, err = loadfile(MODULES .. file)
  if not chunk then error("mock_ns: cannot load " .. file .. ": " .. tostring(err)) end
  return chunk("CDMProbe", H.ns)
end

--------------------------------------------------------------------------------
-- A fresh namespace: the REAL data + a fixture-settable STATE surface.
--------------------------------------------------------------------------------
function H.fresh()
  H.frames = {}
  H.clock, H.combat, H.secret = 0, false, {}
  local ns = {}
  H.ns = ns

  -- Real, shipping implementations (data + lookups + Secret-Values-aware helpers).
  H.load("Util.lua")
  H.load("SpecDemonology.lua")

  -- The fixture handle every spec pokes.  Tables are keyed by spellID.
  local fx = {
    mode = nil, shards = nil, projected = false, aoe = false,
    cost = {}, baseCD = {}, remain = {}, remainSource = {},
    present = {}, override = {},
  }
  H.fx = fx

  -- Override the two RUNTIME readers (the real ones ask C_Spell on a live client);
  -- everything else in Util stays the shipping code.
  ns.ShardCost    = function(id) local c = fx.cost[id]; if c == nil then return nil end return c, c end
  ns.BaseCooldown = function(id) return fx.baseCD[id] end

  ns.HudChrome = { GetReady = function(item) return item and item.ready end }

  -- A fake napkin for HudScore's sake; hudnapkin_spec replaces this by loading the
  -- real module, so the two never fight.
  ns.HudNapkin = {
    SOON_LEAD = 3.0,
    Remaining = function(id) return fx.remain[id] end,
    SourceOf  = function(id) return fx.remainSource[id] end,
  }

  -- The STATE surface HudScore.For reads (see its header): override / Mode /
  -- ProjectedShards / SourcePresent / aoe.  `override` IS fx.override, so a spec
  -- can arm a transform by writing fx.override[base] = overrideID.
  ns.HudState = {
    override        = fx.override,
    aoe             = false,
    shards          = nil,
    Mode            = function() return fx.mode end,
    ProjectedShards = function() return fx.shards, fx.projected end,
    SourcePresent   = function(id) return fx.present[id] and true or false end,
  }

  return ns, fx
end

return H
