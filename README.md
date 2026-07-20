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
| `/cdmp hud` | **The real HUD (v1).** Binds per item to the *live* Cooldown Manager layout by `cooldownID` and draws terminal chrome around Blizzard's untouched icons: group-colour accents with a generator/consumer batch tint, real keybinds, a scanline overlay and a `DEMO.SYS` terminal frame. `/cdmp hud status` prints the bind readout. |
| `/cdmp dump` | Introspects the live viewer frames, item spellIDs, item anatomy, and which APIs (incl. Secret Values) exist. Run in and out of combat. |
| `/cdmp shards` | A draggable Soul Shard bar that flips to `<secret>` if the value can't be read in restricted combat. |
| `/cdmp layout` | Probes whether `C_CooldownViewer.SetLayoutData()` is addon-writable (auto-apply viability). |
| `/cdmp casts` | Logs player casts to test whether the spellID is readable in combat (for roll-your-own cooldown timers). |
| `/cdmp secret` | On-demand test of which values (shards, cooldowns, auras) are Secret Values right now. |
| `/cdmp log` | Logs Cooldown-Manager + proc-glow events (tests whether we can detect procs like Demonic Core). |
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
