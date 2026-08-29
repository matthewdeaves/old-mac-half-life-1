#!/usr/bin/env python3
"""
make-about-art.py - cut the figure out of an icon source and write the About-box
artwork for the mods installer.

Why a script and not a hand-edited PNG
--------------------------------------
The sources in MacOSX/ are full-bleed renders on solid black. Dropped into the
About window as-is they read as a black rectangle pasted onto a grey panel, which
is what shipped in v1.2.0 and looked exactly as bad as it sounds. The fix is a
proper cut-out, and doing it in code keeps the provenance: the checked-in PNG can
always be regenerated from the checked-in source.

Why flood fill and not a colour key
-----------------------------------
The HEV suit's own darkest panels are as black as the backdrop, so any global
"make dark pixels transparent" rule punches holes straight through the figure.
Instead this floods inwards from the image border, so only black that is actually
CONNECTED to the outside is removed. Enclosed dark areas - between the arm and the
chest, inside the visor, the shadow under the crowbar - stay opaque because the
fill never reaches them.

Choosing the threshold is the whole game, and it is measured, not guessed. In
these renders the backdrop is pure black - sampling the border gives p99 = 1,
max = 1 - while the figure's darkest lit pixels sit at 3 and above. So the flood
is allowed through luma <= 2 only. An earlier attempt used 46, which let the fill
walk straight through the suit's black panels and hollowed the figure out.

Recovering the boot sole
------------------------
One part of the figure has no separation at all: the sole of the leading boot,
in shadow and facing away from every light. Measured on
icon-source-gordon-crowbar-new.png, a 220x130 box over the sole gives the same
pixel histogram as a border strip that is known backdrop - (0,0,0) most common,
then (1,0,0), (1,1,1) - so no luma or chroma threshold can tell them apart, and
there is no edge there to find either. The flood walks in and eats the sole,
which is issue #24: a shape punched full of holes, obvious against the About
panel's grey.

What IS different about the sole is its texture. Enough of its tread catches a
little light to survive the flood, and those survivors are left behind as a
dense cloud of ISLANDS: connected components of figure that no longer touch the
main silhouette. Nothing else in the frame looks like that. The rim of the
figure sheds islands too, but as scattered single specks; a genuine gap, like
the triangle between the crowbar and the shoulder, contains none at all.

So the sole is recovered by looking for island DENSITY, not by thresholding
harder. Blur the islands-only mask, keep where it is dense, close the result,
and union it back into the figure. Measured on the same source: 318 components,
986 island pixels, and the rule adds 6106 px, all of them in the sole.

Two rejected alternatives, both of which look correct until you check the rest
of the frame:

- A soft alpha ramp from local figure density fills the sole, and also draws a
  grey halo around the whole figure, worst around the crowbar.
- Directional enclosure ("how boxed-in is this hole") fills the sole, and also
  fills the gap between the crowbar and the arm, which is exactly as enclosed.

The cut is then feathered by a sub-pixel blur of the alpha channel, which
smooths the stair-stepping without eating the render's own anti-aliased rim.

Usage:
    scripts/make-about-art.py [--source PATH] [--out PATH] [--height N]
"""
import argparse
import os
import sys
from collections import deque

try:
    from PIL import Image, ImageChops, ImageFilter
except ImportError:
    sys.exit( "needs Pillow: python3 -m pip install Pillow" )

REPO = os.path.dirname( os.path.dirname( os.path.abspath( __file__ ) ) )
# The shipped About-Gordon.png came from this render, not the gravity-gun one.
DEFAULT_SRC = os.path.join( REPO, "MacOSX", "icon-source-gordon-crowbar-new.png" )
DEFAULT_OUT = os.path.join( REPO, "installer", "About-Gordon.png" )

# Luma at or below this counts as backdrop for the flood. The border of these
# renders measures p99 = 1, and the figure's darkest lit pixels are 3 and up, so
# 2 separates them with room to spare. Raising this hollows out the suit.
FLOOD_MAX = 2
# Sub-pixel feather on the finished alpha, to take the hard stair-step off the
# silhouette. Much above 1.0 and the figure starts to look like a sticker.
FEATHER = 0.8
# Transparent margin kept around the trimmed figure, in pixels of the SOURCE.
MARGIN = 8
# Boot-sole recovery, all in pixels of the SOURCE. Blur radius over the
# islands-only mask, the density needed to count as a cluster, and the closing
# that turns a passing cluster into a solid region. ISLAND_DENSITY_MIN is the
# one that matters: at 8 the sole fills and the figure's rim specks, which are
# isolated, do not.
ISLAND_DENSITY_R = 14
ISLAND_DENSITY_MIN = 8
ISLAND_CLOSE = 10


def luma( px ):
    r, g, b = px[0], px[1], px[2]
    return ( 299 * r + 587 * g + 114 * b ) // 1000


def background_mask( img ):
    """Flood inwards from every border pixel. Returns a bytearray, 1 = backdrop."""
    w, h = img.size
    px = img.load()
    seen = bytearray( w * h )
    q = deque()

    def push( x, y ):
        i = y * w + x
        if seen[i] or luma( px[x, y] ) > FLOOD_MAX:
            return
        seen[i] = 1
        q.append( ( x, y ) )

    for x in range( w ):
        push( x, 0 )
        push( x, h - 1 )
    for y in range( h ):
        push( 0, y )
        push( w - 1, y )

    while q:
        x, y = q.popleft()
        if x > 0:     push( x - 1, y )
        if x < w - 1: push( x + 1, y )
        if y > 0:     push( x, y - 1 )
        if y < h - 1: push( x, y + 1 )

    return seen


