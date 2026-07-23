-- SpecDemonology.lua — the per-spec data table (v1 target: Demonology Warlock).
--
-- ONE table, ONE edit site.  Every Hud* module reads identity + signals from
-- here and holds no spell constants of its own, so adding a second spec (M7)
-- means adding a sibling file, not touching the renderers.
--
-- M3c-a replaced the single `role` enum with a SIGNAL BUCKET.  `role` conflated
-- three separate concepts, and the tell was HudChrome's batch table: `spender`
-- and `burst` carried IDENTICAL tint values, so `burst` never encoded anything —
-- it only smuggled burst-lane membership through the tint field.  The bucket
-- splits those concepts apart so `HudScore` can read each one on its own:
--
--   group      — the §3 colour group (hue carries GROUP, never per-ability
--                identity, and never actionability — that's the dot's job now)
--   kind       — "button" (an icon you press) | "aura" (a buff viewer entry)
--   spends     — what pressing it CONSUMES: "shards" | "core" | "art".  The
--                numeric cost is NEVER authored here — it is talent-dependent,
--                so it's read at runtime via ns.ShardCost (Util.lua).
--   generates  — deterministic Soul Shard yield.  SUBSUMES the old `ghost`
--                field: one field, one meaning.  Drives both the in-flight
--                ghost fill and the overcap guard in HudScore.
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
--                how §0.5.8.6 blocking error #2 got shipped the first time:
--                someone re-derives the lane from burstAlign and Grimoire (which
--                is burst-aligned but is NOT a go-gate) sneaks back into it.
--   stage      — (M4) HOLD this inside the BURST window so it lands fresh IN the
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
--                the M3c-b B7 expected-vs-bound warning, which would otherwise
--                report every Demonic Art transform as a missing ability.
--   lost       — the sentence B7 prints for what a MISSING ability costs you.
--                Says what is lost, not just what is absent.
--   baseCD     — documented base cooldown, sanity-check only.  ns.BaseCooldown
--                reads the live value; nil here means "the docs don't assert it".
--   label      — human name, for `/cdmp hud status` only
--
-- Unknown spellIDs fall back to the neutral accent — never crash, never guess.
local ADDON, ns = ...

