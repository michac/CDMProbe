-- Coach.lua — Stage 2 of the W4 pipeline: State -> **Coach** -> Guidance.
--
-- THE CONTRACT — SINGLE TOP PRESS (guidance-contract.json).  At most ONE cue is the
-- "press now" call (ROTATION, or LATE when overdue): the rotation's #1 ready ability.
-- Everything else is decoration.  That makes the Coach a RANKED WINNER — an explicit
-- priority cascade, never a per-ability scorer, which structurally cannot produce one
-- winner because two abilities can independently score "press me".
--
-- THE SHAPE — five passes, and the split between the shell and the spec brain:
--   1. Classify  — PURE pass over the pulse -> a candidate record per ability
--      (pressable / napkin-probably-up / armed / overdue / transformed …).  A hard-CD
--      with an ELAPSED napkin is ROTATION-ELIGIBLE, not "never".            [SHELL]
--   2. Context   — the whole-board facts the cascade reads.                 [BRAIN]
--   3. RankWinner— the ordered cascade: exactly one winner + level.         [BRAIN]
--   4. Escalate  — ROTATION -> LATE only from READABLE overdue-ness.  A cooldown we
--      cannot read never goes LATE.                                        [BRAIN]
--   5. Emit      — a SEPARATE pass over what the winner did NOT claim: the
--      ROTATION_FALLBACK runner-up (winner pulled, list re-run) and the per-ability
--      SOON decoration, non-press BY CONSTRUCTION; plus resourceBars.       [SHELL]
--
-- PURE of frames, timers, and the live client — a FACTORY (Coach.New(cfg) / __index).
-- Everything volatile arrives in the `state` pulse (State.Build's shape).
-- Deterministic in -> out: that is what lets the Tier-1 branch-coverage specs
-- (coach_apl_spec / coach_destruction_apl_spec) arbitrate it as independent oracles,
-- authored from the rotation docs rather than from this code.
--
-- SPEC-AGNOSTIC.  This file is the generic SHELL; the rotation BRAIN (Context /
-- RankWinner / Escalate + the tunables) lives on the active spec object, attached by
-- Coach<Spec>.lua.  Compute reads ns.ActiveSpec and delegates; ActiveSpec == nil yields
-- EmptyGuidance (the passive-HUD contract).  A second spec is a sibling Coach<Spec>.lua
-- overriding the same three methods and nothing else.
--
-- THE BRAIN CONTRACT, stated ONCE here rather than re-stated in every Coach<Spec>.lua:
--   * `Context(state, env)` -> ctx + a facts index keyed by BASE spellID.  The Coach
--     decides in the domain view's vocabulary; cooldownID is transport the Binder owns
--     and never appears in the Coach's vocabulary.  `env` is the coach instance, which
--     carries `env.shardCostFn` (the injected live cost reader).
--   * `RankWinner(ctx, excluded)` -> winnerKey, level, note.  `excluded` is a BASE
--     spellID dropped at EVERY line that names it, so the shell can recompute the honest
--     SECOND place by re-running the list from the top — NOT by taking "the next line".
--     One base-keyed record per ability is what makes that a one-word exclusion.
--   * `Escalate(winnerKey, level, ctx)` -> level.  ROTATION -> LATE only from READABLE
--     overdue-ness; a bucket whose true gate is secret can never drive an escalation.
-- Each brain's own header documents only its DELTA from this.
local ADDON, ns = ...

ns.Coach = {}
local C = ns.Coach
C.__index = C

--------------------------------------------------------------------------------
-- Shell tunables (seconds).  The DECISION tunables (TCT_LEAD / LATE_LEAD / the power cap /
-- the HoG cost) belong to the spec brain now (CoachDemonology.lua); what stays here is
-- generic to the shell's own passes.
--------------------------------------------------------------------------------
local SOON_LEAD  = 3.0    -- a tracked cooldown anticipated within this => a dumb SOON
                         -- decoration (W4 Phase 8): "coming off cooldown", independent
                         -- of the winner/burst logic — NOT a press claim.  A generic
                         -- decoration lead (not asserted spec-specific), so it stays here.
local CAST_FRESH = 1.0    -- a history 'start' this fresh => the cast_started edge
local INFLIGHT_WINDOW = 3.0  -- a cast still plausibly IN FLIGHT this recently (~2 GCDs).
                             -- Distinct from CAST_FRESH, which answers a different question
                             -- ("is this the cast_started EDGE"), so do not merge them.

-- Pure SAFETY FALLBACKS for ResourceBars (multi-spec Phase 3).  The resource shape is now
-- an ARRAY the spec brain fills (ctx.powers, each entry carrying its own value/max/display/
-- powerType); these only backstop a spec that left max/token off an entry.  The Demo facts
-- (which power, its cap) live on the spec object now, not here.
-- ⚠ DISPLAY UNITS, and named so.  This was `SHARD_CAP` until Phase 6.2, when the decision
-- layer moved to FRAGMENTS (0–50) while the drawn bar stayed in whole shards (0–5) because
-- Renderer.lua pools one pip per unit of `max`.  A fallback that still read `SHARD_CAP`
-- beside a fragment-denominated brain is exactly the 10x confusion the rename prevents.
local BAR_MAX_FALLBACK = 5   -- max fallback, in DISPLAY units, when an entry omits it
local POWER_TOKEN = { SoulShards = "SOUL_SHARDS" }   -- Enum.PowerType name -> render token

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------
-- cfg (all optional):
--   powerCost  fn(spellID, powerType) -> cost   THE GENERAL live cost reader (ns.PowerCost).
--              Threaded to the brain's Context as env.powerCostFn.  The brain owns WHICH
--              spell it costs AND which resource to ask about; the shell owns the reader.
--   shardCost  fn(spellID) -> cost   the WARLOCK-LEGACY reader (ns.ShardCost), hardwired to
--              Soul Shards.  Threaded as env.shardCostFn.  Both Warlock brains still read
--              it; see the banner below before adding a third caller.
--
-- ⚠ WHY THERE ARE TWO, AND WHY `shardCost` IS THE ONE THAT IS WRONG.  `shardCost` was the
-- only cost seam until 2026-08-03, and `ns.ShardCost` filters to `Enum.PowerType.SoulShards`
-- — so it is not a cost reader, it is a *Warlock* cost reader wearing a generic name.  Every
-- spec outside Warlock asked it for a cost, got "no Soul Shard entry", and (with PowerCost's
-- old zero-for-absent contract) read that as FREE.  That is how Retribution shipped cueing a
-- 3-Holy-Power spender at 0 Holy Power.
--
-- The fix is not to widen `ShardCost` — a reader that guesses the resource is the original
-- defect (see ns.PowerCost's v0.10.0 banner: an unfiltered cost is a DIFFERENT RESOURCE
-- silently wearing the right units).  It is to make the resource an ARGUMENT, supplied by
-- the spec that knows it.  `powerCost` is that seam; `shardCost` survives only so the two
-- Warlock brains and their oracles stay untouched, and folding them onto `powerCost` +
-- `C.CostPowerType` is a mechanical follow-up, not a redesign.
function C.New(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, C)
  self.powerCostFn = cfg.powerCost
  self.shardCostFn = cfg.shardCost
  return self
end

-- Which resource does THIS spec's costs live in?  Resolved from the spec's OWN declared
-- `powers` block — the same declaration State builds the resource rail from — so a brain
-- never writes an `Enum.PowerType` literal and a new spec gets this for free by declaring
-- its power, which it must do anyway.
--
-- The rule: an entry explicitly flagged `costPower = true` wins; otherwise the first
-- declared power whose `name` resolves in `Enum.PowerType`.  The flag exists for the specs
-- already on the roadmap that declare TWO powers — Vengeance and Devourer carry Fury plus a
-- derived Soul-Fragment channel, and costs are denominated in Fury, which is not
-- necessarily the first entry.
--
-- Returns nil when nothing resolves (no Enum, no powers, an unknown name).  nil is a
-- REFUSAL and callers must fall back to their declared constant — never to "free".
function C.CostPowerType(spec)
  local pt = Enum and Enum.PowerType
  if not pt or not spec or type(spec.powers) ~= "table" then return nil end
  local first
  for _, p in ipairs(spec.powers) do
    if type(p) == "table" and type(p.name) == "string" then
      local v = pt[p.name]
      if type(v) == "number" then
        if p.costPower then return v end
        if first == nil then first = v end
      end
    end
  end
  return first
end

--------------------------------------------------------------------------------
-- Small readers over the pulse (never mutate it; never read anything secret — the
-- pulse already passed State's readable/Stash gate, so every value here is honest)
--------------------------------------------------------------------------------
local function num(v) return type(v) == "number" and v or nil end

-- Has `base` been COMMITTED within `window` — a cast STARTED or SUCCEEDED?  The burst
-- walk advances on the cast-start edge (the "next move" rule: the instant a demon is
-- committed, move to the next step), so it must not wait for the landed `succeeded`.
-- EXPOSED (Phase 2) as ns.Coach.CommittedWithin: the Demo brain's Context reads it (the
-- staging walk), so it is public shell kit rather than a file-local.
function C.CommittedWithin(state, base, window)
  local now = state.at or 0
  local hist = state.history or {}
  for i = 1, #hist do
    local h = hist[i]
    if (h.phase == "start" or h.phase == "succeeded") and (h.base == base or h.spellID == base) then
      if num(h.at) and (now - h.at) <= window then return true end
    end
  end
  return false
end

-- Net power delta of the casts currently IN FLIGHT: a 'start' with no later 'succeeded'
-- or 'stopped' for the same base, inside the flight window.  PURE over the pulse — this
-- is roster-state-plan Phase 6, which moved the projection out of State.lua (where it
-- dragged `ns.SpecPowerDelta` and both `Enum.PowerType.SoulShards` hardwires into the
-- INGESTION layer) and into the layer that already decides things and is fixture-tested.
--
-- Returns a MAP `powerName -> total`, so a dual-resource spec accumulates each cast onto
-- its OWN named power.  A single-power spec (Demo/Destro) gets the one SoulShards key.
-- The SIGN is the whole point: a builder credits (+), an in-flight spender subtracts
-- (−cost), so the brain ranking on projected = value + incoming clears the spender it is
-- mid-cast on instead of re-cuing it.
--
-- `deltaFn` (in practice `ns.SpecPowerDelta`) is PASSED IN rather than reached for, so the
-- helper stays testable and the spec global is not a hidden dependency.  It returns
-- `{ power, delta }` per base spellID; a nil power or zero delta contributes nothing.
--
-- ⚠ THE DOUBLE-DEDUCTION GUARD IS DELIBERATELY GONE (Phase 6; roster-state-plan §7).  The
-- old State version snapshotted live UnitPower at UNIT_SPELLCAST_START and dropped a
-- spender's −delta once the live value fell below it.  A pure function of the pulse has no
-- `before` value to diff against, and the accepted cost is a stale −N for at most ONE ~10 Hz
-- tick at completion — 'succeeded' supersedes the 'start' on the very next pulse, and often
-- lands before a Build even runs.  Deleting it also removed two latent defects rather than
-- porting them: the snapshot LEAKED whenever the terminal event's spellID read secret (the
-- map entry survived into the next cast of that spender and under-projected for a full
-- flight window), and the comparison was already wrong for a multi-power spec by its own
-- admission.  Do not "fix" this back without reading §7 first.
--
-- EXPOSED as ns.Coach.InflightPower — public shell kit, like C.CommittedWithin: both spec
-- brains read it from their Context.
function C.InflightPower(state, deltaFn, window)
  local sums = {}
  if not deltaFn then return sums end
  local now = state.at or 0
  local hist = state.history or {}
  -- Latest phase per base within the flight window (a fresh 'start' is still in flight; a
  -- 'succeeded'/'stopped' supersedes it and stops it counting).
  local latest = {}
  for i = 1, #hist do
    local h = hist[i]
    local id = h.base or h.spellID
    if num(id) and num(h.at) and (now - h.at) <= (window or INFLIGHT_WINDOW) then
      local prev = latest[id]
      if not prev or h.at >= prev.at then latest[id] = { phase = h.phase, at = h.at } end
    end
  end
  for id, e in pairs(latest) do
    if e.phase == "start" then
      local r = deltaFn(id)
      local p, d = r and r.power, r and r.delta
      if p and num(d) and d ~= 0 then sums[p] = (sums[p] or 0) + d end
    end
  end
  return sums
