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

### The map-load crash was our own byte swap, applied twice

Loading `c1a0` died with SIGSEGV on the G3 and, intermittently, on the G5. It was
first reported here as a fault in renderer setup, because the last line printed
before it was `Setting up renderer...`. That was a coincidence of timing: the
next thing that happens is the first frame, and the first frame is where a studio
model is drawn.

Three measurements found it.

1. **Bisecting by configuration cleared the renderer.** With `gl_singlepass 0` it
   still crashed, and with `-ref soft` it still crashed. A fault that survives
   turning off the multitexture path and then survives swapping the entire
   renderer for the software one is not in either renderer.
2. **The operating system had already written the answer down.** Every one of
   these machines keeps a fully symbolised trace in
   `~/Library/Logs/CrashReporter/xash3d.bin.crash.log`. It named four frames of
   client game code that our own handler never reached:
   `StudioCalcBonePosition` <- `StudioCalcRotations` <- `StudioSetupBones` <-
   `StudioDrawModel`.
3. **The registers named the value.** The faulting address sat `0x7a02` past a
   live model pointer, and `r0` held `0x7a02`. Byte-reversed that is `0x027a`, an
   entirely ordinary offset into a model. So a `short` that should have been in
   host order was in little-endian order at the point of use.

The cause was a commit of ours, `studio: byte-swap the model data the renderer
reads directly`. It swapped animation offsets and animation values in the client
dll's `CStudioModelRenderer`, on the stated grounds that the engine's
`LoadCacheFile` is "a raw file load with no byteswapping anywhere in it".

That premise is false for the engine we build. `Mod_LoadCacheFile` in
`engine/common/model.c` carries an `XASH_BIG_ENDIAN` block that calls
`Mod_SwapStudioSeqGroupAnims`, and the comment above it says what it is for:
"this handles when studio model renderer tries to load sequence files on it's
own, which is what they always do in HLSDK". That is precisely the case the
commit was written for. `Mod_SwapStudioSeqGroupAnims` swaps `mstudioanim_t`'s
six offsets and every `mstudioanimvalue_t` behind them, and it is reached for
sequence group 0 through `R_StudioLoadHeader` as well.

So both halves of the commit were a second swap over bytes that were already in
host order, and a second swap is the identity undone: it put the offsets back
into little-endian, and the pointer arithmetic then walked off the model.

It is reachable because the client sets the renderer's studio header, at
`StudioModelRenderer.cpp:1166`, before calling `StudioSetupBones` at 1190. The
engine's swap block asks for that header through `PARM_GET_STUDIO_HDR`, finds it,
and does the work. Nothing was missing.

**Action: the commit is dropped**, not amended: with the engine doing this
correctly there is nothing left for it to do. It is kept as the tag
`archive/studio-double-swap` on the hlsdk fork rather than in the branch.

The lesson is narrower than "check upstream". The commit's reasoning was sound
for an engine that does not swap there, and it was written while this port still
built against one that did not. When a fix rests on what another component does
*not* do, that premise has to be re-read against the component actually being
built, because it is the kind of premise that silently stops being true.

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
