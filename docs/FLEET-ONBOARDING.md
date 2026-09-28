# Fleet onboarding and the dual G5

How to bring a new machine or partition into the fleet (ssh alias, key, sudo, sleep, names,
OS level), how to switch and stage the multi-boot G5 and G3, and what the dual G5 reports
about itself. The alias table and row-label registry stay in `docs/BENCHMARKING.md`; a
new machine must be added there before its first bench row.

## Switching and staging partitions on a shared IP

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

## Current state of the dual G5

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

## Dual G5 specs, as the machine reports them

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

## Names set on each partition

| partition | `ComputerName` | `LocalHostName` | unix hostname |
|---|---|---|---|
| 1, Panther | `Power Mac G5 Panther` | `g5-panther` | `HOSTNAME=g5-panther` in `/etc/hostconfig`, was `-AUTOMATIC-` |
| 2, Tiger | `Power Mac G5 Tiger` | `g5-tiger` | `scutil --set HostName g5-tiger` |
| 3, Leopard | `Power Mac G5 Leopard` | `g5-leopard` | `scutil --set HostName g5-leopard` |

Tiger and Leopard ship no `HOSTNAME=` line in `hostconfig`, so do not look for one.
Backups: `/etc/sudoers.bak.pre-retro-2026-07-27` on all three partitions,
`/etc/hostconfig.bak.pre-retro-2026-07-27` on Panther.
