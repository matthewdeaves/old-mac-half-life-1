# Benchmarking Half-Life on the old-Mac fleet

A deterministic, demo-free FPS harness for the fleet (PPC G3/G4/G5 plus Intel).
Worked example: `docs/GL-OPTIMIZATION-CASE-STUDY.md`.

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

### Every row here is vsync OFF and every player runs vsync ON

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

### `scripts/fleet-bench.sh`, from the dev box

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

```
scripts/fleet-bench.sh -l baseline      -r gl -W 800 -H 600 yosemite
scripts/fleet-bench.sh -l fix-invalidenum -r gl -W 800 -H 600 yosemite
```

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
| `mini-intel`     | Mac mini (Intel, Lion)     | Intel GMA 950        | 10.7    | yes   |
| `mini-intel2`    | Mac mini (Macmini2,1)      | Intel GMA 950        | 10.7.5  | yes   |
| `mini-sl`        | Mac mini (Macmini3,1)      | NVIDIA GeForce 9400  | 10.6.8  | **no**|

PowerPC aliases are bench and test targets only. Four of the five slices
cross-compile on the Intel Lion minis; `arm64` is built on the orchestration box.
`docs/adr/0005`

**`mini-sl` cannot produce a valid GL benchmark as currently wired.** It has no
display attached and its NVIDIA 9400 will not hand out an accelerated context
without one, so `GL_RENDERER` comes back `Apple Software Renderer` and the number
is 5 to 10 times too low. `bench.sh` fails the run rather than printing it (pass
`-S` if software GL is the point). This is not a headless rule: measured
2026-08-08 over the same ssh path, `mini-intel2` is equally headless and its GMA
950 gives hardware GL, while `mini-g4` has a monitor and is fine. A DVI/HDMI
dummy EDID plug on `mini-sl` would fix it. It remains a functional test target
for the 10.6 floor, which is what it is there for.

Rows are labelled with the **ssh alias**, not the machine's own hostname, because
the G3 and the G5 each multi-boot several OSes from one IP and every partition
answers `hostname` identically. Rows written before 2026-08-08 carry hostnames
instead: `macs-Computer` is the G3 on whichever OS it had booted,
`intelmacmini233` is `mini-intel`, `g4-mini-1` is `mini-g4`. They are left as
measured.

The dual G5 (10.188.1.188, short name `powermacg5`) boots 10.3, 10.4 and 10.5 one
at a time, so like `yosemite` / `yosemite-tiger` it gets **one alias per partition
sharing the IP**, each with `HostKeyAlias` and `CheckHostIP no` so host keys never
clash. Onboard each partition separately per the runbook below or `fleet-bench.sh`
skips it as unreachable. Switching is remote, and the machine returns on the same
IP in about 60 seconds:

```sh
ssh g5-panther 'sudo bless --mount /Volumes/Tiger --setBoot && sudo shutdown -r now'
```

