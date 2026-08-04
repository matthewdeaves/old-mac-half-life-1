# Icon pipeline philosophy - Half-Life old-Mac port

Read this if you touch `scripts/make-icon.py` or regenerate `Half-Life.icns`.

## Current icons

Three pieces of artwork, three distinct uses, and deliberately no repeats. Two
icons ship because two apps ship, and they sit in the same folder and must be
tellable apart in the Dock; the mod installer's About picture should not simply
restate that app's own icon.

| File | Used for | Source |
|---|---|---|
| `MacOSX/Half-Life.icns` | `Half-Life.app` | `icon-source-lrz.png` (the bust) |
| `MacOSX/Half-Life-Mods.icns` | `Half-Life Mods.app` | `icon-source-gordon-gravity-gun.png` |
| `installer/About-Gordon.png` | the mod installer's About box | `icon-source-gordon-crowbar.png` |

The game app uses the head-and-shoulders bust. It reads far better at 32×32 and
16×16 than a full figure does, which is most of what the Dock and the Finder
actually draw, and it is the icon the project shipped before v1.2.0.

The two full-figure sources are 1086×1448 portrait renders on solid black. The
third, `icon-source-lrz.png`, is 1169×1346 and also on black.

### Sizes actually shipped, and the Panther ceiling

Both `.icns` carry the legacy chunks (16/32/48/128) **plus `ic08`, a 256×256
PNG**, so 10.5 and later render 256 natively instead of upscaling the 128×128
`it32`. Nothing larger ships, and that is a hardware finding rather than a
preference. Five identical test bundles differing only in their icon, on the G3
on 10.3.9:

| Chunks | Panther Finder |
|---|---|
| legacy only | icon renders |
| legacy + `ic08` (256) | icon renders |
| legacy + `ic08` + `ic09` | **generic icon** |
| legacy + `ic09` (512) alone | **generic icon** |
| legacy + `ic08` + `ic09` + `ic10` | **generic icon** |

Panther falling back to the generic application icon is silent, so this is the
kind of regression that ships unnoticed. Whether it rejects the `ic09` FourCC
or simply refuses a larger file was not separated: the `ic09`-only file was
431 KB against 160 KB for the `ic08` one. It makes no practical difference, as
no 512px PNG of this artwork compresses near 160 KB.

Above 256, Lion and later still upscale. `--modern` is what adds `ic08`; use
`--base <existing.icns>` to append it to an already-approved icon rather than
regenerating, because Pillow's resampling has drifted between versions and a
rebuild does not reproduce a previously shipped file byte-for-byte.

**The About picture is not made by this pipeline.** It is a cut-out, not an icon:
`scripts/make-about-art.py` removes the black backdrop and trims to the figure,
because it is composited onto a grey window rather than a rounded icon tile. See
task #45 for why that had to be a border flood-fill rather than a colour key.

### Two things that are NOT optional for this artwork

**1. Crop to square first.** `make-icon.py` resizes with `img.resize((size,size))`,
which is a *non-uniform* squash. Handing it a 3:4 portrait compresses Gordon
horizontally by a third. Crop to a square before calling it:

    .venv/bin/python -c "
    from PIL import Image
    Image.open('MacOSX/icon-source-gordon-crowbar.png').convert('RGB').crop((50,5,745,700)).save('/tmp/crowbar-sq.png')
    Image.open('MacOSX/icon-source-gordon-gravity-gun.png').convert('RGB').crop((240,20,915,695)).save('/tmp/gg-sq.png')"

The crops keep the whole weapon plus head and lambda plate, and put the head at
~16% of frame in *both* so the two icons sit at the same visual scale. This is
also a legibility decision: the largest size that reaches every machine is 256
(see above), and a full-body figure at that size is an unreadable smudge.

**2. The threshold in the section below is WRONG for these two renders.** Using
`--soft 239 --hard 247 --top-seed --fill-holes` on them reproduces exactly the
failure that section warns about - a hole through Gordon's shadowed pec and
speckled hair. The reason is measurable: in *this* artwork the true background is
max-channel **0-1** while the darkest suit shadow bottoms out at **2**, so a
"≤8 is background" rule eats the suit. The LRZ render needed ≤8; these need ≤4.

    # the mod installer icon - straight through the tool
    .venv/bin/python scripts/make-icon.py /tmp/gg-sq.png \
        --bg black --soft 251 --hard 254 --modern \
        --preview /tmp/gg-preview.png -o MacOSX/Half-Life-Mods.icns

The game icon is NOT built from the crowbar render. It is the LRZ bust, whose
own operating point is different again, and which **needs `--top-seed`** where
the two full-figure renders must not have it:

    .venv/bin/python scripts/make-icon.py MacOSX/icon-source-lrz.png \
        --bg black --hard 250 --soft 246 --top-seed --fill-holes \
        --base <the previous .icns> -o MacOSX/Half-Life.icns

