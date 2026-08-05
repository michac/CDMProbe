-- CurveLab.lua — ⚠ TEMPORARY DISCOVERY INSTRUMENT, MEANT TO BE DELETED.
--
-- In the AlertTape / Assist mould, with the same end condition.  It is NOT in the pipeline:
-- nothing in State/Coach/Binder/Renderer reads it, no `guidance-contract.json` field, no
-- pixel of the shipping HUD depends on it.
--
-- THE ONE QUESTION.  Midnight 12.0 seals the values this HUD most wants — Fury, cooldown
-- remaining in combat, aura duration and stacks, target health.  Blizzard shipped **curves**
-- and **duration objects** as the sanctioned way to DISPLAY a secret without inspecting it,
-- and NOTHING IN THIS WORKSPACE HAS EVER CALLED ONE.  So: which visual channels can actually
-- carry a secret to the screen, and which silently do nothing?
--
-- ⚠ THE DELETION TRIGGER.  Once the answers land in
-- `knowledge/addon-dev/security-taint-and-restricted-data.md` §4.8, delete this file, its
-- `.toc` line, its `curvelab` / `curvelab_on` saved-vars, its spec
-- (`tests/spec/curvelab_spec.lua`) and `wowkb.cdmp curvelab`.  ONE question, ONE lab, a
-- clear end date — not a kitchen sink that outlives its purpose.
--
-- ⚠ THIS IS NOT A REVIVAL OF THE PHASE-2 FURY CASCADE.  `docs/multi-class-rollout.md`
-- recommended that AGAINST on 2026-08-03 and the verdict stands: it buys ~14 % Fury overcap
-- that top parses do not optimise, at the cost of a permanent decision-log blind spot.  That
-- verdict is about FURY.  It is not a verdict about curves, and the doc says so — *"the
-- technique is correct and will be the right answer for some future problem."*  This
-- measures the technique.  If the DURATION column proves out — an in-combat countdown the
-- HUD has never had — that becomes its own piece of work, with the report in hand.
--
-- ── WHAT IS ALREADY SETTLED (Tier 1, the vendored generated docs @ 12.0.7.68887) ─────────
--
-- THE ADDON CANNOT EVALUATE A CURVE OVER A SECRET ITSELF.  `LuaCurveObject:Evaluate(x)` is
-- `SecretArguments = "AllowedWhenUntainted"` [LuaCurveObjectAPIDocumentation.lua:46-49].
-- Only C-side sinks can drive one, and that single fact defines the whole source list below.
--
-- THE COMPLETE SET OF CURVE SINKS.  `SecretWhenCurveSecret` appears EXACTLY 8× in the
-- corpus: `UnitHealthPercent` [UnitDocumentation.lua:1426], `UnitPowerPercent` [:2716],
-- `C_UnitAuras.GetAuraDispelTypeColor` [UnitAuraDocumentation.lua:224], and five
-- `LuaDurationObject` Evaluate* methods.  (Three `SecondsFormatter` setters carry the
-- NUMERIC-formatter twin and are DELIBERATELY OUT OF SCOPE — a formatter is not a visual
-- channel, and `DurationTextBinding` reaches text more directly.)
--
-- ASPECTS ARE THE READBACK.  A setter that takes a secret and declares
-- `SecretArgumentsAddAspect` marks the object, and
-- `FrameScriptObject:HasSecretAspect(aspect)` / `HasAnySecretAspect()`
-- [SimpleFrameScriptObjectAPIDocumentation.lua:52, 38] report it.  That answers the question
-- this file would otherwise be unable to answer at all — "how do we verify a channel whose
-- value we cannot read back": WE READ THE ASPECT, NOT THE VALUE.
--
-- ⚠ FIVE SECRET-ACCEPTING SETTERS DECLARE NO ASPECT, verified by grep over the corpus, and
-- they are the ONLY anchor-contagion candidates and the only cells with no readback at all:
-- `Texture:SetTexture` [SimpleTextureBaseAPIDocumentation.lua:441], `SetAtlas` [:278],
-- `SetColorTexture` [:313], and `AnimVertexColor:SetStartColor` / `SetEndColor`
-- [SimpleAnimVertexColorAPIDocumentation.lua:46, 36].  ⚠ The earlier worry that `SetAlpha`
-- might poison the anchor chain is WRONG — it declares `{Alpha}` [SimpleRegionAPI…:125].
--
-- ── DESIGN NOTES, because the failure modes here are subtle ──────────────────────────────
--
-- 1. TWO STORES, DEDUPED DIFFERENTLY.  `cells` dedups on the VERDICT KEY (every cell's
--    verdict, plus combat) — the values are unreadable by construction, so a value change is
--    not merely noise here, it is unobservable, and only a verdict change is informative.
--    `negatives` is a flat per-session record kept WHOLE: a negative control that flips even
--    once invalidates every other row in the capture, so it must never be deduped away.
--
-- 2. FIVE-VALUED VERDICTS, NEVER A BOOLEAN.  `WORKED` / `INERT` / `REFUSED` / `UNSOURCED` /
--    `POISONED`.  ⚠ A THROW IS A POSITIVE RESULT for the two access-getters
--    (`GetEffectiveAlpha`, `IsDesaturated`) — the throw IS the proof the aspect landed — so
--    it must never be classified as failure.  And `INERT` is the dangerous cell, not the
--    boring one: the call succeeded, nothing flipped, and the pixel MAY OR MAY NOT have
--    moved.  It is escalated to the card and never scored as a pass.
--
-- 3. A BUILT-IN CONTROL GROUP IN BOTH CHANNELS.  Every sink is also driven by a SYNTHETIC
--    SAWTOOTH (C2) that is available on every character in every cell and is never secret,
--    and on a Warlock by Soul Shards (C1), a real resource that is never secret.  Top row
--    moves + subject row frozen ⇒ the channel is dead for secrets.  Both move ⇒ it works.
--    NEITHER moves ⇒ the instrument is broken and the capture proves nothing.  Without the
--    control, "nothing happened" is unfalsifiable — which is the exact failure AlertTape's
--    note 3 exists to prevent, restated for pixels.
--
-- 4. NEVER FORMAT A SECRET, INCLUDING AN ERROR STRING.  Every value reaching string.format
--    goes through ns.ClassOf first, and a caught error message is ns.Stash'd and truncated
--    before it can reach a row — an error string built by the client from a secret is still
--    a secret, and `%s` on one taints every row it lands in.
local ADDON, ns = ...

ns.CurveLab = {}
local L = ns.CurveLab

local CAP    = 200    -- ring rows kept (dedup by verdict key keeps this tiny)
local PERIOD = 1.0    -- watch sample cadence
local ERRCAP = 90     -- truncation for a stashed error string

L.halted = false      -- set by the UIParent canary; refuses every further cell

-- Forward-declared: the STACK CUE's target table is read by `L.VerdictKey` (its state is
-- part of the dedup key) but declared with the rest of the cue much further down.
local STACK_TARGETS

-- Forward-declared: the STACK CUE's readout is rendered by `L.Lines` but defined with the
-- rest of the cue much further down, so the reader meets the cue as one block rather than
-- split across the file.
local stackLines

--------------------------------------------------------------------------------
-- Small guarded helpers.  ns.ClassOf is the shipping readability classifier.
--------------------------------------------------------------------------------
local classOf = function(v) return ns.ClassOf(v) end

-- An error message is UNTRUSTED TEXT: the client may have built it out of the very secret we
-- passed in.  Stash it (a secret degrades to the string "<secret>") and truncate.
local function stashErr(e)
  local s = ns.Stash(e)
  if type(s) ~= "string" then return "<unprintable>" end
  if #s > ERRCAP then s = s:sub(1, ERRCAP) .. "…" end
  return s
end

-- The guarded call, in Util.lua's house style: capability check, then pcall, then the class.
-- An ABSENT namespace and a THROWING call are different findings and stay so.
local function callNS(tbl, name, ...)
  if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then
    return { call = "absent", class = "absent" }
  end
  local ok, a = pcall(tbl[name], ...)
  if not ok then return { call = "threw", class = "threw", err = stashErr(a) } end
  return { call = "ok", class = classOf(a), value = a }
end

-- ⚠ THE BOOLEAN COERCION IS A NAMED FUNCTION AND NOT AN INLINE `and`/`or`, because the
-- idiomatic `(r.call == "ok") and (r.value and true or false) or nil` SILENTLY COLLAPSES A
-- REAL `false` INTO `nil` — Lua's `false or nil` is nil.  Every reading in this file is
-- three-valued (yes / no / could-not-ask) and that collapse turns every "no" into
-- "unreadable", which is the absent-is-never-zero rule broken in the one place the whole
-- instrument depends on it: `0>1` (it flipped) would render `?>1` (we never knew).
local function boolOf(r)
  if r == nil or r.call ~= "ok" then return nil end
  return r.value and true or false
end

-- Call a METHOD on an object, same three-way outcome.  Written as a pcall'd closure rather
-- than `pcall(o[name], o, …)` because a curve / duration object is not guaranteed to be a
-- plain table, and indexing a userdata-backed one can itself raise.
local function callMethod(o, name, ...)
  if o == nil then return { call = "absent", class = "absent" } end
  local args, n = { ... }, select("#", ...)
  local out
  local ok, err = pcall(function() out = o[name](o, unpack(args, 1, n)) end)
  if not ok then return { call = "threw", class = "threw", err = stashErr(err) } end
  return { call = "ok", class = classOf(out), value = out }
end

-- WHICH BUILD PRODUCED THIS ROW?  The AlertTape.lua:98-116 correction, and it is a
-- CORRECTNESS point here for one specific reason: the duration column asks about
-- `L.SpellID()`, which resolves off the ACTIVE SPEC.  A spec swap without a `/reload` keeps
-- recording into the same ring, so two builds' rows would merge under one verdict key and
-- "the duration sink went inert" would really be "you respecced".  The tag goes INTO the
-- dedup key so rows from two builds can never merge, and ONTO the row so each one says
-- where it came from.
--
-- ⚠ `ns.State` loads AFTER this file in the .toc, so the read is guarded and happens at
-- SAMPLE time, never at load time.
local function buildTag()
  local spec = ns.detectedSpecName or "?"
  local hero
  if ns.State and ns.State.ReadHero then
    local ok, name, id = pcall(ns.State.ReadHero)
    if ok then hero = name or id end
  end
  return spec .. "/" .. tostring(hero or "?")
end
L.BuildTag = buildTag

--------------------------------------------------------------------------------
-- L.Constructors() — does this client have the machinery at all?
--------------------------------------------------------------------------------
-- Step 1 of the sequencing, and the cheapest thing in the file.  An ABSENT constructor makes
-- every downstream verdict meaningless, so it is reported first and separately rather than
-- being folded into a cell's `REFUSED`.
function L.Constructors()
  local out = {}
  local function probe(key, tbl, name)
    if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then
      out[key] = { call = "absent", class = "absent" }
      return
    end
    local ok, v = pcall(tbl[name])
    if not ok then out[key] = { call = "threw", class = "threw", err = stashErr(v) }
    else out[key] = { call = "ok", class = classOf(v), value = v } end
  end
  probe("CreateCurve",              C_CurveUtil,   "CreateCurve")
  probe("CreateColorCurve",         C_CurveUtil,   "CreateColorCurve")
  probe("CreateDuration",           C_DurationUtil, "CreateDuration")
  probe("CreateDurationTextBinding", C_DurationUtil, "CreateDurationTextBinding")
  probe("CreateManualClock",        C_DurationUtil, "CreateManualClock")
  return out
end

--------------------------------------------------------------------------------
-- L.BuildCurves() — the four curves the matrix runs on.
--------------------------------------------------------------------------------
-- `step` IS THE ONE THAT MATTERS FOR THE CARD.  A LINEAR ramp turns every channel into "is
-- that slightly dimmer?", which is unreadable across a room and unreadable in a screenshot;
-- a hard `Step` between 0.15 and 1.0 turns it into on/off.  [T1: LuaCurveType.Step = 1,
-- "Performs no interpolation between points, instead snapping to values exactly."
-- LuaCurveObjectConstantsDocumentation.lua:14]
--
-- `cubic3` IS A DELIBERATE 3-POINT CUBIC.  The docs say Cubic *"[r]equires a minimum of four
-- points ... less than this will fall back to Cosine interpolation"* [:16], while `GetType`
-- is documented only as *"the configured type"* [LuaCurveObjectBaseAPIDocumentation.lua:12].
-- Those two sentences do not settle whether GetType reports the CONFIGURED or the EFFECTIVE
-- type, and the difference decides whether GetType can ever be trusted as a readback.  So it
-- is MEASURED, not assumed.
local STEP_LO, STEP_HI = 0.15, 1.0

