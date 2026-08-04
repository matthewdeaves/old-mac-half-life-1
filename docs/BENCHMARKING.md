# Benchmarking Half-Life on the old-Mac fleet

A deterministic, demo-free FPS harness for measuring engine/renderer performance
across the fleet (PPC G3/G4/G5 + Intel), used to drive and verify the G3 GL
optimization work (see `docs/GL-OPTIMIZATION-CASE-STUDY.md`).

## Why not `timedemo`?

The stock `timedemo` benchmark depends on the demo subsystem, which is broken on
the big-endian PPC builds in **both** directions:

- **Recording crashes** on PPC - `SIGBUS at 0x4` in the demo writer ("Spooling
  demo header").
- **Playing an Intel-recorded `.dem` fails** on PPC - a flood of `svc_bad` /
  `CL_EDICT_NUM: bad number` (little-endian demo stream read by a big-endian
  engine).

On top of that, this Xash fork's `timedemo` is **realtime-paced** (it sleeps to
the ~30 Hz demo/server rate), so it caps fast machines at ~30 fps and can never
report true throughput. Fixing PPC demos is tracked separately (they are a real
Half-Life feature) but is not needed for benchmarking.

## The `timerefresh` command

We added a classic id-engine-style `timerefresh` command to the engine
(`scripts/patch-timerefresh.py`, applied to both engine trees). From an active
map it renders a fixed number of frames **flat-out** (no host-loop pacing) while
spinning the view a full 360° from the map spawn, then prints:

```
timerefresh: <N> frames <T> seconds <F> fps
```

Properties that make it the right measurement tool:

- **Demo-free** → immune to every big-endian demo bug; identical on Intel + PPC.
- **Deterministic** → fixed map + fixed spawn + fixed 360° sweep + fixed frame
  count. On the G3 it is reproducible to **±0.7%** across runs.
- **Flat-out** → renders as fast as the machine can, so it measures real render
  throughput (not a 30 Hz cap). Directly sensitive to GL/renderer changes.

Usage in-game or headless:

```
map c0a0
timerefresh 300     # render 300 frames flat-out, print result
```

## Scripts

### `scripts/bench.sh` - run on a single machine

POSIX sh (runs on 10.3 Panther through modern macOS). Locates the deployed
`Half-Life.app`, pins a deterministic video mode, runs warmup + measured
`timerefresh` passes, and prints a CSV line.

```
bench.sh [-r gl|soft] [-W width] [-H height] [-s fullscreen|borderless|windowed]
         [-f frames] [-n runs] [-w warmups] [-m map] [-a /path/Half-Life.app]
         [-t timeout_s]
```

Defaults: `gl`, `800x600`, `fullscreen`, 300 frames, 3 runs, 1 warmup, map
`c0a0`.

Key details:

- **Resolution is pinned by the `-width`/`-height` *dash* parms** and the
  screen-mode dash parm (`-fullscreen`/`-borderless`/`-windowed`). These are read
  at video init and take priority over `config.cfg`; the `width`/`height`/
  `fullscreen` *cvars* do **not** (config overrides them, and a `vid_restart` in
  windowed mode lets SDL refit the window to the screen).
- **Fullscreen is the default** - it matches how the game is actually played and
  avoids the macOS WindowServer compositing overhead that windowed mode incurs.
  (Windowed 1024×649 measured ~16.5 fps vs fullscreen 800×600 ~24.5 fps on the
  G3 - the compositor and extra pixels both cost.)
- The **first (warmup) pass is discarded** so texture-upload / first-frame
  stalls don't skew the median.
- Output CSV columns:
  `host,renderer,resolution,screenmode,map,frames,fps_min,fps_med,fps_max,fps_runs`

### `scripts/fleet-bench.sh` - orchestrate from the dev box

Ships `bench.sh` to each reachable machine over SSH, runs it, and appends one
timestamped, **labelled** row per machine to `benchmarks/results.csv`.

```
scripts/fleet-bench.sh [-l label] [-r gl|soft] [-W w] [-H h]
                       [-s fullscreen|borderless|windowed]
                       [-f frames] [-n runs] [-w warmups] [-t timeout]
                       [-m map] [host ...]
```

Default fleet: `yosemite quicksilver mini-g4 imac-g5 mini-intel`. Unreachable
machines are skipped. Use `-l` to tag a run so before/after rows are easy to
diff, e.g.:

```
scripts/fleet-bench.sh -l baseline      -r gl -W 800 -H 600 yosemite
scripts/fleet-bench.sh -l fix-invalidenum -r gl -W 800 -H 600 yosemite
```

Results accumulate in `benchmarks/results.csv` (rolling; never truncated).

