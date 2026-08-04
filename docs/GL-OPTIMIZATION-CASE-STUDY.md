# GL/GPU renderer optimization case study - Power Mac G3 (ATI Rage 128)

A worked, measured study of making Half-Life (Xash3D FWGS, GL renderer) render
faster on the weakest machine in the fleet:

- **yosemite** - Power Mac G3, 450 MHz PPC750, **ATI Rage 128** (OpenGL **1.1**,
  **2 texture units**, 16 MB VRAM), 640 MB RAM, Mac OS X **10.3.9** Panther.

Target: **800×600 fullscreen**, map `c0a0`. All numbers come from the demo-free
`timerefresh` harness (see `BENCHMARKING.md`), reproducible to ±0.7% on the G3.

**Baseline: 23.4 fps** (GL, 800×600 fullscreen, runs 23.41 / 23.34 / 23.37).

---

## Step 1 - Locating the bottleneck

Before touching a line of renderer code, profile the running engine. Panther has
no Xcode/gdb on this box, but it ships `/usr/bin/sample`, a statistical profiler
that attaches to a live PID over SSH and prints a symbol-level call tree. No kext,
no CHUD, no root. Helper: `scripts/prof-g3.sh` (launches the game headless, loads
a map, runs a warmup `timerefresh` as a trigger, then `sample`s the long flat-out
render that follows).

Result - `sample` of the live engine, `c0a0`, 800×600 GL, 30 s @ 10 ms,
**2789 main-thread samples**:

| Where the main thread actually is | Samples | % of frame |
|---|---:|---:|
| `SDL_GL_SwapWindow → CGLFlushDrawable → gldFlush → mach_msg_trap` - **blocked waiting on the GPU** | **2255** | **80.9 %** |
| CPU render submission - `SCR_UpdateScreen → R_RenderScene` and children | 489 | 17.5 % |
|  · `R_DrawWorld` (static world surfaces) | 160 | 5.7 % |
|  · `R_DrawBrushModel` (doors / moving brush entities) | 164 | 5.9 % |
|  · of which the separate 2nd lightmap pass (`R_BlendLightmaps → DrawGLPolyChain`) | ~60 | 2.1 % |

### Conclusion: the G3 is **GPU / fillrate bound**, not CPU bound

~81 % of every frame the CPU is *stalled in the buffer flush, waiting for the GPU
to drain the command queue*. That is the signature of a fillrate /
overdraw-limited frame. It is **not** vsync - we measure 23 fps, far below the
60 Hz cap, and `gl_vsync 0` is set during the measurement.

Two things follow directly:

1. **CPU-side micro-optimizations are near-worthless here.** Shaving the
   per-frame fog readback, `R_TextureAnimation`, `R_CheckLightMap`, etc. only
   trims the 17.5 % CPU slice - but the CPU already spends ~35 ms/frame *idle,
   spinning in the flush* waiting on the GPU. Making it wait faster changes
   nothing. (This retires the "drop the per-frame `pglIsEnabled(GL_FOG)`" idea as
   a measurable win.)
2. **The only lever that moves fps is cutting GPU fill work** - specifically
   **overdraw**.

### Where the overdraw comes from

The non-VBO world path rasterizes every world/brush surface **twice**:

- **Pass 1** - base texture. `R_DrawTextureChains → R_RenderBrushPoly` binds the
  surface's diffuse texture to TMU0 and emits the polygon (`DrawGLPoly`).
- **Pass 2** - lightmap. `R_BlendLightmaps → DrawGLPolyChain` re-emits the *same*
  geometry with the lightmap texture and a multiply blend
  (`glBlendFunc(GL_ZERO, GL_SRC_COLOR)`).

Two full-screen-ish layers of fragments for the same surfaces. On a fillrate-
bound Rage 128 that is the dominant cost.

> Note: the fork's single-pass **VBO** path (which *does* combine base+lightmap
> via multitexture) is **dead on the Rage 128** - the driver advertises
> `GL_ARB_vertex_buffer_object` but crashes (`SIGBUS`) inside `glBufferDataARB`.
> So the win must be captured in **immediate mode**, not via VBOs.

---

## Step 2 - Collapse the two passes into one (immediate-mode multitexture)

The Rage 128 has exactly **2 TMUs** and `GL_ARB_multitexture`, which is all a
single-pass lightmapped surface needs:

- **TMU0** = diffuse texture, `GL_REPLACE`
- **TMU1** = lightmap texture, `GL_MODULATE` (result = base × lightmap)
- one `glBegin/glEnd` per surface emitting both texcoords via
  `GL_MultiTexCoord2f(XASH_TEXTURE0, …)` + `GL_MultiTexCoord2f(XASH_TEXTURE1, …)`.

This halves the rasterized world/brush fragments - the exact thing the profile
says we are bound on. The engine already has every primitive required (the studio
path in `gl_alias.c` and the dead VBO path both do immediate/array multitexture),
so no new GL plumbing is needed.

### Confirming the hardware can actually do it

