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

-- Fury costs, ALWAYS resolved live through env.powerCostFn (talent-modifiable); these are
-- only the fallbacks for a harness or an unreadable read.  Never hardcode a cost at a call
-- site.  T1 DB2 @ 12.0.7, SpellPower PowerType 17 — and the OVERRIDES carry the same
-- numbers on their own ids (Annihilation 40, Death Sweep 35, Abyssal Gaze 30), which is one
-- of the properties that identified them.
spec.SPENDER_COST_FALLBACK  = 40   -- Chaos Strike / Annihilation
spec.DANCE_COST_FALLBACK    = 35   -- Blade Dance / Death Sweep
spec.EYE_BEAM_COST_FALLBACK = 30   -- Eye Beam / Abyssal Gaze
spec.GLAIVE_COST_FALLBACK   = 25   -- Throw Glaive / Reaver's Glaive

-- L6's Fury floor, simc's own number (`essence_break,if=fury>=35`).  A press gate, not a
-- pooling rule.
spec.ESSENCE_BREAK_FURY = 35

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

-- The Fury DEFICITS that gate the two generator lines.  simc computes them against
-- `variable.fury_gen_per_sec`, a six-term expression including haste and three buff stack
-- counts — none of which is on the pulse.  Flat thresholds are the honest reduction:
-- simc's :90 is `fury.deficit>=15+gen*0.5` (~25 at typical haste) and :92 is
-- `fury.deficit>20+gen*gcd.max` (~35).  Rounded to numbers that keep the two lines in the
-- same order rather than pretending to a precision we do not have.
spec.FELBLADE_DEFICIT = 40
spec.IMMO_DEFICIT     = 20

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

  -- The in-flight projection, derived from the pulse's cast history.
  local sums = ns.Coach.InflightPower(state, ns.SpecPowerDelta)

  -- ── THE FURY RAIL ──────────────────────────────────────────────────────────
  -- Shared arithmetic (ns.Coach.PowerContext): the exact read, the display-value fallback
  -- when the client refuses, the cap fallbacks, and the ctx.powers fold.  ⚠ Fury's modifier
  -- is 1, so `rails.Fury.value` is simply Fury — there is no second unit in this spec and
  -- nothing here is named `*Frags`.
  local bars, rails = ns.Coach.PowerContext(state, self, sums)
  local furyRail = rails.Fury or {}

  local ctx = {
    facts = factsByBase,
    mode = state.mode,
    fury = furyRail.value,
    furyIncoming = furyRail.incoming or 0,
    furyMax = furyRail.max or self.FURY_CAP,
    furyProjected = furyRail.projected,
    atCap = furyRail.atCap or false,
    powerReadable = furyRail.readable or false,
  }
  ctx.powers = bars

  -- WHICH RESOURCE THIS SPEC'S COSTS ARE DENOMINATED IN.  Resolved from `spec.powers` by
  -- the shell kit, NOT written as a literal here — `Enum.PowerType.Fury` is 17, but a brain
  -- that hardcodes 17 is one refactor away from the Soul-Shard bug in a new direction.
  -- nil (no Enum / nothing declared) means every cost falls back to the declared constant,
  -- which is the honest degradation.
  ctx.costPowerType = ns.Coach.CostPowerType(self)

  -- The live costs.  The shell owns the INJECTED reader (env.powerCostFn = cfg.powerCost);
  -- this brain owns WHICH spells cost, in WHICH resource, and the fallbacks.
  --
  -- ⚠ NO UNIT CONVERSION.  Fury's divisor is 1, so display units ARE exact units.
  -- Destruction multiplies by 10 at this exact point; copying that here would be a silent
  -- 10x error that no test would catch, because 40 * 10 is still a plausible-looking gate.
  --
  -- ⚠ A COST OF **0** IS AN ANSWER, NOT A REFUSAL.  `ns.PowerCost` is three-valued since
  -- 2026-08-03 — nil means unreadable, 0 means explicitly free — so this guard tests for a
  -- NUMBER and lets a real zero through.  `nil` MUST fall through to the fallback; a spec
  -- whose cost cannot be read must under-promise, never cue a press that fails.
  local function costOf(spellID, fallback)
    if env and env.powerCostFn and spellID and ctx.costPowerType then
      local c = env.powerCostFn(spellID, ctx.costPowerType)
      if type(c) == "number" then return c end
    end
    return fallback
  end

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

  -- ── The spender, and the three other Fury costs ────────────────────────────
  -- ⚠ THE COST IS OF THE SPELL WE WILL ACTUALLY PRESS, not of the base always.  In demon
  -- form the frame casts Annihilation, and only the LIVE id carries Annihilation's own
  -- cost — which happens to be identical today (40) and must not be assumed to stay so.
  -- Falls back to the base id where there is no transform, and to the declared constant
  -- where the client refuses.  Retribution learned this one the same way.
  local function liveOf(base)
    local rec = base and factsByBase[base]
    return (rec and rec.live) or base
  end
  -- The BASE key the spend lines return.  Resolved through `facts`, so an untracked Chaos
  -- Strike yields nil and both spend lines simply find nothing rather than cueing a ghost.
  ctx.spenderKey     = factsByBase[S.CHAOS_STRIKE] and S.CHAOS_STRIKE or nil
  ctx.spenderCost    = costOf(liveOf(S.CHAOS_STRIKE),  self.SPENDER_COST_FALLBACK)
  ctx.danceCost      = costOf(liveOf(S.BLADE_DANCE),   self.DANCE_COST_FALLBACK)
  ctx.eyeBeamCost    = costOf(liveOf(S.EYE_BEAM),      self.EYE_BEAM_COST_FALLBACK)
  ctx.glaiveCost     = costOf(liveOf(S.THROW_GLAIVE),  self.GLAIVE_COST_FALLBACK)

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
function spec:RankWinner(ctx, excluded)
  local S = ids()
  -- Fury throughout, plain integers: `projected` is the live rail plus the signed in-flight
  -- delta.  There is no second unit in this spec.
  local projected = ctx.furyProjected or ctx.fury or 0
  -- The DEFICIT gates read the LIVE value, not the projection: a spender already in flight
  -- has committed to draining the bar, and crediting that drain toward "I need Fury" would
  -- fire the generator lines a GCD early on every single spend.
  local live = ctx.fury or 0
  local deficit = (ctx.furyMax or self.FURY_CAP) - live

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
  -- ⚠ simc:103 is the longest single line in the APL and only THREE of its terms survive.
  -- `!buff.inner_demon.up` is readable (389693 is tracked).  `cooldown.blade_dance.remains`
  -- means "Blade Dance is ON cooldown", which is `not bladeDanceUsable` — one of the few
  -- cooldown-remains terms in this APL that survives as a BOOLEAN rather than a duration.
  -- The Eye Beam alignment block (five `cooldown.eye_beam.remains>=N` clauses) is dropped
  -- entirely: every term is a secret read, and holding a 2-minute cooldown on a gate we
  -- cannot evaluate would be worse than landing it out of sync.
  if ctx.metaUsable and not ctx.innerDemon and not ctx.bladeDanceUsable then
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
  if ctx.inMeta and ctx.essenceBreakUsable and live >= self.ESSENCE_BREAK_FURY then
    k, lv, nt = pick(key(S.ESSENCE_BREAK), "ROTATION"); if k then return k, lv, nt end
  end

  -- L7 — [META] BLADE DANCE, which the frame draws as DEATH SWEEP.  In demon form Death
  -- Sweep heads the meta list (actions.meta:118 / :122 / :130, all above eye_beam at :129),
  -- and out of it Eye Beam comes first (:86 above :88).  That inversion is ONE of the two
  -- things the fork genuinely changes, and it is why this line and L10 are separate.
  if ctx.inMeta and ctx.bladeDanceUsable and projected >= (ctx.danceCost or 0) then
    k, lv, nt = pick(key(S.BLADE_DANCE), "ROTATION", "Death Sweep"); if k then return k, lv, nt end
  end

  -- L8 — THE SPENDER inside an Essence Break window (simc:89 outside meta, :119 inside).
  -- Essence Break is a ~4 s amplification window and the whole point is to flood it with
  -- spenders; casting anything weak inside it is the mistake the line exists to prevent.
  -- The window comes from CAST HISTORY, not an aura — see EB_WINDOW's banner.
  if ctx.ebWindow and projected >= (ctx.spenderCost or 0) then
    k, lv, nt = pick(ctx.spenderKey, "ROTATION", "Essence Break window")
    if k then return k, lv, nt end
  end

  -- L9 — EYE BEAM on cooldown, which Fel-Scarred draws as ABYSSAL GAZE.  simc's gate is a
  -- six-clause alignment expression (`eb_aligned`, `raid_event.adds`, `desired_targets`,
  -- Eternal Hunt) built almost entirely from secret cooldown reads and sim-only facts.  What
  -- survives is "it is up and you can afford it", which is also what the KB says.
  if ctx.eyeBeamUsable and projected >= (ctx.eyeBeamCost or 0) then
    k, lv, nt = pick(key(S.EYE_BEAM), "ROTATION"); if k then return k, lv, nt end
  end

  -- L10 — [NO META] BLADE DANCE (simc:88, below eye_beam).  The other half of L7.
  -- ⚠ `variable.use_blade_dance` IS TREATED AS TRUE, and this is the one place the list
  -- deliberately chooses OVER-pressing.  simc gates it on three unreadable talents, and
  -- First Blood — the standard single-target pick — makes Blade Dance a full ST spender.
  -- Gating on `mode == "aoe"` instead would make it INVISIBLE for the whole single-target
  -- rotation of the standard build; over-pressing it on a First-Blood-less build costs a
  -- little damage on a press that is still positive.  rotation.md Deviation 8.
  if not ctx.inMeta and ctx.bladeDanceUsable and projected >= (ctx.danceCost or 0) then
    k, lv, nt = pick(key(S.BLADE_DANCE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L11 — FELBLADE for Fury (simc:90).  ⚠ Filed CDM-**Utility** by Blizzard and cueable
  -- anyway, because the pipeline's fences read the SPEC-authored `cadence` — see the file
  -- header.  simc's `fury.deficit>=15+gen*0.5` becomes a flat deficit: `fury_gen_per_sec`
  -- is a six-term expression including haste and three stack counts, none of it on the
  -- pulse, and a fabricated generation rate would be a guess dressed as arithmetic.
  if ctx.felbladeUsable and deficit >= self.FELBLADE_DEFICIT then
    k, lv, nt = pick(key(S.FELBLADE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L12 — IMMOLATION AURA for Fury (simc:91-92), the second and lower of its two lines.
  -- Same flat-deficit reduction as L11.  Fel-Scarred draws this frame as CONSUMING FIRE.
  if ctx.immoUsable and deficit >= self.IMMO_DEFICIT then
    k, lv, nt = pick(key(S.IMMOLATION_AURA), "ROTATION"); if k then return k, lv, nt end
  end

  -- L13 — THE SPENDER (simc:95 outside meta, :134 inside): the main Fury dump, and the line
  -- that runs most of the time.  In demon form the frame casts Annihilation.
  -- ⚠ simc's threshold is `75 - gen*gcd - 20*cs_machine + 25*pool_glaive_tempest`, three
  -- terms of which are talent-derived and unreadable.  With none of them the gate is simply
  -- "can you afford it", which is the implicit affordability gate every line already
  -- carries.  The POOLING nuance is lost; the press is not.  rotation.md Deviation 9.
  if projected >= (ctx.spenderCost or 0) then
    k, lv, nt = pick(ctx.spenderKey, "ROTATION", ctx.inMeta and "Annihilation" or nil)
    if k then return k, lv, nt end
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
  if ctx.throwGlaiveUsable and projected >= (ctx.glaiveCost or 0) then
    k, lv, nt = pick(key(S.THROW_GLAIVE), "ROTATION"); if k then return k, lv, nt end
  end

  -- No press.  Honest, and visible in the decision log as `w:-` — which on this spec is the
  -- signature of "every cooldown is down and there is not enough Fury for a spender", a real
  -- state rather than a bug.  ⚠ Havoc should show it LESS than Retribution did (13.9 % in
  -- combat on v0.32.90): Chaos Strike has no cooldown at all, so L13 is reachable on every
  -- tick the bar carries 40 Fury.  A high in-combat `w:-` here means the FURY RAIL is not
  -- being read, not that the list has a hole — check `PW:` first.
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

  -- 2. The spender parked at a FULL Fury bar — the readable overcap dump, the analogue of
  --    Destruction's Chaos-Bolt-at-full-bar rule and Retribution's spender-at-cap.  Gated
  --    on ACTUAL Fury, not the projection: an in-flight spender has already committed to
  --    draining the bar, so projecting it would call you late for something you are mid-way
  --    through fixing.  No burst carve-out, because Havoc never pools for a window on
  --    purpose.
  if rec.base == ctx.spenderKey and ctx.fury
      and ctx.fury >= (ctx.furyMax or self.FURY_CAP) then
    return "LATE"
  end

  return level
end
