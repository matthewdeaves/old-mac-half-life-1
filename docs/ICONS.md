# Icon pipeline - Half-Life old-Mac port

Read this if you touch `scripts/make-icon.py` or regenerate `Half-Life.icns`.

## Current icons

Four pieces of artwork, four uses, no repeats: three apps ship side by side and
must be tellable apart in the Dock, and the installer's About picture should not
restate that app's own icon.

Since 2026-08 all three app icons come from the **new half-machine busts**
(`*-new.png`), cut out with `make-icon-mask.py` and verified over magenta. The
older sources below are kept as artwork of record and are no longer what ships.

| File | Used for | Source |
|---|---|---|
| `MacOSX/Half-Life.icns` | `Half-Life.app` | `icon-source-halflife-new.png`, HEV suit and orange lambda |
| `MacOSX/Half-Life-Mods.icns` | `Half-Life Mods.app` | `icon-source-mods-new.png`, hard hat and hi-vis |
| `MacOSX/Half-Life-SysReport.icns` | `Half-Life System Report.app` | `icon-source-sysreport-new.png`, lab coat |
| `installer/About-Gordon.png` | the mod installer's About box | `icon-source-gordon-crowbar-new.png` |

The System Report app used to share the game's icon, on the argument that it was
one less piece of artwork to keep in step. That was reversed: the app someone
runs when the game will not start is the worst one to leave looking like the
game. `docs/adr/0010`.

The bust reads better at 32×32 and 16×16 than a full figure, which is most of
what the Dock and Finder draw. The older full-figure sources are 1086×1448 on
solid black; `icon-source-lrz.png` is 1169×1346, also on black.

**The Mods artwork is the useful test of the seeding rule**: its hi-vis jacket
reaches the bottom corners of the frame, which are therefore NOT background.
Seeding the flood fill from the bottom edge would have eaten it. Top-and-upper-
sides seeding handles it with no special case.

**The About box aspect is not free to change.** It went from 0.518 to 0.611 with
the new crowbar art, so the button frame goes from 124x240 to 135x220 points.
Without that the image is forced into the old frame and stretched, the same
defect that was fixed once before at 147x240.

### Sizes shipped, and the Panther ceiling

Both `.icns` carry the legacy chunks (16/32/48/128) **plus `ic08`, a 256×256
PNG**, so 10.5 and later render 256 natively instead of upscaling the 128×128
`it32`. Nothing larger ships, measured on the G3 on 10.3.9:

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
99.8%**; without it the shoulder is semi-transparent, visible as background
through the suit at 256 and invisible at 128px.

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

### The new-artwork game icon (icon-source-halflife-new.png)

The 2026-08 regeneration from the new HEV bust shipped with the shoulders eaten
through again, reported from the G3 Finder and obvious over magenta: 2503
partial-alpha pixels inside the lower half of the 256 chunk against 789 for a
clean cut (789 is just the silhouette's anti-aliased edge). The mask tool was
not at fault; a fresh `make-icon-mask.py` cut of the same source is solid at any
threshold, so the damage rode in through a stale or reprocessed intermediate.
The recipe that produced the current shipped icns, verified over magenta at
256 and 128 and chunk-checked Panther-safe:

    .venv/bin/python scripts/make-icon-mask.py MacOSX/icon-source-halflife-new.png \
        --thresh 2 -o /tmp/hl-cut.png --preview /tmp/hl-prev.png
    # square crop BEFORE assembly (the resize is non-uniform, see above):
    .venv/bin/python -c "from PIL import Image; \
        Image.open('/tmp/hl-cut.png').crop((0,120,1169,1289)).save('/tmp/hl-cut-sq.png')"
    .venv/bin/python scripts/make-icon.py /tmp/hl-cut-sq.png --keep-bg --modern \
        -o MacOSX/Half-Life.icns

LOOK at the preview before assembling, and LOOK at the icns composited over
magenta after: the holes are invisible against the black backdrop they were cut
from, which is how they survived review twice before.

Known imperfection: a faint grainy edge above the crowbar shoulder and along the
prongs, from a mottled 1-4 halo a 3-level ramp can't feather. Invisible at 128px
and below; a fix needs a spatially-varying ramp (`--ramp-soft`), which does not
exist yet.

## Provenance

`MacOSX/icon-source-lrz.png`, the game icon through 2026-07, is an AI-edited
derivative of Little Red Zombies' "HλLF-LIFE: Gordon (UE4)" MetaHuman render, not
that render as published. `MacOSX/icon-source-gordon-gravity-gun.png` and
`MacOSX/icon-source-gordon-crowbar.png`, the mod installer's icon and About
picture over the same period, are **AI-generated** images of Gordon Freeman made
for this project in 2026-07.

**The four `*-new.png` sources that ship today have no provenance recorded
anywhere in this repository.** They are AI-generated or AI-edited like the ones
above (INFERRED from the same workflow and from the commit that introduced them,
`3db1b81`), but which of the two, and from what if anything they derive, is not
written down. That needs establishing and recording here, because the README
makes a public attribution claim about the game icon and it currently describes
the superseded artwork.

Gordon Freeman is Valve's character; this is a non-commercial fan project, and any
of this artwork comes out or gets replaced on request. A rights-clean stand-in
is recoverable from git history (`MacOSX/icon-wiki.icns`,
`MacOSX/icon-source-wiki.png`).

### Files

| File | What |
|---|---|
| `MacOSX/Half-Life.icns` | shipped game icon |
| `MacOSX/Half-Life-Mods.icns` | shipped installer icon |
| `MacOSX/Half-Life-SysReport.icns` | shipped System Report icon |
| `MacOSX/icon-source-halflife-new.png` | game artwork of record, what ships |
| `MacOSX/icon-source-mods-new.png` | installer icon artwork of record, what ships |
| `MacOSX/icon-source-sysreport-new.png` | System Report artwork of record, what ships |
| `MacOSX/icon-source-gordon-crowbar-new.png` | installer About-box artwork, what ships |
| `MacOSX/icon-source-lrz.png` | superseded game artwork, 1169×1346 (black bg) |
| `MacOSX/icon-source-gordon-gravity-gun.png` | superseded installer artwork, 1086×1448 (black bg) |
| `MacOSX/icon-source-gordon-crowbar.png` | superseded About-box artwork, same |

### Where each is consumed

- `Half-Life.icns`: `make-dmg.sh` copies it into the staged bundle on every
  release, so an icon change reaches the DMG **without** a full engine rebuild.
  `make-app.sh` also takes one as its optional third argument.
- `Half-Life-Mods.icns`: `build-installer.sh` copies it in and sets
  `CFBundleIconFile`. Missing file = generic app icon, never a failed build.
- `Half-Life-SysReport.icns`: `scripts/build-sysreport.sh:128-133`, same
  arrangement and the same silent fallback.

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
