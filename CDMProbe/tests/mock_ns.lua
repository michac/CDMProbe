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

-- SECRET TABLES — a DISTINCT verdict from a secret scalar, and the one the addon's
-- readers ask about separately (Util.lua:76 ns.IsSecretTable).  `issecrettable` used to be
-- hardcoded `false` here, which made six real refusal branches unreachable in tests:
-- State.lua:104 (the info struct), :429 (a packed auraData), Util.lua:158 / :179 / :199
-- (the cooldown + charges tables).  Keyed by table IDENTITY, so a fake that builds a fresh
-- table per call cannot be marked — memoise one table per fixture (see H.poison's note).
H.secretTable = {}     -- table -> true means issecrettable() reports it secret

-- "THIS CALL THROWS" — keyed by the DOTTED API name (`"C_Spell.GetSpellCooldown"`), so a
-- fixture can arm any single guarded call site without replacing the fake.  ~14 pcall'd
-- sites are reachable from St.Build and none of them had throw coverage before.
H.throws = {}          -- "dotted.name" -> true means the wrapped call errors

-- WHICH IDS THE CLIENT FAKES WERE ASKED ABOUT.  Several CDM defects are "which id did you
-- ask about" bugs (the charge ladder, the per-entry GCD read), and asserting the OUTCOME
-- cannot catch those — only the question can.  Reset by H.fresh().
H.asked = {}

-- Spec detection (Phase 5).  GetSpecialization returns an INDEX; GetSpecializationInfo
-- maps that index -> (specID, name).  Default: index 1 = Demonology (266), so the resolver
-- lands on the shipping spec exactly as the old static activation did.  Tests flip
-- H.specIndex (nil = no spec chosen) to exercise the passive / swap paths.
H.specIndex = 1
-- Index 3 (Destruction, 267) IS registered now — coach_destruction_apl_spec drives it by
-- calling H.setSpecIndex(3) then ns.ResolveActiveSpec() after H.fresh().  Index 2
-- (Affliction) stays the unregistered/passive fixture spec_detect_spec relies on.
-- ⚠ DO NOT RENUMBER 1-3.  Index 2 is Affliction 265, deliberately UNREGISTERED as
-- spec_detect_spec's passive/unsupported fixture; indices 1 and 3 are load-bearing in
-- coach_apl_spec and coach_destruction_apl_spec.  New specs APPEND.
H.specByIndex = {
  [1] = { 266, "Demonology" },
  [2] = { 265, "Affliction" },   -- registered? NO — the unsupported/passive fixture
  [3] = { 267, "Destruction" },
  [4] = { 70,  "Retribution" },
  [5] = { 577, "Havoc" },        -- coach_havoc_apl_spec drives it with H.setSpecIndex(5)
}
function H.setSpecIndex(i) H.specIndex = i end

function H.setClock(t) H.clock = t end
function H.advance(dt) H.clock = H.clock + dt end
function H.setCombat(v) H.combat = v and true or false end
function H.markSecret(v) H.secret[v] = true end
function H.lastFrame() return H.frames[#H.frames] end

-- ⚠ H.secret is keyed BY VALUE, so `H.markSecret(1)` marks the number 1 everywhere in the
-- fixture.  Prefer a sentinel TABLE (`H.secretValue()`) wherever the code under test only
-- tests readability rather than doing arithmetic — `readable()` is a `type(v) == "number"`
-- test, so a table is refused for the same reason a secret number is, one branch earlier.
function H.markSecretTable(t) H.secretTable[t] = true; return t end
function H.secretValue() local v = {}; H.secret[v] = true; return v end

-- Arm / disarm a guarded call site by its dotted name.
function H.throwOn(name) H.throws[name] = true end

-- Wrap a fake so `H.throws[name]` makes it raise.  The addon pcalls these sites; a fixture
-- that cannot make them throw leaves every refusal path untested.  Level 0 so the message
-- is the message, not a mock_ns.lua line reference.
function H.guard(name, fn)
  return function(...)
    if H.throws[name] then error("mock_ns: " .. name .. " throws (H.throws)", 0) end
    return fn(...)
  end
end

-- A table that INDEXES FINE for most keys and THROWS on named ones.  Distinct from a
-- secret table, and it is the shape `Util.lua:163` and `State.lua:519` pcall against:
-- they guard the *index*, not the call, on the documented reasoning that "a table that
-- passes issecrettable can still throw on access under the 12.0 restrictions".
--
-- Mutates `t` in place and returns it, so table IDENTITY is preserved (H.secretTable and
-- a memoised per-cid info table both key on identity).  Note Lua 5.1 has no `__pairs`, so
-- a poisoned table does not iterate — nothing in the code under test iterates these.
function H.poison(t, fields)
  local store = {}
  for k, v in pairs(t) do store[k] = v; t[k] = nil end
  local bad = {}
  for _, f in ipairs(fields or {}) do bad[f] = true end
  return setmetatable(t, {
    __index = function(_, k)
      if bad[k] then error("mock_ns: poisoned field '" .. tostring(k) .. "'", 0) end
      return store[k]
    end,
    __newindex = function(_, k, v) store[k] = v end,
  })
end

--------------------------------------------------------------------------------
-- The frame / fontstring / animation stub
--------------------------------------------------------------------------------
-- One shape covers all three (a fontstring is never asked to CreateFrame, a frame
-- is never Play()ed — over-providing methods is harmless; MISSING one surfaces as
-- a clear "attempt to call nil", which is the honest failure we want).
--------------------------------------------------------------------------------
-- SECRET ASPECTS — the 12.0 readback channel, modelled rather than stubbed.
--------------------------------------------------------------------------------
-- ⚠ THIS IS THE `issecrettable`-HARDCODED-`false` SHAPE, and it is why it is modelled at
-- all.  A collaborator that always answers the same thing makes real branches unreachable
-- while every suite stays green — that bug sat in this file for the whole life of the addon.
-- So: a setter carrying `SecretArgumentsAddAspect` marks the object **only when the value it
-- actually received is secret**, exactly as the client does.  Without that conditional,
-- CurveLab's two central verdicts — `WORKED` (an aspect flipped) and `INERT` (a secret was
-- accepted and NOTHING flipped) — are inexpressible, and the instrument could not be tested
-- at all.  `harness_spec.lua` covers this.
--
-- Keyed by the enum VALUE, because `HasSecretAspect(aspect)` is called with the value.  The
-- names here are the ones the generated docs declare per setter, transcribed by hand.
local function anySecret(...)
  for i = 1, select("#", ...) do
    if H.secret[(select(i, ...))] == true then return true end
  end
  return false
end

local function addAspects(self, ...)
  self._aspects = self._aspects or {}
  local E = _G.Enum and _G.Enum.SecretAspect
  for i = 1, select("#", ...) do
    local v = E and E[(select(i, ...))]
    if v ~= nil then self._aspects[v] = true end
  end
end

-- WHOLE-OBJECT SECRECY + ANCHOR CONTAGION — the (b) outcome of the three in
-- security-taint-and-restricted-data.md §4.6.  A secret-accepting setter with NO declared
-- aspect marks the object as having secret values, which marks its anchoring data secret and
-- propagates DOWN the anchor chain to dependents (never up).  `_dependents` is populated by
-- SetPoint below, so the propagation modelled here is the anchor chain and nothing else —
-- which is precisely the Tier-2 rule CurveLab's canary exists to falsify.
local function markSecretValues(self)
  self._hasSecretValues = true
  self._anchoringSecret = true
  for _, dep in ipairs(self._dependents or {}) do
    dep._hasSecretValues = true
    dep._anchoringSecret = true
  end
end

local function newStub()
  local t = { _scripts = {}, _events = {}, _level = 1 }
  local function chain(self) return self end
  for _, m in ipairs({
    "SetAllPoints", "SetScale",
    "SetJustifyH", "SetJustifyV", "SetBlendMode",
    "SetMask", "SetDrawLayer", "SetTexCoord",
    -- Mask OBJECTS (the RingedFrameTemplate idiom the cue dot uses), not the SetMask path.
    "AddMaskTexture", "RemoveMaskTexture",
    "SetFrameStrata",
    -- The moveable-panel surface (HudVirtual Phase 2).  `EnableMouse` is RECORDING (below):
    -- "does the panel eat clicks right now" is the lock state's user-visible half.
    "SetMovable", "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetClampedToScreen",
    "SetLooping", "Pause", "Finish",
    "SetSmoothing", "SetOffset", "SetFromAlpha", "SetToAlpha",
    "SetOrder", "SetStartDelay", "SetChildKey", "SetTarget", "SetTargetKey",
    "SetFlipBookRows", "SetFlipBookColumns", "SetFlipBookFrames",
    "SetFlipBookFrameWidth", "SetFlipBookFrameHeight",
    "SetRadians", "SetOrigin",
    -- The Scale animation's setter under BOTH spellings (the Renderer probes for the
    -- newer one and falls back).  Missing here, the fallback would `attempt to call nil`.
    "SetScaleFrom", "SetScaleTo", "SetFromScale", "SetToScale",
  }) do t[m] = chain end
  -- RECORDING methods (W4 Phase 3 — the Renderer harness).  The Renderer draws no
  -- real pixels off-game, so busted asserts on what the stub was TOLD: colour,
  -- points, size, shown-state.  These replace the silent chain no-ops so a spec can
  -- read `dot._color` / `dot._points` / `dot._shown` after a Draw (mock_ns header).
  -- ⚠ `SetColorTexture` IS ONE OF THE FIVE ASPECT-LESS SETTERS
  -- [SimpleTextureBaseAPIDocumentation.lua:313] — it accepts a secret and declares NO
  -- aspect, so it marks the whole object instead.  Modelling it as aspect-ADDING (the easy
  -- copy-paste from SetVertexColor) would make the contagion column unfalsifiable.
  function t:SetColorTexture(r, g, b, a)
    self._color = { r, g, b, a }
    if anySecret(r, g, b, a) then markSecretValues(self) end
    return self
  end
  function t:SetVertexColor(r, g, b, a)
    self._color = { r, g, b, a }
    if anySecret(r, g, b, a) then addAspects(self, "VertexColor", "Alpha") end
    return self
  end
  function t:GetVertexColor()
    local c = self._color
    if not c then return nil end
    return c[1], c[2], c[3], c[4]
  end
  function t:SetVertexColorFromBoolean(v, ifTrue, ifFalse)
    if anySecret(v) then
      addAspects(self, "VertexColor", "Alpha")
    else
      -- ⚠ UNPACKED, not stored whole: the *FromBoolean setters take ColorMixin TABLES while
      -- `_color` is the array `GetVertexColor` unpacks.  Storing the table put a nil in
      -- slot 1, so GetVertexColor's class silently went `num` -> `nil` on a call that
      -- succeeded — a harness artefact indistinguishable from a real readback change.
      local c = v and ifTrue or ifFalse
      if type(c) == "table" then self._color = { c.r, c.g, c.b, c.a } end
    end
    return self
  end
  function t:SetTextColor(r, g, b, a)
    self._textColor = { r, g, b, a }
    if anySecret(r, g, b, a) then addAspects(self, "VertexColor", "Alpha") end
    return self
  end
  -- The other four aspect-less setters.  ⚠ `SetTexture` / `SetAtlas` were chainable no-ops
  -- until CurveLab; a no-op cannot express "took a secret and poisoned the anchor chain".
  function t:SetTexture(a) self._texture = a; if anySecret(a) then markSecretValues(self) end; return self end
  function t:SetAtlas(a)   self._atlas   = a; if anySecret(a) then markSecretValues(self) end; return self end
  function t:SetStartColor(c) self._startColor = c; if anySecret(c) then markSecretValues(self) end; return self end
  function t:SetEndColor(c)   self._endColor   = c; if anySecret(c) then markSecretValues(self) end; return self end
  function t:SetPoint(point, rel, relPoint, dx, dy)
    self._points = self._points or {}
    self._points[#self._points + 1] =
      { point = point, rel = rel, relPoint = relPoint, dx = dx, dy = dy }
    -- THE ANCHOR CHAIN, recorded on the ANCHOR rather than the anchoree, because contagion
    -- travels down it (§4.6(b)) and that direction is the whole property under test.
    if type(rel) == "table" and rel ~= self then
      rel._dependents = rel._dependents or {}
      rel._dependents[#rel._dependents + 1] = self
      if rel._hasSecretValues then self._hasSecretValues, self._anchoringSecret = true, true end
    end
    return self
  end
  function t:ClearAllPoints() self._points = {}; return self end
  -- The LAST SetPoint, in the API's return order — `(point, relativeTo, relPoint, x, y)`.
  -- This is what makes HudVirtual's save/restore round-trip testable off-game.
  function t:GetPoint()
    local p = self._points and self._points[#self._points]
    if not p then return nil end
    return p.point, p.rel, p.relPoint, p.dx, p.dy
  end
  function t:EnableMouse(v) self._mouse = v and true or false; return self end
  function t:IsMouseEnabled() return self._mouse and true or false end
  -- RECORDING, not a chain no-op: HudVirtual's resting-dim vs cued-lit distinction IS an
  -- alpha, so a spec has to be able to read back what it was set to (GetAlpha below).
  -- ⚠⚠ THE CRITICAL ONE.  `SetAlpha` declares `SecretArgumentsAddAspect = {Alpha}`
  -- [SimpleRegionAPIDocumentation.lua:125] and is `AllowedWhenTainted`, so it is the one
  -- setter CurveLab can reach with a secret AND read back — the aspect flip is what
  -- separates `WORKED` from `INERT`.  It must add the aspect ONLY when the value received is
  -- secret; an unconditional flip would make every cell read WORKED and INERT unreachable.
  function t:SetAlpha(a)
    self._alpha = a
    if anySecret(a) then addAspects(self, "Alpha") end
    return self
  end
  function t:SetAlphaFromBoolean(v, ifTrue, ifFalse)
    if anySecret(v) then addAspects(self, "Alpha")
    else self._alpha = v and ifTrue or ifFalse end
    return self
  end
  -- ⚠ `GetEffectiveAlpha` is `RequiresScriptObjectAlphaAccess`
  -- [SimpleFrameAPIDocumentation.lua:336] — it REFUSES once the Alpha aspect is set, and
  -- that THROW is a POSITIVE result for CurveLab (the refusal IS the proof).  Modelled, not
  -- stubbed, because a getter that always answers makes the positive branch unreachable.
  function t:GetEffectiveAlpha()
    if self._aspects and _G.Enum and _G.Enum.SecretAspect
      and self._aspects[_G.Enum.SecretAspect.Alpha] then
      error("mock_ns: GetEffectiveAlpha refused — object has the Alpha aspect", 0)
    end
    return self._alpha or 1
  end
  -- The same shape for the Desaturation channel, which has NO non-throwing readback at all
  -- (`IsDesaturated` is `RequiresScriptObjectDesaturationAccess`,
  -- SimpleTextureBaseAPIDocumentation.lua:242).
  function t:SetDesaturation(v)
    self._desaturation = v
    if anySecret(v) then addAspects(self, "Desaturation") end
    return self
  end
  function t:SetDesaturated(v)
    self._desaturated = v
    if anySecret(v) then addAspects(self, "Desaturation") end
    return self
  end
  function t:IsDesaturated()
    if self._aspects and _G.Enum and _G.Enum.SecretAspect
      and self._aspects[_G.Enum.SecretAspect.Desaturation] then
      error("mock_ns: IsDesaturated refused — object has the Desaturation aspect", 0)
    end
    return self._desaturated and true or false
  end
  function t:SetRotation(r)
    self._rotation = r
    if anySecret(r) then addAspects(self, "Rotation") end
    return self
  end
  function t:GetRotation() return self._rotation or 0 end
  -- StatusBar.  `SetValue` / `SetMinMaxValues` both add `{BarValue}`
  -- [SimpleStatusBarAPIDocumentation.lua:218, 333]; `SetStatusBarColor` adds
  -- `{VertexColor, Alpha}` [:261].
  function t:SetValue(v)
    self._barValue = v
    if anySecret(v) then addAspects(self, "BarValue") end
    return self
  end
  function t:GetValue() return self._barValue end
  function t:SetMinMaxValues(lo, hi)
    self._barMin, self._barMax = lo, hi
    if anySecret(lo, hi) then addAspects(self, "BarValue") end
    return self
  end
  function t:GetMinMaxValues() return self._barMin, self._barMax end
  function t:SetStatusBarColor(r, g, b, a)
    self._color = { r, g, b, a }
    if anySecret(r, g, b, a) then addAspects(self, "VertexColor", "Alpha") end
    return self
  end
  -- ⚠ `GetStatusBarColor` [SimpleStatusBarAPIDocumentation.lua:92], NOT `GetVertexColor`:
  -- a StatusBar is a Frame, not a Region, so the Region getter is genuinely absent on it.
  -- The first live capture recorded `read=threw>threw` on every barColor cell because
  -- CurveLab asked the wrong one, and the stub answering BOTH would have hidden that.
  function t:GetStatusBarColor()
    local c = self._color
    if not c then return nil end
    return c[1], c[2], c[3], c[4]
  end
  function t:SetStatusBarTexture(a) self._barTexture = a; return self end
  function t:GetStatusBarTexture() return self._barTexture end
  -- THE DURATION SINKS.  These take an OBJECT, never a secret argument, so they add NO
  -- aspect and mark nothing — the readback is the object's own `HasSecretValues`.
  function t:SetTimerDuration(dur) self._timerDuration = dur; return self end
  function t:GetTimerDuration() return self._timerDuration end
  function t:SetCooldownFromDurationObject(dur) self._durationObject = dur; return self end
  -- ⚠ THE NEGATIVE CONTROL.  `Cooldown:SetCooldown` is `AllowedWhenUntainted`
  -- [FrameAPICooldownDocumentation.lua:280], so a tainted caller passing a secret is
  -- REFUSED — the sharpest pairing in the corpus (same widget, same fact, forbidden route).
  -- It must throw here or CurveLab's most important negative control cannot be tested.
  function t:SetCooldown(start, dur)
    if anySecret(start, dur) then
      error("mock_ns: SetCooldown refused a secret (AllowedWhenUntainted)", 0)
    end
    self._cooldown = { start, dur }
    return self
  end
  -- THE ASPECT READBACK ITSELF (SimpleFrameScriptObjectAPIDocumentation.lua:52, 38) and the
  -- whole-object / anchor queries (:69, SimpleScriptRegionAPIDocumentation.lua:367).
  function t:HasSecretAspect(a) return (self._aspects and self._aspects[a]) == true end
  function t:HasAnySecretAspect()
    return self._aspects ~= nil and next(self._aspects) ~= nil
  end
  function t:HasSecretValues()   return self._hasSecretValues == true end
  function t:IsAnchoringSecret() return self._anchoringSecret == true end
  function t:Show()        self._shown = true;  return self end
  function t:Hide()        self._shown = false; return self end
  function t:SetShown(v)   self._shown = v and true or false; return self end
  function t:SetSize(w, h) self._size = { w, h }; return self end
  function t:SetWidth(w)   self._size = self._size or {}; self._size[1] = w; return self end
  function t:SetHeight(h)  self._size = self._size or {}; self._size[2] = h; return self end
  function t:SetFrameLevel(n) self._level = n or self._level; return self end
  function t:GetFrameLevel() return self._level or 1 end
  -- ANIMATION STATE IS RECORDED, not chained away.  The Renderer's cue treatment is
  -- MOTION — a spin period per emphasis, an echo counter-rotating at a ratio of it, a
  -- one-shot pop — and a chainable no-op cannot tell "the echo turns the other way at
  -- 10s" from "the echo was never timed at all".  `_plays` counts rather than latches,
  -- because "exactly ONE pop per arriving cue" is a load-bearing claim.
  function t:SetDuration(s) self._duration = s; return self end
  function t:SetDegrees(d)  self._degrees = d;  return self end
  function t:Play() self._playing = true; self._plays = (self._plays or 0) + 1; return self end
  -- ⚠ `Stop()` FIRES OnFinished, as the client does (with requested = true).  Modelled
  -- rather than no-op'd because it makes an ordering bug EXPRESSIBLE: the Renderer's
  -- ghost sets its "a ghost is playing" flag, and stopping a previous ghost clears that
  -- flag through this very path — so set-before-stop and set-after-stop are different
  -- programs, and only a harness that fires can tell them apart.
  function t:Stop()
    local was = self._playing
    self._playing = false
    if was and self._scripts.OnFinished then self._scripts.OnFinished(self, true) end
    return self
  end
  function t:IsPlaying() return self._playing and true or false end
  -- WHO OWNS THIS REGION.  The one honest way to assert that the keybind hint does NOT
  -- ride the popped cue layer: it is a question about parentage, not about pixels.
  function t:SetParent(p) self._parent = p; return self end
  function t:GetParent() return self._parent end
  function t:SetFont(...) return true end                 -- ns.SetFont branches on this
  function t:GetFont() return "font", 12, "" end
  -- `SetText` / `SetFormattedText` both add `{Text}` and are `AllowedWhenTainted`
  -- [SimpleFontStringAPIDocumentation.lua:653, 528] — the route a SECRET STRING (an aura's
  -- `GetAuraApplicationDisplayCount`) has to take, since stacks come back as text.
  function t:SetText(s)
    self._text = s
    if anySecret(s) then addAspects(self, "Text") end
    return self
  end
  function t:SetFormattedText(s)
    self._text = s
    if anySecret(s) then addAspects(self, "Text") end
    return self
  end
  function t:GetText() return self._text end
  function t:GetAlpha() return self._alpha or 1 end
  function t:GetWidth()  return (self._size and self._size[1]) or 48 end
  function t:GetHeight() return (self._size and self._size[2]) or 48 end
  function t:IsShown() return self._shown and true or false end
  function t:SetScript(ev, fn) self._scripts[ev] = fn; return self end
  function t:HookScript(ev, fn) self._scripts[ev] = fn; return self end
  function t:GetScript(ev) return self._scripts[ev] end

  -- EVENT REGISTRATION IS MODELLED, not a no-op.  ⚠ This was a chainable no-op until
  -- 2026-07-31, and that made an entire class of bug untestable: `Fire` dispatched to any
  -- frame with an OnEvent script whether or not it had ever registered the event, so
  -- "State never listens for TRAIT_CONFIG_UPDATED" looked identical to "State handles it".
  -- The live bug that hid there — build caches invalidated only from an Acquire-gated
  -- frame, so a hero-tree swap with the HUD off was never seen — passed its own new test
  -- until this was fixed.  A harness that cannot express the failure cannot gate it.
  function t:RegisterEvent(ev) self._events[ev] = true; return self end
  function t:RegisterUnitEvent(ev) self._events[ev] = true; return self end
  function t:UnregisterEvent(ev) self._events[ev] = nil; return self end
  function t:UnregisterAllEvents() self._events = {}; return self end
  function t:IsEventRegistered(ev) return self._events[ev] == true end
  -- Test-only: invoke a stored handler as WoW would (self, ...) — but ONLY for an event
  -- this frame actually registered, which is what the client does.  A non-OnEvent script
  -- (OnUpdate, OnDragStart, …) has no registration and always fires.
  function t:Fire(ev, ...)
    local f = self._scripts[ev]
    if not f then return end
    if ev == "OnEvent" then
      local event = ...
      if not self._events[event] then return end
    end
    return f(self, ...)
  end
  -- Every child records its CREATOR as `_parent` (see SetParent above).
  local function child(self) local c = newStub(); c._parent = self; return c end
  t.CreateFontString     = child
  t.CreateTexture        = child
  t.CreateMaskTexture    = child
  t.CreateAnimationGroup = child
  t.CreateAnimation      = child
  return t
end
H.newStub = newStub

--------------------------------------------------------------------------------
-- Global fakes
--------------------------------------------------------------------------------
-- ⚠ THESE USED TO BE INSTALLED AT FILE SCOPE, once per `dofile`.  Busted loads EVERY spec
-- file and only THEN runs the tests, so a `_G` mutation made during a test survived into
-- later files — `state_domainview_spec.lua` nils `_G.C_Spell.GetSpellCharges` in an
-- after_each, and that deletion outlived the file.  Worse, the closures below capture the
-- `H` of whichever dofile ran last, so `H.fx`-reading fakes could be looking at a
-- different file's fixture handle entirely.  Extracted into a function and called from
-- H.fresh() as well: every test starts from the same globals, bound to ITS OWN H.
function H.installGlobals()
  _G.GetTime          = function() return H.clock end
  _G.wipe             = function(t) for k in pairs(t) do t[k] = nil end return t end
  _G.InCombatLockdown = function() return H.combat end
  _G.issecretvalue    = function(v) return H.secret[v] == true end
  -- Table-driven, exactly like issecretvalue.  ⚠ `ns.IsSecret`/`ns.IsSecretTable` are the
  -- SHIPPING implementations (Util.lua:62-80) — the harness supplies only the two globals
  -- they ask, so every refusal path below runs the real code.
  _G.issecrettable    = function(t) return H.secretTable[t] == true end
  _G.hooksecurefunc   = function() end
  -- `date` — a FIXED stamp, because the harness clock is fixed.  DecisionLog.Record calls it
  -- once per session header; a real date() would make a session header non-deterministic and
  -- there is nothing to learn from the wall clock in a unit test.
  _G.date             = function() return "2026-01-01 00:00:00" end
  -- POWER, both rails (Phase 6.2).  `UnitPower(unit, type, unmodified)` returns the game's
  -- INTERNAL units when the flag is set — Soul Shards are stored as 0-50 fragments and
  -- displayed as 0-5 whole shards — and State reads BOTH.  Driven off `fx.power[type]`:
  --   { value = n, max = n, unmodified = n, unmodifiedMax = n }
  -- Omitting a field makes THAT read refuse (returns nil), which is how the "absent, never
  -- zero" contract is exercised.  Default: no entry => max 0 => the power is not reported
  -- at all, exactly as before this fake grew a body.
  local function powerFake(field, exactField)
    return function(_, powerType, unmodified)
      local e = H.fx and H.fx.power and H.fx.power[powerType]
      if not e then return 0 end
      return e[unmodified and exactField or field]
    end
  end
  _G.UnitPower        = powerFake("value", "unmodified")
  _G.UnitPowerMax     = powerFake("max", "unmodifiedMax")
  _G.CreateColor      = function(r, g, b, a)
    return { r = r, g = g, b = b, a = a, GetRGB = function() return r, g, b end }
  end
  -- The alert-event enum values are Blizzard's, verbatim (Blizzard_APIDocumentationGenerated/
  -- CooldownViewerConstantsDocumentation.lua:43-55) — State branches on them by name, but the
  -- numbers are what a live TriggerAlertEvent carries, so the harness must not invent its own.
  -- ⚠ `HolyPower = 9` IS NOT DECORATION.  Its absence is why the 76-case Retribution oracle
  -- could not see the defect that shipped: `ns.Coach.CostPowerType` resolves the spec's cost
  -- resource through `Enum.PowerType[power.name]`, so with no `HolyPower` member the whole
  -- cost path degrades to the fallback and the real reader is never exercised.  The values
  -- are the client's (LuaEnum.lua:5681), not invented — Fury = 17 is here for the DH specs
  -- on the roadmap, which declare it the same way.
  _G.Enum   = { PowerType = { SoulShards = 7, Mana = 0, Energy = 3, HolyPower = 9, Fury = 17 },
                CooldownViewerAlertEventType = {
                  Available = 1, PandemicTime = 2, OnCooldown = 3,
                  ChargeGained = 4, OnAuraApplied = 5, OnAuraRemoved = 6,
                },
                -- LuaCurveObjectConstantsDocumentation.lua:13-16, verbatim.
                LuaCurveType = { Linear = 0, Step = 1, Cosine = 2, Cubic = 3 },
                -- SecretAspectConstantsDocumentation.lua:13-41, verbatim — including the
                -- ⚠ SEVEN NAMES ALIASED TO 1, which are in the SHIPPED FILE and not a
                -- transcription slip.  Reproduced faithfully so a consumer that keys on a
                -- literal instead of a member breaks HERE rather than in game.
                SecretAspect = {
                  ObjectDebug = 1, ObjectName = 1, ObjectType = 1, ObjectSecrets = 1,
                  ObjectSecurity = 1, Attributes = 1, Hierarchy = 1,
                  ID = 2, Toplevel = 4, Text = 8, SecureText = 16, Shown = 32, Scale = 64,
                  Alpha = 128, FrameLevel = 256, ScrollRange = 512, Cursor = 1024,
                  VertexColor = 2048, Desaturation = 4096, TexCoords = 8192,
                  BarValue = 16384, Cooldown = 32768, Rotation = 65536,
                  MinimumWidth = 131072, Padding = 262144, CooldownStyle = 524288,
                  TooltipTexture = 1048576, ButtonState = 2097152, ScrollOffset = 4194304,
                } }
  -- ⚠ ALL THREE ARE INERT — they hand back a cancellable handle and NEVER FIRE.  A ticker
  -- that fired would make every module owning one (HudDriver at 10 Hz, Flight at 1 Hz)
  -- run its whole body inside an unrelated test, on that test's fixture.  Tests drive the
  -- sampled function DIRECTLY instead, which is also the only way to control WHEN.
  _G.C_Timer = { After = function() end,
                 NewTimer  = function() return { Cancel = function() end } end,
                 NewTicker = function() return { Cancel = function() end } end }
  _G.C_Spell = { GetSpellName = function(id) return "Spell:" .. tostring(id) end,
                 GetSpellTexture = function(id) return "Interface\\Icons\\Spell_" .. tostring(id) end,
                 -- The COST list, verbatim in the client's shape: an array of
                 -- { type = <Enum.PowerType>, cost = n, name = "…" }.  ns.PowerCost filters it
                 -- by type and ns.ShardCost passes the survivor through untouched; both are
                 -- SHIPPING code, so a spec that drives this fake tests the real ladder.
                 -- ⚠ The client PRE-APPLIES the display divisor (Chaos Bolt's DB2 cost of 20
                 -- fragments arrives as 2), so a fixture cost is in WHOLE SHARDS.
                 GetSpellPowerCost = function(id)
                   return (H.fx and H.fx.powerCost and H.fx.powerCost[id]) or {}
                 end }

  ------------------------------------------------------------------------------
  -- THE REAL CLIENT SURFACE (default-INERT).
  ------------------------------------------------------------------------------
  -- WHY, when state_domainview_spec already replaces `ns.ReadCooldown` wholesale: that
  -- replacement is a CALL RECORDER and should stay, but it must not be the only path.
  -- Replacing the function moves four things outside the code under test — the combat
  -- short-circuit (Util.lua:217), `rawCooldown`'s six-guard ladder (:154-167), the GCD
  -- TRAP (:225-239) and the banked-charge short-circuit (:222).  The GCD trap settles it
  -- on its own: `ns.ReadCooldown` calls `rawCooldown(GCD_SPELLID)` once PER ENTRY, and the
  -- planned hoist claims "pure win, no behaviour change" — unfalsifiable without a fake.
  -- With one, `H.asked.cooldown` counts the GCD reads and the entire fix is one number.
  --
  -- INERTNESS IS THE SAFETY PROPERTY.  An unregistered id returns `nil`, which every
  -- guard ladder above already treats identically to "the function does not exist", so
  -- installing these cannot move an existing result.  A fixture opts in per id via H.fx.
  --
  -- ⚠ THE RETURNED TABLES ARE THE FIXTURE'S OWN, handed back by identity rather than
  -- rebuilt per call — otherwise H.markSecretTable / H.poison could never mark them, and a
  -- secret-struct case would pass for the wrong reason.  It also matches Blizzard's single
  -- cached record per cooldownID (cooldown-manager.md §2.5).
  local function record(bucket, id) bucket[#bucket + 1] = id end

  _G.C_Spell.GetSpellCooldown = H.guard("C_Spell.GetSpellCooldown", function(spellID)
    record(H.asked.cooldown, spellID)
    return H.fx and H.fx.cd and H.fx.cd[spellID] or nil
  end)
  _G.C_Spell.GetSpellCharges = H.guard("C_Spell.GetSpellCharges", function(spellID)
    record(H.asked.charges, spellID)
    return H.fx and H.fx.charges and H.fx.charges[spellID] or nil
  end)

  -- The full active-buff walk State folds into `activeAuras` / `buffs`.  Entries are the
  -- PACKED aura tables the real API hands a `usePackedAura = true` callback; a secret one
  -- is just `H.markSecretTable(entry)`, which is the case State.lua:429 guards.
  _G.AuraUtil = { ForEachAura = H.guard("AuraUtil.ForEachAura", function(unit, filter, max, cb)
    local list = H.fx and H.fx.auras
    if type(list) ~= "table" or type(cb) ~= "function" then return end
    for _, aura in ipairs(list) do
      if cb(aura) then return end   -- a truthy return stops the walk, as the real API does
    end
  end) }

  -- ⚠ PER-ID throw control, not just the blanket H.throws entry: `readAura` walks the
  -- row's associated ids and gives up on the FIRST failure, so proving that defect needs
  -- id 1 to raise while id 2 answers cleanly.
  _G.C_UnitAuras = { GetPlayerAuraBySpellID =
    H.guard("C_UnitAuras.GetPlayerAuraBySpellID", function(spellID)
      record(H.asked.auraByID, spellID)
      if H.fx and H.fx.auraThrows and H.fx.auraThrows[spellID] then
        error("mock_ns: aura read refused for " .. tostring(spellID), 0)
      end
      return H.fx and H.fx.auraByID and H.fx.auraByID[spellID] or nil
    end) }

  -- THE CLASS-RESOURCE CHANNEL (2026-08-02) — the two APIs behind `spec.derived`.  Same
  -- default-INERT contract as everything above: an unregistered id returns nil, which the
  -- guard ladders already treat as "we could not ask".
  --
  -- ⚠ `GetSpellCastCount` is faked SEPARATELY from `GetSpellCharges` even though the two
  -- answer nearly the same question, because that is the whole point of the channel: an
  -- ability can carry a cast count WITHOUT having real charges (api-events-and-discovery.md
  -- §2), and a fixture that could not tell them apart could not test Vengeance's fragments.
  _G.C_Spell.GetSpellCastCount = H.guard("C_Spell.GetSpellCastCount", function(spellID)
    record(H.asked.castCount, spellID)
    return H.fx and H.fx.castCount and H.fx.castCount[spellID] or nil
  end)
  _G.C_Spell.GetSpellMaxCumulativeAuraApplications =
    H.guard("C_Spell.GetSpellMaxCumulativeAuraApplications", function(spellID)
      record(H.asked.maxStacks, spellID)
      return H.fx and H.fx.maxStacks and H.fx.maxStacks[spellID] or nil
    end)

  -- THE AFFORDABILITY CHANNEL (2026-08-03) — `C_Spell.IsSpellUsable`, the replacement for
  -- reading a SECRET primary resource.  See ns.SpellUsable's banner in Util.lua.
  --
  -- ⚠ IT RETURNS **TWO** BOOLEANS, and the pair is the whole point: `isUsable` alone cannot
  -- express "affordable but on cooldown", which is the state the Retribution flight measured
  -- and the reason the pipeline reads `insufficientPower` instead.
  --
  -- ⚠ DEFAULT-INERT LIKE EVERY FAKE HERE, and that is NOT the IsSpellOverlayed doctrine.
  -- `IsSpellOverlayed` returns a real `false` for an unregistered id because "not overlayed"
  -- is a genuine answer.  Here an unregistered id returns `nil` — "we could not ask" — so a
  -- fixture that says nothing about affordability gets the UNREADABLE branch rather than a
  -- silent "affordable" or "broke".  A fixture opts in with `H.fx.usable[id] = { usable =
  -- bool, insufficientPower = bool }`, and a REGISTERED id returns the pair.
  _G.C_Spell.IsSpellUsable = H.guard("C_Spell.IsSpellUsable", function(spellID)
    record(H.asked.usable, spellID)
    local u = H.fx and H.fx.usable and H.fx.usable[spellID]
    if u == nil then return nil end
    return u.usable, u.insufficientPower
  end)

  -- The proc-glow channel — the CDM's only combat-readable proc signal (§6).  Returns a
  -- real boolean for every id, because that is what the client does: "not overlayed" is an
  -- answer, not a refusal.  A refusal is H.throws, and a secret answer is fx.glow[id] set
  -- to a marked sentinel.
  _G.C_SpellActivationOverlay = { IsSpellOverlayed =
    H.guard("C_SpellActivationOverlay.IsSpellOverlayed", function(spellID)
      record(H.asked.glow, spellID)
      local g = H.fx and H.fx.glow and H.fx.glow[spellID]
      if g == nil then return false end
      return g
    end) }
  -- Spellbook knownness — the surviving correctness fence of field-fix A, and the one State's
  -- virtual-row walk reads (an untracked ability has no CDM struct to carry `isKnown`).
  -- Defaults to NOT known for every id: a spec opts a spellID in with `fx.known[id] = true`, so
  -- no existing test silently grows a virtual row.  Returns a real boolean, as the API does.
  _G.C_SpellBook = { IsSpellKnown = H.guard("C_SpellBook.IsSpellKnown", function(id)
    record(H.asked.known, id)
    return (H.fx and H.fx.known and H.fx.known[id]) == true
  end) }
  _G.CreateFrame = function(_, name, parent, _)
    local f = newStub()
    f._parent = parent
    H.frames[#H.frames + 1] = f
    if type(name) == "string" then _G[name] = f end
    return f
  end
  _G.GetSpecialization     = function() return H.specIndex end
  _G.GetSpecializationInfo = function(idx)
    local s = H.specByIndex[idx]
    if not s then return nil end
    return s[1], s[2]   -- specID, name (real API also returns description/icon/role — unused)
  end
  -- ACTION BARS — default-INERT, so HudBinds' 180-slot scan can run with no client: an
  -- empty bar is a legitimate answer and is exactly the LOGIN-RACE state its retry fence is
  -- about.  A spec opts in via `H.bar[slot] = { id = <spellID> }` +
  -- `H.bindings[<command>] = "<key>"`.
  _G.GetActionInfo = function(slot)
    local a = H.bar and H.bar[slot]
    if not a then return nil end
    return a.kind or "spell", a.id
  end
  _G.GetMacroSpell = function(id) return H.macros and H.macros[id] or nil end
  _G.GetBindingKey = function(cmd) return H.bindings and H.bindings[cmd] or nil end
  _G.UIParent = _G.UIParent or newStub()   -- the Renderer's default root token target
  -- ⚠ AND ITS SECRET STATE IS RESET, unlike the object itself.  UIParent is deliberately
  -- kept across H.fresh() (the Renderer holds references to it), but CurveLab's CANARY asks
  -- `UIParent:IsAnchoringSecret()` — so a test that poisons it would leak a permanently
  -- halted lab into every later spec file.  Same leak `installGlobals` exists to close.
  _G.UIParent._anchoringSecret = nil
  _G.UIParent._hasSecretValues = nil
  _G.UIParent._aspects         = nil
  _G.UIParent._dependents      = nil
end

-- Installed at load as well as from H.fresh(), so a module dofile'd before any test still
-- finds the client surface it expects.
H.installGlobals()

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
  H.secretTable, H.throws = {}, {}
  -- Per-case record of which ids each client fake was asked about.  See H.asked's header.
  H.asked = { cooldown = {}, charges = {}, glow = {}, auraByID = {}, known = {},
              info = {}, categorySet = {}, castCount = {}, maxStacks = {}, usable = {} }
  H.specIndex = 1               -- default to Demonology so the resolver activates 266
  H.bar, H.bindings, H.macros = {}, {}, {}   -- the action-bar client fake (default: empty)
  -- ⚠ RE-INSTALL, do not assume.  A previous test may have deleted or replaced a `_G`
  -- fake; without this the damage outlives the file that did it (see installGlobals').
  H.installGlobals()
  local ns = {}
  H.ns = ns

  -- The chat surface Core.lua owns in-game.  Provided by the HARNESS rather than guarded at
  -- the call site: `ns.X and ns.X(...)` on our OWN symbol is the idiom that turned a deleted
  -- ns.ItemCooldownID into a silent total outage, so modules call ns.Print/Printf directly.
  -- Captured so a spec can assert on what was announced.
  H.printed = {}
  ns.Print   = function(msg) H.printed[#H.printed + 1] = tostring(msg) end
  ns.Printf  = function(fmt, ...) ns.Print(string.format(fmt, ...)) end
  ns.Heading = function(t) ns.Print(tostring(t)) end

  -- Core.lua's command registry, recorded so a spec can DRIVE a slash verb (`/cdmp panel
  -- unlock`) through the same handler the game dispatches — the module registers at load,
  -- so the harness has to own the registry the way it owns the chat surface.
  H.commands = {}
  ns.RegisterCommand = function(name, help, fn) H.commands[name] = { help = help, fn = fn } end
  H.run = function(name, arg)
    local c = H.commands[name]
    if not c then error("mock_ns: no command '" .. tostring(name) .. "'") end
    return c.fn(arg)
  end

  -- Real, shipping implementations (data + lookups + Secret-Values-aware helpers).
  H.load("Util.lua")
  -- Viewers.lua owns the item-identity resolvers, including ns.DisplayIdentity — which
  -- State.lua calls DIRECTLY (no nil guard) on every fold.  Loaded as the real thing so a
  -- spec driving State never silently exercises a harness-supplied identity rule.
  H.load("Viewers.lua")
  H.load("SpecRegistry.lua")    -- registry + SetActiveSpec + ResolveActiveSpec
  H.load("SpecDemonology.lua")  -- self-registers spec 266 (activation is now the resolver's job)
  H.load("CoachDemonology.lua") -- attaches the Demo brain (Context/RankWinner/Escalate) to spec 266
  H.load("SpecDestruction.lua") -- self-registers spec 267
  H.load("CoachDestruction.lua")-- attaches the Destruction brain to spec 267
  H.load("SpecRetribution.lua") -- self-registers spec 70 (the first non-Warlock spec)
  H.load("CoachRetribution.lua")-- attaches the Retribution brain to spec 70
  H.load("SpecHavoc.lua")       -- self-registers spec 577 (the 2nd class outside Warlock)
  H.load("CoachHavoc.lua")      -- attaches the Havoc brain to spec 577

  -- Forward-declared so the two module stubs below can close over it before it is filled.
  local fx

  -- A fake napkin for HudScore's sake; hudnapkin_spec replaces this by loading the
  -- real module, so the two never fight.
  ns.HudNapkin = {
    SOON_LEAD = 3.0,
    Remaining = function(id) return fx.remain[id] end,
    SourceOf  = function(id) return fx.remainSource[id] end,
    Start     = function() end,     -- St.Acquire calls this DIRECTLY (no nil guard)
    Reset     = function() end,     -- ResolveActiveSpec calls this DIRECTLY on a spec swap
  }

  -- The keybind resolver State reads for every row.  The REAL module (Phase 3): it is pure
  -- over its own cache, and the thing worth testing through it — `B.Resolve`'s RUNG LADDER
  -- — is exactly what a hand-written stub would have to duplicate and could then get right
  -- while the shipping code got it wrong.  So the fixture supplies the CACHE (`B.map` is
  -- pointed at `fx.keybind` below, once fx exists) and everything above it is shipping
  -- code: the secret guard, the SpecBindAlias fallback, the ladder.
  -- ⚠ `Start` is stubbed back out: the real one scans 180 action slots through
  -- `GetActionInfo`, which no test has a client for, and `St.Acquire` calls it unguarded.
  H.load("HudBinds.lua")
  ns.HudBinds.Start = function() end

  -- Static activation is gone (Phase 5) — activate via the REAL resolver so every spec
  -- ships with ns.ActiveSpec = Demo exactly as before, transparently to the 137 tests.
  -- ⚠ MUST come after the two stubs above: the resolver calls HudNapkin.Reset /
  -- HudBinds.Invalidate directly on a spec change, with no existence guard.
  ns.ResolveActiveSpec()

  -- The fixture handle every spec pokes.  Tables are keyed by spellID.
  fx = {
    mode = nil, shards = nil, projected = false, aoe = false,
    cost = {}, baseCD = {}, remain = {}, remainSource = {},
    present = {}, override = {}, keybind = {},
    -- `known` drives the fake C_SpellBook.IsSpellKnown above (State's virtual-row fence).
    -- Empty by default, so virtual rows only appear where a spec explicitly asks for them.
    known = {},
    -- THE LIVE CLIENT, at client-API level (see installGlobals' "real client surface").
    -- Empty by default = every read refuses, which is what every guard ladder already
    -- treats as "the function does not exist".  Keyed by spellID:
    --   cd[id]        = { duration = n, startTime = n }   -- C_Spell.GetSpellCooldown
    --                   ⚠ include [61304] (the GCD) explicitly in any cd case; its ABSENCE
    --                     is a distinct branch — Util.lua:235's 1.5s backstop.
    --   charges[id]   = { currentCharges = n, maxCharges = n }
    --   auras         = { <packed aura>, … }              -- AuraUtil.ForEachAura
    --   auraByID[id]  = <aura table>                      -- GetPlayerAuraBySpellID
    --   auraThrows[id]= true                              -- …and its per-id refusal
    --   glow[id]      = bool                              -- IsSpellOverlayed
    --   power[type]   = { value, max, unmodified, unmodifiedMax }  -- UnitPower(Max)
    --   powerCost[id] = { { type = <PowerType>, cost = n, name = "…" }, … }
    --   castCount[id] = n          -- C_Spell.GetSpellCastCount (the DERIVED channel)
    --   maxStacks[id] = n          -- C_Spell.GetSpellMaxCumulativeAuraApplications
    --   usable[id]    = { usable = bool, insufficientPower = bool }
    --                                -- C_Spell.IsSpellUsable (the AFFORDABILITY channel).
    --                   ⚠ ABSENT is the UNREADABLE branch, not "affordable" — the fake
    --                     returns nil for an unregistered id.  A spec asserting that a
    --                     spender is BLOCKED must register `insufficientPower = true`.
    cd = {}, charges = {}, auras = {}, auraByID = {}, auraThrows = {}, glow = {},
    power = {}, powerCost = {}, castCount = {}, maxStacks = {}, usable = {},
  }
  H.fx = fx

  -- The fixture IS the resolved action-bar cache — `world.keybind[spellID]` in a CDM case,
  -- `H.fx.keybind[…]` elsewhere.  Same shape as what `scan()` would have produced, so the
  -- real `B.Get`/`B.Resolve` run over it unmodified.
  ns.HudBinds.map = fx.keybind
  ns.HudBinds.dirty = false

  -- Override the two RUNTIME readers (the real ones ask C_Spell on a live client);
  -- everything else in Util stays the shipping code.
  ns.ShardCost    = function(id) local c = fx.cost[id]; if c == nil then return nil end return c, c end
  ns.BaseCooldown = function(id) return fx.baseCD[id] end

  ns.HudChrome = { GetReady = function(item) return item and item.ready end }

  -- (ns.HudNapkin / ns.HudBinds are defined ABOVE, before ResolveActiveSpec.)

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
