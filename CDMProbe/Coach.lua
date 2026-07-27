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
--   5. Emit      — a SEPARATE pass over the abilities the winner did NOT claim, so
--      SOON / JUDGE / SEQUENCE are non-press BY CONSTRUCTION and coexist with the
--      one press; plus resourceBar and the opener sequence.
--
-- PURE of frames, timers, and the live client — like HudBoard, a FACTORY
-- (Coach.New(cfg) / __index).  Everything volatile arrives in the `state` pulse
-- (State.Build's shape).  Deterministic in -> out: that is what lets the 23-golden
-- corpus (corpus/goldens/*) arbitrate it (busted coach_golden_spec).  The live path
-- keeps running on HudBoard/HudScore until the Phase-5 cutover — this is built in
-- isolation (build-plan P1), not strangler-fig.
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
local STAGE_LEAD = 5.0    -- Tyrant anticipated <= this => the window is setting up: the
                         -- pre-Tyrant walk runs and Tyrant rides a SOON burst anchor
local POOL_UNTIL = 3.0    -- pool shards to cap only while Tyrant is > this out; inside the
                          -- final approach, commit to the Core dump / demon stage instead
local BURST_LEAD = 20.0   -- Tyrant anticipated <= this => the burst is imminent
local LATE_LEAD  = 4.0    -- a probably-up press left elapsed this long => overdue
local CAST_FRESH = 1.0    -- a history 'start' this fresh => the cast_started edge
local IMP_WINDOW = 6.0    -- history lookback for the imp-napkin promote
local OPENER_MAX = 15.0   -- combat this young + Tyrant never cast => opener running
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

-- Does the recent cast history contain a SUCCEEDED cast of `base` within `window`
-- seconds of `now` (and, if `after`, later than it)?  The Coach's sequence memory.
local function succeededWithin(state, base, window)
  local now = state.at or 0
  local hist = state.history or {}
  for i = 1, #hist do
    local h = hist[i]
    if h.phase == "succeeded" and (h.base == base or h.spellID == base) then
      if num(h.at) and (now - h.at) <= window then return true, h.at end
    end
  end
  return false
end

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

  -- Cooldown state, distilled to the three cases the cascade reads:
  --   napkinProbablyUp — estimate ELAPSED (unknown + source napkin): ROTATION-eligible
  --   anticipated      — counting down (has remaining); SOON when within the lead
  --   cooling          — on cooldown, far — not a candidate
  rec.napkinProbablyUp = (c.state == "unknown" and c.source == "napkin") or false
  rec.anticipated      = (c.state == "anticipated") or false
  rec.remaining        = num(c.remaining)
  rec.cooling          = (c.state == "cooling") or false
  rec.cdChangedAt      = num(c.changedAt)
  rec.cdSource         = c.source

  -- Armed proc / transform.  A live override whose spell `spends == "art"` IS the
  -- Demonic Art transform (Ruination on the HoG frame, Infernal Bolt on the SB
  -- frame) — the precise, combat-readable trigger (mirrors HudScore.ProcArmed's
  -- override branch).  `glow` is State's own combat-readable proc-highlight.
  rec.transformed = (live ~= base and info.spends == "art") or false
  rec.glowActive  = (g.active and g.readable ~= false) or false
  rec.glowChangedAt = num(g.changedAt)

  -- overdue — a probably-up press that has SAT elapsed past the lead (readable off
  -- cd.changedAt).  Only meaningful for the winner (Escalate drives the clock).
  rec.overdue = rec.napkinProbablyUp and rec.cdChangedAt
    and (now - rec.cdChangedAt) >= LATE_LEAD or false

  return rec
end

--------------------------------------------------------------------------------
-- 2. Context — the whole-board facts the cascade reads.
--------------------------------------------------------------------------------
-- Returns ctx + the two index maps (facts by cooldownID key, cooldownID key by
-- base spellID) so RankWinner/Emit can address abilities by identity.
function C:Context(state)
  local S = ids()
  local factsByCid, cidByBase = {}, {}
  for key, cd in pairs(state.cooldowns or {}) do
    local rec = C.Classify(cd, state)
    if rec then
      factsByCid[key] = rec
      if rec.base then cidByBase[rec.base] = key end
    end
  end

  -- A raw self-aura buff read (Core presence, Tyrant-window, Wild Imps) straight off
  -- the pulse — these entries are auras (skipped by Classify) but their buff.isActive
  -- is the combat-readable presence signal.
  local function buffActive(spellID)
    for _, cd in pairs(state.cooldowns or {}) do
      if num(cd.spellID) == spellID then
        return cd.buff and cd.buff.isActive == true
      end
    end
    return false
  end

  local ss = (state.power or {}).SoulShards or {}
  local shards   = num(ss.value)
  local incoming = num(ss.incoming) or 0
  local smax     = num(ss.max) or SHARD_CAP
  local projected = shards and (shards + incoming) or nil

  local ctx = {
    facts = factsByCid, cidByBase = cidByBase,
    mode = state.mode,
    shards = shards, incoming = incoming, smax = smax,
    projected = projected,
    atCap = projected and projected >= SHARD_CAP or false,
    powerReadable = ss.readable ~= false and shards ~= nil,
  }

  -- Core proc: readable via the Demonbolt glow OR the Demonic Core buff presence.
  local dbolt = S.DEMONBOLT and cidByBase[S.DEMONBOLT] and factsByCid[cidByBase[S.DEMONBOLT]]
  ctx.coreUp = (dbolt and dbolt.glowActive) or buffActive(S.DEMONIC_CORE) or false

  -- Demonic Art armed + which FRAME carries the transform (Ruination -> HoG frame,
  -- Infernal Bolt -> SB frame).
  for key, rec in pairs(factsByCid) do
    if rec.transformed then ctx.artFrame = key; ctx.artInfo = rec.info; break end
  end

  -- Tyrant proximity + the window.
  ctx.tyrantWindowActive = buffActive(S.TYRANT)
  local ty = S.TYRANT and cidByBase[S.TYRANT] and factsByCid[cidByBase[S.TYRANT]]
  ctx.tyrant = ty
  ctx.tyrantProbablyUp = ty and ty.napkinProbablyUp or false
  ctx.tyrantAnticipated = ty and ty.anticipated or false
  ctx.tyrantRemaining = ty and ty.remaining or nil
  ctx.tyrantSource = ty and ty.cdSource or nil
  ctx.tyrantImminent = ctx.tyrantAnticipated and ctx.tyrantRemaining
    and ctx.tyrantRemaining <= BURST_LEAD or false

  -- Dreadstalkers + Grimoire: Imp Lord — the two pre-Tyrant demon summons (SEQUENCE 2).
  -- `*Committed` reads the cast-START edge so the staging walk advances the instant a
  -- demon is pressed, without waiting for the summon to land (the "next move" rule).
  local dr = S.DREADSTALKERS and cidByBase[S.DREADSTALKERS] and factsByCid[cidByBase[S.DREADSTALKERS]]
  ctx.dread = dr
  ctx.dreadProbablyUp = dr and dr.napkinProbablyUp or false
  ctx.dreadCommitted = committedWithin(state, S.DREADSTALKERS, 3.0)
  local gr = S.IMP_LORD and cidByBase[S.IMP_LORD] and factsByCid[cidByBase[S.IMP_LORD]]
  ctx.grimoire = gr
  ctx.grimoireProbablyUp = gr and gr.napkinProbablyUp or false
  ctx.grimoireCommitted = committedWithin(state, S.IMP_LORD, 3.0)

  -- Implosion — its true gate (Wild Imps >= 6) is secret, so it is never a plain
  -- press; the cascade only promotes it on the napkin heuristic, else it JUDGEs.
  local im = S.IMPLOSION and cidByBase[S.IMPLOSION] and factsByCid[cidByBase[S.IMPLOSION]]
  ctx.implosion = im
  ctx.implosionProbablyUp = im and im.napkinProbablyUp or false

  -- Board freshness — the summons freshly laid (Dreadstalkers just cast) => we are
  -- entering the Tyrant window, not mid-sustain.
  ctx.boardFresh = committedWithin(state, S.DREADSTALKERS, 3.0)

  -- The imp-napkin confident promote (implosion-primed): 2+ full HoGs banked recently
  -- with no Implosion since AND imps to spend (Implosion probably-up).  A readable
  -- approximation of the secret >=6-imp gate — only confident enough to PRESS in AoE.
  local hogHits = 0
  for _, h in ipairs(state.history or {}) do
    if h.phase == "succeeded" and (h.base == S.HAND_OF_GULDAN or h.spellID == S.HAND_OF_GULDAN)
        and num(h.at) and (state.at - h.at) <= IMP_WINDOW then
      hogHits = hogHits + 1
    end
  end
  local implodedSince = succeededWithin(state, S.IMPLOSION, IMP_WINDOW)
  ctx.impNapkinConfident = (hogHits >= 2) and not implodedSince and ctx.implosionProbablyUp or false

  -- Opener — Tyrant has NEVER been on cooldown (cd.source == "none": pre-first-cast)
  -- and combat is young.  The recurring mid-fight Tyrant entry reads source "napkin"
  -- (been cast), so this discriminates opener-midflight from tyrant-ready cleanly.
  local elapsed = state.combatStartedAt and (state.at - state.combatStartedAt) or nil
  ctx.openerActive = (ctx.tyrantSource == "none")
    and state.combat and (not elapsed or elapsed <= OPENER_MAX)
    and succeededWithin(state, S.DREADSTALKERS, 20.0) and true or false

  -- Phase — first match.  (Documented in the module header + w4-build-plan.)
  if ctx.openerActive then ctx.phase = "OPENER"
  elseif ctx.tyrantWindowActive then ctx.phase = "TYRANT_WINDOW"
  elseif ctx.tyrantProbablyUp and shards and shards >= SHARD_CAP and ctx.boardFresh then
    ctx.phase = "TYRANT_ENTRY"
  elseif ctx.tyrantAnticipated and ctx.tyrantRemaining and ctx.tyrantRemaining <= STAGE_LEAD then
    ctx.phase = "TYRANT_STAGING"
  elseif ctx.tyrantImminent then ctx.phase = "BURST_IMMINENT"
  else ctx.phase = "STEADY" end

  return ctx
end

--------------------------------------------------------------------------------
-- 3. RankWinner — the ordered cascade.  Returns winnerKey, level, note (the ONE
--    press).  nil winner = the panel/SEQUENCE owns the press (opener).
--------------------------------------------------------------------------------
function C:RankWinner(ctx)
  local S = ids()
  local B = ctx.cidByBase
  local shards = ctx.shards or 0
  local cost = hogCost(self)

  local function key(base) return B[base] end

  if ctx.phase == "OPENER" then
    return nil
  end

  if ctx.phase == "TYRANT_WINDOW" then
    -- HoG-spam floods imps inside the window (SEQUENCE 3 / maxroll "as many HoG as
    -- possible for 15s") — HoG OUTRANKS a Core dump here, the inverse of steady.
    if shards >= 3 then
      return key(S.HAND_OF_GULDAN), "ROTATION", "flood imps — spam Hand of Gul'dan"
    elseif ctx.coreUp and shards < 4 then
      return key(S.DEMONBOLT), "ROTATION"
    else
      return key(S.SHADOW_BOLT), "ROTATION"
    end
  end

  if ctx.phase == "TYRANT_ENTRY" then
    return key(S.TYRANT), "ROTATION"
  end

  if ctx.phase == "TYRANT_STAGING" then
    -- The pre-Tyrant walk (SEQUENCE 2), one press at a time.  Order:
    --   1. Dump a banked Demonic Core (Demonbolt) — it refunds +2 shards, so it BUILDS
    --      toward the pool while spending the Core; the top move when one's up.
    --   2. POOL shards to cap (Shadow Bolt), even with a demon droppable — the flood
    --      needs a full bar — but ONLY while there's time (Tyrant > POOL_UNTIL out); in
    --      the final approach, commit to the demon instead of a slow build.
    --   3. Drop the demons in order: Dreadstalkers ("the last summon before Tyrant"),
    --      then Grimoire: Imp Lord ("pressed next to Dreadstalkers").
    -- Steps 3+ advance on the cast-START edge (ctx.*Committed), so once a demon is
    -- committed the cue moves to the next move instead of telling you to re-press what
    -- you're already casting.  If everything is staged but Tyrant isn't up yet, fall
    -- through to the steady cascade (TYRANT_ENTRY takes over once Tyrant reads up).
    if ctx.coreUp and shards < 4 then
      return key(S.DEMONBOLT), "ROTATION"
    end
    if shards < SHARD_CAP and ctx.tyrantRemaining and ctx.tyrantRemaining > POOL_UNTIL then
      return key(S.SHADOW_BOLT), "ROTATION", "pool to 5 for the flood"
    end
    if ctx.dreadProbablyUp and not ctx.dreadCommitted then
      return key(S.DREADSTALKERS), "ROTATION", "stage — last summon before Tyrant"
    end
    if ctx.dreadCommitted and ctx.grimoireProbablyUp and not ctx.grimoireCommitted then
      return key(S.IMP_LORD), "ROTATION", "Imp Lord — pair with Dreadstalkers"
    end
  end

  -- STEADY / BURST_IMMINENT — the resource+summon cascade (rotation.md 1-12).
  -- 1. A Demonic Art transform is the top press when armed.
  if ctx.artFrame then
    local ai = ctx.artInfo
    -- Infernal Bolt is the +3-shard refill Art (generates == 3); Ruination is the
    -- no-refund triple-imp Art (no generates).  That distinguishes the two frames.
    local isInfernal = ai and ai.generates == 3
    if isInfernal then
      -- Infernal Bolt refills +3; take it only if it won't overcap (rotation.md prio).
      if shards + 3 <= SHARD_CAP then
        return ctx.artFrame, "ROTATION", "Infernal Bolt"
      end
    else
      -- Ruination — the free triple-imp spend, always the top press when armed.
      return ctx.artFrame, "ROTATION", "Ruination — free triple-imp (Pit Lord)"
    end
  end

  -- 2. A cooldown-gated summon reading probably-up, pressed on CD when Tyrant is far
  --    (nothing to stage for).
  if ctx.dreadProbablyUp and not ctx.tyrantImminent then
    return key(S.DREADSTALKERS), "ROTATION"
  end

  -- 3. The imp-napkin confident promote (AoE only) — the readable stand-in for the
  --    secret >=6-imp gate.
  if ctx.impNapkinConfident and ctx.mode == "aoe" then
    return key(S.IMPLOSION), "ROTATION", "imps banked — implode"
  end

  -- 4. Spend a Demonic Core on Demonbolt — but only BELOW 4 shards, else the +2
  --    refund overcaps (the shipped softenAbove rule, now a cascade position).
  if ctx.coreUp and shards < 4 then
    return key(S.DEMONBOLT), "ROTATION"
  end

  -- 5. Hand of Gul'dan — the primary spender, at/above its cost on the PROJECTION
  --    (value + in-flight builder yield).  Gating the press on `projected` rather
  --    than live `shards` is the 6b promote: an in-flight builder that lands the
  --    cost'th shard makes HoG the readable next move NOW (one move ahead), not a
  --    lagging "SOON".  incoming is builder-only (5b); the signed-spend case is 6d.
  if ctx.projected and ctx.projected >= cost then
    return key(S.HAND_OF_GULDAN), "ROTATION"
  end

  -- 6. Shadow Bolt — the free builder/filler that refills shards (rotation.md 12).
  return key(S.SHADOW_BOLT), "ROTATION"
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
  -- A probably-up summon (Dreadstalkers) left sitting past the lead.
  if rec.base == S.DREADSTALKERS and rec.overdue then return "LATE" end
  -- HoG parked at a FULL bar (actual shards, not the projection) — the readable dump.
  if rec.base == S.HAND_OF_GULDAN and ctx.shards and ctx.shards >= SHARD_CAP then
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
  if rec.napkinProbablyUp and rec.cdChangedAt == now then return "ready" end
  return nil
end

--------------------------------------------------------------------------------
-- 5. Emit — the full Guidance object.  A SEPARATE pass over the NON-winner
--    abilities, so SOON / JUDGE / SEQUENCE are non-press by construction and
--    coexist with the one press; plus resourceBar and the opener sequence.
--------------------------------------------------------------------------------
function C:Emit(state, ctx, winnerKey, level, winnerNote)
  local S = ids()
  local B = ctx.cidByBase
  local cues = {}

  local function put(k, emphasis, note)
    if not k then return end
    local rec = ctx.facts[k]
    cues[k] = { draw = true, emphasis = emphasis, note = note,
                transient = transientFor(state, rec) }
  end

  -- The one press.
  if winnerKey then put(winnerKey, level, winnerNote) end

  -- SEQUENCE — the opener panel owns the plan; the active step's ability draws the
  -- attention-redirect cue (not a press).
  if ctx.phase == "OPENER" and B[S.TYRANT] then
    put(B[S.TYRANT], "SEQUENCE", "opener — Tyrant is the step")
  end

  -- Tyrant SOON — the burst anchor while the window sets up (never a press).  Rides the
  -- whole staging lead so it stays visible across the pool -> demons -> summon walk; a
  -- bare non-press SOON that coexists with the one ROTATION.
  local tyKey = B[S.TYRANT]
  if tyKey and tyKey ~= winnerKey and ctx.tyrantAnticipated and ctx.tyrantRemaining
      and ctx.tyrantRemaining <= STAGE_LEAD and not cues[tyKey] then
    put(tyKey, "SOON")
  end

  -- (HoG "SOON" retired at 6b.)  The press gate (RankWinner step 5) now reads
  -- `projected` directly, so an in-flight builder that lifts projected to the cost
  -- promotes HoG to the ROTATION press itself — there is no separate value-vs-
  -- projected band left to signal as SOON.  Anticipating a not-yet-affordable
  -- spender (projected < cost) is out of scope here; that behaviour belongs to 6d.

  -- Dreadstalkers JUDGE — held for the imminent window (your call to stage or press).
  local drKey = B[S.DREADSTALKERS]
  if drKey and drKey ~= winnerKey and not cues[drKey]
      and ctx.dreadProbablyUp and ctx.phase == "BURST_IMMINENT" then
    put(drKey, "JUDGE", "Tyrant soon — hold for the window or press")
  end

  -- Demonbolt JUDGE — only on a FRESH Core proc edge with a readable competitor: the
  -- press-vs-hold turns on the secret Core stack count, so inform (JUDGE), don't
  -- instruct.  A steady proc (no edge) stays unlisted AVAILABLE.
  local dbKey = B[S.DEMONBOLT]
  if dbKey and dbKey ~= winnerKey and not cues[dbKey] then
    local rec = ctx.facts[dbKey]
    if rec and rec.glowActive and rec.glowChangedAt == (state.at or 0) then
      put(dbKey, "JUDGE", "Core proc — dump if 2+")
    end
  end

  -- Implosion JUDGE — otherwise-up with a SECRET gate (imp count).  Never a press
  -- unless the confident promote already claimed it as the winner.
  local imKey = B[S.IMPLOSION]
  if imKey and imKey ~= winnerKey and not cues[imKey] and ctx.implosionProbablyUp then
    local note = (ctx.phase == "BURST_IMMINENT") and "hold imps for burst — your call"
      or "imps uncertain — your call"
    put(imKey, "JUDGE", note)
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
-- sequence — the opener panel (drop-through cursor over the fixed opener).  Only
-- OPENER draws a panel; steady state shows none.
--------------------------------------------------------------------------------
-- The Demo opener panel (diabolist-sequences.md SEQUENCE 1 / rotation.md opener).
-- Authored here as pass-through display data (labels are the panel's own copy, the
-- contract's opaque display text) rather than in ns.Spec (no schema change).
local OPENER_STEPS = {
  { id = 104316,  label = "Dreadstalkers" },
  { id = 1276452, label = "Grimoire: Imp Lord" },
  { id = 265187,  label = "Summon Demonic Tyrant" },
  { id = 105174,  label = "Hand of Gul'dan" },
  { id = 105174,  label = "Hand of Gul'dan", gate = "shards", note = "Need 3 shards" },
  { id = 196277,  label = "Implosion", aoe = true, note = "AoE only" },
}

function C:Sequence(state, ctx)
  if ctx.phase ~= "OPENER" then return { show = false } end

  -- Drop-through cursor: advance past each opener step already seen in the cast
  -- history (in order), so out-of-order / optional presses don't jam it.
  local cursor = 0
  local hist = state.history or {}
  for _, h in ipairs(hist) do
    if h.phase == "succeeded" then
      local step = OPENER_STEPS[cursor + 1]
      if step and (h.base == step.id or h.spellID == step.id) then
        cursor = cursor + 1
      end
    end
  end

  local keybindOf = function(spellID)
    local key = ctx.cidByBase[spellID]
    local cd = key and state.cooldowns[key]
    return cd and cd.keybind or nil
  end

  local steps = {}
  for i, tmpl in ipairs(OPENER_STEPS) do
    local zero = i - 1
    local st, note
    if zero < cursor then st = "done"
    elseif zero == cursor then st = "active"
    elseif tmpl.aoe and ctx.mode ~= "aoe" then st, note = "skipped", tmpl.note
    elseif tmpl.gate == "shards" then st, note = "blocked", tmpl.note
    else st = "pending" end
    steps[i] = { spellID = tmpl.id, label = tmpl.label,
                 keybind = keybindOf(tmpl.id), state = st, note = note }
  end

  return { show = true, title = "OPENER", cursor = cursor, steps = steps }
end

--------------------------------------------------------------------------------
-- Compute — the one public entry.  State pulse in, Guidance out.
--------------------------------------------------------------------------------
function C:Compute(state)
  local ctx = self:Context(state)
  local winnerKey, level, note = self:RankWinner(ctx)
  level = self:Escalate(winnerKey, level, ctx)
  return self:Emit(state, ctx, winnerKey, level, note)
end
