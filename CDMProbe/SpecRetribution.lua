-- SpecRetribution.lua — the per-spec DATA table for Retribution Paladin (70).
--
-- The project's THIRD registered spec, and the first outside Warlock — so it is the one
-- that proves the seam is class-agnostic, not just spec-agnostic.  It is DATA ONLY: named
-- IDs, the power array, the decision-log vocabulary, the per-spellID signal bucket, and the
-- two lookup helpers the pipeline calls.  The rotation BRAIN (Context / RankWinner /
-- Escalate) is CoachRetribution.lua, which hangs itself on the object this file registers.
--
-- WHAT IS DELIBERATELY ABSENT.  All nine dormant Tier-3 tables (SpecGroups / SpecColor /
-- SpecPole / SpecGhost / SpecNoCue / SpecProcGlow / SpecStacks / SpecOpener / SpecBurst).
-- None has a live consumer in the v1 pipeline; SpecDestruction.lua omitted all nine and
-- nothing broke.  This file follows Destruction, not Demonology.
--
-- THE SIGNAL BUCKET (`spec.Spec`).  Same vocabulary as the two Warlock specs; the fields the
-- generic shell actually reads are `emphasis` / `kind` / `cadence` / `label` / `abbr` /
-- `expect`, and everything else is this spec's private convention (read by the brain):
--   kind       — "button" (an icon you press) | "aura" (a buff-viewer input, never scored)
--   spends     — "hp" = this press costs Holy Power.  The numeric cost is NEVER authored
--                here — it is talent-modifiable, so it is read at runtime via ns.ShardCost
--                (the generic power-cost reader, despite the Warlock-era name), with a
--                per-spec fallback on the brain.
--   spender    — WHICH finisher this is: "verdict" | "storm" | "hammer_of_light".  The
--                brain branches on THIS, never on `abbr`.  ⚠ That separation is
--                load-bearing and was learned expensively on Destruction: when the brain
--                branched on `abbr`, every alias ID of one transform had to share a single
--                log code, and the capture then could not answer WHICH numeric override had
--                surfaced — the exact question it was recording for.  `spender` is semantic;
--                `abbr` is per-ID display.  Do not re-merge them.
--   charges    — documented charge count, sanity-check only (State reports the live one).
--   chargeCD   — documented CHARGE-CATEGORY recovery, in seconds.  ⚠ Documentation ONLY,
--                and it exists because `ns.BaseCooldown` cannot see it: FOUR of the nine
--                Essential buttons (Judgment, Crusader Strike, Blade of Justice, Wake of
--                Ashes) have SpellCooldowns.RecoveryTime = 0 and keep their real cooldown on
--                a CHARGE CATEGORY, so GetSpellBaseCooldown returns 0 and HudNapkin has
--                nothing to count down from.
--                ⚠ "Documentation ONLY / nothing reads this field today" WAS TRUE AND IS
--                NOT ANY MORE (corrected 2026-08-03): HudNapkin.lua:113-119 falls back to
--                `ns.SpecInfo(spellID).chargeCD` when the live base cooldown reads 0, and
--                files the result as `source = "declared"` — a third provenance value beside
--                "cast" and "read", so a spec-authored number can never be mistaken for an
--                observation.  Edit these numbers as live data, not as prose.
--                ⚠ THE NUMBER WAS "SIX" HERE AND IT WAS WRONG (corrected 2026-08-03).
--                Avenging Wrath carries CategoryRecoveryTime = 120000 on the SPELL row, so
--                its base cooldown reads fine; Templar's Verdict and Divine Storm read 0
--                because they have NO cooldown at all, which is a different thing.
--                ⚠ AND THE CONSEQUENCE IS NARROWER THAN IT SOUNDS.  Readiness for these
--                does NOT depend on the napkin — it comes from the CHARGE COUNT, which
--                State seeds out of combat and maintains in combat off the ChargeGained
--                alert, with this same recovery duration as its GAIN FLOOR (State.lua's
--                chargeGain, via ns.ReadCharges' third return).  What is genuinely lost is
--                the SOON decoration and Escalate's overdue signal, both of which need a
--                positive `remaining`.  Same shape Destruction already ships for
--                Conflagrate — the only difference is that here it is four abilities.
--   cadence    — "oncd" | "gated" | "reactive" | "filler" | "utility"
--   judgeable  — DEFAULT TRUE.  False = the ability's TRUE gate is something we cannot
--                read, so we must never claim it is the right press.
--   secretGate — the sentence a judgeable=false ability would print instead of a call
--   expect     — DEFAULT TRUE.  False = "never expect this bound to a CDM icon of its own".
--                ⚠ LOAD-BEARING, and missing from adding-a-spec.md's Tier-1 list:
--                State.lua's virtual-row walk auto-promotes an untracked kind="button"
--                ability with no base cooldown into a self-drawn icon, so an ALIAS that
--                passed those fences would draw a duplicate beside the real one.
--   baseCD     — documented base cooldown, sanity-check only (ns.BaseCooldown reads live)
--   label      — human name, for `/cdmp hud status`
--   abbr       — the decision-log short code (ONE edit site per ability)
--
-- ⚠ DESK-DERIVED, NOT YET FLOWN.  Every ID below is Tier-1 (wago DB2 @ 12.0.7, fetched
-- 2026-08-02: CooldownSetSpell for set 901, TraitNode->TraitDefinition for talents,
-- SpellPower for costs, SpellCategories/SpellCategory for charges).  They are not guesses.
-- What is UNCONFIRMED is which of them the live Cooldown Manager tracks for a given build —
-- `/cdmp hud layout` on a real Retribution character is the one-time check.  The specific
-- worries are recorded at their entries and in specs/retribution/observability-map.md.
local ADDON, ns = ...

local spec = {}

-- Named IDs.  Tier-1: wago DB2 @ 12.0.7.
spec.SpecIDs = {
  -- ── The tracked rotation buttons (CooldownSetSpell set 901, Essential) ────
  TEMPLARS_VERDICT  = 85256,
  DIVINE_STORM      = 53385,
  JUDGMENT          = 20271,
  CRUSADER_STRIKE   = 35395,
  BLADE_OF_JUSTICE  = 184575,
  WAKE_OF_ASHES     = 255937,
  EXECUTION_SENTENCE = 343527,
  DIVINE_TOLL       = 375576,
  AVENGING_WRATH    = 31884,

  -- ── The OVERRIDES — abilities with no icon of their own ───────────────────
  -- Retribution's structural signature: four rotation abilities arrive as SPELL
  -- OVERRIDES riding a tracked frame, the same channel Demonology's Ruination and
  -- Destruction's Infernal Bolt use.  That channel is readable in restricted combat, which
  -- is precisely why Templar is the v1 profile.
  --
  -- ⚠ HAMMER OF LIGHT 427453 WAS DISCRIMINATED, NOT PICKED.  SpellName carries EIGHT
  -- "Hammer of Light" rows (160420 / 160426 / 427441 / 427453 / 429826 / 1217116 /
  -- 1235934 / 1246643) and the name tells them apart not at all.  SpellPower does: exactly
  -- ONE of them costs Holy Power (PowerType 9, cost 3) — the same signature Templar's
  -- Verdict, Divine Storm and Final Verdict carry.  The method matters more than the
  -- answer: a homonym is resolved by a PROPERTY ONLY THE REAL SPELL HAS, never by picking
  -- the plausible-looking number.  (SpecDemonology.lua accrued its override bugs by doing
  -- the latter, before the tools existed.)
  HAMMER_OF_LIGHT   = 427453,
  -- Final Verdict is a class talent that REPLACES Templar's Verdict.  Same 3 Holy Power.
  FINAL_VERDICT     = 383328,
  -- Templar Strike / Slash replace Crusader Strike on the Templar tree.  407480
  -- corroborates independently: it shares Crusader Strike's charge category 1627, which is
  -- what an override of Crusader Strike must do.
  TEMPLAR_STRIKE    = 407480,
  TEMPLAR_SLASH     = 406647,
  -- The AoE member of the same chain.  Registered so the decision log can NAME it; without
  -- an entry an override that surfaces here resolves to SpecInfo's NEUTRAL fallback and the
  -- trace shows an anonymous transform — which is exactly what makes a capture unreadable
  -- three weeks later.
  TEMPLAR_SWEEP     = 406661,

  -- ── Hammer of Wrath — the one button with no home ─────────────────────────
  -- Absent from set 901 entirely, so it has NO CDM icon.  Its only possible home is a
  -- VIRTUAL row, which needs ns.BaseCooldown to read 0 — DB2 says RecoveryTime IS 0 (the
  -- cooldown lives on charge category 1895), so it should qualify, but whether
  -- GetSpellBaseCooldown really returns 0 for a charge-category spell is untested.
  -- Three Paladin-side ids exist and they are NOT interchangeable: 24275 is the class
  -- skill-line spell that carries the charge category, 326730 a second skill-line row, and
  -- 1241288 the Midnight talent-node spell.  Primary + two aliases, so whichever the client
  -- surfaces resolves the same cue and only one virtual icon can ever be drawn.
  -- @verify-ingame
  HAMMER_OF_WRATH   = 24275,
  HOW_ALT           = 326730,
  HOW_TALENT        = 1241288,

  -- ── Buff viewers — the proc/aura inputs the list actually reads ───────────
  ART_OF_WAR        = 406064,   -- free instant Blade of Justice
  RIGHTEOUS_CAUSE   = 402912,   -- same slot as Art of War
  EMPYREAN_POWER    = 326732,   -- the next Divine Storm is free
  EMPYREAN_LEGACY   = 387170,   -- the next Templar's Verdict cleaves => SUPPRESSES DS
  LIGHTS_DELIVERANCE = 433674,  -- a FREE Hammer of Light (stacking; count is secret)
  DIVINE_PURPOSE    = 408459,
  EXPURGATION       = 383344,
  UNDISPUTED_RULING = 432626,
  SHAKE_THE_HEAVENS = 431536,
  DIVINE_HAMMER     = 432929,
  CRUSADING_STRIKES = 404542,
  DIVINE_RESONANCE  = 384029,
  -- (Herald of the Sun) — registered so a Herald build is not blind.  None is in the
  -- priority list: the KB does not distil Herald line-by-line, and inventing an order from
  -- a tree summary would be guessing.
  BLESSING_OF_ANSHE = 445206,
  DAWNLIGHT         = 431377,
  SUN_SEAR          = 431413,
  -- Herald's Holy Power SPENDER, and a genuine hole in the delta section rather than a
  -- deliberate omission: on Herald the spender lines are INCOMPLETE without it.  Tier-1 —
  -- SpellPower @ 12.0.7 gives 156322 PowerType 9, cost 3, the same signature as every other
  -- finisher, and knowledge/.../talents.md marks it ACTIVE.  Not in the tracked set, so it
  -- has no icon of its own.  @verify-ingame whether it rides the spender frame as an
  -- override; if it does, its entry below already names it.
  ETERNAL_FLAME     = 156322,

  -- CRUSADE — the Avenging Wrath ALTERNATIVE, and the reason L9 could have gone silently
  -- dark.  `ctx.wingsUp` is the only readable half of Hammer of Wrath's gate, so a build
  -- whose burst buff is not 31884 would never fire it.  Tier-1: knowledge/.../talents.md and
  -- the Paladin trait tree both give 1253598.  ⚠ DB2 says it has NO cooldown, NO power cost
  -- and CumulativeAura = 0, i.e. 1253598 is the TALENT NODE, not a stacking buff — so its
  -- presence is a plain boolean and reading it is safe.  Not in the tracked set.
  CRUSADE           = 1253598,
}

local S = spec.SpecIDs

-- ⚠ NO `spec.SpecBindAlias`.  Every override here rides a frame whose BASE id is the one on
-- the action bar (you bind Templar's Verdict and press Hammer of Light through it), which is
-- exactly the case HudBinds' rung ladder already resolves (rung 3 -> 4 -> 5).  Immolate's
-- alias exists because its TRACKED id differs from its CAST id; nothing here has that shape.

-- ── HOLY POWER: TRACKED, DELIBERATELY NOT DRAWN ──────────────────────────────
-- `Enum.PowerType.HolyPower` = 9 (offline-confirmed against
-- BlizzardInterfaceResources/Resources/LuaEnum.lua:5691).  0-5, modifier 1 — so the exact
-- rail and the display rail are the SAME integer and NONE of Destruction's fragment
-- arithmetic applies here.  Do not copy the `*Frags` naming into this spec.
--
-- ⚠ `display = "none"` IS THE POINT, and it is not the same as declaring no powers.
--   * The HUD draws no bar: Blizzard's own Holy Power bar is right there, and the project's
--     stance is enhance-don't-replace.
--   * But an EMPTY spec.powers emits no resourceBars[] entry at all, and DecisionLog's `PW:`
--     field reads the BAR, not the pulse — so the trace would render `?/?` for the whole
--     spec.  That column is the primary instrument for debugging a brain nobody can watch
--     live.  `none` keeps the entire data rail (ctx.powers -> resourceBars[] -> PW:) and
--     turns off exactly one thing: pixels.  Renderer.lua skips it on `display`.
--
-- ⚠ `incoming = true`, AND THIS COMMENT SAID `false` UNTIL 2026-08-03 — it contradicted the
-- line three rows below it, and the code was the correct half.  `incoming` is the
-- spec-declared "this bar receives the in-flight projection" flag: Coach:ResourceBars reads
-- `p.incoming and sums[p.name]`, so declaring it FALSE would zero the incoming term and make
-- `projected` permanently equal to the live value.  That is not a cosmetic choice on a bar
-- nobody draws — SpecPowerDelta below projects SPENDERS, and the brain ranks on `projected`
-- precisely so a spender in flight stops being re-cued mid-cast.  With `false` that
-- cancellation never happens.  The bar draws nothing either way (`display = "none"`); what
-- `true` buys is the decision log's `PW:` column showing the minus, which on a spec nobody
-- can watch live is the whole instrument.
spec.powers = {
  { name = "HolyPower", display = "none", incoming = true, token = "HOLY_POWER",
    exactMax = 5, barMax = 5 },
}

-- The cap, as a fallback for a pulse-less caller.  DISPLAY units and exact units coincide.
spec.HP_CAP = 5

-- The DECISION-LOG vocabulary (adding-a-spec.md Step 6).  DecisionLog.lua holds no spec
-- constants: per-ability short codes ride `abbr` on each spec.Spec entry, and the
-- non-per-ability bits live here.  Read off ns.ActiveSpec.log.
--   cdOrder    the S{CD:…} readiness render order, by abbr (deterministic).
--   procOrder  the S{PR:…} proc/buff render order, by code.
--   procBuffs  buff spellID -> PR code (the domain view's `buffs` is spellID-keyed).
spec.log = {
  -- Only the cooldown-BEARING rotation buttons; the spenders have no readiness to render.
  -- Order is burst -> the timed talents -> the charged builders -> the filler.
  cdOrder   = { "AW", "ES", "DT", "WoA", "BoJ", "Judg", "HoW", "CS" },
  -- ⚠ A code absent from this list is SILENTLY DROPPED from `PR:`, so every per-id override
  -- abbr has to appear here or the per-ID split buys nothing.  `HoL` is the override seen on
  -- Templar's Verdict's frame and `HoL2` the one seen on Divine Storm's — which frame the
  -- client actually overrides is the open question this ordering exists to answer.
  procOrder = { "AoW", "RC", "EP", "EL", "LD", "DP", "Exp", "UR", "StH", "Cru",
                "HoL", "HoL2", "FV", "TS", "TSl", "TSw", "EF" },
  procBuffs = {
    [406064]  = "AoW",   -- Art of War
    [402912]  = "RC",    -- Righteous Cause
    [326732]  = "EP",    -- Empyrean Power
    [387170]  = "EL",    -- Empyrean Legacy
    [433674]  = "LD",    -- Light's Deliverance
    [408459]  = "DP",    -- Divine Purpose
    [383344]  = "Exp",   -- Expurgation
    [432626]  = "UR",    -- Undisputed Ruling
    [431536]  = "StH",   -- Shake the Heavens
    -- Crusade: the ONE buff whose absence from this map would be invisible AND load-bearing,
    -- because ctx.wingsUp ORs it in and the log is the only place that would show which of
    -- the two burst buffs is actually up.
    [1253598] = "Cru",   -- Crusade (the Avenging Wrath alternative)
  },
}

spec.Spec = {
  -- ── Essential: the burst window ───────────────────────────────────────────
  -- Avenging Wrath is the whole window, and NOTHING is staged for it — Retribution holds no
  -- resource and no summon the way Demonology holds demons for Tyrant.  So it is a plain
  -- on-cooldown press with no go-gate and no `stage` bit, structurally Destruction's Summon
  -- Infernal rather than Demonology's Tyrant.  `emphasis = "burst"` marks it the loudest cue.
  -- ⚠ On a RADIANT GLORY build this button does not exist (Wake of Ashes / Execution
  -- Sentence cast the wings).  That needs no talent read: the ability is simply not tracked,
  -- the line finds nothing, and evaluation continues.  A free degradation.
  [S.AVENGING_WRATH] = {
    kind = "button", cadence = "oncd", emphasis = "burst", baseCD = 120,
    abbr = "AW", label = "Avenging Wrath",
    lost = "the burst window has no button — the only cooldown worth building around",
  },
  [S.EXECUTION_SENTENCE] = {
    kind = "button", cadence = "oncd", baseCD = 60, abbr = "ES",
    label = "Execution Sentence",
  },
  [S.DIVINE_TOLL] = {
    kind = "button", cadence = "oncd", baseCD = 60, abbr = "DT", label = "Divine Toll",
  },

  -- ── Essential: the spenders ───────────────────────────────────────────────
  -- Templar's Verdict appears at THREE lines of the priority list (L1 as Hammer of Light,
  -- L4 the anti-overcap dump, L8 the main dump), so a second-place recompute must suppress
  -- all three — which it does for free, since they all key on this one base spellID.
  -- ⚠ 3 HOLY POWER, NOT 5 (T1 DB2: SpellPower @ 12.0.7).  The KB's "spend at 5 Holy Power"
  -- is a POOLING rule, not a cost; reading it as a cost would double every gate.  The cost
  -- is resolved live anyway — this is documentation.
  [S.TEMPLARS_VERDICT] = {
    kind = "button", spends = "hp", spender = "verdict", cadence = "gated", primary = true,
    abbr = "TV", label = "Templar's Verdict",
  },
  [S.DIVINE_STORM] = {
    kind = "button", spends = "hp", spender = "storm", cadence = "gated",
    abbr = "DS", label = "Divine Storm",
  },

  -- ── The overrides (Templar + the Final Verdict talent) ────────────────────
  -- OVERRIDES, never separately tracked.  `expect = false` so an expected-vs-bound diff
  -- never reports them as a missing ability (unbound is their normal state) and State's
  -- virtual-row walk never draws a second icon beside the real one.
  --
  -- ⚠ BOTH SPENDER FRAMES CARRY A HAMMER OF LIGHT ENTRY, and the two have DIFFERENT `abbr`
  -- codes on purpose.  Which frame the client actually overrides is unknown offline; mapping
  -- both costs nothing, and the per-ID codes are what let ONE capture answer the question.
  -- (SpecDestruction learned this the hard way: a shared `abbr` made its own decision log
  -- unable to say whether 433891 or 434506 had surfaced — the exact unknown the pass existed
  -- to close.)  `spender` is what the brain reads; `abbr` is display only.
  [S.HAMMER_OF_LIGHT] = {
    kind = "button", spends = "hp", spender = "hammer_of_light", cadence = "reactive",
    expect = false, abbr = "HoL", label = "Hammer of Light",
  },
  [S.FINAL_VERDICT] = {
    kind = "button", spends = "hp", spender = "verdict", cadence = "gated",
    expect = false, abbr = "FV", label = "Final Verdict (talent override)",
  },

  -- ── Essential: the builders ───────────────────────────────────────────────
  -- ⚠ EVERY ONE OF THESE HAS RecoveryTime = 0 AND KEEPS ITS COOLDOWN ON A CHARGE CATEGORY
  -- (T1 DB2 @ 12.0.7).  GetSpellBaseCooldown therefore returns 0 for them and the napkin has
  -- nothing to count down from, so in-combat readiness rests entirely on the CDM's
  -- Available/OnCooldown alert edges.  `chargeCD` documents the real number; nothing reads
  -- it (see the header).  This is the Conflagrate problem generalised to most of a spec, and
  -- it is why the brain's usable() lets the COUNT outrank the cooldown read.
  [S.WAKE_OF_ASHES] = {
    kind = "button", cadence = "oncd", charges = 1, chargeCD = 30, abbr = "WoA",
    label = "Wake of Ashes",
    -- Its rotational weight is not its damage: it ARMS Hammer of Light for 20s, which is
    -- why L4 declines to dump at cap while this is ready.
  },
  [S.BLADE_OF_JUSTICE] = {
    -- ⚠ chargeCD WAS 12 AND THAT WAS WRONG — corrected to 10 by measurement, 2026-08-03.
    -- Out of combat `C_Spell.GetSpellCharges` returned rc=9.312 here, rc=10.243 for Judgment
    -- (declared 11) and rc=5.587 for Crusader Strike (declared 6).  The latter two give the
    -- SAME haste factor, 0.931, twice over — so the factor is trustworthy, and 9.312/0.931
    -- = 10.00 exactly.  A declared 12 held this button back two seconds too long on every
    -- cast.  These constants are a last-resort fallback for a row the live read never
    -- covered; the haste-scaled `recharge` off GetSpellCharges is the real number.
    kind = "button", cadence = "reactive", charges = 1, chargeCD = 10, abbr = "BoJ",
    label = "Blade of Justice",
  },
  [S.JUDGMENT] = {
    kind = "button", cadence = "oncd", charges = 1, chargeCD = 11, abbr = "Judg",
    label = "Judgment",
  },
  -- THE FILLER FRAME, and the one place charges genuinely bite: 2 charges on a 6s recharge
  -- (SpellCategory 1627).  On Templar this same frame shows Templar Strike / Templar Slash;
  -- the brain presses the FRAME and the game decides which strike comes out, because the
  -- alternation is Blizzard's and not ours.
  [S.CRUSADER_STRIKE] = {
    kind = "button", cadence = "filler", charges = 2, chargeCD = 6, abbr = "CS",
    label = "Crusader Strike",
  },
  [S.TEMPLAR_STRIKE] = {
    kind = "button", cadence = "filler", expect = false, abbr = "TS",
    label = "Templar Strike (Templar override)",
  },
  -- ⚠ ONLY TEMPLAR STRIKE SHARES CRUSADER STRIKE'S CHARGE CATEGORY (1627).  Templar Slash
  -- and Templar Sweep have ChargeCategory 0 — they are the follow-ups in the chain, not
  -- independent presses, which is exactly why the brain presses the FRAME and lets the game
  -- pick.  (An earlier comment here implied all three shared 1627; DB2 @ 12.0.7 says not.)
  [S.TEMPLAR_SLASH] = {
    kind = "button", cadence = "filler", expect = false, abbr = "TSl",
    label = "Templar Slash (Templar override)",
  },
  [S.TEMPLAR_SWEEP] = {
    kind = "button", cadence = "filler", expect = false, abbr = "TSw",
    label = "Templar Sweep (Templar override, AoE)",
  },
  -- (Herald) Eternal Flame — a real 3-Holy-Power spender with no tracked icon.
  -- ⚠ `expect = false` IS LOAD-BEARING HERE, and for the one reason that field exists: this
  -- is a kind="button", non-utility ability with no base cooldown, which is precisely the
  -- shape State.virtualCandidates promotes into a self-drawn icon.  Without the fence, a
  -- Herald build would grow a phantom Eternal Flame button that NO priority line ever cues —
  -- worse than not registering it at all.  With the fence it stays a labelled entry the
  -- decision log can name if it ever surfaces as an override.
  [S.ETERNAL_FLAME] = {
    kind = "button", spends = "hp", spender = "eternal_flame", cadence = "gated",
    expect = false, abbr = "EF", label = "Eternal Flame (Herald spender)",
  },

  -- ── Hammer of Wrath: no icon, and a gate we can only half-read ────────────
  -- Its TRUE gate is `target.health.pct<20 | buff.avenging_wrath.up | talent.walk_into_light`.
  -- We can read the wings and nothing else, so the brain fires it only inside Avenging
  -- Wrath — a missed press outside the window, never a wrong one.  It stays `judgeable`
  -- because the half we CAN read is a genuine, sufficient condition; this is not the Havoc
  -- case, where no readable condition implies the press at all.
  [S.HAMMER_OF_WRATH] = {
    kind = "button", cadence = "reactive", charges = 1, chargeCD = 7.5, abbr = "HoW",
    label = "Hammer of Wrath",
    lost = "the execute press has no icon unless the virtual row picks it up",
  },
  [S.HOW_ALT]    = { kind = "button", cadence = "reactive", expect = false, abbr = "HoW2",
                     label = "Hammer of Wrath (alt skill-line ID, alias)" },
  [S.HOW_TALENT] = { kind = "button", cadence = "reactive", expect = false, abbr = "HoW3",
                     label = "Hammer of Wrath (Midnight talent-node ID, alias)" },

  -- ── Utility: defensives / CC / mobility ───────────────────────────────────
  -- Never scored, never cued, excluded from the SOON decoration by the shell.  ⚠ Divine
  -- Shield / Lay on Hands / Divine Protection sit here rather than in a defensive channel
  -- ON PURPOSE: a health-gated mitigation cue needs a new emphasis token, i.e. a
  -- guidance-contract.json change, and that is explicitly out of scope.
  [190784]  = { kind = "button", cadence = "utility", label = "Divine Steed" },
  [403876]  = { kind = "button", cadence = "utility", label = "Divine Protection" },
  [96231]   = { kind = "button", cadence = "utility", label = "Rebuke" },
  [853]     = { kind = "button", cadence = "utility", label = "Hammer of Justice" },
  [115750]  = { kind = "button", cadence = "utility", label = "Blinding Light" },
  [213644]  = { kind = "button", cadence = "utility", label = "Cleanse Toxins" },
  [10326]   = { kind = "button", cadence = "utility", label = "Turn Evil" },
  [642]     = { kind = "button", cadence = "utility", label = "Divine Shield" },
  [633]     = { kind = "button", cadence = "utility", label = "Lay on Hands" },
  [1044]    = { kind = "button", cadence = "utility", label = "Blessing of Freedom" },
  [6940]    = { kind = "button", cadence = "utility", label = "Blessing of Sacrifice" },
  [1022]    = { kind = "button", cadence = "utility", label = "Blessing of Protection" },
  [204018]  = { kind = "button", cadence = "utility", label = "Blessing of Spellwarding" },
  [210256]  = { kind = "button", cadence = "utility", label = "Blessing of Sanctuary" },
  [391054]  = { kind = "button", cadence = "utility", label = "Intercession" },

  -- ── Buff viewers.  kind = "aura": INPUTS to the decision, never scored, no cue. ──
  [S.ART_OF_WAR]         = { kind = "aura", label = "Art of War" },
  [S.RIGHTEOUS_CAUSE]    = { kind = "aura", label = "Righteous Cause" },
  [S.EMPYREAN_POWER]     = { kind = "aura", label = "Empyrean Power" },
  [S.EMPYREAN_LEGACY]    = { kind = "aura", label = "Empyrean Legacy" },
  [S.LIGHTS_DELIVERANCE] = { kind = "aura", label = "Light's Deliverance" },
  [S.DIVINE_PURPOSE]     = { kind = "aura", label = "Divine Purpose" },
  [S.EXPURGATION]        = { kind = "aura", label = "Expurgation" },
  [S.UNDISPUTED_RULING]  = { kind = "aura", label = "Undisputed Ruling" },
  [S.SHAKE_THE_HEAVENS]  = { kind = "aura", label = "Shake the Heavens" },
  [S.DIVINE_HAMMER]      = { kind = "aura", label = "Divine Hammer" },
  [S.CRUSADING_STRIKES]  = { kind = "aura", label = "Crusading Strikes" },
  [S.DIVINE_RESONANCE]   = { kind = "aura", label = "Divine Resonance" },
  -- CRUSADE, twice on purpose.  As an AURA it is what ctx.wingsUp ORs in (the readable half
  -- of Hammer of Wrath's gate on a Crusade build).  It is NOT registered as a button: DB2
  -- gives it no cooldown and no cost, so it is the talent node rather than a press, and a
  -- button entry would have been a guess.  If the live pass shows Crusade OVERRIDING the
  -- Avenging Wrath frame, add an `expect = false` button entry carrying the AW bucket's
  -- `emphasis = "burst"` — without one, Classify falls back to NEUTRAL and L2 loses its
  -- loudest cue.  @verify-ingame
  [S.CRUSADE]            = { kind = "aura", label = "Crusade (Avenging Wrath alternative)" },
  [S.BLESSING_OF_ANSHE]  = { kind = "aura", label = "Blessing of An'she (Herald)" },
  [S.DAWNLIGHT]          = { kind = "aura", label = "Dawnlight (Herald)" },
  [S.SUN_SEAR]           = { kind = "aura", label = "Sun Sear (Herald)" },
}

-- Lookup helpers ---------------------------------------------------------------

local NEUTRAL = { kind = "button", cadence = "utility" }

-- Never nil, never errors: unknown IDs get the neutral fallback.
-- ⚠ THE SECRET GUARD IS LOAD-BEARING and is kept verbatim from the Warlock specs: a Secret
-- Value must never be used as a table key (indexing with one taints), so a secret id is
-- treated exactly like an unresolved one — neutral, no guess.
function spec.SpecInfo(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return NEUTRAL, false end
  local e = ns.Spec[spellID]
  if e then return e, true end
  return NEUTRAL, false
end

-- SIGNED net Holy Power delta of an in-flight cast — what the rail will read AFTER this cast
-- resolves, relative to now, and which named power it moves.  The Coach folds it into
-- `incoming` (ns.Coach.InflightPower) and the brain ranks on projected = hp + incoming.
--
-- ⚠ SPENDERS ONLY, ON PURPOSE — and this is a DIFFERENT judgement from Destruction's, not a
-- copy of an obsolete one.  Destruction projects builders because its yields are exact
-- integers in a unit the client hands us (Incinerate is deterministically 2 fragments).
-- Retribution's generators are not that: Judgment, Blade of Justice, Crusader Strike, Wake
-- of Ashes and Divine Toll all have TALENT-MODIFIED yields (Judge/Jury/Executioner, Greater
-- Judgment, Boundless Conviction, the Templar strikes' own generation), and none of it is on
-- the pulse.  Authoring a base number here would be exactly the guess the project's
-- floor-is-the-contract rule forbids: an over-credited builder promises a spender you cannot
-- cast, which is the failure direction that actively misleads.  Under-crediting a builder
-- costs one press of latency, so omission is the safe half.
--
-- ⚠ AND NOTE THE UNIT: Holy Power's modifier is 1, so there is NO conversion here at all.
-- Do not copy Destruction's `cost * FRAGS_PER_SHARD` multiplication — the cost reader already
-- speaks the only unit this spec has.
--
-- An UNREADABLE cost drops the spend term rather than guessing — the safe direction, since
-- it never pre-deducts power we are not sure will be spent.
--
-- ⚠ THIS READ `ns.ShardCost` UNTIL 2026-08-03, WHICH MEANT IT NEVER FIRED IN GAME.  That
-- reader filters to Soul Shards, so a Paladin spender matched nothing, the cost came back
-- absent, and the guard below dropped the term on EVERY cast — the in-flight Holy Power
-- projection was dead code for the life of the spec.  It failed in the safe direction (an
-- under-projection costs a press of latency), which is exactly why nobody saw it: the same
-- mis-wiring in CoachRetribution's `costOf` failed in the UNSAFE direction and cued a
-- spender at 0 Holy Power.  One defect, two call sites, two very different symptoms.
-- The resource is now an ARGUMENT, resolved from this spec's own `powers` block.
function spec.SpecPowerDelta(spellID)
  local info = ns.SpecInfo(spellID)
  if info.spends ~= "hp" or not ns.PowerCost then return { power = nil, delta = 0 } end
  -- Guarded because the .toc loads this file BEFORE Coach.lua; the call is at runtime, so
  -- the shell kit is there by then, but a missing helper must degrade, not error.
  local pt = ns.Coach and ns.Coach.CostPowerType and ns.Coach.CostPowerType(spec)
  if not pt then return { power = nil, delta = 0 } end
  local cost = ns.PowerCost(spellID, pt)
  if type(cost) ~= "number" or cost <= 0 then return { power = nil, delta = 0 } end
  return { power = "HolyPower", delta = -cost }
end

-- Self-register.  Registration is STATIC; ACTIVATION is the resolver's job —
-- ns.ResolveActiveSpec detects the player's real spec on login / PLAYER_SPECIALIZATION_
-- CHANGED and activates 70 only when Retribution is actually the current spec.  Never call
-- ns.SetActiveSpec from a spec file.
ns.RegisterSpec(70 --[[ Retribution ]], spec)
