# Benchmarking Half-Life on the old-Mac fleet

A deterministic, demo-free FPS harness for the fleet (PPC G3/G4/G5 plus Intel). `timerefresh` renders N frames flat-out from a fixed
map and spawn, driven by `scripts/bench.sh` (one machine) and `scripts/fleet-bench.sh` (many, appending to `benchmarks/results.csv`).
This file also holds the vsync and MSAA measurements, the machine alias table and row-label registry (`tests/test-repo.py` reads
both), and the G5 "7 fps" investigation. Worked example: `docs/GL-OPTIMIZATION-CASE-STUDY.md`. Machine onboarding:
`docs/FLEET-ONBOARDING.md`.

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

See `docs/BENCH-MEASUREMENTS.md`.

## MSAA per GPU, measured on-cap (#41)

See `docs/BENCH-MEASUREMENTS.md`.

## Ripple upload CPU cost (v1.9.16, ADR 0019)

See `docs/BENCH-MEASUREMENTS.md`.

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

See `docs/BENCH-MEASUREMENTS.md`.

## A trap in fleet-bench.sh, found while measuring the above (fixed)

See `docs/BENCH-MEASUREMENTS.md`.