`--top-seed` matters because the bust's shoulders run off the bottom and both
sides of the frame, and they are near-black. Seeding the flood-fill from every
edge lets it walk in from the background straight through them. Measured on the
256px chunk, the lower body goes from **88.8% opaque to 99.8%** when `--top-seed`
is added; the missing 11% was semi-transparent shoulder, plainly visible as
background showing through the suit once the icon is drawn at 256.

That defect shipped briefly and was caught by eye on an Intel machine viewing
the icon large. It is invisible at 128px, so the legacy chunks never showed it.
At that tighter threshold `--top-seed` and `--fill-holes` become actively
harmful for **these two renders** and are dropped. Note this is the opposite of
what the LRZ bust needs, above: the difference is framing, not artwork. The bust
is cropped so the subject leaves the frame on three sides, the full-figure
renders are not.

- `--top-seed` leaves a solid black slab in the crowbar image's bottom-right - a
  background pocket bounded by the outstretched arm, the torso, and the unseeded
  bottom/right edges. Seeding from all edges removes it, and the eaten-shoulders
  risk that `--top-seed` existed to avoid does not materialise here, because it
  was a consequence of the *loose* threshold, not of the seeding.
- `--fill-holes` re-fills the gravity gun's prong cage, which is see-through.

The gravity-gun icon needs one hand touch-up for that cage - `--scrub-interior`
cannot do it (its annulus-darkness test measures 210-230 there against a required
`< 150`, so it finds nothing at any size). That is the Photoshop-touch-up
workflow this document already prescribes, just done in numpy. See the git log
for the exact seeded punch.

**Verify by compositing over magenta and white** (`--preview`) and *looking*: no
holes in suit/hair/shoulders, no black fringe. Then render the finished `.icns`
back with `sips` and check it still reads at 128 and 64.

Known imperfection: a faint grainy edge above the crowbar shoulder and along the
prongs, from a mottled 1-4 halo in the renders that a 3-level ramp can't feather.
Invisible at 128px and below. A proper fix needs a spatially-varying ramp
(`--ramp-soft`), which does not exist yet.

## Provenance

The two are not the same, and the difference matters when crediting them.

The **game** icon, `MacOSX/icon-source-lrz.png`, is an AI-edited derivative of
Little Red Zombies' "HλLF-LIFE: Gordon (UE4)" MetaHuman render, not that render
as published. It is the icon this project shipped before v1.2.0 and still ships.

The **mod installer** icon and its About picture are **AI-generated** images of
Gordon Freeman, made for this project in 2026-07:
`MacOSX/icon-source-gordon-gravity-gun.png` and
`MacOSX/icon-source-gordon-crowbar.png`.

Gordon Freeman is Valve's character; this is a non-commercial fan project, and
any of this artwork comes out or gets replaced on request.

The Half-Life-wiki stand-in once kept beside the LRZ render as a rights-clean
fallback was **removed in v1.2.0** and is recoverable from git history
(`MacOSX/icon-wiki.icns`, `MacOSX/icon-source-wiki.png`).

### Files

| File | What |
|---|---|
| `MacOSX/Half-Life.icns` | shipped game icon |
| `MacOSX/Half-Life-Mods.icns` | shipped installer icon |
| `MacOSX/icon-source-lrz.png` | game artwork of record, 1169×1346 (black bg) |
| `MacOSX/icon-source-gordon-gravity-gun.png` | installer icon artwork of record, 1086×1448 (black bg) |
| `MacOSX/icon-source-gordon-crowbar.png` | installer About-box artwork, same |

### Where each is consumed

- `Half-Life.icns` - `make-dmg.sh` copies it into the staged bundle on every
  release, so an icon change reaches the DMG **without** a full engine rebuild.
  `make-app.sh` also takes one as its optional third argument.
- `Half-Life-Mods.icns` - `build-installer.sh` copies it in and sets
  `CFBundleIconFile`. Missing file = generic app icon, never a failed build.

## Generating

    .venv/bin/python scripts/make-icon.py <source.png> --keep-bg

`--keep-bg` when the source already carries an alpha channel; drop it (or pass
`--bg white|black`) for a source with a solid background.

## Background removal

`scripts/make-icon.py` ships **conservative defaults**: edge-flood-fill
bg removal that preserves all interior detail, no auto-scrubbing of
interior bg-coloured pockets. The `--scrub-interior` knob exists for
artwork that has bg leaking through logo glyph gaps or detail-sparse
areas, but the heuristics (size + score-purity + annulus darkness) can't
reliably distinguish bg-bleed from saturated specular highlights on
metallic surfaces.

**Use Photoshop touch-up over algorithmic perfection.** The proven workflow:
1. Run `make-icon.py` with defaults to produce a conservative
   transparent-bg master + a magenta-composited preview (`--preview`).
2. Open the master in Photoshop, paint any visible bg pockets to alpha=0
   using the magenta preview as a guide.
3. Save back as RGBA PNG, hand it back via `--keep-bg` to regenerate the
   ICNS without re-running bg removal.

Don't burn cycles trying to make `--scrub-interior` work perfectly on a
new artwork - if defaults leave visible bg pockets, ship to Photoshop.
