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
-- Shell tunables (seconds / shards).  The DECISION tunables (TCT_LEAD / LATE_LEAD /
-- SHARD_CAP / HoG cost) belong to the spec brain now (CoachDemonology.lua); what stays
-- here is generic to the shell's own passes.
--------------------------------------------------------------------------------
local SOON_LEAD  = 3.0    -- a tracked cooldown anticipated within this => a dumb SOON
                         -- decoration (W4 Phase 8): "coming off cooldown", independent
                         -- of the winner/burst logic — NOT a press claim.  A generic
                         -- decoration lead (not asserted spec-specific), so it stays here.
local CAST_FRESH = 1.0    -- a history 'start' this fresh => the cast_started edge

-- Pure SAFETY FALLBACKS for ResourceBars (multi-spec Phase 3).  The resource shape is now
-- an ARRAY the spec brain fills (ctx.powers, each entry carrying its own value/max/display/
-- powerType); these only backstop a spec that left max/token off an entry.  The Demo facts
-- (which power, its cap) live on the spec object now, not here.
local SHARD_CAP   = 5     -- max fallback when a power entry omits it
local POWER_TOKEN = { SoulShards = "SOUL_SHARDS" }   -- Enum.PowerType name -> render token

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------
-- cfg (all optional):
--   shardCost  fn(spellID) -> cost   the LIVE cost reader (ns.ShardCost) when wired;
--              nil in the golden harness, where the spec's fallback answers.  The shell
--              owns the INJECTED reader (threaded to the brain's Context as env.shardCostFn);
--              the brain owns WHICH spell it costs.
function C.New(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, C)
  self.shardCostFn = cfg.shardCost
  return self
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
-- fallbackKey/fallbackNote — the SECOND place from RankWinner(ctx, winnerKey): the
-- honest "what would I press instead" once the winner's ability is removed.  Always
-- offered when castable.
function C:Emit(state, ctx, winnerKey, level, winnerNote, fallbackKey, fallbackNote)
  local cues = {}

  local function put(k, emphasis, note)
    if not k then return end
    local rec = ctx.facts[k]
    cues[k] = { draw = true, emphasis = emphasis, note = note,
                transient = transientFor(state, rec) }
  end

  -- The one press.
  if winnerKey then put(winnerKey, level, winnerNote) end

  -- The fallback — always shown when castable (never the winner's ability; RankWinner
  -- excluded it).  ROTATION_FALLBACK: a real runner-up press, not a "press now" claim.
  if fallbackKey and fallbackKey ~= winnerKey and not cues[fallbackKey] then
    put(fallbackKey, "ROTATION_FALLBACK", fallbackNote)
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
--------------------------------------------------------------------------------
function C:ResourceBars(ctx)
  local out = {}
  for _, p in ipairs((ctx and ctx.powers) or {}) do
    out[#out + 1] = {
      value = p.value or 0,
      max = p.max or SHARD_CAP,
      incoming = p.incoming or 0,
      display = p.display or "discrete",
      powerType = p.powerType or POWER_TOKEN.SoulShards or "SOUL_SHARDS",
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
  -- The honest second place: re-run the list with the winner's ability excluded.  Always
  -- computed; Emit shows it whenever it is castable, so the runner-up itself carries the
  -- "I am not certain" signal rather than a separate hedge token.
  local fbKey, fbNote
  if winnerKey then
    local k, _, nt = spec:RankWinner(ctx, winnerKey)
    fbKey, fbNote = k, nt
  end
  return self:Emit(state, ctx, winnerKey, level, note, fbKey, fbNote)
end