## Machines (SSH aliases)

| alias        | machine                    | GPU                  | OS      |
|--------------|----------------------------|----------------------|---------|
| `yosemite`   | Power Mac G3 (ppc750)      | ATI Rage 128 (GL1.1) | 10.3.9  |
| `quicksilver`| Power Mac G4 Quicksilver   | -                    | 10.4    |
| `mini-g4`    | Mac mini G4                | -                    | 10.4    |
| `imac-g5`    | iMac G5                    | ATI Radeon 9600      | 10.5    |
| `g5-panther` | Power Mac G5 dual 2.7 GHz, partition 1 | ATI Radeon 9650 | 10.3.9 |
| `g5-tiger`   | Power Mac G5 dual 2.7 GHz, partition 2 | ATI Radeon 9650 | 10.4.11 |
| `g5-desktop` | Power Mac G5 dual 2.7 GHz, partition 3 | ATI Radeon 9650 | 10.5.8 |
| `mini-intel` | Mac mini (Intel, Lion)     | Intel                | 10.7    |

Every PowerPC alias above is a **bench and test target only**. All three slices
cross-compile on the Intel Lion minis; no PowerPC box is ever a build host.

The dual G5 (10.188.1.188, account short name `powermacg5`) is partitioned to
boot 10.3, 10.4 and 10.5
side by side, one at a time, so it gets the `yosemite` / `yosemite-tiger`
treatment: **one alias per partition sharing the IP**, each with its own
`HostKeyAlias` and `CheckHostIP no` so the three host keys never clash.
`g5-panther` is partition 1, `g5-tiger` is partition 2 and `g5-desktop` is the
Leopard partition 3. Each partition has to be onboarded independently, per the
runbook below, or `fleet-bench.sh` skips it as unreachable. All three are
onboarded as of 2026-07-27.

Partitions are switched remotely: bless the target volume and reboot, and the
machine comes back on the same IP in about 60 seconds.

```sh
ssh g5-panther 'sudo bless --mount /Volumes/Tiger --setBoot && sudo shutdown -r now'
```

Panther's `bless` predates the double-dash spelling and wants `bless -mount DIR
-setBoot`; Tiger and Leopard take either. Confirm with `bless --info --getBoot`
before rebooting, and note that the first connection to a freshly onboarded alias
needs `-o StrictHostKeyChecking=accept-new`, since a non-interactive ssh cannot
answer the new-host prompt and fails with "Host key verification failed", which
reads exactly like a credential problem and is not one.

Because whichever OS is booted mounts the other two under `/Volumes`, one
partition can stage files for all three. That is how the game was deployed here:
`scripts/deploy-dmg.sh g5-panther` plus one copy of the retail content over the
network, then `ditto` from the booted partition into
`/Volumes/Tiger/Users/powermacg5/Desktop` and the Leopard equivalent, with a
`chown -R 501:GID` after, since the Leopard account is in `staff` where the other
two are in their own group.

## Onboarding a new partition or machine

Every partition is a separate OS install and shares nothing with its neighbours,
so all of this is per partition, not per machine.

1. **At the machine**: turn Remote Login on, and check the account short name and
   password actually authenticate over ssh, not just at the login window. `ssh`
   is usually the only open port, so a wrong credential leaves no way in. Read
   the short name off the machine (`ls /Users`) rather than guessing it from the
   machine's nickname: the dual G5's account is `powermacg5`, not `g5`, and that
   single wrong assumption blocked the first onboarding attempt outright. The
   auto-generated hostname is no guide either, it was `powermacg527`.
2. **Add the alias** to `~/.ssh/config`, copying an existing entry for the same
   OS generation. `HostKeyAlias` plus `CheckHostIP no` are mandatory whenever the
   partitions share one IP, otherwise each boot trips a host-key mismatch:

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

   The last two lines are what 10.3 and 10.4 sshd need on top of what the Intel
   boxes need. Keep them for 10.5 too; they cost nothing. On a modern client a
   multi-word `-o` value has to be quoted (`-o 'HostKeyAlgorithms=+ssh-rsa'`) or
   ssh reports "extra arguments at end of line".
3. **Install the key.** `~/.ssh/id_rsa_retro.pub` into `~/.ssh/authorized_keys`,
   `~/.ssh` mode 700 and the file mode 600, or sshd ignores it silently.
4. **Passwordless sudo.** **Append to `/etc/sudoers` directly**, after backing it
   up. sudo on 10.3 through 10.5 is 1.6.x (Panther 10.3.5 reports 1.6.6): it has
   **no `/etc/sudoers.d` and no `#includedir`**, so a file dropped in that
   directory does nothing at all and gives no error. `sudo -n` does not exist on
   these releases either, so the only honest test is `sudo -k` to drop the cached
   credential, then a plain `sudo whoami` in a fresh non-interactive ssh command.
   If it prints `root` with no prompt it works; if it prompts, it does not.

   Bootstrap with the account password over stdin, since there is no tty:

   ```sh
   ssh HOST 'echo PASSWORD | sudo -S -p "" sh -c "
     cp -p /etc/sudoers /etc/sudoers.bak.pre-retro &&
     cp /etc/sudoers /tmp/sudoers.new &&
     echo \"USER ALL=(ALL) NOPASSWD: ALL\" >> /tmp/sudoers.new &&
     visudo -c -f /tmp/sudoers.new &&
     cat /tmp/sudoers.new > /etc/sudoers && chmod 440 /etc/sudoers"'
   ```

   `cat > /etc/sudoers` rather than `mv`, so the file keeps its inode and mode.
   The first password-bearing `sudo` also prints the "usual lecture" banner on a
   box that has never run sudo; that is not an error.
