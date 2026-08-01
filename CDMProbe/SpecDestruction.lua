-- SpecDestruction.lua — the per-spec DATA table for Destruction Warlock (267).
--
-- The project's SECOND registered spec, and the first one authored through the
-- multi-spec seam rather than retro-fitted into it (docs/adding-a-spec.md, Steps 2 + 6).
-- It is DATA ONLY: named IDs, the power array, the decision-log vocabulary, the
-- per-spellID signal bucket, and the two lookup helpers the pipeline calls.  The rotation
-- BRAIN (Context / RankWinner / Escalate) is CoachDestruction.lua, which hangs itself on
-- the same object this file registers.
--
-- WHAT IS DELIBERATELY ABSENT (adding-a-spec.md "Tier 3 — carried but dormant").
-- Demonology carries SpecGroups / SpecColor / SpecPole / SpecGhost / SpecNoCue /
-- SpecProcGlow / SpecStacks / SpecOpener / SpecBurst.  NONE of them has a live consumer
-- in the v1 pipeline (v1 colours cues by `emphasis`, not group hue, and the sequence panel
-- was retired at the TCT redesign), so this file omits all nine rather than cargo-culting
-- them.  ns.SetActiveSpec clears each to nil when Destruction activates — verified safe:
-- no module outside SpecDemonology.lua reads them.  The colour-group MEMBERS are still
-- documented, as prose, in specs/destruction/notes.md.
--
-- THE SIGNAL BUCKET (`spec.Spec`).  Same vocabulary as SpecDemonology.lua; the fields the
-- generic shell actually reads are `emphasis` / `kind` / `cadence` / `label` / `abbr` /
-- `transform`, and everything else is this spec's private convention (read by the brain):
--   kind       — "button" (an icon you press) | "aura" (a buff-viewer input, never scored)
--   spends     — what pressing it CONSUMES: "shards" | "art".  The numeric cost is NEVER
--                authored here — it is talent-dependent, so it is read at runtime via
--                ns.ShardCost (Util.lua), with a per-ability fallback on the brain.
--   cadence    — "oncd" | "gated" | "reactive" | "filler" | "utility"
--   judgeable  — DEFAULT TRUE.  False = the ability's TRUE gate is something we cannot
--                read, so we must never claim it is the right press.  Havoc is the
--                Destruction case (its gate is `target_if` over a target roster with
--                time-to-die — no roster, no TTD), which is why it is NOT in the priority
--                list at all (specs/destruction/input-contract.md).
--   secretGate — the sentence a judgeable=false ability would print instead of a call
--   expect     — DEFAULT TRUE.  False = "never expect this bound to a CDM icon"; it only
--                exists as a live spell OVERRIDE (the two Demonic Art transforms).
--   baseCD     — documented base cooldown, sanity-check only (ns.BaseCooldown reads live)
--   label      — human name, for `/cdmp hud status`
--   abbr       — the decision-log short code (ONE edit site per ability, per Step 6)
--
-- ⚠ DESK-DERIVED, NOT YET FLOWN.  Every ID below is Tier-1 (wago DB2 via
-- `wowkb.spec_inventory --spec Destruction`, reconciled against SpellName @ 12.0.7) — they
-- are not guesses.  What is UNCONFIRMED is which of them the live Cooldown Manager
-- actually tracks for a given build: `/cdmp hud layout` on a real Destruction character is
-- the one-time check (adding-a-spec.md Step 8).  The two specific worries are recorded at
-- their entries below (Incinerate's absence, and the Art override IDs).
local ADDON, ns = ...

local spec = {}

-- Named IDs.  Tier-1: `wowkb.spec_inventory --spec Destruction` @ 12.0.7.
spec.SpecIDs = {
  -- The rotation buttons.
  CHAOS_BOLT        = 116858,
  CONFLAGRATE       = 17962,
  SHADOWBURN        = 17877,
  RAIN_OF_FIRE      = 5740,
  SOUL_FIRE         = 6353,
  CATACLYSM         = 152108,
  SUMMON_INFERNAL   = 1122,
  HAVOC             = 80240,
  CHANNEL_DEMONFIRE = 196447,
  -- Immolate is tracked as the DoT AURA id 157736, NOT the cast id 348 (both resolve to
  -- "Immolate" in SpellName; the cooldown-set data carries the aura).  So the registry
  -- entry, the keybind resolution and every cue key off 157736, with 348 aliased below —
  -- exactly the Imp Lord cast-id-vs-entry-id problem SpecDemonology.lua already solves.
  -- The upside: a tracked AURA is where a duration/uptime read would come from, which is
  -- what the L8 DoT-maintenance line is blocked on (see CoachDestruction).
  IMMOLATE          = 157736,
  IMMOLATE_CAST     = 348,
  -- The spec's FLOOR PRESS — and the one that may have no icon.  Incinerate does not
  -- appear in the Destruction union at all (not the talent tree, not the class skill line,
  -- not the CooldownSetSpell residue), so if that reflects the live CDM set then the
  -- bottom of the priority list has nothing to light, and the Infernal Bolt transform is
  -- blind the way Shadow Bolt's is for Demonology.  The brain degrades honestly (an
  -- untracked line simply yields no candidate and evaluation continues).
  -- @verify-ingame — the single most important thing to check on a live capture.
  INCINERATE        = 29722,
  -- (Hellcaller) — the two abilities the delta section adds.  Registered so a Hellcaller
  -- build is not blind; the brain gives Malevolence its own on-cooldown line.
  MALEVOLENCE       = 442726,
  WITHER            = 445468,

  -- The Demonic Art transforms (Diabolist).  These are OVERRIDES — they replace Chaos
  -- Bolt / Incinerate on the live button and are never separately tracked.
  -- ⚠ THE ID SPLIT.  SpellName carries three "Ruination" ids (433885 / 434635 / 434636)
  -- and two "Infernal Bolt" (433891 / 434506).  Demonology CONFIRMED 434635 / 434506 live
  -- off the retired probe; Destruction's cooldown-set residue names 433885 / 433891 — i.e.
  -- the pair SpecDemonology.lua labels "alt ID, unconfirmed" are most likely the
  -- DESTRUCTION-side ids.  So this file takes the residue pair as primary and maps the
  -- Demo-confirmed pair as harmless aliases (they cost nothing and cover a build that
  -- surfaces the other id).  Identity is keyed on `abbr`, so either id reads the same.
  RUINATION         = 433885,
  INFERNAL_BOLT     = 433891,

  -- Buff viewers — the proc/aura inputs.
  DIABOLIC_RITUAL   = 428514,   -- the Demonic Art container (Demo found this tracked TWICE
                                -- under two cooldownIDs sharing one spellID; harmless here,
                                -- the domain view folds by base spellID)
  BACKDRAFT         = 117828,   -- 2 stacks; PRESENCE readable, COUNT secret
  CHAOTIC_INFERNO   = 1244860,  -- arms the empowered Incinerate (L6)
  FIENDISH_CRUELTY  = 1245664,  -- arms Shadowburn (L7)
  -- ⚠ CRASHING_CHAOS 417234 WAS HERE AND IS DELETED ON PURPOSE (Phase 4, 2026-07-31).
  -- The CDM tracks it in ZERO rows, so it had no `IsActive()`, no `auraDataUnit`, no
  -- edges — and in combat there is no fallback channel at all (`C_UnitAuras` is fully
  -- secret, and `COMBAT_LOG_EVENT_UNFILTERED` errors on registration).  What it would
  -- have told us is a SHARD-COST change, which the brain already reads live via
  -- `costOf` -> `ns.ShardCost` -> `C_Spell.GetSpellPowerCost`
  -- (CoachDestruction.lua).  Redundant, not blind — and it was the only reader of its
  -- own declaration.  Don't re-add it; add the observation you actually need instead.
  BACKLASH          = 387384,
  FLASHPOINT        = 387263,
  LAKE_OF_FIRE      = 1244918,
  ALYTHESS_IRE      = 1244947,
}

