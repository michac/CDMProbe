# CDMProbe — addon repo (michac/CDMProbe)

A **standalone GitHub repo** for the CDMProbe WoW addon, checked out **inside**
the `wwt-keyboard` workspace at `projects/cooldown-hud/addon/` but with its
**own git root** (`michac/CDMProbe`). The parent workspace **gitignores this
folder** (`/projects/cooldown-hud/addon/`) so the workspace never sees it as an
embedded repo — exactly how `planner-state/` (michac/wow-planner-state) and
`projects/keybinder/addon/` (michac/BucketBinds) are handled.

Don't confuse this checkout with the **installed** copy under
`…/_retail_/Interface/AddOns/CDMProbe/`. This is the **source of truth**; the
installed copy is what `ghaddons` deploys.

## What the addon is (and isn't)

An **experiment / kitchen sink**, not a finished product. It probes what a
custom addon can actually do on top of Blizzard's built-in **Cooldown Manager**
(a.k.a. Cooldown Viewer) under Midnight 12.0's **Secret Values** restrictions,
so we can *see at a target dummy* what updates, what's readable, and how the skin
looks. It now also carries **the real HUD** (`/cdmp hud`) — the **W4 pipeline**
`State -> Coach -> Binder -> Renderer` (see `docs/architecture.md`). The v1 direction
is a **terminal / CRT-flavoured overlay that leaves Blizzard's icons native and
untouched** and builds all value-add in the chrome around them.

Retired directions, code **deleted** (recover from git history if revived):
- **The old HUD engine** — HudCore/HudState/HudScore/HudBoard/HudChrome + the
  opener/burst/pane/queue/float widgets and the HudLog pull recorder — **deleted at
  the W4 cutover (2026-07-28)** once the pipeline (`/cdmp hud`) replaced it. `/cdmp hud`
  is now the pipeline.
- Green-phosphor icon-tint era (`/cdmp crt`, `HudTint.lua`) + the "no-icons, solid
  color block" experiments (`/cdmp skin`, `/cdmp resource`; `Skin.lua` + `Resource.lua`) —
  **deleted in W4a (2026-07-24)**.

Registered specs: **Demonology** (266, play-settled), **Destruction** (267, shipped
2026-07-29, flown 2026-07-30), **Retribution Paladin** (70, shipped 2026-08-02, cannot be
flown — no max-level Paladin) and **Havoc Demon Hunter** (577, shipped 2026-08-03, **flown
twice**: the first pass FAILED — `UnitPower(player, Fury)` is a SECRET value, so every Fury
gate compared against a fabricated zero — and the Phase-1 remediation then **flew clean**
(Chaos Strike + Annihilation the top winner at 35.4 %, `PW:restricted` throughout). A third
flight is owed for v0.32.95's charge-cap gate, amp window and look-ahead, and it remains the
in-game gate for the rest of the rollout). Every other spec resolves
passive by design.

Design context + status live in the parent workspace at
`projects/cooldown-hud/docs/` (`spec.md` vision · `notes.md` technical findings ·
`milestones.md` roadmap) — not this repo.

## Commands (`/cdmp <cmd>`, alias `/cdmprobe`)

> **The `probe` command was retired 2026-07-29.** It was a rule-*discovery* instrument
> (secret-value / cooldown-readability / cast-phase / override probing) from the period
> when those rules were open questions. They are now settled game-wide invariants
> (`GetSpellCooldown` secret in combat; cast START/SUCCEEDED readable; `item:IsActive()`
> readable; the override channel works), and a spec's tracked set comes from wago DB2 via
> `wowkb.spec_inventory` — so per-spec re-measurement bought nothing, and the on-disk
> `reports`/`probe`/`probe-baseline.json` machinery + `wowkb.cdmp check|show|diff` went
> with it. The **decision log** (below) is the addon's only recorder now. Recover the probe
> from git history if a genuinely new observation is ever needed (add a targeted command
> then — don't resurrect the whole kitchen sink).

- `hud` — **the real HUD — the W4 pipeline.** Each ~10 Hz tick runs
  `State.Build -> Coach:Compute -> Binder:Bind(guidance, layout) -> Renderer:Draw`
  (see `docs/architecture.md`): State folds the CDM rows into a base-spellID domain
  view, the Coach ranks a single-top-press winner (+ a runner-up + per-ability
  anticipation), the Binder resolves each spellID cue to a display icon via the live
  Layout, and the Renderer draws OUR OWN textures anchored to Blizzard's icons —
  which stay **native and untouched**. Toggling off clears every dot, leaving
  Blizzard's UI pixel-clean. Auto-enables on login if it was on. (Reclaimed `/cdmp hud`
  at the W4 cutover.)
  - `hud on` / `hud off` — set it explicitly (bare `hud` toggles).
  - `hud sound on|off` — the **cue sound**: one play per *change of the cue set*, on
    channel **Master** (it answers only to master volume — a rotation cue must not vanish
    because effects were turned down to hear the boss). Defaults **on**
    (`ns.db.hudSound`). ⚠ A swap is **one** event, not a remove plus an add — 60 % of real
    set changes are swaps, so firing per handle would double the common case. Measured
    rate: ~120 plays / 504 s of play, one every ~4 s, tracking your casts.
  - `hud status` — the pipeline readout: ON/OFF, State ingestion consumer count, and
    the last tick's cue count / any tick error. The decision trace is in
    `CDMProbeDB.decisionlog` (extract with `wowkb.cdmp decisionlog`).
  - `hud layout` — dump the live Layout (icon viewers -> cooldownID -> spellID +
    the State-resolved keybind) — the row to read when a cue's key is missing.
  - `hud coverage` — the **roster coverage** table (Phase 4, `Coverage.lua`): every id the
    spec DECLARES vs what the CDM actually tracks, blind rows first. The summary line rides
    `hud status`. ⚠ Alert types read **"reported eligible"**, never "cannot fire" —
    `GetValidAlertTypes` under-reports.
- `flight` — **ARM THE ACCEPTANCE RECORDER — the one command an in-game pass needs.**
  Turns the HUD on and records every *change of answer* (coverage, assist classes,
  aura-frame capability, keybind stats, layout, cue/key counts) through combat entry, spec
  swaps and hero swaps, **with no further typing**. Then `/reload` and run
  `uv run python -m wowkb.cdmp flight` for a **PASS / FAIL / MEASURED** report judged
  against criteria that live in code. `flight off` stops it, `flight status` shows progress.
  ⚠ Arming **wipes the ring** — a flight is one session. Replaces what used to be a
  ten-command checklist typed partly during a GCD.
- `assist` — ⚠ **TEMPORARY** probe of `C_AssistedCombat` (`Assist.lua`): does
  `GetNextCastSpell()` return a **readable** spellID in combat? Bare = a one-shot readout of
  readability CLASSES (never raw values); `assist watch` arms a 1 Hz class-change sampler
  (off by default) into `CDMProbeDB.assist`, `off` stops it, `dump` reads the ring, `clear`
  wipes it. Delete the file, its `.toc` line and the saved-vars once the answer lands in
  `knowledge/addon-dev/api-events-and-discovery.md` §2.
- `single` / `multi` / `aoe` — the target-mode toggle (`Mode.lua`): idempotent
  macro-friendly setters + a bare toggle. Forwarded by State as its `mode` field;
  the Coach reads it but does not branch yet (scaffolding for a 2nd spec / AoE rule).
- `panel` — move OUR OWN icon row (`HudVirtual.lua`): `unlock` | `lock` | `reset`, bare
  toggles. Unlocked = mouse on + a terminal-green edge/caption + icons held lit so you can
  see what you drag; locked = only the icon, and the frame eats no clicks. The position
  saves to `CDMProbeDB.virtualPanel` on drop. Refuses to CREATE the panel in combat (frame
  discipline) — an already-created one unlocks fine.
- `rt` — render test: draw a hand-authored DrawList fixture (`RenderTest.lua`). `states`
  (default) is the reference card — every cue state in a row, captioned, over real spell
  art; `list` names the rest, `rotate` hops one cue across 5 panels, `off` clears.
  (The `inventory` and `burst-hold` fixtures were deleted 2026-07-30 with the retired
  JUDGE/SEQUENCE tokens — `states` had already superseded `inventory`.)
  ⚠ It exercises `R:Draw` ONLY — the proc-glow squares are applied post-Draw by the test
  rig, and `HudVirtual`'s own panel is not in it at all.
  ⚠ **THE `rt fx` DIALLING RIG AND THE `rt lab` RENDER LAB ARE BOTH ARCHIVED** (2026-08-02,
    `CDMProbe/archive/`). `rt fx` dialled the **v1** cue treatment and reaches into
    `cueGlows` / `cueEchoes` / `cueLayers.pop`, none of which the v2 cue has. `rt lab` was
    the experiment that replaced v1 and is spent. Read
    `archive/RenderTest-fx-v1.lua` and `archive/cue-treatment-v1.lua` before building any
    successor — between them they carry the two rules that cost the most to learn: a rig
    claiming to be a faithful A/B baseline must be **asserted** against the shipped path
    (the `rt fx` alpha bug showed a ring at >2× shipped brightness for six builds), and a
    winning effect gets **promoted into the Renderer properly**, never shipped from a rig.
