-- CoachDemonology.lua — the DEMONOLOGY decision brain (multi-spec Phase 2).
--
-- WHY THIS EXISTS.  Coach.lua used to BE Demonology: RankWinner was the Demo cascade,
-- Context computed Demo facts (coreUp / artFrame / tct / tyrant proximity), and the
-- tunables (TCT_LEAD / LATE_LEAD / the shard cap / HoG cost) were file-locals.  Phase 2 split
-- that in two: Coach.lua is now a GENERIC shell (Classify / Emit / ResourceBars / Sequence /
-- the Compute orchestration) that any spec drives, and this file is the Demo BRAIN it
-- delegates to — Context / RankWinner / Escalate plus the Demo tunables.  A second spec is
-- now a sibling Coach<Spec>.lua that attaches the same three methods to its own spec object.
--
-- HOW IT ATTACHES.  SpecDemonology.lua registered a plain-data spec object into ns.Specs[266]
-- (and statically activated it).  This file grabs that SAME object and hangs the three
-- decision methods + tunables on it, so ns.ActiveSpec carries both the data AND the brain.
-- The shell reads ns.ActiveSpec and calls spec:Context / spec:RankWinner / spec:Escalate.
--
-- BEHAVIOUR-PRESERVING.  Everything here is a VERBATIM move of the old Coach.lua logic; the
-- only edits are the re-pointing the split forced: file-local tunables -> self.*, the
-- file-local committedWithin -> ns.Coach.CommittedWithin, hogCost -> ctx.hogCostFrags resolved
-- from the coach env, and re-applying the Demo `spends == "art"` filter here (the shell
-- relaxed Classify's `transformed` to the generic live~=base).  Same decisions, same tests.
--
-- LOAD ORDER.  This loads right after SpecDemonology.lua (so ns.Specs[266] exists) and may
-- sit before Coach.lua in the .toc: the ns.Coach.* references below are RUNTIME-only (inside
-- the methods), never touched at load, so the shell need not exist yet when this file runs.
local ADDON, ns = ...

local spec = ns.Specs[266]   -- the Demonology object registered by SpecDemonology.lua

--------------------------------------------------------------------------------
-- Tunables (seconds / whole shards).  Moved verbatim from Coach.lua's file-locals onto the
-- spec object.  The RAIL constants live on the data object (SpecDemonology.lua: FRAG_CAP /
-- BAR_MAX / FRAGS_PER_SHARD, Phase 6.2).
--------------------------------------------------------------------------------
spec.TCT_LEAD   = 3.0    -- Tyrant Condition (TCT): Tyrant napkin remaining <= this (OR off
                         -- cooldown) => the burst window: cap -> demons -> Tyrant -> flood
spec.LATE_LEAD  = 4.0    -- a probably-up press left elapsed this long => overdue.  Read by
                         -- the shell's Classify off ns.ActiveSpec.LATE_LEAD.
-- ⚠ IN WHOLE SHARDS, like ns.ShardCost itself — Context converts it UP to fragments at the
-- single conversion site, so the fallback and the live read cross the unit boundary the same
-- way (Phase 6.2).  Never pre-multiply it here.
spec.HOG_COST_FALLBACK = 3   -- Hand of Gul'dan's cost when no live reader is wired

local function ids()
  return ns.SpecIDs or {}
end

-- ⚠ THIS FILE'S `num` AND `truncToward` ARE GONE (2026-08-02), and their absence is the
-- proof the hoist actually landed.  Both existed ONLY to serve the power-rail block that
-- ns.Coach.PowerContext now owns — `num` guarded the pulse's power fields, `truncToward`
-- scaled the exact projection back into pip units.  Every remaining read in this brain goes
-- through the shared rail, so a local copy of either would be a second implementation of an
-- arithmetic that must not have two.  If a future line here needs to read a raw pulse
-- number, re-add `num` at that line's expense — do not restore it pre-emptively.

--------------------------------------------------------------------------------
-- Context — the whole-board facts the cascade reads (contract: Coach.lua's header).
--------------------------------------------------------------------------------
function spec:Context(state, env)
  local S = ids()
  local factsByBase = {}
  for _, entry in pairs(state.abilities or {}) do
    local rec = ns.Coach.Classify(entry, state)
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

  -- The in-flight projection, derived HERE from the pulse's cast history (roster-state-plan
  -- Phase 6 — State emits raw `power` now and no longer folds `incoming` onto the bar).
  -- One map per Context, shared by the shard scalars below and the generic ctx.powers loop.
  local sums = ns.Coach.InflightPower(state, ns.SpecPowerDelta)

  -- ── THE SHARD RAIL, IN FRAGMENTS (Phase 6.2) ───────────────────────────────
  -- Every gate below this line is denominated in FRAGMENTS (0–50), never whole shards, and
  -- every field carries the unit in its NAME.  `ctx.shards` was DELETED rather than
  -- repurposed: had it kept its name and changed meaning, a surviving `shards >= 2` would
  -- compile fine and be silently wrong by 10x, which is the one failure this migration can
  -- produce.  A stale reader now gets nil and fails loudly instead.
  --
  -- ⚠ THE ARITHMETIC MOVED, THE NAMES DID NOT (2026-08-02).  The read ladder — exact rail
  -- first, display-value-x-modifier when the client refuses, the cap fallbacks, the
  -- `ctx.powers` fold — is now ns.Coach.PowerContext, shared with every other brain, because
  -- it was byte-identical in two files and about to be copied into five more.  What stays
  -- HERE is the Soul-Shard VOCABULARY: `frags`, `fragsMax`, `fragsProjected` are Demonology's
  -- words for the generic rail, and the cascade below is unchanged.  A Fury brain publishes
  -- its own names off the same call.
  local bars, rails = ns.Coach.PowerContext(state, self, sums)
  local ss = rails.SoulShards or {}
  local mod = ss.modifier or self.FRAGS_PER_SHARD
  local frags = ss.value
  local fragsIncoming = ss.incoming or 0
  local fragsMax = ss.max or self.FRAG_CAP
  local fragsProjected = ss.projected

  local ctx = {
    facts = factsByBase,
    mode = state.mode,   -- carried, but Demo's RankWinner gates NOTHING on it: it is a
                         -- passive-cleave spec, so single vs AoE changes no press.
                         -- (Destruction's L10 Rain of Fire does gate on it.)
    frags = frags, fragsIncoming = fragsIncoming, fragsMax = fragsMax,
    fragsProjected = fragsProjected,
    fragModifier = mod,
    atCap = ss.atCap or false,
    powerReadable = ss.readable or false,
  }

  -- ctx.powers — the GENERIC power array the shell's ResourceBars emits from (multi-spec
  -- Phase 3), built by the shared fold above.  Demo declares exactly SoulShards, so this is
  -- one bar; a dual-resource spec gets two, in declaration order.  ⚠ It is in DISPLAY units
  -- (Renderer.lua pools one pip per unit of `max`) with the exact integers alongside on the
  -- `*Exact` fields — see ns.Coach.PowerContext's header for why the two rails are separate.
  ctx.powers = bars

  -- HoG's shard cost, resolved ONCE (talent-dependent at runtime).  The shell owns the
  -- INJECTED reader (env.shardCostFn = cfg.shardCost); the Demo brain owns WHICH spell it
  -- costs + the fallback.  Only HoG is gated on a readable shard cost in the corpus; the
  -- summons are phase/proc-gated, not cost-gated.  RankWinner reads ctx.hogCostFrags.
  --
  -- ⚠ COSTS CONVERT UP, HERE AND NOWHERE ELSE.  `ns.ShardCost` returns WHOLE SHARDS and its
  -- name says so — the client pre-applies the display divisor (Chaos Bolt: DB2 stores 20,
  -- the API hands back 2, measured 2026-08-01).  The gates compare in fragments, so the cost
  -- is multiplied UP at this one site and renamed `*Frags` from here down.  The fallback
  -- goes through the same conversion, so there is exactly one unit boundary in this file.
  local hogShards = self.HOG_COST_FALLBACK
  if env and env.shardCostFn and S.HAND_OF_GULDAN then
    local c = env.shardCostFn(S.HAND_OF_GULDAN)
    if type(c) == "number" then hogShards = c end
  end
  ctx.hogCostFrags = math.floor(hogShards * mod + 0.5)

  -- Core proc: readable via the Demonbolt glow OR the Demonic Core buff presence.
  local dbolt = S.DEMONBOLT and factsByBase[S.DEMONBOLT]
  ctx.coreUp = (dbolt and dbolt.glowActive) or buffActive(S.DEMONIC_CORE) or false

  -- Demonic Art armed + which ABILITY carries the transform (Ruination -> HoG, Infernal
  -- Bolt -> SB).  `artFrame` is a BASE spellID key (the domain-view identity), not a cid.
  -- The shell relaxed Classify's `transformed` to the generic live~=base, so the Demo
  -- `spends == "art"` filter (the Demonic Art trigger) is RE-APPLIED here.
  for base, rec in pairs(factsByBase) do
    if rec.transformed and rec.info.spends == "art" then
      ctx.artFrame = base; ctx.artInfo = rec.info; break
    end
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
    or (ctx.tyrantAnticipated and ctx.tyrantRemaining and ctx.tyrantRemaining <= self.TCT_LEAD)
    or false

  -- Dreadstalkers + Grimoire: Imp Lord — the two pre-Tyrant demon summons (SEQUENCE 2).
  -- `*Committed` reads the cast-START edge so the staging walk advances the instant a
  -- demon is pressed, without waiting for the summon to land (the "next move" rule).
  local dr = S.DREADSTALKERS and factsByBase[S.DREADSTALKERS]
  ctx.dread = dr
  ctx.dreadProbablyUp = dr and dr.probablyUp or false
  ctx.dreadCommitted = ns.Coach.CommittedWithin(state, S.DREADSTALKERS, 3.0)
  local gr = S.IMP_LORD and factsByBase[S.IMP_LORD]
  ctx.grimoire = gr
  ctx.grimoireProbablyUp = gr and gr.probablyUp or false
  ctx.grimoireCommitted = ns.Coach.CommittedWithin(state, S.IMP_LORD, 3.0)

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
-- RankWinner — the FLAT PRIORITY LIST (W4 Phase 8, apl-prototype/pseudocode.md).
--    Evaluated top to bottom; the FIRST line whose ability is usable is the one press.
--    Returns winnerKey, level, note.  No phase branch, and no nil "panel owns it" case:
--    at pull start Dreadstalkers (held for the window, released by L6) is the answer,
--    not a hardcoded SB+DB display.  Pooling is emergent — the build gates + the bottom
--    filler fill the bar on their own between higher-priority presses.
--------------------------------------------------------------------------------
-- `excluded` (contract: Coach.lua's header) suppresses an ability EVERYWHERE it appears,
-- because each ability is one base-keyed record — Demonbolt in the block and at L5,
-- Dreadstalkers in the block and at L3, both dropped by one exclusion.
function spec:RankWinner(ctx, excluded)
  local S = ids()
  -- FRAGMENTS throughout (Phase 6.2).  `projected` is the exact 0-50 rail plus the signed
  -- in-flight delta, and every constant below is a fragment count: 20 = 2 shards.
  local projected = ctx.fragsProjected or ctx.frags or 0   -- value + signed incoming
  local costFrags = ctx.hogCostFrags

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

  -- Which Demonic Art is armed?  Only one ever is.  Read the SEMANTIC field, never the
  -- shard yield: `generatesFrags` is tuning arithmetic and would flip this decision if retuned
  -- (SpecDemonology's transform block explains the split).
  local artIsInfernal = (ctx.artInfo and ctx.artInfo.art == "infernal") or false

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
    if projected < 20 and ctx.artFrame and artIsInfernal then
      k, lv, nt = pick(ctx.artFrame, "ROTATION", "Infernal Bolt"); if k then return k, lv, nt end
    end
    if projected < 40 and ctx.coreUp then
      k, lv, nt = pick(key(S.DEMONBOLT), "ROTATION"); if k then return k, lv, nt end
    end
    if projected < (ctx.fragsMax or self.FRAG_CAP) then
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
  -- setup, and the ROTATION_FALLBACK offers the alternative instead of a separate hedge.
  if ctx.implosionProbablyUp then
    k, lv, nt = pick(key(S.IMPLOSION), "ROTATION"); if k then return k, lv, nt end
  end

  -- L5 — low-shard builder: dump a Core with Demonbolt if one is present, else Shadow
  -- Bolt.  Sits BELOW the no-shard-cost cooldowns above (Dreadstalkers/Implosion) per
  -- pseudocode.md — outside a Tyrant window those beat the build.  Ordered DB-then-SB so
  -- excluding Demonbolt (fallback recompute) lets the Shadow Bolt branch surface.
  if projected < 30 then
    if ctx.coreUp then
      k, lv, nt = pick(key(S.DEMONBOLT), "ROTATION"); if k then return k, lv, nt end
    end
    k, lv, nt = pick(key(S.SHADOW_BOLT), "ROTATION"); if k then return k, lv, nt end
  end

  -- L6 — Hand of Gul'dan: the primary spender and the bottom filler.  Post-Tyrant flood
  -- (Tyrant buff up -> spam HoG) falls out here on its own, no special case.  Below its
  -- cost (a higher-cost talent + a partial bar) the Shadow Bolt floor keeps building.
  if projected >= costFrags then
    k, lv, nt = pick(key(S.HAND_OF_GULDAN), "ROTATION"); if k then return k, lv, nt end
  end
  k, lv, nt = pick(key(S.SHADOW_BOLT), "ROTATION"); if k then return k, lv, nt end
  return nil
end

--------------------------------------------------------------------------------
-- Escalate — Demo's readable overdue-ness.  Demonic Core stacks are secret, so a
--    Core-gated press can never escalate.
--------------------------------------------------------------------------------
function spec:Escalate(winnerKey, level, ctx)
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
  -- HoG parked at a FULL bar (actual fragments, not the projection) — the readable dump.
  -- Suppressed during the burst / window, where a full bar is intentional pooling for
  -- the flood, not overcap-parking.
  -- ⚠ A FULL BAR IS `>= fragsMax`, i.e. 50 — NOT 5.  This is the LATE-at-full-bar rule the
  -- Phase-6.2 migration singled out: it reads like a whole-shard comparison and is not one.
  if rec.base == S.HAND_OF_GULDAN and ctx.frags and ctx.frags >= (ctx.fragsMax or self.FRAG_CAP)
      and not ctx.tct and not ctx.tyrantWindowActive then
    return "LATE"
  end
  return level
end