end

--------------------------------------------------------------------------------
-- ns.Coach.Advance — THE ONE-GCD LOOK-AHEAD (2026-08-03)
--------------------------------------------------------------------------------
-- WHAT IT IS.  A PURE `(state, winnerKey, lead) -> state2` that answers *"what does the
-- board look like one global cooldown from now, assuming the player presses the winner?"*
-- The shell then runs the spec's own Context + RankWinner over `state2`, so the look-ahead
-- is computed by THE SAME CASCADE that picked the winner — no second rotation model, no
-- per-spec knowledge in here.
--
-- WHY IT REPLACED THE RUNNER-UP.  `ROTATION_FALLBACK` used to be "re-run the list with the
-- winner's ability excluded" — a SUBSTITUTE at the same instant ("if I'm wrong, press this")
-- rather than a SEQUENCE.  On a fast spec the more useful hint is what comes NEXT, because
-- it tells you what to be ready for rather than hedging a call the list already made.
-- Decided 2026-08-03; guidance-contract.json's emphasis vocabulary carries the ruling.
--
-- ⚠⚠ WHAT IT DELIBERATELY DOES **NOT** MODEL, and this is the honesty boundary:
--   * RESOURCES.  Fury is a SECRET VALUE and most specs' primary resource is (see
--     ns.SpellUsable).  There is no readable number to decrement, so `power`, and every
--     affordability verdict riding `abilities[*].usable`, pass through UNTOUCHED.  The
--     look-ahead therefore assumes you can still afford whatever you can afford now.  That
--     is wrong immediately after a spend — and it is the LEAST-WRONG option available,
--     because the alternative is a fabricated number, which is the exact bug class that
--     failed the 2026-08-03 Havoc flight.
--   * BUFFS AND CAST HISTORY.  A press that would open a window (Metamorphosis -> demon
--     form, Vengeful Retreat -> Initiative, Essence Break -> its window) does not flip it
--     here.  Modelling that means per-spec knowledge in shell kit; it is a deliberate
--     follow-up, not an oversight.  Consequence: the look-ahead under-predicts the burst
--     lines, i.e. it fails toward showing the STEADY-STATE next press.
--   * `state.at`.  NOT advanced, on purpose.  Rolling the clock would age every napkin,
--     every dot timer and every history window by a GCD as a side effect of asking one
--     question about cooldowns.  Only `cd.remaining` moves.
--
-- ⚠ AND THE INVARIANT THAT MAKES THE PREDICTION SAFE: a cooldown crossing zero here is
-- marked `state = "ready"` with `source = "lookahead"`, which is a CLAIM, not an
-- observation.  It may only ever reach the NEXT cue — never the press-now cue, which is
-- still ranked off the real pulse.  `source` names the provenance so the decision log and
-- any future consumer can tell a predicted readiness from a measured one.
local LOOKAHEAD_LEAD = 1.0   -- seconds.  See the note below.