local S = spec.SpecIDs

-- Keybind-resolution aliases.  A spell whose CDM/tracked id differs from the id sitting on
-- the action bar won't resolve a keybind under its own id.  Immolate is the case: tracked
-- as the DoT aura 157736, cast (and bound) as 348.  HudBinds.Get falls back to the alias,
-- so the cue shows the key either way.  Bidirectional.
spec.SpecBindAlias = {
  [157736] = 348,
  [348]    = 157736,
}

-- The Soul Shard cap.  Destruction spends in whole shards against the same 0–5 rail.
spec.SHARD_CAP = 5

-- THE POWER ARRAY.  Destruction rides the SAME power as Demonology — SoulShards, rendered
-- as discrete pips on the SOUL_SHARDS token — so this spec touches NEITHER of the two
-- Renderer generalization points (adding-a-spec.md Step 5): no new power colour to resolve
-- through PowerBarColor, and no `continuous` fill path to build.
--
-- ⚠ FRAGMENTS, and why `display` is still "discrete".  Destruction SPENDS in whole shards
-- (Chaos Bolt 2 / Rain of Fire 3 / Shadowburn 1) but GENERATES in tenths — Incinerate,
-- Conflagrate, Soul Fire and Immolate ticks each pay a fraction.  The bar is conventionally
-- drawn as 5 segments with partial fill, which is neither `discrete` nor `continuous`.  We
-- render `discrete` because State cannot READ the fraction anyway: State.lua's readOnePower
-- calls UnitPower("player", pt) with no unmodified flag, so the value that arrives here is
-- already whole shards.  Adding a segments-with-partial-fill member to `resourceDisplay`
-- would be a contract edit that displays a precision we do not have — so the enum stays
-- closed until the fragment READ lands (specs/destruction/observability-map.md).
spec.powers = {
  { name = "SoulShards", display = "discrete", incoming = true, token = "SOUL_SHARDS" },
}

