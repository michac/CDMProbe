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
looks — before committing to the real HUD. The v1 direction is a **CRT /
green-phosphor overlay that keeps Blizzard's icons and tints them in place**
(`/cdmp crt`); the older "no-icons, solid color block" experiments (`/cdmp skin`,
`/cdmp resource`) are kept as reference, not the direction.

Target spec for v1 experiments: **Demonology Warlock**.

Design context + status live in the parent workspace at
`projects/cooldown-hud/docs/` (`spec.md` vision · `notes.md` technical findings ·
`milestones.md` roadmap) — not this repo.

## Commands (`/cdmp <cmd>`, alias `/cdmprobe`)

- `dump` — introspect the live API: viewer frames, item frames, resolved
  spellIDs, item anatomy, and which APIs (`C_CooldownViewer`, Secret Values)
  exist. Run **out of combat and again in combat** to see what turns `<secret>`.
- `crt` — **the v1 direction (M1 prototype).** Keeps the Essential/Utility icons
  and desaturates + green-tints them in place; DUMMY 4-letter labels / keybinds /
  block-char meters; scanline+vignette overlay; a viewer-anchored Soul Shard rail;
  a `DEMONOLOGY.SYS` terminal frame. Tint persists via per-item leaf-method hooks
  (no white flash). `crt status` prints the F1–F5 feasibility verdicts.
- `skin` — *(reference, retired direction)* hide icons on Essential+Utility, paint
  solid color blocks + labels, keep Blizzard's secure cooldown swipe.
- `resource` — *(reference, retired direction)* resource-centric skin: group-color
  blocks + 4-letter labels, recolored BuffBar duration bars, and a Soul Shard rail
  we own (fill, generate→spend→cap recolor, cap flash + spark + earcon).
- `shards` — draggable Soul Shard bar; Secret-Values-aware (flips to `<secret>`
  if the value is unreadable in restricted combat).
- `layout` — probe whether `C_CooldownViewer.SetLayoutData()` is addon-writable
  (auto-apply viability); `layout write` attempts the safe round-trip OOC.
- `casts` — log player casts to test whether the spellID is readable in combat
  (decides roll-your-own cooldown timers).
- `secret` — on-demand probe of which values are secret right now.
- `log` — event logger (CDM data-loaded, glow show/hide = proc detection test).
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
    Viewers.lua                   locate viewers, enumerate items, `dump`
    Skin.lua                      color-block skin experiment (retired direction)
    Probes.lua                    shard bar, `secret`, `log`, `casts`, `reset`
    Resource.lua                  resource-centric skin: group-color blocks +
                                  duration bars + soul-shard rail (`resource`)
    Layout.lua                    `layout` probe: is SetLayoutData addon-writable?
    CRT.lua                       the v1 CRT/green-phosphor prototype (`crt`) —
                                  keep+tint icons, leaf-hook persistence, chrome
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
6. **Deploy**: `cd ../../../addon-manager && python3 -m ghaddons.cli update michac/CDMProbe`
   (first time: `... add michac/CDMProbe` then `... install michac/CDMProbe`).
7. In-game: `/reload`, then `/cdmp help`.

## Conventions

- **Interface version** tracks the live patch. 12.0.7 = `120007`.
- **Tag = `.toc` version**, prefixed `v` (`## Version: 0.1.0` → tag `v0.1.0`).
- SavedVariables: `CDMProbeDB`.

## In-game smoke test (v0.1 — probe)

Deploy a build (`ghaddons update michac/CDMProbe` → `/reload`), then:

1. `/cdmp dump` **out of combat** → the four viewers are found, items list with
   real spellIDs + names, item anatomy fields print. Note the `C_CooldownViewer`
   function list and whether the Secret Values API is present.
2. `/cdmp skin` → Essential + Utility icons become color blocks with 4-letter
   labels; the cooldown swipe still animates over them. Toggle off → icons back.
3. `/cdmp shards` → shard bar appears; spend/generate shards out of combat and
   watch it track. Drag to reposition (persists).
4. Pull a **target dummy**. `/cdmp secret` **in combat** and `/cdmp dump` in
   combat → record which values read `<secret>` (esp. Soul Shards, cooldown
   duration, aura expirationTime). This answers the open "are shards secret in
   instanced combat" question — note dummies are open-world, so also test inside
   a M+/raid to be sure.
5. `/cdmp log` → cast to proc **Demonic Core**; check whether
   `GLOW SHOW … (id=…)` prints the proc's spellID (proc-detection viability).
6. `/cdmp reset` → everything clears cleanly.

Report findings back to the parent workspace to shape the real HUD.
