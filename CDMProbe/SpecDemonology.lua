-- SpecDemonology.lua — the per-spec data table (v1 target: Demonology Warlock).
--
-- ONE table, ONE edit site.  Every other module reads identity + signals from here and
-- holds no spell constants of its own, so adding a spec is a sibling file, not an edit
-- to the pipeline.
--
-- Each entry is a SIGNAL BUCKET — one field per concept, so a consumer reads exactly
-- the bit it needs and nothing is smuggled through a field that means something else:
--
--   group      — the colour group (hue carries GROUP, never per-ability identity,
--                and never actionability — that's the cue's job)
--   kind       — "button" (an icon you press) | "aura" (a buff viewer entry)
--   spends     — what pressing it CONSUMES: "shards" | "core" | "art".  The
--                numeric cost is NEVER authored here — it is talent-dependent,
--                so it's read at runtime via ns.ShardCost (Util.lua).
--   generatesFrags — deterministic Soul Shard yield, in FRAGMENTS (10 per whole
--                shard).  Drives both the in-flight projection and the overcap
--                guard.  ⚠ It was `generates` in WHOLE SHARDS until Phase 6.2; the
--                name carries the unit precisely so a stale read fails loudly
--                instead of being silently wrong by 10x.
--   cadence    — "oncd"     use it whenever it's up (the burst summons)
--                "gated"    press it when the resource gate opens (HoG)
--                "reactive" press it when a proc/condition arms it
--                "filler"   what you press when nothing else is lit
--                "utility"  outside the damage rotation entirely
--                (`burst` is deliberately NOT a cadence — it was redundant with
--                 burstAlign, which is a separate bit below.)
--   burstAlign — belongs in the burst window; hold it for Tyrant alignment
--   goGate     — a SEPARATE bit from burstAlign, on purpose.  The go-gate is
--                Tyrant + Dreadstalkers ONLY.  Collapsing it into burstAlign is
--                how this shipped broken the first time:
--                someone re-derives the lane from burstAlign and Grimoire (which
--                is burst-aligned but is NOT a go-gate) sneaks back into it.
--   stage      — HOLD this inside the BURST window so it lands fresh IN the
--                window instead of firing on cooldown just before it.  Its own bit
--                (not "goGate and not Tyrant") so the hold can never catch Tyrant,
--                the very thing the window is waiting for.  Dreadstalkers only.
--   primary    — the one spender the shard economy points at (HoG)
--   judgeable  — DEFAULT TRUE.  False means the ability's TRUE gate is a Secret
--                Value we cannot read, so we must never claim it's the right
--                press.  These CAP AT "AVAILABLE" and say why.  Implosion is the
--                known case: its real gate is Wild Imps >= 6 and the count is
--                secret.  This is "inform, don't instruct" made mechanical.
--   secretGate — the sentence a judgeable=false ability prints instead of a call
--   expect     — DEFAULT TRUE.  False means "never expect this to be bound to a
--                CDM icon" — it exists only as a live spell OVERRIDE.  Read by
--                the expected-vs-bound warning, which would otherwise
--                report every Demonic Art transform as a missing ability.
--   lost       — the sentence the expected-vs-bound warning prints for what a
--                MISSING ability costs you: what is lost, not just what is absent.
--   baseCD     — documented base cooldown, sanity-check only.  ns.BaseCooldown
--                reads the live value; nil here means "the docs don't assert it".
--   label      — human name, for `/cdmp hud status` only
--
-- Unknown spellIDs fall back to the neutral accent — never crash, never guess.
local ADDON, ns = ...

-- Multi-spec Phase 1: this file no longer clobbers the ns.Spec* globals at load.  It fills
-- a local `spec` object and self-registers it (bottom of file); the SpecRegistry resolver
-- DERIVES the legacy globals from whichever spec is active.  The field names on `spec`
-- match the old global names 1:1 so every consumer keeps reading ns.SpecIDs / ns.SpecInfo
-- / … untouched.  Runtime cross-references INSIDE these functions stay `ns.Spec*` — they
-- resolve post-activation to the active spec (= Demo), which is correct since only the
-- active spec's functions are ever invoked through the rebound globals.
local spec = {}