-- The DECISION-LOG vocabulary (adding-a-spec.md Step 6).  DecisionLog.lua holds no spec
-- constants: per-ability short codes ride `abbr` on each spec.Spec entry, and the
-- non-per-ability bits live here.  Read off ns.ActiveSpec.log.
--   cdOrder    the S{CD:…} readiness render order, by abbr (deterministic).
--   procOrder  the S{PR:…} proc/buff render order, by code.
--   procBuffs  buff spellID -> PR code (the domain view's `buffs` is spellID-keyed).
--   artArmed   a live override id in this set ⇒ the Demonic-Art transform is up.
-- NOTE: no `coreGlowID`.  That field is Demonology's "the Demonbolt glow IS the Demonic
-- Core proc" shortcut, and DecisionLog hardcodes the literal code `core` for it.
-- Destruction's procs all read off `buffs` (procBuffs covers them), and its glow analogue
-- would sit on Incinerate — the one button that may not be tracked.  Omitted rather than
-- borrowed.
spec.log = {
  -- Only the cooldown-BEARING rotation buttons; the fillers/spenders have no readiness to
  -- render.  Order is burst -> the timed talents -> the charged instants -> the utilities
  -- of the rotation.
  cdOrder   = { "SI", "Mal", "SF", "Cat", "Conf", "SB", "CDF", "Hav" },
  -- ⚠ A code absent from this list is SILENTLY DROPPED from `PR:`, so every per-id transform
  -- abbr has to appear here or the split above buys nothing.  The suffixed codes are the
  -- alias IDs (IB2 = 434506, RU2 = 434635, RU3 = 434636); a bare IB/RU is the
  -- cooldown-set-residue id (433891 / 433885).  Which one the client actually surfaces is
  -- the open question this ordering exists to answer — see the transform block below.
  procOrder = { "art", "BD", "CI", "FC", "IB", "IB2", "RU", "RU2", "RU3" },
  procBuffs = {
    [428514]  = "art",   -- Diabolic Ritual — the Demonic Art container
    [117828]  = "BD",    -- Backdraft (presence only; the stack count is secret)
    [1244860] = "CI",    -- Chaotic Inferno
    [1245664] = "FC",    -- Fiendish Cruelty
  },
  -- Both id pairs, for the same reason SpecIDs maps both (see the ID-split note).
  artArmed  = { [433885] = true, [433891] = true, [434506] = true, [434635] = true,
                [434636] = true },
}

spec.Spec = {
  -- ── Essential: the burst window ───────────────────────────────────────────
  -- Summon Infernal is the WHOLE window — there is no second summon to line up with, and
  -- everything that syncs to it (potion, racials, trinkets) is off-GCD or not ours to cue.
  -- So there is NO go-gate and NO `stage` bit here: Demonology's "hold this so it lands
  -- inside the window" has no Destruction analogue, because nothing is held for the
  -- Infernal (specs/destruction/notes.md).  `emphasis = "burst"` marks it the loudest cue
  -- on the board, the one field that carries over from Tyrant.
  [S.SUMMON_INFERNAL] = {
    kind = "button", spends = "shards", cadence = "oncd", emphasis = "burst",
    baseCD = 120, abbr = "SI", label = "Summon Infernal",
    lost = "the burst window has no button — the only cooldown worth building around",
  },
  -- (Hellcaller) Malevolence is a SECOND, INDEPENDENT burst line — ~60s against the
  -- Infernal's 120s/90s, and the KB is explicit that the two deliberately do NOT align
  -- outside a fight's final casts.  So it is its own on-cooldown press, never a paired
  -- gate; building a Tyrant-style common-fate treatment here would be wrong roughly every
  -- other window.
  [S.MALEVOLENCE] = {
    kind = "button", cadence = "oncd", baseCD = 60, abbr = "Mal",
    label = "Malevolence (Hellcaller)",
  },

  -- ── Essential: the fire core ──────────────────────────────────────────────
  -- Chaos Bolt: the payoff spender the whole shard economy points at, and the frame the
  -- Ruination transform rides.  It appears at THREE lines of the priority list (L3 spend
  -- the Art, L11 the main dump, and L1 as Ruination), so a second-place recompute must
  -- suppress all three — which it does for free, since they all key on this one base id.
  [S.CHAOS_BOLT] = {
    kind = "button", spends = "shards", cadence = "gated", primary = true,
    abbr = "CB", label = "Chaos Bolt",
  },
  -- Incinerate: the floor press.  `lost` states what its absence costs, in the same spirit
  -- as Demonology's Shadow Bolt entry — and here it is worse, because Incinerate is pressed
  -- far more often than Shadow Bolt and carries the Infernal Bolt transform.
  [S.INCINERATE] = {
    kind = "button", cadence = "filler", abbr = "Inc", label = "Incinerate",
    lost = "the floor press has no icon, and Inc -> Infernal Bolt cannot light",
  },
  -- CONFLAGRATE is the project's first — and so far only — charged tracked ability
  -- (2 charges, ~13s recharge).  Demonology has none.  ns.ReadCharges is combat-gated
  -- (C_Spell.GetSpellCharges reads secret in restricted combat), so the EXACT count is an
  -- OOC luxury; in a pull the brain reads State's CHARGE NAPKIN instead (seeded exact OOC,
  -- -1 per landed cast, +1 per ChargeGained alert, clamped, biased to undercount).
  -- `charges` here documents the real ability; the count comes from State.
  [S.CONFLAGRATE] = {
    kind = "button", cadence = "reactive", charges = 2, abbr = "Conf",
    label = "Conflagrate",
  },
  -- ⚠ SHADOWBURN HAS NO CHARGES.  This entry carried `charges = 2` and these docs called it
  -- the second charged ability; both were wrong.  DB2 @ 12.0.7 is unambiguous —
  -- SpellCategories.ChargeCategory is 0 for Shadowburn 17877 (and Chaos Bolt), against
  -- Conflagrate 17962's 672 — which also matches the live alert capture: Conflagrate raised
  -- ChargeGained, Shadowburn never did.  So it has no charge channel to miss.
  [S.SHADOWBURN] = {
    kind = "button", spends = "shards", cadence = "reactive", abbr = "SB",
    label = "Shadowburn",
  },
  -- Soul Fire: a hard-cast builder on a ~45s cooldown that also refreshes Immolate.
  [S.SOUL_FIRE] = {
    kind = "button", cadence = "oncd", baseCD = 45, abbr = "SF", label = "Soul Fire",
  },
  -- Immolate — the spec's SPINE, keyed on the tracked DoT aura id (see SpecIDs).
  [S.IMMOLATE] = {
    kind = "button", cadence = "gated", abbr = "Imm", label = "Immolate",
  },
  -- 348 is the CAST id, kept mapped as a harmless alias for a build that surfaces it
  -- (the tracked/cue id is S.IMMOLATE above) — the same treatment Demo gives 136726.
  -- ⚠ `expect = false` BECAUSE IT IS AN ALIAS, not a second ability.  The field means
  -- "never expect this bound to a CDM icon of its own", which was already true here (the
  -- CDM tracks Immolate as the DoT aura 157736) and merely under-stated.  It became
  -- load-bearing with State's virtual-row walk: Immolate has no base cooldown, so without
  -- this an absent 348 would pass every fence and get drawn as a SECOND Immolate icon
  -- beside the real one.
  [S.IMMOLATE_CAST] = {
    kind = "button", cadence = "gated", expect = false, abbr = "Imm",
    label = "Immolate (cast-id alias)",
  },
  -- (Hellcaller) Wither replaces Immolate.  A STACKING DoT whose 8-stack Blackened Soul
  -- threshold is as unreadable as Backdraft's count — so the brain can maintain it and
  -- never play around its stacks.
  [S.WITHER] = {
    kind = "button", cadence = "gated", abbr = "Wth", label = "Wither (Hellcaller)",
  },

  -- ── Essential: AoE / fel explosion ────────────────────────────────────────
  -- Rain of Fire's REAL gate is a target count (~8+ on Diabolist, 5+ on Hellcaller).  We
  -- have no target roster, only the manual single/AoE mode toggle, so the brain gates it
  -- on `mode` — a player DECLARATION, never an observation.
  [S.RAIN_OF_FIRE] = {
    kind = "button", spends = "shards", cadence = "gated", abbr = "RoF",
    label = "Rain of Fire",
  },
  [S.CATACLYSM] = {
    kind = "button", cadence = "oncd", baseCD = 30, abbr = "Cat", label = "Cataclysm",
  },
  -- Channel Demonfire is a CHOICE node whose simc placement depends on Immolate/Wither
  -- spread we cannot count, so it is registered (it classifies, it can show SOON) but is
  -- deliberately NOT in the priority list — parked until the build is settled
  -- (specs/destruction/rotation.md, Deviation 6).
  [S.CHANNEL_DEMONFIRE] = {
    kind = "button", cadence = "reactive", baseCD = 25, abbr = "CDF",
    label = "Channel Demonfire",
  },
  -- THE judgeable=false case for this spec — Destruction's Implosion.  Havoc's true gate is
  -- simc's `target_if`: the add with the most time-to-die that is not your current target,
  -- and not right before Infernal.  We have no target roster and no time-to-die, so we can
  -- never claim this is the press; it stays out of the priority list entirely and hands the
  -- call back with the reason stated.
  [S.HAVOC] = {
    kind = "button", cadence = "reactive", baseCD = 30, judgeable = false,
    secretGate = "which add, and how long it lives — your call",
    abbr = "Hav", label = "Havoc",
  },

  -- ── The Demonic Art transforms (Diabolist) ────────────────────────────────
  -- OVERRIDES, never separately tracked: Ruination replaces Chaos Bolt, Infernal Bolt
  -- replaces Incinerate.  `expect = false` so an expected-vs-bound diff never reports them
  -- as a missing ability (unbound is their normal state).  `spends = "art"` is what the
  -- brain's Context filters on to recognise an armed Art, and **`art`** is what tells the
  -- two apart — deliberately NOT a `generates` number, because Destruction's Infernal Bolt
  -- refills in FRAGMENTS and the KB has no clean whole-shard figure for it
  -- (@verify-ingame).  Demonology could key on `generates == 3`; we key on identity.
  -- Both id pairs mapped — see the ID-split note in SpecIDs.
  --
  -- ⚠ `art` EXISTS SO `abbr` CAN BE PER-ID.  These two fields were one until 2026-07-30:
  -- the brain branched on `abbr == "IB"`, which forced every Infernal Bolt id to share one
  -- code — and that made the log unable to answer the open question it was recording for.
  -- The 2026-07-30 capture shows `IB` on 9 lines and CANNOT say whether 433891 or 434506
  -- surfaced, which is exactly the unknown (*status.md* Destruction item 4) the pass was
  -- meant to close.  So semantics moved to `art` (what the brain reads) and `abbr` became
  -- the per-id DISPLAY code (what the log prints).  Do not re-merge them.
  [433885] = { kind = "button", spends = "art", art = "ruination", cadence = "reactive",
               expect = false, abbr = "RU",  label = "Ruination" },
  [434635] = { kind = "button", spends = "art", art = "ruination", cadence = "reactive",
               expect = false, abbr = "RU2", label = "Ruination (Demo-confirmed ID, alias)" },
  [434636] = { kind = "button", spends = "art", art = "ruination", cadence = "reactive",
               expect = false, abbr = "RU3", label = "Ruination (alt ID, unconfirmed)" },
  [433891] = { kind = "button", spends = "art", art = "infernal",  cadence = "reactive",
               expect = false, abbr = "IB",  label = "Infernal Bolt" },
  [434506] = { kind = "button", spends = "art", art = "infernal",  cadence = "reactive",
               expect = false, abbr = "IB2", label = "Infernal Bolt (Demo-confirmed ID, alias)" },

  -- ── Utility: defensives / CC / mobility ───────────────────────────────────
  -- Class-shared with Demonology, so the same shape.  Utilities are never scored, never
  -- cued and are excluded from the SOON decoration by the shell.
  [104773]  = { kind = "button", cadence = "utility", label = "Unending Resolve" },
  [108416]  = { kind = "button", cadence = "utility", label = "Dark Pact" },
  [30283]   = { kind = "button", cadence = "utility", label = "Shadowfury" },
  [5484]    = { kind = "button", cadence = "utility", label = "Howl of Terror" },
  [6789]    = { kind = "button", cadence = "utility", label = "Mortal Coil" },
  -- The live tracked set carries the WRAPPER spell Command Demon, not the pet ability;
  -- both mapped, as for Demonology.  The pet DISPELS (Devour Magic / Singe Magic) override
  -- this same button, so they are mapped too with expect = false — that override is what
  -- silently cost Demonology a button's dot twice.
  [119898]  = { kind = "button", cadence = "utility", label = "Command Demon" },
  [119914]  = { kind = "button", cadence = "utility", label = "Axe Toss" },
  [388215]  = { kind = "button", cadence = "utility", expect = false, label = "Devour Magic" },
  [132411]  = { kind = "button", cadence = "utility", expect = false, label = "Singe Magic" },
  [1271802] = { kind = "button", cadence = "utility", label = "Blight of Tongues" },
  [48020]   = { kind = "button", cadence = "utility", label = "Demonic Circle: Teleport" },

  -- ── Buff viewers.  kind = "aura": INPUTS to the decision, never scored, no cue. ──
  [S.DIABOLIC_RITUAL]  = { kind = "aura", label = "Diabolic Ritual" },
  [S.BACKDRAFT]        = { kind = "aura", label = "Backdraft" },
  [S.CHAOTIC_INFERNO]  = { kind = "aura", label = "Chaotic Inferno" },
  [S.FIENDISH_CRUELTY] = { kind = "aura", label = "Fiendish Cruelty" },
  [S.BACKLASH]         = { kind = "aura", label = "Backlash" },
  [S.FLASHPOINT]       = { kind = "aura", label = "Flashpoint" },
  [S.LAKE_OF_FIRE]     = { kind = "aura", label = "Lake of Fire" },
  [S.ALYTHESS_IRE]     = { kind = "aura", label = "Alythess's Ire" },
}

