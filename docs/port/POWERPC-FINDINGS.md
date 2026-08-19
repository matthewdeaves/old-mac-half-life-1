# PowerPC findings

What running Half-Life on a 1999 Power Mac actually costs, one entry per finding.

Every change this port makes is a commit on our own branch of an upstream tree,
so `git log <upstream>..oldmac` is the complete record and this file is the
readable version of it. Most of them sit on the engine branch. The count is
deliberately not written down here: git already knows it, and a number kept by
hand is a second source of truth that goes stale the next time the branch moves.

Most of these are not really about PowerPC. They are about a codebase meeting an
older OS, an older compiler and a smaller GPU than anyone had tried it against,
and about half of them turned out to be architecture-neutral defects that the
PowerPC build simply reached first. Where that is true it is said so, because
"PowerPC bug" is the wrong thing to write down when the Intel build has it too.

**Each entry gives** the tree and function, the observable symptom, what the
change does, and the machines it was verified on. Nothing here is inferred from
reading code alone; where something is unmeasured it says so.

The fleet referred to throughout:

| name | machine | CPU | GPU | OS |
|---|---|---|---|---|
| yosemite | Power Mac G3 | 750 | ATI Rage 128, GL 1.1, 2 TMUs | 10.3.9 / 10.4.11 |
| mini-g4 | Mac mini G4 | 7447 | Radeon 9200 | 10.4.11 |
| quicksilver | Power Mac G4 | 7450 | | 10.4.11 |
| g5 | dual Power Mac G5 | 970 | Radeon 9650 | 10.3.9 / 10.4.11 / 10.5.8 |

---

## Engine: the operating system

### 1. Panther's `dladdr` keeps the leading underscore, so save and restore loses every carried entity

**`engine/common/lib_posix.c`, `COM_NameForFunction`** ([`6ceb56b5`](../../))

**Symptom.** On the G3 under 10.3.9, walking through the first level transition
left the guard who is supposed to open the door standing still for ever. The
game did not crash and printed nothing.

**Cause.** Half-Life saves function pointers by NAME. It turns a pointer into a
string with `dladdr` on save, and turns the string back into a pointer with
`dlsym` on restore, so an entity carried across a level transition keeps its
`think`, `touch` and `use`. Mach-O prepends `_` to every symbol. On 10.4, 10.5
and Intel, `dladdr` strips that back off; **on 10.3 it does not**. So the saved
name is `__ZN...`, `COM_DetectMangleType` only recognises `_ZN`, the mangling is
classified as unknown, the `dlsym` round trip fails, and every carried entity
restores with a NULL think.

**Change.** Normalise a leading `__ZN` to `_ZN` in `COM_NameForFunction`. A
runtime no-op anywhere `dladdr` already strips the underscore, so it is applied
to every slice rather than gated on the OS.

**Verified.** G3 on 10.3.9 (the failure) and on 10.4.11 (no regression). Not a
compiler fault: it was investigated as a gcc miscompile first, and that was
wrong.

### 2. Darwin refuses `execve` from a multi-threaded process, so no mod can be switched

**`engine/common/host.c`** ([`09afd735`](../../))

**Symptom.** Choosing a mod in Custom Game did nothing. The engine shut down
cleanly and then printed

```
Error: Failed to restart the engine
execv(.../Contents/MacOS/xash3d.bin) failed: Operation not supported
```

leaving a live process with no window that had to be force-quit.

**Cause.** Darwin will not `execve()` from a process with more than one thread.
It does not replace the image; it returns `ENOTSUP` (errno 45). By the time the
engine wants to restart it has SDL's audio thread up, so it is always
multi-threaded.

**Change.** `fork()` first and `exec` in the child, which is single-threaded.

**Verified.** Demonstrated with a purpose-built test binary on quicksilver, a G4
on 10.4.11, before the fix was written. This is the whole reason mods work at
all on this port.

### 3. `dlopen` of a bare leaf name cannot work when launched from Finder

**`engine/common/lib_posix.c`, `COM_LoadLibrary`** ([`6ceb56b5`](../../))

**Symptom.** The app ran from a terminal and failed from a double-click.

**Cause.** Launched from Finder the working directory is `/`. dyld will not
resolve a bare leaf name (no slash) against the working directory, only against
the `DYLD_*` paths. `filesystem_stdio`, `ref_gl`, `ref_soft` and `menu` live
next to the executable, so they were not found.

