# Benchmark measurements

Measured MSAA, ripple and refresh-rate costs, plus dated machine findings.
The runtime benchmark procedure stays in `docs/BENCHMARKING.md`.
These are recorded measurements; use their named artifact and hardware when comparing.

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
