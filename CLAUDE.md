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
looks. It now also carries **the real HUD** (`/cdmp hud`, M3+). The v1 direction
is a **terminal / CRT-flavoured overlay that leaves Blizzard's icons native and
untouched** and builds all value-add in the chrome around them; the green-phosphor
icon-tint era (`/cdmp crt`) was **retired in v0.6.0** — its tint machinery survives
dormant in `HudTint.lua`. The older "no-icons, solid color block" experiments
(`/cdmp skin`, `/cdmp resource`) are kept as reference, not the direction.

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
  `probe clear` resets the passive counters.
  **The loop:** `/cdmp probe` out of combat → pull → `/cdmp probe` in combat →
  **`/reload`** → reports are at
  `…/_retail_/WTF/Account/<ACCT>/SavedVariables/CDMProbe.lua` under
  `CDMProbeDB.reports["probe_ooc"]` / `["probe_combat"]`.
  ⚠ The `/reload` is **not optional** — SavedVariables only flush on
  reload/logout, so skipping it leaves last session's text on disk, which looks
  exactly like a probe that silently did nothing.
- `hud` — **the real HUD (M3+).** Binds per item to the **live** CDM layout by
  `cooldownID` off the `RefreshLayout` hook (+ `COOLDOWN_VIEWER_DATA_LOADED` /
  `PLAYER_ENTERING_WORLD`) — no ticker. Blizzard's icons stay **native and
  untouched**; we draw group-colour accents with a generator/consumer batch tint,
  real keybinds (action-bar scan, cached, OOC-only), a scanline overlay and the
  `DEMO.SYS` terminal frame.
  Since v0.10.0 it also draws the **dot score** (§0.5.8.7): a per-ability dot
  carrying an actionability LEVEL (NEVER / AVAILABLE / ROTATION / LATE, with SOON
  as an anticipation treatment on NEVER) plus a text row saying *why* — so the
  score is auditable, not an oracle.
  v0.13.0 (**M3c-b, the truth pass**) added no new signal — it made that one
  true: the dot scores the **live** identity (a transformed button is judged as
  what it has become, and an unrecognised override gets **no dot**), identity
  reads are Secret-Value-guarded at the source with a last-known-good fallback
  across rebinds, LATE no longer accrues out of combat, an in-flight cast
  projects its shard spend (rendered **hollow** — it's an estimate), and the HUD
  **warns when an ability it expects isn't in your tracked set**, saying what
  that costs you.
  - `hud status` — bound items per viewer, resolved spellIDs + group/pole/cadence,
    keybind hits/misses, per-source rebind fire counts, the score block (how many
    dots are lit and why), the **expected-vs-bound diff** (abilities `ns.Spec`
    knows about, that you have, that your CDM isn't tracking — the persistent home
    for that warning, since chat scrolls away and this gets captured by `probe`),
    and **whether the napkin is live at all** — i.e.
    whether `UNIT_SPELLCAST_SUCCEEDED` spellIDs read non-secret in this context.
  - `hud binds` — **every** action slot each tracked spell sits in, with binding
    command, raw key and which one the chrome actually uses. Diagnoses "I remapped
    a key and it didn't pick it up": first-bound-slot-wins, unbindable slot ranges
    (13–24 / 109–180), and macros `GetMacroSpell` can't resolve.
  - `hud debug` — verbose rows (identity, cooldown, raw+normalised cost, presence
    source, override state).  `hud dump` prints the same to chat.
  - `hud rows` — turn the text rows off entirely (the dots stay).
  - `hud opener 1a|1b` — *(M3c)* which opener the pre-pull queue ghosts.
- `skin` — *(reference, retired direction)* hide icons on Essential+Utility, paint
  solid color blocks + labels, keep Blizzard's secure cooldown swipe.
- `resource` — *(reference, retired direction)* resource-centric skin: group-color
  blocks + 4-letter labels, recolored BuffBar duration bars, and a Soul Shard rail
  we own (fill, generate→spend→cap recolor, cap flash + spark + earcon).
- `reset` — turn every experiment off.

## File layout

```
projects/cooldown-hud/addon/      <- THIS repo root (michac/CDMProbe)
  CLAUDE.md                       this file
  README.md
  LICENSE                         MIT
  .gitignore
  CDMProbe/                       <- the addon folder ghaddons installs
    CDMProbe.toc
    Core.lua                      namespace, saved vars, slash cmds, registry
    Util.lua                      color, spell-name, Secret-Values-aware describe
    Viewers.lua                   locate viewers, enumerate items,
                                  ns.DumpViewers() (a `probe` section)
    Skin.lua                      color-block skin experiment (retired direction)
    Probe.lua                     THE probe: passive recorders + `/cdmp probe`
                                  (one report, saved to SavedVariables), `reset`
    Resource.lua                  resource-centric skin: group-color blocks +
                                  duration bars + soul-shard rail (`resource`)
    SpecDemonology.lua            per-spec data: the SIGNAL BUCKET per spellID
                                  (group / kind / spends / generates / cadence /
                                  burstAlign / goGate / primary / judgeable).
                                  Replaced the old `role` enum in v0.10.0.  The
                                  seam a 2nd spec plugs into (M7); render modules
                                  hold no spell constants of their own.
    HudCore.lua                   registry bound by cooldownID, RefreshLayout +
                                  event binding, enable/disable, `hud` cmds
    HudChrome.lua                 everything we DRAW: the per-item DOT (level),
                                  the group BRACKET spanning icon+dot+text,
                                  keybind text, proc glow, DEMO.SYS terminal
                                  frame, scanline/vignette overlay
    HudScore.lua                  the DOT SCORE: a pure function of readable
                                  state -> (level, reasons).  NEVER / AVAILABLE /
                                  ROTATION / LATE, plus the judgeable=false cap.
                                  Owns no frames and reads nothing secret.
    HudNapkin.lua                 anticipation: SUCCEEDED cast -> base-cooldown
                                  countdown.  The only DRIFTING input in the
                                  design, fenced so it can only make the HUD
                                  early: an observed ready edge always wins, and
                                  an expired estimate says "should be up,
                                  unconfirmed" rather than promoting a dot.
    HudRow.lua                    the row beside each icon: dot level + WHY.
                                  Default-ON (was HudDebug.lua); `hud debug` is
                                  now a verbose flag on the same row builder.
    HudBinds.lua                  action-bar scan -> keybind per spellID (cached,
                                  out-of-combat only)
    HudTint.lua                   DORMANT leaf-method icon-tint machinery rescued
                                  from the deleted CRT.lua — unwired; gates a
                                  future optional solid-colour mode (notes.md §9)
```

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
2. `/cdmp hud` → Essential + Utility icons keep their **native art, swipe and
   countdown**; group-colour accents appear around them (Tyrant/Dreadstalkers/
   Grimoire green, HoG/Demonbolt violet, Implosion lime, defensives blue, CC
   slate, Circle gold), real keybinds in the corner, DEMO.SYS frame + scanlines.
   Drag the CDM in Edit Mode → chrome rides along. Change Orientation/# Rows →
   `/cdmp hud status` fire counts increment and nothing detaches. Toggle off →
   Blizzard's UI is pixel-clean.
3. **Pull a target dummy** and play a real rotation for a minute — the passive
   recorders are collecting the whole time, so just play. Proc a Demonic Core,
   let a Grimoire go on cooldown, cast a few cast-time spells.
4. **`/cdmp probe` again, in combat.** Diff section A against the OOC run (that
   is the M3d answer), and check section C for any phase reading `ALL SECRET`.
5. **`/reload`**, then the two reports are on disk under `CDMProbeDB.reports`.
6. `/cdmp reset` → everything clears cleanly.

Report findings back to the parent workspace to shape the real HUD.