-- Group hues.  These are the exact triples tuned in Resource.lua:12-27; do not
-- re-pick them.  spec.md §3: summon = fel green, core shadow = violet, fel
-- explosion = lime, proc/resource = cyan, defensive = blue, CC = slate,
-- mobility = gold.
ns.SpecGroups = {
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
ns.SpecIDs = {
  TYRANT        = 265187,
  DREADSTALKERS = 104316,
  HAND_OF_GULDAN = 105174,
  DEMONBOLT     = 264178,
  SHADOW_BOLT   = 686,
  IMPLOSION     = 196277,
  -- Buff viewers (M3b proc presence via the TriggerAlertEvent aura edges;
  -- item:IsShown() is only the best-effort LEVEL backstop — see HudState.lua):
  DEMONIC_CORE   = 264173,   -- BuffBar
  DIABOLIC_RITUAL = 428514,  -- BuffIcon — the Demonic Art container
  WILD_IMP       = 296553,   -- BuffIcon — M5 #17 stack text
  DOMINION       = 1276166,  -- BuffBar
}

local S = ns.SpecIDs

-- The Soul Shard cap.  Used by the overcap guard: a generator that would push
-- past this stops being a ROTATION call even when its proc is genuinely up.
ns.SHARD_CAP = 5

ns.Spec = {
  -- ── Essential: the burst summons (§3 "summon" / fel green) ────────────────
  -- cadence = "oncd": these are the abilities the user rates the biggest win —
  -- "firing cooldown abilities as soon as they are up".  So a ready edge on any
  -- of them is a ROTATION call outright, and the napkin gives them lead time.
  [S.TYRANT] = {
    group = "summon", kind = "button", spends = "shards", cadence = "oncd",
    burstAlign = true, goGate = true, baseCD = 60, label = "Summon Demonic Tyrant",
  },
  -- `stage = true` (M4): inside the BURST window HudScore reads this AVAILABLE
  -- "stage for Tyrant" instead of greenlighting it on cooldown, so it lands FRESH
  -- in the window — rotation.md #5: a Dreadstalkers cast too early expires before
  -- Tyrant. Keyed on this bit (not "goGate and not Tyrant") so Tyrant is never held.
  [S.DREADSTALKERS] = {
    group = "summon", kind = "button", spends = "shards", cadence = "oncd",
    burstAlign = true, goGate = true, stage = true, baseCD = 20,
    label = "Call Dreadstalkers",
  },
  -- Grimoire is burst-ALIGNED but is NOT part of the go-gate (see `goGate` above).
  [1276467] = {
    group = "summon", kind = "button", cadence = "oncd", burstAlign = true,
    baseCD = 120, label = "Grimoire: Fel Ravager",
  },
  [136726] = {
    group = "summon", kind = "button", cadence = "oncd", burstAlign = true,
    baseCD = 120, label = "Grimoire: Imp Lord",
  },

  -- ── Essential: core shadow damage (§3 "core" / shadow violet) ─────────────
  -- HoG is the spender the whole shard economy points at — `primary`.
  [S.HAND_OF_GULDAN] = {
    group = "core", kind = "button", spends = "shards", cadence = "gated",
    primary = true, label = "Hand of Gul'dan",
  },
  -- C2, the pole fix.  v0.9.1 classified Demonbolt as a `builder`, which put it
  -- at the OPPOSITE tint pole from Hand of Gul'dan — its single most common
  -- partner in the cast log (313 + 313 two-grams).  §0.5.1 calls it a bucket-2
  -- spender: it CONSUMES a Demonic Core proc (that's the press decision) and
  -- happens to refund 2 shards.  So `spends = "core"` decides the pole, and
  -- `generates = 2` is what drives the overcap guard.
  [S.DEMONBOLT] = {
    group = "core", kind = "button", spends = "core", generates = 2,
    cadence = "reactive", label = "Demonbolt",
  },
  [S.SHADOW_BOLT] = {
    group = "core", kind = "button", generates = 1, cadence = "filler",
    -- B7: what the player LOSES if this isn't in the tracked set.  Named
    -- specifically because this exact gap hid the SB -> Infernal Bolt blind spot
    -- for four milestones, and because Shadow Bolt is added by hand — the
    -- knowingly-accepted risk is silent degradation if the setting is ever lost.
    lost = "SB -> Infernal Bolt cannot light, and the filler has no dot",
    label = "Shadow Bolt",
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
  [433891] = { group = "core", kind = "button", spends = "art", generates = 3,
               cadence = "reactive", expect = false, label = "Infernal Bolt (alt ID, unconfirmed)" },
  [434506] = { group = "core", kind = "button", spends = "art", generates = 3,
               cadence = "reactive", expect = false, label = "Infernal Bolt" },  -- CONFIRMED live
  [434635] = { group = "core", kind = "button", spends = "art",
               cadence = "reactive", expect = false, label = "Ruination" },      -- CONFIRMED live
  [434636] = { group = "core", kind = "button", spends = "art",
               cadence = "reactive", expect = false, label = "Ruination (alt ID, unconfirmed)" },

  -- ── Essential: the fel explosion (§3 "aoe" / lime) ────────────────────────
  -- THE judgeable=false case.  Implosion's real gate is Wild Imps >= 6.  The
  -- count is displayed by Blizzard and is a Secret Value to us (§0.5.5), so we
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
    label = "Implosion",
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
  -- THE DEFECT THAT MOTIVATED M3c-b.  Devour Magic is a pet purge that OVERRIDES
  -- the Grimoire button, and because M3c-a scored the base spell unconditionally
  -- the HUD advertised "Grimoire: Fel Ravager - up - use on cooldown - waiting
  -- 18s" on a button that was a purge.  Mapped so the live identity resolves to
  -- something real: a utility, i.e. "your call", i.e. never a lit dot.
  -- `expect = false` — it only ever appears as an override.
  [388215]  = { group = "cc",  kind = "button", cadence = "utility", expect = false,
                label = "Devour Magic" },
  [1271802] = { group = "cc",  kind = "button", cadence = "utility", label = "Blight of Tongues" },
  [48020]   = { group = "mob", kind = "button", cadence = "utility", label = "Demonic Circle: Teleport" },

  -- ── Buff viewers.  kind = "aura": these are INPUTS to the score, never
  --    scored themselves, and they carry no dot. ─────────────────────────────
  [S.DEMONIC_CORE]    = { group = "proc",   kind = "aura", label = "Demonic Core" },
  [S.DIABOLIC_RITUAL] = { group = "proc",   kind = "aura", label = "Diabolic Ritual" },
  [S.WILD_IMP]        = { group = "summon", kind = "aura", label = "Wild Imp" },
  [S.DOMINION]        = { group = "core",   kind = "aura", label = "Dominion of Argus" },
}

-- Proc routing (M3b, §0.5.8.3 #2/#3) -------------------------------------------
--
-- source buff spellID -> which BUTTON lights up.  The mapping lives here, in the
-- per-spec table, so HudState stays spec-agnostic: it observes presence edges and
-- asks this table where to put the glow.  M3c-a adds a second consumer —
-- HudScore reads the same table to decide `procArmed`, so the glow and the dot
-- can never disagree about what's armed.
--
--   target      — base spellID of the icon to glow (nil = "wherever the spell
--                 override lands", resolved live from
--                 COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED)
--   softenAbove — shard count at or above which the glow SOFTENS instead of
--                 clearing (§0.5.8.4): Demonbolt refunds +2, so from 4 shards it
--                 overcaps and the cap cue outranks the Core glow.  The proc is
--                 still real, so we dim it rather than lie about it.  HudScore's
--                 overcap guard is the same rule expressed as a level.
--   transform   — this proc arms a spell OVERRIDE; the override event is the
--                 primary trigger and this presence edge only corroborates.
ns.SpecProcGlow = {
  [S.DEMONIC_CORE] = {
    target = S.DEMONBOLT, group = "proc", softenAbove = 4,
    label = "Demonic Core -> Demonbolt", why = "core up",
  },
  [S.DIABOLIC_RITUAL] = {
    -- v1 blind spot: only the HoG -> Ruination half is glowable.  Shadow Bolt is
    -- NOT in the tracked set (notes.md §2), so SB -> Infernal Bolt has no icon to
    -- light — flagged in guidance-model.md §0.5.5, never faked.
    target = S.HAND_OF_GULDAN, group = "summon", transform = true,
    label = "Diabolic Ritual -> transformed button (HoG half only)",
    why = "art armed",
  },
}

-- Stack-count emphasis (M3, §0.5.8.3 #17) --------------------------------------
--
-- Which tracked auras get their (unreadable) stack count enlarged, and what
-- static gate is printed beside it.  The number stays Blizzard's — we cannot
-- read it — so this surfaces the ONE AoE decision without pretending to make it.
--
-- The two constants are DIFFERENT and must never be crossed (notes.md §1):
-- Wild Imps gate Implosion at >=6; Demonic Core caps at 4.
ns.SpecStacks = {
  [S.WILD_IMP] = { suffix = "/6", label = "Wild Imp -> Implosion gate" },
}

-- The pre-pull opener (M3, §0.5.8.3 #8) ----------------------------------------
--
-- Consumed by HudOpener via the reusable HudQueue widget.  ONE opener — the
-- "Tyrant-first burst", verified against the live #1 parse (Inphected, WCL
-- bracket 291, 2026-07-21): Dreadstalkers + Imp Lord pre-stage, Tyrant at t~3.4s,
-- HoG HoG, Implosion, then rebuild.  Matches diabolist-sequences.md SEQUENCE 1a.
-- (There is deliberately NO alternate/variant machinery here — if the opener ever
-- needs to change, we revise this one table.  The old "1a"/"1b" split was a
-- speculative contingency WCL structurally can't show and was never authored.)
--
-- The `preamble` casts (pre-pull HoG, then DB/SB to seed a Core) happen BEFORE we
-- are listening and cannot be cast-verified — they are SHOWN as setup, never
-- advance-tracked.  `alt` lets one step match either of two abilities (the first
-- in-combat spend is Demonbolt if a Core seeded, else Shadow Bolt).  `optional`
-- steps (Imp Lord "if up", Implosion "AoE only") drop without stalling the queue.
-- `prereqs` (M4) — the pre-pull WALL-DOWN state the sequence pane shows above the
-- strip, each lit when met.  `spell` prereqs check readiness (ready edge, or the
-- napkin within `lead` seconds); `shards` checks the live count.  For the opener
-- these are the hard pre-pull conditions, so `lead` defaults to 0 (ready NOW).
ns.SpecOpener = {
  header   = "OPENER",
  preamble = "pre-stack: HoG -> DB/SB (seed a Core)",
  prereqs = {
    { spell = S.TYRANT,        label = "Tyrant" },
    { spell = S.DREADSTALKERS, label = "Dreadstalkers" },
    { shards = 5,              label = "5 shards" },
  },
  steps = {
    { spell = S.DREADSTALKERS,             label = "Dreadstalkers" },
    { spell = 136726,                      label = "Imp Lord", optional = true, note = "if up" },
    { spell = S.TYRANT,                    label = "Tyrant", note = "t~3s" },
    { spell = S.SHADOW_BOLT, alt = S.DEMONBOLT, label = "SB / DB" },
    { spell = S.HAND_OF_GULDAN,            label = "HoG", count = 2 },
    { spell = S.IMPLOSION,                 label = "Implosion", optional = true, note = "AoE" },
    { spell = S.SHADOW_BOLT,               label = "SB", count = 3, note = "rebuild" },
  },
}

-- The BURST window (M4) — consumed by HudBurst, arming the SAME sequence pane when
-- HudState.Mode flips BURST (a Tyrant window opening mid-fight).  The burn order
-- for the window: Tyrant, dump shards into HoG, spend banked Cores, Implosion on
-- AoE.  `prereqs` use `lead = 5` (= HudState HOLD_LEAD) so "Tyrant" lights while
-- it is still coming up, matching when the window actually opens.
ns.SpecBurst = {
  header   = "BURST",
  preamble = "Tyrant window — dump into demons",
  prereqs = {
    { spell = S.TYRANT, label = "Tyrant", lead = 5 },
    { shards = 5,       label = "5 shards" },
  },
  steps = {
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
function ns.SpecInfo(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return NEUTRAL, false end
  local e = ns.Spec[spellID]
  if e then return e, true end
  return NEUTRAL, false
end

-- r, g, b for a spellID's group hue.
function ns.SpecColor(spellID)
  local info = ns.SpecInfo(spellID)
  local c = ns.SpecGroups[info.group] or ns.SpecGroups.neutral
  return c[1], c[2], c[3]
end

-- Which BATCH TINT pole an ability sits at (§0.5.8.4).  One classifier, read by
-- both HudChrome (the accent) and the row, so the two can never disagree.
--
-- Order matters and encodes C2: `spends` is checked BEFORE `generates`, so
-- Demonbolt (spends a Core, refunds 2 shards) lands at the CONSUMER pole beside
-- Hand of Gul'dan rather than opposite it.
function ns.SpecPole(info)
  if info.kind == "aura" then return "proc" end
  if info.cadence == "utility" then return "utility" end
  if info.cadence == "oncd" or info.spends then return "consumer" end
  if info.generates then return "generator" end
  return "consumer"
end

-- Deterministic shard yield of an in-flight cast (anticipation layer / overcap).
function ns.SpecGhost(spellID)
  return (ns.SpecInfo(spellID).generates) or 0
end
