# Benchmarking Half-Life on the old-Mac fleet

A deterministic, demo-free FPS harness for the fleet (PPC G3/G4/G5 plus Intel).
`timerefresh` renders N frames flat-out from a fixed map and spawn, driven by
`scripts/bench.sh` (one machine) and `scripts/fleet-bench.sh` (many, appending to
`benchmarks/results.csv`). This file also holds the vsync and MSAA measurements, the
machine alias table and row-label registry (`tests/test-repo.py` reads both), and the
G5 "7 fps" investigation. Worked example: `docs/GL-OPTIMIZATION-CASE-STUDY.md`.
Machine onboarding: `docs/FLEET-ONBOARDING.md`.

## Why not `timedemo`?

Demos are broken on the big-endian PowerPC builds both ways: recording crashes
with `SIGBUS at 0x4` in the demo writer ("Spooling demo header"), and an
Intel-recorded `.dem` floods `svc_bad` / `CL_EDICT_NUM: bad number`, a
little-endian stream read big-endian. `timedemo` is also realtime-paced (it
sleeps to the ~30 Hz demo/server rate), capping fast machines at ~30 fps, so it
cannot report throughput.

## The `timerefresh` command

Our engine branch carries an id-engine-style `timerefresh` (commit "engine: add a
demo-free timerefresh benchmark command"). From an active map it renders N frames
flat-out, no host-loop pacing, spinning the view a full 360° from the map spawn:

```
timerefresh: <N> frames <T> seconds <F> fps
```

Demo-free, so identical on Intel and PPC. Deterministic (fixed map, spawn, sweep,
frame count), reproducible to **±0.7%** on the G3. Flat-out, so it measures render
throughput, not a 30 Hz cap; the sweep covers the whole scene around the spawn,
so the number is average-case geometry and overdraw, not one lucky angle.

```
map c0a0
timerefresh 300     # render 300 frames flat-out, print result
```

## Scripts

### `scripts/bench.sh`, one machine

POSIX sh, 10.3 Panther through modern macOS. Finds the deployed `Half-Life.app`,
pins a video mode, runs warmup plus measured passes, prints CSV.

```
bench.sh [-r gl|soft] [-W width] [-H height] [-s fullscreen|borderless|windowed]
         [-f frames] [-n runs] [-w warmups] [-m map] [-a /path/Half-Life.app]
         [-t timeout_s] [-A "launch args"]
```

`-A` passes its argument through to the launcher. It exists because the pixel
format is fixed when the GL context is created, so the G3 knobs cannot be
reached by a `-x` console cvar the way a renderer setting can. The G3 profile's
flags each have a `-no` form for exactly this: `-A "-nobpp"`, `-A "-nogldepth16"`,
`-A "-noglnostencil"`, `-A "-nobilinear"`.

Defaults: `gl`, `800x600`, `fullscreen`, 300 frames, 3 runs, 1 warmup, map `c0a0`.
CSV columns:
`host,renderer,resolution,screenmode,map,frames,fps_min,fps_med,fps_max,fps_runs`

- Resolution is pinned by the `-width`/`-height` and screen-mode **dash parms**,
  read at video init, which outrank `config.cfg`. The `width`/`height`/
  `fullscreen` **cvars** do not: config overrides them, and a `vid_restart` in
  windowed mode lets SDL refit the window to the screen.
- Fullscreen is the default: it matches how the game is played and avoids
  WindowServer compositing. On the G3, windowed 1024×649 measured ~16.5 fps
  against fullscreen 800×600 ~24.5 fps.
- The warmup pass is discarded, so first-frame and texture-upload stalls stay out
  of the median.
- `gl_vsync 0` is set before measuring, so the swap never blocks on vblank, and
  the engine's own `MODE:` line goes into the human-readable stderr note, where it
  confirms whether the requested resolution took.

## Every row here is vsync OFF and every player runs vsync ON

`gl_vsync` defaults to 1 (`ref_common.c:35`), `configs/userconfig.cfg` pins it to
1 on every machine, and `bench.sh` turns it off for the measurement. So a number
in `results.csv` is the RENDER COST. It is not what the player sees, and the two
can differ by a factor of three.

Measured 2026-08-23, map `crossfire`, 300 frames, median of 3, same resolution in
both legs, `gl_vsync` the only difference:

| machine | vsync 0 | vsync 1 | regime |
| --- | --- | --- | --- |
| g5-desktop 1024x768 | 181.6 | 60.007 | hard 60 Hz cap, 3x headroom |
| mini-g4 1024x768 | 62.9 | 42.276 | above the refresh, no headroom |
| yosemite 800x600 | 58.5 | 41.1 | same, on a slower machine |

There are three regimes and only the first is intuitive.

**Capped.** The G5 renders 181 and shows 60. Anything costing less than that
headroom is free to the player. Measured: `r_shadows 1` costs 1.45% off-cap and
reads 60.007 both ways on-cap.

**Just above the refresh.** 42.276 is neither 60 nor 30. A frame that misses a
16.7 ms deadline waits for the next vblank, so the average lands between the two
rates and there is NO headroom. A 1% render cost can take several fps off the
vsynced average, because it moves more frames across the deadline.

**Below the refresh.** The G3 pays close to the raw cost: `r_shadows` measured
-7.4% off-cap and -8.0% on-cap.

So quote both numbers whenever a decision turns on them, and never infer the
on-cap figure by taking a ceiling of the off-cap one.

## fps above the refresh rate on macOS 10.14+ (#44)

On `imac-2019` (15.7.9, AMD Radeon Pro 580X) `gl_vsync 1` measured 62-120 fps
against a display measured at 59.9929 Hz
(`CVDisplayLinkGetNominalOutputVideoRefreshPeriod`), not a stable ~60 fps cap.
`CGLGetParameter(kCGLCPSwapInterval)` read back 1 on the live process: the
interval is set and accepted, but macOS 10.14+'s GL-on-Metal path does not
block the swap on it.

`Host_CalcFPS()` (`engine/common/host.c:495-531`) compounds this on our
engine specifically: the host-side `fps_max` throttle (default 72) is
deliberately disabled whenever `gl_vsync` is nonzero, trusting the driver to
pace instead (`Host_Autosleep`, `host.c:538`). So on a Mac where the driver
does not gate the swap, nothing bounds the fps.

**On 10.14+, an fps reading above the display's refresh rate is not by
itself evidence of tearing or a missed cap.** The WindowServer still
presents at the display's real rate underneath a legacy GL context; fps past
that point is render throughput, not frames actually shown. Judge vsync
correctness on these OSes by what is on screen (or a player report), not by
an fps counter. `imac-2019` play was reported smooth by the user at the time
of this measurement.

## MSAA per GPU, measured on-cap (#41)

2026-09-23, v1.9.19, `crossfire`, 300 frames, median of 3, each machine at its
shipping resolution borderless, MSAA 0 and 2 interleaved over two rounds, the
effective values read back from the engine log:

| machine | MSAA | vsync 0 | vsync 1 |
| --- | --- | --- | --- |
| mini-g4 Radeon 9200, 1024x768 | 0 | 112.7 | 59.9 |
| | 2 | 62.4 | 42.18 |
| g5-tiger Radeon 9650, 1680x1050 | 0 | 118.6 | 60.008 |
| | 2 | 71.1 | 60.008 |

2x is free on the G5 and costs the mini G4 a locked 60, so the launcher forces
0 on the Radeon 9200 (RV280) only.

## Ripple upload CPU cost (v1.9.16, ADR 0019)

`tests/test-ripples.py`, median CPU time for 10000 updates, before/after, same
pixels: G3 76.7 s to 27.5 s, mini G4 36.6 s to 10.2 s, Intel mini 4.90 s to
2.85 s, Apple Silicon 0.245 s to 0.160 s. Whole-game fps on `crossfire` (no
water in view) did not move outside run-to-run spread.

## `scripts/fleet-bench.sh`, from the dev box

Ships `bench.sh` to each reachable machine over SSH, runs it, appends one
timestamped, labelled row per machine to `benchmarks/results.csv` (rolling, never
truncated). Unreachable machines are skipped.

```
scripts/fleet-bench.sh [-l label] [-r gl|soft] [-W w] [-H h]
                       [-s fullscreen|borderless|windowed]
                       [-f frames] [-n runs] [-w warmups] [-t timeout]
                       [-m map] [-A "launch args"] [host ...]
```

Default fleet: `yosemite quicksilver mini-g4 imac-g5 mini-intel`. Name hosts
explicitly to bench whichever partitions are actually booted, since the G3 and
the G5 answer on one IP per machine and only one OS at a time is up. `-l` tags a
run so before/after rows diff easily:

`qemu-tiger3d` (POLICY "Machines": iterative target, real hardware is for
final testing before a release) is not in the default fleet: it is one shared
VM on the workstation, claimed through the same `pick-bench-host.sh` lock as
every other machine, and every other port benches on it too. Start it first
with `scripts/shared.sh qemu-vm.sh up`, deploy with `scripts/deploy-dmg.sh
qemu-tiger3d`, then `scripts/fleet-bench.sh -t 300 ... qemu-tiger3d` (the
300 s timeout the Quake ports use for it; TCG emulation is slow). Check the
first run's picture before quoting fps, with `scripts/vm-frame-check.sh`
(host-side `qemu-vm.sh screendump`, build-host#123; `docs/VM-TIGER.md`), not `hw-shot.sh`: this
VM's guest-side readback comes back solid black (halflife#51, qemu#7/#8), a
capture-path bug distinct from whatever fps or rendering the engine actually
produced. A rendering fault seen only in the VM goes to the manager for
qemumac, not into the engine.

```
scripts/fleet-bench.sh -l baseline      -r gl -W 800 -H 600 yosemite
scripts/fleet-bench.sh -l fix-invalidenum -r gl -W 800 -H 600 yosemite
```

## old-mac-build-host first: the proven jobs

Smoke runs and single-shot bench checks go through `old-mac-build-host` by default,
not by running the scripts by hand (user's cutover instruction,
`retro-agents` b98bd74). The CI runs this repo's own scripts from a clone at
`~/repos/old-mac-half-life-1` on the build host, re-synced to `origin/main` before every
build, under the same bench lock; the CI is only the trigger and the queue.
Proven equivalent to direct runs on 2026-08-23, build-host#15: smoke four
times over, bench on imac-g5 47.8 fps direct vs 45.2 via CI, ordinary
variance.

Jobs include: `smoke-halflife-<m>` for g3, g5, imac-g5,
mini-g4, mini-intel, mini-sl, quad, quicksilver, sawtooth, and
`bench-halflife-imac-g5`. The bench job runs `fleet-bench.sh -n 1 imac-g5`
with `BENCH_CSV` redirected to an output file on the build host, so this repo's tracked `benchmarks/results.csv` is never touched by a
job. A CI bench row is a candidate, not a result: fetch it, sanity-check
the run the same as a direct one (spread, cold start, vsync state), then
append and commit by hand with the reason.

Run `smoke-dmg.sh` or `fleet-bench.sh` directly only when the CI on `old-mac-build-host` is down, or
when no job covers the shape: bench exists for imac-g5 at `-n 1` only, so
multi-leg interleaved A/B series and every other machine's bench are still
direct runs until jobs grow to cover them.

## Machines (SSH aliases)

| alias            | machine                    | GPU                  | OS      | hw GL |
|------------------|----------------------------|----------------------|---------|-------|
| `yosemite`       | Power Mac G3 (ppc750)      | ATI Rage 128 (GL1.1) | 10.3.9  | yes   |
| `yosemite-tiger` | Power Mac G3, partition 2  | ATI Rage 128         | 10.4.11 | yes   |
| `quicksilver`    | Power Mac G4 Quicksilver   | -                    | 10.4    | yes   |
| `mini-g4`        | Mac mini G4 (ppc7450)      | ATI Radeon 9200 (RV280) | 10.4.11 | yes |
| `imac-g5`        | iMac G5                    | ATI Radeon 9600      | 10.5    | yes   |
| `g5-panther`     | Power Mac G5 dual 2.7 GHz, partition 1 | ATI Radeon 9650 | 10.3.9 | yes |
| `g5-tiger`       | Power Mac G5 dual 2.7 GHz, partition 2 | ATI Radeon 9650 | 10.4.11 | yes |
| `g5-desktop`     | Power Mac G5 dual 2.7 GHz, partition 3 | ATI Radeon 9650 (RV351) | 10.5.8 | yes |
| `mini-intel`     | Mac mini, Core 2 T7600 2.33 GHz, 4 GB | Intel GMA 950 | 10.7.5 | yes |
| `mini-intel2`    | Mac mini, Core 2 T5600 1.83 GHz, 2 GB | Intel GMA 950 | 10.7.5 | yes |
| `mini-sl`        | Mac mini (Macmini3,1)      | NVIDIA GeForce 9400  | 10.6.8  | **no**|
| `imac-2019`      | iMac 5K 2019, i5-9600K     | AMD Radeon Pro 580X  | 15.7.9  | yes   |
| `g5-leopard`     | the same partition as `g5-desktop`, under its other name | ATI Radeon 9650 | 10.5.8 | yes |
| `quad-leopard`   | Power Mac G5 quad, partition 1 | -                | 10.5    | -     |
| `quad-tiger`     | Power Mac G5 quad, partition 2 | -                | 10.4    | -     |
| `sawtooth`       | Power Mac G4 Sawtooth      | -                    | -       | -     |
| `qemu-tiger3d`   | QemuMac VM (emulated G4, ppc7400) on the workstation | emulated ATI Radeon 9700 (R300) | 10.4.6 | yes |

A `-` means the field is not recorded here, not that the machine lacks it. The
quad G5 and the Sawtooth have **no rows in `results.csv`**; they are listed
because they are live ssh aliases, so a bench on one would otherwise be rejected
by the label check below.

`g5-desktop` and `g5-leopard` are one machine, one partition, two names: they
share a single `Host` stanza in `~/.ssh/config` with `HostKeyAlias g5-desktop`.
Aggregating the two as separate machines double-counts one partition, which is
why 39 rows read as two things.

**Each machine also answers to a second alias**, so both spellings can appear in
the `host` column and both are valid:

| primary | synonym | | primary | synonym |
|---|---|---|---|---|
| `yosemite` | `g3-panther` | | `imac-g5` | `g5-imac` |
| `yosemite-tiger` | `g3-tiger` | | `quad-leopard` | `g5quad-leopard` |
| `quicksilver` | `g4-quicksilver` | | `quad-tiger` | `g5quad-tiger` |
| `mini-g4` | `g4-mini` | | `sawtooth` | `g4-sawtooth` |
| `mini-intel` | `lion-build1` | | `mini-intel2` | `lion-build2` |
| `mini-sl` | `snow-build1` | | | |

PowerPC aliases are bench and test targets only. Four of the five slices
cross-compile on the Intel Lion minis; `arm64` is built on the orchestration box.
`docs/adr/0005`

**`mini-sl` now produces a valid GL benchmark.** Until issue #50, it had no
display attached and its NVIDIA 9400 would not hand out an accelerated context
without one, so `GL_RENDERER` came back `Apple Software Renderer` and the number
was 5 to 10 times too low (`bench.sh` failed the run rather than printing it,
`-S` was needed if software GL was the point). Measured 2026-09-27: `mini-sl`
now reports a real attached display (`system_profiler`: DP monitor, 1920x1080,
Online: Yes) and `bench-evidence.sh` returns the hardware renderer,
`NVIDIA GeForce 9400 OpenGL Engine`, at a plausible fps for the class. This is
not a headless rule generally: measured 2026-08-08 over the same ssh path,
`mini-intel2` is equally headless and its GMA 950 gives hardware GL, while
`mini-g4` has a monitor and is fine; `mini-sl` specifically needed a display
(a dummy EDID plug or better) and now has one.

## Row labels, and the seven historical ones

Rows are labelled with the **ssh alias**, never the machine's own hostname,
because the G3 and the G5 each multi-boot several OSes from one IP and every
partition answers `hostname` identically. `bench.sh` now **requires** `-N` and
refuses to run without it; there is no hostname fallback to inherit.

Twenty-three of the 164 rows predate that and carry a hostname. They are **left
as measured**: the label is what was recorded, and a row rewritten years later is
worse than an odd one. This table is how they aggregate instead.

| label | machine | partition | how it is known |
|---|---|---|---|
| `macs-Computer`   | the G3     | see below    | the G3's own short name |
| `yosemite-g3`     | the G3     | unresolved   | name |
| `g4733`           | `quicksilver` | 10.4      | the Quicksilver is the fleet's only 733 MHz G4 (README) |
| `quicksilver-g4`  | `quicksilver` | 10.4      | name |
| `g4-mini-1`       | `mini-g4`  | 10.4         | name |
| `imacg5siMacG5`   | `imac-g5`  | 10.5         | name |
| `intelmacmini233` | `mini-intel` | 10.7       | 2.33 GHz, and only `mini-intel` is 2.33 GHz |

Two of these do not resolve completely, and the gap is the point of the table:

**`macs-Computer` names the machine but not the OS**, which is exactly the
failure the alias rule exists to prevent. Of its 10 rows the run tag recovers
three: `g3-panther-verify` is Panther, `v1.5.0-g3-tiger-singlepass` and
`v1.5.0-g3-tiger-twopass` are Tiger. The other seven are the G3 on an unknown
partition and cannot be compared against either alias.

**`intelmacmini233` resolves to `mini-intel`, on two independent facts.** The
hostname encodes 2.33 GHz and `mini-intel` is the only 2.33 GHz machine in the
fleet. Date order agrees: every `intelmacmini233` row falls on or before
2026-08-05, and the first `mini-intel2` row is 2026-08-08.

This entry was first written here as unresolvable, on the stated grounds that
both Intel minis were Macmini2,1 at 2.33 GHz so the clock could not separate
them. That was wrong, and it came from the shared model identifier rather than
from either machine. Measured 2026-08-23, over ssh, on the machines themselves:

    mini-intel    Core 2 T7600 @ 2.33 GHz   4 GB   4 MB L2   Macmini2,1
    mini-intel2   Core 2 T5600 @ 1.83 GHz   2 GB   2 MB L2   Macmini2,1

**They are not interchangeable and must never be pooled into one Intel class.**
`hw.model` is `Macmini2,1` on both and the OS is 10.7.5 on both, so nothing but
the CPU tells them apart. `mini-intel` is 27% faster by clock alone, with twice
the L2 and twice the RAM. Rows carrying the two aliases are already distinct in
`results.csv`; the hazard is aggregating them, not the labels.

The two styles overlap in time, so a date does not tell you which a row uses:
hostname labels run 2026-07-24T09:58 to 2026-08-05T00:54, and alias labels start
2026-07-24T13:28.

**Aggregate by machine, not by label.** `g5-panther`, `g5-tiger` and `g5-desktop`
are three partitions of one Power Mac G5: distinguishing them is right for an OS
comparison and wrong for a hardware one, and nothing in the row says which
question is being asked. The same holds for `yosemite` and `yosemite-tiger`.

`tests/test-repo.py` enforces this section: every label in `results.csv` must
appear either in the alias table above or in this one. A bench on a machine that
is in neither fails the repo test until it is added here. Onboarding runbook:
`docs/FLEET-ONBOARDING.md`.

The dual G5 boots three OSes from one IP, so each partition has its own alias.
Switching and staging partitions: `docs/FLEET-ONBOARDING.md`.

## The 7 fps on this machine did not reproduce (2026-07-28)

Onboarding recorded **7.0 fps** on `c0a0` on the Leopard partition. It did not
reproduce on re-measurement across all three partitions, the mechanism is not
known, and there is no longer a fault to explain: every partition of the dual 2.7
is the fastest PowerPC box in the fleet. The slow rows stay in
`benchmarks/results.csv` under `g5-leopard-onboard`; the 2026-07-28 rows carry
`g5-osdiff-*`, `g5-ressweep-*` and `g5-leopard-gl-*`, and the two `ref_soft` rows
`g5-leopard-SOFT-not-comparable-to-gl`, because a soft number must never be read
against a gl one.

All rows below are `gl`, map `c0a0`, `gl_vsync 0`, one warmup discarded, median
of three; `MODE:` is the engine's own line, not the request.

| partition | requested | engine `MODE:` | median fps |
|---|---|---|---|
| Panther 10.3.9 | 320x240 | 640x480 | 170.8 |
| Panther 10.3.9 | 800x600 | 800x600 | 137.2 |
| Panther 10.3.9 | 1280x1024 | 1680x1050 | 56.2 |
| Panther 10.3.9 | 1680x1050 | 1680x1050 | 56.5 |
| Tiger 10.4.11 | 800x600 | 800x600 | 144.9 |
| Tiger 10.4.11 | 1680x1050 | 1680x1050 | 58.0 |
| Leopard 10.5.8 | 320x240 | 640x480 | 184.4 |
| Leopard 10.5.8 | 800x600 | 800x600 | 149.3 |
| Leopard 10.5.8 | 800x600 windowed | 800x600 | 140.7 |
| Leopard 10.5.8 | 1680x1050 | 1680x1050 | 56.4 |

Fillrate scales close to linearly: fit the Panther rows and it is about **3.3 ms
fixed cost plus 8.2 ns per thousand pixels**, within a few percent from 640x480
to 1680x1050. A retracted earlier reading, "3.5x the pixels costs nothing, so it
is not fillrate", came from the CSV recording the request rather than the mode;
do not carry it forward.

**The driver substitutes modes, per machine, and it bites fleet comparisons.**
The substitution shows only in `MODE:`: here 320x240 landed on **640x480** and
1280x1024 on **1680x1050**, and under `-r gl -W 800 -H 600 -s fullscreen`
`imac-g5` reports `MODE: 1440x900`, its native panel size, and measures 61.7 fps,
where the dual G5 reports `MODE: 800x600`. `bench.sh` records the request, so
read `MODE:` when the pixel count matters; historical fullscreen rows differ in
pixel count. The `windowed` iMac G5 rows of 2026-07-24 (86.8 and 95.8 fps) really
were 800x600, and the dual G5's 140.7 fps windowed 800x600 is about 1.6x those,
the shape expected from two cores at 2.7 GHz against one at 1.8.

Ruled out, each by measurement:

- **Hardware, GPU, cooling conversion**: same machine and card, three OSes, 137 to
  149 fps at 800x600.
- **OS and ATI driver family**: Leopard, the partition the 7 fps came from, is the
  fastest. `GL_VERSION` differs (`1.5 ATI-1.3.42` Panther, `1.5 ATI-1.4.18` Tiger,
  `2.0 ATI-1.5.48` Leopard) to no measurable effect.
- **Just-booted transient**: 149.1 fps 41 seconds after a Leopard boot.
- **Spotlight indexing**: 136.2 fps during a forced reindex (`mdutil -E /`, `mds`
  over 100 percent CPU, `mdworker` at 47).
- **CPU contention**: 89.6 fps with both cores pinned by busy loops; total
  starvation costs 40 percent, not 20x.
- **Software-rasterizer fallback**: `ref_soft` measures 28.9 fps at 800x600, four
  times *faster* than 7 fps, and 15.6 fps at 1680x1050.

**`ref_soft` renders in wrong colours** on this fleet: blocky, dark, light sprites
magenta where they should be white, confirmed on the G5 under Leopard. That is
`ref_soft` big-endian palette behaviour, not a GL regression; `gl_texture_nearest`
was `0` throughout and GL renders correctly. Expect a bystander watching a
`bench.sh -r soft` run to call it a rendering bug.

**Provenance caveat for rows dated on or before 2026-07-27**: because of the trap
below, any row reading `fullscreen` may have asked for another mode. `windowed`
and `borderless` rows came from a direct `bench.sh` call and cannot be affected,
since `fleet-bench.sh` could never produce one. The five `v1.0.0` rows of
2026-07-25 share one timestamp, which only `fleet-bench.sh` produces, so that
batch ran fullscreen whatever it asked for.

## A trap in fleet-bench.sh, found while measuring the above (fixed)

`fleet-bench.sh` parsed `-s fullscreen|borderless|windowed` into `SCREENMODE` but
never passed it to `bench.sh`, which used its own default of `fullscreen`. The
CSV records what actually ran, so every row is honest, but the request was lost
with no warning. It now canonicalises the mode, passes `-s` through, and compares
it against field 4 of the line `bench.sh` returns, shouting `SCREENMODE MISMATCH`
on stderr if the two disagree.
