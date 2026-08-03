-- SpecHavoc.lua — the per-spec DATA table for Havoc Demon Hunter (577).
--
-- The project's FOURTH registered spec and the SECOND class outside Warlock.  It is DATA
-- ONLY: named IDs, the power array, the decision-log vocabulary, the per-spellID signal
-- bucket, and the two lookup helpers the pipeline calls.  The rotation BRAIN (Context /
-- RankWinner / Escalate) is CoachHavoc.lua, which hangs itself on the object this file
-- registers.
--
-- WHAT IS DELIBERATELY ABSENT.  All nine dormant Tier-3 tables (SpecGroups / SpecColor /
-- SpecPole / SpecGhost / SpecNoCue / SpecProcGlow / SpecStacks / SpecOpener / SpecBurst).
-- None has a live consumer in the v1 pipeline; SpecDestruction and SpecRetribution omitted
-- all nine and nothing broke.  This file follows them, not Demonology.
--
-- ⚠ AND NO `spec.derived` BLOCK, WHICH IS A DECISION AND NOT AN OMISSION.  The Phase-0.3
-- class-resource channel exists for Demon Hunter Soul Fragments, so a DH spec is exactly
-- where a reader expects to find one.  Havoc does not have that resource.  Three Tier-1
-- checks, recorded here because "the DH spec that declares no fragments" will otherwise
-- read as a hole:
--   1. `demonhunter_havoc.simc` references `soul_fragments` ONCE, as one of three ORed
--      alternatives gating a single `annihilation` line.  `demonhunter_vengeance.simc`
--      references it 32 times.  Havoc's resource is Fury; Vengeance's is fragments.
--   2. Neither shipped reader is Havoc's.  The `castCount` path reads Soul Cleave 228477,
--      a VENGEANCE spell Havoc does not have; the `auraStacks` path reads Dark Heart
--      1225789, and Blizzard's own DemonHunterSoulFragmentsBar.lua:18 sets
--      `self.requiredSpec = SPEC_DEMONHUNTER_DEVOURER` — the fragment bar is DEVOURER-ONLY.
--   3. What Aldrachi Reaver Havoc interacts with are ordinary BUFFS (Rending Strike,
--      Glaive Flurry, Reaver's Mark, Thrill of the Fight), which ride the existing
--      `item:IsActive()` presence channel, not a counter.
-- Vengeance (`castCount`) and Devourer (`auraStacks`) remain the channel's first consumers.
--
-- THE SIGNAL BUCKET (`spec.Spec`).  Same vocabulary as the three shipped specs; the fields
-- the generic shell actually reads are `kind` / `cadence` / `label` / `abbr` / `expect`,
-- and everything else is this spec's private convention (read by the brain):
--   kind       — "button" (an icon you press) | "aura" (a buff-viewer input, never scored)
--   spends     — "fury" = this press costs Fury.  The numeric cost is NEVER authored here
--                — it is talent-modifiable, so it is read at runtime through the general
--                `env.powerCostFn` (ns.PowerCost) asked about THIS SPEC'S resource
--                (ns.Coach.CostPowerType), with a fallback constant on the brain.
--   charges    — documented charge count, sanity-check only (State reports the live one).
--   chargeCD   — documented CHARGE-CATEGORY recovery, in seconds.  READ by
--                HudNapkin.lua:113-119 when the live base cooldown reads 0, filed
--                `source = "declared"`.  Edit these as live data, not as prose.
--                ⚠ ON THIS SPEC THE FALLBACK OFTEN CANNOT FIRE — see THE LYING COOLDOWNS.
--   cadence    — "oncd" | "gated" | "reactive" | "filler" | "utility".
--                ⚠ THIS FIELD, NOT THE CDM CATEGORY, IS WHAT MAKES AN ABILITY CUEABLE.
--                Three of Havoc's rotational presses (Felblade, Vengeful Retreat, Fel
--                Rush) are filed CDM-**Utility** by Blizzard, and the rollout plan expected
--                that to need a pipeline edit.  It does not: the SOON fence
--                (Coach.lua:501) and the virtual-row fence (State.lua:1941) both test the
--                SPEC-AUTHORED `info.cadence`.  Declaring them "filler"/"oncd" here is the
--                whole fix.  The CDM category only decides which viewer frame they draw on
--                and how a claim is ranked when two roster entries contest one row.
--   expect     — DEFAULT TRUE.  False = "never expect this bound to a CDM icon of its own".
--                ⚠ LOAD-BEARING: State.lua's virtual-row walk auto-promotes an untracked
--                kind="button" ability with no base cooldown into a self-drawn icon, so an
--                OVERRIDE that passed those fences would draw a duplicate beside the real
--                one.  Every one of this spec's six overrides carries it.
--   baseCD     — documented base cooldown, sanity-check only (ns.BaseCooldown reads live)
--   label      — human name, for `/cdmp hud status`
--   abbr       — the decision-log short code (ONE edit site per ability)
--
-- ⚠⚠ THE LYING COOLDOWNS — THIS SPEC'S DEFINING OBSERVABILITY FACT.  Retribution's was
-- four Essential buttons whose cooldown lives on a charge category with RecoveryTime = 0,
-- so `ns.BaseCooldown` reads 0 and the napkin has nothing to count.  Havoc's is worse in
-- KIND: three buttons report a base cooldown that is not absent but WRONG, because a short
-- SHARED-CATEGORY lockout sits on the spell row while the real recovery lives on a charge
-- category.  T1 DB2 @ 12.0.7:
--
--     Fel Rush 195072          RecoveryTime 1000  vs ChargeCategory 1545 recovery 10000
--     Immolation Aura 258920   CategoryRecoveryTime 1500  vs ChargeCategory 1676 rec 30000
--     Vengeful Retreat 198793  RecoveryTime  500  vs ChargeCategory 1601 recovery 25000
--
-- A lie defeats the mitigation an honest zero gets: HudNapkin's declared-`chargeCD`
-- fallback is gated on `not (type(len) == "number" and len > 0)`, which an honest 0 trips
-- and a lying 1 does not.  So Fel Rush gets a ONE-SECOND napkin against a TEN-SECOND
-- cooldown and no constant below can rescue it.
--
-- WHAT SAVES IT, AND IT WAS NOT BUILT FOR THIS: all three are ONE-charge categories, and
-- `usable()`'s one-charge rule — shipped for Retribution's flight defect #5 on 2026-08-03
-- — requires BOTH a banked charge AND `probablyUp` for a pool of one.  The charge napkin
-- decrements on the cast and only restores on the `ChargeGained` alert at the REAL
-- recovery, so the count vetoes the early cooldown read for the whole duration.  The PRESS
-- is protected; only the DECORATION lies.  The `chargeCD` numbers below are authored anyway
-- — they are the right numbers, and they become live the moment the fence changes.
--
-- ⚠ THE RESIDUAL RISK IS NARROW AND REAL, and it is flight question #1
-- (specs/havoc/observability-map.md): if the charge count is ABSENT — `ch.charged` false,
-- or no out-of-combat seed, since `C_Spell.GetSpellCharges` is combat-gated — `usable()`
-- falls through to `probablyUp or chargeBanked` and the early napkin wins.  Do NOT
-- pre-emptively "fix" this by widening the napkin: the fix is a pipeline edit against a
-- symptom nobody has observed, and specs/havoc/rotation.md records the exact one-line shape
-- it should take if the flight shows it biting.
--
-- ⚠ DESK-DERIVED, NOT YET FLOWN.  Every ID below is Tier-1 (wago DB2 @ 12.0.7, fetched
-- 2026-08-03: CooldownSetSpell for set 1599, SpellCooldowns, SpellCategories +
-- SpellCategory, SpellPower, SpellEffect, SkillLineAbility).  They are not guesses, and
-- NONE was resolved by name — Demon Hunter has the Hammer-of-Light problem twice over
-- (SpellName carries 76 rows called "Annihilation" and 19 called "Chaos Strike").  Every
-- override below was discriminated by `SpellEffect.EffectAura == 332`
-- (override-actionbar-spell) plus a corroborating property; the method is recorded at each
-- entry because it matters more than the answer.
local ADDON, ns = ...

