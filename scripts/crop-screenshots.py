#!/usr/bin/env python3
"""Crop full-desktop screen grabs down to just the app window, plus a margin.

The screenshots in docs/img/screenshots/ are taken on real hardware by pressing
the screen-grab key, so they arrive as whole-desktop images: wallpaper, Dock,
menu bar and all. For the README we want the window and nothing else.

Detection rather than hardcoded rectangles, because the three machines run at
three different resolutions (G3 800x600, G5 1440x900, Intel 1920x1080) and the
window lands in a different place on each.

How the window is found: Aqua window chrome is close to neutral grey and bright,
while every wallpaper in the fleet is saturated. So mask "low saturation AND
bright", label the connected regions, and take the largest one. The menu bar and
Dock also pass the colour test, which is why the largest *connected* region is
used rather than the mask's overall bounding box - the window is one solid slab
and dwarfs both.

That finds the window *body* only. Aqua draws a dark hairline under the title
bar, which severs the title bar into a region of its own, so a plain bbox of the
largest region slices the title bar off. Dilating the mask to bridge the hairline
was tried and is too blunt: on Panther a 4px dilation also welds the window to
the Dock and the menu bar, and the crop becomes the whole screen.

So the title bar is re-attached explicitly. Any other region that spans roughly
the same columns as the body and sits within a few rows of it is merged in. That
matches the title bar and nothing else, because a desktop icon or Dock beside the
window does not share its column range.

Panther has no PNG grab: 10.3's screen capture writes PDF, so those two are
converted first with sips.

Usage:
    scripts/crop-screenshots.py <original-dir> <output-dir>

The full-desktop originals are NOT kept in the repo; only the crops in
docs/img/screenshots/ ship. To refresh them, take new grabs on the machines,
drop them in a directory, extend NAMES below and run this again. Panther writes
"Picture N.pdf" to the Desktop, Leopard "Picture N.png", Lion "Screen Shot ....png".
"""

import os
import re
import subprocess
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

# Margin in pixels left around the detected window. Enough to read the window
# edge and its shadow against the wallpaper without showing desktop clutter.
MARGIN = 18

# Window chrome test. Saturation is 0..1, value is 0..255.
MAX_SAT = 0.18
MIN_VAL = 175

# Reject a detection that cannot plausibly be the app window.
MIN_FRACTION = 0.02

# A region is treated as part of the window if it starts within this many rows of
# the body. Generous, because an INACTIVE title bar is drawn in a paler gradient
# whose lower half fails the brightness test, leaving an 11px gap on the shots
# where a sheet has the focus. The column test below is what keeps this safe.
ATTACH_GAP = 24

# ...and if its columns line up with the body's to within this fraction of the
# body's width. The title bar is exactly as wide as the body; a desktop icon or
# the Dock is not.
ATTACH_TOL = 0.05

# Source name to output name. The originals are numbered in the order they were
# taken on each machine, which is the order of the install run.
NAMES = {
    "Picture 1.png": "g5-01-ready",
    "Picture 2.png": "g5-02-about-box",
    "Picture 3.png": "g5-03-mounting-image",
    "Picture 4.png": "g5-04-installing-blue-shift",
    "Picture 7.png": "g5-07-finished",
    "Screen Shot 2026-07-26 at 22.22.15.png": "intel-04-installing-induction",
    "Picture 1.pdf": "panther-01-ready",
}


def load(path):
    """Open an image, converting Panther's PDF grabs on the way through."""
    if path.lower().endswith(".pdf"):
        png = path[:-4] + ".converted.png"
        subprocess.check_call(
            ["sips", "-s", "format", "png", path, "--out", png],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return Image.open(png).convert("RGB")
    return Image.open(path).convert("RGB")


def find_window(img):
    """Locate the window.

    Returns (left, top, right, bottom, limit_top, limit_bottom): the window's own
    box, plus the rows the margin must not cross because the menu bar or the Dock
    is there.
    """
    a = np.asarray(img).astype(np.float32)
    high = a.max(axis=2)
    low = a.min(axis=2)
    # Saturation as HSV defines it, guarding the black pixels where it is undefined.
    sat = np.where(high > 0, (high - low) / np.maximum(high, 1), 0)

    mask = (sat < MAX_SAT) & (high > MIN_VAL)

    labels, count = ndimage.label(mask)
    if count == 0:
        raise ValueError("no window-coloured region found")

    # Largest component by pixel count, ignoring label 0 which is the background.
    sizes = ndimage.sum(mask, labels, range(1, count + 1))
    best = int(np.argmax(sizes)) + 1

    if sizes[best - 1] < mask.size * MIN_FRACTION:
        raise ValueError("largest neutral region is too small to be the window")

    boxes = ndimage.find_objects(labels)
    body = boxes[best - 1]
    top, bottom = body[0].start, body[0].stop
    left, right = body[1].start, body[1].stop
    tol = max(2, int((right - left) * ATTACH_TOL))

    for i, box in enumerate(boxes):
        if box is None or i == best - 1:
            continue
        y, x = box
        if abs(x.start - left) > tol or abs(x.stop - right) > tol:
            continue
        # Reaches the body from above (they may overlap by a row or two).
        if y.start < top and y.stop >= top - ATTACH_GAP:
            top = y.start
        # ...or from below.
        elif y.stop > bottom and y.start <= bottom + ATTACH_GAP:
            bottom = y.stop

    # The menu bar and the Dock are the two things the margin can spill into: on
    # the G3's 800x600 screen the window very nearly fills the display. Both span
    # almost the full width and touch an edge, which is what identifies them.
    limit_top, limit_bottom = 0, img.height
    for i, box in enumerate(boxes):
        if box is None or i == best - 1:
            continue
        y, x = box
        if x.stop - x.start < img.width * 0.9:
            continue
        if y.start == 0:
            limit_top = max(limit_top, y.stop)
        elif y.stop == img.height:
            limit_bottom = min(limit_bottom, y.start)

    return left, top, right, bottom, limit_top, limit_bottom


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src_dir, out_dir = sys.argv[1], sys.argv[2]

    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)

    for name in sorted(NAMES):
        path = os.path.join(src_dir, name)
        if not os.path.exists(path):
            print("  missing: %s" % name)
            continue

        img = load(path)
        left, top, right, bottom, limit_top, limit_bottom = find_window(img)

        left = max(0, left - MARGIN)
        top = max(limit_top, top - MARGIN)
        right = min(img.width, right + MARGIN)
        bottom = min(limit_bottom, bottom + MARGIN)

        out = os.path.join(out_dir, NAMES[name] + ".png")
        img.crop((left, top, right, bottom)).save(out, optimize=True)
        print(
            "  %-34s -> %-36s %dx%d"
            % (name, NAMES[name] + ".png", right - left, bottom - top)
        )


if __name__ == "__main__":
    main()