- `reset` — turn the HUD off.

*(The `skin` / `resource` solid-colour-block directions were deleted in W4a
(2026-07-24); the old HUD engine + its `hud log`/`hud opener`/`hud binds`/`hud debug`/
`hud rows` subcommands + `single/multi/aoe`'s old home were retired at the W4 cutover
(2026-07-28). Recover from git history if revived.)*

## File layout

```
projects/cooldown-hud/addon/      <- THIS repo root (michac/CDMProbe)
  CLAUDE.md                       this file
  README.md
  LICENSE                         MIT
  .gitignore
  .luacheckrc                     luacheck config (WoW-globals std) — M4.5 T1
  CDMProbe/                       <- the addon folder ghaddons installs
    CDMProbe.toc
    Core.lua                      namespace, saved vars, slash cmds, registry
    Util.lua                      color, spell-name, Secret-Values-aware describe, and the
                                  GUARDED-READ LADDER every game read goes through:
                                  ns.ReadCooldown / ReadCharges / ReadGCD /
                                  ns.ReadValidAlertTypes (promoted out of AlertTape.lua in
                                  Phase 3 — ⚠ that API UNDER-REPORTS, so a consumer says
                                  "not reported eligible", never "cannot fire") +
                                  ns.AlertEventName (the alert-enum value->name map,
                                  promoted out of AlertTape.lua in Phase 4 for the same
                                  reason)
    Viewers.lua                   locate viewers, enumerate items, and resolve each item's
                                  IDENTITY: ns.GetViewer / ns.GetItemFrames /
                                  ns.ItemCooldownID / ns.ItemBaseSpellID /
                                  ns.ItemDisplaySpellID / ns.DisplayIdentity (read by
                                  HudLayout + State). DisplayIdentity moved here from
                                  Util.lua on 2026-07-30: it reads ns.SpecInfo, so the
                                  bottom-of-stack utility file was depending on the spec
                                  registry six files later. ⚠ ItemCooldownID is the
                                  pipeline's BINDING KEY — it was deleted with HudCore at
                                  the W4 cutover and its nil-guarded call sites turned that
                                  into a silent total HUD outage (fixed v0.32.25). Do not
                                  reintroduce `ns.X and ns.X(...)` guards on our own symbols.
    AlertTape.lua                 ⚠ TEMPORARY discovery instrument, MEANT TO BE DELETED.
                                  Records every CooldownViewerItemMixin:TriggerAlertEvent
                                  (all six alert types) + a three-way readability probe of
                                  the pandemic fields, to answer whether PandemicTime /
                                  ChargeGained / OnAura* fire in combat and whether
                                  pandemicStartTime/EndTime survive Secret Values.
                                  `/cdmp alerts on|off|probe|dump|clear`, off by default;
                                  extracted by `wowkb.cdmp alerttape`. Delete this file,
                                  its .toc line and the `alerttape` saved-var once those
                                  rules land in knowledge/addon-dev/
                                  api-events-and-discovery.md §2.8.
                                  ⏳ Those rules HAVE landed (§2.8 is confirmed in-client),
                                  and the pipeline now consumes all six types — but the tape
                                  is the instrument that CONFIRMS the field-fix C/C2 latches
                                  against their source events, so it survives until that
                                  in-game pass is done. Delete it straight after.
                                  ⚠ Its `GetValidAlertTypes` read was PROMOTED out to
                                  `ns.ReadValidAlertTypes` (Util.lua) in Phase 3, because
                                  Phase 4's roster coverage probe is built on it and must
                                  not die with this file. Only the capture bookkeeping +
                                  formatting stayed here.
    -- (Census.lua — the temporary CDM STRUCT CENSUS, `/cdmp census` — was DELETED in
    -- Phase 3 (2026-07-31) along with its .toc line, its `census` saved-var, its spec and
    -- `wowkb.cdmp census`. It did its job: the 2026-07-31 capture answered all six
    -- roster-state-plan Phase-2 questions and Phase 2 consumed the answers. Recover from
    -- git history if a genuinely new struct question ever needs the same instrument.)
    Assist.lua                    ⚠ TEMPORARY discovery instrument, MEANT TO BE DELETED —
                                  the AlertTape mould, and NOT in the pipeline (nothing
                                  reads it). One question: does
                                  `C_AssistedCombat.GetNextCastSpell()` return a READABLE
                                  spellID in COMBAT? If it does, Blizzard hands us a
                                  ground-truth "what to press next" through a channel that
                                  survives Secret Values — an independent oracle to diff the
                                  Coach against (never a replacement: it is generic
                                  single-target with no mode/AoE awareness and no burst
                                  planning). `GetRotationSpells()` rides along as a second
                                  opinion on ROSTER COMPLETENESS. `/cdmp assist [watch|off|
                                  dump|clear]`; the watch ring dedups by READABILITY CLASS,
                                  because a value change is noise and a class change is the
                                  answer. Delete this file, its .toc line and the
                                  `assist`/`assist_on` saved-vars once the answer lands in
                                  knowledge/addon-dev/api-events-and-discovery.md §2.
    Flight.lua                    THE ACCEPTANCE RECORDER (`/cdmp flight`). Every phase
                                  of this project ends with an in-game pass, and the pass
                                  kept being written down as a CHECKLIST OF SLASH COMMANDS —
                                  which asks the player to type during a GCD and makes the
                                  acceptance criteria something a human eyeballs in a chat
                                  dump. The decision log already solved this shape: record
                                  structurally, extract on the desktop. This is that,
                                  applied to the whole pass. 1 Hz ticker recording only on a
                                  change of ANSWER SHAPE (the AlertTape/Assist dedup idiom),
                                  with combat entry/exit + spec + talent swaps forcing an
                                  immediate sample so the interesting transitions are never
                                  up to a second late. ⚠ IT MUST NOT PERTURB WHAT IT
                                  MEASURES: it calls the SHIPPING ns.Coverage.Get() and
                                  ns.Assist.Probe(), never a private copy — a copy could
                                  pass while the shipped path fails, which is the whole
                                  failure mode it exists to catch. Read by
                                  `wowkb.cdmp flight`.
    Mode.lua                      the single/AoE target-mode toggle (`ns.Mode.aoe`
                                  + `single`/`multi`/`aoe`); State forwards it, the
                                  Coach reads it (extracted from HudCore at the cutover)
    SpecRegistry.lua              the multi-spec seam: ns.Specs registry +
                                  ns.RegisterSpec / ns.SetActiveSpec, and
                                  ns.ResolveActiveSpec — reads GetSpecialization/
                                  GetSpecializationInfo on login + PLAYER_SPECIALIZATION_
                                  CHANGED, activates the registered spec or goes passive
                                  (ns.ActiveSpec=nil). Re-binds the legacy ns.Spec* globals
                                  off the active spec so existing call sites are untouched.
    SpecDemonology.lua            per-spec DATA for Demonology (266): the SIGNAL BUCKET
                                  per spellID (group / kind / spends / generates / cadence /
                                  burstAlign / goGate / primary / judgeable / abbr).
                                  SELF-REGISTERS a spec object via ns.RegisterSpec(266,…);
                                  activation is ns.ResolveActiveSpec's job (no static
                                  SetActiveSpec). The seam a 2nd spec plugs into; other
                                  modules hold no spell constants of their own.
    SpecDestruction.lua           per-spec DATA for Destruction (267) — the 2nd registered
                                  spec, and the proof the seam works (added with NO pipeline
                                  edit). Same signal bucket, minus the nine DORMANT Tier-3
                                  tables Demo carries (SpecGroups/SpecOpener/SpecBurst/…
                                  have no live consumer in v1, so this file omits them).
                                  Same SoulShards power rendered `discrete`, so Destruction
                                  touches NEITHER Renderer generalization point.
                                  ⚠ SpecPowerDelta projects BUILDERS AND SPENDERS since
                                  Phase 6.2 (2026-08-01), in FRAGMENTS (0-50, the game's
                                  internal Soul Shard unit). The old "spenders only" fence
                                  existed because State could read whole shards only; it
                                  reads the exact rail now, so `generatesFrags` carries real
                                  integer yields (Incinerate 2, Conflagrate 5, Soul Fire 10,
                                  Infernal Bolt 20) — BASE values, never crit bonuses, since
                                  over-crediting promises a cast you cannot make. Diabolic
                                  Embers (387173) is the one conditional, read via
                                  C_SpellBook.IsSpellKnown and cached through the registry's
                                  `Invalidate` seam (the first spec to use it). ⚠ ns.ShardCost
                                  returns WHOLE SHARDS (the client pre-applies the divisor),
                                  so the cost is multiplied UP here — one unit boundary.
    SpecRetribution.lua           per-spec DATA for Retribution Paladin (70) — the 3rd
                                  registered spec and the FIRST OUTSIDE WARLOCK, so the one
                                  that proves the seam is class-agnostic rather than merely
                                  spec-agnostic. ⚠ Its resource is declared
                                  `display = "none"`: Holy Power rides the whole rail
                                  (ctx.powers -> resourceBars[] -> the decision log's `PW:`
                                  column) and the Renderer draws NOTHING for it. That is not
                                  the same as declaring no powers — an empty spec.powers
                                  emits no bar at all and PW: renders `?/?`, losing the one
                                  instrument that can explain a decision nobody watched.
                                  ⚠ FOUR of its rotation abilities have NO ICON OF THEIR OWN:
                                  Hammer of Light, Final Verdict, Templar Strike and Templar
                                  Slash all arrive as spell OVERRIDES riding a tracked frame
                                  — the same channel Demonology's Ruination uses, and the
                                  reason Templar is the v1 profile (it is readable in
                                  restricted combat). Hammer of Light 427453 was
                                  DISCRIMINATED, not picked: SpellName carries eight
                                  "Hammer of Light" rows and exactly one costs Holy Power.
                                  ⚠ FOUR of the nine Essential buttons (Judgment, Crusader
                                  Strike, Blade of Justice, Wake of Ashes) have
                                  SpellCooldowns.RecoveryTime = 0 and keep their cooldown on
                                  a CHARGE CATEGORY, so ns.BaseCooldown reads 0 and the
                                  napkin has nothing to count down from. ⚠ This said SIX
                                  until 2026-08-03 — Avenging Wrath keeps its cooldown on the
                                  spell row, and the two spenders read 0 because they have NO
                                  cooldown, which is a different condition. Readiness is NOT
                                  what is lost (it comes from the charge count); SOON and
                                  Escalate's overdue call are. `chargeCD` documents the real
                                  recovery numbers and HudNapkin.lua:113-119 now READS it,
                                  filed source = "declared".
    CoachRetribution.lua          the Retribution BRAIN: Context / RankWinner / Escalate on
                                  spec 70's object, implementing specs/retribution/
                                  rotation.md L1-L12. Structurally Destruction, not Demo: no
                                  burst SETUP block (nothing is held for Avenging Wrath) and
                                  no window suppression in Escalate. Its own shape: the
                                  SPENDER sits on three lines (L1 as Hammer of Light, L4 the
                                  anti-overcap dump, L8 the main dump) all keyed on one base
                                  spellID, so one exclusion drops every occurrence; L4
                                  deliberately YIELDS to a ready Wake of Ashes, because WoA
                                  ARMS Hammer of Light and that is worth more than the
                                  overcap. ⚠ NO fragment arithmetic — Holy Power's modifier
                                  is 1, so display units ARE exact units and copying
                                  Destruction's `cost * FRAGS_PER_SHARD` would be a silent
                                  10x error. `RET_HOL_FROM_BUFF` is the one unsettled read,
                                  defaulted OFF (the ART_FROM_RITUAL precedent).
                                  Greened against coach_retribution_apl_spec (68 cases).
    SpecHavoc.lua                 per-spec DATA for Havoc Demon Hunter (577) — the 4th
                                  registered spec and the 2nd class outside Warlock.  Fury is
                                  0-120 with MODIFIER 1, so the exact rail and the display
                                  rail are the SAME integer: do NOT copy Destruction's
                                  `cost * FRAGS_PER_SHARD` or the `*Frags` naming, which
                                  would be a silent no-op teaching the next reader the wrong
                                  lesson.  Declared `display = "none"` for Retribution's
                                  reason (the rail reaches DecisionLog's `PW:` column; the
                                  Renderer draws nothing).
                                  ⚠ NO `spec.derived` BLOCK, AND THAT IS A DECISION.  The
                                  Phase-0.3 class-resource channel exists for DH Soul
                                  Fragments, so a DH spec is exactly where a reader expects
                                  one — Havoc does not have that resource (simc references
                                  `soul_fragments` ONCE vs Vengeance's 32; the castCount
                                  reader is Soul Cleave, a VENGEANCE spell; Blizzard's own
                                  DemonHunterSoulFragmentsBar.lua:18 is DEVOURER-ONLY).
                                  ⚠⚠ THREE ESSENTIAL BUTTONS REPORT A BASE COOLDOWN THAT IS
                                  **WRONG**, not merely absent — Fel Rush 195072 reads 1 s
                                  against a real 10 s, Immolation Aura 258920 reads 2 s
                                  against 30 s, Vengeful Retreat 198793 reads 0.5 s against
                                  25 s (a short SHARED-CATEGORY lockout sits on the spell row
                                  while the real recovery lives on a charge category).  A LIE
                                  defeats the mitigation an honest zero gets: HudNapkin's
                                  declared-`chargeCD` fallback is gated on `not (len > 0)`,
                                  which an honest 0 trips and a lying 1 does not.  What saves
                                  it — and it was not built for this — is that all three are
                                  ONE-charge categories, so usable()'s one-charge rule
                                  (`cur >= 1 AND probablyUp`) makes the count veto the early
                                  read for the whole real duration.  THE PRESS IS PROTECTED;
                                  ONLY THE DECORATION LIES.  Do NOT pre-emptively widen the
                                  napkin — specs/havoc/rotation.md records the exact one-line
                                  fix if the flight shows it biting.
                                  ⚠ THREE ROTATIONAL PRESSES ARE FILED CDM-**UTILITY**
                                  (Felblade 232893, Vengeful Retreat 198793, Fel Rush 195072
                                  — which has TWO rows, one Essential one Utility) and it
                                  needed NO pipeline edit: both fences that could block them
                                  (Coach.lua:501, State.lua:1941) test the SPEC-AUTHORED
                                  `cadence`, not the CDM category.  The next TANK spec will
                                  meet the same shape.
                                  ⚠ SpecBindAlias is LOAD-BEARING here: SkillLine 1848
                                  teaches WRAPPER spells (Chaos Strike 344862 -> tracked
                                  162794; Fel Rush 344865 -> tracked 195072), so without the
                                  aliases both silently lose their keybind hint.
                                  ⚠ Rain from Above 206803 is a KNOWINGLY DEAD ICON — a
                                  tracked Essential with a real 90 s cooldown that appears
                                  NOWHERE in the 140-line APL.  Registered so the log can
                                  name it and Coverage does not report it blind;
                                  `cadence = "utility"` keeps SOON off a button we never cue.
                                  Every override was DISCRIMINATED by `SpellEffect.EffectAura
                                  == 332` plus a corroborating cost/category, NEVER by name —
                                  SpellName carries 76 rows called "Annihilation".
    CoachHavoc.lua                the Havoc BRAIN: Context / RankWinner / Escalate on spec
                                  577's object, implementing specs/havoc/rotation.md L1-L15.
                                  ⚠ THE META FORK IS ONE CASCADE, NOT TWO LISTS.  simc ends
                                  its top-level list with `run_action_list,name=meta` — a hard
                                  fork into a second complete priority list that never returns
                                  — but demon form is a DISPLAY OVERRIDE on frames the list
                                  already presses (Metamorphosis 162264 carries two
                                  `EffectAura 332` effects: Annihilation 201427, Death Sweep
                                  210152), so the Coach cues the BASE spellID and the icon
                                  shows the right art.  A second list would be fifteen
                                  duplicated lines differing only in a label the pipeline
                                  supplies for free.  What the fork genuinely changes is
                                  ORDER, in exactly TWO places — L6 (Essence Break is
                                  meta-only) and L7-vs-L10 (Blade Dance outranks Eye Beam in
                                  meta) — and only those two lines read `ctx.inMeta`.  That is
                                  read from TWO ORed sources (the Metamorphosis TrackedBuff
                                  row 191427, and either override visibly live on its base
                                  frame), published separately as well as ORed so the decision
                                  log can say WHICH one forked the list.
                                  ⚠ THE ESSENCE BREAK WINDOW COMES FROM CAST HISTORY, not an
                                  aura: debuff 320338 has no CooldownSetSpell row, but its
                                  SpellDuration is a flat 4000 ms and ns.Coach.CommittedWithin
                                  answers off a channel that survives combat.  Known bias (it
                                  cannot see a window ended early), and it fails toward a
                                  REORDERING rather than a wasted press — which is why this
                                  channel and not a napkin-derived aura.
                                  ⚠ L5 IS THE FIRST CROSS-ABILITY TIMING GATE IN ANY BRAIN —
                                  Vengeful Retreat reads EYE BEAM's napkin `remaining`.
                                  Licensed because Eye Beam's 30 s lives on the SPELL row so
                                  the napkin counts it honestly; Retribution DROPPED its
                                  equivalent handshake because Wake of Ashes is
                                  charge-category and has no napkin.  The rule: a
                                  cross-ability timing gate is allowed when the OTHER
                                  ability's cooldown is one the napkin can honestly count.
                                  FIRST SUSPECT if VR misbehaves in play.
                                  `HAVOC_RG_FROM_BUFF` is the one unsettled read, defaulted
                                  OFF (the RET_HOL_FROM_BUFF shape verbatim — Art of the
                                  Glaive is an 80-stack counter whose presence would jam L1).
                                  ⚠ The Reaver's Glaive SPEND SEQUENCE is deliberately NOT a
                                  parked switch: Rending Strike 442442, Glaive Flurry 442435
                                  and buff.reavers_glaive 442294 have NO CooldownSetSpell row
                                  in set 1599, so six APL lines are dark and no switch could
                                  ever flip on.  A parked switch waits on a question a FLIGHT
                                  can settle; this one already has an answer.
                                  Greened against coach_havoc_apl_spec (100 cases).
    -- The W4 pipeline (State -> Coach -> Binder -> Renderer), driven each tick by
    -- HudDriver.  See docs/architecture.md.
    State.lua                     ingestion + State.Build: the ROSTER-ANCHORED domain view
                                  (abilities/buffs/power), keyed by base spellID;
                                  Secret-Value-guarded, napkin + edge fused for honest
                                  readiness. The pipeline's INPUT.
                                  ⚠ THE ANCHOR INVERTED IN PHASE 5 (2026-08-03,
                                  roster-state-plan §6.3 — READ IT BEFORE EDITING THIS FILE;
                                  eleven decisions there are not in the plan text). Build used
                                  to ENUMERATE the whole CDM database and filter back down to
                                  what is pressable, with the spec table entering only at the
                                  end as the source for virtual rows. Now the spec's declared
                                  ROSTER is the anchor and the CDM is ONE EVIDENCE SOURCE
                                  joined against it. Three pure seams carry it:
                                    St.RosterEntries(specTable) — the roster walk, factored
                                      once and sorted by spellID so a contested claim never
                                      depends on pairs() order. Coverage.lua uses it too.
                                    St.RosterClaims — ranks claims GLOBALLY (identity match >
                                      base match > bare mention; Essential > Utility > tab 2)
                                      and assigns greedily, so ONE ROW IS CLAIMED BY AT MOST
                                      ONE ABILITY. `pulse.cooldowns` stays intact.
                                    St.RosterView — builds the rows off those claims.
                                  ⚠ THE ROOT FIX IS ONE INTENT: `readAbilityFacts(rid, rep)`
                                  passes the ROSTER spellID to BOTH readCd and readCharge, so
                                  an ability's cooldown and its charges are asked about the
                                  SAME id. They used to run two ladders — cooldown on the
                                  DISPLAY identity, charges on `overrideSpellID or spellID` —
                                  and on a row whose identity flips mid-session (Judgment
                                  alternates with Hammer of Wrath in the tracked set) those
                                  resolve to DIFFERENT SPELLS, i.e. one ability's cooldown
                                  compared against another's charges. Three of the five
                                  Retribution flight defects, one cause. Do not re-derive
                                  either fact through a row's identity.
                                  ⚠ UNCLAIMED ROWS COST NO READS — a row no declared ability
                                  claims gets `cd = {state="unknown", source="none"}` /
                                  `charge = {readable=false}` rather than its own read. That
                                  is where the sizing win actually comes from.
                                  ⚠ SYNTHESIS HAS THREE WHOLESALE GUARDS, not one: no frame
                                  map, empty database, and ANY ROW WITH NO RESOLVABLE BASE
                                  (an unreadable row makes every "untracked" negative
                                  unprovable). Without them a refused CDM read puts OUR icon
                                  on screen for the whole rotation — the v0.32.32 duplicate at
                                  roster scale. Guard 3 keys on `baseOfRow(entry, fold) ==
                                  nil`, NOT on "the spellID read secret", so a warm in-combat
                                  pulse keeps drawing.
                                  ⚠ `power` is RAW — value/max/readable per
                                  Enum.PowerType NAME, no `incoming` — PLUS the EXACT rail
                                  (Phase 6.2): `unmodified`/`unmodifiedMax`/`modifier` from
                                  `UnitPower(unit, type, true)`, which returns the game's
                                  internal units (Soul Shards: 0-50 fragments vs a displayed
                                  0-5) and WORKS IN COMBAT. Purely additive, ABSENT never
                                  zero on a refusal, and spec-agnostic by vocabulary
                                  (`unmodified`, not "fragments"). The in-flight
                                  projection lived here until roster-state-plan Phase 6
                                  moved it to ns.Coach.InflightPower; that took the
                                  `ns.SpecPowerDelta` injection, BOTH
                                  `Enum.PowerType.SoulShards` hardwires (State's last
                                  class-specific literals) and its only read of
                                  ns.ActiveSpec out of this file. ⚠ The four terminal
                                  cast events it registers (INTERRUPTED / FAILED /
                                  FAILED_QUIET / STOP) now look ORPHANED from in here —
                                  they push history's `"stopped"` phase, which is what
                                  lets the COACH cancel a mid-flight spender. Do not
                                  drop them or the phase.
                                  ⚠ `abilities` IS NO LONGER FILTERED — it MARKS (Phase 5,
                                  §6.1). Field-fix A used to DELETE an unlearned or undrawable
                                  row, because both read `ready` forever and so won the
                                  priority list (216 dropped Soul Fire cues in one live
                                  session). Anchored on the roster there is one base set and
                                  no safe default, so every declared ability enters `abilities`
                                  carrying THREE-VALUED `known`: true | false | "unknown" |
                                  nil. ⚠ THE THIRD VALUE IS THE STRING, NOT nil — `nil` has to
                                  keep meaning "nobody asked" (every hand-built fixture pulse
                                  carries it). The SPELLBOOK is the authority and the row's
                                  `isKnown` only the fallback, because a row's isKnown
                                  describes its BASE, which on a display-overridden row is a
                                  different spell (Hellcaller cid 66181's base Shadow Bolt is
                                  unlearned while the Incinerate it draws is pressed every
                                  GCD). Coach.Classify makes the decision: false => nil,
                                  "unknown" => the row survives with its readiness flags
                                  zeroed (that IS "available"). `pulse.knownReadable == false`
                                  is the WHOLESALE GUARD and overrides both — not one ability
                                  answered means a broken read, not a bare character.
                                  ⚠ `pulse.dropped` IS DELETED. Its visibility is what made
                                  the Soul Fire bug findable, so the decision log's `DR:` field
                                  was RE-SOURCED off the rows' `known` (and renders `!refused`
                                  when the guard fires) — strictly more than `dropped` carried,
                                  which could only ever name a would-be press. `displayable`
                                  survives on the raw row as a diagnostic.
                                  Consumes ALL SIX alert types now: the two cooldown
                                  edges (readiness), the three aura edges (`dotEdge`, the
                                  pandemic latch) and `ChargeGained` (the charge napkin) —
                                  each promoted on measurement, see knowledge/addon-dev/
                                  api-events-and-discovery.md §2.8. Also owns the ACTIVE
                                  HERO TREE read (C_ClassTalents, cached, wiped on
                                  SPELLS_CHANGED) and puts it on the pulse as
                                  `hero`/`heroSubTreeID` — moved out of CoachDestruction
                                  2026-07-30 so a captured pulse can reproduce a
                                  hero-gated decision.
    Coach.lua                     the generic Coach SHELL: Classify / Emit / ResourceBars
                                  / Sequence + a delegating Compute + EmptyGuidance. Reads
                                  ns.ActiveSpec live each tick; returns EmptyGuidance when
                                  passive. Holds no spec logic — Context/RankWinner/Escalate
                                  live on the active spec object (CoachDemonology.lua).
                                  Also the PUBLIC SHELL KIT both brains read from their
                                  Context: ns.Coach.CommittedWithin and (Phase 6)
                                  ns.Coach.InflightPower — the per-power in-flight
                                  projection, a PURE walk of the pulse's cast history
                                  (latest phase per base inside a 3s window x the spec's
                                  signed ns.SpecPowerDelta, passed IN so it is not a hidden
                                  dependency). ⚠ Its predecessor in State had a
                                  double-deduction guard; that was DROPPED, not ported —
                                  roster-state-plan §7.1 says why, read it before
                                  "restoring" it.
    CoachDemonology.lua           the Demonology BRAIN: attaches Context / RankWinner /
                                  Escalate + tunables to spec 266's object. RankWinner is a
                                  FLAT priority list (apl-prototype/pseudocode.md) — no phase
                                  machine; emits winner + ROTATION_FALLBACK runner-up + dumb
                                  per-ability SOON. Greened against coach_apl_spec (the
                                  Tier-1 branch oracle).
    CoachDestruction.lua          the Destruction BRAIN: Context / RankWinner / Escalate on
                                  spec 267's object, implementing specs/destruction/
                                  rotation.md L1-L13. Structurally unlike Demo: NO burst
                                  setup block (nothing is held for Summon Infernal, so no
                                  tct / stage / go-gate and no window suppression in
                                  Escalate), CHARGE-AWARE readiness (Conflagrate is the
                                  project's ONLY charged tracked ability — Shadowburn has no
                                  charges, DB2 ChargeCategory=0; the exact count is OOC-only,
                                  so in combat it reads State's charge napkin), and a
                                  three-way up/missing/unknown DoT read so an UNREADABLE
                                  Immolate never becomes "refresh it now". That read runs on
                                  THREE CHANNELS in trust order (reordered 2026-07-31,
                                  roster-state-plan §3.10): (1) the PER-FRAME AURA VERDICT,
                                  State's read of `auraDataUnit`/`PandemicIcon` — Blizzard
                                  recomputes both every frame off secrets we cannot read, so
                                  unlike an edge they SELF-CLEAR, which is the only channel
                                  that can ever say "apply it"; (2) the PandemicTime/OnAura*
                                  alert latch, DEMOTED to a fast path — it is a one-shot
                                  notification, not a state (41 Immolate casts raised one
                                  OnAuraApplied, one PandemicTime, zero OnAuraRemoved), and
                                  it remains the whole answer on a row whose frame fields
                                  are absent; (3) the buff-item presence read, OOC fallback
                                  only — on a tab-1 row it no longer exists at all (§3.1),
                                  since `IsActive()` there is a constant `true`, which is
                                  what jammed this read to "up" on both hero trees.
                                  Hero tree now arrives ON THE PULSE (`state.hero`, read by
                                  State); the multi-signal tracked-set inference survives
                                  only as the fallback for a refused API read, and the
                                  announcement moved to HudDriver's one-shot notice. And
                                  ctx.dotID resolves to whichever Immolate/Wither id the
                                  pulse actually carries. `ART_FROM_RITUAL` is the one
                                  unsettled read, defaulted OFF — see the file header.
                                  Greened against coach_destruction_apl_spec.
    Binder.lua                    Binder:Bind(guidance, layout) -> DrawList: resolves
                                  each spellID cue to a display cooldownID/icon. Emits TWO
                                  per-icon channels (Phase 3): `cues[]`, one entry per Coach
                                  DECISION, and `keybinds[]`, one per displayed icon with a
                                  key — built straight off the Layout with NO Coach
                                  involvement, because a keybind is identity chrome. Before
                                  Phase 3 a key hint rode an emphasis-less "empty cue", so a
                                  display concern travelled the decision channel and
                                  `#cues` counted chrome as well as decisions.
    Renderer.lua                  Renderer:Draw(drawList): OUR OWN textures anchored
                                  to Blizzard's icons; semantic tokens -> pixels. PURE:
                                  no decisions, no game reads, no timers. ⚠ `drawCues` and
                                  `drawKeybinds` each RETURN their active handle set and
                                  `Draw` culls the shared `cueHolders` on the UNION — both
                                  channels ride one holder per icon, so a per-channel cull
                                  would hide the other channel's decoration every frame.
                                  ⚠ THE CULL IS TWO TERMS, and only because the flare is
                                  ARRIVAL-ONLY. A third has lived there twice (v1's
                                  `ghosting`, v2's `leaving`): a removed handle leaves both
                                  active sets in the very draw that starts its out-animation,
                                  so a two-term union hides the holder and the animation
                                  plays invisibly. Add a departure animation and the third
                                  term comes back WITH it.
                                  ⚠ THE CUE IS v2 + THE ARRIVAL BURST (2026-08-02):
                                  backing disc + dot + TWO COUNTER-ROTATING RINGS, and a
                                  one-shot FLARE on arrival (`R.BURST` / `R:fireBurst`).
                                  ⚠⚠ IT REPLACED A `Scale` POP THAT SHIPPED TWICE AND WAS
                                  WRONG BOTH TIMES — the pop made the steady rings READ as
                                  spinning far too fast, permanently, from the instant it
                                  played, while `Rotation:GetProgress()` measured perfectly
                                  nominal. `/cdmp rt pop` isolated it one property per
                                  panel and the answer is a rule, not a patch:
                                  **NOTHING THAT IS AN ANCESTOR OF A ROTATING TEXTURE MAY BE
                                  ANIMATED.** The flare's own textures scale and rotate
                                  THEMSELVES; their frame is a plain anchor and a SIBLING of
                                  the rings. Do not "simplify" that by scaling the frame or
                                  the layer — renderer_spec's invariant test is mutation-
                                  checked against exactly that edit. Read the header at
                                  R.BURST before touching any of it.
                                  ⚠ ARRIVAL-ONLY, deliberately: on a swap (60 % of real set
                                  changes) a departure flare drags the eye back to the icon
                                  you should stop looking at.
                                  ⚠ Its numbers were dialled IN PLAY via `/cdmp rt pop
                                  burst <knob> <value>`, which mutates the SHIPPED R.BURST
                                  table rather than a copy.
                                  The KEYBIND FONTSTRING STAYS ON THE HOLDER: identity
                                  chrome must not move when the rotation does. Its ring
                                  numbers are an EXPERIMENTAL RESULT, not a dial-in — two
                                  subagents blind to this repo converged on them and both
                                  ran steady. ⚠ The pair COUNTER-ROTATES at DIFFERENT
                                  periods on purpose; the constraint is the BEAT FREQUENCY
                                  (n-fold art beats at n x the relative angular velocity —
                                  6s vs 9s gives 2.2 Hz, above the band the eye tracks).
                                  RING_SCALE is ART-SPECIFIC — 3.34 belongs to star_07 and
                                  does not transfer; swapping the art and re-dialling BOTH
                                  periods are ONE job.
    archive/                      RETIRED CODE, kept as a record.  NOT in the .toc, never
                                  parsed by the game, and EXCLUDED FROM luacheck on purpose
                                  (linting it would mean editing it, and an edited record is
                                  a worse record).  `cue-treatment-v1.lua` = the v1 cue
                                  (spinning ring + locked-in-phase echo + breathe + pop +
                                  ghost) and the reasoning that produced it — the
                                  art-symmetry retune, the moiré analysis, the light split;
                                  `RenderTest-fx-v1.lua` = the `/cdmp rt fx` dialling rig
                                  that dialled it (the `sound` auditioner in there is
                                  treatment-independent and worth recovering if the cue
                                  sound is ever re-picked); `RenderLab*.lua` = the blind
                                  three-way experiment that replaced it.  ⚠ Reviving
                                  anything means moving it back into CDMProbe/ proper, where
                                  the linter applies again.
    RenderTest.lua                the `/cdmp rt` render-test rig — IMPURE by construction
                                  and deliberately outside the Draw path: placeholder icon
                                  frames, a C_Timer ticker, the hand-authored DrawList
                                  fixtures (ns.RenderTestFixtures, consumed by binder_spec)
                                  and the borrowed ActionButtonSpellAlertManager proc glow.
                                  Split out of Renderer.lua 2026-07-30. ⚠ The `rt fx`
                                  DIALLING RIG lived here and is now archive/
                                  RenderTest-fx-v1.lua (2026-08-02) — this file is back to
                                  what it says on the tin: fixtures, a rig, `states`,
                                  `rotate`, `off`.
    Media/fx/                     the shipped art + sound: `glow/star_07.tga` is BOTH cue
                                  rings, `sfx/drawKnife1.ogg` + `sfx/chip-lay-1.ogg` the two
                                  cue sounds; the rest are candidates that lost, kept for
                                  a future round. All CC0 Kenney — CREDITS.md has
                                  the per-pack provenance and says which three ship.
    HudProcGlow.lua               post-hooks each CDM item's RefreshOverlayGlow and dims
                                  item.SpellActivationAlert (SetAlpha 0.5) while the HUD is
                                  on, so Blizzard's proc glow doesn't drown our chrome;
                                  restored to full on toggle-off. Gated on ns.HudOn().
    HudLayout.lua                 Scan the live CDM icon viewers -> Layout
                                  (cooldownID -> spellID + frame registry).
    HudGeometry.lua               shared frame/anchor geometry helpers.
    HudVirtual.lua                OUR OWN icons for the rotation buttons the CDM tracks
                                  NOWHERE (Destruction's Incinerate, Demo's Shadow Bolt).
                                  State synthesises the domain-view row behind a NEGATIVE
                                  handle (`-spellID`); this pools one button frame per row
                                  and returns (layout, registry) fragments the driver merges
                                  — Binder.lua and Renderer.lua are UNCHANGED, which is the
                                  seam's success criterion. Owns the MOVEABLE panel:
                                  `/cdmp panel`, the drag, and the saved position in
                                  `ns.db.virtualPanel` (BucketBinds Console.lua's shape).
    HudDriver.lua                 the LIVE driver: the ~10 Hz ticker that runs the
                                  pipeline + the `/cdmp hud` command.
                                  ⚠ THE CADENCE IS SPLIT (Phase 5 §C8), and the two halves
                                  are not interchangeable. `pulseNow()` throttles the PULSE to
                                  OOC_BUILD_PERIOD = 0.5s OUT OF COMBAT ONLY (in combat every
                                  tick still builds — a stale pulse mid-pull is the one thing
                                  the HUD may never serve), while St.PumpFrames() runs EVERY
                                  tick regardless: it hoists `installAlertHooks` out of Build,
                                  so a frame that appears between throttled pulses still gets
                                  hooked and no alert edge is lost. ns.SetHud clears the cache
                                  on toggle, so turning the HUD on never serves a pulse from
                                  before it was off.
    Coverage.lua                  THE ROSTER COVERAGE PROBE (roster-state-plan Phase 4):
                                  does the CDM actually TRACK every id the spec's roster
                                  declares? Asked OUT OF COMBAT, where it is cheap.
                                  `Build(rows, specTable, deps)` is PURE (deps injected);
                                  `Get()` computes once, caches, and owns its own event
                                  frame (SPELLS_CHANGED / TRAIT_CONFIG_UPDATED /
                                  PLAYER_SPECIALIZATION_CHANGED) so the State->Coverage
                                  dependency stays ONE-WAY. Per id: coverage
                                  (tracked/untracked/unreadable) + verdict (ok / virtual /
                                  expected / BLIND / unknown). It was the REQUIRED replacement
                                  for `pulse.dropped`, which Phase 5 deleted (the decision
                                  log's `DR:` field is the other half).
                                  ⚠ ITS `blind` VERDICT NARROWED TO AURAS IN PHASE 5, and the
                                  probe is weaker for it. Every declared non-utility BUTTON now
                                  gets a virtual row by construction, so the HUD cannot be
                                  blind to a button any more — only a `kind = "aura"` entry can
                                  still be blind. Do not read a quiet coverage report as broad
                                  coverage; filed in status.md alongside roster gap #2 (the
                                  aura half of the roster is still write-only for State).
                                  ⚠ It joins on `linkedSpellIDs` and the DOMAIN VIEW
                                  DELIBERATELY DOES NOT — Coverage asks "does the CDM know this
                                  id at all", the join asks "which ability IS this row", and
                                  the pool is a bag of alternatives, so joining on it there
                                  would let one id claim a row that visibly draws another
                                  ability. The asymmetry is intentional; do not "align" them.
                                  ⚠ THE WHOLESALE GUARD IS THE POINT: an empty scan is
                                  `ok=false, reason="cdm-empty"` and reports NO entry as
                                  untracked (an empty database means the read refused, not
                                  that your roster is blind) — the twin of domainView's
                                  `next(items) ~= nil` refusal; in combat Get() hands back
                                  the cached report marked stale rather than rescanning. The
                                  zero-row case is MUTATION-CHECKED. ⚠ Virtual eligibility
                                  calls the REAL St.VirtualCandidates fences with an empty
                                  abilities map — do NOT copy the fences here, that is how
                                  the two drift. ⚠ Alert types render as "reported
                                  eligible", never "cannot fire" (lower bound).
    DecisionLog.lua               the decision log: one greppable `S{} G{} B{}` line
                                  per decision change -> CDMProbeDB.decisionlog.
                                  ⚠ Plus the EDGE MARKERS `# config` and (v0.32.75)
                                  `# combat start`/`# combat end`. The combat one is
                                  stamped ABOVE the change-only dedup and that placement
                                  is load-bearing: pulling from an idle bar does not move
                                  the decision, so a marker below the dedup would be
                                  swallowed exactly when it matters. It exists because
                                  `w:-` is only meaningful IN a pull, and entries are
                                  stored PRE-RENDERED — so combat can never be recovered
                                  from an older capture.
                                  Short-codes come from per-spec `abbr`/`spec.log`.
                                  ⚠ The `PW:` field reads guidance.resourceBars (Phase 6),
                                  NOT pulse.power — the bar carries both `value` and
                                  `incoming`, and State stopped writing `incoming`. A
                                  PASSIVE spec has no bar, so it honestly renders `?/?`.
    HudNapkin.lua                 anticipation: SUCCEEDED cast -> base-cooldown
                                  countdown.  The only DRIFTING input, fenced so it
                                  can only make the HUD early: an observed ready edge
                                  always wins, an expired estimate says "should be
                                  up, unconfirmed" rather than claiming ready.
    HudBinds.lua                  action-bar scan -> keybind per spellID (cached,
                                  out-of-combat only); read live off State each tick.
                                  `B.Resolve(...)` is the RUNG LADDER (Phase 3 §4.1):
                                  candidate ids in rung order, first one with a real
                                  binding wins. State passes rung 3 -> 4 -> 5
                                  (overrideTooltipSpellID / overrideSpellID / base). ⚠ It
                                  carries NO spec fences — unlike ns.DisplayIdentity it asks
                                  the action bar, so a wrong candidate simply has no binding
                                  and falls through. Rungs 1-2 are deliberately out: rung 1
                                  is the Demonic-Art transform fence, rung 2 was measured
                                  absent (0 of 72 rows, 2026-07-31).
    tests/                        busted unit tests (M4.5 T2) — NOT in the .toc,
                                  so never loaded in-game / harmless in the zip
      mock_ns.lua                 the harness: CreateFrame stub + fake clock +
                                  global fakes + real Util + SpecRegistry +
                                  SpecDemonology + CoachDemonology + SpecDestruction +
                                  CoachDestruction + SpecRetribution + CoachRetribution +
                                  SpecHavoc + CoachHavoc (spec 266 activated through the
                                  resolver; H.setSpecIndex(3/4/5) + ResolveActiveSpec drives
                                  267 / 70 / 577), + a fixture-settable
                                  ShardCost/BaseCooldown/napkin surface.
                                  ⚠ `H.specByIndex` IS APPEND-ONLY.  Index 2 is Affliction
                                  265, deliberately UNREGISTERED as spec_detect_spec's
                                  passive/unsupported fixture, and 1/3 are load-bearing in
                                  coach_apl_spec / coach_destruction_apl_spec — renumbering
                                  breaks suites that never mention the spec they broke.
      case_builders.lua           the CDM-case FACTORY, `(H, SECRET) -> {mint, buildItem}`:
                                  turns a case's declarative `world`/`cdm` tables into the
                                  faked database + item frames one St.Build pulse reads.
                                  Lives outside cdm_cases_spec.lua so harness_spec can prove
                                  it (Phase 2). Frame knobs are `fields` (minted verbatim),
                                  `methods` (no-op stubs, so ns.HasMethod answers true —
                                  ABSENT BY DEFAULT, which is what keeps the capability
                                  check falsifiable) and `raises` (H.poison on named fields).
      spec/coach_apl_spec.lua     the Tier-1 ROTATION gate for DEMONOLOGY: minimal
                                  hand-built State pulses assert winner + fallback + SOON
                                  per BRANCH of the flat list + shard boundaries, authored
                                  from apl-prototype/pseudocode.md (the independent oracle)
      spec/state_domainview_spec.lua  State's ROSTER-ANCHORED DOMAIN VIEW + its HERO-TREE
                                  read, loaded from the REAL State.lua with only the CDM
                                  database + frame discovery faked: St.RosterEntries /
                                  St.RosterClaims / St.RosterView as pure functions (a row is
                                  claimed by AT MOST ONE ability, and the claim ranking is
                                  global so pairs() order cannot decide a contest), the
                                  three-valued knownness MARK and its wholesale guard, the
                                  aura-lifecycle latch across Immolate's TWO cooldownIDs, and
                                  the charge napkin's full loop.
                                  ⚠ It runs DESTRUCTION throughout (H.setSpecIndex(3)), and
                                  the "exactly one virtual row per spec" guards build their
                                  board from St.RosterEntries (onScreenExcept) rather than a
                                  hand-listed id set — a hand-listed board silently stops
                                  covering anything added to the spec table later.
                                  ⚠ TWO MUTATION CHECKS ARE OWED TO IT AND WERE RUN 2026-08-03:
                                  delete the `(asked == 0) or sawReadable` term in rosterView's
                                  return and "knownReadable is FALSE when the whole roster
                                  refused" goes red; delete the `info.expect ~= false` fence in
                                  virtualCandidates and four cases go red, including both
                                  EXPECT=FALSE ones.
      spec/viewers_spec.lua       the item->identity resolvers, loaded from the REAL
                                  Viewers.lua with only frame DISCOVERY faked — the
                                  companion that proves ns.ItemCooldownID actually SHIPS.
                                  hudlayout_spec stubs it, which is exactly why the
                                  v0.32.25 outage stayed green for two days: a stub proves
                                  the caller works given the collaborator, never that the
                                  collaborator exists.
      spec/coach_destruction_apl_spec.lua  the same gate for DESTRUCTION (267), authored
                                  from specs/destruction/rotation.md L1-L13 — plus the
                                  spec-specific channels: banked charges, the three-way DoT
                                  presence read, the untracked-Incinerate degradation, and
                                  the ART_FROM_RITUAL switch on both settings
      spec/coach_retribution_apl_spec.lua  the same gate for RETRIBUTION (70), authored from
                                  specs/retribution/rotation.md L1-L12 — plus the
                                  spec-specific channels: the Hammer-of-Light override on
                                  either spender frame, the `display = "none"` rail proved
                                  all the way to the decision log's PW: column (the whole
                                  argument for `none` over an empty spec.powers), L4's
                                  deliberate yield to a ready Wake of Ashes, the LIVE spender
                                  cost, charge-aware readiness in BOTH directions (a zero
                                  count vetoes a ready cooldown; an ABSENT count does not),
                                  and the RET_HOL_FROM_BUFF switch on both settings.
                                  ⚠ It wires `ns.Coach.New({ shardCost = ns.ShardCost })` as
                                  the live driver does — coach_destruction_apl_spec does not,
                                  which is why the "cost is resolved live" rule is currently
                                  unasserted for Destruction (status.md backlog)
      spec/coach_havoc_apl_spec.lua  the same gate for HAVOC (577), authored from
                                  specs/havoc/rotation.md L1-L15 — plus the spec-specific
                                  channels: the META FORK proved on BOTH sources
                                  INDEPENDENTLY (the TrackedBuff row alone, either transform
                                  alone, both together) and the two orderings it moves (L6 is
                                  meta-only; L7-vs-L10 inverts Blade Dance against Eye Beam),
                                  the `display = "none"` Fury rail proved all the way to the
                                  decision log's PW: column, L1's Reaver's Glaive transform
                                  with HAVOC_RG_FROM_BUFF on BOTH settings, `ctx.ebWindow`
                                  from CAST HISTORY (inside / outside / no cast / the exact
                                  boundary), the LIVE spender cost resolving to
                                  ANNIHILATION's id in demon form, charge-aware readiness on
                                  a ONE-charge pool in both directions (a zero count vetoes a
                                  ready cooldown; an ABSENT count does not — that asymmetry
                                  IS the lying-cooldown mitigation and its residual hole),
                                  L5's cross-ability napkin gate + the Initiative veto, the
                                  runner-up dropping BOTH occurrences of an ability, and
                                  Rain from Above never being cued or decorated.
                                  ⚠ It wires the REAL `ns.Coach.New({ powerCost =
                                  ns.PowerCost })` and drives costs through the CLIENT-level
                                  `H.fx.powerCost` fake, so the shipping cost ladder runs —
                                  a harness that stubs the reader cannot catch a mis-wired
                                  one, which is how Retribution's cost bug survived 76 green
                                  cases.
                                  ⚠ It also files Felblade / Vengeful Retreat / Fel Rush as
                                  `category = "Utility"` in the fixture ON PURPOSE: a fixture
                                  that quietly filed them Essential would assert nothing
                                  about the cadence-not-category finding this spec exists to
                                  record.
      spec/derived_resource_spec.lua  THE CLASS-RESOURCE CHANNEL: ns.ReadCastCount /
                                  ReadAuraApplications / ReadMaxAuraApplications against the
                                  REAL Util.lua, plus State's declarative `derived` block.
                                  The property it exists to pin is ABSENT IS NEVER ZERO — 0
                                  is a real answer ("you have no fragments") and a refusal
                                  must never impersonate one.  ⚠ It also pins that
                                  ReadCastCount has NO combat gate, deliberately: ReadCharges
                                  carries one because GetSpellCharges was MEASURED secret,
                                  and pre-emptively copying it here would make the
                                  measurement impossible
      spec/coach_classify_spec.lua Classify in isolation (probably-up, transforms) + THE
                                  KNOWNNESS CAP (Phase 5 §C5, the phase's only Coach edit):
                                  known == false returns nil, "unknown" keeps the record with
                                  ready/probablyUp/anticipated/overdue zeroed and knownUnknown
                                  set, the underlying remaining/cdSource survive the cap so
                                  the trace stays honest, `state.knownReadable == false`
                                  ignores knownness in BOTH directions, and — the one that
                                  guards every other suite — an ABSENT `known` field changes
                                  nothing, which is why the third value is the STRING
                                  "unknown" and not nil
      spec/huddriver_cadence_spec.lua  the SPLIT CADENCE (Phase 5 §C8): the pulse throttles
                                  to 0.5s OUT OF COMBAT ONLY, in combat every tick rebuilds,
                                  the frame PUMP runs every tick either way (so no alert edge
                                  is lost between throttled pulses), and ns.SetHud clears the
                                  cache on toggle
      spec/binder_spec.lua        spellID cue -> display cooldownID/icon resolution, and
                                  the SECOND channel: cues carry decisions only, keybinds[]
                                  carries the key hint for every displayed icon (Phase 3)
      spec/coverage_spec.lua      the ROSTER COVERAGE JOIN as a pure function: the four ways
                                  a row can carry a declared id (base / overrideSpellID /
                                  overrideTooltipSpellID / a linkedSpellIDs member — four
                                  cases, because they are four separate joins), the three
                                  untracked verdicts, three-valued knownness surviving onto
                                  the entry, the alert-type outcomes (a refusal carries the
                                  REASON, an empty list is a distinct real answer, a secret
                                  member renders SECRET) — and THE WHOLESALE GUARD, which is
                                  MUTATION-CHECKED: flip the guard off and the zero-row case
                                  must go red. Plus C.Get's cache + its combat refusal.
                                  ⚠ Hand-built rows prove the JOIN and nothing about where
                                  rows come from — state_domainview_spec's "St.CoverageRows"
                                  block is the shipped-symbol companion
      spec/flight_spec.lua        the acceptance recorder: the properties that would make
                                  the REPORT lie — a transition deduped away, an unbounded
                                  ring, an arm that appends to the last flight — plus the
                                  two that matter most, that entering combat leaves the
                                  coverage answer INVARIANT (cached + stale, never a
                                  rescan) and that a cold in-combat arm refuses rather than
                                  reading the roster through secret-shortened enumeration
      spec/assist_spec.lua        the temporary C_AssistedCombat probe, cheap by design: the
                                  readout degrades honestly when the namespace is absent
                                  (ABSENT and nil are different findings), when the call
                                  throws, and when the return is secret — a secret must
                                  render as a CLASS, never be compared or printed, and must
                                  reach disk as the string "<secret>"
      spec/hudbinds_spec.lua      B.Resolve's RUNG LADDER off the REAL module: order (3>4>5),
                                  fall-through on an unbound rung, the secret/non-number
                                  refusals, nil rather than a placeholder, the alias fallback
                                  surviving on a rung.  Also the shipped-symbol gate for
                                  Resolve — State calls it unguarded
      spec/renderer_spec.lua      DrawList -> texture/token treatment
      spec/hudlayout_spec.lua     the CDM viewer walk -> Layout
      spec/hudvirtual_spec.lua    the virtual-icon fragments (shape agrees with
                                  HudLayout.Build by construction; the negative handle
                                  cannot collide) + the MOVEABLE panel: the saved-position
                                  round-trip, the default fallback, `reset`, lock/unlock
                                  over mouse+chrome+alpha, and the extents floor
      fixtures/cdm-cases.lua      THE CDM EDGE INVENTORY (pure data, never auto-collected —
                                  busted's pattern is `_spec.lua`).  107 declarative
                                  (CDM input -> expected State row) cases in 7 axes,
                                  authored from knowledge/addon-dev/cooldown-manager.md
                                  (NOT from State.lua — a suite transcribed from the source
                                  is a change-detector wearing a contract's clothes).
                                  ⚠ `status = "pinned-defect"` cases assert the CONTRACT
                                  answer, run INVERTED, and FAIL TODAY ON PURPOSE — a suite
                                  100 % green against the current code is by construction a
                                  snapshot.  When the fix lands, the case goes RED and the
                                  fix commit flips it to green + `fixed = "<phase> <§>"` in
                                  its own diff; do NOT "repair" one by weakening the
                                  expectation.  Phase 2 cleared all 11, so the corpus is
                                  currently **0 pinned-defect / 29 `fixed`** — the `fixed`
                                  tag is the permanent record that the case once failed, and
                                  a meta-test floors `#pinned + #fixed` so the history can
                                  never be quietly deleted.  Read the file header for the
                                  schema.
      spec/cdm_cases_spec.lua     the parametrised driver for the above: installs each
                                  case's CDM database + client world, runs its ordered
                                  script, diffs every named view off one St.Build pulse.
                                  Ten meta-tests enforce the corpus's own invariants
                                  (unique names, a mandatory `ref` that may never point at
                                  State.lua, a per-axis coverage floor, and a DEFECT-HISTORY
                                  floor on `#pinned + #fixed` that survived Phase 2 clearing
                                  every pin — never lower either floor)
      spec/harness_spec.lua       the HARNESS is a collaborator and gets the same treatment:
                                  H.secretTable / H.throws+H.guard / H.poison /
                                  H.installGlobals / the default-inert client fakes.
                                  `issecrettable` sat hardcoded `false` for the life of the
                                  addon, making six real refusal branches unreachable while
                                  every suite stayed green — the v0.32.25 shape exactly
      spec/decisionlog_spec.lua   the decision-log Record/Render split — including the `DR:`
                                  field RE-SOURCED off the rows' three-valued `known`
                                  (Phase 5 §C6): `<abbr>:unlearned`, `<abbr>:unknown`, `-`
                                  when there is nothing to report, and `!refused` when
                                  pulse.knownReadable == false, which a reader must never
                                  mistake for the healthy case
      spec/hudnapkin_spec.lua     anticipation countdown + honesty rules
      spec/specdelta_spec.lua     SpecDemonology signal-bucket deltas
      spec/spec_registry_spec.lua RegisterSpec/SetActiveSpec + legacy-global rebind
      spec/spec_detect_spec.lua   ResolveActiveSpec: known / unsupported / swap / no-spec
      spec/resource_multipower_spec.lua  synthetic 2-power spec -> resourceBars[] + N meters,
                                  and (Phase 6) the home of ns.Coach.InflightPower's proof:
                                  the per-power MAP survived the move off State, and the
                                  LATEST-PHASE-SUPERSEDES rule — a 'succeeded' or 'stopped'
                                  cancels an in-flight 'start', a re-cast after one projects
                                  again — which was never tested while it lived in State and
                                  is the thing that move was most likely to break silently
```

## Local checks (luacheck + busted) — M4.5

Two rungs above the release flow's luaparser **syntax** gate, both run against the
source tree (no game, no release). The toolchain is Lua 5.1 + luarocks (matches
WoW's runtime); provision once with `luarocks install --local luacheck busted` and
put `~/.luarocks/bin` on PATH.

- **`luacheck CDMProbe/`** — static analysis: undefined globals, dead locals,
  shadowing, typos. Config is **`.luacheckrc`** at this repo root: a WoW-globals
  `read_globals` std (the Blizzard API surface the addon actually calls), our few
  true global writes (`SLASH_CDMPROBE1/2`, `SlashCmdList`, `CDMProbeDB`,
  `CDMProbeShards`), `unused_args=false` / `max_line_length=false`, an
  `ignore = {"211/ADDON"}` for the idiomatic-but-unused `local ADDON, ns = ...`
  header, and a `CDMProbe/tests/` → `+busted` override. **Doctrine: curate the
  config or FIX the code — do not scatter inline `-- luacheck: ignore`.** A real
  catch gets fixed; a legit API name goes in the std.
- **`busted CDMProbe/tests/spec`** — unit tests for the pure-logic pipeline modules
  (`Coach`, `Binder`, `Renderer`, `HudLayout`, `DecisionLog`, `HudNapkin`,
  `SpecDemonology`) + the multi-spec seam (`SpecRegistry`/`ResolveActiveSpec`, the
  resource-array projection) + the **Destruction**, **Retribution** and **Havoc** rotation
  gates + **State's roster-anchored domain view** + State's hero-tree resolution + the **CDM
  edge inventory** (see `tests/fixtures/` below). **983 tests / 4 pending** (⚠ this number has
  drifted repeatedly — **re-run `busted` and read the summary rather than copying it**). The
  harness is
  **`CDMProbe/tests/mock_ns.lua`**: a chainable `CreateFrame`/FontString/animation
  stub, a **settable `GetTime` fake clock**, global fakes
  (`wipe`/`InCombatLockdown`/`issecretvalue`/`C_Timer`/`Enum`/`GetSpecialization`/…),
  the **real** `Util.lua` + `Viewers.lua` + `SpecRegistry.lua` + `SpecDemonology.lua` +
  `CoachDemonology.lua` + `SpecDestruction.lua` + `CoachDestruction.lua` +
  `SpecRetribution.lua` + `CoachRetribution.lua` + `SpecHavoc.lua` + `CoachHavoc.lua` +
  `HudBinds.lua` loaded through the `local ADDON, ns = ...` vararg shim (spec
  266 activated via the resolver), and a fixture-settable `ShardCost`/`BaseCooldown`/
  napkin surface. ⚠ `HudBinds` is the REAL module with `B.map` pointed at `fx.keybind` —
  the fixture supplies the action-bar cache and the rung ladder above it is shipping code
  (a stub would have had to duplicate the ladder these cases are about); only `Start` is
  stubbed, since the real one scans 180 slots through `GetActionInfo`. Specs load the module under test into that same `ns`. Run from this
  repo root:

  ```bash
  export PATH="$HOME/.luarocks/bin:$PATH"
  luacheck CDMProbe/
  busted CDMProbe/tests/spec
  ```

**`wowkb.cdmp decisionlog`** (runs in the parent workspace) extracts the live pipeline
**decision log** off SavedVariables to a grep-friendly `.log` — the greppable trace of
what State saw → what the Coach decided → what the Binder drew, one line per decision
change. Use it to answer "why does `/cdmp hud` show nothing here?":

```bash
cd ~/code/fun/wow/tools
uv run python -m wowkb.cdmp decisionlog   # → raw/cdmp-decision.log
```

**`wowkb.cdmp flight`** is the one to run after a test build: it reads `/cdmp flight`'s ring
out of the same SavedVariables file and prints a **PASS / FAIL / MEASURED** acceptance report
— roster coverage per spec, the in-combat wholesale guard, spec/hero invalidation, the
standing capability checks, the Phase-2 + `ChargeGained` signals lifted from the decision
log, and the `C_AssistedCombat` measurement. Exit 2 means "no failures, but you did not fly
part of it".

*(The old `wowkb.cdmp check|show|diff` probe-assertion suite + `probe-baseline.json` were
retired with the probe on 2026-07-29 — see the Commands note above.)*

**The release flow runs BOTH automatically** (`wowkb.addon release cdmp`), above the
luaparser syntax gate. Each is opt-in per addon and PATH-conditional — luacheck fires
only for an addon shipping a `.luacheckrc` (so bb/ps aren't drowned in false positives),
busted only for one declaring a `test_dir`, and either tool absent from PATH ⇒ warn +
continue, so a bare machine isn't wedged. **But when the tool IS present, a non-zero
exit aborts the cut — busted is a HARD release gate, not merely a dev/pre-commit check**
(`tools/wowkb/addon.py` step 4b). luaparser proves the Lua is well-formed; only busted
proves it still decides correctly. `--skip-lint` bypasses both.

## Licensing note

MIT. **EnhancedCooldownManager (GPL-3.0)** was read for API discovery only — no
code copied. The shared surface (Blizzard frame/field names like
`EssentialCooldownViewer` / `item.Cooldown`, and `hooksecurefunc` idioms) is API
fact, not copyrightable expression.

## Deploy / release workflow (a plain push does NOT reach the game)

`ghaddons` installs by pulling the **latest GitHub Release** (falls back to a
default-branch snapshot if none exists; we cut releases so version tracking is
clean). Updating the in-game addon:

1. **Edit** the Lua.
2. **Bump** `## Version:` in `CDMProbe/CDMProbe.toc`. Keep `## Interface:`
   matching the live patch (12.0.7 → `120007`; source of truth
   `wwt-keyboard/knowledge/_meta/game-version.md`).
3. **Syntax-check** (no Lua binary here — use luaparser):
   ```bash
   uv run --with luaparser python -c "import luaparser.ast as a,glob; \
     [a.parse(open(f).read()) for f in glob.glob('CDMProbe/*.lua')]; print('lua OK')"
   ```
4. **Commit** in this repo.
5. **Cut a GitHub Release** whose tag matches the `.toc` version:
   ```bash
   git push
   gh release create v0.1.0 --title v0.1.0 --notes "…" --repo michac/CDMProbe
   ```
   (No BigWigs packager, so ghaddons uses the release **source zip**, which
   contains `CDMProbe/CDMProbe.toc` — installs correctly.)
6. **Deploy** — this pulls the release into `Interface/AddOns/`. Runnable from
   any directory (ghaddons keeps its config next to its own package, not in the
   cwd), from WSL or from Windows `python`:
   ```bash
   PYTHONPATH=~/code/fun/wow/addon-manager python3 -m ghaddons.cli update michac/CDMProbe
   ```
   First time only: `... add michac/CDMProbe` then `... install michac/CDMProbe`.
   Confirm with `... list` — CDMProbe should read `ok` at the new version, and
   the `.toc` under `…/_retail_/Interface/AddOns/CDMProbe/` should show it too.
   *(If it reports "AddOns directory not found", `addons_dir` in
   `addon-manager/config.json` points at a WoW install that isn't there — the
   `/mnt/c` vs `C:\` distinction is handled automatically and is not the cause.)*
7. In-game: `/reload`, then `/cdmp help`.

## Conventions

- **Interface version** tracks the live patch. 12.0.7 = `120007`.
- **Tag = `.toc` version**, prefixed `v` (`## Version: 0.1.0` → tag `v0.1.0`).
- SavedVariables: `CDMProbeDB`.

## In-game smoke test

Deploy a build (`ghaddons update michac/CDMProbe` → `/reload`), then:

1. `/cdmp hud` → the pipeline draws its cue overlay; Essential + Utility icons keep
   their **native art, swipe and countdown**. `/cdmp hud status` reads ON with a
   non-zero ingestion consumer count, a clean last tick, and the active spec line;
   `/cdmp hud layout` lists the tracked icons with resolved spellIDs + keybinds.
   Toggle off → Blizzard's UI is pixel-clean (every dot cleared).
2. **Pull a target dummy** and play a real rotation for a minute — proc a Demonic
   Core, fire the burst, cast a few cast-time spells. Watch the cues track the
   rotation.
3. **`/reload`**, then extract the trace: `uv run python -m wowkb.cdmp decisionlog`
   and grep `raw/cdmp-decision.log` for any `w:-` (Coach found no winner) or `×`
   (Binder dropped a cue) — the two pipeline-failure smoking guns.
4. `/cdmp reset` → the HUD clears cleanly.