Panther's `bless` predates the double-dash spelling and wants `bless -mount DIR
-setBoot`; Tiger and Leopard take either. Check `bless --info --getBoot` first. A
new alias needs `-o StrictHostKeyChecking=accept-new` on the first connection,
because a non-interactive ssh cannot answer the new-host prompt and instead fails
with "Host key verification failed", which reads like a credential problem and is
not one.

The booted OS mounts the other two under `/Volumes`, so one partition stages for
all three: `scripts/deploy-dmg.sh g5-panther` plus one network copy of the retail
content, then `ditto` into `/Volumes/Tiger/Users/powermacg5/Desktop` and the
Leopard equivalent, then `chown -R 501:GID` (the Leopard account is in `staff`,
the other two in their own group).

## Onboarding a new partition or machine

Every partition is a separate OS install, so all of this is per partition.

1. **At the machine**: Remote Login on, and verify the short name and password
   over ssh, not just at the login window; `ssh` is usually the only open port.
   Read the short name from `ls /Users`, never guess: the dual G5's is
   `powermacg5`, not `g5`, and its auto-generated hostname was `powermacg527`.
2. **Add the alias** to `~/.ssh/config` from an entry for the same OS generation.
   Where partitions share an IP, `HostKeyAlias` plus `CheckHostIP no` are
   mandatory, or every boot trips a host-key mismatch:

   ```
   Host g5-panther
       HostName 10.188.1.188
       User powermacg5
       HostKeyAlias g5-panther
       CheckHostIP no
       IdentityFile ~/.ssh/id_rsa_retro
       IdentitiesOnly yes
       HostKeyAlgorithms +ssh-rsa
       PubkeyAcceptedAlgorithms +ssh-rsa
       KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
       Ciphers +aes256-cbc,aes128-cbc,3des-cbc
       MACs +hmac-sha1,hmac-md5
   ```

   The last two lines are what 10.3 and 10.4 sshd need beyond the Intel boxes;
   keep them for 10.5. Quote multi-word `-o` values on a modern client
   (`-o 'HostKeyAlgorithms=+ssh-rsa'`), or ssh reports "extra arguments at end of
   line".
3. **Install the key**: `~/.ssh/id_rsa_retro.pub` into `~/.ssh/authorized_keys`,
   `~/.ssh` mode 700 and the file 600, or sshd ignores it silently.
4. **Passwordless sudo, appended to `/etc/sudoers` directly** after a backup. sudo
   on 10.3 through 10.5 is 1.6.x (Panther 10.3.5 reports 1.6.6): **no
   `/etc/sudoers.d`, no `#includedir`**, so a file dropped there does nothing
   silently, and there is no `sudo -n`. Test with `sudo -k`, then plain
   `sudo whoami` over fresh non-interactive ssh; `root` with no prompt means it
   works. Bootstrap over stdin, there is no tty:

   ```sh
   ssh HOST 'echo PASSWORD | sudo -S -p "" sh -c "
     cp -p /etc/sudoers /etc/sudoers.bak.pre-retro &&
     cp /etc/sudoers /tmp/sudoers.new &&
     echo \"USER ALL=(ALL) NOPASSWD: ALL\" >> /tmp/sudoers.new &&
     visudo -c -f /tmp/sudoers.new &&
     cat /tmp/sudoers.new > /etc/sudoers && chmod 440 /etc/sudoers"'
   ```

   `cat >` not `mv`, to keep the inode and mode. The first password-bearing `sudo`
   prints the "usual lecture" banner; not an error.
5. **Stop it sleeping**, or it drops off mid-run. Panther's `pmset` takes only
   **`dim`, `sleep`, `spindown`** in minutes, no `displaysleep`, `disksleep` or
   `-g custom`: `sudo pmset -a sleep 0 dim 0 spindown 0`. It ships
   `sleep 10 dim 5 spindown 10`, so every fresh install needs this. Verify with
   `pmset -g live` or `pmset -g disk`; bare `pmset -g` is cached and can show old
   values for seconds.
6. **Name it.** Panther's `scutil --set` takes **only `ComputerName` and
   `LocalHostName`**, not `HostName` (Tiger adds it); its unix hostname is
   `HOSTNAME=` in `/etc/hostconfig`, shipped `-AUTOMATIC-`. Set that to the alias
   so logs and `uname -a` name the partition, back the file up, and set
   `LocalHostName` to the alias to keep partitions distinct on Bonjour. Record
   what you set.
7. **Confirm the IP is stable**, since the aliases hardcode it;
   `ipconfig getpacket en0` shows whether the lease is DHCP and who issued it.
   Partitions share the NIC and MAC, so one DHCP reservation pins all three.
8. **Bring the OS to the target version.** PowerPC slices target 10.3.9, so a
   10.3.x partition needs the 10.3.9 combo updater. No modern TLS here: copy it
   from another fleet box over ssh, never download on the old machine, and `md5`
   both ends. Copies:
   `yosemite:/Users/mini/Documents/MacOSXUpdateCombo10.3.9.dmg` and
   `~/Documents/MacOSXUpdateCombo10.3.9.dmg` on the dev box, both 118917398 bytes,
   md5 `d8fdc52ba42792a53092e03a26779914`. Old `scp` needs `-O` from a modern client.
   Leave the installer for the machine's owner.
9. **Record the specs.** Panther's `system_profiler` has **no
   `SPDisplaysDataType`**: ask for `SPHardwareDataType`, `SPMemoryDataType` and
   `SPPCIDataType`, and read the GPU from the PCI list. `-listDataTypes` shows
   what an OS offers.
10. Only then install the game and take a first benchmark.

Tiger differs on three points: sshd is OpenSSH 4.x and takes the same legacy
options, `pmset` is closer to modern syntax, and `scutil` and `system_profiler`
gain the `HostName` and `SPDisplaysDataType` Panther lacks. The sudo 1.6 trap is
unchanged on Tiger and Leopard.

### Current state of the dual G5

All three partitions are onboarded per the runbook above and carry the game:
`~/Desktop` holds a release `.dmg` plus a `Half-Life/` folder with the three app
bundles and a full retail `valve/`, md5 verified against the dev box. (The
deployed version moves every release and is not tracked here; `scripts/deploy-dmg.sh`
is what puts it there.)

