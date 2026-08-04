-- CoachHavoc.lua — the HAVOC DEMON HUNTER decision brain (spec 577).
--
-- WHAT THIS IS.  The three methods the generic Coach shell delegates to, hung on the spec
-- object SpecHavoc.lua registered, plus this spec's tunables:
--   spec:Context(state, env)               fold the pulse into whole-board facts
--   spec:RankWinner(ctx, excluded)         the flat priority list — first usable line wins
--   spec:Escalate(winnerKey, level, ctx)   ROTATION -> LATE, from READABLE overdue-ness only
-- The shell (Coach.lua) owns Classify / Emit / ResourceBars and never learns a spell id.
--
-- THE LIST IT IMPLEMENTS is specs/havoc/rotation.md (the spec of record, distilled from the
-- Tier-1 simc APL `ActionPriorityLists/default/demonhunter_havoc.simc` @ ab7b0b8,
-- 2026-08-01 — 140 lines, 24 variables, 3 sub-lists).  Line numbers L1-L15 below are that
-- document's, so the two can be diffed by eye.  Where a line's real gate is not readable
-- the degradation is stated AT the line rather than faked — the standing rule is that
-- absence of a read never becomes a positive claim.
--
-- HOW HAVOC DIFFERS FROM THE THREE SHIPPED BRAINS, structurally:
--
--   * THE RESOURCE IS THE PLAINEST YET.  Fury is 0-120 with modifier 1, so the exact rail
--     and the display rail are the SAME integer.  No fragment arithmetic, no unit boundary,
--     no `*Frags` naming — and deliberately so: Destruction's `cost * FRAGS_PER_SHARD`
--     would be a silent 1x no-op here that teaches the next reader the wrong lesson.
--   * NO RESOURCE BAR IS DRAWN.  `display = "none"` (SpecHavoc.lua): Fury rides the whole
--     rail into the decision log's `PW:` column and the Renderer skips it.
--   * NO BURST SETUP BLOCK.  Nothing is held for Metamorphosis — no pooling, no partner
--     summon — so it is a plain on-cooldown line and Escalate has no window suppression.
--     Structurally Destruction's Summon Infernal, not Demonology's Tyrant.
--   * ⚠ THE ONE GENUINELY NEW SHAPE IS THE META FORK, and modelling it as a second cascade
--     would have been wrong.  simc ends its top-level list with
--     `run_action_list,name=meta,if=buff.metamorphosis.up` — a HARD fork into a second
--     complete priority list that never returns.  But demon form is a DISPLAY OVERRIDE on
--     frames the list already presses (Chaos Strike -> Annihilation, Blade Dance -> Death
--     Sweep, both granted by Metamorphosis 162264's two `EffectAura 332` effects), so the
--     Coach cues the BASE spellID and the icon already shows the right art.  A second list
--     would be fifteen duplicated lines whose only difference is a label the pipeline
--     supplies for free.  What the fork genuinely changes is ORDER, in exactly two places —
--     L6 (Essence Break is meta-only) and L7-vs-L10 (Blade Dance outranks Eye Beam in meta).
--     Those two lines carry `ctx.inMeta`; nothing else does.
--   * ⚠ THREE ROTATIONAL PRESSES ARE FILED CDM-**UTILITY** (Felblade, Vengeful Retreat, Fel
--     Rush) and it needed NO pipeline edit.  Both fences that could have blocked them — the
--     SOON fence (Coach.lua:501) and the virtual-row fence (State.lua:1941) — test the
--     SPEC-AUTHORED `info.cadence`, not the CDM's category.  SpecHavoc declares them
--     "filler"/"oncd" and they are cueable.  The rollout plan expected worse; recorded
--     because the next tank spec will meet the same shape.
--   * ⚠ CHARGES ARE EVERYWHERE AND THEIR COOLDOWNS LIE.  Three buttons report a base
--     cooldown that is WRONG, not merely absent — see SpecHavoc.lua's header.  usable()'s
--     one-charge rule is what protects the press; read its comment before touching it.
--
-- LOAD ORDER.  Loads right after SpecHavoc.lua (so ns.Specs[577] exists) and may sit before
-- Coach.lua: every ns.Coach.* reference here is runtime-only, never touched at load.
local ADDON, ns = ...

local spec = ns.Specs[577]   -- the Havoc object registered by SpecHavoc.lua

--------------------------------------------------------------------------------
-- Tunables (seconds / Fury).  Fields on the spec object, so a sibling spec's values can
-- never leak in as file-locals.
--------------------------------------------------------------------------------
spec.LATE_LEAD = 4.0    -- a probably-up press left elapsed this long => overdue.  Read by
                        -- the shell's Classify off ns.ActiveSpec.LATE_LEAD.

-- ⚠⚠ THE FOUR `*_COST_FALLBACK` CONSTANTS AND `ESSENCE_BREAK_FURY` ARE **DELETED**
-- (2026-08-03), ALONG WITH EVERY FURY COMPARISON IN THIS FILE.  Do not restore them.
--
-- `UnitPower("player", Enum.PowerType.Fury)` RETURNS A SECRET VALUE.  Secrecy is per power
-- type and the rule is primary-vs-secondary [T1 blue post, *Midnight Public Alpha Addon API
-- Changes*, 2025-11-24]; Fury is the Demon Hunter's PRIMARY resource, so it is secret in a
-- city and mid-pull alike — `C_Secrets.GetPowerTypeSecrecy(17)` = 2 (`ContextuallySecret`),
-- `ShouldUnitPowerBeSecret("player", 17)` = true, measured both places.  There is no
-- out-of-combat window and no seed value, EVER.  A cost constant that nothing can compare
-- against is not a fallback, it is a trap.
--
-- WHAT IT COST: the 2026-08-03 flight.  `ctx.fury or 0` fabricated a zero, every
-- `projected >= cost` was false, and Chaos Strike, Eye Beam, Blade Dance and Metamorphosis
-- won ZERO of 2374 in-combat lines while Throw Glaive won 770 — because its
-- `GLAIVE_COST_FALLBACK = 25` was itself wrong (the live client reports Throw Glaive FREE)
-- and 0 >= 0 passes.  ⚠ **DB2 COSTS ARE NOT THE CLIENT'S COSTS.**
--
-- WHAT REPLACES THEM: `ns.SpellUsable` -> `insufficientPower`, per spell, attached by State
-- as `abilities[base].usable`.  Read `affordable()` in RankWinner and ns.SpellUsable's
-- banner in Util.lua.  The cost NUMBER is never needed, so `env.powerCostFn` is no longer
-- consulted here at all.
--
-- WHAT IS GENUINELY LOST, stated so nobody re-derives it: `IsSpellUsable` is BINARY — false
-- at 40 Fury and at 170 alike — so OVERCAP AVOIDANCE is unrecoverable through it.  Havoc
-- will overcap and the HUD will not warn.  Blizzard's own assisted-combat list accepts the
-- same loss (zero Fury references in 20 lines).  specs/havoc/rotation.md -> *What this
-- costs, knowingly* and docs/multi-class-rollout.md -> *Phase 2* carry the recovery design.

-- THE ESSENCE BREAK WINDOW, in seconds — and it is a DB2 fact, not a tuned lead.  simc
-- gates four lines on `debuff.essence_break.up`/`.down`, and that debuff (320338) has NO
-- CooldownSetSpell row in set 1599, so there is no presence channel for it.  What IS
-- readable is the CAST: `UNIT_SPELLCAST_SUCCEEDED` spellIDs survive combat (settled
-- game-wide), and ns.Coach.CommittedWithin already answers "was this base cast within N
-- seconds" off the pulse's history.  320338's SpellDuration is a flat 4000 ms.
--
-- ⚠ IT IS AN ESTIMATE WITH A KNOWN BIAS, and the bias is what makes it acceptable.  It
-- cannot see a window ended early by the target dying, and it does not model the talent
-- that extends it — both fail toward thinking the window is open slightly too long, which
-- spends a GCD on Chaos Strike.  That is the press L13 would have made anyway, so the
-- failure is a REORDERING, not a wasted press.  A napkin-derived AURA read would not have
-- that property, which is why this channel and not that one.
spec.EB_WINDOW = 4.0

-- L5's lead: how close Eye Beam must be for Vengeful Retreat to be worth pressing first.
-- simc says `cooldown.eye_beam.remains<=gcd.remains`, i.e. about one GCD.
--
-- ⚠ THIS IS THE ONE CROSS-ABILITY TIMING READ IN THE FILE, and it needs its licence stated.
-- A CLIENT cooldown-remains read of another ability is secret in combat, which is why
-- Retribution dropped its Execution-Sentence/Wake-of-Ashes handshake.  But this reads OUR
-- OWN NAPKIN: Eye Beam's 30 s lives on the SPELL row (CategoryRecoveryTime 30000), so
-- ns.BaseCooldown reads it honestly and `rec.remaining` is the same number the shell
-- already draws as SOON.  The rule that separates the two cases: a cross-ability timing
-- gate is allowed when the OTHER ability's cooldown is one the napkin can honestly count.
-- Wake of Ashes is charge-category (base cooldown 0) and fails that test; Eye Beam passes.
-- If the flight shows VR cueing at wrong moments, L5 is the first suspect.
spec.EYE_BEAM_LEAD = 1.5

-- ⚠ `FELBLADE_DEFICIT` AND `IMMO_DEFICIT` ARE **DELETED** TOO, for the same reason one
-- level up: a Fury DEFICIT is `max - value`, and `value` does not exist.  They gated the
-- two generator lines (L11, L12).
--
-- What replaces them is POSITION, not a weaker threshold — and it is Blizzard's own shape.
-- `ActionPriorityLists/assisted_combat/demonhunter_havoc.simc` presses a bare `felblade`
-- with no gate of any kind, between two `chaos_strike` lines, and an `immolation_aura`
-- gated only on enemy count.  So the evaluation order became
-- **L11 Felblade -> L13 spender -> L12 Immolation Aura**: a generator fires when usable,
-- the spender takes the press whenever the client says it is affordable, and the second
-- generator sits BELOW it.  ⚠ THAT ORDERING IS LOAD-BEARING — leaving both generators above
-- the main dump with their gates removed would jam them on and starve the spender, which is
-- the flight failure reproduced by a different mechanism.  The L-numbers stay put (the
-- brain, rotation.md and the oracle all key on them); only the order moved.

-- ⚠ THE ONE GENUINELY UNSETTLED READ (the ART_FROM_RITUAL / RET_HOL_FROM_BUFF precedent).
-- rotation.md L1 is "if a Reaver's Glaive is armed, press it", and the unambiguous source
-- for that is the OVERRIDE on the Throw Glaive frame — a transformed Throw Glaive IS an
-- armed Reaver's Glaive (Reaver's Glaive 444686, `EffectAura 332`, `misc0 = 185123`).
--
-- The tempting second source is the Art of the Glaive buff (442290), and it is NOT
-- equivalent: Art of the Glaive is the FRAGMENT COUNTER that arms Reaver's Glaive at 6
-- fragments (its real aura 444661 carries CumulativeAura 80), and the count is unreachable
-- — the buff channel is `item:IsActive()`, a bool.  If the buff is simply present for most
-- of a fight, which is what a stacking counter does, treating its presence as "armed" would
-- jam L1 above Metamorphosis and The Hunt permanently.
--
-- That is the Light's Deliverance shape verbatim, and that one was answered NO by
-- measurement.  So the default is FALSE: only a visible transform arms it.  Flip this only
-- if the decision log shows 442290 present ONLY while a Reaver's Glaive is genuinely
-- available.  A one-line, one-place reversal, deliberately not a guess baked into the
-- cascade.
spec.HAVOC_RG_FROM_BUFF = false

