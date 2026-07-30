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
  is now the pipeline; `/cdmp hud2` is a transitional alias.
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
  at the W4 cutover; **`/cdmp hud2` is a transitional alias** for the same handler.)
  - `hud on` / `hud off` — set it explicitly (bare `hud` toggles).
  - `hud status` — the pipeline readout: ON/OFF, State ingestion consumer count, and
    the last tick's cue count / any tick error. The decision trace is in
    `CDMProbeDB.decisionlog` (extract with `wowkb.cdmp decisionlog`; `hud2log` is a
    back-compat alias).
  - `hud layout` — dump the live Layout (icon viewers -> cooldownID -> spellID +
    the State-resolved keybind) — the row to read when a cue's key is missing.
- `single` / `multi` / `aoe` — the target-mode toggle (`Mode.lua`): idempotent
  macro-friendly setters + a bare toggle. Forwarded by State as its `mode` field;
  the Coach reads it but does not branch yet (scaffolding for a 2nd spec / AoE rule).
- `rendertest` — Phase-3 draw test: render a hand-authored DrawList fixture (`Renderer.lua`).
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
    Util.lua                      color, spell-name, Secret-Values-aware describe
    Viewers.lua                   locate viewers, enumerate items, and resolve each item's
                                  IDENTITY: ns.GetViewer / ns.GetItemFrames /
                                  ns.ItemCooldownID / ns.ItemSpellID / ns.ItemBaseSpellID
                                  (read by HudLayout + State). ⚠ ItemCooldownID is the
                                  pipeline's BINDING KEY — it was deleted with HudCore at
                                  the W4 cutover and its nil-guarded call sites turned that
                                  into a silent total HUD outage (fixed v0.32.25). Do not
                                  reintroduce `ns.X and ns.X(...)` guards on our own symbols.
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
                                  SpecPowerDelta projects SPENDERS ONLY: Destruction
                                  generates in FRAGMENTS into a bar State reads in whole
                                  shards, so faking integer `generates` would make the
                                  in-flight projection lie by up to a shard per filler cast.
    -- The W4 pipeline (State -> Coach -> Binder -> Renderer), driven each tick by
    -- HudDriver.  See docs/architecture.md.
    State.lua                     ingestion + State.Build: folds the CDM rows into
                                  the base-spellID domain view (abilities/buffs/
                                  resources); Secret-Value-guarded, napkin + edge
                                  fused for honest readiness. The pipeline's INPUT.
    Coach.lua                     the generic Coach SHELL: Classify / Emit / ResourceBars
                                  / Sequence + a delegating Compute + EmptyGuidance. Reads
                                  ns.ActiveSpec live each tick; returns EmptyGuidance when
                                  passive. Holds no spec logic — Context/RankWinner/Escalate
                                  live on the active spec object (CoachDemonology.lua).
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
                                  Escalate), CHARGE-AWARE readiness (Conflagrate +
                                  Shadowburn are the project's first charged tracked
                                  abilities — banked-charge read works OOC, degrades to
                                  binary in combat), and a three-way up/missing/unknown DoT
                                  read so an UNREADABLE Immolate never becomes "refresh it
                                  now". `ART_FROM_RITUAL` is the one unsettled read,
                                  defaulted OFF — see the file header. Greened against
                                  coach_destruction_apl_spec.
    Binder.lua                    Binder:Bind(guidance, layout) -> DrawList: resolves
                                  each spellID cue to a display cooldownID/icon.
    Renderer.lua                  Renderer:Draw(drawList): OUR OWN textures anchored
                                  to Blizzard's icons; semantic tokens -> pixels.
    HudProcGlow.lua               post-hooks each CDM item's RefreshOverlayGlow and dims
                                  item.SpellActivationAlert (SetAlpha 0.5) while the HUD is
                                  on, so Blizzard's proc glow doesn't drown our chrome;
                                  restored to full on toggle-off. Gated on ns.HudOn().
    HudLayout.lua                 Scan the live CDM icon viewers -> Layout
                                  (cooldownID -> spellID + frame registry).
    HudGeometry.lua               shared frame/anchor geometry helpers.
    HudDriver.lua                 the LIVE driver: the ~10 Hz ticker that runs the
                                  pipeline + the `/cdmp hud` command (alias `hud2`).
    DecisionLog.lua               the decision log: one greppable `S{} G{} B{}` line
                                  per decision change -> CDMProbeDB.decisionlog.
                                  Short-codes come from per-spec `abbr`/`spec.log`.
    HudNapkin.lua                 anticipation: SUCCEEDED cast -> base-cooldown
                                  countdown.  The only DRIFTING input, fenced so it
                                  can only make the HUD early: an observed ready edge
                                  always wins, an expired estimate says "should be
                                  up, unconfirmed" rather than claiming ready.
    HudBinds.lua                  action-bar scan -> keybind per spellID (cached,
                                  out-of-combat only); read live off State each tick.
    tests/                        busted unit tests (M4.5 T2) — NOT in the .toc,
                                  so never loaded in-game / harmless in the zip
      mock_ns.lua                 the harness: CreateFrame stub + fake clock +
                                  global fakes + real Util + SpecRegistry +
                                  SpecDemonology + CoachDemonology + SpecDestruction +
                                  CoachDestruction (spec 266 activated through the
                                  resolver; H.setSpecIndex(3) + ResolveActiveSpec drives
                                  267), + a fixture-settable ShardCost/BaseCooldown/napkin
                                  surface
      spec/coach_apl_spec.lua     the Tier-1 ROTATION gate for DEMONOLOGY: minimal
                                  hand-built State pulses assert winner + fallback + SOON
                                  per BRANCH of the flat list + shard boundaries, authored
                                  from apl-prototype/pseudocode.md (the independent oracle)
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
      spec/binder_spec.lua        spellID cue -> display cooldownID/icon resolution
      spec/renderer_spec.lua      DrawList -> texture/token treatment
      spec/hudlayout_spec.lua     the CDM viewer walk -> Layout
      spec/decisionlog_spec.lua   the decision-log Record/Render split
      spec/hudnapkin_spec.lua     anticipation countdown + honesty rules
      spec/specdelta_spec.lua     SpecDemonology signal-bucket deltas
      spec/spec_registry_spec.lua RegisterSpec/SetActiveSpec + legacy-global rebind
      spec/spec_detect_spec.lua   ResolveActiveSpec: known / unsupported / swap / no-spec
      spec/resource_multipower_spec.lua  synthetic 2-power spec -> resourceBars[] + N meters
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
  resource-array projection) + the **Destruction** rotation gate. **209 tests**
  (141 pipeline/Demonology + 57 Destruction + 11 viewers_spec). The harness is
  **`CDMProbe/tests/mock_ns.lua`**: a chainable `CreateFrame`/FontString/animation
  stub, a **settable `GetTime` fake clock**, global fakes
  (`wipe`/`InCombatLockdown`/`issecretvalue`/`C_Timer`/`Enum`/`GetSpecialization`/…),
  the **real** `Util.lua` + `SpecRegistry.lua` + `SpecDemonology.lua` +
  `CoachDemonology.lua` + `SpecDestruction.lua` + `CoachDestruction.lua`
  loaded through the `local ADDON, ns = ...` vararg shim (spec
  266 activated via the resolver), and a fixture-settable `ShardCost`/`BaseCooldown`/
  napkin surface. Specs load the module under test into that same `ns`. Run from this
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
uv run python -m wowkb.cdmp decisionlog   # → raw/cdmp-decision.log  (hud2log is an alias)
```

*(The old `wowkb.cdmp check|show|diff` probe-assertion suite + `probe-baseline.json` were
retired with the probe on 2026-07-29 — see the Commands note above.)*

**The release flow runs luacheck automatically** (`wowkb.addon release cdmp`), as a
SOFT gate above luaparser: it fires only for an addon that ships a `.luacheckrc`
(so bb/ps aren't drowned in false positives) and only if `luacheck` is on PATH
(absent ⇒ warn + continue, so a bare machine isn't wedged); a non-zero exit aborts
the cut. `busted` is **not** wired into the release — it's a dev/pre-commit check.
`--skip-lint` bypasses both.

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