5. **Stop it sleeping.** A bench box that sleeps drops off mid-run, which is what
   a partition dropping off the network for a minute at a time looks like.
   Panther's `pmset` predates the modern option names: it takes **`dim`,
   `sleep` and `spindown`** (minutes), and has no `displaysleep`, no `disksleep`
   and no `-g custom`. `sudo pmset -a sleep 0 dim 0 spindown 0` is the whole job.
   Panther ships with `sleep 10 dim 5 spindown 10`, so a fresh install always
   needs this. Verify with **`pmset -g live`** or `pmset -g disk`, not bare
   `pmset -g`, which serves a cached view and can still show the old values for
   several seconds after the change lands.
6. **Name it.** Panther's `scutil --set` accepts **only `ComputerName` and
   `LocalHostName`**, not `HostName` (Tiger adds it). The unix hostname comes
   from `HOSTNAME=` in `/etc/hostconfig`, which ships as `-AUTOMATIC-`; set it to
   the alias so logs and `uname -a` name the partition, and back the file up.
   Set `LocalHostName` to the ssh alias so the three partitions are distinct on
   Bonjour even though they share one IP. Record what you set here.
7. **Confirm the IP is stable**, since the aliases hardcode it and the whole
   point of per-partition aliases is that the IP holds across all three OSes.
   `ipconfig getpacket en0` says whether the lease is DHCP and who issued it.
   All partitions of one machine share the NIC and therefore the MAC, so a DHCP
   reservation on the router pins the address for all three at once; there is no
   need to configure each partition statically.
8. **Bring the OS up to the target version.** PowerPC slices target 10.3.9, so a
   10.3.x partition needs the 10.3.9 combo updater first. These machines cannot
   do modern TLS, so never download it on the old machine: copy it from another
   fleet box over ssh and verify with `md5` on both ends. Copies are at
   `yosemite:/Users/mini/Documents/MacOSXUpdateCombo10.3.9.dmg` and on the dev
   box at `~/Documents/MacOSXUpdateCombo10.3.9.dmg`, both 118917398 bytes, md5
   `d8fdc52ba42792a53092e03a26779914`. Old `scp` needs `-O` from a modern client.
   Leave the installer for the machine's owner to run.
9. **Record the specs**, which is the point of onboarding an unusual machine.
   Panther's `system_profiler` has **no `SPDisplaysDataType`**; ask it for
   `SPHardwareDataType`, `SPMemoryDataType` and `SPPCIDataType`, and read the GPU
   out of the PCI list. `system_profiler -listDataTypes` shows what a given OS
   actually offers.
10. Only then install the game and take a first benchmark.

Expect Tiger to differ from Panther on three points: its sshd is OpenSSH 4.x and
takes the same legacy options without complaint, its `pmset` is closer to the
modern syntax, and its `scutil` and `system_profiler` gain the `HostName` and
`SPDisplaysDataType` that Panther lacks. The sudo 1.6 trap in step 4 is unchanged
on Tiger and on Leopard.

### Current state of the dual G5

All three partitions are onboarded and carry the game. The account is
`powermacg5` on each, and each has the retro key installed, passwordless sudo,
sleep and disk sleep and display sleep off, its names set to its alias, and
`~/Desktop` holding `Half-Life-OldMac-v1.4.3.dmg` plus a `Half-Life/` folder with
the three app bundles and a full retail `valve/`, md5 verified against the dev box.