**Change.** Retry the load against the executable's own directory. Both `dlopen`
sites in `COM_LoadLibrary` needed it, not just the obvious one.

**Verified.** Every machine in the fleet, since it affects all of them.

### 4. A blocking `getaddrinfo` on the frame loop reads as broken input, not as a stall

**`engine/common/net_ws.c`** ([`f75afcb9`](../../), [`b187b4db`](../../))

**Symptom.** On the G4 under 10.4.11: open Multiplayer, then Internet Game, then
Add server, and type. Nothing appears. Fifteen to twenty seconds later every
character arrives at once, in order, with nothing lost. A Cmd-Q registers just
as late.

**Cause.** The engine resolved its own hostname on the frame loop. While that
blocks, the engine is not running frames, so SDL never drains the OS event
queue and the keystrokes sit in it. The shape of the symptom is the evidence:
delayed, in order and complete is a frame-loop stall, whereas broken text input
would drop characters.

**Change.** Take our own address from the interface list instead of a blocking
lookup, and resolve no hostname on the frame loop at all.

**Verified.** G4 on 10.4.11.

---

## Engine: the GPU

### 5. Leopard advertises non-power-of-two textures its driver samples in software

**`ref/gl/gl_image.c`** ([`b686a174`](../../))

**Symptom.** The same binary on the same G5 with the same map: **56.0 fps on
10.4, 2.0 fps on 10.5.** Slower than the engine's own software renderer at the
same resolution, which is the tell.

**Cause.** The trigger is the OS, not the card. 10.4 reports GL 1.5 and does not
advertise `GL_ARB_texture_non_power_of_two`, so the engine rounds every texture
up to a power of two and the sampler handles it in hardware. 10.5 reports GL
2.0, where NPOT is **core**, so the driver is obliged to advertise it; the engine
takes it at its word and uploads at native size. 1570 of the 3116 miptex in
`halflife.wad` are not powers of two, commonly 96x128, 48x48 and 64x96, and
world textures are `GL_REPEAT` with a full mip chain, which is exactly the
combination an R300 sampler cannot address. The driver drops the whole scene to
software.

**Change.** Do not use NPOT textures on a PowerPC Mac.

**Verified.** Dual G5 with a Radeon 9650 at 1680x1050, measured both ways with
the cvar as the only change.

**Worth generalising:** an extension being advertised is a statement about the
API, not about the silicon.

### 6. The world can be drawn in one multitexture pass instead of two, worth about 30% on a G3

**`ref/gl/gl_rsurf.c`** ([`694a4f4f`](../../), [`a52cea7c`](../../))

**Symptom.** Not a bug. Profiling the live engine on the G3 showed **~81% of
every frame blocked in `CGLFlushDrawable`** waiting on the GPU, i.e. fillrate
bound rather than CPU bound.

**Cause.** The non-VBO world path rasterises every surface twice: a base texture
pass through `R_RenderBrushPoly`, then a separate lightmap pass through
`R_BlendLightmaps`.

**Change.** Collapse both into one `glBegin`/`glEnd` with TMU0 as base
(`GL_REPLACE`) and TMU1 as lightmap (`GL_MODULATE`, or a `COMBINE` x2 for
`gl_overbright`). The Rage 128 has exactly two texture units and both
`GL_ARB_multitexture` and `GL_ARB_texture_env_combine`, which is all this needs.
Brush models got the same treatment separately.

**Verified.** G3, +30%. See `docs/GL-OPTIMIZATION-CASE-STUDY.md` for the
measurement method, and note entry 13 below for the part of this that was got
wrong twice.

---

## Engine: diagnosis of the port itself

### 7. `backtrace_full` describes only the frames it can, so a release build gets nothing

**`engine/common/crashhandler.c`** ([`5f04e0e4`](../../))

**Symptom.** Reported as PowerPC-only, on every launch of the G3 and G4 slices:

```
Error: libbacktrace error: backtrace library does not support threads (0)
```

**Cause, and why the report was misleading.** Fixing that alone was not enough.
With libbacktrace running, a forced `SIGSEGV` produced fourteen lines of "no
debug info in Mach-O executable" and not one stack frame. Running the same test
on Intel, which never had the threads error, produced the same fourteen lines.
So the crash handler produced no usable backtrace on **any** slice, and the
PowerPC fault was hiding a defect that was never architecture-specific.