Half-Life defaults `gl_overbright` to **on**, which brightens lightmapped surfaces
×2. The classic two-pass path gets that ×2 for free from the framebuffer blend
(`glBlendFunc(GL_DST_COLOR, GL_SRC_COLOR)`). A single combined pass has no such
blend, so it must produce the ×2 inside the texture stage - which needs
`GL_ARB_texture_env_combine` (`GL_RGB_SCALE_ARB = 2`) on the lightmap TMU. If the
Rage 128 driver didn't expose that, single-pass would render the whole world at
half brightness.

Rather than guess, ask the driver. Xash already exposes the full GL capability
set through its `r_info` console command (`R_RenderInfo_f` →
`glGetString(GL_EXTENSIONS)` + `GL_MAX_TEXTURE_UNITS_ARB`). Launched headless on
the G3, it reports straight from the ATI driver:

```
GL_VENDOR:   ATI Technologies Inc.
GL_RENDERER: ATI Rage 128 OpenGL Engine
GL_VERSION:  1.1 ATI-1.3.28
GL_MAX_TEXTURE_SIZE:      1024
GL_MAX_TEXTURE_UNITS_ARB: 2
  ... GL_ARB_multitexture
  ... GL_ARB_texture_env_combine     <-- overbright x2 is available
  ... GL_ARB_texture_env_add
```

So the single-pass plan is sound on this exact GPU: 2 TMUs and
`texture_env_combine` are both present. (Note the driver does **not** advertise
`GL_ARB_vertex_buffer_object` at all here - consistent with VBO being a dead end.)

---

## Step 3 - Result: **+30% fps**, lighting unchanged

Implemented in `scripts/patch-single-pass-multitexture.py` (applied to the engine
tree by the build scripts). Scope: opaque world surfaces only
(`R_DrawTextureChains`), gated on a new cvar `gl_singlepass` (default `1`) so the
classic two-pass path is one console command away for A/B. Static-lightmap
surfaces are drawn base×lightmap in a single `glBegin/glEnd`; dynamic-lightmap
surfaces, tiled/conveyor surfaces, brush models, water and alpha keep the classic
path. When fog is on (or the GPU reports <2 TMUs) single-pass auto-disables.

Measured on the G3 (Rage 128, 800×600 fullscreen, map `c0a0`, demo-free
`timerefresh 300`), toggling only `gl_singlepass` inside one build:

| `gl_singlepass` | fps (3 runs) | order |
|---|---|---|
| **0** (classic two-pass) | 25.39 / 25.38 / 25.39 | measured cold, first |
| **1** (single-pass)      | 33.12 / 33.01 / 33.17 | second |
| 1 (single-pass)          | 32.94 / 33.08 / 32.94 | measured first |
| 0 (classic two-pass)     | 25.24 / 25.16 / 25.23 | second |

**Two-pass 25.4 fps → single-pass 33.1 fps = +30%.** The gap is identical whether
single-pass or classic runs first, so it is the render change, not warmup/cache
ordering. This lands exactly where the profile predicted: collapsing the world
from two rasterized layers to one directly relieves the fillrate bound.

**Lighting is unchanged.** A screenshot A/B (`gl_singlepass 1` vs `0`, same map)
shows identical brightness and lightmap gradients - the overbright ×2 done in the
TMU1 combiner (`GL_RGB_SCALE_ARB = 2`) matches the framebuffer-blend ×2 of the
classic path. No half-brightness, no missing lightmaps, no colour shift; the HUD
and viewmodel are unaffected because the two-TMU state is set up and torn down
around the world loop only.

> The standalone `bench.sh` cold baseline in this document (23.4 fps) was taken in
> an earlier session with a different warmup count; the same-build A/B above
> (25.4 vs 33.1) is the measure of the change itself, since it isolates the
> single variable.

### It generalises across the whole fleet

The same change (identical patch, same `gl_singlepass` toggle) was measured on
every machine - `c0a0`, 800×600, `timerefresh` - and wins everywhere, most on the
weakest GPU, exactly as a fillrate optimisation should:

| machine | GPU / OS | classic (0) | single-pass (1) | gain |
|---|---|---:|---:|---:|
| G3 yosemite | Rage 128 · 10.3 | 25.4 | 33.1 | **+30 %** |
| Intel mini  | GMA 950 · 10.7 | 102.5 | 120.7 | **+18 %** |
| G4 mini     | Radeon 9200 · 10.4 | 47.5 | 53.5 | **+12 %** |
| G5 iMac     | Radeon 9600 · 10.5 (windowed) | 86.9 | 95.8 | **+10 %** |
| G4 Quicksilver | Radeon 9000 · 10.4 | 52.4 | 54.1 | **+3 %** |

The ordering tracks how fillrate-starved each part is: the Rage 128 and the
integrated GMA 950 gain most; the discrete Radeons (more fill headroom, more
CPU/geometry bound at these settings) gain least, down to just +3 % on the
Quicksilver's Radeon 9000. No machine regressed and
lighting was verified unchanged on the G3 and G4 by screenshot A/B. The change is
arch-neutral and lives in one commit on our engine branch, so every slice builds
from it and it cannot be present on one architecture and missing on another.