local spec = {}

-- Named IDs.  Tier-1: wago DB2 @ 12.0.7, CooldownSet 1599.
spec.SpecIDs = {
  -- ── Essential: the rotation buttons (CooldownSetSpell set 1599, category 0) ──
  -- ⚠ CHAOS STRIKE IS 162794, NOT 344862, and the difference is not cosmetic.  SkillLine
  -- 1848 (Havoc) teaches a WRAPPER spell 344862 whose only SpellEffect is a bare dummy;
  -- 162794 is the row the Cooldown Manager tracks, carries the PowerType-17 cost of 40, and
  -- triggers the real damage spells (222031 / 199547).  The domain view is anchored on the
  -- roster and joined against the CDM, so the id that JOINS is the one to declare.  The
  -- action-bar id is handled by SpecBindAlias below.
  CHAOS_STRIKE      = 162794,
  BLADE_DANCE       = 188499,
  IMMOLATION_AURA   = 258920,
  EYE_BEAM          = 198013,
  THROW_GLAIVE      = 185123,
  -- Same wrapper story as Chaos Strike: 344865's ONLY effect is `Effect 64, trigger ->
  -- 195072`, so 195072 is the tracked id and 344865 is what your keybind is on.
  -- ⚠ FEL RUSH HAS **TWO** CDM ROWS — one Essential, one Utility, same spellID.  One
  -- ability, two rows; St.RosterClaims assigns each row to at most one ability and ranks
  -- Essential above Utility, so this should claim the Essential row and leave the other
  -- unclaimed.  Never verified live — observability-map question 4.
  FEL_RUSH          = 195072,
  THE_HUNT          = 370965,
  METAMORPHOSIS     = 191427,
  ESSENCE_BREAK     = 258860,
  -- ⚠ RAIN FROM ABOVE IS A DEAD ICON, ON PURPOSE.  A tracked Essential with a real 90 s
  -- cooldown that appears NOWHERE in the 140-line APL.  It is registered so the decision
  -- log can name it and so Coverage does not report it blind — never because a line cues
  -- it.  `cadence = "utility"` below is what keeps it out of the SOON decoration: an
  -- anticipation glow on a button the HUD will never recommend is a promise, not a hint.
  RAIN_FROM_ABOVE   = 206803,

  -- ── The three rotational presses Blizzard filed as UTILITY ───────────────────
  -- See the `cadence` note in the header: this needs no pipeline edit, only an honest
  -- cadence.  Felblade is the Fury generator (12 s, the one HONEST RecoveryTime among the
  -- three); Vengeful Retreat procs Initiative and is pressed before every Eye Beam.
  FELBLADE          = 232893,
  VENGEFUL_RETREAT  = 198793,

  -- ── The OVERRIDES — abilities with no icon of their own ──────────────────────
  -- ⚠ HAVOC'S STRUCTURAL GIFT: every one is a 1:1 replacement of ONE named base, riding
  -- that base's frame.  Retribution needed a semantic `spender` discriminator because two
  -- different frames could carry the same Hammer of Light; nothing here has that shape, so
  -- `ctx.facts[base]` is always the record and `rec.live` is always the label.
  --
  -- METAMORPHOSIS 162264 (the demon-form AURA, distinct from the 191427 cast that the CDM
  -- tracks) carries TWO `EffectAura 332` effects with basePoints 201427 and 210152.  That
  -- is the meta fork, proven from game data rather than from a guide:
  --   Annihilation 201427 — corroborated by PowerType 17 cost 40, identical to Chaos Strike
  --   Death Sweep  210152 — corroborated by SHARING Blade Dance's category 1640 AND its
  --                         Fury cost of 35, which is what an override of Blade Dance must do
  ANNIHILATION      = 201427,
  DEATH_SWEEP       = 210152,
  -- (Fel-Scarred) Demonsurge 452489 overrides Eye Beam 198013 with Abyssal Gaze — the
  -- `misc0` field names 198013 EXPLICITLY, and 452497 shares Eye Beam's category 1582 and
  -- its Fury cost of 30.
  ABYSSAL_GAZE      = 452497,
  -- (Fel-Scarred) Consuming Fire — A HOMONYM PAIR, and BOTH are registered because nothing
  -- separates them offline.  452489 grants 452487 by spell-class MASK (which covers
  -- Immolation Aura 258920) and 456640 against 427917 (a different Immolation Aura
  -- variant); both share ChargeCategory 1676.  Distinct `abbr` codes so ONE capture can
  -- answer which the client surfaces — the same reason Retribution carries two Hammer of
  -- Light entries and Destruction learned to stop sharing a code.
  CONSUMING_FIRE    = 452487,
  CONSUMING_FIRE_ALT = 456640,
  -- (Aldrachi Reaver) Reaver's Glaive 444686 overrides Throw Glaive with 442294 —
  -- `misc0 = 185123`, explicit, no inference.  ⚠ 444764 is the VENGEANCE sibling (it
  -- overrides 204157) and is deliberately NOT registered.
  REAVERS_GLAIVE    = 442294,
  -- (talent) Dash of Chaos 427793 overrides Fel Rush 195072 with 427785.  Registered only
  -- so a capture can NAME it; without an entry it would resolve to SpecInfo's NEUTRAL
  -- fallback and the trace would show an anonymous transform.
  FEL_RUSH_DASH     = 427785,

  -- ── Buff viewers — the tracked auras the list reads or the log names ─────────
  -- ⚠ THESE ARE THE **TRACKED** IDS, NOT THE REAL AURA IDS, and that is correct rather
  -- than sloppy.  `state.buffs` is keyed by the CDM ROW's base spellID
  -- (State.lua:2304), which for Havoc is almost always the TALENT id.  Declaring the real
  -- aura instead would create a roster entry with no CDM row — which Coverage reports as
  -- BLIND, and which no channel could ever answer.  The real aura ids are recorded in the
  -- comments because a future stack-capable channel will need them; the stack COUNTS are
  -- unreachable today regardless, since `item:IsActive()` is a bool.
  INNER_DEMON       = 389693,   -- vetoes Metamorphosis (simc's `!buff.inner_demon.up`)
  INITIATIVE        = 388108,   -- vetoes Vengeful Retreat.  Real aura 391215 (5 s, +crit)
  ART_OF_THE_GLAIVE = 442290,   -- real aura 444661, CumulativeAura 80 — the fragment
                                -- counter that ARMS Reaver's Glaive.  The parked switch.
  DEMONSURGE        = 452402,   -- real aura 452416, CumulativeAura 4
  INERTIA           = 427640,   -- real aura 427641 (5 s).  ⚠ NOT the inertia TRIGGER,
                                -- which is a third aura with no tracked row — see
                                -- rotation.md Deviation 2 before reading this as "armed".
  UNBOUND_CHAOS     = 347461,   -- real aura 347462 (12 s)
  CYCLE_OF_HATRED   = 258887,
  CHAOS_THEORY      = 389687,
  THRILL_OF_THE_FIGHT = 442686,
  REAVERS_MARK      = 442679,   -- ⚠ a DEBUFF ON THE TARGET filed as a TrackedBuff.  Whether
                                -- `IsActive()` reports one at all is unsettled and is
                                -- observability-map question 3 — it blocks nothing here and
                                -- decides Vengeance's Frailty channel.
  FURY_OF_THE_ALDRACHI = 442718,
  RAGEFIRE          = 388107,
  BURNING_WOUND     = 391189,
  SOULSCAR          = 388106,
  SERRATED_GLAIVE   = 390154,
  ARMY_UNTO_ONESELF = 442714,
  INCORRUPTIBLE_SPIRIT = 442736,
  EVASIVE_ACTION    = 444926,
  STUDENT_OF_SUFFERING = 452412,
  MONSTER_RISING    = 452414,
  MORTAL_DANCE      = 328725,
  FURIOUS_GAZE      = 343311,
  ETERNAL_HUNT      = 1270898,
  ETERNAL_HUNT_ALT  = 1270901,
  EXERGY            = 206476,
}

local S = spec.SpecIDs

-- ── THE ACTION-BAR / CDM ID SPLIT ────────────────────────────────────────────
-- `HudBinds.B.Resolve` walks the rung ladder (overrideTooltipSpellID -> overrideSpellID ->
-- base) and asks the ACTION BAR about each candidate.  For these two the tracked id is
-- never on a bar, so every rung misses and the icon silently loses its key hint.  This is
-- the Imp Lord case (cast id ≠ action-bar id), which is the one documented reason
-- SpecBindAlias exists.  Evidence, not inference — see SpecIDs' comments on each.
--
-- ⚠ NOTHING ELSE NEEDS AN ALIAS.  Havoc's six overrides all ride a frame whose BASE id IS
-- the one on the bar (you bind Chaos Strike and press Annihilation through it), which the
-- rung ladder already resolves.
spec.SpecBindAlias = {
  [S.CHAOS_STRIKE] = 344862,   -- SkillLine 1848 wrapper
  [S.FEL_RUSH]     = 344865,   -- SkillLine 1848 wrapper (`trigger -> 195072`)
}

-- ── FURY: TRACKED, DELIBERATELY NOT DRAWN ────────────────────────────────────
-- `Enum.PowerType.Fury` = 17.  0-120, modifier 1 — so the exact rail and the display rail
-- are the SAME integer and NONE of Destruction's fragment arithmetic applies.  Do not copy
-- the `*Frags` naming or the `cost * FRAGS_PER_SHARD` multiplication into this spec; at
-- modifier 1 the latter is a silent no-op that teaches the next reader the wrong lesson.
--
-- ⚠ `display = "none"` IS THE POINT, and it is not the same as declaring no powers.
--   * The HUD draws no bar: Blizzard's own Fury bar is right there, and the project's
--     stance is enhance-don't-replace.
--   * But an EMPTY spec.powers emits no resourceBars[] entry at all, and DecisionLog's
--     `PW:` field reads the BAR, not the pulse — so the trace would render `?/?` for the
--     whole spec, losing the primary instrument for debugging a brain nobody watches live.
--     `none` keeps the entire rail (ctx.powers -> resourceBars[] -> PW:) and turns off
--     exactly one thing: pixels.  Renderer.lua skips it on `display`.
--
-- ⚠ AND `continuous` IS NOT THE ALTERNATIVE, despite Fury looking like a continuous bar.
-- Its pixel path is a declared STUB that draws nothing, and `discrete` pools one pip
-- texture per unit of `max` (clamped at MAX_PIPS = 12) — a 120-max Fury bar would render
-- meaningless either way.  `none` is the member that was added for exactly these specs.
--
-- `incoming = true`: Coach:ResourceBars reads `p.incoming and sums[p.name]`, so declaring
-- it false would zero the incoming term and make `projected` permanently equal the live
-- value.  SpecPowerDelta below projects SPENDERS, and the brain ranks on projected
-- precisely so a spender in flight stops being re-cued mid-GCD.
spec.powers = {
  { name = "Fury", display = "none", incoming = true, token = "FURY",
    exactMax = 120, barMax = 120 },
}

-- The cap, as a fallback for a pulse-less caller.  DISPLAY units and exact units coincide.
spec.FURY_CAP = 120

-- The DECISION-LOG vocabulary (adding-a-spec.md Step 6).  DecisionLog.lua holds no spec
-- constants: per-ability short codes ride `abbr` on each spec.Spec entry, and the
-- non-per-ability bits live here.  Read off ns.ActiveSpec.log.
--   cdOrder    the S{CD:…} readiness render order, by abbr (deterministic).
--   procOrder  the S{PR:…} proc/buff render order, by code.
--   procBuffs  buff spellID -> PR code (the domain view's `buffs` is spellID-keyed).
spec.log = {
  -- Only the cooldown-BEARING rotation buttons; Chaos Strike has no cooldown at all.
  -- Order is burst -> the honest spell-row cooldowns -> the charge-category ones -> filler.
  cdOrder   = { "Meta", "Hunt", "EB", "EssB", "BD", "IA", "FB", "VR", "FR", "TG" },
  -- ⚠ A code absent from this list is SILENTLY DROPPED from `PR:`, so every override abbr
  -- has to appear here or the per-ID split buys nothing.  `CFire` / `CFire2` are the two
  -- Consuming Fire candidates and answering WHICH one surfaces is the reason they differ.
  procOrder = { "Meta", "ID", "Init", "AotG", "Inrt", "Dsrg", "UC", "CoH", "CT", "ToF",
                "RMk", "FotA", "Rage", "BWnd", "SoS", "MRis",
                "Anni", "DS", "AG", "CFire", "CFire2", "RG" },
  procBuffs = {
    -- ⚠ METAMORPHOSIS IS THE ONE THAT MUST NOT BE MISSING.  `ctx.inMeta` ORs this row's
    -- presence with the Chaos Strike transform, and the log is the only place that can say
    -- WHICH of the two forked the list.
    [191427]  = "Meta",   -- Metamorphosis (the Essential row doubles as the TrackedBuff)
    [389693]  = "ID",     -- Inner Demon      — vetoes L2
    [388108]  = "Init",   -- Initiative       — vetoes L5
    [442290]  = "AotG",   -- Art of the Glaive — the parked switch's source
    [427640]  = "Inrt",   -- Inertia
    [452402]  = "Dsrg",   -- Demonsurge
    [347461]  = "UC",     -- Unbound Chaos
    [258887]  = "CoH",    -- Cycle of Hatred
    [389687]  = "CT",     -- Chaos Theory
    [442686]  = "ToF",    -- Thrill of the Fight
    [442679]  = "RMk",    -- Reaver's Mark
    [442718]  = "FotA",   -- Fury of the Aldrachi
    [388107]  = "Rage",   -- Ragefire
    [391189]  = "BWnd",   -- Burning Wound
    [452412]  = "SoS",    -- Student of Suffering
    [452414]  = "MRis",   -- Monster Rising
  },
}

spec.Spec = {
  -- ── Essential: the burst window ─────────────────────────────────────────────
  -- Metamorphosis is the whole window, and NOTHING is staged for it — Havoc holds no
  -- resource and no summon the way Demonology holds demons for Tyrant.  So it is a plain
  -- on-cooldown press with no go-gate and no `stage` bit, structurally Destruction's Summon
  -- Infernal.  ⚠ `emphasis` currently has NO reader in the v1 pipeline
  -- (adding-a-spec.md correction 2); it is set for parity with SpecRetribution so the four
  -- spec files read alike, and it is the field a burst treatment would revive.
  [S.METAMORPHOSIS] = {
    kind = "button", cadence = "oncd", emphasis = "burst", baseCD = 120,
    abbr = "Meta", label = "Metamorphosis",
    lost = "the demon-form window has no button — the cooldown the whole rotation orbits",
  },
  [S.THE_HUNT] = {
    kind = "button", cadence = "oncd", baseCD = 90, abbr = "Hunt", label = "The Hunt",
  },
  -- Eye Beam's 30 s lives on the SPELL row (CategoryRecoveryTime 30000), so ns.BaseCooldown
  -- reads it honestly.  ⚠ That is what makes it the ONE ability another line may time
  -- against (L5's Vengeful Retreat) — see CoachHavoc's `eyeBeamSoon`.
  [S.EYE_BEAM] = {
    kind = "button", spends = "fury", cadence = "oncd", baseCD = 30,
    abbr = "EB", label = "Eye Beam",
  },
  -- The only Essential with an honest `RecoveryTime`.  META-ONLY in this APL revision: the
  -- top-level essence_break action at simc:87 sits inside a `#` comment, so it survives
  -- only in actions.meta:121 (rotation.md Deviation 3 — possibly an authoring accident,
  -- re-check on the next simc pull).
  [S.ESSENCE_BREAK] = {
    kind = "button", cadence = "gated", baseCD = 40, abbr = "EssB", label = "Essence Break",
  },
  -- 15 s on the SPELL row (category 1640), shared with Death Sweep — which carries 9000 on
  -- the SAME category, i.e. the meta form is genuinely faster and the frame's countdown is
  -- Blizzard's problem, not ours.
  [S.BLADE_DANCE] = {
    kind = "button", spends = "fury", cadence = "oncd", baseCD = 15,
    abbr = "BD", label = "Blade Dance",
  },

  -- ── Essential: the spender ──────────────────────────────────────────────────
  -- No cooldown at all — the gate is Fury and nothing else.  Appears at TWO lines (L8 the
  -- Essence Break window, L13 the main dump), both keyed on this one base spellID, so a
  -- single exclusion drops both for the runner-up recompute.
  [S.CHAOS_STRIKE] = {
    kind = "button", spends = "fury", cadence = "gated", primary = true,
    abbr = "CS", label = "Chaos Strike",
  },

  -- ── Essential: the charge-category buttons (THE LYING COOLDOWNS) ────────────
  -- Read the header before editing any `chargeCD` here.  All three are ONE-charge
  -- categories, which is what lets usable()'s one-charge rule veto the early cue.
  -- ⚠ Immolation Aura's `charges = 1` is the BASE value; the A Fire Inside talent makes it
  -- 2, which State reports live.  This field is a sanity check, never a gate.
  [S.IMMOLATION_AURA] = {
    kind = "button", cadence = "oncd", charges = 1, chargeCD = 30, baseCD = 30,
    abbr = "IA", label = "Immolation Aura",
  },
  [S.THROW_GLAIVE] = {
    -- The one HONEST member of this group: RecoveryTime is a true 0, so the napkin's
    -- declared fallback DOES fire here and `chargeCD = 9` is live data.
    kind = "button", spends = "fury", cadence = "filler", charges = 1, chargeCD = 9,
    abbr = "TG", label = "Throw Glaive",
  },
  [S.FEL_RUSH] = {
    -- ⚠ THE SHARPEST CASE: RecoveryTime 1000 against a real 10 000 on category 1545.  The
    -- napkin will count down from ONE SECOND and the declared fallback below cannot fire,
    -- because the fence tests `len > 0` and 1 passes it.  Flight question #1.
    kind = "button", cadence = "filler", charges = 1, chargeCD = 10,
    abbr = "FR", label = "Fel Rush",
  },
  [S.VENGEFUL_RETREAT] = {
    -- Filed CDM-Utility; `cadence = "oncd"` is what makes it cueable (header note).
    -- RecoveryTime 500 against a real 25 000 on category 1601 — the third lie.
    kind = "button", cadence = "oncd", charges = 1, chargeCD = 25,
    abbr = "VR", label = "Vengeful Retreat",
  },
  [S.FELBLADE] = {
    -- Filed CDM-Utility, and the ONLY one of the three whose cooldown is honest: a plain
    -- RecoveryTime of 12 000 with no charge category at all.
    kind = "button", cadence = "filler", baseCD = 12, abbr = "FB", label = "Felblade",
  },

  -- ── The dead icon ───────────────────────────────────────────────────────────
  -- `cadence = "utility"` on a real 90 s Essential cooldown, deliberately.  Nothing in the
  -- APL presses Rain from Above, so the SOON fence (Coach.lua:501) must skip it — an
  -- anticipation glow on a button the HUD will never recommend advertises a press we do not
  -- make.  Registered, named, and never cued.
  [S.RAIN_FROM_ABOVE] = {
    kind = "button", cadence = "utility", baseCD = 90,
    abbr = "RfA", label = "Rain from Above (tracked, never in the APL)",
  },

  -- ── The overrides.  `expect = false` on EVERY one (see the header). ─────────
  -- ⚠ None of these needs a semantic discriminator.  Each replaces exactly one named base
  -- on that base's own frame, so the brain reads `ctx.facts[<base>]` and the `abbr` is
  -- display only.  NEVER branch rotation logic on `abbr` — that lesson cost Destruction a
  -- capture that could not answer the question it was recording for.
  [S.ANNIHILATION] = {
    kind = "button", spends = "fury", cadence = "gated", expect = false,
    abbr = "Anni", label = "Annihilation (Metamorphosis override)",
  },
  [S.DEATH_SWEEP] = {
    kind = "button", spends = "fury", cadence = "oncd", expect = false,
    abbr = "DS", label = "Death Sweep (Metamorphosis override)",
  },
  [S.ABYSSAL_GAZE] = {
    kind = "button", spends = "fury", cadence = "oncd", expect = false,
    abbr = "AG", label = "Abyssal Gaze (Fel-Scarred override)",
  },
  [S.CONSUMING_FIRE] = {
    kind = "button", cadence = "oncd", expect = false,
    abbr = "CFire", label = "Consuming Fire (Fel-Scarred override)",
  },
  [S.CONSUMING_FIRE_ALT] = {
    kind = "button", cadence = "oncd", expect = false,
    abbr = "CFire2", label = "Consuming Fire (Fel-Scarred override, alt ID)",
  },
  [S.REAVERS_GLAIVE] = {
    -- L1's entire readable channel on Aldrachi Reaver.  Everything it ARMS (Rending Strike
    -- 442442, Glaive Flurry 442435) has NO CooldownSetSpell row in set 1599, so the spend
    -- sequence is unimplementable rather than merely hard — specs/havoc/rotation.md
    -- Deviation 1.
    kind = "button", spends = "fury", cadence = "reactive", expect = false,
    abbr = "RG", label = "Reaver's Glaive (Aldrachi Reaver override)",
  },
  [S.FEL_RUSH_DASH] = {
    kind = "button", cadence = "filler", expect = false,
    abbr = "FR2", label = "Fel Rush (Dash of Chaos override)",
  },

  -- ── Utility: defensives / CC / mobility ─────────────────────────────────────
  -- Never scored, never cued, excluded from the SOON decoration by the shell.  ⚠ Blur and
  -- Darkness sit here rather than in a defensive channel ON PURPOSE: a health-gated
  -- mitigation cue needs a new emphasis token, i.e. a guidance-contract.json change, and
  -- that is explicitly out of scope for the rollout.
  [183752] = { kind = "button", cadence = "utility", label = "Disrupt" },
  [198589] = { kind = "button", cadence = "utility", label = "Blur" },
  [196718] = { kind = "button", cadence = "utility", label = "Darkness" },
  [179057] = { kind = "button", cadence = "utility", spends = "fury", label = "Chaos Nova" },
  [207684] = { kind = "button", cadence = "utility", label = "Sigil of Misery" },
  [217832] = { kind = "button", cadence = "utility", label = "Imprison" },
  [278326] = { kind = "button", cadence = "utility", label = "Consume Magic" },
  [188501] = { kind = "button", cadence = "utility", label = "Spectral Sight" },
  [185245] = { kind = "button", cadence = "utility", label = "Torment" },
  [205604] = { kind = "button", cadence = "utility", label = "Reverse Magic" },

  -- ── Buff viewers.  kind = "aura": INPUTS to the decision, never scored, no cue. ──
  -- ⚠ Metamorphosis, Immolation Aura, The Hunt, Blur, Darkness and Chaos Nova are ALSO
  -- TrackedBuff rows, and they are NOT repeated here — the spec table is keyed by spellID,
  -- one entry per ability, and a pressable ability must stay `kind = "button"` or Classify
  -- would drop it.  Their buff presence still reaches `state.buffs` (State.lua:2304 keys on
  -- the row's base regardless of category), which is exactly how `ctx.inMeta` reads 191427.
  [S.INNER_DEMON]          = { kind = "aura", label = "Inner Demon" },
  [S.INITIATIVE]           = { kind = "aura", label = "Initiative" },
  [S.ART_OF_THE_GLAIVE]    = { kind = "aura", label = "Art of the Glaive" },
  [S.DEMONSURGE]           = { kind = "aura", label = "Demonsurge" },
  [S.INERTIA]              = { kind = "aura", label = "Inertia" },
  [S.UNBOUND_CHAOS]        = { kind = "aura", label = "Unbound Chaos" },
  [S.CYCLE_OF_HATRED]      = { kind = "aura", label = "Cycle of Hatred" },
  [S.CHAOS_THEORY]         = { kind = "aura", label = "Chaos Theory" },
  [S.THRILL_OF_THE_FIGHT]  = { kind = "aura", label = "Thrill of the Fight" },
  [S.REAVERS_MARK]         = { kind = "aura", label = "Reaver's Mark (target debuff)" },
  [S.FURY_OF_THE_ALDRACHI] = { kind = "aura", label = "Fury of the Aldrachi" },
  [S.RAGEFIRE]             = { kind = "aura", label = "Ragefire" },
  [S.BURNING_WOUND]        = { kind = "aura", label = "Burning Wound" },
  [S.SOULSCAR]             = { kind = "aura", label = "Soulscar" },
  [S.SERRATED_GLAIVE]      = { kind = "aura", label = "Serrated Glaive" },
  [S.ARMY_UNTO_ONESELF]    = { kind = "aura", label = "Army Unto Oneself" },
  [S.INCORRUPTIBLE_SPIRIT] = { kind = "aura", label = "Incorruptible Spirit" },
  [S.EVASIVE_ACTION]       = { kind = "aura", label = "Evasive Action" },
  [S.STUDENT_OF_SUFFERING] = { kind = "aura", label = "Student of Suffering" },
  [S.MONSTER_RISING]       = { kind = "aura", label = "Monster Rising" },
  [S.MORTAL_DANCE]         = { kind = "aura", label = "Mortal Dance" },
  [S.FURIOUS_GAZE]         = { kind = "aura", label = "Furious Gaze" },
  [S.ETERNAL_HUNT]         = { kind = "aura", label = "Eternal Hunt" },
  [S.ETERNAL_HUNT_ALT]     = { kind = "aura", label = "Eternal Hunt (alt ID)" },
  [S.EXERGY]               = { kind = "aura", label = "Exergy" },
}