**Change.** Five fixes; two PowerPC-only, three shared. Includes unwinding
PowerPC from the signal context rather than from the handler frame
([`df97adf5`](../../)), and `-nomsgbox` for machines with nobody sitting at them
([`ac6cb211`](../../)).

**Verified.** Forced `SIGSEGV` on PowerPC and Intel.

---

## Menu

### 8. `L()` returns its key on a miss, so a missing dictionary draws token names

**mainui `CMenuBannerBitmap` and friends**

**Symptom.** Menu items rendered as raw coded tokens rather than words.

**Cause.** mainui's `L()` returns the key itself when the dictionary has no
entry. Retail Half-Life ships no `resource/*_english.txt` and mainui bundles
none, so nothing supplies these but us. A missing dictionary therefore does not
degrade visibly, it degrades into something that looks like a different bug.

**Change.** Ship `configs/gameui_english.txt` and copy it into the bundle.
`tests/test-repo.py` asserts both the file and the copy step, because shipping
the file and forgetting the copy looks identical to never having written it.

### 9. The menu's hint text stops scaling at 1280 wide

**`3rdparty/mainui/controls/PicButton.cpp`, and `engine/client/console.c`,
`Con_LoadConchars`**

**Symptom.** On a 2880 wide display the grey description beside each menu item is
tiny, while the yellow item next to it looks right. Reported from a screenshot.

**Cause.** mainui draws an item's description with `DrawConsoleString`, so it
uses the CONSOLE font, while the item itself is scaled by `uiStatic.scaleX`. The
engine has only three console fonts and picks by width:

```
width <= 640   font 0
width >= 1280  font 2      the largest there is
```

Past 1280 the buttons keep scaling and the descriptions do not. At 2880 they are
drawn at their 1280 size beside buttons more than twice that, which reads as
broken artwork rather than as a font that ran out of sizes.

**Change.** The launcher derives `con_fontscale` from the width it is about to
request, clamped to [1, 3]. 800, 1024 and 1280 come out at 1.0 and are omitted
entirely, so nothing about the old machines changes; 2880 gives 2.2, confirmed on
screen. No engine change was needed.

**Verified.** Apple Silicon at 2880x1864, before and after. G3 at 800x600 is a
no-op by construction.

**This is the opposite of the usual entry here.** Everything else on this page is
an old machine failing at something modern code assumed. This is modern hardware
failing at something an old codebase assumed: that nobody would ever have a
display more than twice as wide as 1280.

---

## What was got wrong

Publishing only the diagnoses that survived would misrepresent the work. Three
mechanisms were stated as fact and retracted in one session, which is what the
project's refutation-pass rule exists for.

### 10. The G3 guard-door freeze was blamed on a gcc miscompile

It is entry 1 above: `dladdr` and the leading underscore. The compiler was never
involved.

### 11. Two diagnoses in the endianness work, made, measured and withdrawn

Recorded in `PPC-PORT-NOTES.md`. Kept there rather than restated here.

### 12. The studio model byteswap that was applied twice

Mod game code carried a swap of the studio animation offsets in the client
renderer, on the theory that PowerPC needed it. The engine already swaps that
data, in `Mod_LoadCacheFile` and `R_StudioLoadHeader`, and does so for mods
exactly as for the base game. Applying it again is the identity undone: the
offsets go back to little-endian and the pointer arithmetic in
`StudioCalcBonePosition` walks off the model. It crashed the base game on every
PowerPC machine as soon as a real map loaded a studio model. The graft was
removed rather than fixed.

### 13. The single-pass world draw, three times, and then withdrawn

The +30% in entry 6 was real, but the first two attempts shipped visual faults:
a flicker traced to running `R_CheckLightMap` before the base draw, and a
dynamic-lightmap branch that rebound the base texture in a case that could never
fire ([`a95988c8`](../../), [`327336b5`](../../)). The second was found only by
reading the code back after the first was fixed.

A third attempt tried to let the path run under fog, where it disables itself and
so gives the gain up exactly where the G3 can least afford it. That attempt was
abandoned, and how it failed is worth more than the change would have been.

The premise held up: `GL_SetupFogColorForSurfacesEx` pre-compensates the fog
colour because fog is applied once per pass and the passes composite by
multiplication, and its `passes < 2` branch sets the true colour and returns. One
pass is the case needing no correction, and it was the case the guard refused.