-- Group hues — THE source of truth, so no render module holds a colour constant of its
-- own.  ⚠ DORMANT with SpecColor (see the banner further down); the pipeline's Renderer
-- colours by emphasis, not by group.  design.md: summon = fel green, core shadow =
-- violet, fel explosion = lime, proc/resource = cyan, defensive = blue, CC = slate,
-- mobility = gold.
spec.SpecGroups = {
  summon  = { 0.216, 0.784, 0.435 }, -- fel green     — demon summons / burst
  core    = { 0.627, 0.396, 1.000 }, -- shadow violet — core shadow damage
  aoe     = { 0.741, 0.953, 0.227 }, -- fel lime      — Implosion
  proc    = { 0.176, 0.831, 0.933 }, -- arcane cyan   — procs / resource accent
  def     = { 0.290, 0.620, 1.000 }, -- blue          — defensives
  cc      = { 0.541, 0.580, 0.671 }, -- slate         — control
  mob     = { 0.961, 0.773, 0.259 }, -- gold          — mobility
  neutral = { 0.360, 0.340, 0.420 }, -- unknown / outside our opinionated set
}

-- Named IDs the render modules reference by name rather than by literal.
spec.SpecIDs = {
  TYRANT        = 265187,
  DREADSTALKERS = 104316,
  HAND_OF_GULDAN = 105174,
  DEMONBOLT     = 264178,
  SHADOW_BOLT   = 686,
  IMPLOSION     = 196277,
  -- Grimoire: Imp Lord.  The CAST spellID is 1276452 (talents.json:1919), NOT the
  -- talent tree ENTRY-id 136726 the code used to reference (talents.json:1917).
  -- Under 136726 ns.Spec didn't know the live button -> neutral "your call" ->
  -- always AVAILABLE, and no keybind resolved so the sequence strip printed the
  -- NAME.  One id fixes both reports; 136726 stays a harmless alias below.
  IMP_LORD      = 1276452,
  -- Buff viewers (proc presence comes from the buff item's IsActive(); item:IsShown()
  -- is only a best-effort backstop — see State.lua):
  DEMONIC_CORE   = 264173,   -- BuffBar
  DIABOLIC_RITUAL = 428514,  -- BuffIcon — the Demonic Art container
  WILD_IMP       = 296553,   -- BuffIcon — the stack-text surface
  DOMINION       = 1276166,  -- BuffBar
}

local S = spec.SpecIDs

-- Keybind-resolution aliases.  A spell whose CDM/cast id differs from the id that
-- sits on the action bar won't resolve a keybind under its own id — Imp Lord is
-- the case (cast 1276452 vs talent entry 136726).  HudBinds.Get falls back to the
-- alias so the icon + sequence show the key either way.  Bidirectional.
spec.SpecBindAlias = {
  [1276452] = 136726,
  [136726]  = 1276452,
}

-- ── THE SOUL SHARD RAIL, IN TWO UNITS (Phase 6.2) ────────────────────────────
-- The game stores Soul Shards as 0–50 FRAGMENTS and DISPLAYS them as 0–5 whole shards;
-- `UnitPower(…, unmodified)` reads the exact rail, `UnitPower(…)` the display one
-- (measured 2026-08-01: max 50 vs 5, modifier 10).  Every DECISION is made in fragments —
-- integers, exactly summable, no boundary comparison decided by a float — and only the
-- rendered bar stays in whole shards, because Renderer.lua draws one pip per unit of `max`.
--
-- FRAG_CAP is the overcap guard's ceiling: a generator that would push past it stops
-- being a ROTATION call even when its proc is genuinely up.  It is a FALLBACK — the brain
-- prefers the live `unmodifiedMax` off the pulse.
spec.FRAG_CAP        = 50   -- exact units (fallback for state.power.SoulShards.unmodifiedMax)
spec.BAR_MAX         = 5    -- DISPLAY units — the pip count, never a gate
spec.FRAGS_PER_SHARD = 10   -- the modifier, as a fallback for a pulse-less caller