def islands( mask ):
    """Every component of `mask` except the largest one, as its own mask.

    The largest is the figure. What is left is the anti-aliased rim shedding
    single specks, plus the dense cloud the flood leaves behind where it ate
    the boot sole.
    """
    w, h = mask.size
    px = mask.load()
    label = bytearray( w * h )      # 0 = unvisited/backdrop, 1 = kept, 2 = figure
    best_n, best_seed = 0, None
    seeds = []

    for sy in range( h ):
        row = sy * w
        for sx in range( w ):
            if not px[sx, sy] or label[row + sx]:
                continue
            n = 0
            q = deque( ( ( sx, sy ), ) )
            label[row + sx] = 1
            while q:
                x, y = q.popleft()
                n += 1
                for nx, ny in ( ( x - 1, y ), ( x + 1, y ), ( x, y - 1 ), ( x, y + 1 ) ):
                    if 0 <= nx < w and 0 <= ny < h and px[nx, ny] and not label[ny * w + nx]:
                        label[ny * w + nx] = 1
                        q.append( ( nx, ny ) )
            seeds.append( ( n, sx, sy ) )
            if n > best_n:
                best_n, best_seed = n, ( sx, sy )

    # Re-walk the largest component and mark it 2, so it drops out.
    if best_seed is not None:
        sx, sy = best_seed
        q = deque( ( best_seed, ) )
        label[sy * w + sx] = 2
        while q:
            x, y = q.popleft()
            for nx, ny in ( ( x - 1, y ), ( x + 1, y ), ( x, y - 1 ), ( x, y + 1 ) ):
                if 0 <= nx < w and 0 <= ny < h and px[nx, ny] and label[ny * w + nx] == 1:
                    label[ny * w + nx] = 2
                    q.append( ( nx, ny ) )

    out = Image.new( "L", ( w, h ) )
    out.putdata( [ 255 if v == 1 else 0 for v in label ] )
    kept = sum( 1 for v in label if v == 1 )
    print( "components: %d, figure %d px, islands %d px"
           % ( len( seeds ), best_n, kept ) )
    return out


def recover_clusters( figure ):
    """Add back the regions the flood ate that are dense clouds of islands.

    See the module docstring: this is the boot sole, and nothing else in the
    frame has that texture.
    """
    dense = islands( figure ).filter( ImageFilter.GaussianBlur( ISLAND_DENSITY_R ) )
    dense = dense.point( lambda v: 255 if v >= ISLAND_DENSITY_MIN else 0 )
    k = 2 * ISLAND_CLOSE + 1
    dense = dense.filter( ImageFilter.MaxFilter( k ) ).filter( ImageFilter.MinFilter( k ) )
    out = ImageChops.lighter( figure, dense )
    added = sum( 1 for a, b in zip( out.tobytes(), figure.tobytes() ) if a and not b )
    print( "island clusters recovered: %d px" % added )
    return out


def cut_out( img ):
    w, h = img.size
    bg = background_mask( img )
    # Opaque everywhere the flood did not reach, which is the figure plus any
    # black it fully encloses.
    figure = Image.new( "L", ( w, h ) )
    figure.putdata( [ 0 if b else 255 for b in bg ] )
    cleared = sum( bg )
    print( "backdrop removed: %.1f%% of the frame" % ( 100.0 * cleared / ( w * h ) ) )

    alpha = recover_clusters( figure )
    if FEATHER > 0:
        alpha = alpha.filter( ImageFilter.GaussianBlur( FEATHER ) )

    out = img.convert( "RGB" ).copy()
    out.putalpha( alpha )
    return out


def trim( img ):
    box = img.split()[3].point( lambda a: 255 if a > 8 else 0 ).getbbox()
    if box is None:
        return img
    l, t, r, b = box
    w, h = img.size
    return img.crop( ( max( 0, l - MARGIN ), max( 0, t - MARGIN ),
                       min( w, r + MARGIN ), min( h, b + MARGIN ) ) )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument( "--source", default=DEFAULT_SRC )
    ap.add_argument( "--out", default=DEFAULT_OUT )
    ap.add_argument( "--height", type=int, default=440,
                     help="output height in pixels; width follows the figure" )
    args = ap.parse_args()

    src = Image.open( args.source ).convert( "RGB" )
    print( "source: %s %dx%d" % ( args.source, src.size[0], src.size[1] ) )

    art = trim( cut_out( src ) )
    print( "trimmed to figure: %dx%d" % art.size )

    w = max( 1, int( round( art.size[0] * args.height / float( art.size[1] ) ) ) )
    art = art.resize( ( w, args.height ), Image.LANCZOS )

    art.save( args.out, "PNG", optimize=True )
    print( "wrote: %s %dx%d (aspect %.4f)  %d bytes"
           % ( args.out, art.size[0], art.size[1],
               art.size[0] / float( art.size[1] ),
               os.path.getsize( args.out ) ) )
    print( "point size for the About button: %.1f x %d"
           % ( art.size[0] / 2.0, args.height // 2 ) )


if __name__ == "__main__":
    main()
