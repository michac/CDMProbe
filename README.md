# CDMProbe

An experimental World of Warcraft addon that probes what's possible on top of
Blizzard's built-in **Cooldown Manager** under Midnight (12.0) — a kitchen sink
for testing a condensed, **no-icons / color-coded** cooldown HUD before building
the real thing. Target spec for v1: **Demonology Warlock**.

> ⚠️ This is a research/experiment addon, not a polished product. It changes how
> the Cooldown Manager looks and prints diagnostics to chat. Everything is
> reversible with `/cdmp reset`.

## Install

Via [`ghaddons`](https://github.com/michac) (the GitHub-driven addon manager),
or manually: drop the `CDMProbe/` folder into
`World of Warcraft/_retail_/Interface/AddOns/` and `/reload`.

## Usage

`/cdmp help` lists everything. The interesting ones:

| Command | What it does |
| --- | --- |
| `/cdmp dump` | Introspects the live viewer frames, item spellIDs, item anatomy, and which APIs (incl. Secret Values) exist. Run in and out of combat. |
| `/cdmp skin` | Hides icons on the Essential + Utility viewers and paints solid **color blocks** with labels, keeping Blizzard's secure cooldown swipe. |
| `/cdmp shards` | A draggable Soul Shard bar that flips to `<secret>` if the value can't be read in restricted combat. |
| `/cdmp secret` | On-demand test of which values (shards, cooldowns, auras) are Secret Values right now. |
| `/cdmp log` | Logs Cooldown-Manager + proc-glow events (tests whether we can detect procs like Demonic Core). |
| `/cdmp reset` | Turns every experiment back off. |

## Why

Midnight's **Secret Values** system stops addons from *reading* personal combat
state to branch on it in instanced content, while still letting them *display*
it through Blizzard-sanctioned pipes. This addon exists to find, empirically and
at a target dummy, exactly where that line is — and how a minimal color-coded
skin over the stock Cooldown Manager looks and behaves.

## License

MIT. Developed with EnhancedCooldownManager (GPL-3.0) read as an API reference
only; no code copied.