| partition | slice | OS | alias | state |
|---|---|---|---|---|
| 1 | `disk0s3`, "Panther" | 10.3.9 Panther, build 7W98 | `g5-panther` | onboarded, game deployed |
| 2 | `disk0s5`, "Tiger" | 10.4.11 Tiger, build 8S165 | `g5-tiger` | onboarded, game deployed |
| 3 | `disk0s7`, "Leopard" | 10.5.8 Leopard, build 9L31a | `g5-desktop` | onboarded, game deployed |

The disk is one 465.8 GB drive split into three 155.1 GB HFS+ partitions, all
visible from whichever OS is booted, so the volume names above are how you tell
which partition you are looking at.

### Dual G5 specs, as the machine reports them

First `ppc970` machine the fleet has had on anything below 10.5, so this is
recorded verbatim.

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

`hw.cpusubtype` 100 confirms what the slice table already says: `dyld` grades by
subtype, there is no `ppc970` slice, so this machine loads the `ppc7400` slice
exactly as a G4 does.

Panther 10.3.5 does not put a marketing name on the card, and the reported
device ID is an RV350-class part rather than the R350/R360 of a Radeon 9800. That
was re-read once Tiger went on: `SPDisplaysDataType` there names it an **ATI
Radeon 9650**, 256 MB, driving a 1680x1050 Cinema display, with the second
connector empty. Panther has no `SPDisplaysDataType` at all, which is why the
first pass could only report the PCI device ID.

The machine has been **converted from liquid to air cooling**, so throttling is a
fair thing to suspect on any odd result. Read rather than assumed, on Panther and
again on Tiger: `hw.cpufrequency` is 2700000000, `hw.busfrequency` is 1350000000
and `pmset` reports `reduce 0`, so both CPUs are at full speed and not in the
reduced-performance mode. No actual temperature has ever been read; Panther exposes
no usable sensor node through `ioreg` and the fleet carries no tool for it. It has
not been needed so far: the machine sustained 137 to 185 fps across an hour of
back-to-back benching on all three partitions, run to run within 1 percent, which
is not what a throttling G5 looks like.

### Names set on each partition

| partition | `ComputerName` | `LocalHostName` | unix hostname |
|---|---|---|---|
| 1, Panther | `Power Mac G5 Panther` | `g5-panther` | `HOSTNAME=g5-panther` in `/etc/hostconfig`, was `-AUTOMATIC-` |
| 2, Tiger | `Power Mac G5 Tiger` | `g5-tiger` | `scutil --set HostName g5-tiger` |
| 3, Leopard | `Power Mac G5 Leopard` | `g5-leopard` | `scutil --set HostName g5-leopard` |

Panther is the odd one out: its `scutil` takes only `ComputerName` and
`LocalHostName`, so the unix hostname has to come from `/etc/hostconfig`. Tiger
and Leopard have `scutil --set HostName` and ship no `HOSTNAME=` line in
`hostconfig` at all, so do not go looking for one there.

Backups left on the machine: `/etc/sudoers.bak.pre-retro-2026-07-27` on all three
partitions, and `/etc/hostconfig.bak.pre-retro-2026-07-27` on Panther.

### The 7 fps on this machine did not reproduce (2026-07-28)

The onboarding run recorded **7.0 fps** on `c0a0` on the Leopard partition and
that number stood as an open question, with a fixed-per-frame cost, throttling and
a silent software fallback all on the suspect list. It was re-measured across all
three partitions the next day and **it does not reproduce**. Every partition of the
dual 2.7 is now the fastest PowerPC box in the fleet, as it should be.

All rows below are `gl`, map `c0a0`, `gl_vsync 0`, one warmup discarded, median of
three runs, and the `MODE:` column is the engine's own line, not the request.

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

**The resolution sweep now says the opposite of what the onboarding pair said.**
Fillrate scales cleanly and close to linearly: fit the Panther row set and it is
about **3.3 ms of fixed cost plus 8.2 ns per thousand pixels**, holding to within a
few percent from 640x480 to 1680x1050. The earlier "3.5x the pixels costs nothing,
so it is not fillrate" reading was an artefact of the CSV recording the requested
size rather than the mode, and it should not be carried forward.

Note two mode substitutions the driver made, both visible only in `MODE:`: a
request for 320x240 landed on **640x480**, and a request for 1280x1024 landed on
**1680x1050**. `bench.sh` still writes the request into the resolution column, so
read `MODE:` whenever the exact pixel count matters.