-- ⚠ A CONSTANT, BECAUSE THE PULSE CARRIES NO GCD.  `ns.ReadGCD` is COMBAT-GATED (its read
-- is secret in restricted combat), so the one number this wants is unavailable exactly when
-- it is wanted.  1.0 s sits between the 1.5 s unhasted global and the ~0.86 s a geared Havoc
-- actually runs at (MEASURED: the median Felblade-after-Vengeful-Retreat gap across seven
-- top-100 Mythic parses, WCL 12.0.7).  A spec may override with `spec.LOOKAHEAD_LEAD`.
-- Being wrong by ±0.2 s only shifts WHICH near-ready ability the hint names, never whether
-- the press-now cue is right.
local function shallow(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

-- The winner's own cooldown AFTER pressing it.  The declared `baseCD`/`chargeCD` is the
-- source, NOT a client read: this runs per tick and `ns.BaseCooldown` is a guarded call, and
-- more importantly the declared number is the one the spec author reasoned about.
-- ⚠ NO DECLARED COOLDOWN MEANS IT STAYS READY, and that is correct rather than a gap —
-- Chaos Strike genuinely has none, so "press it again" is the true answer and the cue
-- carries `next` on the SAME icon (the double-tap hint).
local function spentCd(row, base, lead)
  local info = ns.SpecInfo and ns.SpecInfo(base) or nil
  local len = info and (num(info.baseCD) or num(info.chargeCD)) or nil
  local ch = row.charge or {}
  local cur = num(ch.cur)
  -- A banked charge survives the press: still pressable next GCD.
  if cur ~= nil and cur - 1 >= 1 then return row.cd end
  if not len or len <= 0 then return row.cd end          -- no cooldown -> unchanged
  return { state = "on-cooldown", remaining = math.max(len - lead, 0),
           readable = false, source = "lookahead", changedAt = (row.cd or {}).changedAt }
end

local function spentCharge(ch)
  if not ch then return ch end
  local cur = num(ch.cur)
  if cur == nil then return ch end
  local o = shallow(ch)
  o.cur = math.max(cur - 1, 0)
  return o
end

-- Everything the player did NOT press simply gets one GCD closer to ready.
local function advancedCd(cd, lead)
  if type(cd) ~= "table" then return cd end
  if cd.state ~= "on-cooldown" then return cd end        -- ready / unknown pass through
  local r = num(cd.remaining)
  if r == nil then return cd end
  local left = r - lead
  if left > 0 then
    local o = shallow(cd); o.remaining = left; return o
  end
  -- Crossed zero: a PREDICTION, labelled as one.
  return { state = "ready", remaining = 0, readable = false, source = "lookahead",
           changedAt = cd.changedAt }
end

function C.Advance(state, winnerKey, lead)
  lead = num(lead) or LOOKAHEAD_LEAD
  local src = state.abilities or {}
  local out = {}
  for id, row in pairs(src) do
    local nrow = shallow(row)
    if id == winnerKey then
      nrow.cd = spentCd(row, id, lead)
      nrow.charge = spentCharge(row.charge)
    else
      nrow.cd = advancedCd(row.cd, lead)
    end
    out[id] = nrow
  end
  local s2 = shallow(state)
  s2.abilities = out
  return s2
end

-- Truncate TOWARD ZERO.  Used only to render an EXACT-unit projection back into the DISPLAY
-- units a pip bar speaks — never in a gate (gates compare exact integers), so this is the
-- only place a division reaches.  Toward-zero is the honest direction for both signs: a
-- partial shard gained is not yet a shard, and one spent is not yet spent.
local function truncToward(x)
  if x >= 0 then return math.floor(x) end
  return -math.floor(-x)
end

-- ns.Coach.PowerContext — THE PER-POWER RAIL, hoisted out of the two brains.
--
-- WHY IT IS HERE.  Both Warlock brains opened Context with a byte-identical ~15-line block
-- (the exact-rail read, the modifier fallback ladder, `truncToward`, and the whole
-- `ctx.powers` fold) and docs/status.md filed it with the trigger stated: *"A third spec is
-- when this stops being cosmetic."*  Five arrived at once.  It joins C.CommittedWithin and
-- C.InflightPower as public shell kit: a PURE fold of the pulse a brain reads from its own
-- Context, not something the shell does to it.
--
-- WHAT CHANGED IN THE HOIST — the Soul-Shard vocabulary is gone.  The brains' block was
-- written for ONE power and named for it (`frags` / `fragsMax` / `FRAGS_PER_SHARD`), which
-- is why it could not be shared: a Fury or Holy Power spec cannot read `fragsProjected`.
-- Both rails are keyed BY POWER NAME now, and every fallback that was a spec-object
-- constant moved onto the `spec.powers[]` entry that owns it (`modifier` / `exactMax` /
-- `barMax`), which is where a per-power fact belongs.  A brain that wants scalars still
-- publishes them under its own names — the naming stays the BRAIN's, only the arithmetic
-- is shared.
--
-- RETURNS `bars, rails`:
--   `bars`  — the ARRAY the shell's ResourceBars emits from, in DISPLAY units, one entry per
--             declared power in declaration order.  ⚠ `valueExact`/`maxExact` here are
--             MEASUREMENTS: the raw client read, ABSENT (never derived, never zero) when it
--             refused.  That is deliberately NOT the same number as `rails[].value` below.
--   `rails` — a MAP `powerName -> { value, incoming, max, projected, modifier, readable,
--             atCap }` in the game's EXACT internal units, which is what gates compare.
--             `value` here DOES fall back to `display x modifier` when the exact read
--             refuses — coarse but never wrong in units — because a gate needs a number and
--             a bar needs the truth about whether we measured one.  Absent stays nil.
--
-- ⚠ THE TWO UNITS ARE THE WHOLE POINT (Phase 6.2), so read `unitsNote` in
-- guidance-contract.json before collapsing them.  `bars` is display units because
-- Renderer.lua pools one pip per unit of `max`; `rails` is exact units because a boundary
-- comparison decided by a float is the bug that phase existed to remove.
--
-- `sums` is C.InflightPower's per-power map, PASSED IN for the same reason `deltaFn` is:
-- the caller already computed it and a hidden second call would be a silent second opinion.
function C.PowerContext(state, spec, sums)
  local bars, rails = {}, {}
  sums = sums or {}
  local power = state.power or {}
  for _, p in ipairs((spec and spec.powers) or {}) do
    local pw = power[p.name] or {}
    -- The divisor between the EXACT units the spec's SpecPowerDelta speaks and the DISPLAY
    -- units the bar renders in.  Live client read first; `p.modifier` is the spec's declared
    -- fallback for when it refuses.  A power with no divisor omits it entirely => 1, which
    -- is every power in the game except Soul Shards.
    local mod = num(pw.modifier) or num(p.modifier) or 1

    -- The MEASUREMENTS, kept separate from the fallbacks below.
    local exactValue, exactMax = num(pw.unmodified), num(pw.unmodifiedMax)

    -- The GATE rail.  Falls back to the display value scaled up when the exact read refused
    -- — coarse (a true 1.9 arrives as 10) but never wrong in units.  nil stays nil: absence
    -- of a read must never become "you have none".
    local value = exactValue
    if value == nil then
      local v = num(pw.value)
      value = v and (v * mod) or nil
    end
    local maxValue = exactMax
      or (num(pw.max) and num(pw.max) * mod)
      or num(p.exactMax)
    local incoming = (p.incoming and num(sums[p.name])) or 0
    local projected = value and (value + incoming) or nil

    rails[p.name] = {
      value = value, incoming = incoming, max = maxValue, projected = projected,
      modifier = mod,
      -- `readable` is the TRUST annotation, not the presence test: the client said the
      -- power is readable AND we came away with a number.
      readable = (pw.readable ~= false) and value ~= nil,
      -- STRUCTURALLY unreadable — a PRIMARY resource, secret forever (State's readOnePower
      -- asks C_Secrets).  Distinct from `readable == false`, which only says this pulse
      -- came away empty.  A brain must never wait for a restricted rail to warm up.
      restricted = pw.restricted == true,
      atCap = (projected ~= nil and maxValue ~= nil and projected >= maxValue) or false,
    }

    bars[#bars + 1] = {
      value     = num(pw.value),
      max       = num(pw.max) or num(p.barMax),
      -- `p.incoming` is the spec-declared "this bar shows a projection" flag.  `sums` is in
      -- EXACT units, so the display half is scaled DOWN and truncated toward zero.
      incoming  = truncToward(incoming / mod),
      display   = p.display or "discrete",
      powerType = p.token,
      -- ⚠ MEASUREMENTS, absent rather than derived — see the header.  A consumer must be
      -- able to tell "the client refused" from "we scaled the display value for you".
      valueExact    = exactValue,
      maxExact      = exactMax,
      incomingExact = incoming,
      modifier      = mod,
      -- Rides the bar as well as the rail, because the DECISION LOG reads the bar and
      -- "why is this column empty" is a question only this field can answer.
      restricted    = pw.restricted == true,
    }
  end
  return bars, rails
end

-- The MOST RECENT in-flight start for `base` with no later succeeded, if fresh.
local function castingFresh(state, base)
  local now = state.at or 0
  local hist = state.history or {}
  local startAt, resolved
  for i = 1, #hist do
    local h = hist[i]
    if (h.base == base or h.spellID == base) and num(h.at) then
      if h.phase == "start" then startAt, resolved = h.at, false
      elseif h.phase == "succeeded" then resolved = true end
    end
  end
  if startAt and not resolved and (now - startAt) <= CAST_FRESH then return true end
  return false
end

-- A SUCCEEDED cast of `base` that landed on THIS pulse (at == pulse at) — the
-- cast_ended edge.
local function landedThisPulse(state, base)
  local now = state.at or 0
  local hist = state.history or {}
  for i = 1, #hist do
    local h = hist[i]
    if h.phase == "succeeded" and (h.base == base or h.spellID == base)
        and num(h.at) and h.at == now then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- 1. Classify — the per-cooldown candidate record.  Owns the "probably-up is
--    PRESSABLE" semantics.  Auras are inputs, never scored (return nil).
--------------------------------------------------------------------------------
function C.Classify(cd, state)
  -- `identity` is State's display-keyed identity (ns.DisplayIdentity) — the spell the row
  -- actually SHOWS, which for a display-overridden row is not `spellID`.  The record must
  -- key on it or the brain's `facts[<ability>]` lookups miss: on Diabolist the Incinerate
  -- row's own spellID is Shadow Bolt 686, and keying there made the Incinerate line
  -- unreachable.  Falls back to `spellID` for virtual rows and for every fixture written
  -- before the field existed.
  local base = num(cd.identity) or num(cd.spellID)
  local live = num(cd.liveSpellID) or base
  local info = ns.SpecInfo(live)
  if not info or info.kind == "aura" then return nil end

  ------------------------------------------------------------------------------
  -- KNOWNNESS — roster-state-plan Phase 5 §6.1, and the ONLY Coach edit the phase needs
  ------------------------------------------------------------------------------
  -- State stopped FILTERING on knownness and started MARKING with it: every declared
  -- ability is in `abilities` now, carrying `known = true | false | nil`, so the decision
  -- about what an unlearned or unreadable ability may do is made HERE, once, for all three
  -- brains.  Two rules, and they are not the same rule:
  --
  --   * `false` — the client says the character does not have this spell.  NEVER a
  --     candidate: return nil, exactly as an aura row does two lines up.  This is what
  --     killed the 216-dropped-Soul-Fire-cues bug and it has to keep killing it.
  --   * `"unknown"` — we could not find out (a refused `IsSpellKnown`, a load-order race,
  --     the cache window).  ⚠ IT IS THE STRING, NOT `nil`, and that is deliberate: `nil`
  --     has to keep meaning "nobody asked" so a hand-built fixture pulse (and any consumer
  --     written before this field existed) is unaffected, while "we asked and came away
  --     with nothing" is a positive, greppable value.  The row STAYS: it is in `ctx.facts`,
  --     in the decision log and in
  --     Coverage.  It simply may not WIN or be the runner-up, which — read against
  --     `guidance-contract.json`, where AVAILABLE is "off cooldown but not a call, no cue"
  --     — is the same pixels as "cap at available".  Zeroing the three readiness flags is
  --     the whole implementation: `usable()` in both brains needs `probablyUp` or a banked
  --     charge, `Emit`'s fallback needs a castable rec, and SOON needs `anticipated`.
  --
  -- ⚠ AND THE WHOLESALE GUARD OVERRIDES BOTH.  `state.knownReadable == false` means NOT ONE
  -- declared ability answered — a broken read, not a bare character — so knownness is
  -- ignored entirely rather than barring the whole roster at once (§6.1).
  --
  -- ⚠ NOT AN EMPHASIS TOKEN.  "Cap at available and say why" is tempting to render, but the
  -- channel that would carry it (`judgeable`/`secretGate` -> the JUDGE token) was retired in
  -- W4 Phase 8 and reviving it is its own contract change, filed in status.md.  The "why"
  -- lands in the DECISION LOG's `DR:` field, which is where `pulse.dropped` used to say it.
  local ignoreKnown = (state.knownReadable == false)
  if not ignoreKnown and cd.known == false then return nil end

  local c = cd.cd or {}
  local g = cd.glow or {}
  local now = state.at or 0

  local rec = {
    cid  = cd.cooldownID,          -- carried for reference; the cue key is the map key
    base = base,
    live = live,
    info = info,
    reasons = {},                  -- the "auditable, not an oracle" contract
  }

  -- Cooldown state, derived off the 3-state contract (W4 Phase 7): state is
  -- ready | on-cooldown | unknown, `source` a trust annotation on `remaining`.
  --   ready       — observed up (OOC baseline / an Available edge): a hard press.
  --   probablyUp  — ready, OR on-cooldown with the napkin estimate exhausted
  --                 (remaining <= 0, source napkin): ROTATION-eligible.
  --   anticipated — on-cooldown with a positive remaining: SOON when within the lead.
  rec.ready       = (c.state == "ready") or false
  rec.onCd        = (c.state == "on-cooldown") or false
  rec.remaining   = num(c.remaining)
  rec.probablyUp  = rec.ready
    or (rec.onCd and c.source == "napkin" and (rec.remaining or 0) <= 0)
    or false
  rec.anticipated = (rec.onCd and (rec.remaining or 0) > 0) or false
  rec.cdChangedAt = num(c.changedAt)
  rec.cdSource    = c.source

  -- Armed proc / transform.  GENERIC in the shell: a live override (live ~= base) is a
  -- transform.  The spec-specific meaning of that override (Demo: `spends == "art"` IS the
  -- Demonic Art — Ruination on the HoG frame, Infernal Bolt on the SB frame) is re-applied
  -- by the spec brain's Context, which owns the filter.  `glow` is State's own
  -- combat-readable proc-highlight.
  rec.transformed = (live ~= base) or false
  rec.glowActive  = (g.active and g.readable ~= false) or false
  rec.glowChangedAt = num(g.changedAt)

  -- overdue — a probably-up press that has SAT elapsed past the lead (readable off
  -- cd.changedAt).  Only meaningful for the winner (Escalate drives the clock).  The lead
  -- is the ACTIVE spec's LATE_LEAD (Demo = 4.0); no active spec -> a neutral 4.0 default.
  local lead = (ns.ActiveSpec and ns.ActiveSpec.LATE_LEAD) or 4.0
  rec.overdue = rec.probablyUp and rec.cdChangedAt
    and (now - rec.cdChangedAt) >= lead or false

  -- THE CAP (see the knownness block above).  Applied LAST, over the finished record, so
  -- there is exactly one place an unreadable knownness can leak from — and so the record
  -- still carries its honest `remaining` / `cdSource` / `glowActive` for the trace.
  if not ignoreKnown and cd.known == "unknown" then
    rec.knownUnknown = true
    rec.ready, rec.probablyUp, rec.anticipated, rec.overdue = false, false, false, false
  end

  return rec
end

--------------------------------------------------------------------------------
-- The transient EDGE for a drawn cue (proc / ready / cast_started / cast_ended),
-- each justified by a "this pulse" marker in State.  Steady-state carries none.
--------------------------------------------------------------------------------
local function transientFor(state, rec)
  if not rec then return nil end
  local now = state.at or 0
  if landedThisPulse(state, rec.base) then return "cast_ended" end
  if castingFresh(state, rec.base) then return "cast_started" end
  if rec.glowActive and rec.glowChangedAt == now then return "proc" end
  if rec.probablyUp and rec.cdChangedAt == now then return "ready" end
  return nil
end

--------------------------------------------------------------------------------
-- 5. Emit — the full Guidance object.  A SEPARATE pass over the NON-winner
--    abilities, so the fallback (ROTATION_FALLBACK) and SOON are non-press by
--    construction and coexist with the one press; plus resourceBars.
--------------------------------------------------------------------------------
-- `nextKey`/`nextNote` — THE LOOK-AHEAD (2026-08-03): what the SAME cascade picks one GCD
-- from now, ranked over `ns.Coach.Advance(state, winnerKey)`.  It REPLACED the runner-up
-- (`RankWinner(ctx, winnerKey)` — "what would I press instead"); see C.Advance's banner for
-- why, and for what the model deliberately does not simulate.
--
-- ⚠ WHEN IT LANDS ON THE WINNER'S OWN ABILITY it is NOT emitted as a second cue — the
-- winner's cue carries `next = true` instead, and the Renderer draws a companion dot on the
-- same icon.  That is the DOUBLE-TAP hint, and it is the common case on this pipeline's
-- fastest spec: Chaos Strike has no cooldown at all and won 35 % of a real flight, so a
-- second dot on one icon says "press it twice" where a second icon would have to lie.
function C:Emit(state, ctx, winnerKey, level, winnerNote, nextKey, nextNote)
  local cues = {}

  local function put(k, emphasis, note)
    if not k then return end
    local rec = ctx.facts[k]
    cues[k] = { draw = true, emphasis = emphasis, note = note,
                transient = transientFor(state, rec) }
  end

  -- The one press.
  if winnerKey then put(winnerKey, level, winnerNote) end

  -- THE LOOK-AHEAD.  Two shapes, and the difference is the whole feature:
  --   * a DIFFERENT ability -> its own cue, emphasis ROTATION_FALLBACK ("press this next").
  --   * the SAME ability    -> no second cue; the winner's own cue is flagged `next`, and
  --                            the Renderer draws a companion dot on that one icon.
  -- ⚠ `next` RIDES THE EXISTING CUE rather than becoming a second entry keyed on the same
  -- ability, because `cues` is keyed BY BASE SPELLID — a second entry would overwrite the
  -- first and the press-now emphasis would be lost.  The Binder and Renderer are keyed by
  -- ICON for the same reason; see Renderer:drawCues.
  if nextKey and nextKey == winnerKey then
    if cues[winnerKey] then cues[winnerKey].next = true end
  elseif nextKey and not cues[nextKey] then
    put(nextKey, "ROTATION_FALLBACK", nextNote)
  end

  -- SOON — a DUMB per-ability "coming off cooldown" decoration (W4 Phase 8): any tracked
  -- damage cooldown (not a utility, not an aura) anticipated within the lead lights SOON,
  -- independent of the winner/burst logic.  Multiple abilities may show SOON.  Skips
  -- anything the press/fallback already claimed and never overrides a real press.
  for k, rec in pairs(ctx.facts) do
    if k ~= winnerKey and not cues[k]
        and rec.anticipated and rec.remaining and rec.remaining <= SOON_LEAD
        and rec.info and rec.info.cadence ~= "utility" then
      put(k, "SOON")
    end
  end

  return {
    resourceBars = self:ResourceBars(ctx),
    cues = cues,
    sequence = self:Sequence(state, ctx),
  }
end

--------------------------------------------------------------------------------
-- resourceBars — the ARRAY of power meters (multi-spec Phase 3).  Generic pass-through
-- of ctx.powers (the spec brain's Context fills it off spec.powers × state.power): one
-- entry per declared power, each carrying value + max + the in-flight incoming projection
-- + its display token + render powerType.  A single-power spec (Demo) yields a one-element
-- array — the same shard meter as before.  The shell owns only the safety fallbacks.
--
-- ⚠ TWO UNITS, DELIBERATELY (Phase 6.2).  `value`/`max`/`incoming` stay in DISPLAY units
-- because `Renderer.lua:drawResourceRow` pools one pip texture per unit of `max` — a `max`
-- of 50 would try to draw fifty pips.  The EXACT rail rides ALONGSIDE as
-- `valueExact`/`maxExact`/`incomingExact` plus the `modifier` that relates them: ADDITIVE
-- and optional, ABSENT when the client refused the exact read rather than zero.
--
-- The exact fields are INTEGERS in the game's internal units (Soul Shards: 0–50 fragments,
-- `modifier` 10) — NOT pre-divided floats.  Dividing is the CONSUMER's job, at the edge:
-- DecisionLog's `PW:` renders `valueExact / modifier` as `1.8`, and a future partial-fill
-- pip renderer would do the same.  Keeping the transport integral is the whole reason a
-- boundary comparison upstream can never be decided by a float.
-- See guidance-contract.json -> channels/resourceBars.
--------------------------------------------------------------------------------
-- ⚠⚠ `value` AND `incoming` PASS `nil` THROUGH, AND THAT IS THE 2026-08-03 FIX.  They read
-- `p.value or 0` / `p.incoming or 0` until the Havoc flight, and those two `or 0`s are what
-- turned "we could not read the rail" into "you have zero Fury" — the project's own
-- ABSENT-IS-NEVER-ZERO rule broken in the one place nothing tested.  Zero is the worst
-- possible degradation for a resource: every spender becomes unaffordable and every
-- generator maximally urgent, which is precisely the winner distribution the flight
-- produced (Chaos Strike 0 presses, Throw Glaive 770).
--
-- Note the exact rail three lines down already passed absence through VERBATIM.  The
-- inconsistency between the two halves of this one table literal WAS the bug; the exact
-- rail's shape is the one to copy, not the display rail's.
--
-- ⚠ `max` (BAR_MAX_FALLBACK) and `powerType` DELIBERATELY KEEP THEIR FALLBACKS.  A missing
-- max or token is a SPEC-AUTHORING gap, not a measurement — the Renderer needs a number to
-- size a bar and a token to colour it, and there is nothing dishonest about defaulting a
-- constant nobody measured.  `value` is a measurement.  The two are not the same kind of
-- field and must not get the same treatment.
function C:ResourceBars(ctx)
  local out = {}
  for _, p in ipairs((ctx and ctx.powers) or {}) do
    out[#out + 1] = {
      value = p.value,
      max = p.max or BAR_MAX_FALLBACK,
      incoming = p.incoming,
      display = p.display or "discrete",
      powerType = p.powerType or POWER_TOKEN.SoulShards or "SOUL_SHARDS",
      -- The exact rail, passed through VERBATIM — including its absence.
      valueExact = p.valueExact,
      maxExact = p.maxExact,
      incomingExact = p.incomingExact,
      modifier = p.modifier,
      restricted = p.restricted,
    }
  end
  return out
end

--------------------------------------------------------------------------------
-- sequence — RETIRED at the TCT redesign (docs/archive/w4-phase6-tct-redesign.md).  The
-- one-press-at-a-time cue walk replaced the opener panel, so the Coach never emits one.
-- The contract field stays (show:false) for the Binder/Renderer.
--------------------------------------------------------------------------------
function C:Sequence(_state, _ctx)
  return { show = false }
end

--------------------------------------------------------------------------------
-- EmptyGuidance — the passive HUD (Phase-1 unsupported-spec contract).  When no spec is
-- active (ns.ActiveSpec == nil, e.g. a spec with no profile), Compute returns this: no
-- cues, an EMPTY resourceBars array, no sequence.  Demo is always active in-game, so this
-- is correctness insurance, not a visible path yet (Phase 5 builds the "no profile" UX on it).
--------------------------------------------------------------------------------
function C:EmptyGuidance()
  return {
    cues = {},
    resourceBars = {},
    sequence = { show = false },
  }
end

--------------------------------------------------------------------------------
-- Compute — the one public entry.  State pulse in, Guidance out.  Pure ORCHESTRATION
-- (Phase 2): the shell delegates the DECISION to the active spec brain (Context /
-- RankWinner / Escalate on ns.ActiveSpec) and owns only the Emit assembly.
--------------------------------------------------------------------------------
function C:Compute(state)
  local spec = ns.ActiveSpec
  if not spec then return self:EmptyGuidance() end   -- unsupported spec -> passive HUD
  -- `self` is the env the brain's Context reads (env.shardCostFn = the injected cost reader).
  local ctx = spec:Context(state, self)
  local winnerKey, level, note = spec:RankWinner(ctx)
  level = spec:Escalate(winnerKey, level, ctx)

  -- THE LOOK-AHEAD (2026-08-03).  Advance the board one GCD as if the player pressed the
  -- winner, then ask the SAME cascade what it picks — so the hint is "what comes next",
  -- not "what would I press instead".
  --
  -- ⚠ IT RUNS THE SPEC'S OWN `Context` OVER THE ADVANCED STATE rather than mutating `ctx`.
  -- `ctx` is the brain's private fold and carries derived facts (`usable()` verdicts, the
  -- SOON handshakes, the transforms) that a shell-side edit could not keep consistent —
  -- re-folding is the only way the second answer is computed by the same rules as the
  -- first.  Cost is one extra Context + RankWinner per tick over a small table; the shell
  -- already ran RankWinner twice for the runner-up it replaced.
  --
  -- ⚠ THE WINNER IS **NOT** EXCLUDED from the re-rank, deliberately.  An ability with no
  -- cooldown is genuinely the next press too, and saying so is the point — see Emit.
  local nextKey, nextNote
  if winnerKey then
    local ok, s2 = pcall(C.Advance, state, winnerKey, spec.LOOKAHEAD_LEAD)
    if ok and s2 then
      local ok2, k, _, nt = pcall(function()
        local c2 = spec:Context(s2, self)
        return spec:RankWinner(c2)
      end)
      -- ⚠ GUARDED, AND THE FAILURE MODE IS SILENCE.  A brain that throws on a hypothetical
      -- board must not take the PRESS-NOW cue down with it: the look-ahead is a decoration
      -- and the press is the product.  A refusal simply emits no next cue.
      if ok2 then nextKey, nextNote = k, nt end
    end
  end
  return self:Emit(state, ctx, winnerKey, level, note, nextKey, nextNote)
end
