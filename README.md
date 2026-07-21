# CDMProbe

An experimental World of Warcraft addon that probes what's possible on top of
Blizzard's built-in **Cooldown Manager** under Midnight (12.0) — a kitchen sink
for prototyping a condensed, glanceable cooldown HUD before building the real
thing — and now also the real HUD itself (`/cdmp hud`). The v1 direction is a
**terminal / CRT-flavoured overlay that leaves Blizzard's icons completely
untouched** and builds all its value-add in the chrome around them (not a
replacement UI). Target spec for v1: **Demonology Warlock**.

> ⚠️ This is a research/experiment addon, not a polished product. It restyles the
> Cooldown Manager and prints diagnostics to chat. Everything is reversible with
> `/cdmp reset`.

## Install

Via [`ghaddons`](https://github.com/michac) (the GitHub-driven addon manager),
or manually: drop the `CDMProbe/` folder into
`World of Warcraft/_retail_/Interface/AddOns/` and `/reload`.

## Usage

`/cdmp help` lists everything. The interesting ones:

| Command | What it does |
| --- | --- |
| `/cdmp hud` | **The real HUD (v1).** Binds per item to the *live* Cooldown Manager layout by `cooldownID` and draws terminal chrome around Blizzard's untouched icons: group-colour accents with a generator/consumer batch tint, real keybinds, a scanline overlay and a `DEMO.SYS` terminal frame. Since v0.7.0 it also carries **state**: a ready accent off the observed ready edge, proc glows for Demonic Core (on Demonbolt) and Demonic Art (on the transformed button), and an empty-board recede. `/cdmp hud status` prints the bind + state readout. |
| `/cdmp probe` | **Every probe, one report, written to disk.** Environment + viewer/item anatomy, the secret map, cooldown readability per tracked spell, spell-override/transform capture, per-phase cast-spellID readability, and the imp-count side channel — plus the HUD's own state block. Passive recorders run from load, so nothing has to be armed in advance. Run once out of combat, once in combat, then `/reload` and read `CDMProbeDB.reports` from SavedVariables. `probe clear` resets the counters. |
| `/cdmp skin` · `/cdmp resource` | Earlier "solid color block" skin experiments, kept as reference (superseded by `hud`). |
| `/cdmp reset` | Turns every experiment back off. |

## Why

Midnight's **Secret Values** system stops addons from *reading* personal combat
state to branch on it in instanced content, while still letting them *display*
it through Blizzard-sanctioned pipes. This addon exists to find, empirically and
at a target dummy, exactly where that line is — and how a minimal skin over the
stock Cooldown Manager looks and behaves. The overlay owns what it can read
(soul shards, proc presence, layout, keybinds, chrome) and borrows Blizzard's
secure widgets for what it can't (cooldown/aura timers, icon art).

## License

MIT. Developed with EnhancedCooldownManager (GPL-3.0) read as an API reference
only; no code copied.