**The substitution is per machine, and it bites the fleet comparison.** A control
run on `imac-g5` the same night, `-r gl -W 800 -H 600 -s fullscreen`, reports
`MODE: 1440x900`, the panel's native size, and measures 61.7 fps. The dual G5 under
the identical command reports `MODE: 800x600`. So the historical fullscreen rows
are not all the same number of pixels, and the two machines cannot be compared from
the resolution column alone. The `windowed` iMac G5 rows of 2026-07-24 (86.8 and
95.8 fps) really were 800x600, and against those the dual G5's 140.7 fps windowed
800x600 is about 1.6x, which is the shape you would expect from two cores at 2.7 GHz
against one at 1.8.

What the re-measurement rules out as the mechanism, each by measurement:

- **Hardware, the GPU and the cooling conversion.** Same machine, same card, three
  OSes, 137 to 149 fps at 800x600. A thermally limited G5 cannot do that.
- **The OS and the ATI driver family.** Leopard is the *fastest* of the three, and
  it is the partition the 7 fps came from. `GL_VERSION` differs across them
  (`1.5 ATI-1.3.42` on Panther, `1.5 ATI-1.4.18` on Tiger, `2.0 ATI-1.5.48` on
  Leopard) and it makes no difference worth the name.
- **A just-booted transient.** Benched 41 seconds after a Leopard boot: 149.1 fps.
- **Spotlight indexing**, which was live in the original session. Forced a full
  reindex (`mdutil -E /`, `mds` at over 100 percent CPU, `mdworker` at 47) and
  benched during it: 136.2 fps.
- **CPU contention in general.** Both cores pinned by busy loops: 89.6 fps. Total
  CPU starvation costs 40 percent, not 20x, so no amount of background work on
  this machine explains 7 fps.
- **A silent fallback to software rasterization at 800x600.** `ref_soft` at
  800x600 measures 28.9 fps, four times *faster* than the 7 fps figure.

What is left unexplained: the original session itself. The Leopard system log puts
that boot at 22:44:02 and the first slow row 64 seconds later, on the partition's
first boot after the game was staged onto it. Whatever the condition was, it did
not survive the reboot and nothing tried since has recreated it. **The mechanism is
not known and the honest statement is that there is no longer a fault to explain.**
The one number that would still be worth having is a `ref_soft`-at-panel-resolution
coincidence: soft at 1680x1050 measures 15.6 fps, which is not 7 either, so even
the fallback-at-native theory does not fit.

The original rows stay in `benchmarks/results.csv` under `g5-leopard-onboard`. They
are real measurements of something; they are just not a property of this machine.
The 2026-07-28 rows carry `g5-osdiff-*`, `g5-ressweep-*` and `g5-leopard-gl-*`
labels, and the two `ref_soft` rows are labelled
`g5-leopard-SOFT-not-comparable-to-gl` because a soft number must never be read
against a gl one.

**`ref_soft` on this fleet renders in wrong colours.** Confirmed on the G5 under
Leopard while taking the rows above: blocky, dark, and light sprites come out
magenta where they should be white. That is the big-endian palette behaviour of
`ref_soft`, not a GL regression; `gl_texture_nearest` was `0` throughout and the
GL path renders correctly. Expect a bystander watching the screen during a
`bench.sh -r soft` run to report it as a rendering bug.

**Provenance caveat for every row dated on or before 2026-07-27.** Because of the
`fleet-bench.sh` trap recorded below, any row whose screenmode column reads
`fullscreen` may have been a run that asked for another mode and was silently given
fullscreen. Rows reading `windowed` or `borderless` cannot be affected, since
`fleet-bench.sh` could never produce one; those came from a direct `bench.sh` call.
The five `v1.0.0` rows of 2026-07-25 share one timestamp, which only `fleet-bench.sh`
produces, so that batch certainly ran fullscreen whatever it was asked for.

### A trap in fleet-bench.sh, found while measuring the above (fixed)

`fleet-bench.sh` accepted `-s fullscreen|borderless|windowed` and parsed it into
`SCREENMODE`, but **never passed it to `bench.sh`**, which then used its own
default of `fullscreen`. The CSV records what actually ran, so every row is
honest, but the request was lost with no warning. It had been that way since the
harness landed in `7e122d3`, so any row a `fleet-bench.sh -s` run produced is a
fullscreen row.

Fixed: `fleet-bench.sh` now canonicalises the mode, passes `-s` through, and
compares the mode it asked for against field 4 of the line `bench.sh` returns,
shouting `SCREENMODE MISMATCH` on stderr if the two ever disagree again.

## Notes on determinism

- `gl_vsync 0` is set before measuring so the swap never blocks on vblank.
- The spinning 360° view exercises the whole scene around the spawn, so the
  number reflects average-case geometry/overdraw, not a single lucky angle.
- The engine prints the actual `MODE:` it ran at; `bench.sh` records it in the
  human-readable stderr note so you can confirm the requested resolution took.
