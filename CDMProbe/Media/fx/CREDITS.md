# `Media/fx/` — third-party assets

Glow art and cue sounds for the "the cues read too subdued in play" investigation.

**Three of these are no longer experimental — they ship.** `glow/star_07.tga` is the
Renderer's cue ring (`GLOW_ART`), and `sfx/drawKnife1.ogg` + `sfx/chip-lay-1.ogg` are the
two cue sounds the live HUD plays (`HudDriver.lua`). Everything else in here is still a
candidate that lost, kept because `/cdmp rt fx` is the rig for the next round of dialling.
**Do not prune the shipped three.**

## Licence — CC0 1.0 Universal (public domain)

Everything in this folder is by **Kenney** (<https://kenney.nl>), released under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). CC0 imposes **no
attribution requirement**, so this file is provenance for us, not a licence obligation
— it is recorded because CDMProbe is MIT and a reader should be able to tell at a
glance that the binaries in the tree are safe to ship. Nothing here is GPL, nothing
here is Blizzard art.

| folder | source pack | upstream |
|---|---|---|
| `glow/` | Particle Pack (80 sprites) | <https://kenney.nl/assets/particle-pack> |
| `sfx/confirmation_*`, `bong_*`, `select_*`, `question_*` | Interface Sounds (100 sounds) | <https://kenney.nl/assets/interface-sounds> |
| `sfx/drawKnife1.ogg` | RPG Audio (50 sounds) | <https://kenney.nl/assets/rpg-audio> |
| `sfx/chip-lay-1.ogg` | Casino Audio (54 sounds) | <https://kenney.nl/assets/casino-audio> |

## `glow/` — ring/burst art, 128×128 32-bit RLE TGA

**`star_07.tga` is the shipped cue ring** (Renderer.lua `GLOW_ART`). It replaced
Blizzard's `services-ring-large-glowspin` atlas for the reason the next paragraph but one
gives: that atlas is gold, `SetVertexColor` multiplies, and our violet emphasis token
multiplied most of it away.

⚠ **These sprites differ in ROTATIONAL SYMMETRY, and that changes how fast a spin reads**
— perceived rate is angular velocity × symmetry order (how often a spoke passes a fixed
point), so swapping between two of them invalidates `SPIN_SECS` as surely as it
invalidates `GLOW_SCALE`. Measured from the alpha channel (angular-energy profile →
dominant Fourier order), for whoever dials the next one:

| sprite | order | reads as |
|---|---|---|
| `twirl_01` / `twirl_03` | **k=1** | one swept arm — a slow sweep at any period |
| `light_01` | k≈5, weak (0.12) | near-symmetric: rotation is almost invisible |
| `magic_05` | k=4 (0.30) | mild |
| `star_09` | k=6 (0.31) | mild |
| `star_04` | k=4 (0.91) | strong 4-point |
| **`star_07`** ← shipped | **k=8** (0.92) | 8 points, alternating long/short (hence k=4 + k=16 harmonics) |

star_07 at the pre-swap 4.0 s period put a spoke past every 0.5 s and read as a strobe;
it ships at **12.0 s** (~1.5 s per spoke). Blizzard's ring, being a swept gradient, sits
down with the twirls.

Converted from the upstream 512×512 PNGs. Two deliberate changes:

- **PNG → TGA.** The upstream sprites are **palette** PNGs (colortype 3) with `tRNS`
  alpha. WoW documents BLP/JPEG/PNG/TGA at power-of-two sizes, but the PNG path is the
  least-specified of the four and palette+`tRNS` is the variant most likely to be
  refused or to silently lose transparency. 32-bit RGBA TGA is the classic addon format
  with the least doubt, so this converts rather than gambles.
- **512 → 128.** A glow ring draws at ~28 px base, ~38 px escalated, ~110 px at the
  largest `rays` echo. 512² is resolution nothing ever samples and costs 4.8 MiB across
  the set as uncompressed TGA; 128² is comfortably above the largest draw and lands the
  whole set at ~210 KiB. Downscale is an integer 4× box filter — no resampling
  artefacts. (Straight, non-premultiplied average is safe here: the sprites are
  white/grey with the shape carried in **alpha**, so transparent pixels cannot bleed a
  tint.)

They are white/greyscale by design, which is the point — `SetVertexColor` **multiplies**,
so white art keeps full energy in every channel and tints cleanly to any hue. That is
exactly what Blizzard's gold `services-ring-large-glowspin` cannot do: our violet
`ROTATION_FALLBACK` (green channel 0.16) multiplies most of a warm atlas away.

Conversion script: `png2tga.py`, kept beside this file so the derivation is reproducible.

## `sfx/` — cue sounds, Ogg Vorbis

Taken as the upstream **`.ogg`** originals (WoW loads `.ogg` and `.mp3` only — nothing
else). ⚠ The Godot mirrors of this pack on GitHub are transcoded to **WAV** and are
useless here; these came from the `gamesounds.xyz` mirror of the original OGGs.

Kenney normalises this pack's volume, which is the reason it is here: there is **no
volume parameter** anywhere in WoW's sound API (`PlaySound` / `PlaySoundFile` take a
channel, not a gain), so the only real control over "too subtle" is shipping a file
that is already loud.

`confirmation_001`–`004` are the "activated!" candidates; `bong_001`, `select_001/004`
and `question_001` are alternates with different attack characters. **None of them won.**

### The two that ship

The cue sound is **one play per change of the cue set** — measured at ~120 plays over
504 s of real play, one every ~4 s, tracking your casts. So it had to be short, dry and
physical rather than musical: a tone at that cadence becomes a melody you start hearing
instead of a signal you react to.

| file | plays when | upstream name | pack |
|---|---|---|---|
| `drawKnife1.ogg` | the cue set gained something (`"new"`) | `drawKnife1.ogg` | RPG Audio |
| `chip-lay-1.ogg` | the set only lost something (`"gone"`) | `chipLay1.ogg` | Casino Audio |

Both are **CC0 Kenney**, same as the rest of this folder — different packs from the
`glow/` and interface sounds above, so they are listed separately rather than folded into
the one row. Taken as the upstream `.ogg` originals; `chip-lay-1.ogg` is `chipLay1.ogg`
renamed and nothing else (its embedded Vorbis `TITLE` tag still reads `chipLay1`).

⚠ `"gone"` is **rare by construction** and that is correct, not a broken file: the board
never went empty once in those 504 s of pulls, so `chip-lay-1` is mostly an end-of-pull
sound. `/cdmp rt fx sound 1|2` auditions both on demand.