-- The POWER ARRAY (multi-spec Phase 3, the resource seam).  A spec declares an ORDERED
-- list of the named powers its HUD renders; the pipeline is now array-shaped end to end
-- (State projects `incoming` per power, the Coach emits one resourceBar per entry, the
-- Renderer stacks them).  Demo has exactly ONE — the Soul Shard bar — so the HUD renders
-- the identical single shard meter it always did.  A dual-resource spec (energy+combo,
-- runes+runic power) simply lists two entries here.
--   name     the Enum.PowerType member name State keys the power by (state.power[name]).
--   display  the guidance-contract resourceDisplay token (discrete pips | continuous fill).
--   incoming true => this power receives State's in-flight projection (the +/- shard math).
--   token    the game power render token the Renderer resolves to a colour (PowerBarColor).
--   modifier FALLBACK exact-units-per-display-unit for this power (Phase 6.2): the divisor
--            between the units SpecPowerDelta speaks and the units the bar renders in.  The
--            LIVE `state.power[name].modifier` wins where the client gave one; this is what
--            keeps the display honest when the exact read refuses.  Omit it (=> 1) for a
--            power with no divisor.
--   exactMax FALLBACK cap in EXACT units, and `barMax` the same in DISPLAY units.  These
--            were `spec.FRAG_CAP` / `spec.BAR_MAX` file-wide constants until the
--            ns.Coach.PowerContext hoist (2026-08-02); they moved ONTO the power entry
--            because they are per-power facts, and a spec with two powers cannot have one
--            of each.  The spec-object constants survive above — the brain still reads
--            FRAG_CAP in its own Escalate — but the RAIL's fallbacks come from here.
-- Read off ns.ActiveSpec.powers (an object read, like SHARD_CAP), NOT a rebound SpecField.
spec.powers = {
  { name = "SoulShards", display = "discrete", incoming = true, token = "SOUL_SHARDS",
    modifier = 10, exactMax = 50, barMax = 5 },
}

