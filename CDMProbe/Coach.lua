-- Coach.lua — Stage 2 of the W4 pipeline: State -> **Coach** -> Guidance.
--
-- WHY THIS EXISTS (docs/w4-build-plan.md Phase 2, the ⛔ decision gate).  The live
-- HUD (HudState -> HudScore -> HudBoard -> HudChrome) scores every ability
-- INDEPENDENTLY, with no priority order.  The committed Guidance v1 contract
-- (guidance-contract.json) requires SINGLE-TOP-PRESS: at most ONE cue is the
-- "press now" call (ROTATION, or LATE when overdue) — the rotation's #1 ready
-- ability — and every other ready ability caps at AVAILABLE.  That makes the Coach
-- a RANKED WINNER, which the reused per-ability scorer structurally cannot be
-- (HudScore floors a probably-up hard-CD to NEVER, and its context-prunes lower
-- levels per-ability so two presses can green at once).  So the Coach REUSES the
-- readable facts but REDESIGNS the decision as an explicit priority cascade.
--
-- THE SHAPE (agreed this session):
--   1. Classify  — a PURE pass over the State pulse producing a rich candidate
--      record per cooldown (pressable / napkin-probably-up / armed / overdue /
--      transformed …).  Key change from HudScore: a hard-CD with an ELAPSED napkin
--      is ROTATION-ELIGIBLE, not NEVER.
--   2. Context   — the whole-board facts the cascade reads (phase, shards+incoming,
--      coreUp, artArmed, tyrant proximity, board freshness, mode, opener).
--   3. RankWinner — the ordered cascade: exactly one winner cooldownID + level.
--   4. Escalate  — ROTATION -> LATE only from READABLE overdue-ness (napkin elapsed
--      past the lead, or HoG parked at cap).  Secret buckets never go LATE.
--   5. Emit      — a SEPARATE pass over the abilities the winner did NOT claim: the
--      ROTATION_FALLBACK runner-up (winner's ability pulled, list re-run) and the
--      dumb per-ability SOON decoration, non-press BY CONSTRUCTION and coexisting
--      with the one press; plus resourceBar.  (JUDGE retired — the runner-up now
--      carries the uncertainty the hedge used to.)
--
-- PURE of frames, timers, and the live client — like HudBoard, a FACTORY
-- (Coach.New(cfg) / __index).  Everything volatile arrives in the `state` pulse
-- (State.Build's shape).  Deterministic in -> out: that is what lets the Tier-1
-- branch-coverage spec (busted coach_apl_spec) arbitrate it — the independent oracle
-- authored from apl-prototype/pseudocode.md (the golden corpus retired W4 Phase 8, its
-- rotation-gate role replaced by that per-branch spec).  Wired live behind
-- `/cdmp hud2` (the Phase-5c driver: State -> Coach -> Binder -> Renderer), running
-- PARALLEL to the old default `/cdmp hud` (HudBoard/HudScore), which stays until the
-- Phase-5e cutover.
--
-- SPEC-AGNOSTIC-ISH: the Coach reads identity/signal buckets from SpecDemonology
-- (ns.SpecInfo / ns.SpecIDs), holds no colour constants, and takes its one
-- talent-dependent number (HoG's shard cost) through cfg.shardCost with a Demo
-- fallback.  The cascade ORDER is Demo rotation knowledge (rotation.md steps 1-12 +
-- diabolist-sequences.md); a second spec overrides RankWinner in pure Lua, exactly
-- as HudBoard documents.
local ADDON, ns = ...

ns.Coach = {}
local C = ns.Coach
C.__index = C

--------------------------------------------------------------------------------
-- Tunables (seconds / shards).  Named + commented so the cascade reads as rules.
--------------------------------------------------------------------------------
local SHARD_CAP  = 5      -- full soul-shard bar (ns.SHARD_CAP mirrors this)
local TCT_LEAD   = 3.0    -- Tyrant Condition (TCT): Tyrant napkin remaining <= this (OR off
                         -- cooldown) => the burst window: cap -> demons -> Tyrant -> flood
local LATE_LEAD  = 4.0    -- a probably-up press left elapsed this long => overdue
local SOON_LEAD  = 3.0    -- a tracked cooldown anticipated within this => a dumb SOON
                         -- decoration (W4 Phase 8): "coming off cooldown", independent
                         -- of the winner/burst logic — NOT a press claim
local CAST_FRESH = 1.0    -- a history 'start' this fresh => the cast_started edge
local HOG_COST_FALLBACK = 3   -- Hand of Gul'dan's cost when no live reader is wired

-- The game's own power token per Enum.PowerType name (contract's sanctioned
-- pass-through — the Renderer resolves colour via PowerBarColor).  Demo only reads
-- SoulShards today; a second power name lands here when a second spec needs it.
local POWER_TOKEN = { SoulShards = "SOUL_SHARDS" }

-- Demo shard-cost fallback (talent-dependent at runtime; cfg.shardCost overrides).
-- Only HoG is gated on a readable shard COST in the corpus; the summons are
-- phase/proc-gated, not cost-gated in the cascade.
local DEMO_COST = nil  -- built lazily from ns.SpecIDs on first use

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------
-- cfg (all optional):
--   shardCost  fn(spellID) -> cost   the LIVE cost reader (ns.ShardCost) when wired;
--              nil in the golden harness, where the Demo fallback answers.
function C.New(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, C)
  self.shardCostFn = cfg.shardCost
  return self
end

local function ids()
  return ns.SpecIDs or {}
end

local function hogCost(self)
  local S = ids()
  if self.shardCostFn and S.HAND_OF_GULDAN then
    local c = self.shardCostFn(S.HAND_OF_GULDAN)
    if type(c) == "number" then return c end
  end
  if not DEMO_COST then
    DEMO_COST = {}
    if S.HAND_OF_GULDAN then DEMO_COST[S.HAND_OF_GULDAN] = HOG_COST_FALLBACK end
  end
  return (S.HAND_OF_GULDAN and DEMO_COST[S.HAND_OF_GULDAN]) or HOG_COST_FALLBACK
end

--------------------------------------------------------------------------------
-- Small readers over the pulse (never mutate it; never read anything secret — the
-- pulse already passed State's readable/Stash gate, so every value here is honest)
--------------------------------------------------------------------------------
local function num(v) return type(v) == "number" and v or nil end

-- Has `base` been COMMITTED within `window` — a cast STARTED or SUCCEEDED?  The burst
-- walk advances on the cast-start edge (the "next move" rule: the instant a demon is
-- committed, move to the next step), so it must not wait for the landed `succeeded`.
local function committedWithin(state, base, window)
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
-- 1. Classify — the per-cooldown candidate record (REUSES HudScore's readable
--    sub-logic, re-pointed at the pulse; owns a REDESIGNED "probably-up is
--    pressable" semantics).  Auras are inputs, never scored (return nil).
--------------------------------------------------------------------------------
function C.Classify(cd, state)
  local base = num(cd.spellID)
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

  -- Armed proc / transform.  A live override whose spell `spends == "art"` IS the
  -- Demonic Art transform (Ruination on the HoG frame, Infernal Bolt on the SB
  -- frame) — the precise, combat-readable trigger (mirrors HudScore.ProcArmed's
  -- override branch).  `glow` is State's own combat-readable proc-highlight.
  rec.transformed = (live ~= base and info.spends == "art") or false
  rec.glowActive  = (g.active and g.readable ~= false) or false
  rec.glowChangedAt = num(g.changedAt)

  -- overdue — a probably-up press that has SAT elapsed past the lead (readable off
  -- cd.changedAt).  Only meaningful for the winner (Escalate drives the clock).
  rec.overdue = rec.probablyUp and rec.cdChangedAt
    and (now - rec.cdChangedAt) >= LATE_LEAD or false

  return rec
end

--------------------------------------------------------------------------------
-- 2. Context — the whole-board facts the cascade reads.
--------------------------------------------------------------------------------
-- Returns ctx + the facts index (records by BASE spellID) so RankWinner/Emit can
-- address abilities by identity.  The Coach decides in spellID terms (the domain view);
-- cooldownID is transport the Binder owns — it never appears in the Coach's vocabulary.
function C:Context(state)
  local S = ids()
  local factsByBase = {}
  for _, entry in pairs(state.abilities or {}) do
    local rec = C.Classify(entry, state)
    if rec and rec.base then
      -- One record per base spellID BY CONSTRUCTION: `abilities` already folded the CDM's
      -- N rows of an ability into one pressable representative, so the buggy last-writer-
      -- wins `cidByBase[rec.base] = key` is gone — there is nothing to overwrite.
      factsByBase[rec.base] = rec
    end
  end

  -- Buff presence (Core, Tyrant-window, Wild Imps) straight off the domain view's
  -- spellID-keyed `buffs` set — secrecy already folded in by State (an unreadable aura is
  -- absence there, never a false true).
  local function buffActive(spellID)
    return (state.buffs and state.buffs[spellID] == true) or false
  end

  local ss = (state.power or {}).SoulShards or {}
  local shards   = num(ss.value)
  local incoming = num(ss.incoming) or 0
  local smax     = num(ss.max) or SHARD_CAP
  local projected = shards and (shards + incoming) or nil

  local ctx = {
    facts = factsByBase,
    mode = state.mode,
    shards = shards, incoming = incoming, smax = smax,
    projected = projected,
    atCap = projected and projected >= SHARD_CAP or false,
    powerReadable = ss.readable ~= false and shards ~= nil,
  }

  -- Core proc: readable via the Demonbolt glow OR the Demonic Core buff presence.
  local dbolt = S.DEMONBOLT and factsByBase[S.DEMONBOLT]
  ctx.coreUp = (dbolt and dbolt.glowActive) or buffActive(S.DEMONIC_CORE) or false

  -- Demonic Art armed + which ABILITY carries the transform (Ruination -> HoG, Infernal
  -- Bolt -> SB).  `artFrame` is a BASE spellID key (the domain-view identity), not a cid.
  for base, rec in pairs(factsByBase) do
    if rec.transformed then ctx.artFrame = base; ctx.artInfo = rec.info; break end
  end

  -- Tyrant proximity + the window.
  ctx.tyrantWindowActive = buffActive(S.TYRANT)
  local ty = S.TYRANT and factsByBase[S.TYRANT]
  ctx.tyrant = ty
  -- Off cooldown = probably-up.  A never-cast Tyrant now reads `ready` off the OOC
  -- baseline (Phase 7), so the pre-first-Tyrant opener is a burst WITHOUT a per-ability
  -- carve-out — the old `cdSource == "none"` special-case is deleted.
  ctx.tyrantProbablyUp = (ty and ty.probablyUp) or false
  ctx.tyrantAnticipated = ty and ty.anticipated or false
  ctx.tyrantRemaining = ty and ty.remaining or nil
  ctx.tyrantSource = ty and ty.cdSource or nil
  -- Tyrant Condition (TCT) — the single burst trigger: Tyrant off cooldown (probably-up)
  -- OR its napkin countdown within the lead.  Replaces OPENER/ENTRY/STAGING/IMMINENT.
  ctx.tct = ctx.tyrantProbablyUp
    or (ctx.tyrantAnticipated and ctx.tyrantRemaining and ctx.tyrantRemaining <= TCT_LEAD)
    or false

  -- Dreadstalkers + Grimoire: Imp Lord — the two pre-Tyrant demon summons (SEQUENCE 2).
  -- `*Committed` reads the cast-START edge so the staging walk advances the instant a
  -- demon is pressed, without waiting for the summon to land (the "next move" rule).
  local dr = S.DREADSTALKERS and factsByBase[S.DREADSTALKERS]
  ctx.dread = dr
  ctx.dreadProbablyUp = dr and dr.probablyUp or false
  ctx.dreadCommitted = committedWithin(state, S.DREADSTALKERS, 3.0)
  local gr = S.IMP_LORD and factsByBase[S.IMP_LORD]
  ctx.grimoire = gr
  ctx.grimoireProbablyUp = gr and gr.probablyUp or false
  ctx.grimoireCommitted = committedWithin(state, S.IMP_LORD, 3.0)

  -- Implosion — its true gate (Wild Imps >= 6) is secret.  The priority list treats it
  -- as castable-when-off-cooldown (pseudocode L3); the "your call" softening for the
  -- unreadable imp count is Emit's job, not a gate here.
  local im = S.IMPLOSION and factsByBase[S.IMPLOSION]
  ctx.implosion = im
  ctx.implosionProbablyUp = im and im.probablyUp or false

  -- NO phase field (W4 Phase 8).  The OOC_IDLE / TYRANT_WINDOW / BURST / STEADY
  -- state-machine is gone: RankWinner is a single flat priority list, and combat is a
  -- plain State fact (state.combat) a gate may read — never a top-level branch.

  return ctx
end

--------------------------------------------------------------------------------
-- 3. RankWinner — the FLAT PRIORITY LIST (W4 Phase 8, apl-prototype/pseudocode.md).
--    Evaluated top to bottom; the FIRST line whose ability is usable is the one press.
--    Returns winnerKey, level, note.  No phase branch, and no nil "panel owns it" case:
--    at pull start Dreadstalkers (held for the window, released by L6) is the answer,
--    not a hardcoded SB+DB display.  Pooling is emergent — the build gates + the bottom
--    filler fill the bar on their own between higher-priority presses.
--------------------------------------------------------------------------------
-- `excluded` (optional) — a cooldownID key removed from consideration at EVERY line
-- that names it, so the caller can recompute the honest SECOND place (the winner's
-- ability pulled, list re-run from the top — NOT "the next line").  Ported from
-- apl-prototype/apl.lua's evaluate_once(excluded).  `excluded` is a BASE spellID (the
-- winner), and since each ability is one base-keyed record, excluding it suppresses the
-- ability everywhere (Demonbolt in the block + L5; Dreadstalkers in the block + L3).
function C:RankWinner(ctx, excluded)
  local S = ids()
  local projected = ctx.projected or ctx.shards or 0   -- value + signed incoming
  local cost = hogCost(self)

  -- The Coach decides in BASE spellIDs (the domain view), so `key()` is IDENTITY — the
  -- winner IS a base spellID.  It still gates on the ability being TRACKED (present in
  -- ctx.facts): an untracked line (e.g. Shadow Bolt when the CDM isn't tracking it) yields
  -- nil and evaluation continues, exactly as the old `cidByBase[base]` lookup did.  The
  -- Binder resolves the winning spellID to its display cooldownID.
  local function key(base) return (base and ctx.facts[base]) and base or nil end

  -- pick — the line's candidate, or nil to keep evaluating: nil when the ability
  -- isn't tracked (key == nil) OR it is the excluded ability.  Callers do
  -- `local k,lv,nt = pick(...); if k then return k,lv,nt end`.
  local function pick(k, level, note)
    if k and k ~= excluded then return k, level, note end
    return nil
  end
  local k, lv, nt

  -- Which Demonic Art is armed?  Infernal Bolt refills +3 (generates == 3); Ruination
  -- is the no-refund triple-imp Art.  Only one is ever armed at a time.
  local artIsInfernal = (ctx.artInfo and ctx.artInfo.generates == 3) or false

  -- L1 — Ruination: the free triple-imp Art, top press whenever armed.
  if ctx.artFrame and not artIsInfernal then
    k, lv, nt = pick(ctx.artFrame, "ROTATION", "Ruination — free triple-imp (Pit Lord)")
    if k then return k, lv, nt end
  end

  -- L2 — the Tyrant-window setup walk (SETUP sense of tct): cap shards, dump a Core,
  -- stage the held demons, then Summon Tyrant.  The demon steps advance on the
  -- cast-START edge (ctx.*Committed) so a committed summon yields to the next move
  -- instead of re-pressing itself.  This OUTRANKS Dreadstalkers/Implosion below so the
  -- setup is never preempted by them.  (pseudocode.md: burning cooldowns with no shard
  -- cost beat the build outside a Tyrant window — hence the block sits above L5.)
  if ctx.tct then
    -- IB (the +3 refill Art) leads the block when nearly empty: pool shards FAST for
    -- the flood.  A procced SB frame IS Infernal Bolt (the transform), so outside the
    -- window the L5 build reaches IB the same way via key(SHADOW_BOLT).
    if projected < 2 and ctx.artFrame and artIsInfernal then
      k, lv, nt = pick(ctx.artFrame, "ROTATION", "Infernal Bolt"); if k then return k, lv, nt end
    end
    if projected < 4 and ctx.coreUp then
      k, lv, nt = pick(key(S.DEMONBOLT), "ROTATION"); if k then return k, lv, nt end
    end
    if projected < SHARD_CAP then
      k, lv, nt = pick(key(S.SHADOW_BOLT), "ROTATION", "pool to 5 for the flood"); if k then return k, lv, nt end
    end
    if ctx.dreadProbablyUp and not ctx.dreadCommitted then
      k, lv, nt = pick(key(S.DREADSTALKERS), "ROTATION", "stage — last summon before Tyrant"); if k then return k, lv, nt end
    end
    if ctx.grimoireProbablyUp and not ctx.grimoireCommitted then
      k, lv, nt = pick(key(S.IMP_LORD), "ROTATION", "Imp Lord — pair with Dreadstalkers"); if k then return k, lv, nt end
    end
    if ctx.tyrantProbablyUp then
      k, lv, nt = pick(key(S.TYRANT), "ROTATION"); if k then return k, lv, nt end
    end
  end

  -- L3 — Call Dreadstalkers on cooldown, OUTSIDE a Tyrant window (inside, the block above
  -- staged it; the guard stops this line from re-pressing the staged summon).
  if ctx.dreadProbablyUp and not ctx.tct then
    k, lv, nt = pick(key(S.DREADSTALKERS), "ROTATION"); if k then return k, lv, nt end
  end

  -- L4 — Implosion when off cooldown.  Its real gate is a SECRET imp count, so the press
  -- cannot be conditioned on it; sitting below the Tyrant block, it never hijacks the
  -- setup, and the ROTATION_FALLBACK offers the alternative instead of a JUDGE hedge.
  if ctx.implosionProbablyUp then
    k, lv, nt = pick(key(S.IMPLOSION), "ROTATION"); if k then return k, lv, nt end
  end

  -- L5 — low-shard builder: dump a Core with Demonbolt if one is present, else Shadow
  -- Bolt.  Sits BELOW the no-shard-cost cooldowns above (Dreadstalkers/Implosion) per
  -- pseudocode.md — outside a Tyrant window those beat the build.  Ordered DB-then-SB so
  -- excluding Demonbolt (fallback recompute) lets the Shadow Bolt branch surface.
  if projected < 3 then
    if ctx.coreUp then
      k, lv, nt = pick(key(S.DEMONBOLT), "ROTATION"); if k then return k, lv, nt end
    end
    k, lv, nt = pick(key(S.SHADOW_BOLT), "ROTATION"); if k then return k, lv, nt end
  end

  -- L6 — Hand of Gul'dan: the primary spender and the bottom filler.  Post-Tyrant flood
  -- (Tyrant buff up -> spam HoG) falls out here on its own, no special case.  Below its
  -- cost (a higher-cost talent + a partial bar) the Shadow Bolt floor keeps building.
  if projected >= cost then
    k, lv, nt = pick(key(S.HAND_OF_GULDAN), "ROTATION"); if k then return k, lv, nt end
  end
  k, lv, nt = pick(key(S.SHADOW_BOLT), "ROTATION"); if k then return k, lv, nt end
  return nil
end

--------------------------------------------------------------------------------
-- 4. Escalate — ROTATION -> LATE only from READABLE overdue-ness.  Secret buckets
--    (Demonic Core stacks) can never go LATE.
--------------------------------------------------------------------------------
function C:Escalate(winnerKey, level, ctx)
  if not winnerKey or level ~= "ROTATION" then return level end
  local S = ids()
  local rec = ctx.facts[winnerKey]
  if not rec then return level end
  -- A probably-up summon (Dreadstalkers) left sitting past the lead.  Suppressed in
  -- the burst/window, where a ready summon is a STAGED press, not a forgotten one:
  -- since Phase 7 the OOC baseline makes a never-cast summon read `ready` (with an
  -- OOC-old changedAt) at pull start, so the burst walk must not escalate its staged
  -- Dreadstalkers to LATE (mirrors the HoG-at-cap guard below).
  if rec.base == S.DREADSTALKERS and rec.overdue
      and not ctx.tct and not ctx.tyrantWindowActive then
    return "LATE"
  end
  -- HoG parked at a FULL bar (actual shards, not the projection) — the readable dump.
  -- Suppressed during the burst / window, where a full bar is intentional pooling for
  -- the flood, not overcap-parking.
  if rec.base == S.HAND_OF_GULDAN and ctx.shards and ctx.shards >= SHARD_CAP
      and not ctx.tct and not ctx.tyrantWindowActive then
    return "LATE"
  end
  return level
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
--    construction and coexist with the one press; plus resourceBar.
--------------------------------------------------------------------------------
-- fallbackKey/fallbackNote — the SECOND place from RankWinner(ctx, winnerKey): the
-- honest "what would I press instead" once the winner's ability is removed.  Always
-- offered when castable (the retired JUDGE hedge is replaced by showing the runner-up
-- as a real press).
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
    resourceBar = self:ResourceBar(ctx),
    cues = cues,
    sequence = self:Sequence(state, ctx),
  }
end

--------------------------------------------------------------------------------
-- resourceBar — value + max + the in-flight incoming projection, forwarded from
-- State's napkin (the Coach ranks on value + incoming).
--------------------------------------------------------------------------------
function C:ResourceBar(ctx)
  return {
    value = ctx.shards or 0,
    max = ctx.smax or SHARD_CAP,
    incoming = ctx.incoming or 0,
    display = "discrete",       -- soul shards are whole segments
    powerType = POWER_TOKEN.SoulShards or "SOUL_SHARDS",
  }
end

--------------------------------------------------------------------------------
-- sequence — RETIRED at the TCT redesign (docs/w4-phase6-tct-redesign.md).  The
-- one-press-at-a-time cue walk replaced the opener panel (6e = drop the panel), so
-- the Coach never emits a panel now.  The contract field stays (show:false) for the
-- Binder/Renderer; 5e deletes HudPane/HudOpener/HudBurst.
--------------------------------------------------------------------------------
function C:Sequence(_state, _ctx)
  return { show = false }
end

--------------------------------------------------------------------------------
-- Compute — the one public entry.  State pulse in, Guidance out.
--------------------------------------------------------------------------------
function C:Compute(state)
  local ctx = self:Context(state)
  local winnerKey, level, note = self:RankWinner(ctx)
  level = self:Escalate(winnerKey, level, ctx)
  -- The honest second place: re-run the list with the winner's ability excluded.  Always
  -- computed (the "always try to calculate a fallback" directive); Emit shows it whenever
  -- it is castable, so the runner-up carries the uncertainty the JUDGE cue used to hedge.
  local fbKey, fbNote
  if winnerKey then
    local k, _, nt = self:RankWinner(ctx, winnerKey)
    fbKey, fbNote = k, nt
  end
  return self:Emit(state, ctx, winnerKey, level, note, fbKey, fbNote)
end