| partition | slice | OS | alias | state |
|---|---|---|---|---|
| 1 | `disk0s3`, "Panther" | 10.3.9 Panther, build 7W98 | `g5-panther` | onboarded, game deployed |
| 2 | `disk0s5`, "Tiger" | 10.4.11 Tiger, build 8S165 | `g5-tiger` | onboarded, game deployed |
| 3 | `disk0s7`, "Leopard" | 10.5.8 Leopard, build 9L31a | `g5-desktop` | onboarded, game deployed |

One 465.8 GB drive split into three 155.1 GB HFS+ partitions, all visible from
whichever OS is booted, so the volume names tell you which one you are in.

### Dual G5 specs, as the machine reports them

| item | value |
|---|---|
| `sw_vers` | Mac OS X 10.3.9, build 7W98 (the install disc shipped 10.3.5, build 7P134) |
| `uname -a` | `Darwin g5-panther 7.9.0 Darwin Kernel Version 7.9.0: Wed Mar 30 20:11:17 PST 2005; root:xnu/xnu-517.12.7.obj~1/RELEASE_PPC Power Macintosh powerpc` |
| `hw.model` | `PowerMac7,3` (Power Mac G5, Early 2005) |
| `hw.ncpu` | 2 |
| `hw.cpusubtype` | 100, that is `ppc970`; `machine` also prints `ppc970` |
| `hw.memsize` | 2684354560, that is 2.5 GB (2x 1 GB + 2x 256 MB PC3200 DDR, 4 slots free) |
| CPU | PowerPC G5 (3.1) at 2.7 GHz, 512 KB L2 per CPU, 1.35 GHz bus, AltiVec present |
| Boot ROM | 5.2.4f1 |
| GPU | AGP slot 1, `ATY,RV351`, ATI (0x1002) device `0x4150`, ROM 113-A58503-115, 256 MB VRAM, one LCD attached |
| Ethernet | `en0`, 1000baseTX full duplex, MAC `00:14:51:03:6e:8a` |
| Address | DHCP, 10.188.1.188, 24 hour lease from the router at 10.188.1.1 |

`hw.cpusubtype` 100 confirms the slice table: `dyld` grades by subtype and there is
no `ppc970` slice, so this machine loads `ppc7400` exactly as a G4 does.

Panther names no card and reports an RV350-class device ID rather than the
R350/R360 of a Radeon 9800. Tiger's `SPDisplaysDataType`, which Panther lacks,
names it an **ATI Radeon 9650**, 256 MB, driving a 1680x1050 Cinema display with
the second connector empty.

The machine is **converted from liquid to air cooling**, so throttling is fair to
suspect on an odd result. Read on Panther and again on Tiger: `hw.cpufrequency`
2700000000, `hw.busfrequency` 1350000000, `pmset` `reduce 0`, so both CPUs run
full speed. No temperature has ever been read: Panther exposes no usable `ioreg`
sensor node and the fleet carries no tool for it. It sustained 137 to 185 fps
across an hour of back-to-back benching on all three partitions, run to run within
1 percent.

### Names set on each partition

| partition | `ComputerName` | `LocalHostName` | unix hostname |
|---|---|---|---|
| 1, Panther | `Power Mac G5 Panther` | `g5-panther` | `HOSTNAME=g5-panther` in `/etc/hostconfig`, was `-AUTOMATIC-` |
| 2, Tiger | `Power Mac G5 Tiger` | `g5-tiger` | `scutil --set HostName g5-tiger` |
| 3, Leopard | `Power Mac G5 Leopard` | `g5-leopard` | `scutil --set HostName g5-leopard` |

Tiger and Leopard ship no `HOSTNAME=` line in `hostconfig`, so do not look for one.
Backups: `/etc/sudoers.bak.pre-retro-2026-07-27` on all three partitions,
`/etc/hostconfig.bak.pre-retro-2026-07-27` on Panther.

### The 7 fps on this machine did not reproduce (2026-07-28)

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

### A trap in fleet-bench.sh, found while measuring the above (fixed)

`fleet-bench.sh` parsed `-s fullscreen|borderless|windowed` into `SCREENMODE` but
never passed it to `bench.sh`, which used its own default of `fullscreen`. The
CSV records what actually ran, so every row is honest, but the request was lost
with no warning. It now canonicalises the mode, passes `-s` through, and compares
it against field 4 of the line `bench.sh` returns, shouting `SCREENMODE MISMATCH`
on stderr if the two disagree.
