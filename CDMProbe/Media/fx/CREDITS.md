# `Media/fx/` — third-party assets for the `/cdmp rt fx` experiments

Candidate glow art and cue sounds for the "the cues read too subdued in play"
investigation. **Experimental**: these are here to be A/B'd against Blizzard's own
atlases and SoundKit entries, and most of them will lose. Prune to the winner before
any of this is promoted out of the render-test rig.

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
| `sfx/`  | Interface Sounds (100 sounds) | <https://kenney.nl/assets/interface-sounds> |

## `glow/` — ring/burst art, 128×128 32-bit RLE TGA

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
and `question_001` are alternates with different attack characters.
