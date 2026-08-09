# PowerPC findings

What running Half-Life on a 1999 Power Mac actually costs, one entry per finding.

Every change this port makes is a commit on our own branch of an upstream tree,
so `git log <upstream>..oldmac` is the complete record and this file is the
readable version of it. Fifty-six commits sit on the engine branch alone.

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
measurement method, and note entry 12 below for the part of this that was got
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

---

## What was got wrong

Publishing only the diagnoses that survived would misrepresent the work. Three
mechanisms were stated as fact and retracted in one session, which is what the
project's refutation-pass rule exists for.

### 9. The G3 guard-door freeze was blamed on a gcc miscompile

It is entry 1 above: `dladdr` and the leading underscore. The compiler was never
involved.

### 10. Two diagnoses in the endianness work, made, measured and withdrawn

Recorded in `PPC-PORT-NOTES.md`. Kept there rather than restated here.

### 11. The studio model byteswap that was applied twice

Mod game code carried a swap of the studio animation offsets in the client
renderer, on the theory that PowerPC needed it. The engine already swaps that
data, in `Mod_LoadCacheFile` and `R_StudioLoadHeader`, and does so for mods
exactly as for the base game. Applying it again is the identity undone: the
offsets go back to little-endian and the pointer arithmetic in
`StudioCalcBonePosition` walks off the model. It crashed the base game on every
PowerPC machine as soon as a real map loaded a studio model. The graft was
removed rather than fixed.

### 12. The single-pass world draw, twice

The +30% in entry 6 was real, but the first two attempts shipped visual faults:
a flicker traced to running `R_CheckLightMap` before the base draw, and a
dynamic-lightmap branch that rebound the base texture in a case that could never
fire ([`a95988c8`](../../), [`327336b5`](../../)). The second was found only by
reading the code back after the first was fixed.

### 13. The blue tint that was not a rendering fault at all

Screenshots came out blue. It was the screenshot capture path, not the renderer:
`ref_soft` wrote pixels as a native-order word instead of as bytes
([`a7bb7bd3`](../../)). What was on screen had always been correct.

---

## Still open

- **Menu frame rate collapses while the multiplayer name dialog is up**, on 10.3
  and 10.4. The 15-second `getaddrinfo` stall (entry 4) was a separate fault with
  the same appearance and is fixed; this is what remains. Leading candidate,
  **not measured**: SDL's Cocoa text input attaches an AppKit subview over the
  NSOpenGL content view and pre-Leopard AppKit composites it every frame.
  Issue #29.
- **Single-pass disables itself under fog**, which is backwards: single pass is
  the case that needs no fog compensation. Issue #31.
- **G3 menu text is blurry.** Issue #35.
