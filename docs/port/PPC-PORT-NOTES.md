# Porting the PowerPC build onto mainline Xash3D FWGS

Working notes, kept as the port proceeds so the commits that come out of it can
explain themselves. Method: compile mainline for `ppc` against the 10.3.9 SDK,
fix whatever the compiler and the hardware object to, and keep going.

Engine base: `FWGS/xash3d-fwgs` @ `f0ea3a194ab06d56032c5d26578254698e361655`,
which is the same commit the Intel build already uses. If this lands, the project
drops from two engine trees to one.

## Findings

### Upstream already fixes the default-texture endianness, and does it better

`patch-gl-default-texture-endian.py` rewrote `GL_CreateInternalTextures()` in
`ref/gl/gl_image.c` to store the 16x16 "missing texture" checkerboard as explicit
RGBA bytes, because the packed constants `0xFFFF00FF` and `0xFF000000` byte-swap
on a big-endian machine into yellow and transparent.

Mainline has since moved that code into the engine, at
`R_CreateBuiltinTextures()` in `engine/client/dll_int/ref_common.c`, and builds
the same checkerboard with

```c
data16x16[y * 16 + x] = HostFourCC( 255, 0, 255, 255 );
```

`HostFourCC` composes the word in host byte order, so the bug cannot occur. That
is a better fix than ours: it is one expression rather than a block, and it
applies everywhere the macro is used instead of at one call site.

**Action: drop the patch.** Nothing to port.

### The native macOS menu bar is a feature mainline does not have

`patch-menu-darwin-tiger.py` edits `engine/platform/darwin/menu_darwin.m`. No
such file exists in mainline: a native menu bar was never part of upstream. The
engine runs perfectly well without one - it is a fullscreen game.

**Action: not applied.** If we want a native menu bar it should be written as our
own feature, on purpose, rather than inherited as a side effect of a port.

### It builds, it launches, and the menu draws

Mainline `f0ea3a1` built `ppc750 ppc7400 x86_64` with zero errors and only our
own patches. On the dual G5 under 10.3.9 it brings up hardware GL on the Radeon
9600, plays audio, execs the configs and draws the main menu: every item, the
descriptions, the logo and the version string are correct.

Captured headlessly with `scripts/hw-shot.sh`, which is frame-count based rather
than wall-clock so it behaves the same on a 450 MHz G3.

### CLOSED, NOT A FAULT: the "corrupted glyphs" top left are the background art

This was reported here as an open PowerPC bug: a band of garbled, very
low-contrast glyphs at the top left of the menu, said to be the engine echoing
its startup messages through a console font that got the byte order wrong. The
menu's own text being perfect in the same frame looked like the clinching detail,
two font paths with one of them broken.

All of that was wrong. Three measurements closed it.

1. **It is identical on Intel.** The same build, the same frame, the same region
   on an x86_64 Lion machine looks the same. A fault that reproduces identically
   on both architectures is not an endian fault.
2. **It never changes.** Screenshots taken at frame 200 and at frame 1700 of the
   same run differ by zero pixels in that region, so it is not console output and
   not a notify line fading out. It is static.
3. **It is invisible at normal contrast.** It only resolves into anything
   glyph-like after pushing contrast about five times, and what appears then is
   the colour of the menu's description text, not of anything the engine draws.

It is the menu background image. The Half-Life background is a grimy wall with
stencilled markings painted on it, which is also why "C 14" is legible further
down the same screenshot. Both machines mount the same retail `valve/`, so both
render the same pixels.

Two lessons worth keeping, since both cost time here. A symptom seen on one
architecture says nothing until it has been looked for on the other, and the
control was one command away the whole time. And enhancing an image to see a
suspected fault will manufacture the fault: five times contrast on dark, noisy
artwork produces shapes that read convincingly as broken text.

A fix was written for the diagnosis above, landed, measured to change nothing,
and reverted. See the revert commit on the engine branch for what it did.
