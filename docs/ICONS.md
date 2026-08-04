# Icon pipeline - Half-Life old-Mac port

Read this if you touch `scripts/make-icon.py` or regenerate `Half-Life.icns`.

## Current icons

Three pieces of artwork, three uses, no repeats: two apps ship side by side and
must be tellable apart in the Dock, and the installer's About picture should not
restate that app's own icon.

| File | Used for | Source |
|---|---|---|
| `MacOSX/Half-Life.icns` | `Half-Life.app` | `icon-source-lrz.png` (the bust) |
| `MacOSX/Half-Life-Mods.icns` | `Half-Life Mods.app` | `icon-source-gordon-gravity-gun.png` |
| `installer/About-Gordon.png` | the mod installer's About box | `icon-source-gordon-crowbar.png` |

The bust reads better at 32×32 and 16×16 than a full figure, which is most of what
the Dock and Finder draw, and it shipped before v1.2.0. The full-figure sources
are 1086×1448 on solid black; `icon-source-lrz.png` is 1169×1346, also on black.

### Sizes shipped, and the Panther ceiling

Both `.icns` carry the legacy chunks (16/32/48/128) **plus `ic08`, a 256×256
PNG**, so 10.5 and later render 256 natively instead of upscaling the 128×128
`it32`. Nothing larger ships: a hardware finding, from five identical test bundles
differing only in their icon, on the G3 on 10.3.9:

| Chunks | Panther Finder |
|---|---|
| legacy only | icon renders |
| legacy + `ic08` (256) | icon renders |
| legacy + `ic08` + `ic09` | **generic icon** |
| legacy + `ic09` (512) alone | **generic icon** |
| legacy + `ic08` + `ic09` + `ic10` | **generic icon** |

The fallback to the generic application icon is silent, so this regression ships
unnoticed. Whether Panther rejects the `ic09` FourCC or just refuses a larger file
was not separated: `ic09`-only was 431 KB against 160 KB for `ic08`, and no 512px
PNG of this artwork compresses near 160 KB. Above 256, Lion and later upscale.

`--modern` adds `ic08`. Use `--base <existing.icns>` to append it to an approved
icon rather than regenerate: Pillow's resampling has drifted between versions, so
a rebuild is not byte-for-byte.

**The About picture is not made by this pipeline.** It is a cut-out:
`scripts/make-about-art.py` removes the black backdrop and trims to the figure,
for compositing onto a grey window rather than a rounded tile. Task #45 covers why
it had to be a border flood-fill, not a colour key.

### Two things that are NOT optional for this artwork

**1. Crop to square first.** `make-icon.py` resizes with `img.resize((size,size))`,
a non-uniform squash: a 3:4 portrait compresses Gordon horizontally by a third.

    .venv/bin/python -c "
    from PIL import Image
    Image.open('MacOSX/icon-source-gordon-crowbar.png').convert('RGB').crop((50,5,745,700)).save('/tmp/crowbar-sq.png')
    Image.open('MacOSX/icon-source-gordon-gravity-gun.png').convert('RGB').crop((240,20,915,695)).save('/tmp/gg-sq.png')"

The crops keep the whole weapon plus head and lambda plate, head at ~16% of frame
in *both* so the icons share a visual scale. The largest size that reaches every
machine is 256, where a full-body figure is an unreadable smudge.

**2. The thresholds under "Background removal" are WRONG for these two renders.**
`--soft 239 --hard 247 --top-seed --fill-holes` puts a hole through Gordon's
shadowed pec and speckles the hair, exactly the failure that section warns about.
Here the background is max-channel **0-1** and the darkest suit shadow is **2**,
so a "≤8 is background" rule eats the suit: the LRZ render needed ≤8, these need
≤4.

    # the mod installer icon - straight through the tool
    .venv/bin/python scripts/make-icon.py /tmp/gg-sq.png \
        --bg black --soft 251 --hard 254 --modern \
        --preview /tmp/gg-preview.png -o MacOSX/Half-Life-Mods.icns

The game icon is the LRZ bust, not the crowbar render, and its operating point
differs again. It **needs `--top-seed`**: the bust's shoulders run off the bottom
and both sides and are near-black, so seeding from every edge lets the fill walk
in through them. On the 256px chunk the lower body goes from **88.8% opaque to
99.8%**; the missing 11% was semi-transparent shoulder, visible as background
through the suit at 256, invisible at 128px, and it shipped briefly before being
caught by eye on an Intel machine.

    .venv/bin/python scripts/make-icon.py MacOSX/icon-source-lrz.png \
        --bg black --hard 250 --soft 246 --top-seed --fill-holes \
        --base <the previous .icns> -o MacOSX/Half-Life.icns