-- The DECISION-LOG vocabulary (multi-spec Phase 4, the decision-log seam).  DecisionLog.lua
-- holds NO spec constants of its own: the per-ability short codes live as `abbr` on each
-- spec.Spec entry (one identity source), and the non-per-ability bits live here.  Read off
-- ns.ActiveSpec.log (an object read, like spec.powers), NOT a rebound SpecField.
--   cdOrder    the S{CD:…} readiness render order, by abbr (deterministic).
--   procOrder  the S{PR:…} proc/buff render order, by code.
--   procBuffs  buff spellID -> PR code (the domain view's `buffs` is keyed by spellID).
--   artArmed   live override id ∈ this set ⇒ the Demonic-Art transform is up (a PR code).
--   coreGlowID the button whose glow.active reads the core proc (Demonbolt) even when the
--              aura reads secret.
spec.log = {
  cdOrder   = { "T", "D", "I", "G", "HoG", "DB", "SB" },
  procOrder = { "core", "Tw", "IB", "RU" },
  procBuffs = {
    [264173] = "core",   -- Demonic Core buff present
    [265187] = "Tw",     -- Tyrant window active (TrackedBar buff.isActive)
  },
  artArmed  = { [433891] = true, [434506] = true, [434635] = true, [434636] = true },
  coreGlowID = 264178,   -- Demonbolt glow.active ⇒ core proc (the empowered button)
}

spec.Spec = {
  -- ── Essential: the burst summons (§3 "summon" / fel green) ────────────────
  -- cadence = "oncd": these are the abilities the user rates the biggest win —
  -- "firing cooldown abilities as soon as they are up".  So a ready edge on any
  -- of them is a ROTATION call outright, and the napkin gives them lead time.
  -- `emphasis = "burst"` (A3, M4.4): Tyrant's cue bar is the WIDEST on the board
  -- regardless of level — the burst go-signal shouts even when it is only SOON
  -- (yellow).  A DEDICATED field, NOT `goGate` (that is Tyrant + Dreadstalkers);
  -- feedback 5 wants Tyrant SPECIFICALLY the widest.  Extensible to a lesser tier.
  [S.TYRANT] = {
    group = "summon", kind = "button", spends = "shards", cadence = "oncd",
    burstAlign = true, goGate = true, emphasis = "burst",
    baseCD = 60, abbr = "T", label = "Summon Demonic Tyrant",
  },
  -- `stage = true`: inside the BURST window this reads "stage for Tyrant" instead of
  -- greenlighting on cooldown, so it lands FRESH in the window — rotation.md #5: a
  -- Dreadstalkers cast too early expires before Tyrant.  Keyed on this bit (not
  -- "goGate and not Tyrant") so Tyrant itself is never held.
  [S.DREADSTALKERS] = {
    group = "summon", kind = "button", spends = "shards", cadence = "oncd",
    burstAlign = true, goGate = true, stage = true, baseCD = 20,
    abbr = "D", label = "Call Dreadstalkers",
  },
  -- The Grimoire summons are burst-ALIGNED but NOT part of the go-gate (see
  -- `goGate` above).  `stage = true`: both are 2-min summons paired with Tyrant
  -- (diabolist-sequences.md — out BEFORE Tyrant), so inside the BURST window they
  -- stage for Tyrant like Dreadstalkers.
  -- They stay `optional` in the queue drain: 2-min CD = present every OTHER
  -- Tyrant, so a missing one must drop-through, not jam.
  -- `discretion = true` (feedback 2026-07-23): when up, these read cyan "ready —
  -- save for Tyrant (your call)", NEVER a green "press on cooldown".  They are
  -- 2-min summons paired with Tyrant, so on-cooldown use is almost always wrong.
  [1276467] = {
    group = "summon", kind = "button", cadence = "oncd", burstAlign = true,
    stage = true, discretion = true, baseCD = 120, abbr = "G", label = "Grimoire: Fel Ravager",
  },
  [S.IMP_LORD] = {
    group = "summon", kind = "button", cadence = "oncd", burstAlign = true,
    stage = true, discretion = true, baseCD = 120, abbr = "G", label = "Grimoire: Imp Lord",
  },
  -- 136726 is the talent ENTRY-id, kept mapped as a harmless alias for a build
  -- that surfaces it; the live tracked/cast id is S.IMP_LORD (1276452) above.
  -- `expect = false` because it is an ALIAS, not a second ability — the same treatment
  -- Destruction gives Immolate's cast-id 348.  It was already true and merely unstated; it
  -- matters now because State's virtual-row walk keys on this field, and an alias that
  -- passed the fences would be drawn as a SECOND Imp Lord icon.  Today its 120s cooldown
  -- also excludes it, but that is accidental protection — this is the deliberate kind.
  [136726] = {
    group = "summon", kind = "button", cadence = "oncd", burstAlign = true, expect = false,
    stage = true, discretion = true, baseCD = 120, abbr = "G", label = "Grimoire: Imp Lord (entry-id alias)",
  },

  -- ── Essential: core shadow damage (§3 "core" / shadow violet) ─────────────
  -- HoG is the spender the whole shard economy points at — `primary`.
  [S.HAND_OF_GULDAN] = {
    group = "core", kind = "button", spends = "shards", cadence = "gated",
    primary = true, abbr = "HoG", label = "Hand of Gul'dan",
  },
  -- C2, the pole fix.  v0.9.1 classified Demonbolt as a `builder`, which put it
  -- at the OPPOSITE tint pole from Hand of Gul'dan — its single most common
  -- partner in the cast log (313 + 313 two-grams).  A bucket-2
  -- spender: it CONSUMES a Demonic Core proc (that's the press decision) and
  -- happens to refund 2 shards.  So `spends = "core"` decides the pole, and
  -- `generatesFrags = 20` is what drives the overcap guard.
  [S.DEMONBOLT] = {
    group = "core", kind = "button", spends = "core", generatesFrags = 20,
    cadence = "reactive", abbr = "DB", label = "Demonbolt",
  },
  [S.SHADOW_BOLT] = {
    group = "core", kind = "button", generatesFrags = 10, cadence = "filler",
    -- B7: what the player LOSES if this isn't in the tracked set.  Named
    -- specifically because this exact gap hid the SB -> Infernal Bolt blind spot
    -- for four milestones, and because Shadow Bolt is added by hand — the
    -- knowingly-accepted risk is silent degradation if the setting is ever lost.
    lost = "SB -> Infernal Bolt cannot light, and the filler has no dot",
    abbr = "SB", label = "Shadow Bolt",
  },

  -- Demonic Art transforms.  These are OVERRIDES, never separately tracked by
  -- the CDM — they replace Hand of Gul'dan / Shadow Bolt on the live button — so
  -- `expect = false` keeps B7's expected-vs-bound diff from reporting them as a
  -- gap (unbound is their normal state).
  --
  -- Two IDs were in circulation for each in the maxroll captures.  The probe
  -- CONFIRMED the live ones on 2026-07-21: **Ruination = 434635**, **Infernal
  -- Bolt = 434506**.  The other two stay mapped — they cost nothing and cover a
  -- build that surfaces the alternate ID.
  -- `art` is the SEMANTIC discriminator the brain branches on; `generatesFrags` is the
  -- mechanical shard yield SpecPowerDelta feeds the Coach's in-flight projection.  ⚠ They
  -- were ONE field until 2026-07-30: CoachDemonology asked `generates == 3` to mean "this
  -- Art is Infernal Bolt".  That silently couples a rotation decision to a TUNING number —
  -- retune Infernal Bolt off 3, or give Ruination a yield, and the brain recommends the
  -- wrong Art at the top of the burst window with nothing naming the cause.  SpecDestruction
  -- split exactly this overload out of `abbr`; this is the same fix on its sibling.  Branch
  -- on `art`, never on a number that exists for arithmetic.
  [433891] = { group = "core", kind = "button", spends = "art", art = "infernal", generatesFrags = 30,
               cadence = "reactive", expect = false, abbr = "IB", label = "Infernal Bolt (alt ID, unconfirmed)" },
  [434506] = { group = "core", kind = "button", spends = "art", art = "infernal", generatesFrags = 30,
               cadence = "reactive", expect = false, abbr = "IB", label = "Infernal Bolt" },  -- CONFIRMED live
  [434635] = { group = "core", kind = "button", spends = "art", art = "ruination",
               cadence = "reactive", expect = false, abbr = "RU", label = "Ruination" },      -- CONFIRMED live
  [434636] = { group = "core", kind = "button", spends = "art", art = "ruination",
               cadence = "reactive", expect = false, abbr = "RU", label = "Ruination (alt ID, unconfirmed)" },

  -- ── Essential: the fel explosion (§3 "aoe" / lime) ────────────────────────
  -- THE judgeable=false case.  Implosion's real gate is Wild Imps >= 6.  The
  -- count is displayed by Blizzard and is a Secret Value to us, so we
  -- cannot compute the gate and must never claim this is the press.  It caps at
  -- AVAILABLE and hands the call back, with the reason stated.
  [S.IMPLOSION] = {
    group = "aoe", kind = "button", cadence = "reactive", baseCD = 15,
    judgeable = false, secretGate = ">=6 imps — count is secret, your call",
    -- ⚠ NOT `aoeOnly` (reverted v0.16.4).  It's tempting, but rotation.md is
    -- explicit: Implosion at >=6 imps fires "only if 3+ targets OR To Hell and
    -- Back talented", so on a THaB build it's a single-target press too — a hard
    -- ST-suppress would black it out wrongly.  Demo is a "passive cleave" spec
    -- whose priority is "largely the same across target counts", so there is no
    -- clean ST/AoE dot difference to gate here.  It stays judgeable=false / "your
    -- call" in both modes; the imp count we can't read is the real gate.
    abbr = "I", label = "Implosion",
  },

  -- ── Utility: defensives / CC / mobility ───────────────────────────────────
  [104773]  = { group = "def", kind = "button", cadence = "utility", label = "Unending Resolve" },
  [108416]  = { group = "def", kind = "button", cadence = "utility", label = "Dark Pact" },
  [30283]   = { group = "cc",  kind = "button", cadence = "utility", label = "Shadowfury" },
  -- The live tracked set carries the WRAPPER spell Command Demon (119898), not
  -- the pet ability Axe Toss (119914) that notes.md §2 recorded — confirmed off
  -- `/cdmp hud status` on 2026-07-20.  Both are mapped: the wrapper is what
  -- actually appears, the inner ID is kept in case a different pet/build surfaces it.
  [119898]  = { group = "cc",  kind = "button", cadence = "utility", label = "Command Demon" },
  [119914]  = { group = "cc",  kind = "button", cadence = "utility", label = "Axe Toss" },
  [6789]    = { group = "cc",  kind = "button", cadence = "utility", label = "Mortal Coil" },
  -- Devour Magic is a pet purge that OVERRIDES
  -- the Grimoire button, and because the base spell used to be scored unconditionally
  -- the HUD advertised "Grimoire: Fel Ravager - up - use on cooldown - waiting
  -- 18s" on a button that was a purge.  Mapped so the live identity resolves to
  -- something real: a utility, i.e. "your call", i.e. never a lit dot.
  -- `expect = false` — it only ever appears as an override.
  [388215]  = { group = "cc",  kind = "button", cadence = "utility", expect = false,
                label = "Devour Magic" },
  -- THE SAME DEFECT, A DIFFERENT PET — found by the first real `wowkb.cdmp check`
  -- (play-test 5).  Singe Magic is the IMP's dispel and it overrides the Grimoire
  -- button exactly as Devour Magic does for the Felhunter; the capture caught
  -- `base=1276452 -> over=132411` four times plus a live divergence, and 132411
  -- was mapped NOWHERE, so the button silently lost its dot.  Name confirmed off
  -- wago DB2 SpellName @ 12.0.7.68256 (the static spell API 404s on pet spells).
  -- `expect = false` — like Devour Magic, it only ever appears as an override.
  [132411]  = { group = "cc",  kind = "button", cadence = "utility", expect = false,
                label = "Singe Magic" },
  [1271802] = { group = "cc",  kind = "button", cadence = "utility", label = "Blight of Tongues" },
  [48020]   = { group = "mob", kind = "button", cadence = "utility", label = "Demonic Circle: Teleport" },

  -- ── Buff viewers.  kind = "aura": these are INPUTS to the score, never
  --    scored themselves, and they carry no dot. ─────────────────────────────
  [S.DEMONIC_CORE]    = { group = "proc",   kind = "aura", label = "Demonic Core" },
  [S.DIABOLIC_RITUAL] = { group = "proc",   kind = "aura", label = "Diabolic Ritual" },
  [S.WILD_IMP]        = { group = "summon", kind = "aura", label = "Wild Imp" },
  [S.DOMINION]        = { group = "core",   kind = "aura", label = "Dominion of Argus" },
}

--------------------------------------------------------------------------------
-- ⚠ DORMANT (Tier 3) — no live reader, from here to `Lookup helpers` below.
--------------------------------------------------------------------------------
-- `SpecNoCue` · `SpecProcGlow` · `SpecStacks` · `SpecOpener` · `SpecBurst` (and,
-- further down, `SpecGroups` / `SpecColor` / `SpecPole` / `SpecGhost`) were all read by
-- the old HudScore/HudChrome/HudOpener/HudQueue/HudBurst engine, DELETED at the W4
-- cutover.  Nothing in the pipeline reads them today.
--
-- They are kept on purpose, for two reasons: they are the REVIVAL SURFACE if the
-- sequence pane / proc routing / group tinting come back, and every name here is part
-- of the `ns.SpecFields` rebind contract (SpecRegistry.lua) that the multi-spec seam
-- copies off the active spec.  SpecDestruction omits the whole set, which is the proof
-- they are optional.  ⚠ `SpecGroups` is read by `SpecColor` — those two live or die
-- together.
--
-- The per-table essays that used to sit here argued with modules that no longer exist;
-- they are in git history and `docs/archive/` if a revival needs them.  Keep the DATA,
-- not the argument.
--------------------------------------------------------------------------------

spec.SpecNoCue = {
  [1276467]     = true,   -- Grimoire: Fel Ravager
  [S.IMP_LORD]  = true,   -- Grimoire: Imp Lord
  [136726]      = true,   -- Grimoire: Imp Lord (talent entry-id alias)
}

-- source buff spellID -> which BUTTON lights up.
spec.SpecProcGlow = {
  [S.DEMONIC_CORE] = {
    target = S.DEMONBOLT, group = "proc", softenAbove = 4,
    label = "Demonic Core -> Demonbolt", why = "core up",
  },
  [S.DIABOLIC_RITUAL] = {
    -- Only the HoG -> Ruination half is glowable: Shadow Bolt is not in the CDM
    -- tracked set, so SB -> Infernal Bolt has no icon to light.  Flagged, never faked.
    target = S.HAND_OF_GULDAN, group = "summon", transform = true,
    label = "Diabolic Ritual -> transformed button (HoG half only)",
    why = "art armed",
  },
}

-- Which tracked auras get their (unreadable) stack count enlarged, and the static gate
-- printed beside it.  The number stays Blizzard's — we cannot read it.
-- ⚠ The two constants are DIFFERENT and must never be crossed (notes.md §1): Wild Imps
-- gate Implosion at >=6; Demonic Core caps at 4.
spec.SpecStacks = {
  [S.WILD_IMP] = { suffix = "/6", label = "Wild Imp -> Implosion gate" },
}

-- The pre-pull opener — the "Tyrant-first burst", verified against the live #1 parse
-- (Inphected, WCL bracket 291, 2026-07-21).  ONE opener, deliberately: no alternate /
-- variant machinery, because WCL structurally cannot show which variant was chosen.
--
-- `preamble` casts happen BEFORE we are listening and are SHOWN as setup, never
-- advance-tracked.  `alt` lets one step match either of two abilities.  `optional`
-- steps drop without stalling the queue.  `prereqs` are the pre-pull wall-down state:
-- `spell` checks readiness (ready edge, or the napkin within `lead` seconds), `shards`
-- the live count; `lead` defaults to 0 (ready NOW).
spec.SpecOpener = {
  header   = "OPENER",
  preamble = "pre-stack: HoG -> DB/SB (seed a Core)",
  prereqs = {
    { spell = S.TYRANT,        label = "Tyrant" },
    { spell = S.DREADSTALKERS, label = "Dreadstalkers" },
    { shards = 5,              label = "5 shards" },
  },
  steps = {
    { spell = S.DREADSTALKERS,             label = "Dreadstalkers" },
    -- Imp Lord: correct id now, so the keybind resolves and readiness is knowable
    -- (M4.1 drops the old "if up" note that implied we couldn't tell).  Still
    -- `optional` so its absence drops through without jamming the queue.
    { spell = S.IMP_LORD,                  label = "Imp Lord", optional = true },
    { spell = S.TYRANT,                    label = "Tyrant", note = "t~3s" },
    { spell = S.SHADOW_BOLT, alt = S.DEMONBOLT, label = "SB / DB" },
    { spell = S.HAND_OF_GULDAN,            label = "HoG", count = 2 },
    { spell = S.IMPLOSION,                 label = "Implosion", optional = true, note = "AoE" },
    -- (The old trailing "SB x3 rebuild" step was dropped in M4.1: a scripted
    -- filler tail is thrown out by the first proc, so it only misinformed.)
  },
}

-- The BURST window — a Tyrant window opening mid-fight.  Staged summons first
-- (Dreadstalkers + Imp Lord land BEFORE Tyrant), then Tyrant, then the burn: dump
-- shards into HoG, spend banked Cores, Implosion on AoE.  `lead = 5` on the prereqs so
-- "Tyrant" lights while it is still coming up, matching when the window opens.
spec.SpecBurst = {
  header   = "BURST",
  preamble = "Tyrant window — stage demons, then dump",
  prereqs = {
    { spell = S.TYRANT,        label = "Tyrant", lead = 5 },
    { spell = S.DREADSTALKERS, label = "Dreadstalkers", lead = 5 },
    -- Imp Lord is an OPTIONAL prereq: nice to have in the window, but its absence
    -- (off-Tyrant cycle) must NOT gate the sequence from lighting up as ready.
    { spell = S.IMP_LORD,      label = "Imp Lord", lead = 5, optional = true },
    { shards = 5,              label = "5 shards" },
  },
  steps = {
    { spell = S.DREADSTALKERS,  label = "Dreadstalkers" },
    { spell = S.IMP_LORD,       label = "Imp Lord", optional = true },
    { spell = S.TYRANT,         label = "Tyrant" },
    { spell = S.HAND_OF_GULDAN, label = "HoG", count = 2 },
    { spell = S.DEMONBOLT,      label = "Demonbolt", note = "cores" },
    { spell = S.IMPLOSION,      label = "Implosion", optional = true, note = "AoE" },
  },
}

-- Lookup helpers ---------------------------------------------------------------

local NEUTRAL = { group = "neutral", kind = "button", cadence = "utility" }

-- Never nil, never errors: unknown IDs get the neutral accent.
-- A Secret Value must never be used as a table key (indexing with one taints),
-- so it is treated exactly like an unresolved ID — neutral, no guess.
function spec.SpecInfo(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return NEUTRAL, false end
  local e = ns.Spec[spellID]
  if e then return e, true end
  return NEUTRAL, false
end

-- r, g, b for a spellID's group hue.
function spec.SpecColor(spellID)
  local info = ns.SpecInfo(spellID)
  local c = ns.SpecGroups[info.group] or ns.SpecGroups.neutral
  return c[1], c[2], c[3]
end

-- DORMANT (see the banner above).  Which BATCH TINT pole an ability sits at.
-- Order matters: `spends` is checked BEFORE `generatesFrags`, so Demonbolt (spends a Core,
-- refunds 2 shards) lands at the CONSUMER pole beside HoG rather than opposite it.
function spec.SpecPole(info)
  if info.kind == "aura" then return "proc" end
  if info.cadence == "utility" then return "utility" end
  if info.cadence == "oncd" or info.spends then return "consumer" end
  if info.generatesFrags then return "generator" end
  return "consumer"
end

-- DORMANT (see the banner above); superseded by SpecPowerDelta below.  Deterministic
-- shard yield of an in-flight cast, in FRAGMENTS since Phase 6.2.
function spec.SpecGhost(spellID)
  return (ns.SpecInfo(spellID).generatesFrags) or 0
end

-- SIGNED net power delta of an in-flight cast (multi-spec Phase 3; was SpecShardDelta,
-- W4 P6 Part 2) — what the power bar will read AFTER this cast resolves, relative to now,
-- AND which named power it moves.  Positive for a builder (Shadow Bolt +10, Demonbolt +20,
-- Infernal Bolt +30), NEGATIVE for a pure spender (Hand of Gul'dan −cost).  Supersedes
-- SpecGhost as the Coach's `incoming` reader so an in-flight HoG projects −30 and the Coach
-- (ranking on projected = value + incoming) clears it to the builder mid-cast instead of
-- re-cuing the spell you are casting.
--
--   delta = (generatesFrags or 0) − (live shard cost x FRAGS_PER_SHARD IFF it spends shards)
--
-- ⚠ EVERYTHING HERE IS FRAGMENTS (Phase 6.2), because that is the unit the brain's gates
-- compare in and the unit the client's exact power read hands back.  ns.ShardCost's name
-- says shards and it means it — `C_Spell.GetSpellPowerCost` PRE-APPLIES the display divisor
-- (Chaos Bolt: DB2 stores 20, the client returns 2, measured 2026-08-01) — so the cost is
-- multiplied UP here, at the one conversion site this function has.  A missed conversion is
-- a silent 10x error that still looks like a plausible shard count; there is deliberately no
-- second place it could hide.
--
-- ⚠ THE CONSTANT, not the pulse's live `modifier`: this is a pure (spellID) -> delta
-- function by contract (Coach.InflightPower passes it nothing else), so it has no pulse to
-- ask.  spec.FRAGS_PER_SHARD is the same number the brain falls back to when the exact read
-- refuses, and the game has reported 10 since the rail existed.
--
-- Returns `{ power, delta }` — Phase 3 made the projection per-power (State sums delta
-- into sums[power]), so the reader now NAMES the power it moves ("SoulShards" for Demo).
-- A zero net delta (an art spender with no refund, or an unknown id) returns
-- `{ power = nil, delta = 0 }`; State's accumulator skips a nil-power entry.
--
-- The spend is counted only when `spends == "shards"` — Demonbolt spends a CORE, not
-- shards, so its +20 refund stands uncosted (same rule as SpecPole's C2 ordering).  The
-- cost is read LIVE (talent-dependent) via ns.ShardCost; an UNREADABLE cost drops the
-- spend term (delta = generatesFrags only) rather than guessing — the safe direction (never
-- pre-deducts shards on an unreadable read).
function spec.SpecPowerDelta(spellID)
  local info = ns.SpecInfo(spellID)
  local delta = info.generatesFrags or 0
  if info.spends == "shards" and ns.ShardCost then
    local cost = ns.ShardCost(spellID)
    if type(cost) == "number" then
      delta = delta - math.floor(cost * spec.FRAGS_PER_SHARD + 0.5)
    end
  end
  if delta == 0 then return { power = nil, delta = 0 } end
  return { power = "SoulShards", delta = delta }
end

-- Self-register (multi-spec) --------------------------------------------------
-- The resolver rebinds ns.SpecIDs / ns.SpecInfo / … from this object.  Registration is
-- static; ACTIVATION is the resolver's job (Phase 5) — ns.ResolveActiveSpec detects the
-- player's real spec on login / PLAYER_SPECIALIZATION_CHANGED and activates 266 only when
-- Demonology is actually the current spec.
ns.RegisterSpec(266 --[[ Demonology ]], spec)
