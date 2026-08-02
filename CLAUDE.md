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

Registered specs: **Demonology** (266, play-settled) and **Destruction** (267, shipped
2026-07-29, not yet flown). Every other spec resolves passive by design.

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
    -- The W4 pipeline (State -> Coach -> Binder -> Renderer), driven each tick by
    -- HudDriver.  See docs/architecture.md.
    State.lua                     ingestion + State.Build: folds the CDM rows into
                                  the base-spellID domain view (abilities/buffs/
                                  power); Secret-Value-guarded, napkin + edge
                                  fused for honest readiness. The pipeline's INPUT.
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
                                  ⚠ `abilities` is FILTERED (field-fix A): a row that is
                                  unlearned (isKnown==false) or undrawable (no item frame)
                                  never enters it — both read `ready` forever, so they won
                                  the priority list (216 dropped Soul Fire cues in one live
                                  session). Drops are reported on `pulse.dropped`, never
                                  silent. Consumes ALL SIX alert types now: the two cooldown
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
                                  ⚠ THE CULL HAS A THIRD TERM, `ghosting`: a removed handle
                                  leaves both active sets in the very draw that starts its
                                  out-animation, so a two-term union would hide the holder
                                  and the ghost would play invisibly.
                                  ⚠ THE CUE LAYER (`cueLayers`, 2026-08-01) is why the pop
                                  can exist. `setDotGlow` re-asserts SetSize on the dot /
                                  ring / echo / disc at ~10 Hz, which would fight a Scale
                                  animation on those same textures — so the pop scales a
                                  FRAME that owns them and the draw path never touches its
                                  size. Its rect is the DOT's rect, not the icon's, so the
                                  scale origin is the cue's own centre. The KEYBIND
                                  FONTSTRING DELIBERATELY STAYS ON THE HOLDER: identity
                                  chrome must not grow every time the rotation moves.
                                  ⚠ THE CUE IS v2 (2026-08-02): backing disc + dot + TWO
                                  COUNTER-ROTATING RINGS, no breathe / pop / ghost (all in
                                  archive/cue-treatment-v1.lua). Its numbers are an
                                  EXPERIMENTAL RESULT, not a dial-in — two subagents blind
                                  to this repo converged on them and both ran steady, which
                                  is why the header at RING_SCALE is worth reading before
                                  touching any of them. ⚠ The pair COUNTER-ROTATES at
                                  DIFFERENT periods on purpose; v1's echo was locked in
                                  phase to kill a moiré and the cost was that the second
                                  ring was invisible. The constraint is the BEAT FREQUENCY
                                  (n-fold art beats at n x the relative angular velocity —
                                  6s vs 9s gives 2.2 Hz, above the band the eye tracks);
                                  check any retune against the art's symmetry order, not by
                                  eye at one speed.
                                  ⚠ ONE INJECTED CALLBACK, `cfg.onCueSetChanged(kind)` —
                                  fired ONCE per draw on which the cue set changed at all
                                  ("new" if anything was added, else "gone"). The Renderer
                                  still calls no game function; HudDriver hangs the sound
                                  off it and busted asserts the edges directly.
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
    Coverage.lua                  THE ROSTER COVERAGE PROBE (roster-state-plan Phase 4):
                                  does the CDM actually TRACK every id the spec's roster
                                  declares? Asked OUT OF COMBAT, where it is cheap.
                                  `Build(rows, specTable, deps)` is PURE (deps injected);
                                  `Get()` computes once, caches, and owns its own event
                                  frame (SPELLS_CHANGED / TRAIT_CONFIG_UPDATED /
                                  PLAYER_SPECIALIZATION_CHANGED) so the State->Coverage
                                  dependency stays ONE-WAY. Per id: coverage
                                  (tracked/untracked/unreadable) + verdict (ok / virtual /
                                  expected / BLIND / unknown). Also the REQUIRED replacement
                                  for `pulse.dropped`, which Phase 5 deletes.
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
                                  CoachDestruction (spec 266 activated through the
                                  resolver; H.setSpecIndex(3) + ResolveActiveSpec drives
                                  267), + a fixture-settable ShardCost/BaseCooldown/napkin
                                  surface
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
      spec/state_domainview_spec.lua  State's DOMAIN VIEW + its HERO-TREE read, loaded
                                  from the REAL State.lua
                                  with only the CDM database + frame discovery faked: the
                                  PRESSABLE filter (an unlearned or undrawable row never
                                  reaches `abilities`, the raw `cooldowns` view keeps both,
                                  and every drop is reported), the aura-lifecycle latch
                                  across Immolate's TWO cooldownIDs, and the charge napkin's
                                  full loop. The filter is mutation-checked three ways.
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
      spec/coach_classify_spec.lua Classify in isolation (probably-up, transforms)
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
                                  busted's pattern is `_spec.lua`).  99 declarative
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
                                  currently **0 pinned-defect / 21 `fixed`** — the `fixed`
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
      spec/decisionlog_spec.lua   the decision-log Record/Render split
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
  resource-array projection) + the **Destruction** rotation gate + **State's domain-view
  fold** + State's hero-tree resolution + the **CDM edge inventory** (see `tests/fixtures/`
  below). **688 tests / 4 pending.** The harness is
  **`CDMProbe/tests/mock_ns.lua`**: a chainable `CreateFrame`/FontString/animation
  stub, a **settable `GetTime` fake clock**, global fakes
  (`wipe`/`InCombatLockdown`/`issecretvalue`/`C_Timer`/`Enum`/`GetSpecialization`/…),
  the **real** `Util.lua` + `Viewers.lua` + `SpecRegistry.lua` + `SpecDemonology.lua` +
  `CoachDemonology.lua` + `SpecDestruction.lua` + `CoachDestruction.lua` + `HudBinds.lua`
  loaded through the `local ADDON, ns = ...` vararg shim (spec
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
