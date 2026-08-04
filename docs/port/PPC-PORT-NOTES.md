# Porting the PowerPC build onto mainline Xash3D FWGS

Running notes on the port, so the commits that come out of it can explain
themselves. Method: compile mainline for `ppc` against the 10.3.9 SDK and fix
whatever the compiler and the hardware object to.

Engine base: `FWGS/xash3d-fwgs` @ `f0ea3a194ab06d56032c5d26578254698e361655`, the
same commit the Intel build already uses, so the project drops from two engine
trees to one.

## Mainline already fixes the default-texture endianness

Our old `patch-gl-default-texture-endian.py` rewrote `GL_CreateInternalTextures()`
in `ref/gl/gl_image.c` to store the 16x16 "missing texture" checkerboard as explicit
RGBA bytes, because the packed constants `0xFFFF00FF` and `0xFF000000` byte-swap on
a big-endian machine into yellow and transparent. Mainline has moved that code into
the engine, at `R_CreateBuiltinTextures()` in
`engine/client/dll_int/ref_common.c`, and builds the checkerboard with

```c
data16x16[y * 16 + x] = HostFourCC( 255, 0, 255, 255 );
```

`HostFourCC` composes the word in host byte order, everywhere the macro is used, so
the bug cannot occur. **Patch dropped, nothing to port.**

## No native macOS menu bar in mainline

`patch-menu-darwin-tiger.py` edited `engine/platform/darwin/menu_darwin.m`, a file
mainline does not have: a native menu bar was never part of upstream, and a
fullscreen game runs without one. **Not applied.** If we want one it should be
written as our own feature, on purpose, rather than inherited as a side effect of a
port.

## It builds, launches and draws

Mainline `f0ea3a1` built `ppc750 ppc7400 x86_64` with zero errors and only our own
changes. On the dual G5 under 10.3.9 it brings up hardware GL on the Radeon 9600,
plays audio, execs the configs and draws the main menu correctly: every item, the
descriptions, the logo and the version string. Captured headlessly with
`scripts/hw-shot.sh`, which counts frames rather than wall-clock time, so it behaves
the same on a 450 MHz G3.

## The map-load crash was our own byte swap, applied twice

`c1a0` died with SIGSEGV on the G3 and, intermittently, on the G5. It was first
reported as a fault in renderer setup, because the last line printed was `Setting up
renderer...`. Coincidence of timing: the next thing that happens is the first frame,
and the first frame is where a studio model is drawn. Three measurements found it.

1. **Bisecting by configuration cleared the renderer.** It still crashed with
   `gl_singlepass 0` and still crashed with `-ref soft`. A fault that survives
   turning off the multitexture path and then swapping the entire renderer for the
   software one is in neither renderer.
2. **The OS had already written the answer down.** The fully symbolised trace these
   machines keep in `~/Library/Logs/CrashReporter/xash3d.bin.crash.log` named four
   frames of client game code that our own handler never reached:
   `StudioCalcBonePosition` <- `StudioCalcRotations` <- `StudioSetupBones` <-
   `StudioDrawModel`.
3. **The registers named the value.** The faulting address sat `0x7a02` past a live
   model pointer and `r0` held `0x7a02`. Byte-reversed, `0x027a` is an entirely
   ordinary offset into a model: a `short` that should have been in host order was
   in little-endian order at the point of use.

The cause was a commit of ours, `studio: byte-swap the model data the renderer reads
directly`, which swapped animation offsets and animation values in the client dll's
`CStudioModelRenderer` on the stated grounds that the engine's `LoadCacheFile` is "a
raw file load with no byteswapping anywhere in it".

That premise is false for the engine we build. `Mod_LoadCacheFile` in
`engine/common/model.c` carries an `XASH_BIG_ENDIAN` block calling
`Mod_SwapStudioSeqGroupAnims`, commented "this handles when studio model renderer
tries to load sequence files on it's own, which is what they always do in HLSDK",
which is precisely the case the commit was written for.
`Mod_SwapStudioSeqGroupAnims` swaps `mstudioanim_t`'s six offsets and every
`mstudioanimvalue_t` behind them, and sequence group 0 reaches the same work through
`R_StudioLoadHeader`. It is reachable: the client sets the renderer's studio header
at `StudioModelRenderer.cpp:1166` before calling `StudioSetupBones` at 1190, and the
engine's swap block asks for that header through `PARM_GET_STUDIO_HDR`, finds it and
does the work. Nothing was missing.

So both halves of the commit were a second swap over bytes already in host order,
and a second swap is the identity undone: the offsets went back to little-endian and
the pointer arithmetic walked off the model. **The commit is dropped**, not amended,
and kept as the tag `archive/studio-double-swap` on the hlsdk fork rather than in
the branch.

The lesson is narrower than "check upstream". The reasoning was sound for an engine
that does not swap there, and it was written while this port still built against one
that did not. When a fix rests on what another component does *not* do, that premise
has to be re-read against the component actually being built, because it is the kind
of premise that silently stops being true.

## CLOSED, NOT A FAULT: the "corrupted glyphs" top left are the background art

Reported as an open PowerPC bug: a band of garbled, very low-contrast glyphs at the
top left of the menu, said to be the engine echoing its startup messages through a
console font that got the byte order wrong, with the menu's own perfect text in the
same frame as the clinching detail. All of it was wrong, and three measurements
closed it.

1. **Identical on Intel.** Same build, same frame, same region on an x86_64 Lion
   machine. A fault that reproduces identically on both architectures is not an
   endian fault.
2. **It never changes.** Frame 200 and frame 1700 of the same run differ by zero
   pixels in that region, so it is static: not console output, not a notify line
   fading out.
3. **Invisible at normal contrast.** It resolves into anything glyph-like only after
   pushing contrast about five times, and what appears then is the colour of the
   menu's description text, not of anything the engine draws.

It is the menu background image: the Half-Life background is a grimy wall with
stencilled markings painted on it, which is also why "C 14" is legible further down
the same screenshot. Both machines mount the same retail `valve/`, so both render
the same pixels.

Two lessons, since both cost time. A symptom seen on one architecture says nothing
until it has been looked for on the other, and that control was one command away the
whole time. And enhancing an image to see a suspected fault will manufacture it:
five times contrast on dark, noisy artwork produces shapes that read convincingly as
broken text.

A fix for that diagnosis was written, landed, measured to change nothing, and
reverted; see the revert commit on the engine branch for what it did.
