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

Target spec for v1 experiments: **Demonology Warlock**.

Design context + status live in the parent workspace at
`projects/cooldown-hud/docs/` (`spec.md` vision · `notes.md` technical findings ·
`milestones.md` roadmap) — not this repo.

## Commands (`/cdmp <cmd>`, alias `/cdmprobe`)

- `probe` — **THE probe (v0.12.0).** One command, one report, **written to disk**.
  Replaced `dump` / `secret` / `casts` / `log` / `layout` / `shards`, which each
  answered one question and each had to be toggled *before* the interesting thing
  happened — the wrong shape, since procs/transforms/secret reads can't be
  scheduled. Everything passive now records **from load** (cast-phase readability
  counters, spell-override pairs, glow + data-loaded counts) at counter cost, and
  `probe` renders the lot: environment + viewer/item anatomy, the secret map,
  **A** cooldown readability per tracked spell (the M3d gate), **B** overrides and
  live base-vs-live divergence, **C** per-phase cast readability, **D** the
  imp-count side-channel probe, plus the HUD's own state/score/napkin block.
  `probe clear` resets the passive counters **and the stored snapshots** — run it
  at the start of a session so coverage reads as *this* session's.
  **The loop:** `/cdmp probe` out of combat → pull → `/cdmp probe` in combat →
  **`/reload`** → reports are at
  `…/_retail_/WTF/Account/<ACCT>/SavedVariables/CDMProbe.lua` under
  `CDMProbeDB.reports["probe_ooc"]` / `["probe_combat"]`.
  ⚠ The `/reload` is **not optional** — SavedVariables only flush on
  reload/logout, so skipping it leaves last session's text on disk, which looks
  exactly like a probe that silently did nothing.
  - **Two outputs, one observation set (v0.25.0, M4.5 T3).** Every probe run also
    writes the same facts as a **structured table** at `CDMProbeDB.probe.ooc` /
    `.combat` — the machine input for `wowkb.cdmp`, which must never text-parse a
    report this codebase re-words freely. Each section computes its observation as
    a **value** first and renders it twice (chat line + snapshot), so the two can't
    drift. **Rule: never read the game a second time to fill the table.** A field
    that would carry a Secret Value is stashed as the string `"<secret>"`; a read
    that *errors* is flagged `<field>Errored` — different worlds, kept distinct.
  - **`probe guide`** — a **pull-based** coverage checklist (no frame, no
    auto-refresh; re-type it to re-check). Ticks each goal — OOC reads captured,
    SUCCEEDED seen readable, a transform observed, imp aura observed, in-combat
    probe taken — names what's missing and nudges, and reports "coverage complete"
    only when all are met. **What it buys is timing:** you learn the capture is
    incomplete while still at the dummy, not an hour later from `wowkb.cdmp check`.
    It *detects and nudges*; it cannot *create* state (no proc, no imps on demand).
  - **The division of labour** (`docs/m4.5-t3-plan.md`): **collect** a new
    observation → addon change + release; **assert / interpret / re-verify** →
    local tooling, no release. That is why the expectations live in
    `projects/cooldown-hud/probe-baseline.json`, not in shipped Lua.
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
    `CDMProbeDB.hud2log` (extract with `wowkb.cdmp hud2log`).
  - `hud layout` — dump the live Layout (icon viewers -> cooldownID -> spellID +
    the State-resolved keybind) — the row to read when a cue's key is missing.
- `single` / `multi` / `aoe` — the target-mode toggle (`Mode.lua`): idempotent
  macro-friendly setters + a bare toggle. Forwarded by State as its `mode` field;
  the Coach reads it but does not branch yet (scaffolding for a 2nd spec / AoE rule).