-- Lookup helpers ---------------------------------------------------------------

local NEUTRAL = { kind = "button", cadence = "utility" }

-- Never nil, never errors: unknown IDs get the neutral fallback.
-- ⚠ THE SECRET GUARD IS LOAD-BEARING and is kept verbatim from the three shipped specs: a
-- Secret Value must never be used as a table key (indexing with one taints), so a secret id
-- is treated exactly like an unresolved one — neutral, no guess.
function spec.SpecInfo(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return NEUTRAL, false end
  local e = ns.Spec[spellID]
  if e then return e, true end
  return NEUTRAL, false
end

-- SIGNED net Fury delta of an in-flight cast — what the rail will read AFTER this cast
-- resolves, relative to now, and which named power it moves.  The Coach folds it into
-- `incoming` (ns.Coach.InflightPower) and the brain ranks on projected = fury + incoming.
--
-- ⚠ SPENDERS ONLY, ON PURPOSE — and this is RETRIBUTION'S judgement, not Destruction's.
-- Destruction projects builders because its yields are exact integers the client hands us
-- (Incinerate is deterministically 2 fragments).  Havoc's generators are auto-attack,
-- Immolation Aura ticks, Felblade and Vengeful Retreat's Tactical Retreat — every one
-- talent-modified, and simc computes `variable.fury_gen_per_sec` from SIX terms including
-- haste and three buff stack counts, none of which is on the pulse.  Authoring a base
-- number here would be exactly the guess the project's floor-is-the-contract rule forbids:
-- an over-credited builder promises a spender you cannot cast, which is the failure
-- direction that actively misleads.  Under-crediting costs one press of latency, so
-- omission is the safe half.
--
-- ⚠ AND NOTE THE UNIT: Fury's modifier is 1, so there is NO conversion here at all.  Do not
-- copy Destruction's `cost * FRAGS_PER_SHARD` multiplication — the cost reader already
-- speaks the only unit this spec has.
--
-- An UNREADABLE cost drops the spend term rather than guessing — the safe direction, since
-- it never pre-deducts power we are not sure will be spent.
function spec.SpecPowerDelta(spellID)
  local info = ns.SpecInfo(spellID)
  if info.spends ~= "fury" or not ns.PowerCost then return { power = nil, delta = 0 } end
  -- Guarded because the .toc loads this file BEFORE Coach.lua; the call is at runtime, so
  -- the shell kit is there by then, but a missing helper must degrade, not error.
  local pt = ns.Coach and ns.Coach.CostPowerType and ns.Coach.CostPowerType(spec)
  if not pt then return { power = nil, delta = 0 } end
  local cost = ns.PowerCost(spellID, pt)
  if type(cost) ~= "number" or cost <= 0 then return { power = nil, delta = 0 } end
  return { power = "Fury", delta = -cost }
end

-- Self-register.  Registration is STATIC; ACTIVATION is the resolver's job —
-- ns.ResolveActiveSpec detects the player's real spec on login / PLAYER_SPECIALIZATION_
-- CHANGED and activates 577 only when Havoc is actually the current spec.  Never call
-- ns.SetActiveSpec from a spec file.
ns.RegisterSpec(577 --[[ Havoc ]], spec)