function L.BuildCurves()
  -- CACHED.  The points are static, so rebuilding per probe would cost ten constructions a
  -- tick at the card's 0.25 s cadence for no new information.  ⚠ Reuse is only safe because
  -- we never `AddPoint` a secret (that refuses — it is a negative control), so the curve
  -- itself can never pick up secret values; `HasSecretValues` is reported below rather than
  -- assumed, because that is the assumption most worth being wrong about.
  if L.curves then return L.curves, L.curveErr end
  local C, err = {}, {}
  local function make(key, ctor, points, curveType)
    if type(C_CurveUtil) ~= "table" or type(C_CurveUtil[ctor]) ~= "function" then
      err[key] = "absent"; return
    end
    local ok, curve = pcall(C_CurveUtil[ctor])
    if not ok or curve == nil then err[key] = "constructor refused"; return end
    local built = pcall(function()
      if curveType ~= nil then curve:SetType(curveType) end
      for _, p in ipairs(points) do curve:AddPoint(p[1], p[2]) end
    end)
    if not built then err[key] = "AddPoint/SetType refused"; return end
    C[key] = curve
  end
  local T = Enum and Enum.LuaCurveType
  local color = function(r, g, b, a)
    return (type(CreateColor) == "function") and CreateColor(r, g, b, a)
      or { r = r, g = g, b = b, a = a }
  end
  -- The card curve: on/off, legible across the room.
  make("step",  "CreateCurve", { { 0, STEP_LO }, { 0.5, STEP_HI } }, T and T.Step)
  -- The matrix curve: a smooth 0..1 ramp, so a channel that IS continuous shows it.
  make("ramp",  "CreateCurve", { { 0, 0 }, { 1, 1 } }, T and T.Linear)
  -- The colour curve.  ⚠ OPEN QUESTION, and worth a row of its own: `UnitPowerPercent`'s
  -- curve argument is typed `LuaCurveObjectBase` [UnitDocumentation.lua:2729] — the shared
  -- base of BOTH curve types — while `GetAuraDispelTypeColor`'s is typed narrowly
  -- `LuaColorCurveObject` [UnitAuraDocumentation.lua:238].  The generator distinguishes
  -- them, so a COLOUR curve may be accepted by UnitPowerPercent: secret Fury driving a
  -- colour directly, with no boolean quantisation.  Inferred, NOT proven — hence the cell.
  make("color", "CreateColorCurve",
       { { 0, color(1, 0.25, 0.25, 1) }, { 0.5, color(0.35, 1, 0.45, 1) } }, T and T.Step)
  -- The fallback probe (see the banner above).
  make("cubic3", "CreateCurve", { { 0, 0 }, { 0.5, 1 }, { 1, 0 } }, T and T.Cubic)
  L.curves, L.curveErr = C, err
  return C, err
end

-- The configured-vs-effective readback, reported next to the constructors.
function L.CurveTypes(C)
  local out = {}
  for key, curve in pairs(C or {}) do
    local t = callMethod(curve, "GetType")
    local n = callMethod(curve, "GetPointCount")
    local h = callMethod(curve, "HasSecretValues")
    out[key] = { typeClass = t.class, typeValue = ns.Stash(t.value),
                 points = ns.Stash(n.value),
                 -- `ReturnsNeverSecret` [LuaCurveObjectBaseAPIDocumentation.lua:24-26], so
                 -- this is free and always readable.  It must stay FALSE for our curves; a
                 -- true here means the cache above is unsafe and the curves must be rebuilt.
                 hasSecretValues = boolOf(h) }
  end
  return out
end

--------------------------------------------------------------------------------
-- L.Negatives() — THE NEGATIVE CONTROLS.  A probe without these proves nothing.
--------------------------------------------------------------------------------
-- ⚠ RUN FIRST, AND `curveEvaluate` IS LOAD-BEARING.  If `curve:Evaluate(secret)` SUCCEEDS,
-- the Tier-1 model this whole file is built on is wrong, every other verdict in the capture
-- is suspect, and the honest thing is to say so and stop rather than publish a matrix.
--
-- The sharpest pairing in the corpus is `cooldownSetCooldown` against the duration column:
-- SAME widget, SAME fact, one route forbidden (`Cooldown:SetCooldown` is
-- `SecretArguments = "AllowedWhenUntainted"` [FrameAPICooldownDocumentation.lua:280]) and
-- one sanctioned (`SetCooldownFromDurationObject`, which takes an OBJECT and never a number).
-- If both refuse, the sanctioned route is not sanctioned and §4.8 is wrong.
function L.Negatives(C, secret)
  local out = {}
  local function control(key, why, fn)
    if secret == nil or secret.class ~= "SECRET" then
      out[key] = { key = key, why = why, call = "n/a", verdict = "UNSOURCED",
                   detail = "no secret scalar this sample" }
      return
    end
    local ok, err = pcall(fn)
    out[key] = { key = key, why = why,
                 call = ok and "ok" or "threw",
                 err = (not ok) and stashErr(err) or nil,
                 -- A REFUSAL IS THE PASS HERE.  Inverted on purpose: these exist to fail.
                 verdict = ok and "WORKED" or "REFUSED" }
  end

  control("curveEvaluate", "curve:Evaluate(secret) MUST throw — if it does not, the model "
    .. "is wrong and every other verdict here is suspect", function()
      if not C.ramp then error("no curve", 0) end
      return C.ramp:Evaluate(secret.value)
    end)
  control("curveAddPoint", "curve:AddPoint(0, secret) MUST refuse "
    .. "(AllowedWhenUntainted)", function()
      if not C.ramp then error("no curve", 0) end
      return C.ramp:AddPoint(0, secret.value)
    end)
  control("gameCurve", "C_CurveUtil.EvaluateGameCurve(id, secret) MUST refuse", function()
    if type(C_CurveUtil) ~= "table" or type(C_CurveUtil.EvaluateGameCurve) ~= "function" then
      error("absent", 0)
    end
    return C_CurveUtil.EvaluateGameCurve(1, secret.value)
  end)
  control("cooldownSetCooldown", "Cooldown:SetCooldown(secret, secret) MUST refuse — the "
    .. "same fact the duration column carries, down the forbidden route", function()
      local sb = L.sandbox
      local cd = sb and sb.negativeCooldown
      if not cd then error("no sandbox cooldown", 0) end
      return cd:SetCooldown(secret.value, secret.value)
    end)
  return out
end

--------------------------------------------------------------------------------
-- THE SOURCES
--------------------------------------------------------------------------------
-- `kind` is what the source PRODUCES, and it is what pairs a source with a sink — the matrix
-- is deliberately sparse rather than dense, because feeding a colour to `SetText` measures
-- our own type error and nothing about the client.
--
--   number   a curve-evaluated scalar, guaranteed into 0..1 by OUR OWN curve
--   color    a colorRGBA (a ColorMixin table, possibly a SECRET TABLE — see below)
--   bool     a boolean, possibly secret
--   string   a string, possibly secret
--   duration a LuaDurationObject (never itself secret; it CARRIES the secret)
--
-- ⚠ THE RANGE GUARANTEE IS WHY EVERY NUMBER GOES THROUGH A CURVE.  `SetAlpha` wants 0..1 and
-- `UnitPowerPercent` without a curve returns a percentage; we cannot clamp a secret, because
-- we cannot compare one.  The curve does the clamping in C.  Same reason `SetRotation` is
-- fed the raw 0..1 as RADIANS rather than being scaled: `v * 6.28` on a secret is exactly
-- the arithmetic rule 13 forbids.
local FURY = 17            -- Enum.PowerType.Fury — primary, ContextuallySecret (measured)
local SOUL_SHARDS = 7      -- Enum.PowerType.SoulShards — on Blizzard's never-secret list

local function powerType(name, fallback)
  local E = Enum and Enum.PowerType
  local v = E and E[name]
  return (type(v) == "number") and v or fallback
end

-- WHICH SPELL THE DURATION COLUMN ASKS ABOUT.  Soft-resolved at DISPATCH time (not load
-- time — this file sits above SpecRegistry in the .toc): the active spec's first declared
-- ability if there is one, else the GCD, which every character always has.  `/cdmp curve
-- spell <id>` overrides it, because the interesting answer may be on a specific button.
local GCD_SPELLID = 61304

-- Returns (spellID, source) where source is "override" | "roster" | "roster-any" | "gcd".
--
-- ⚠⚠ THE FIRST CUT READ `ns.ActiveSpec.abilities`, WHICH DOES NOT EXIST, so this silently
-- returned the GCD on every spec and the DURATION COLUMN — the likeliest real win in the
-- whole file — asked about spell 61304 for a whole capture and came back `clean` on every
-- row.  THE ROSTER **IS** THE SPEC TABLE: `St.RosterEntries` walks `pairs(specTable)` over
-- numeric keys (State.lua:218), and the live one is the legacy global `ns.Spec`
-- (State.lua:2261 passes exactly that).  A silently-wrong spellID is the worst failure this
-- file can have, because every duration cell then reads UNSOURCED — "we never had a secret
-- to send" — which is indistinguishable from "the channel is dead".  Hence the second
-- return, which the readout prints and shouts about when it lands on the fallback.
--
-- ⚠ AND `ns.Spec` IS NIL ON AN UNREGISTERED SPEC (Vengeance, every spec outside the four),
-- where the GCD fallback is genuinely all there is — so on those, `/cdmp curve spell <id>`
-- is not optional.
function L.SpellID()
  if type(L.spellOverride) == "number" then return L.spellOverride, "override" end
  local roster = ns.Spec
  if type(roster) ~= "table" then return GCD_SPELLID, "gcd" end
  -- SORTED, so the pick is deterministic: a `pairs()`-order choice would make the verdict
  -- key differ between sessions for no reason anyone could see.
  local ids = {}
  for id, info in pairs(roster) do
    if type(id) == "number" and id > 0 and type(info) == "table" and info.kind ~= "aura" then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local anyNonUtility, anyButton
  for _, id in ipairs(ids) do
    anyButton = anyButton or id
    if roster[id].cadence ~= "utility" then
      anyNonUtility = anyNonUtility or id
      -- Prefer a rotational button whose cooldown the client will actually report, so the
      -- duration object has something to carry.  ⚠ `ns.BaseCooldown` is a WEAK test on some
      -- specs — Havoc has three rows that LIE and charge-category rows read 0 — which is
      -- exactly why the override exists and why the source is reported rather than assumed.
      if (ns.BaseCooldown(id) or 0) > 0 then return id, "roster" end
    end
  end
  -- A UTILITY button is the last thing to aim this at: it is the least likely to be on
  -- cooldown while you are looking, so it degrades to a clean duration and an UNSOURCED
  -- column — the failure mode this whole function is now shaped around.
  if anyNonUtility then return anyNonUtility, "roster-any" end
  if anyButton then return anyButton, "roster-utility" end
  return GCD_SPELLID, "gcd"
end

-- WHICH AURA THE AURA COLUMN ASKS ABOUT.  An `auraInstanceID` is required by three of the
-- five sources, and in combat the enumeration that hands one out is itself sealed — so it is
-- resolved OUT OF COMBAT and CACHED.  Instance ids are stable for the life of the aura, so a
-- cached one keeps working through the pull, which is the whole point.
function L.AuraInstance()
  if L.auraInstance then return L.auraInstance, L.auraUnit end
  if InCombatLockdown() then return nil, nil end
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil, nil end
  for _, unit in ipairs({ "player", "target" }) do
    for i = 1, 8 do
      local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
      if ok and type(data) == "table" and not ns.IsSecretTable(data) then
        local id
        if pcall(function() id = data.auraInstanceID end)
          and type(id) == "number" and not ns.IsSecret(id) then
          L.auraInstance, L.auraUnit = id, unit
          return id, unit
        end
      end
    end
  end
  return nil, nil
end