-- ⚠ AND THE THING THAT IS NOT A SWITCH, stated here so nobody adds one.  The Reaver's
-- Glaive SPEND SEQUENCE (simc's `variable.rg_inc` / `rg_ds`, six APL lines at :56-61) is
-- not implemented, and the reason is DATA rather than difficulty: Rending Strike 442442 and
-- Glaive Flurry 442435 — the two buffs the whole sequence is ordered by — have NO
-- CooldownSetSpell row in set 1599, and neither does `buff.reavers_glaive` 442294.  There
-- is no presence channel for any of them on any surface the addon can reach.  A parked
-- `spec.X = false` switch waits on a question a FLIGHT can settle; this one already has an
-- answer, and it is "the read does not exist".  Machinery behind a switch nothing can ever
-- flip on is worse than the honest gap.  See specs/havoc/rotation.md Deviation 1.

local function ids()
  return ns.SpecIDs or {}
end

-- Honest pulse-number reader: a non-number reads nil, never a guess.
local function num(v) return type(v) == "number" and v or nil end

--------------------------------------------------------------------------------
-- Context — the whole-board facts the cascade reads (contract: Coach.lua's header).
--------------------------------------------------------------------------------
function spec:Context(state, env)
  local S = ids()
  local abilities = state.abilities or {}

  local factsByBase = {}
  for _, entry in pairs(abilities) do
    local rec = ns.Coach.Classify(entry, state)
    if rec and rec.base then
      -- One record per base spellID by construction (State already folded the CDM's N rows
      -- of an ability into one pressable representative).
      factsByBase[rec.base] = rec
    end
  end

  -- Buff PRESENCE off the domain view's spellID-keyed set.  Secrecy is already folded in by
  -- State (an unreadable aura is absence there, never a false true).  ⚠ PRESENCE ONLY —
  -- every Havoc buff that matters has a secret duration, and every STACKING one also sits
  -- behind a talent id whose CDM row reads CumulativeAura = 0.  Both walls land in the same
  -- place: the channel is a bool.
  --
  -- ⚠ KEYED ON THE **TRACKED** ID, NOT THE REAL AURA ID.  State.lua:2304 writes
  -- `buffs[baseOf(entry)]`, i.e. the CDM row's own spellID, which for Havoc is almost
  -- always the TALENT id (Art of the Glaive 442290, not its aura 444661; Demonsurge 452402,
  -- not 452416).  SpecHavoc declares the tracked ids for exactly this reason.
  local function buffActive(spellID)
    return (state.buffs and state.buffs[spellID] == true) or false
  end

  -- ── THE FURY RAIL — PUBLISHED, NEVER COMPARED ──────────────────────────────
  -- Shared arithmetic (ns.Coach.PowerContext).  ⚠ THE RAIL IS SECRET AND SO EVERY FIELD
  -- BELOW IS EXPECTED TO BE `nil` IN PRACTICE — it is kept because the whole point of
  -- `display = "none"` is that Fury reaches the DECISION LOG's `PW:` column, and a column
  -- that reads `restricted` is the instrument that explains a decision nobody watched.
  -- ⚠ NOTHING IN RankWinner OR Escalate MAY READ `ctx.fury`.  There is no fallback and no
  -- warm-up: `restricted` means secret forever, not "not yet".  Affordability comes from
  -- `ctx.affordable`, below.
  --
  -- ⚠ NO `sums` ARGUMENT.  `ns.SpecPowerDelta` is deleted for this spec — an in-flight
  -- projection onto an absent value is either a no-op or a fabrication, and the second is
  -- the bug being remediated.  `spec.powers[1].incoming = false` says so declaratively, so
  -- `incoming` folds to 0 and `projected` stays nil.
  local bars, rails = ns.Coach.PowerContext(state, self)
  local furyRail = rails.Fury or {}

  local ctx = {
    facts = factsByBase,
    mode = state.mode,
    fury = furyRail.value,               -- expected nil.  DO NOT COERCE.
    furyMax = furyRail.max or self.FURY_CAP,
    powerReadable = furyRail.readable or false,
    -- STRUCTURALLY unreadable, straight from C_Secrets via State.  Published so the log can
    -- say WHY the column is empty, and so a future reader does not re-derive the finding.
    furyRestricted = furyRail.restricted or false,
  }
  ctx.powers = bars

  -- ── Readiness, CHARGE-AWARE ────────────────────────────────────────────────
  -- An ability with a charge banked is usable even while its recharge timer runs, so a
  -- charged ability's readiness is NOT its cooldown state.  `ns.ReadCharges` is combat-gated
  -- (C_Spell.GetSpellCharges reads secret in restricted combat), so the EXACT count is an
  -- out-of-combat luxury; in a pull State carries a napkin estimate, biased to UNDERCOUNT.
  --
  -- ⚠ FOR A CHARGED ABILITY THE COUNT IS AUTHORITATIVE — the cooldown state is NOT, and
  -- trusting it is what made the HUD recommend Conflagrate at ZERO charges on 190 of 194
  -- log lines.  The mechanism, measured: the CDM raises `Available` every time a CHARGE is
  -- restored but never raises `OnCooldown` at all for a charged ability, so State's
  -- ready-edge latches true on the first charge and is never cleared — `cd` then reads
  -- `ready` forever.
  --
  -- ⚠ AND ON THIS SPEC IT CARRIES MORE WEIGHT THAN ON ANY SPEC SO FAR.  Retribution's four
  -- charge-category buttons read a base cooldown of ZERO, so the napkin simply had nothing
  -- to count.  THREE OF HAVOC'S READ A WRONG NUMBER instead — Fel Rush 1 s against a real
  -- 10 s, Immolation Aura 2 s against 30 s, Vengeful Retreat 0.5 s against 25 s (T1 DB2 @
  -- 12.0.7; a short shared-category lockout sits on the spell row while the real recovery
  -- lives on a charge category).  A wrong napkin makes `probablyUp` true EARLY, which is
  -- strictly worse than never being true at all.
  --
  -- ⚠⚠ SO THE ONE-CHARGE RULE BELOW IS NOT A LEFTOVER GUARD HERE — IT IS THE MITIGATION.
  -- All three lying rows are ONE-charge categories, and for a pool of one "you have a
  -- charge" and "it is off cooldown" are the SAME FACT and cannot legitimately disagree.
  -- Requiring both means the charge count — which decrements on the cast and only restores
  -- on the `ChargeGained` alert at the REAL recovery — vetoes the early cooldown read for
  -- the whole duration.  For a pool of TWO they legitimately differ (one banked, second
  -- recharging), which is the Conflagrate rule, kept verbatim.
  --
  -- ⚠ THE RESIDUAL HOLE, and it is flight question #1: if there is NO count at all —
  -- `ch.charged` false, or no out-of-combat seed — this falls through to
  -- `probablyUp or chargeBanked` and the early napkin wins.  Do not widen the napkin
  -- pre-emptively; specs/havoc/rotation.md records the exact one-line fix if the flight
  -- shows it biting.
  --
  -- Cloned verbatim from CoachRetribution.lua's usable() — deliberately, not incidentally.
  -- Two copies of a rule this expensive to learn are better than one generalisation that
  -- quietly acquires a spec's assumptions.  ⚠ THIS IS THE THIRD COPY.  If a fourth spec
  -- needs it, hoist it to shell kit then — three is the line.
  local function chargeBanked(base)
    local row = base and abilities[base]
    local ch = row and row.charge
    if not ch then return false end
    local cur = num(ch.cur)
    return (cur ~= nil and cur >= 1) or false
  end
  local function usable(base)
    local rec = base and factsByBase[base]
    if not rec then return false end
    local ch = abilities[base] and abilities[base].charge
    if ch and ch.charged then
      local cur = num(ch.cur)
      if cur ~= nil then
        if num(ch.max) == 1 then return cur >= 1 and (rec.probablyUp or false) end
        return cur >= 1
      end
    end
    return rec.probablyUp or chargeBanked(base)
  end

  ctx.metaUsable         = usable(S.METAMORPHOSIS)
  ctx.huntUsable         = usable(S.THE_HUNT)
  ctx.eyeBeamUsable      = usable(S.EYE_BEAM)
  ctx.essenceBreakUsable = usable(S.ESSENCE_BREAK)
  ctx.bladeDanceUsable   = usable(S.BLADE_DANCE)
  ctx.immoUsable         = usable(S.IMMOLATION_AURA)
  ctx.felbladeUsable     = usable(S.FELBLADE)
  ctx.vrUsable           = usable(S.VENGEFUL_RETREAT)
  ctx.felRushUsable      = usable(S.FEL_RUSH)
  ctx.throwGlaiveUsable  = usable(S.THROW_GLAIVE)

  -- ── The transforms ─────────────────────────────────────────────────────────
  -- The shell relaxed Classify's `transformed` to the generic `live ~= base`, so each
  -- spec re-applies its own filter.  Havoc's is the simplest of the four shipped specs:
  -- every override replaces exactly ONE named base on that base's own frame, so the
  -- question is always "is THIS frame showing THAT id" and never "which frame carries it".
  -- ⚠ Checked EXPLICITLY rather than by walking factsByBase, because a `pairs` walk would
  -- make the answer depend on table order the moment two overrides were live at once.
  local function transformedTo(base, overrideID)
    local rec = base and factsByBase[base]
    return (rec and rec.transformed and rec.live == overrideID) or false
  end

  -- ── THE METAMORPHOSIS FORK ─────────────────────────────────────────────────
  -- Read from TWO independent sources, ORed.  Neither is a guess and neither is strictly
  -- more trustworthy, so a build (or a row) that surfaces only one still forks correctly:
  --   1. the Metamorphosis TrackedBuff row (191427) reporting IsActive().  ⚠ 191427 is the
  --      CAST id; the aura that actually grants the overrides is 162264, which the CDM does
  --      not track — so this is the row we have, not the aura we would pick.
  --   2. either meta override visibly live on its base frame.  Metamorphosis 162264 carries
  --      two `EffectAura 332` effects (basePoints 201427 and 210152), so demon form always
  --      transforms BOTH frames; seeing either is sufficient.
  -- Both are combat-readable channels.  Published separately as well as ORed, so the
  -- decision log can say WHICH one forked the list — a fork nobody can explain is exactly
  -- the hole the Destruction field capture fell into.
  ctx.metaFromBuff      = buffActive(S.METAMORPHOSIS)
  ctx.metaFromTransform = transformedTo(S.CHAOS_STRIKE, S.ANNIHILATION)
    or transformedTo(S.BLADE_DANCE, S.DEATH_SWEEP)
  ctx.inMeta = ctx.metaFromBuff or ctx.metaFromTransform

  -- ── Aldrachi Reaver: the one readable signal ───────────────────────────────
  -- A Throw Glaive frame showing Reaver's Glaive.  `rgFrame` is a BASE spellID (the
  -- domain-view identity), never a cooldownID.
  ctx.rgFrame = transformedTo(S.THROW_GLAIVE, S.REAVERS_GLAIVE) and S.THROW_GLAIVE or nil
  ctx.artOfGlaive = buffActive(S.ART_OF_THE_GLAIVE)
  -- "A Reaver's Glaive that should be pressed."  A visible transform is that; the Art of
  -- the Glaive buff only counts when HAVOC_RG_FROM_BUFF says so — see the tunable's note.
  ctx.rgArmed = (ctx.rgFrame ~= nil)
    or (self.HAVOC_RG_FROM_BUFF and ctx.artOfGlaive)
    or false

  -- ── The Essence Break window, from CAST HISTORY ────────────────────────────
  -- Not an aura read: 320338 has no CDM row (see EB_WINDOW's note).  ns.Coach.CommittedWithin
  -- walks the pulse's history for a 'start' or 'succeeded' of this base inside the window.
  ctx.ebWindow = ns.Coach.CommittedWithin(state, S.ESSENCE_BREAK, self.EB_WINDOW)

  -- ── Proc presence (never a count, never a duration) ────────────────────────
  ctx.innerDemon = buffActive(S.INNER_DEMON)   -- vetoes L2 (simc's `!buff.inner_demon.up`)
  -- Initiative vetoes L5: Vengeful Retreat exists to PROC this, so pressing it while the
  -- buff is already up wastes the retreat.  simc: `!buff.initiative.up` on the non-inertia
  -- Vengeful Retreat line (:81).
  ctx.initiative = buffActive(S.INITIATIVE)

  -- ── AFFORDABILITY — the channel that replaced the Fury comparison ──────────
  -- `abilities[base].usable` is State's per-ability read of `C_Spell.IsSpellUsable`, asked
  -- about the LIVE id (State's readAbilityFacts) and fenced on the spec's `spends` field.
  -- Its shape is ABSENT-on-refusal: `{ readable = false }` carries no `insufficientPower`
  -- member at all, so "we could not ask" and "you cannot afford it" stay distinguishable.
  --
  -- ⚠ USE `insufficientPower`, NOT `isUsable`.  `isUsable` was MEASURED true on a spell
  -- visibly on cooldown during the Retribution flight — it answers "can I afford it", not
  -- "can I cast it".  Readiness is `usable()`'s job, three blocks up, and it stays there.
  --
  -- ⚠ AN UNREADABLE VERDICT DOES NOT BLOCK.  `nil`/absent falls through to TRUE.  That is
  -- the safe direction HERE and only here, because every line that calls this also passes
  -- the CDM/napkin/charge readiness gate first — so the worst case is a cue for a press
  -- that fails, where the opposite default reproduces the exact flight failure (an absent
  -- read becoming "unaffordable" on every ability, forever).
  local function affordable(base)
    local row = base and abilities[base]
    local u = row and row.usable
    if not (u and u.readable) then return true end
    return u.insufficientPower ~= true
  end
  ctx.affordable = affordable

  -- The BASE key the spend lines return.  Resolved through `facts`, so an untracked Chaos
  -- Strike yields nil and both spend lines simply find nothing rather than cueing a ghost.
  ctx.spenderKey = factsByBase[S.CHAOS_STRIKE] and S.CHAOS_STRIKE or nil

  -- Published for the decision log and the oracle — the four gates the list actually asks,
  -- resolved once here so RankWinner's two runs (winner + runner-up) cannot disagree.
  -- ⚠ ONLY THE ABILITIES THE LIST GATES ON RESOURCE APPEAR.  Felblade, Immolation Aura,
  -- Fel Rush, Vengeful Retreat, The Hunt and Metamorphosis are generators or free presses;
  -- Essence Break has NO Fury cost at all (its old `fury>=35` was a POOLING rule — see
  -- rotation.md Deviation 13), so there is nothing for the client to report.
  ctx.spenderAfford  = affordable(S.CHAOS_STRIKE)
  ctx.danceAfford    = affordable(S.BLADE_DANCE)
  ctx.eyeBeamAfford  = affordable(S.EYE_BEAM)
  ctx.glaiveAfford   = affordable(S.THROW_GLAIVE)

  -- ── L5's cross-ability anticipation read ───────────────────────────────────
  -- See EYE_BEAM_LEAD's note for why this one read is licensed where every other
  -- `cooldown.X.remains` gate in the APL is dropped.  `anticipated` + a positive
  -- `remaining` is exactly the pair the shell's SOON decoration already uses, so this reads
  -- no channel the pipeline is not already trusting for pixels.
  local ebRec = factsByBase[S.EYE_BEAM]
  ctx.eyeBeamSoon = (ebRec and ebRec.anticipated
    and (num(ebRec.remaining) or 99) <= self.EYE_BEAM_LEAD) or false

  -- ── The hero tree ──────────────────────────────────────────────────────────
  -- Read off the PULSE (State's talent-API read; TraitSubTree 34 = Fel-Scarred,
  -- 35 = Aldrachi Reaver), and NEVER inferred from the tracked set.  That inference is
  -- field-fix B: on Destruction, deriving the tree from a tracked ability corrupted both
  -- answers at once on the first live session.
  -- ⚠ NO INFERENCE FALLBACK HERE, and that is deliberate rather than an omission.  On
  -- Destruction the fallback exists because the tree GATES rotation lines.  It does not
  -- here: L1 fires because the Throw Glaive frame is VISIBLY transformed, which is an
  -- Aldrachi Reaver fact that announces itself, and every Fel-Scarred addition (Abyssal
  -- Gaze, Consuming Fire) is a display override on a frame the list already presses.  A
  -- guessed tree would buy nothing and could only mislead the log.
  -- ⚠ `ctx.aldrachi` is published and currently has NO reader.  That is honest rather than
  -- useless — it is the name for the build, the decision log wants it, and the first line
  -- that genuinely needs a tree branch must read this instead of re-inferring.
  ctx.hero = state.hero
  ctx.aldrachi = (ctx.hero == "aldrachi-reaver")

  return ctx
end

--------------------------------------------------------------------------------
-- RankWinner — THE FLAT PRIORITY LIST (specs/havoc/rotation.md L1–L15).
--    Evaluated top to bottom; the FIRST line whose ability is usable is the one press.
--    Returns winnerKey, level, note.
--------------------------------------------------------------------------------
-- ⚠ THE ORDER IS THE APL'S **CALL STRUCTURE**, NOT ITS TEXT ORDER.  Both of Retribution's
-- ordering bugs came from reading the file top to bottom, so this one was walked as the
-- engine walks it: `actions.cooldown` is CALLED at :68 (which is why Metamorphosis and The
-- Hunt sit near the top, above everything from :69 down), and the meta fork at :82 means
-- every line from :83 onward is the NON-meta branch while `actions.meta` (:118-140) is the
-- other.  Two orderings differ between them and only two — L6 and L7-vs-L10.
--
-- `excluded` (contract: Coach.lua's header) matters here for three abilities: Immolation
-- Aura sits on L4 and L12, Blade Dance on L7 and L10, and the spender on L8 and L13.  Each
-- pair keys on ONE base spellID, so one exclusion drops both occurrences and the shell's
-- honest second place is a genuine re-run rather than "the next line".
--
-- ⚠⚠ NOT ONE LINE BELOW COMPARES A FURY NUMBER, AND NONE MAY (2026-08-03).  Fury is secret
-- — see the deleted-tunables banner at the top of this file.  Affordability is the client's
-- own per-spell `insufficientPower` verdict, resolved in Context as `ctx.*Afford`.
--
-- ⚠ THE EVALUATION ORDER IS **L11 -> L13 -> L12**, and the out-of-sequence L-numbers are
-- deliberate: they are permanent labels that rotation.md and coach_havoc_apl_spec both key
-- on, so renumbering would silently invalidate every cross-reference for a cosmetic gain.
-- The shape is Blizzard's — generator, spender, generator — from
-- `assisted_combat/demonhunter_havoc.simc`, and it exists because the two generator lines
-- lost their Fury-deficit gates: left above the main dump ungated they would jam on and
-- starve the spender, which is the flight failure by a different mechanism.
function spec:RankWinner(ctx, excluded)
  local S = ids()

  -- The Coach decides in BASE spellIDs, so key() is IDENTITY — it only gates on the ability
  -- being TRACKED (present in ctx.facts).  An untracked line yields nil and evaluation
  -- continues; that is how the list degrades on a build that talented an ability out.
  local function key(base) return (base and ctx.facts[base]) and base or nil end

  -- pick — the line's candidate, or nil to keep evaluating.
  local function pick(k, level, note)
    if k and k ~= excluded then return k, level, note end
    return nil
  end
  local k, lv, nt

  -- L1 — REAVER'S GLAIVE, whenever the Throw Glaive frame is showing it (Aldrachi Reaver).
  -- ⚠ Gated on the TRANSFORM alone, not on Throw Glaive's cooldown — this is Destruction's
  -- Ruination precedent exactly: a granted free press that REPLACES the button on its own
  -- frame, so sitting on it blocks nothing and gains nothing.
  -- ⚠ And the list goes quiet immediately after.  Everything Reaver's Glaive ARMS (Rending
  -- Strike, Glaive Flurry, the empowered spender, simc's whole `rg_ds` ordering) rides
  -- buffs with no CDM row — six APL lines dark.  Under-serving the tree's payoff, never
  -- mis-serving it.  See the HAVOC_RG_FROM_BUFF banner.
  if ctx.rgArmed then
    k, lv, nt = pick(key(ctx.rgFrame or S.THROW_GLAIVE), "ROTATION", "Reaver's Glaive")
    if k then return k, lv, nt end
  end

  -- L2 — METAMORPHOSIS: the whole burst window, as a plain press.  Nothing is staged for it
  -- and nothing is held, so it never reads as a hold.
  -- ⚠ simc:103 is the longest single line in the APL and only ONE of its terms survives:
  -- `!buff.inner_demon.up` (389693 is tracked).  The Eye Beam alignment block (five
  -- `cooldown.eye_beam.remains>=N` clauses) is dropped because every term is a secret read.
  --
  -- ⚠⚠ THE BLADE DANCE TERM WAS **DROPPED 2026-08-03**, AND IT WAS A MISREADING, NOT A
  -- SIMPLIFICATION.  This line used to carry `not ctx.bladeDanceUsable`, derived from the
  -- fragment `cooldown.blade_dance.remains` read as a truthy duration.  Reading the fragment
  -- instead of the clause was the error.  In full, with simc's precedence (`&` over `|`):
  --
  --   ( cooldown.blade_dance.remains
  --     & ( cooldown.blade_dance.remains > gcd.max*3 | prev_gcd.{1,2,3}.death_sweep ) )
  --   | !talent.chaotic_transformation
  --
  -- Two independent disqualifications.  (1) The whole clause is TRUE for anyone WITHOUT
  -- Chaotic Transformation — the talent that makes Meta reset Eye Beam and Blade Dance, and
  -- the only reason the gate exists — and `talent.chaotic_transformation` is not readable,
  -- so the escape hatch is invisible to us.  (2) Even with it, the requirement is "Blade
  -- Dance is ~3 GCDs from ready, or a Death Sweep just went out", not "Blade Dance is on
  -- cooldown".  MEASURED CONSEQUENCE: the term vetoed Metamorphosis on ALL 2374 in-combat
  -- lines of the 2026-08-03 flight — zero presses of a 2-minute cooldown.
  --
  -- Dropped, on the same rule the Eye Beam block already got: holding a 2-minute cooldown on
  -- a gate we cannot evaluate is worse than landing it out of sync.  rotation.md Dev. 12.
  if ctx.metaUsable and not ctx.innerDemon then
    k, lv, nt = pick(key(S.METAMORPHOSIS), "ROTATION"); if k then return k, lv, nt end
  end

  -- L3 — THE HUNT on cooldown, out of an Essence Break window and with no glaive armed.
  -- simc:115's nine-term gate reduces to those two: `debuff.essence_break.down` (readable
  -- through cast history) and `!buff.reavers_glaive.up` (readable through the transform).
  -- The seven Eternal-Hunt alignment clauses are all secret cooldown reads and are dropped,
  -- which lands on the KB's own summary: "The Hunt on cooldown, kept out of Essence Break
  -- windows."
  if ctx.huntUsable and not ctx.ebWindow and not ctx.rgArmed then
    k, lv, nt = pick(key(S.THE_HUNT), "ROTATION"); if k then return k, lv, nt end
  end

  -- L4 — IMMOLATION AURA in AoE (simc:69-74, above the meta fork).  Every one of those five
  -- lines is gated on a target count or a charge-cap check; `active_enemies` has no channel,
  -- so it collapses to the MANUAL mode toggle — a player DECLARATION, never an observation,
  -- exactly as Destruction's Rain of Fire and Retribution's Divine Storm do.
  -- ⚠ The anti-charge-cap half (`charges=2|full_recharge_time<gcd.max*2`) is NOT
  -- reimplemented: with A Fire Inside this is a 2-charge pool and usable() already presses
  -- it whenever a charge is banked, which is the same behaviour by a shorter road.
  if ctx.mode == "aoe" and ctx.immoUsable then
    k, lv, nt = pick(key(S.IMMOLATION_AURA), "ROTATION", "AoE"); if k then return k, lv, nt end
  end

  -- L5 — VENGEFUL RETREAT, just before Eye Beam (simc:79-81).  Its whole rotational purpose
  -- is proccing Initiative / triggering Inertia in the GCD before a burst window, so it is
  -- gated on Eye Beam being ready-or-nearly and on Initiative NOT already being up.
  -- ⚠ THE ONE CROSS-ABILITY TIMING READ IN THE FILE — see EYE_BEAM_LEAD's banner for why it
  -- is licensed here and nowhere else.  `eyeBeamUsable` is included beside `eyeBeamSoon`
  -- because simc's `remains<=gcd.remains` includes zero: with Eye Beam already up, the
  -- retreat goes FIRST and Eye Beam follows on the next GCD (L9).
  -- ⚠ The Inertia half of simc's gate is dropped — `buff.inertia_trigger` is a third aura
  -- with no tracked row (rotation.md Deviation 2), so an Inertia build loses the
  -- optimisation and keeps the press.
  if ctx.vrUsable and (ctx.eyeBeamUsable or ctx.eyeBeamSoon) and not ctx.initiative then
    k, lv, nt = pick(key(S.VENGEFUL_RETREAT), "ROTATION", "before Eye Beam")
    if k then return k, lv, nt end
  end

  -- L6 — [META] ESSENCE BREAK (simc's actions.meta:121).  META-ONLY, and that is what the
  -- APL says rather than an inference: the top-level `essence_break` action at :87 sits
  -- INSIDE a `#` comment, so `actions.meta` is its only surviving home.  ⚠ That may be a
  -- simc authoring accident rather than a tuning decision — taking the file literally is the
  -- Tier-1-faithful call and it fails safe (a missed press, never a wrong one).  Re-check on
  -- the next simc pull.  `fury>=35` is simc's own number.
  -- ⚠ `fury>=35` IS DROPPED, and it is the one genuine ROTATIONAL regression of the secrecy
  -- finding.  It was a POOLING rule — the 4 s window wants Fury behind it to flood — not a
  -- press cost: Essence Break 258860 has NO PowerType-17 row in DB2 `SpellPower`, so it
  -- costs nothing and `IsSpellUsable` has nothing to report.  With no readable Fury there is
  -- no replacement, so the window can now open on an empty bar and the lines below it
  -- generate rather than spend inside it.  Every other dropped gate loses a nuance on a
  -- press that stays correct; this one can waste a 40 s cooldown.  rotation.md Dev. 13.
  if ctx.inMeta and ctx.essenceBreakUsable then
    k, lv, nt = pick(key(S.ESSENCE_BREAK), "ROTATION"); if k then return k, lv, nt end
  end

  -- L7 — [META] BLADE DANCE, which the frame draws as DEATH SWEEP.  In demon form Death
  -- Sweep heads the meta list (actions.meta:118 / :122 / :130, all above eye_beam at :129),
  -- and out of it Eye Beam comes first (:86 above :88).  That inversion is ONE of the two
  -- things the fork genuinely changes, and it is why this line and L10 are separate.
  if ctx.inMeta and ctx.bladeDanceUsable and ctx.danceAfford then
    k, lv, nt = pick(key(S.BLADE_DANCE), "ROTATION", "Death Sweep"); if k then return k, lv, nt end
  end

  -- L8 — THE SPENDER inside an Essence Break window (simc:89 outside meta, :119 inside).
  -- Essence Break is a ~4 s amplification window and the whole point is to flood it with
  -- spenders; casting anything weak inside it is the mistake the line exists to prevent.
  -- The window comes from CAST HISTORY, not an aura — see EB_WINDOW's banner.
  if ctx.ebWindow and ctx.spenderAfford then
    k, lv, nt = pick(ctx.spenderKey, "ROTATION", "Essence Break window")
    if k then return k, lv, nt end
  end

  -- L9 — EYE BEAM on cooldown, which Fel-Scarred draws as ABYSSAL GAZE.  simc's gate is a
  -- six-clause alignment expression (`eb_aligned`, `raid_event.adds`, `desired_targets`,
  -- Eternal Hunt) built almost entirely from secret cooldown reads and sim-only facts.  What
  -- survives is "it is up and you can afford it", which is also what the KB says.
  if ctx.eyeBeamUsable and ctx.eyeBeamAfford then
    k, lv, nt = pick(key(S.EYE_BEAM), "ROTATION"); if k then return k, lv, nt end
  end

  -- L10 — [NO META] BLADE DANCE (simc:88, below eye_beam).  The other half of L7.
  -- ⚠ `variable.use_blade_dance` IS TREATED AS TRUE, and this is the one place the list
  -- deliberately chooses OVER-pressing.  simc gates it on three unreadable talents, and
  -- First Blood — the standard single-target pick — makes Blade Dance a full ST spender.
  -- Gating on `mode == "aoe"` instead would make it INVISIBLE for the whole single-target
  -- rotation of the standard build; over-pressing it on a First-Blood-less build costs a
  -- little damage on a press that is still positive.  rotation.md Deviation 8.
  if not ctx.inMeta and ctx.bladeDanceUsable and ctx.danceAfford then
    k, lv, nt = pick(key(S.BLADE_DANCE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L11 — FELBLADE for Fury (simc:90).  ⚠ Filed CDM-**Utility** by Blizzard and cueable
  -- anyway, because the pipeline's fences read the SPEC-authored `cadence` — see the file
  -- header.
  -- ⚠ THE DEFICIT GATE IS GONE (2026-08-03): a Fury deficit is `max - value` and `value` is
  -- secret.  Position replaces it — Felblade fires when usable and the spender sits
  -- IMMEDIATELY BELOW, so the press costs one GCD the rotation was going to spend generating
  -- anyway.  That is Blizzard's own handling (`assisted_combat` presses a BARE `felblade`
  -- between two `chaos_strike` lines).  Felblade's real 12 s cooldown is what makes
  -- "whenever usable" self-limiting; Immolation Aura's 30 s charge category is not, which is
  -- why L12 went BELOW the dump and this did not.
  if ctx.felbladeUsable then
    k, lv, nt = pick(key(S.FELBLADE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L13 — THE SPENDER (simc:95 outside meta, :134 inside): the main Fury dump, and the line
  -- that runs most of the time.  In demon form the frame casts Annihilation.
  -- ⚠ EVALUATED HERE, BETWEEN L11 AND L12 — see RankWinner's header.  The label stays 13.
  -- ⚠ simc's threshold is `75 - gen*gcd - 20*cs_machine + 25*pool_glaive_tempest`, three
  -- terms of which are talent-derived and unreadable — and since 2026-08-03 the FOURTH term,
  -- Fury itself, is unreadable too.  "Can you afford it" is no longer a reduction of simc's
  -- gate; it is the only formulation the client can answer.  rotation.md Deviation 9.
  if ctx.spenderAfford then
    k, lv, nt = pick(ctx.spenderKey, "ROTATION", ctx.inMeta and "Annihilation" or nil)
    if k then return k, lv, nt end
  end

  -- L12 — IMMOLATION AURA for Fury (simc:91-92), the second and lower of its two lines.
  -- Fel-Scarred draws this frame as CONSUMING FIRE.  Deficit gate dropped as L11's was, and
  -- it moved BELOW the spender for the reason stated there: a 30 s charge category left
  -- ungated above the dump would take the press on every recharge.
  if ctx.immoUsable then
    k, lv, nt = pick(key(S.IMMOLATION_AURA), "ROTATION"); if k then return k, lv, nt end
  end

  -- L14 — FEL RUSH as the AoE filler (simc:94, `active_enemies>1`).  Also CDM-Utility.
  -- ⚠ THIS IS THE ABILITY WHOSE READINESS THE HUD IS LEAST SURE OF: its base cooldown reads
  -- ONE SECOND against a real ten (SpecHavoc.lua's header), and only the charge count keeps
  -- it honest.  Deliberately low in the list and AoE-gated, so an early cue costs a filler
  -- press at worst — the mode toggle is doing double duty as a blast radius here.
  if ctx.mode == "aoe" and ctx.felRushUsable then
    k, lv, nt = pick(key(S.FEL_RUSH), "ROTATION", "AoE"); if k then return k, lv, nt end
  end

  -- L15 — THROW GLAIVE, the last-resort filler (simc:99).  simc's OTHER Throw Glaive line
  -- (:93) is the Soulscar / Furious Throws build's rotational press, gated on three talents
  -- we cannot read; folding to the filler under-presses it on that build and is correct
  -- everywhere else.  On Aldrachi Reaver this frame becomes Reaver's Glaive, which L1 has
  -- already claimed by the time evaluation reaches here.
  -- ⚠ AND ITS FALLBACK COST WAS **WRONG** — the reason this line won 770 of 2380 flight
  -- lines.  `GLAIVE_COST_FALLBACK = 25` came from DB2 `SpellPower`, but the live client
  -- reports Throw Glaive with `insufficientPower = false` at a Fury level where Chaos
  -- Strike, Eye Beam and Blade Dance all reported true — i.e. FREE.  Against a fabricated
  -- Fury of 0, `0 >= 25` was false for everything else and this line inherited the rotation.
  -- ⚠ DB2 COSTS ARE NOT THE CLIENT'S COSTS.  Asking the client is now the only channel.
  if ctx.throwGlaiveUsable and ctx.glaiveAfford then
    k, lv, nt = pick(key(S.THROW_GLAIVE), "ROTATION"); if k then return k, lv, nt end
  end

  -- No press.  Honest, and visible in the decision log as `w:-`.
  -- ⚠ READ THE WINNER **DISTRIBUTION**, NOT THIS RATIO, when judging a flight.  The failed
  -- 2026-08-03 pass scored 0.0 % in-combat `w:-` — a perfect score — precisely BECAUSE the
  -- generator lines were jammed on and something always won.  A low ratio proves the list
  -- always has an answer, not that the answer is right.  The acceptance is that Chaos
  -- Strike / Annihilation is the MOST COMMON winner, as it is in any real Havoc rotation.
  -- ⚠ If `w:-` is genuinely high, the suspect is no longer the Fury rail (nothing reads it):
  -- check `usable()`'s charge inputs and the CDM coverage first.
  return nil
end

--------------------------------------------------------------------------------
-- Escalate — Havoc's readable overdue-ness.
--------------------------------------------------------------------------------
-- Two readable ways to be late, and NO window suppression: unlike Demonology (where a ready
-- summon inside the Tyrant window is a STAGED press, not a forgotten one), Havoc holds
-- nothing, so a ready cooldown sitting idle is always genuinely late.
function spec:Escalate(winnerKey, level, ctx)
  if not winnerKey or level ~= "ROTATION" then return level end
  local S = ids()
  local rec = ctx.facts[winnerKey]
  if not rec then return level end

  -- 1. A cooldown left sitting past the lead.  `overdue` is computed by the shell off
  --    cd.changedAt, i.e. from how long it has READ ready — not from a napkin guess.
  --    ⚠ ONLY THE FOUR SPELL-ROW COOLDOWNS ARE LISTED, and the exclusions are the point.
  --    Metamorphosis (120 s), The Hunt (90 s), Eye Beam (30 s) and Blade Dance (15 s) all
  --    carry their cooldown as `CategoryRecoveryTime` on the SPELL row, so ns.BaseCooldown
  --    reads them and the ready-edge means something.  Every ability on a CHARGE CATEGORY
  --    is deliberately absent: a charged ability raises `Available` on every charge restore
  --    and never `OnCooldown`, so its edge latches and `overdue` would fire constantly.
  --    Essence Break is absent too, for a different reason — its `RecoveryTime` is honest,
  --    but it is META-GATED (L6), so a ready Essence Break outside demon form is correctly
  --    idle rather than late, and escalating it would nag for a press the list refuses to
  --    make.  Escalating on a signal we cannot trust is exactly what this method is
  --    forbidden to do.
  if (rec.base == S.METAMORPHOSIS or rec.base == S.THE_HUNT
      or rec.base == S.EYE_BEAM or rec.base == S.BLADE_DANCE) and rec.overdue then
    return "LATE"
  end

  -- 2. ⚠ THE "SPENDER PARKED AT A FULL FURY BAR" RULE IS **DELETED** (2026-08-03), NOT
  --    MOVED.  It was the analogue of Destruction's Chaos-Bolt-at-full-bar and
  --    Retribution's spender-at-cap, and it read `ctx.fury >= ctx.furyMax` — a comparison
  --    against a value that DOES NOT EXIST.  Fury is secret (see the file header); the rule
  --    fired on `0 >= 120`, i.e. never, and restoring it against any fabricated number
  --    would make it fire ALWAYS, which is worse.
  --
  --    ⚠ IT IS ALSO NOT RECOVERABLE THROUGH THE NEW CHANNEL.  `IsSpellUsable` is BINARY: a
  --    spender is equally "affordable" at 40 Fury and at 170, so overcap is invisible to it
  --    BY CONSTRUCTION.  This is the single thing Phase 1 knowingly gives up.  The only
  --    route back is Phase 2's `LuaCurveObject` — `UnitPowerPercent(unit, type, unmodified,
  --    curve)` evaluated in C and handed straight to a draw call, so Lua never sees the
  --    number.  docs/multi-class-rollout.md carries the design.  DO NOT reinstate this
  --    against a Lua-side value; there will never be one.

  return level
end
