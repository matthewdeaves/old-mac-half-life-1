#!/usr/bin/env python3
"""
make-icon-mask.py - cut a dark subject off a black backdrop, without eating it.

Produces an RGBA PNG with a correct alpha channel. Feed the result to
make-icon.py --keep-bg, which then just assembles the .icns and does no
background removal of its own.

WHY THIS EXISTS, and why make-icon.py's own stage 1 could not do it

make-icon.py removes a black background by scoring each pixel 255 - max(rgb) and
flood-filling from the image edge. That works for a bright subject. It does NOT
work for this project's artwork, which is a DARK subject ON black: Gordon's hair
is nearly as dark as the backdrop, and the hazard suit is darker still.

Two failures were shipped before this script existed, and they are opposite ends
of the same knob:

  * loose threshold  -> the fill walks from the top edge straight into the hair
                        and feathers the whole subject away. Measured on the
                        256px chunk: only 14.8% of the icon fully opaque and
                        43.1% carrying PARTIAL alpha, which composites to a
                        washed-out grey on a light Finder background and reads
                        as inverted colours.
  * removal disabled -> correct colours but an opaque black square, which is not
                        what an app icon should look like.

The separation is real, it just needs to be made on connectivity rather than on
brightness alone. Measured on icon-source-lrz.png: 33% of the image is exactly
0,0,0 and only 45% is at or below max-channel 4, so backdrop and subject are
cleanly separable if "background" means "dark AND reachable from outside".

WHAT IT DOES

  1. dark      = max(rgb) <= T          (T=10 by default, near-black only)
  2. label the dark pixels, and treat as background ONLY the components that
     touch a seed edge. A dark pocket enclosed by the subject is not background.
  3. binary_fill_holes on the foreground, so any remaining enclosed pocket is
     forced opaque. This is what stops holes appearing in the shoulders.
  4. a short uniform-filter ramp on the background side only, for edge AA. The
     foreground is pinned to 255 so the ramp can never eat into the subject.

SEEDING, which is the part that matters for a bust

--top-seed (default) seeds the flood from the TOP edge and the upper part of the
left and right edges only, never the bottom. These are portraits: the shoulders,
and on the Mods artwork the legs, run right to the bottom of the frame. Seeding
from the bottom edge lets the fill climb up through the dark trousers and punch
holes through the body, which is exactly what happened before this was added.

Verify the result by compositing over magenta and LOOKING at it. A hole in a
shoulder is obvious against magenta and invisible against the black backdrop it
was cut from, which is why it survived review twice.
"""

import argparse
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def cutout(src, out, thresh=10, feather=2, top_seed=True, band=0.40):
    rgb = np.array(Image.open(src).convert("RGB")).astype(int)
    h, w, _ = rgb.shape

    dark = rgb.max(axis=2) <= thresh
    lab, _ = ndimage.label(dark)

    seeds = set(np.unique(lab[0, :]))                      # top edge always
    if top_seed:
        b = int(h * band)
        seeds |= set(np.unique(lab[:b, 0])) | set(np.unique(lab[:b, -1]))
    else:
        seeds |= set(np.unique(lab[-1, :]))
        seeds |= set(np.unique(lab[:, 0])) | set(np.unique(lab[:, -1]))
    seeds.discard(0)

    bg = np.isin(lab, list(seeds))
    fg = ndimage.binary_fill_holes(~bg)     # enclosed pockets belong to the subject
    bg = ~fg

    alpha = np.where(bg, 0, 255).astype(np.uint8)
    if feather:
        ramp = ndimage.uniform_filter(alpha.astype(float), size=feather * 2 + 1)
        alpha = np.where(bg, np.minimum(ramp, 255), 255).astype(np.uint8)

    Image.fromarray(np.dstack([rgb.astype(np.uint8), alpha]), "RGBA").save(out)

    opaque = 100.0 * (alpha == 255).sum() / alpha.size
    clear = 100.0 * (alpha == 0).sum() / alpha.size
    print("%s -> %s  opaque %.1f%%  transparent %.1f%%" % (src, out, opaque, clear))
    return alpha


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--thresh", type=int, default=10,
                    help="max channel value still counted as backdrop (default 10)")
    ap.add_argument("--feather", type=int, default=2, help="edge AA radius (default 2)")
    ap.add_argument("--all-edges", action="store_true",
                    help="seed from every edge. Only for artwork that does NOT "
                         "touch the bottom of the frame; on a bust it punches "
                         "holes up through the shoulders and legs.")
    ap.add_argument("--preview", help="also write an over-magenta composite to LOOK at")
    a = ap.parse_args()

    cutout(a.source, a.output, a.thresh, a.feather, top_seed=not a.all_edges)

    if a.preview:
        im = Image.open(a.output).convert("RGBA")
        bg = Image.new("RGBA", im.size, (255, 0, 255, 255))
        Image.alpha_composite(bg, im).convert("RGB").save(a.preview)
        print("preview: %s" % a.preview)
    return 0


if __name__ == "__main__":
    sys.exit(main())