Three faults followed, each hidden by the way the previous one was checked.

**The water trap.** `EmitWaterPolys` sets the fog colour twice by itself: the
true colour going in, the multi-pass colour coming out. The compensating restore
was written inside a `Mod_HaveLightmappedWater()` branch, which is false on every
stock map, so it never ran, and one water surface left every following surface
over-compensated. Underwater, water is always in view.

**The default that made it a no-op.** The change declined single-pass when fog
and detail textures were both on, on the belief that `r_detailtextures` was off
in practice. It defaults to `"1"`. So under fog, on a default install, the change
written to make single-pass work under fog did nothing at all.

**And a measurement that could not have detected either.** Screenshots of
single-pass off against on differed by a mean of 0.07 of 255, which was read as
the compensation being correct. It was 0.07 because both frames were the same
renderer. A screenshot comparison cannot separate "it ran and matched" from "it
declined and fell back", because matching output is precisely what the change is
supposed to produce.

The check that settles it in a minute: `r_lightmap 1` strips textures in
`R_BlendLightmaps`, which single-pass surfaces never reach, so a live single-pass
path leaves those surfaces textured while the fallback ones go flat. Toggling
`gl_singlepass` under `r_lightmap 1` changed nothing, which said at once that the
path was dead.

With all of that fixed, a person looking at the screen judged the classic
two-pass path better and the new one worse, and the work was dropped. The gain
was narrow to begin with: fogged and underwater scenes, on the one machine in the
fleet that is fillrate-bound, in a game with few of them.

### 14. The blue tint that was not a rendering fault at all

Screenshots came out blue. It was the screenshot capture path, not the renderer:
`ref_soft` wrote pixels as a native-order word instead of as bytes
([`a7bb7bd3`](../../)). What was on screen had always been correct.

### 15. The welder that went dark twice, both times by archive

v1.7.0 hands-on testing: the welder's dynamic light did not reach the floor on
the G3, while the iMac G5 lit correctly. The lead was "it worked before the
move onto our own forks", which pointed at the re-ported single-pass world
draw. The code was innocent: the pre-fork single-pass implementation was
recovered from this repo's history (the deleted patch script) and is
line-for-line what the fork carries. Measured on the machine instead:
`r_dynamic` is `FCVAR_ARCHIVE` and the G3's carried-over `config.cfg` held it
at `"0"`, written by an old benchmark probe and preserved across every deploy
since, because a deploy never touches the player folder. The engine history
records the same machine going dark the same way once before. The change is a
`r_dynamic "1"` pin in the shipped `userconfig.cfg` (`10c4b06`), the third
cvar pinned there against archive contamination; the light was then confirmed
on the G3. The moral repeats entry 13's: on this fleet, "worked before X"
dates the config, not the code.

---

## The perf-ppc branch (2026-08-18)

### 16. The Rage 128's remaining fps lived in the pixel format, not the code

**`make-app.sh` G3 profile; `ref/gl/gl_opengl.c`, `gl_image.c`;
`engine/platform/sdl2/vid_sdl2.c`**

**Symptom.** Not a bug. After the single-pass work the G3 still spent ~83% of
each frame blocked on the GPU at 30 fps.

**Cause.** Three costs a config could not reach: the framebuffer ran 32-bit
because SDL's Cocoa backend ignores the GL color size attributes and derives
the depth from the current display mode; the min filter was hardcoded
trilinear, which the Rage 128 samples in two cycles; and the default pixel
format carried a 24-bit Z plus an 8-bit stencil nothing shipped reads, when the
card's native Z is 16-bit.

**Change.** Four launch knobs the G3 profile passes and every other machine
never sees: `-bpp 16` switches the display mode itself (which also flips
texture uploads to RGB5/RGBA4 via `desktopBitsPixel`), `-bilinear` selects
single-mip filtering and is read at the filter site so an archived
`opengl.cfg` cannot defeat it, `-gldepth16` and `-glnostencil` trim the
context. Each has a `-no` form and the bench harness passes launch args
through (`fleet-bench -A`).

**Verified.** Knob isolation on the G3, c0a0, 800x600, interleaved: 16-bit
mode +23%, bilinear +14%, lean Z and no stencil +5%. Together 30.0 to 44.6
fps, measured identically on 10.3.9 and 10.4.11. The 16-bit look was judged
by eye on a same-frame screenshot pair before shipping; the Rage 128 dithers
its 16-bit output and the verdict was very little visible difference. The
same `-bpp 16` measured +33% on the G4 mini's Radeon 9200 (92.5 to 123.6)
and is deliberately not shipped there: the G4s already run above 90 fps and
keep the clean framebuffer.