For the two full-figure renders at the tighter threshold, `--top-seed` and
`--fill-holes` are harmful and are dropped. The difference is framing, not
artwork: the bust leaves the frame on three sides, they do not.

- `--top-seed` leaves a solid black slab in the crowbar image's bottom-right, a
  pocket bounded by the outstretched arm, the torso and the unseeded bottom and
  right edges. Seeding all edges removes it; the eaten-shoulders risk `--top-seed`
  guards against came from the *loose* threshold, not the seeding.
- `--fill-holes` re-fills the gravity gun's see-through prong cage.

The prong cage needs a hand touch-up: `--scrub-interior`'s annulus-darkness test
measures 210-230 there against a required `< 150`, so it finds nothing at any
size. Same Photoshop workflow as below, done in numpy; git log has the exact
seeded punch.

**Verify over magenta and white** (`--preview`) by *looking*: no holes in suit,
hair or shoulders, no black fringe. Then render the `.icns` back with `sips` and
check 128 and 64.

Known imperfection: a faint grainy edge above the crowbar shoulder and along the
prongs, from a mottled 1-4 halo a 3-level ramp can't feather. Invisible at 128px
and below; a fix needs a spatially-varying ramp (`--ramp-soft`), which does not
exist yet.

## Provenance

The **game** icon `MacOSX/icon-source-lrz.png` is an AI-edited derivative of Little
Red Zombies' "HλLF-LIFE: Gordon (UE4)" MetaHuman render, not that render as
published. The **mod installer** icon and its About picture are **AI-generated**
images of Gordon Freeman made for this project in 2026-07:
`MacOSX/icon-source-gordon-gravity-gun.png` and
`MacOSX/icon-source-gordon-crowbar.png`.

Gordon Freeman is Valve's character; this is a non-commercial fan project, and any
of this artwork comes out or gets replaced on request. The Half-Life-wiki stand-in
once kept beside the LRZ render as a rights-clean fallback was **removed in
v1.2.0**, recoverable from git history (`MacOSX/icon-wiki.icns`,
`MacOSX/icon-source-wiki.png`).

### Files

| File | What |
|---|---|
| `MacOSX/Half-Life.icns` | shipped game icon |
| `MacOSX/Half-Life-Mods.icns` | shipped installer icon |
| `MacOSX/icon-source-lrz.png` | game artwork of record, 1169×1346 (black bg) |
| `MacOSX/icon-source-gordon-gravity-gun.png` | installer icon artwork of record, 1086×1448 (black bg) |
| `MacOSX/icon-source-gordon-crowbar.png` | installer About-box artwork, same |

### Where each is consumed

- `Half-Life.icns`: `make-dmg.sh` copies it into the staged bundle on every
  release, so an icon change reaches the DMG **without** a full engine rebuild.
  `make-app.sh` also takes one as its optional third argument.
- `Half-Life-Mods.icns`: `build-installer.sh` copies it in and sets
  `CFBundleIconFile`. Missing file = generic app icon, never a failed build.

## Generating

    .venv/bin/python scripts/make-icon.py <source.png> --keep-bg

`--keep-bg` when the source already carries alpha; drop it (or pass
`--bg white|black`) for a solid background.

## Background removal

`make-icon.py` ships **conservative defaults**: edge flood fill that preserves all
interior detail, no auto-scrubbing of interior bg-coloured pockets.
`--scrub-interior` exists for artwork with bg leaking through logo glyph gaps or
detail-sparse areas, but its heuristics (size, score-purity, annulus darkness)
can't reliably tell bg-bleed from saturated specular highlights on metal.

**Use Photoshop touch-up over algorithmic perfection**, rather than tuning
`--scrub-interior` for new artwork:

1. Run `make-icon.py` with defaults for a conservative transparent-bg master plus
   a magenta-composited preview (`--preview`).
2. In Photoshop, paint any visible bg pockets to alpha=0, preview as guide.
3. Save back as RGBA PNG and hand it to `--keep-bg` to regenerate the ICNS without
   re-running bg removal.