-- The source table.  `control = true` marks a channel that is NEVER secret by design; its
-- verdict is always UNSOURCED and that is correct — a control's value is VISUAL (the card),
-- not evidential (the matrix).  Reading a control's UNSOURCED as a failure is the one
-- misreading this table can produce, so it says so here.
function L.Sources(C)
  C = C or {}
  local S = {}
  local function add(t) S[#S + 1] = t end

  -- ── the controls, pinned first so the card draws them at the top ──────────────────────
  add({ key = "C2", label = "synthetic sawtooth", kind = "number", control = true,
        why = "the same curve fed a plain GetTime()%1 — available on EVERY character in "
           .. "EVERY cell.  If this row is frozen, the instrument is broken.",
        get = function()
          if not C.step then return { call = "absent", class = "absent" } end
          return callMethod(C.step, "Evaluate", GetTime() % 1)
        end })
  add({ key = "C2c", label = "synthetic sawtooth → colour", kind = "color", control = true,
        why = "the colour control: the colour curve driven by a plain number",
        get = function()
          if not C.color then return { call = "absent", class = "absent" } end
          return callMethod(C.color, "Evaluate", GetTime() % 1)
        end })
  add({ key = "C1", label = "Soul Shards % (never secret)", kind = "number", control = true,
        why = "a REAL resource on Blizzard's never-secret list — the control that proves a "
           .. "live UnitPowerPercent call reaches the sink at all (Warlock only)",
        get = function()
          if type(UnitPowerPercent) ~= "function" then return { call = "absent", class = "absent" } end
          return callNS(_G, "UnitPowerPercent", "player",
                        powerType("SoulShards", SOUL_SHARDS), false, C.step)
        end })
  add({ key = "C3", label = "hand-built duration", kind = "duration", control = true,
        why = "a duration object WE built, carrying no secret — the duration column's "
           .. "control: if this draws nothing, the sink is dead for every source",
        get = function()
          if type(C_DurationUtil) ~= "table"
            or type(C_DurationUtil.CreateDuration) ~= "function" then
            return { call = "absent", class = "absent" }
          end
          local ok, dur = pcall(C_DurationUtil.CreateDuration)
          if not ok or dur == nil then return { call = "threw", class = "threw" } end
          if not pcall(function() dur:SetTimeFromStart(GetTime(), 30) end) then
            return { call = "threw", class = "threw" }
          end
          return { call = "ok", class = classOf(dur), value = dur }
        end })
  add({ key = "C4", label = "hand-built duration → IsActive()", kind = "bool", control = true,
        why = "the BOOLEAN control: a bool off a duration that carries no secret",
        get = function()
          if type(C_DurationUtil) ~= "table"
            or type(C_DurationUtil.CreateDuration) ~= "function" then
            return { call = "absent", class = "absent" }
          end
          local ok, dur = pcall(C_DurationUtil.CreateDuration)
          if not ok or dur == nil then return { call = "threw", class = "threw" } end
          if not pcall(function() dur:SetTimeFromStart(GetTime(), 30) end) then
            return { call = "threw", class = "threw" }
          end
          return callMethod(dur, "IsActive")
        end })

  -- ── S1 · Fury.  The resource the Havoc flight failed on. ──────────────────────────────
  add({ key = "S1", label = "Fury % · step curve", kind = "number",
        get = function()
          if type(UnitPowerPercent) ~= "function" then return { call = "absent", class = "absent" } end
          return callNS(_G, "UnitPowerPercent", "player", powerType("Fury", FURY), false, C.step)
        end })
  add({ key = "S1r", label = "Fury % · linear ramp", kind = "number",
        get = function()
          if type(UnitPowerPercent) ~= "function" then return { call = "absent", class = "absent" } end
          return callNS(_G, "UnitPowerPercent", "player", powerType("Fury", FURY), false, C.ramp)
        end })
  -- ⚠ THE OPEN QUESTION (see L.BuildCurves' `color` note): a COLOUR curve into a
  -- `LuaCurveObjectBase` argument.  If this reads `table`, secret Fury drives a colour
  -- directly with no boolean quantisation.
  add({ key = "S1c", label = "Fury % · COLOUR curve  ⚠open", kind = "color",
        get = function()
          if type(UnitPowerPercent) ~= "function" then return { call = "absent", class = "absent" } end
          return callNS(_G, "UnitPowerPercent", "player", powerType("Fury", FURY), false, C.color)
        end })

  -- ── S2 · cooldown / charge remaining, as duration objects.  THE LIKELIEST REAL WIN: it
  -- needs no curve at all, and `GetSpellCooldownDuration` carries no secrecy predicate. ───
  add({ key = "S2", label = "cooldown remaining (duration)", kind = "duration",
        get = function()
          local dur, hsvOrErr = ns.ReadCooldownDuration((L.SpellID()), false)
          if dur == nil then
            return { call = "threw", class = "absent", err = stashErr(hsvOrErr) }
          end
          return { call = "ok", class = classOf(dur), value = dur, hsv = hsvOrErr }
        end })
  add({ key = "S2c", label = "charge recharge (duration)", kind = "duration",
        get = function()
          -- ⚠ A LOCAL, not an inline call: `L.SpellID()` returns TWO values and as the
          -- LAST argument it would EXPAND, handing the client the source string as a
          -- second argument.  Truncation is only automatic in non-final position.
          local id = L.SpellID()
          return callNS(C_Spell, "GetSpellChargeDuration", id)
        end })

  -- ── S3 · health.  `SecretReturns` UNCONDITIONALLY, so this is the one source that cannot
  -- come back readable — the cleanest positive control for "a secret reached the sink". ───
  add({ key = "S3", label = "target health % · step curve", kind = "number",
        get = function()
          if type(UnitHealthPercent) ~= "function" then return { call = "absent", class = "absent" } end
          local unit = (type(UnitExists) == "function" and UnitExists("target")) and "target" or "player"
          return callNS(_G, "UnitHealthPercent", unit, false, C.step)
        end })

  -- ── S4 / S5 · auras.  `GetAuraDuration` carries NO SecretWhenUnitAuraRestricted
  -- [UnitAuraDocumentation.lua:245], which is new: aura data is wholly sealed in combat
  -- today, and this may be a way to a LIVE AURA TIMER. ──────────────────────────────────
  add({ key = "S4", label = "aura remaining (duration)", kind = "duration",
        get = function()
          local id, unit = L.AuraInstance()
          if id == nil then return { call = "absent", class = "absent", err = "no aura instance" } end
          return callNS(C_UnitAuras, "GetAuraDuration", unit, id)
        end })
  add({ key = "S4c", label = "aura dispel colour", kind = "color",
        get = function()
          local id, unit = L.AuraInstance()
          if id == nil then return { call = "absent", class = "absent", err = "no aura instance" } end
          if not C.color then return { call = "absent", class = "absent", err = "no colour curve" } end
          return callNS(C_UnitAuras, "GetAuraDispelTypeColor", unit, id, C.color)
        end })
  -- ⚠ AURA STACKS COME BACK AS A **STRING**, not a number
  -- [GetAuraApplicationDisplayCount, UnitAuraDocumentation.lua:112] — so stacks route to the
  -- TEXT sinks, and `FontString:SetText` / `SetFormattedText` are `AllowedWhenTainted` with
  -- aspect `{Text}` [SimpleFontStringAPIDocumentation.lua:653, 528].
  add({ key = "S5", label = "aura stacks (STRING)", kind = "string",
        get = function()
          local id, unit = L.AuraInstance()
          if id == nil then return { call = "absent", class = "absent", err = "no aura instance" } end
          return callNS(C_UnitAuras, "GetAuraApplicationDisplayCount", unit, id, 1, 99)
        end })
  -- A boolean off a duration that DOES carry a secret — the only route to a secret bool this
  -- file has, and a measurement in its own right (`IsActive` declares no SecretReturns, but
  -- the object it is asked of is carrying secret timing).
  add({ key = "S6", label = "cooldown duration → IsActive()", kind = "bool",
        get = function()
          local dur = ns.ReadCooldownDuration((L.SpellID()), false)
          if dur == nil then return { call = "absent", class = "absent" } end
          return callMethod(dur, "IsActive")
        end })

  return S
end

--------------------------------------------------------------------------------
-- THE SINKS — the file's contract.
--------------------------------------------------------------------------------
-- ⚠ `expectAspect` IS HAND-TRANSCRIBED FROM THE GENERATED DOCS, by NAME.  Names, not the
-- enum's numeric values, because seven `Enum.SecretAspect` members are aliased to 0x1 in the
-- shipped file [SecretAspectConstantsDocumentation.lua:13-19] and a literal is therefore a
-- question about seven things at once (ns.SecretAspectName's banner has the rule).
--
-- ⚠ `aspectless = true` marks the FIVE secret-accepting setters that declare NO aspect.
-- Those are the ONLY anchor-contagion candidates and the ONLY cells with no readback of any
-- kind — eyeball on the card, or nothing.  The three DURATION sinks also have no aspect, but
-- for a different reason (they take an OBJECT, never a secret argument), so they are not
-- flagged: conflating "takes a secret and declares nothing" with "takes no secret at all"
-- would put three harmless cells on the contagion watch list and hide the real five.
local function color4(c)
  -- ⚠ `ns.IsSecretTable` BEFORE ANY `.r`.  A secret TABLE cannot be indexed at all; a
  -- READABLE table can still hand back secret members (Util.lua:76-80).  This one read
  -- decides whether the colour column has any sink at all, and getting it wrong is a taint,
  -- not a wrong answer.
  if c == nil then return nil, "nil colour" end
  if ns.IsSecret(c) then return nil, "SECRET scalar where a colour was expected" end
  if ns.IsSecretTable(c) then return nil, "SECRET-table — cannot be indexed" end
  local r, g, b, a
  if not pcall(function() r, g, b, a = c.r, c.g, c.b, c.a end) then
    return nil, "colour members raised on access"
  end
  if r == nil then return nil, "no r/g/b members" end
  return { r, g, b, a }
end

local SINKS

function L.Sinks()
  if SINKS then return SINKS end
  SINKS = {
    ----------------------------------------------------------------------------
    -- transparency.  ⚠ The widget is a FRAME, not a texture, and deliberately:
    -- `GetEffectiveAlpha` — the access-getter whose THROW is the positive result —
    -- is declared on Frame [SimpleFrameAPIDocumentation.lua:336], not on Region.
    ----------------------------------------------------------------------------
    { key = "alpha", channel = "transparency", widget = "frame", method = "SetAlpha",
      expectAspect = { "Alpha" }, accepts = { number = true },
      apply = function(w, v) w:SetAlpha(v) end,
      read  = function(w) return callMethod(w, "GetAlpha").class end,
      access = function(w) return callMethod(w, "GetEffectiveAlpha") end },
    { key = "alphaBool", channel = "transparency", widget = "frame",
      method = "SetAlphaFromBoolean", expectAspect = { "Alpha" }, accepts = { bool = true },
      apply = function(w, v) w:SetAlphaFromBoolean(v, 1.0, 0.15) end,
      read  = function(w) return callMethod(w, "GetAlpha").class end,
      access = function(w) return callMethod(w, "GetEffectiveAlpha") end },

    ----------------------------------------------------------------------------
    -- colour
    ----------------------------------------------------------------------------
    { key = "vertex", channel = "colour", widget = "texture", method = "SetVertexColor",
      expectAspect = { "VertexColor", "Alpha" }, accepts = { number = true, color = true },
      apply = function(w, v, _, kind)
        if kind == "color" then
          local c, why = color4(v)
          if not c then error(why, 0) end
          w:SetVertexColor(c[1], c[2], c[3], c[4])
        else
          w:SetVertexColor(v, v, v, 1)
        end
      end,
      read = function(w) return callMethod(w, "GetVertexColor").class end },
    { key = "vertexBool", channel = "colour", widget = "texture",
      method = "SetVertexColorFromBoolean", expectAspect = { "VertexColor", "Alpha" },
      accepts = { bool = true },
      apply = function(w, v)
        local on  = (type(CreateColor) == "function") and CreateColor(0.35, 1, 0.45, 1)
        local off = (type(CreateColor) == "function") and CreateColor(1, 0.25, 0.25, 1)
        w:SetVertexColorFromBoolean(v, on, off)
      end,
      read = function(w) return callMethod(w, "GetVertexColor").class end },

    ----------------------------------------------------------------------------
    -- brightness.  ⚠ `IsDesaturated` is `RequiresScriptObjectDesaturationAccess`
    -- [SimpleTextureBaseAPIDocumentation.lua:242], i.e. a THROW is the aspect landing.
    -- There is no non-throwing readback on this channel, so `read` is absent by design.
    ----------------------------------------------------------------------------
    { key = "desat", channel = "brightness", widget = "texture", method = "SetDesaturation",
      expectAspect = { "Desaturation" }, accepts = { number = true },
      apply = function(w, v) w:SetDesaturation(v) end,
      access = function(w) return callMethod(w, "IsDesaturated") end },
    { key = "desatBool", channel = "brightness", widget = "texture", method = "SetDesaturated",
      expectAspect = { "Desaturation" }, accepts = { bool = true },
      apply = function(w, v) w:SetDesaturated(v) end,
      access = function(w) return callMethod(w, "IsDesaturated") end },

    ----------------------------------------------------------------------------
    -- bar fill / bar colour
    ----------------------------------------------------------------------------
    { key = "barValue", channel = "bar fill", widget = "statusbar", method = "SetValue",
      expectAspect = { "BarValue" }, accepts = { number = true },
      apply = function(w, v) w:SetValue(v) end,
      read  = function(w) return callMethod(w, "GetValue").class end },
    { key = "barMinMax", channel = "bar fill", widget = "statusbar",
      method = "SetMinMaxValues", expectAspect = { "BarValue" }, accepts = { number = true },
      apply = function(w, v) w:SetMinMaxValues(0, v) end,
      read  = function(w) return callMethod(w, "GetValue").class end },
    { key = "barColor", channel = "bar colour", widget = "statusbar",
      method = "SetStatusBarColor", expectAspect = { "VertexColor", "Alpha" },
      accepts = { number = true, color = true },
      apply = function(w, v, _, kind)
        if kind == "color" then
          local c, why = color4(v)
          if not c then error(why, 0) end
          w:SetStatusBarColor(c[1], c[2], c[3], c[4])
        else
          w:SetStatusBarColor(v, v, v, 1)
        end
      end,
      -- ⚠ `GetStatusBarColor` [SimpleStatusBarAPIDocumentation.lua:92], NOT `GetVertexColor`
      -- — a StatusBar is a Frame, not a Region, so the Region getter is simply absent there
      -- and the first capture recorded `read=threw>threw` on every single barColor cell.
      read = function(w) return callMethod(w, "GetStatusBarColor").class end },

    ----------------------------------------------------------------------------
    -- rotation.  ⚠ The 0..1 curve output is fed as RADIANS UNSCALED — `v * 6.28` on a
    -- secret is the arithmetic rule 13 forbids, so ~57° is the whole swing available.
    ----------------------------------------------------------------------------
    { key = "rotation", channel = "rotation", widget = "texture", method = "SetRotation",
      expectAspect = { "Rotation" }, accepts = { number = true },
      apply = function(w, v) w:SetRotation(v) end,
      read  = function(w) return callMethod(w, "GetRotation").class end },

    ----------------------------------------------------------------------------
    -- text — where the STRING-shaped aura stack count has to land
    ----------------------------------------------------------------------------
    { key = "text", channel = "text", widget = "fontstring", method = "SetText",
      expectAspect = { "Text" }, accepts = { string = true },
      apply = function(w, v) w:SetText(v) end,
      read  = function(w) return callMethod(w, "GetText").class end },
    { key = "textFmt", channel = "text", widget = "fontstring", method = "SetFormattedText",
      expectAspect = { "Text" }, accepts = { string = true },
      apply = function(w, v) w:SetFormattedText(v) end,
      read  = function(w) return callMethod(w, "GetText").class end },

    ----------------------------------------------------------------------------
    -- THE DURATION COLUMN.  No aspect and no curve: these take an OBJECT, and the object
    -- carries the secret internally.  `HasSecretValues` is `ReturnsNeverSecret`, so it is
    -- the one always-readable oracle in the whole file — the readback everything else
    -- has to synthesise out of aspects.
    ----------------------------------------------------------------------------
    { key = "timerDur", channel = "duration bar", widget = "statusbar",
      method = "SetTimerDuration", expectAspect = nil, accepts = { duration = true },
      apply = function(w, v) w:SetTimerDuration(v) end,
      read  = function(w) return callMethod(w, "GetTimerDuration").class end,
      hsv   = function(w) local d = callMethod(w, "GetTimerDuration")
                          if d.call ~= "ok" or d.value == nil then return nil end
                          return boolOf(callMethod(d.value, "HasSecretValues")) end },
    { key = "cdDur", channel = "duration swipe", widget = "cooldown",
      method = "SetCooldownFromDurationObject", expectAspect = nil,
      accepts = { duration = true },
      apply = function(w, v) w:SetCooldownFromDurationObject(v, true) end,
      hsv   = function(_, arg)
                if arg == nil or arg.value == nil then return nil end
                return boolOf(callMethod(arg.value, "HasSecretValues")) end },
    { key = "textBind", channel = "live countdown text", widget = "fontstring",
      method = "C_DurationUtil.CreateDurationTextBinding", expectAspect = nil,
      accepts = { duration = true },
      -- ⚠ THE BINDING IS BUILT WITH THE CELL, NOT ON FIRST APPLY.  Creating it lazily made
      -- the FIRST sample structurally different from every later one — `HasSecretValues` had
      -- no binding to ask before the first apply and one after — so this cell alone could
      -- change verdict between two identical samples and spend a ring row saying so.  Every
      -- other sink's widget is minted up front; this one now is too.
      prepare = function(cell)
        if type(C_DurationUtil) ~= "table"
          or type(C_DurationUtil.CreateDurationTextBinding) ~= "function" then return end
        cell.binding = C_DurationUtil.CreateDurationTextBinding()
        pcall(function() cell.binding:SetFontString(cell.subject) end)
      end,
      apply = function(w, v, cell)
        local b = cell.binding
        if not b then error("C_DurationUtil.CreateDurationTextBinding absent", 0) end
        b:SetFontString(w)
        b:SetDuration(v)
        b:SetUpdateInterval(0.1)
        b:Enable()
      end,
      read = function(w) return callMethod(w, "GetText").class end,
      hsv  = function(_, _, cell)
               if cell == nil or cell.binding == nil then return nil end
               return boolOf(callMethod(cell.binding, "HasSecretValues")) end },

    ----------------------------------------------------------------------------
    -- ⚠ THE FIVE ASPECT-LESS SETTERS.  No aspect, no getter, no readback — the card's
    -- eyeball is the ONLY instrument here, and `anchor` is the only thing the matrix can
    -- measure about them.  Aim the contagion test at exactly these.
    ----------------------------------------------------------------------------
    { key = "texture", channel = "⚠ aspect-less", widget = "texture", method = "SetTexture",
      expectAspect = nil, aspectless = true, accepts = { string = true },
      apply = function(w, v) w:SetTexture(v) end },
    { key = "atlas", channel = "⚠ aspect-less", widget = "texture", method = "SetAtlas",
      expectAspect = nil, aspectless = true, accepts = { string = true },
      apply = function(w, v) w:SetAtlas(v) end },
    { key = "colorTex", channel = "⚠ aspect-less", widget = "texture",
      method = "SetColorTexture", expectAspect = nil, aspectless = true,
      accepts = { number = true, color = true },
      apply = function(w, v, _, kind)
        if kind == "color" then
          local c, why = color4(v)
          if not c then error(why, 0) end
          w:SetColorTexture(c[1], c[2], c[3], c[4])
        else
          w:SetColorTexture(v, v, v, 1)
        end
      end },
    { key = "animStart", channel = "⚠ aspect-less", widget = "animvertexcolor",
      method = "SetStartColor", expectAspect = nil, aspectless = true,
      accepts = { color = true },
      apply = function(w, v) w:SetStartColor(v) end },
    { key = "animEnd", channel = "⚠ aspect-less", widget = "animvertexcolor",
      method = "SetEndColor", expectAspect = nil, aspectless = true,
      accepts = { color = true },
      apply = function(w, v) w:SetEndColor(v) end },
  }
  return SINKS
end

--------------------------------------------------------------------------------
-- THE SANDBOX
--------------------------------------------------------------------------------
-- ⚠ ROOTED AT `UIParent`, NEVER AT ANYTHING THE HUD OWNS.  Secret-value contagion propagates
-- DOWN the anchor chain (security-taint-and-restricted-data.md §4.6(b)), so the only safe
-- parent is one whose dependents do not matter.  It must never be `HudVirtual`'s panel, a
-- CDM item frame, or anything `ns.GetItemFrames` can return.
--
-- ⚠ ONE FRESH WIDGET PER CELL, ~30 of them.  Aspects are STICKY and
-- `FrameScriptObject:SetToDefaults` is `IsProtectedFunction`, so we cannot clear one — reuse
-- would make every cell after the first unfalsifiable (the aspect is already set; the second
-- cell measures the first cell's result).
--
-- ⚠ THE CANARY IS THE MOST IMPORTANT SAFETY PROPERTY IN THIS FILE.  "Contagion propagates
-- down only" is TIER 2, not the generated docs.  If it is wrong, this sandbox poisons the
-- entire UI, so `UIParent:IsAnchoringSecret()` is asked before and after EVERY cell and a
-- flip halts the run, refuses every further cell, prints loudly, and is recorded.
--
-- ⚠ REFUSES TO **CREATE** IN COMBAT (HudVirtual's panel discipline).  An already-built
-- sandbox runs fine in combat, which is exactly where the samples matter.
local function widgetFor(root, kind)
  if kind == "texture" then
    local t = root:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(0.55, 0.55, 0.6, 1)
    return t
  elseif kind == "frame" then
    local f = CreateFrame("Frame", nil, root)
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(f)
    t:SetColorTexture(0.55, 0.55, 0.6, 1)
    f.swatch = t
    return f
  elseif kind == "statusbar" then
    local b = CreateFrame("StatusBar", nil, root)
    -- ⚠ THE TEXTURE IS NOT DECORATION — it is what makes the `barColor` cell measurable.
    -- The first live capture had a texture-LESS bar and `SetStatusBarColor(secret,…)` came
    -- back *"Object did not allow secret."*, which reads exactly like a Tier-1
    -- contradiction (the docs declare it `AllowedWhenTainted` + `{VertexColor, Alpha}`).
    -- It is far more likely OUR bug: SetStatusBarColor tints the bar's TEXTURE, and with no
    -- texture there is no object to carry the aspect.  Publishing that as a client finding
    -- would have been a confident wrong answer, so the instrument is fixed and the cell
    -- re-measured instead.
    b:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    b:SetMinMaxValues(0, 1)
    b:SetValue(1)
    b:SetStatusBarColor(0.4, 0.9, 0.5, 1)
    return b
  elseif kind == "fontstring" then
    local fs = root:CreateFontString(nil, "OVERLAY")
    ns.SetFont(fs, 11)
    fs:SetText("··")
    return fs
  elseif kind == "cooldown" then
    return CreateFrame("Cooldown", nil, root, "CooldownFrameTemplate")
  elseif kind == "animvertexcolor" then
    local f = CreateFrame("Frame", nil, root)
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(f)
    t:SetColorTexture(0.55, 0.55, 0.6, 1)
    local g = t:CreateAnimationGroup()
    local a = g:CreateAnimation("VertexColor")
    if a and a.SetDuration then a:SetDuration(0.6) end
    return a, f
  end
  return nil
end

function L.Sandbox()
  if L.sandbox then return L.sandbox end
  if InCombatLockdown() then return nil, "refuses to CREATE a sandbox in combat" end
  local root = CreateFrame("Frame", nil, UIParent)
  root:SetSize(1, 1)
  root:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  root:Hide()   -- hidden by default; the CARD is what makes it visible
  local sb = { root = root, cells = {} }
  -- The forbidden-route control lives here so `L.Negatives` has a real Cooldown to refuse.
  sb.negativeCooldown = CreateFrame("Cooldown", nil, root, "CooldownFrameTemplate")
  -- The canary's baseline.  Sampled at BUILD time so a UI already poisoned by someone else
  -- is distinguishable from one this run poisoned.
  sb.canaryAtBuild = boolOf(callMethod(UIParent, "IsAnchoringSecret"))
  L.sandbox = sb
  return sb
end

-- One fresh widget per (source, sink), plus a DEPENDENT CHILD anchored to it whose only job
-- is to answer "did it propagate down".
function L.Cell(sinkKey, srcKey, sink)
  local sb = L.Sandbox()
  if not sb then return nil end
  local key = srcKey .. "|" .. sinkKey
  if sb.cells[key] then return sb.cells[key] end
  local subject, host = widgetFor(sb.root, sink.widget)
  if subject == nil then return nil end
  host = host or ((sink.widget == "texture" or sink.widget == "fontstring") and sb.root) or subject
  -- The dependent: a plain texture anchored to the subject's host.  Anchoring, not
  -- parenting — §4.6(b) is about the ANCHOR chain.
  local child = sb.root:CreateTexture(nil, "BACKGROUND")
  child:SetSize(4, 4)
  local anchorTo = (sink.widget == "animvertexcolor") and host or subject
  pcall(function() child:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, 0) end)
  local cell = { key = key, subject = subject, host = host, child = child, sink = sinkKey }
  -- Any per-cell object the sink needs alongside its widget, built ONCE and up front so no
  -- sample is structurally different from any other (see `textBind`'s note).
  if sink.prepare then pcall(sink.prepare, cell) end
  sb.cells[key] = cell
  return cell
end

--------------------------------------------------------------------------------
-- L.RunCell(sink, arg, cell) -> the verdict record
--------------------------------------------------------------------------------
-- Records six things per cell, and each one is a different question:
--   arg     the CLASS of what we passed          (was there a secret at all?)
--   call    ok / threw / absent / refused        (did the setter accept it?)
--   landed  aspect+ / aspect- / aspect? / n/a    (did the object get marked?)
--   read    getter class before -> after         (did a readback change shape?)
--   hsv     HasSecretValues before -> after      (the duration column's free oracle)
--   anchor  IsAnchoringSecret before -> after    (subject AND its dependent child)
local function readAspects(w, sink)
  if sink.expectAspect == nil then
    -- No declared aspect, so the honest question is the broad one.
    local r = callMethod(w, "HasAnySecretAspect")
    if r.call ~= "ok" then return nil end
    return r.value and true or false
  end
  local E = Enum and Enum.SecretAspect
  if type(E) ~= "table" then return nil end
  for _, name in ipairs(sink.expectAspect) do
    -- ⚠ BY MEMBER, never by literal (ns.SecretAspectName's banner).
    local aspect = E[name]
    if aspect == nil then return nil end
    local r = callMethod(w, "HasSecretAspect", aspect)
    if r.call ~= "ok" then return nil end
    if r.value then return true end
  end
  return false
end

local function readAnchor(cell)
  return boolOf(callMethod(cell.subject, "IsAnchoringSecret")),
         boolOf(callMethod(cell.child, "IsAnchoringSecret"))
end

local function pair(before, after)
  local function n(v) if v == nil then return "?" end return v and "1" or "0" end
  return n(before) .. ">" .. n(after)
end

-- L.CarriesSecret(arg) -> true | false
--
-- "Did this sample actually put a secret in front of the sink?" — the question `UNSOURCED`
-- turns on, and it is NOT the same question as `arg.class == "SECRET"`.
--
-- ⚠ A DURATION OBJECT IS NEVER ITSELF SECRET; it CARRIES the secret internally, which is the
-- entire reason the duration route exists (§4.8: *"the number never enters Lua"*).  So for
-- that kind the class always reads `table` and the honest oracle is the object's own
-- `HasSecretValues()`, which is `ReturnsNeverSecret` and therefore always answerable.
-- Without this split, every duration cell would score UNSOURCED (the class is never SECRET)
-- or every duration cell would score as sourced (the class is never nil) — one of which
-- hides the column's whole finding and the other of which fakes it, including for the C3/C4
-- CONTROLS that are deliberately secret-free.
function L.CarriesSecret(arg)
  if arg == nil or arg.call ~= "ok" then return false end
  if arg.kind == "duration" then
    return boolOf(callMethod(arg.value, "HasSecretValues")) == true
  end
  if arg.class == "SECRET" or arg.class == "SECRET-table" then return true end
  -- ⚠ AND A COLOUR IS THE THIRD SHAPE, found by a smoke run of the whole matrix rather than
  -- by reading the docs.  `GetAuraDispelTypeColor` returns a ColorMixin, and the class of a
  -- READABLE table with SECRET MEMBERS is plain `table` — so a class test alone scored the
  -- colour column's most likely real shape as UNSOURCED, i.e. "we never had a secret to
  -- send", which is precisely the lie this verdict exists to prevent.  Util.lua:72-80 states
  -- the rule these two lines implement: a readable table can still hand back secret members,
  -- so BOTH questions get asked, always in this order.
  if arg.kind == "color" and arg.class == "table" then
    local borne = false
    pcall(function()
      local c = arg.value
      borne = ns.IsSecret(c.r) or ns.IsSecret(c.g) or ns.IsSecret(c.b) or ns.IsSecret(c.a)
    end)
    return borne and true or false
  end
  return false
end

function L.RunCell(sink, arg, cell)
  local rec = { sink = sink.key, src = arg.key, arg = arg.class, control = arg.control }

  if L.halted then
    rec.call, rec.verdict, rec.detail = "refused", "REFUSED", "canary halted the run"
    return rec
  end
  if cell == nil then
    rec.call, rec.verdict, rec.detail = "absent", "REFUSED", "no sandbox widget"
    return rec
  end

  local w = cell.subject
  local aspectBefore = readAspects(w, sink)
  local readBefore   = sink.read and sink.read(w) or nil
  local hsvBefore    = sink.hsv and sink.hsv(w, arg, cell) or nil
  local anchorSBefore, anchorCBefore = readAnchor(cell)

  -- THE SOURCE FAILED, NOT THE SINK, and the two must never be merged: "we could not ask"
  -- is not "the channel is dead".  Recorded UNSOURCED so it can never read as a pass.
  if arg.call ~= "ok" then
    rec.call, rec.verdict = arg.call, "UNSOURCED"
    rec.detail = arg.err or "the source produced nothing this sample"
    return rec
  end
  -- ⚠ A `nil` VALUE IS THE SOURCE SAYING NOTHING, and it must not be driven into the sink.
  -- The first capture aimed the duration column at Eye Beam, which has NO CHARGES, so
  -- `GetSpellChargeDuration` returned nothing (`MayReturnNothing`) — and every S2c cell then
  -- recorded `REFUSED` with a Lua *usage* error from our own nil argument. That is our
  -- mistake wearing the client's clothes: REFUSED means "the channel rejected a secret",
  -- and three rows of it here meant "we asked about a spell with no charges".
  if arg.value == nil then
    rec.call, rec.verdict = "ok", "UNSOURCED"
    rec.detail = "the source returned nil — nothing to send"
    return rec
  end

  local ok, err = pcall(sink.apply, w, arg.value, cell, arg.kind)
  rec.call = ok and "ok" or "threw"
  if not ok then rec.err = stashErr(err) end

  local aspectAfter = readAspects(w, sink)
  local readAfter   = sink.read and sink.read(w) or nil
  local hsvAfter    = sink.hsv and sink.hsv(w, arg, cell) or nil
  local anchorSAfter, anchorCAfter = readAnchor(cell)

  rec.landed = (aspectAfter == nil and "aspect?")
    or (aspectAfter and not aspectBefore and "aspect+")
    or (aspectAfter and "aspect=")
    or "aspect-"
  rec.read   = tostring(readBefore or "-") .. ">" .. tostring(readAfter or "-")
  rec.hsv    = pair(hsvBefore, hsvAfter)
  rec.anchor = pair(anchorSBefore, anchorSAfter) .. "/" .. pair(anchorCBefore, anchorCAfter)

  -- The canary, per cell.  A flip here means the down-only propagation rule is wrong and the
  -- sandbox is poisoning the real UI: halt, refuse everything further, and say so loudly.
  local canary = callMethod(UIParent, "IsAnchoringSecret")
  if canary.call == "ok" and canary.value and not L.sandbox.canaryAtBuild then
    L.halted, rec.canary = true, true
    ns.Print("|cffff4040CURVELAB HALTED|r — UIParent:IsAnchoringSecret() flipped on cell "
      .. tostring(arg.key) .. "|" .. tostring(sink.key)
      .. ". The down-only contagion rule is WRONG. |cffffffff/reload|r.")
  end

  -- ⚠ A **STATE** TEST, for the same sticky-widget reason as `flipped` below — and here it
  -- matters more.  Whole-object secrecy cannot be cleared by tainted code
  -- (`SetToDefaults` is `IsProtectedFunction`), so a cell that poisons its anchor chain on
  -- the first sample is poisoned FOREVER.  Written as an edge test it reported POISONED once
  -- and INERT on every sample after — i.e. the ring's second row said the contagion had
  -- stopped, which is the single most dangerous thing this instrument could claim.
  local anchorSecret = (anchorSAfter == true) or (anchorCAfter == true)
  rec.anchorWasClean = (anchorSBefore == false and anchorCBefore == false) or nil
  local accessThrew   = false
  if sink.access then
    local a = sink.access(w)
    rec.access = a.call
    -- ⚠ A THROW IS A POSITIVE RESULT.  `GetEffectiveAlpha` / `IsDesaturated` carry an access
    -- precondition, so refusing to answer IS the proof the aspect landed.
    accessThrew = (a.call == "threw")
  end

  -- ⚠⚠ "DID IT LAND" IS A **STATE** TEST, NOT AN EDGE TEST, and that is a correction rather
  -- than a preference.  Aspects are STICKY and `SetToDefaults` is `IsProtectedFunction`, so a
  -- cell's widget can only ever transition ONCE — and the widgets are memoised per
  -- (source, sink) because minting fresh ones at 1 Hz would leak ~60 widgets a second with
  -- no way to free them.  Written as an edge test, the FIRST watch sample scored WORKED and
  -- every sample after it scored INERT on the identical fact, so the ring filled with
  -- verdict changes that were artefacts of our own bookkeeping.  `aspect=` (present, and
  -- this cell is the only thing that could have put it there) is therefore just as positive
  -- as `aspect+`.
  --
  -- The same reasoning covers the other two: a getter that RETURNS a secret is the positive
  -- result whatever it returned last sample, and for the duration column `HasSecretValues()`
  -- is the ONLY observable there is — "the sink accepted an object that carries a secret" IS
  -- the §4.8 mechanism working, because the number never enters Lua to be observed.
  local flipped = (rec.landed == "aspect+" or rec.landed == "aspect=")
    or (readAfter == "SECRET" or readAfter == "SECRET-table")
    or (hsvAfter == true)
    or accessThrew
  -- ⚠ AND THERE IS DELIBERATELY NO `readBefore ~= readAfter` TERM.  It was here as a
  -- "weaker signal that might catch a shape change an aspect misses", and it did the
  -- opposite: a memoised widget transitions once, so an edge term scores the FIRST sample
  -- differently from every identical sample after it (measured: `C3|timerDur` read
  -- `nil>table` then `table>table`, WORKED then INERT, on unchanged inputs).  A verdict must
  -- be a function of the CURRENT state and nothing else, or the ring fills with rows
  -- recording our own bookkeeping.  `readBefore` is still RECORDED on the row — it is useful
  -- context for a human — it just does not decide anything.

  -- Ordered, and the order is the contract: a POISONED cell is a finding whether or not it
  -- also "worked", and an UNSOURCED cell must never be scored on a flip it cannot have made.
  if anchorSecret or rec.canary then rec.verdict = "POISONED"
  elseif rec.call ~= "ok" then rec.verdict = "REFUSED"
  elseif not L.CarriesSecret(arg) then rec.verdict = "UNSOURCED"
  elseif flipped then rec.verdict = "WORKED"
  else rec.verdict = "INERT" end
  return rec
end

--------------------------------------------------------------------------------
-- L.Probe() — one full pass over the matrix.
--------------------------------------------------------------------------------
function L.Probe()
  local p = { at = GetTime(), combat = InCombatLockdown() and true or false,
              halted = L.halted, build = buildTag() }
  p.spellID, p.spellSource = L.SpellID()
  local C = L.BuildCurves()
  p.curves       = C
  p.constructors = L.Constructors()
  p.curveTypes   = L.CurveTypes(C)
  p.curveErr     = L.curveErr

  -- The canonical SECRET SCALAR the negative controls need: `UnitPowerPercent` with NO curve
  -- returns a plain float that carries `SecretWhenUnitPowerRestricted`.
  local secret
  if type(UnitPowerPercent) == "function" then
    secret = callNS(_G, "UnitPowerPercent", "player", powerType("Fury", FURY), false)
  end
  -- ⚠ FALL BACK TO HEALTH, because Fury is only secret ON A DEMON HUNTER — the predicate
  -- reads "…unless the subject unit does not have a power of this type", so a Warlock's Fury
  -- reads a plain `num` and the FOUR NEGATIVE CONTROLS all degrade to UNSOURCED.  The
  -- 2026-08-04 Demonology capture recorded exactly that (`secretScalar=num`), which means
  -- the run could not confirm the Tier-1 model on that character at all.  `UnitHealthPercent`
  -- is `SecretReturns` UNCONDITIONALLY [UnitDocumentation.lua:1426] — every character has
  -- one, so the controls now run everywhere.
  if (secret == nil or secret.class ~= "SECRET") and type(UnitHealthPercent) == "function" then
    local h = callNS(_G, "UnitHealthPercent", "player", false)
    if h.class == "SECRET" then secret = h end
  end
  secret = secret or { call = "absent", class = "absent" }
  p.secretScalar = secret.class

  local sb = L.Sandbox()
  p.sandbox = sb and "ok" or "refused (combat)"

  -- ⚠ NEGATIVES FIRST.  If `curveEvaluate` does not refuse, the model is wrong and the
  -- matrix below is not worth reading — so the readout says so and the cells are skipped.
  p.negatives = L.Negatives(C, secret)
  local modelBroken = p.negatives.curveEvaluate
    and p.negatives.curveEvaluate.verdict == "WORKED"
  p.modelBroken = modelBroken and true or false

  p.sources = {}
  p.cells   = {}
  local sources = L.Sources(C)
  p.sourceOrder = {}
  for _, src in ipairs(sources) do
    p.sourceOrder[#p.sourceOrder + 1] = src.key
    local ok, got = pcall(src.get)
    if not ok then got = { call = "threw", class = "threw", err = stashErr(got) } end
    got = got or { call = "absent", class = "absent" }
    got.key, got.kind, got.label, got.control = src.key, src.kind, src.label, src.control
    -- Recorded on the SOURCE, not derived per cell: "did this sample carry a secret" is a
    -- property of the read, and every cell driven by it inherits the same answer.
    got.borne = L.CarriesSecret(got)
    p.sources[src.key] = got
  end

  if modelBroken or not sb then return p end

  for _, sink in ipairs(L.Sinks()) do
    for _, src in ipairs(sources) do
      local arg = p.sources[src.key]
      if sink.accepts[src.kind] then
        local cell = L.Cell(sink.key, src.key, sink)
        p.cells[src.key .. "|" .. sink.key] = L.RunCell(sink, arg, cell)
      end
    end
  end
  return p
end

--------------------------------------------------------------------------------
-- L.VerdictKey(p) — the dedup key: EVERY cell's verdict, plus combat.
--------------------------------------------------------------------------------
-- The values are unreadable by construction, so unlike AlertTape's field channel there is
-- no "value change is noise" trade-off to make here — a verdict change is the ONLY thing
-- observable, and it is exactly what a row should cost.
function L.VerdictKey(p)
  local parts = { p.build or buildTag(), p.combat and "combat" or "ooc" }
  local keys = {}
  for k in pairs(p.cells or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. tostring(p.cells[k].verdict)
  end
  for _, k in ipairs({ "curveEvaluate", "curveAddPoint", "gameCurve", "cooldownSetCooldown" }) do
    local n = (p.negatives or {})[k]
    parts[#parts + 1] = "!" .. k .. "=" .. tostring(n and n.verdict)
  end
  -- ⚠ THE STACK CUE'S STATE IS PART OF THE KEY, and it was NOT until the 2026-08-04
  -- Demonology pass — which is why a 13-row capture carried exactly TWO stack rows.  The
  -- cue's whole transition sequence (`aura-down` -> `ok` -> `id-unreadable`) is invisible to
  -- the matrix's verdicts, so without this the ring only sampled the cue on rows that
  -- happened to change for some unrelated reason.  A recorder that cannot see its own
  -- subject change is the AlertTape lesson restated.
  for _, t in ipairs(STACK_TARGETS) do
    local r = (L.stackLast or {})[t.key]
    parts[#parts + 1] = "#" .. t.key .. "=" .. tostring(r and r.state)
      .. "/" .. tostring(r and r.idClass)
  end
  return table.concat(parts, "|")
end

--------------------------------------------------------------------------------
-- L.Lines(p) -> array of chat lines.  Split out of the command so busted can read the
-- readout without a chat frame, and so a secret can be PROVEN never to reach a format.
--------------------------------------------------------------------------------
local VERDICT_COLOR = {
  WORKED    = "|cff88ff88",
  INERT     = "|cffffd100",
  REFUSED   = "|cff808080",
  UNSOURCED = "|cff6688cc",
  POISONED  = "|cffff4040",
}

local function tint(v)
  return (VERDICT_COLOR[v] or "|cffffffff") .. tostring(v) .. "|r"
end

function L.Lines(p)
  local out = {}
  local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

  add("  %-24s %s%s", "state", p.combat and "COMBAT" or "out of combat",
      p.halted and "  |cffff4040HALTED|r" or "")
  add("  %-24s %s", "sandbox", tostring(p.sandbox))
  -- ⚠ NAMED AND SOURCED, and LOUD on the fallback.  A silently-wrong spellID makes every
  -- duration cell read UNSOURCED — "we never had a secret to send" — which is
  -- indistinguishable from "the channel is dead", and that is exactly how the first live
  -- capture spent its whole duration column on the global cooldown.
  add("  %-24s %s %s  |cff808080[%s]|r", "duration column asks",
      tostring(p.spellID), tostring(ns.SpellName(p.spellID) or "?"),
      tostring(p.spellSource))
  if p.spellSource == "gcd" then
    add("    |cffff4040⚠ THAT IS THE GLOBAL COOLDOWN, not a rotation button.|r No registered "
      .. "spec roster to pick from (passive spec?). The whole DURATION COLUMN will read "
      .. "clean/UNSOURCED and prove nothing — set one: |cffffffff/cdmp curve spell <id>|r")
  elseif p.spellSource == "roster-any" or p.spellSource == "roster-utility" then
    add("    |cffffd100⚠ no roster button reported a base cooldown|r — this one may have "
      .. "nothing to count down. If the duration column reads clean, aim it: "
      .. "|cffffffff/cdmp curve spell <id>|r")
  end

  add("  |cffffd100constructors|r")
  for _, key in ipairs({ "CreateCurve", "CreateColorCurve", "CreateDuration",
                         "CreateDurationTextBinding", "CreateManualClock" }) do
    local r = p.constructors[key] or {}
    add("    %-26s %s", key, tostring(r.class))
  end
  for key, t in pairs(p.curveTypes or {}) do
    add("    curve %-20s type=%s(%s) points=%s", key, tostring(t.typeClass),
        tostring(t.typeValue), tostring(t.points))
  end

  add("  |cffffd100negative controls|r  (a REFUSAL is the pass — these exist to fail)")
  for _, key in ipairs({ "curveEvaluate", "curveAddPoint", "gameCurve",
                         "cooldownSetCooldown" }) do
    local n = (p.negatives or {})[key]
    if n then
      add("    %-22s %s   %s", key, tint(n.verdict), n.err or n.detail or "")
    end
  end
  if p.modelBroken then
    add("  |cffff4040curve:Evaluate(secret) SUCCEEDED.|r The Tier-1 model this file is "
      .. "built on is WRONG; the matrix was NOT run and would not be worth reading.")
    return out
  end

  add("  |cffffd100sources|r")
  for _, key in ipairs(p.sourceOrder or {}) do
    local s = p.sources[key]
    add("    %-4s %-32s %-12s %-10s %s%s", key, s.label, s.class,
        s.borne and "|cff88ff88secret|r" or "clean",
        s.control and "|cff6688cccontrol|r" or "",
        s.err and ("  " .. tostring(s.err)) or "")
  end

  if ns.db and ns.db.curvelab_stack then
    add("  |cffffd100stack cue|r  (the threshold is compared IN C — we never read the count)")
    for _, line in ipairs(stackLines()) do add("%s", line) end
  end

  add("  |cffffd100matrix|r  (arg · call · landed · read · hsv · anchor)")
  for _, sink in ipairs(L.Sinks()) do
    local rows = {}
    for _, key in ipairs(p.sourceOrder or {}) do
      local c = p.cells[key .. "|" .. sink.key]
      if c then rows[#rows + 1] = string.format("%s=%s", key, tint(c.verdict)) end
    end
    if #rows > 0 then
      add("    %-12s %-18s %s%s", sink.key, sink.channel, table.concat(rows, " "),
          sink.aspectless and "   |cffff8080no readback — eyeball only|r" or "")
    end
  end

  -- INERT is escalated, never buried: the call succeeded, nothing flipped, and the pixel
  -- may or may not have moved.  It is the one verdict the card exists to resolve.
  local inert = {}
  for k, c in pairs(p.cells or {}) do
    if c.verdict == "INERT" then inert[#inert + 1] = k end
  end
  table.sort(inert)
  if #inert > 0 then
    add("  |cffffd100%d INERT cell(s)|r — the setter took a secret and NOTHING flipped. "
      .. "The pixel may still have moved: |cffffffff/cdmp curve card|r and look.", #inert)
    add("    %s", table.concat(inert, ", "))
  end
  return out
end

--------------------------------------------------------------------------------
-- The watch ring — opt-in, OFF by default, recording only on a VERDICT change.
--------------------------------------------------------------------------------
local ticker
local stackTicker

local function ringRow(p)
  local cells = {}
  for k, c in pairs(p.cells or {}) do
    cells[k] = { arg = ns.Stash(c.arg), call = ns.Stash(c.call), landed = ns.Stash(c.landed),
                 read = ns.Stash(c.read), hsv = ns.Stash(c.hsv), anchor = ns.Stash(c.anchor),
                 access = ns.Stash(c.access), verdict = ns.Stash(c.verdict),
                 err = ns.Stash(c.err), control = c.control and true or nil }
  end
  local negs = {}
  for k, n in pairs(p.negatives or {}) do
    negs[k] = { verdict = ns.Stash(n.verdict), call = ns.Stash(n.call),
                err = ns.Stash(n.err), why = ns.Stash(n.why) }
  end
  local srcs = {}
  for k, s in pairs(p.sources or {}) do
    srcs[k] = { class = ns.Stash(s.class), kind = ns.Stash(s.kind),
                label = ns.Stash(s.label), err = ns.Stash(s.err),
                borne = s.borne and true or false,
                control = s.control and true or nil }
  end
  local ctors = {}
  for k, r in pairs(p.constructors or {}) do ctors[k] = ns.Stash(r.class) end
  -- THE STACK CUE's reads ride the same ring, because the question it answers — is
  -- `item.auraInstanceID` readable in combat — is settled by a CLASS, not by whether any
  -- text appeared on screen.  ⚠ `value` is deliberately NOT recorded even through Stash:
  -- it is the one field that is a secret STRING by design, and the finding is its CLASS.
  local stack = {}
  for k, r in pairs(L.stackLast or {}) do
    stack[k] = { state = ns.Stash(r.state), idClass = ns.Stash(r.idClass),
                 textClass = ns.Stash(r.textClass), viewer = ns.Stash(r.viewer),
                 unit = ns.Stash(r.unit), min = ns.Stash(r.min),
                 spellID = ns.Stash(r.spellID), err = ns.Stash(r.err) }
  end
  return {
    t = p.at, key = L.VerdictKey(p), combat = p.combat, halted = p.halted and true or nil,
    build = ns.Stash(p.build), version = ns.version, spellID = ns.Stash(p.spellID),
    spellSource = ns.Stash(p.spellSource),
    secretScalar = ns.Stash(p.secretScalar), sandbox = ns.Stash(p.sandbox),
    modelBroken = p.modelBroken and true or nil,
    constructors = ctors, negatives = negs, sources = srcs, cells = cells, stack = stack,
  }
end
L.RingRow = ringRow

function L.Sample()
  if not (ns.db and ns.db.curvelab_on) then return end
  -- Refresh the stack cue's reads first so the row records the SAME instant it drew.
  pcall(L.StackRefresh)
  local p = L.Probe()
  local key = L.VerdictKey(p)
  local ring = ns.db.curvelab
  if type(ring) ~= "table" then ring = {}; ns.db.curvelab = ring end
  if ring[#ring] and ring[#ring].key == key then return end
  if #ring >= CAP then return end
  ring[#ring + 1] = ringRow(p)
  return ring[#ring]
end

function L.Watch(on)
  ns.db = ns.db or {}
  ns.db.curvelab_on = on and true or false
  if ticker then ticker:Cancel(); ticker = nil end
  if on then
    ticker = C_Timer.NewTicker(PERIOD, function() pcall(L.Sample) end)
    L.Sample()
  end
end

--------------------------------------------------------------------------------
-- THE CARD — one row per source × one column per sink, live, on screen.
--------------------------------------------------------------------------------
-- Maximal on purpose: the INERT and aspect-less cells have NO readback at all, so for those
-- the eye is the only instrument there is.  The CONTROL ROWS ARE PINNED AT THE TOP, drawn
-- with the hard `Step` curve so on/off is legible across the room rather than "is that
-- slightly dimmer?".  Top moves + bottom frozen ⇒ the channel is dead for secrets.  Both
-- move ⇒ it works.  NEITHER moves ⇒ the instrument is broken and the capture proves nothing.
local CARD_CELL_W, CARD_CELL_H, CARD_LABEL_W = 84, 46, 190

local function cardCellWidget(cell, sink)
  -- What to SHOW for a cell.  A texture/frame shows itself; the animvertexcolor sink has no
  -- steady visual of its own, so its host frame's swatch stands in.
  if sink.widget == "animvertexcolor" then return cell.host end
  return cell.subject
end

function L.Card(on)
  if on == false then
    if L.card then L.card:Hide() end
    return
  end
  if L.card then L.card:Show(); return L.card end
  local sb = L.Sandbox()
  if not sb then
    ns.Print("|cffff4040cannot build the card in combat|r — the sandbox refuses to CREATE "
      .. "frames in a lockdown. Step out, run it, then pull.")
    return nil
  end
  local card = CreateFrame("Frame", nil, UIParent)
  card:SetAllPoints(UIParent)
  card:SetFrameStrata("FULLSCREEN_DIALOG")
  local bg = card:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(card)
  bg:SetColorTexture(0, 0, 0, 0.86)

  local head = card:CreateFontString(nil, "OVERLAY")
  ns.SetFont(head, 13)
  head:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)
  card.head = head

  local sinks   = L.Sinks()
  local sources = L.Sources(L.BuildCurves())
  -- Controls first — the pinned top rows.
  local order = {}
  for _, s in ipairs(sources) do if s.control then order[#order + 1] = s end end
  for _, s in ipairs(sources) do if not s.control then order[#order + 1] = s end end

  -- Column headers.
  for i, sink in ipairs(sinks) do
    local h = card:CreateFontString(nil, "OVERLAY")
    ns.SetFont(h, 9)
    h:SetPoint("TOPLEFT", card, "TOPLEFT",
               CARD_LABEL_W + (i - 1) * CARD_CELL_W, -34)
    h:SetWidth(CARD_CELL_W - 4)
    h:SetJustifyH("LEFT")
    h:SetText((sink.aspectless and "|cffff8080" or "|cffffd100") .. sink.key .. "|r")
  end

  card.cells = {}
  for r, src in ipairs(order) do
    local y = -52 - (r - 1) * CARD_CELL_H
    local lab = card:CreateFontString(nil, "OVERLAY")
    ns.SetFont(lab, 10)
    lab:SetPoint("TOPLEFT", card, "TOPLEFT", 10, y)
    lab:SetWidth(CARD_LABEL_W - 8)
    lab:SetJustifyH("LEFT")
    lab:SetText((src.control and "|cff6688cc" or "|cffffffff") .. src.key .. " " .. src.label
      .. "|r")
    for i, sink in ipairs(sinks) do
      if sink.accepts[src.kind] then
        local cell = L.Cell(sink.key, src.key, sink)
        if cell then
          local shown = cardCellWidget(cell, sink)
          -- ⚠ The sandbox root is HIDDEN and 1×1; re-parenting the live widget into the card
          -- is what puts it on screen.  Deliberately the SAME widget the matrix drove — a
          -- copy would be a rig that can pass while the measured path fails, which is the
          -- `rt fx` lesson (addon/CLAUDE.md).
          pcall(function()
            shown:SetParent(card)
            shown:ClearAllPoints()
            shown:SetSize(CARD_CELL_W - 26, CARD_CELL_H - 24)
            shown:SetPoint("TOPLEFT", card, "TOPLEFT",
                           CARD_LABEL_W + (i - 1) * CARD_CELL_W, y)
            shown:Show()
          end)
          local vt = card:CreateFontString(nil, "OVERLAY")
          ns.SetFont(vt, 8)
          vt:SetPoint("TOPLEFT", card, "TOPLEFT",
                      CARD_LABEL_W + (i - 1) * CARD_CELL_W, y - (CARD_CELL_H - 22))
          vt:SetWidth(CARD_CELL_W - 4)
          vt:SetJustifyH("LEFT")
          card.cells[src.key .. "|" .. sink.key] = vt
        end
      end
    end
  end

  card.ticker = C_Timer.NewTicker(0.25, function()
    if not card:IsShown() then return end
    local okp, p = pcall(L.Probe)
    if not okp or not p then return end
    for k, fs in pairs(card.cells) do
      local c = p.cells[k]
      fs:SetText(c and (tint(c.verdict) .. (c.canary and " |cffff4040!|r" or "")) or "-")
    end
    head:SetText(string.format(
      "|cffffd100CDMProbe curve lab|r  v%s   %s   spec=%s   canary=%s%s   "
      .. "|cff808080/cdmp curve card to close|r",
      tostring(ns.version), p.combat and "|cffff8080COMBAT|r" or "out of combat",
      tostring(ns.detectedSpecName or "?"),
      tostring((callMethod(UIParent, "IsAnchoringSecret").value) and "SECRET" or "clean"),
      L.halted and "   |cffff4040HALTED|r" or ""))
  end)
  L.card = card
  return card
end

--------------------------------------------------------------------------------
-- THE STACK CUE — the first APPLIED use of the technique this file exists to measure.
--------------------------------------------------------------------------------
-- ⚠ STILL A PROBE.  It draws its own FontStrings anchored to Blizzard's icons and touches
-- NOTHING in State/Coach/Binder/Renderer.  It ships here, in the file already scheduled for
-- deletion, so that if the technique does not hold up there is exactly one thing to delete.
--
-- THE PROBLEM IT SOLVES.  An aura's STACK COUNT is secret in combat — `applications` on the
-- AuraData record and the `GetAuraApplicationDisplayCount` string alike — so no Lua can
-- branch on it, and §4.8.1 measured that a stack count has NO curve sink either, so it can
-- never reach alpha / colour / a bar.  Two Demonology gates live exactly there: **Wild Imps
-- (296553) >= 6** is Implosion's real gate (SpecDemonology.lua's `judgeable = false` case),
-- and **Demonic Core (264173) caps at 4**.
--
-- ⚠⚠ THE TRICK IS THAT THE THRESHOLD COMPARISON HAPPENS IN C, AND WE CONSUME ONLY THE
-- VISUAL DIFFERENCE.  `GetAuraApplicationDisplayCount(unit, id, minDisplayCount,
-- maxDisplayCount)` documents [UnitAuraDocumentation.lua:112-128]:
--   * below `min` -> an EMPTY STRING
--   * above `max` -> the string "*"
-- An empty string renders nothing; a count renders.  So a FontString fed
-- `(unit, id, 7, nil)` is INVISIBLE below 7 stacks and shows the number at 7+, and we never
-- read, compare or even see the value.  The cue IS the appearance of the text.
--
-- ⚠ WHAT MAKES IT WORK IN COMBAT IS `item.auraInstanceID`.  The call is
-- `RequiresValidUnitAuraInstance`, and the enumeration that hands out instance IDs is sealed
-- in a pull — but Blizzard's own CDM item frame CARRIES one and keeps it fresh
-- (`CooldownViewerItemDataMixin:SetAuraInstanceInfo`, `CooldownViewerItemData.lua:243`,
-- called from `RefreshAuraInstance` on every aura change).  We read the frame field, exactly
-- as State already reads `auraDataUnit` (roster-state-plan §3.10).
--
-- ⚠⚠ AND THAT READ IS THE UNMEASURED PART — IT IS THE POINT OF THIS PASS.  If
-- `item.auraInstanceID` reads SECRET in combat we cannot use it at all: the API is
-- `SecretArguments = "AllowedWhenUntainted"`, so a secret instance id is REFUSED, not
-- silently wrong.  The class of that read is recorded on every sample and reported by
-- `wowkb.cdmp curvelab`, so the flight answers it whether or not any text appears.
--
-- ⚠ THE FONTSTRING IS A LEAF, DELIBERATELY.  §4.8.1 measured that `SetText` with a secret
-- applies the `{Text}` aspect AND marks anchoring secret, propagating DOWN to dependents.
-- So this anchors the FontString TO Blizzard's icon (making it the dependent, which is safe
-- — the contagion flows away from the icon, not into it) and NOTHING is ever anchored to
-- the FontString.  Do not hang a backdrop, a border or a second string off it.
STACK_TARGETS = {
  -- `min` is the THRESHOLD, and it is the whole cue: text appears at `min` stacks and not
  -- before.  ⚠ 7 = "MORE THAN 6", which is what was asked for; the APL's own Implosion gate
  -- is `>= 6`, so `/cdmp curve stack imps 6` is the rotation-faithful setting.
  { key = "imps", spellID = 296553, min = 7,
    label = "Wild Imps", color = { 0.741, 0.953, 0.227 } },   -- SpecDemonology's fel lime
  -- Demonic Core caps at 4, so `min = 4` fires only at cap — exactly "4 stacks".
  { key = "core", spellID = 264173, min = 4,
    label = "Demonic Core", color = { 0.51, 0.78, 1.0 } },
}

function L.StackTargets() return STACK_TARGETS end

function L.SetStackThreshold(key, n)
  for _, t in ipairs(STACK_TARGETS) do
    if t.key == key then t.min = n; return t end
  end
  return nil
end

-- Find the CDM item frame carrying a given aura spellID, across the BUFF viewers.  Returns
-- (item, viewerLabel) or nil.  Guarded end to end: a refused viewer read is not a finding
-- about the aura.
function L.FindAuraItem(spellID)
  if not ns.VIEWERS then return nil end
  for _, v in ipairs(ns.VIEWERS) do
    local viewer = ns.GetViewer(v.frame)
    if viewer then
      local ok, frames = pcall(ns.GetItemFrames, viewer)
      if ok and type(frames) == "table" then
        for _, item in ipairs(frames) do
          local base = ns.ItemBaseSpellID(item)
          if base == spellID then return item, v.label end
          -- The aura's own id can also sit on the frame's aura fields rather than its base.
          local aid
          if pcall(function() aid = item.auraSpellID end) and aid == spellID then
            return item, v.label
          end
        end
      end
    end
  end
  return nil
end

-- One target's read, fully classified.  Returns a record; NEVER the value.
function L.StackRead(t)
  local rec = { key = t.key, spellID = t.spellID, min = t.min, label = t.label }
  local item, viewer = L.FindAuraItem(t.spellID)
  rec.viewer = viewer
  if not item then rec.state = "no-frame"; return rec end
  -- ⚠ THE MEASUREMENT.  `item.auraInstanceID` is read through a pcall AND classified, and
  -- both halves matter: absent (the aura is not up) and SECRET (we may not have it) are
  -- completely different findings, and only one of them closes the technique.
  local id
  if not pcall(function() id = item.auraInstanceID end) then
    rec.state, rec.idClass = "threw", "threw"
    return rec
  end
  rec.idClass = classOf(id)
  if id == nil then rec.state = "aura-down"; return rec end
  if rec.idClass ~= "num" then
    -- A secret instance id cannot be passed on (AllowedWhenUntainted) — the technique is
    -- closed for this aura and the report must say so rather than draw nothing quietly.
    rec.state = "id-unreadable"
    return rec
  end
  local unit
  pcall(function() unit = item.auraDataUnit end)
  if ns.IsSecret(unit) or type(unit) ~= "string" then unit = "player" end
  rec.unit = unit
  local r = callNS(C_UnitAuras, "GetAuraApplicationDisplayCount", unit, id, t.min, nil)
  rec.state = (r.call == "ok") and "ok" or r.call
  rec.textClass = r.class
  rec.value = r.value           -- ⚠ possibly SECRET — never formatted, only handed to SetText
  rec.err = r.err
  return rec
end

-- The drawn cue: one FontString per target, parented to our own holder and ANCHORED to
-- Blizzard's icon.
local stackFrames = {}

local function stackFontString(t, item)
  local fs = stackFrames[t.key]
  if fs and fs._item == item then return fs end
  if fs then fs:Hide() end
  local holder = CreateFrame("Frame", nil, UIParent)
  -- ⚠ `SetAllPoints`, because the holder was created with NO SIZE AND NO ANCHOR.  A region
  -- whose parent has an undefined rect is a coin-flip to render, and "nothing appeared"
  -- would then be indistinguishable from "the threshold was never met" — the one confusion
  -- this cue cannot afford, since its entire signal IS the appearance of text.
  holder:SetAllPoints(UIParent)
  holder:SetFrameStrata("HIGH")
  holder:Show()
  fs = holder:CreateFontString(nil, "OVERLAY")
  -- Big, because the whole cue is "a number appeared".  A subtle one is a cue you miss.
  ns.SetFont(fs, 34, "OUTLINE")
  fs:SetTextColor(t.color[1], t.color[2], t.color[3], 1)
  fs._item, fs._holder = item, holder
  -- ⚠ ANCHORED TO the icon, so contagion flows AWAY from Blizzard's frame.  Nothing is ever
  -- anchored to `fs` — it is a leaf on purpose (see the banner).
  --
  -- ⚠ OFFSET ABOVE THE ICON, not centred on it: Blizzard ALREADY draws its own stack count
  -- on these frames (`CooldownViewerBuffItemMixin:RefreshApplications`), so a centred number
  -- lands on top of theirs and the two are impossible to tell apart — which would make the
  -- cue read as "Blizzard's count just got bigger" rather than "the threshold was crossed".
  pcall(function()
    fs:ClearAllPoints()
    fs:SetPoint("BOTTOM", item, "TOP", 0, 2)
  end)
  stackFrames[t.key] = fs
  return fs
end

function L.StackRefresh()
  if not (ns.db and ns.db.curvelab_stack) then return end
  local out = {}
  for _, t in ipairs(STACK_TARGETS) do
    local rec = L.StackRead(t)
    out[t.key] = rec
    local fs = rec.state ~= "no-frame" and stackFontString(t, (L.FindAuraItem(t.spellID)))
    if fs then
      if rec.state == "ok" then
        -- THE ONE LINE THE WHOLE THING IS FOR.  The string is EMPTY below the threshold and
        -- the count at or above it, decided in C.  We never look at it.
        pcall(fs.SetText, fs, rec.value)
        fs:Show()
      else
        pcall(fs.SetText, fs, "")
        fs:Show()
      end
    end
  end
  L.stackLast = out
  return out
end

-- L.StackLocate(seconds) — SHOW ME WHERE IT DRAWS, without needing the aura or the
-- threshold.  The cue's whole signal is "text appeared", so "I saw nothing" has three
-- completely different causes — the threshold was never met, the aura was never up, or it is
-- drawing somewhere I am not looking — and only the third is a bug.  This separates them:
-- it puts a labelled marker on each target's item frame for a few seconds, live, using the
-- same anchor the real cue uses.  Draws even when the aura is DOWN, since the frame exists
-- either way.
function L.StackLocate(seconds)
  local shown = {}
  for _, t in ipairs(STACK_TARGETS) do
    local item, viewer = L.FindAuraItem(t.spellID)
    if item then
      local fs = stackFontString(t, item)
      -- A placeholder that is NOT a digit, so it can never be mistaken for a real reading.
      pcall(fs.SetText, fs, "▼" .. t.key)
      fs:Show()
      shown[#shown + 1] = string.format("%s -> %s", t.key, tostring(viewer))
    else
      shown[#shown + 1] = t.key .. " -> |cffff4040no frame|r"
    end
  end
  C_Timer.After(seconds or 10, function()
    for _, t in ipairs(STACK_TARGETS) do
      local fs = stackFrames[t.key]
      if fs then pcall(fs.SetText, fs, "") end
    end
    pcall(L.StackRefresh)     -- hand the real cue straight back
  end)
  return shown
end

function L.StackCue(on)
  ns.db = ns.db or {}
  ns.db.curvelab_stack = on and true or false
  if stackTicker then stackTicker:Cancel(); stackTicker = nil end
  if on then
    -- 5 Hz: stacks move fast on Demonology and the cue is the only signal.
    stackTicker = C_Timer.NewTicker(0.2, function() pcall(L.StackRefresh) end)
    L.StackRefresh()
  else
    for _, fs in pairs(stackFrames) do pcall(fs.SetText, fs, ""); fs:Hide() end
  end
end

-- `records` defaults to the last refresh, but is injectable so busted can read the readout
-- without driving a ticker — the `A.Lines` precedent.
function stackLines(records)
  local out = {}
  local last = records or L.stackLast or {}
  for _, t in ipairs(STACK_TARGETS) do
    local r = last[t.key] or {}
    out[#out + 1] = string.format("  %-14s %-16s >=%d   frame=%s  id=%s  text=%s  %s",
      t.key, t.label, t.min, tostring(r.viewer or "-"),
      tostring(r.idClass or "-"), tostring(r.textClass or "-"),
      tostring(r.state or "not sampled"))
    if r.state == "id-unreadable" then
      out[#out + 1] = "      |cffff4040item.auraInstanceID reads SECRET|r — the API is "
        .. "AllowedWhenUntainted, so it cannot be passed on. THE TECHNIQUE IS CLOSED for "
        .. "this aura, and that is a real finding, not a bug."
    elseif r.state == "no-frame" then
      out[#out + 1] = "      |cffffd100no CDM item frame carries this aura|r — is it tracked "
        .. "in the buff viewers on this spec/loadout?"
    end
  end
  return out
end

L.StackLines = stackLines

--------------------------------------------------------------------------------
-- The command.  Registered HERE rather than in Core.lua — CurveLab needs no later-loading
-- symbol at registration time (the AlertTape / Assist mould), and keeping the registration
-- inside the file being deleted is what makes the deletion diff ONE BLOCK.
--------------------------------------------------------------------------------
local function dumpRing()
  local ring = (ns.db and ns.db.curvelab) or {}
  ns.Heading("curve lab ring — one row per VERDICT change")
  if #ring == 0 then
    return ns.Print("  |cff808080empty|r — |cffffffff/cdmp curve watch|r to arm it "
      .. "(SavedVariables flush on /reload).")
  end
  for _, r in ipairs(ring) do
    local n = 0
    for _ in pairs(r.cells or {}) do n = n + 1 end
    ns.Printf("  %8.2f  %-6s  %d cell(s)%s", r.t, r.combat and "combat" or "ooc", n,
      r.halted and "  |cffff4040HALTED|r" or "")
  end
  ns.Printf("  %d row(s). |cffffd100/reload to flush|r, then: wowkb.cdmp curvelab", #ring)
end

ns.RegisterCommand("curve",
  "⚠ TEMPORARY curve / secret-display lab — which visual channels can carry a SECRET? "
  .. "bare = the one-shot matrix readout; 'card' covers the screen with live cells, "
  .. "'watch' arms a 1 Hz verdict-change sampler, 'off' stops it, 'dump' reads the ring, "
  .. "'clear' wipes it, 'spell <id>' aims the duration column, 'stack' arms the "
  .. "THRESHOLD CUE on a secret stack count (Wild Imps / Demonic Core).",
  function(rest)
    rest = (rest or ""):lower()
    local id = rest:match("^%s*spell%s+(%d+)")
    if id then
      L.spellOverride = tonumber(id)
      return ns.Printf("curve lab: duration column now asks about spellID %d (%s)",
        L.spellOverride, tostring(ns.SpellName(L.spellOverride) or "?"))
    end
    -- `stack` FIRST, because "stack off" must not be swallowed by the bare `off` branch.
    local stackArg = rest:match("^%s*stack%s*(.*)$")
    if stackArg then
      local key, n = stackArg:match("^(%a+)%s+(%d+)$")
      if key and n then
        local t = L.SetStackThreshold(key, tonumber(n))
        if not t then return ns.Printf("no stack target '%s' — try imps | core", key) end
        -- ⚠ SETTING A THRESHOLD ARMS THE CUE.  `StackRefresh` no-ops while disarmed, so
        -- `stack imps 1` on a cold cue used to change a number nobody was drawing and report
        -- success — a silent no-op in the one command you would reach for to prove the cue
        -- works at all.  Nobody sets a threshold on a cue they do not want on.
        local wasOff = not (ns.db and ns.db.curvelab_stack)
        if wasOff then L.StackCue(true) else L.StackRefresh() end
        return ns.Printf("stack cue: %s now fires at |cffffffff>= %d|r stacks%s",
          t.label, t.min, wasOff and "  (and the cue is now |cff88ff88ON|r)" or "")
      end
      if stackArg:find("locate") then
        L.StackCue(true)
        ns.Heading("stack cue — WHERE IT DRAWS (10 s, a ▼marker, not a reading)")
        for _, line in ipairs(L.StackLocate(10)) do ns.Printf("  %s", line) end
        return ns.Print("  |cff808080above the CDM buff frame for each aura. If you see no "
          .. "marker, it is not drawing where you are looking — which is a DIFFERENT problem "
          .. "from the threshold never being met.|r")
      end
      if stackArg:find("off") then
        L.StackCue(false)
        return ns.Print("stack cue |cffff8080OFF|r.")
      end
      if stackArg == "" or stackArg:find("on") then
        L.StackCue(true)
        ns.Heading("stack cue |cff88ff88ON|r — the threshold is compared IN C; we never read it")
        for _, line in ipairs(stackLines()) do ns.Print(line) end
        ns.Print("  |cff808080a NUMBER APPEARS on the icon at/above the threshold and "
          .. "NOTHING below it. That appearance IS the cue — the count is secret and no Lua "
          .. "here ever sees it.|r")
        return
      end
      ns.Heading("stack cue — a threshold cue on a SECRET stack count")
      for _, line in ipairs(stackLines()) do ns.Print(line) end
      return ns.Print("  |cffffd100/cdmp curve stack|r on | off | locate | imps <n> | core <n>")
    end
    if rest:find("clear") then
      ns.db.curvelab = {}
      return ns.Print("curve lab ring cleared.")
    end
    if rest:find("dump") then return dumpRing() end
    if rest:find("card") then
      if L.card and L.card:IsShown() then
        L.Card(false)
        return ns.Print("curve lab card |cffff8080hidden|r.")
      end
      L.Card(true)
      return ns.Print("curve lab card |cff88ff88up|r — |cff6688ccthe blue CONTROL rows are "
        .. "pinned at the top|r. Top moves + subject frozen = the channel is dead for "
        .. "secrets; both move = it works; NEITHER moves = the instrument is broken and "
        .. "the capture proves nothing.")
    end
    if rest:find("off") then
      L.Watch(false)
      return ns.Print("curve lab watch |cffff8080OFF|r.")
    end
    if rest:find("watch") then
      L.Watch(true)
      ns.Print("curve lab watch |cff88ff88ON|r — 1 Hz, recording only on a VERDICT "
        .. "change. Pull a dummy, then |cffffffff/reload|r and "
        .. "|cffffffffuv run python -m wowkb.cdmp curvelab|r.")
      -- ⚠ THE TWO TOGGLES ARE ORTHOGONAL, and the 2026-08-04 Demonology pass was lost to
      -- exactly that: `watch` was armed, `stack` was not, and the capture carried no STK
      -- rows at all.  A recorder that silently records nothing about the thing you went in
      -- to measure is the failure this whole project keeps re-learning.
      if not ns.db.curvelab_stack then
        ns.Print("  |cffffd100⚠ the STACK CUE is separate and currently OFF|r — if you came "
          .. "for the imp / Demonic Core threshold cue, also run "
          .. "|cffffffff/cdmp curve stack|r or the capture will carry no stack rows.")
      end
      return
    end
    local p = L.Probe()
    ns.Heading("curve / secret-display lab — verdicts, never values")
    for _, line in ipairs(L.Lines(p)) do ns.Print(line) end
    ns.Print("  |cff808080WORKED|r=the secret reached the channel · |cffffd100INERT|r=it was "
      .. "accepted and nothing flipped (LOOK AT THE CARD) · |cff6688ccUNSOURCED|r=no secret "
      .. "this sample, never a pass · |cffff4040POISONED|r=anchor contagion.")
  end)

-- Re-arm across a /reload if it was left on (the watch is the whole point of the ring).
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  if ns.db and ns.db.curvelab_on then L.Watch(true) end
  if ns.db and ns.db.curvelab_stack then L.StackCue(true) end
end