- `reset` — turn every experiment off.

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
    Viewers.lua                   locate viewers, enumerate items,
                                  ns.DumpViewers() (a `probe` section)
    Probe.lua                     THE probe: passive recorders + `/cdmp probe`
                                  (one report, saved to SavedVariables), `reset`
    Mode.lua                      the single/AoE target-mode toggle (`ns.Mode.aoe`
                                  + `single`/`multi`/`aoe`); State forwards it, the
                                  Coach reads it (extracted from HudCore at the cutover)
    SpecDemonology.lua            per-spec data: the SIGNAL BUCKET per spellID
                                  (group / kind / spends / generates / cadence /
                                  burstAlign / goGate / primary / judgeable).
                                  The seam a 2nd spec plugs into; other modules
                                  hold no spell constants of their own.
    -- The W4 pipeline (State -> Coach -> Binder -> Renderer), driven each tick by
    -- HudDriver.  See docs/architecture.md.
    State.lua                     ingestion + State.Build: folds the CDM rows into
                                  the base-spellID domain view (abilities/buffs/
                                  resources); Secret-Value-guarded, napkin + edge
                                  fused for honest readiness. The pipeline's INPUT.
    Coach.lua                     Coach.Compute(state) -> Guidance: the SINGLE-TOP-
                                  PRESS ranked winner. RankWinner is a FLAT priority
                                  list (apl-prototype/pseudocode.md) — no phase
                                  machine; emits winner + ROTATION_FALLBACK runner-up
                                  + dumb per-ability SOON. Greened against
                                  coach_apl_spec (the Tier-1 branch oracle).
    Binder.lua                    Binder:Bind(guidance, layout) -> DrawList: resolves
                                  each spellID cue to a display cooldownID/icon.
    Renderer.lua                  Renderer:Draw(drawList): OUR OWN textures anchored
                                  to Blizzard's icons; semantic tokens -> pixels.
    HudLayout.lua                 Scan the live CDM icon viewers -> Layout
                                  (cooldownID -> spellID + frame registry).
    HudGeometry.lua               shared frame/anchor geometry helpers.
    HudDriver.lua                 the LIVE driver: the ~10 Hz ticker that runs the
                                  pipeline + the `/cdmp hud` command (alias `hud2`).
    Hud2Log.lua                   the decision log: one greppable `S{} G{} B{}` line
                                  per decision change -> CDMProbeDB.hud2log.
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
                                  global fakes + real Util/SpecDemonology + a
                                  fixture-settable ShardCost/BaseCooldown/napkin surface
      spec/coach_apl_spec.lua     the Tier-1 ROTATION gate: minimal hand-built State
                                  pulses assert winner + fallback + SOON per BRANCH of
                                  the flat list + shard boundaries, authored from
                                  apl-prototype/pseudocode.md (the independent oracle)
      spec/coach_classify_spec.lua Classify in isolation (probably-up, transforms)
      spec/binder_spec.lua        spellID cue -> display cooldownID/icon resolution
      spec/renderer_spec.lua      DrawList -> texture/token treatment
      spec/hudlayout_spec.lua     the CDM viewer walk -> Layout
      spec/hud2log_spec.lua       the decision-log Record/Render split
      spec/hudnapkin_spec.lua     anticipation countdown + honesty rules
      spec/specdelta_spec.lua     SpecDemonology signal-bucket deltas
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
  (`Coach`, `Binder`, `Renderer`, `HudLayout`, `Hud2Log`, `HudNapkin`,
  `SpecDemonology`). The harness is
  **`CDMProbe/tests/mock_ns.lua`**: a chainable `CreateFrame`/FontString/animation
  stub, a **settable `GetTime` fake clock**, global fakes
  (`wipe`/`InCombatLockdown`/`issecretvalue`/`C_Timer`/`Enum`/…), the **real**
  `Util.lua` + `SpecDemonology.lua` loaded through the `local ADDON, ns = ...`
  vararg shim, and a fixture-settable `ShardCost`/`BaseCooldown`/napkin surface.
  Specs load the module under test into that same `ns`. Run from this repo root:

  ```bash
  export PATH="$HOME/.luarocks/bin:$PATH"
  luacheck CDMProbe/
  busted CDMProbe/tests/spec
  ```

The **third rung is `wowkb.cdmp`** (M4.5 T3) — the one that reaches what neither
luacheck nor busted can: the *live* Secret-Value / override / cast-readability
paths. It runs **in the parent workspace, not here**, against a real capture:

```bash
cd ~/code/fun/wow/tools
uv run python -m wowkb.cdmp check     # assert the capture vs probe-baseline.json
uv run python -m wowkb.cdmp show      # pretty-print it
uv run python -m wowkb.cdmp diff      # ooc vs combat — the M3d seam
```

`check` exits non-zero on any high-severity failure. Because the assertions live
in `projects/cooldown-hud/probe-baseline.json` (local JSON) rather than in shipped
Lua, **retuning or adding one needs no release** — only *collecting a new
observation* does.

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

1. **`/cdmp probe` out of combat.** The four viewers are found, items list with
   real spellIDs + names. **Section A is the one to read first** — if cooldown
   duration/startTime print real numbers here, M3d (out-of-combat seeding) is
   viable and the "no edge seen yet" cold start is removable.
2. `/cdmp hud` → the pipeline draws its cue overlay; Essential + Utility icons keep
   their **native art, swipe and countdown**. `/cdmp hud status` reads ON with a
   non-zero ingestion consumer count and a clean last tick; `/cdmp hud layout` lists
   the tracked icons with resolved spellIDs + keybinds. Toggle off → Blizzard's UI is
   pixel-clean (every dot cleared).
3. **Pull a target dummy** and play a real rotation for a minute — the passive
   recorders are collecting the whole time, so just play. Proc a Demonic Core,
   let a Grimoire go on cooldown, cast a few cast-time spells.
4. **`/cdmp probe` again, in combat.** Diff section A against the OOC run (that
   is the M3d answer), and check section C for any phase reading `ALL SECRET`.
5. **`/reload`**, then the two reports are on disk under `CDMProbeDB.reports`.
6. `/cdmp reset` → everything clears cleanly.

Report findings back to the parent workspace to shape the real HUD.
