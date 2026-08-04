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
    from PIL import Image, ImageFilter
except ImportError:
    sys.exit( "needs Pillow: python3 -m pip install Pillow" )

REPO = os.path.dirname( os.path.dirname( os.path.abspath( __file__ ) ) )
DEFAULT_SRC = os.path.join( REPO, "MacOSX", "icon-source-gordon-gravity-gun.png" )
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


def cut_out( img ):
    w, h = img.size
    bg = background_mask( img )
    alpha = Image.new( "L", ( w, h ) )
    # Opaque everywhere the flood did not reach, which is the figure plus any
    # black it fully encloses.
    alpha.putdata( [ 0 if b else 255 for b in bg ] )
    cleared = sum( bg )
    print( "backdrop removed: %.1f%% of the frame" % ( 100.0 * cleared / ( w * h ) ) )
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