-- Lookup helpers ---------------------------------------------------------------

local NEUTRAL = { kind = "button", cadence = "utility" }

-- Never nil, never errors: unknown IDs get the neutral fallback.
-- ⚠ THE SECRET GUARD IS LOAD-BEARING and is kept verbatim from SpecDemonology: a Secret
-- Value must never be used as a table key (indexing with one taints), so a secret id is
-- treated exactly like an unresolved one — neutral, no guess.
function spec.SpecInfo(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return NEUTRAL, false end
  local e = ns.Spec[spellID]
  if e then return e, true end
  return NEUTRAL, false
end

-- SIGNED net power delta of an in-flight cast — what the shard bar will read AFTER this
-- cast resolves, relative to now, and which named power it moves.  State folds it into
-- `incoming`, and the brain ranks on projected = value + incoming.
--
-- ⚠ SPENDERS ONLY, ON PURPOSE.  Demonology projects both halves because its generators pay
-- WHOLE shards (Shadow Bolt +1, Demonbolt +2, Infernal Bolt +3).  Destruction's builders
-- pay FRAGMENTS — Incinerate, Conflagrate, Soul Fire and Immolate ticks each yield a
-- fraction — into a bar State can only read in whole shards.  Authoring a fake integer
-- `generates` for them would make the projection lie by up to a full shard on every filler
-- cast, so this spec declines to project builders at all (the option
-- specs/destruction/notes.md spells out) and carries no `generates` field anywhere.
--
-- The SPENDER half is clean whole numbers (Chaos Bolt -2, Rain of Fire -3, Shadowburn -1),
-- so it transfers from Demonology unchanged, including State's double-deduction guard: an
-- in-flight Chaos Bolt projects -2 and the brain re-ranks to the next press mid-cast
-- instead of re-cuing the spell you are already casting.  That is the half that matters
-- for correctness; the builder half only costs us the fine-grained pooling gates, which
-- rotation.md already rounds conservatively.
--
-- The cost is read LIVE (talent-dependent) via ns.ShardCost; an UNREADABLE cost drops the
-- term (delta 0) rather than guessing — the safe direction, since it never pre-deducts
-- shards we are not sure will be spent.
function spec.SpecPowerDelta(spellID)
  local info = ns.SpecInfo(spellID)
  local delta = 0
  if info.spends == "shards" and ns.ShardCost then
    local cost = ns.ShardCost(spellID)
    if type(cost) == "number" then delta = -cost end
  end
  if delta == 0 then return { power = nil, delta = 0 } end
  return { power = "SoulShards", delta = delta }
end

-- Self-register.  Registration is STATIC; ACTIVATION is the resolver's job —
-- ns.ResolveActiveSpec detects the player's real spec on login / PLAYER_SPECIALIZATION_
-- CHANGED and activates 267 only when Destruction is actually the current spec.  Never
-- call ns.SetActiveSpec from a spec file.
ns.RegisterSpec(267 --[[ Destruction ]], spec)