### 17. Client vertex arrays are slower than immediate mode on Apple's PowerPC GL driver

**`ref/gl/gl_rsurf.c`, `R_SinglePassBrushPoly`; cvar `gl_singlepass_arrays`**

**Symptom.** The branch cost the dual G5 12% (209 to 183 fps on Leopard)
while the G4 mini, running the same ppc7400 slice, measured nothing.

**Cause.** The single-pass draw had been converted from per-vertex immediate
mode to one `glDrawArrays` per surface, reasoned from call counts: three
indirect GL calls per vertex against a handful per surface. Apple's driver
prices it the other way. A `sample` profile on the G5 shows every
per-surface draw rebuilding the driver's vertex submit dispatch
(`gleSetVertexArrayFunc`, `gldUpdateDispatch` under
`gleDrawArraysOrElements`): about 2.4x the submission CPU of the plain
`glBegin` path, with the dispatch churn bleeding into the studio path. The
GPU-bound G3 and G4 hid the cost entirely; only the 209 fps G5 exposed it.

**Change.** `gl_singlepass_arrays` defaults 0 and is deliberately not
`FCVAR_GLCONFIG`, so the fleet's archived "1" from the experiment window
cannot override the new default. The code stays for a per-session experiment
on a CPU-bound machine.

**Verified.** With arrays off the G5 came back to parity and slightly ahead
(fresh boots: +1.9% on Tiger, +1.7% on Panther against v1.7.2).

**Got wrong on the way, twice.** The regression was first pinned on
`-mtune=7450`, publicly enough to land in a commit message; a tuned/untuned
build pair measured identical (183 fps both) and refuted it, and the flag
stays dropped only because it buys nothing measurable. Before that, a round
of single-cvar A/Bs seemed to show every knob innocent, because the bench
boxes drift: the Intel mini sagged from 124 to 99 fps and the G5's Leopard
partition from 209 to 180 across the day, for both builds alike. Only
interleaved neighbor pairs, the protocol the single-pass work already used,
produced numbers that meant anything.

### 18. The branch changes that are visually free

**Engine fork, ten commits on `oldmac..perf-ppc`.**

Beyond entries 16 and 17: animated lightstyles (the 1..31 band designers use
for flicker and pulse) were permanently stuck on the two-pass dynamic chain
because `R_CheckLightMap` returned before refreshing `cached_light`; they now
TexSubImage in place and stay single-pass (`gl_lightstyle_upload`). Opaque
world chains draw near to far instead of the pessimal far to near
(`gl_front_to_back`). The dlight BSP marking walked 27x the useful node
volume (`r_dlight_virtual_radius` 3 to 1) and ran even with `r_dynamic` off.
Two 32 KB per-frame array clears became ranged clears. PowerPC mixes sound
at 22 kHz, the assets' native rate, on the integer fast path. All of it is
neutral at the c0a0 bench viewpoint and scene-dependent by design; the
flicker-lit and dlight-heavy scenes it targets have not been measured in
isolation, and a hands-on look at a flickering light remains on the list.

---

## Still open

- **The multiplayer name dialog on PowerPC**, issue #29. The collapse the issue
  describes no longer reproduces: measured with the dialog up, the G3 runs at
  66.7 fps on 10.4.11 (an 11% drop from the main menu) and 60.0 fps on 10.3.9
  (a 40% drop). The larger Panther cost is the first evidence for the text-input
  hypothesis above, but at 60 fps the mouse is sampled sixty times a second, so
  the unresponsive-clicks mechanism has no frame rate to stand on. What remains
  is thirty seconds at the machine confirming the dialog can be filled in and
  dismissed with the mouse.
- **A mod join across machines is kicked by the file consistency check**,
  issue #38. The reproduction predates the move to a single engine tree for all
  slices, so the first job is to re-run it, not to reason from the old logs.
- **Single-pass disables itself under fog**, which is backwards: single pass is
  the case that needs no fog compensation. Attempted, measured, and withdrawn;
  entry 13 above is the full account, issue #45 the mechanism, and the work is
  parked on the engine fork's `fog-singlepass-wip` branch.
