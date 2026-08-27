# Legacy Mac Hardware & Build Traps

## Machines

- **This dev box is orchestration only** (Apple Silicon, macOS 26). ALL THREE
  slices cross-compile on an Intel Lion mini; the PowerPC boxes are bench/test
  targets, NOT build hosts. Drivers RUN ON the mini: `build-lion.sh`,
  `build-ppc-panther.sh` (G3), `build-ppc-tiger.sh` (G4 and G5), fused by
  `make-universal.sh` and `make-app.sh`. `docs/adr/0005`
- **TWO Intel build minis. Either builds any slice, but they are NOT the same
  machine and must never be pooled into one "Intel" class for a measurement.**
  `mini-intel` (10.188.1.245, wifi), `mini-intel2` (10.188.1.164, **wired**,
  server room, wifi disabled). Both are `hw.model` Macmini2,1 on 10.7.5 with the
  same toolchain and a GMA 950, which is exactly why this was written down wrong:
  nothing but the CPU separates them. Measured on the machines 2026-08-23:
  **`mini-intel` is a Core 2 T7600 at 2.33 GHz, 4 GB, 4 MB L2; `mini-intel2` is a
  T5600 at 1.83 GHz, 2 GB, 2 MB L2.** 27% apart on clock alone. Interchangeable
  for BUILDING, not for benching.
  Ask `scripts/pick-build-host.sh` (`--status`,
  `--acquire LABEL`, `--release HOST`), never hardcode: a host is busy if it
  holds `/tmp/.retro-build-lock` or is compiling, so hand-started builds count.
- **THREE separate G5s, and they are easy to mix up.** Read the alias, not the
  word "G5", and never assume "the quad" means whichever G5 you last touched:
  - **`imac-g5`** (10.188.1.168) the iMac G5, 10.5.8
  - **`g5-panther` / `g5-tiger` / `g5-desktop`** (10.188.1.188) the **dual**
    PowerMac G5, multi-boot. `g5-desktop` is the Leopard partition, hostname
    `g5-leopard`.
  - **`quad-leopard` / `quad-tiger`** (10.188.1.120) the **QUAD** PowerMac G5,
    multi-boot, user `g5quad`.

  On 2026-08-21 a whole round of "deploy to the quad" and "quit the game on the
  quad" went to 10.188.1.188 instead, because this list previously named only
  two G5s. The quad kept running an old build and reporting the bug as unfixed,
  and the dual G5 was killed repeatedly for no reason. `ssh_config` is the
  authority for what exists; grep it before touching a machine by nickname.
- **Machines that multi-boot from one IP**: the G3 (`yosemite`,
  `yosemite-tiger`), the dual G5 and the quad G5. One OS at a time, so each
  partition needs its own alias with `HostKeyAlias` and `CheckHostIP no`, and
  the booted one mounts its neighbours under `/Volumes`. An alias for a
  partition that is not booted simply fails to connect, which looks exactly
  like the machine being off. Switch with `bless` and reboot;
  `docs/BENCHMARKING.md`.

## Lion build-box traps

- Git there is Xcode 4's 1.7, which has no `git -C`. Use `( cd DIR && git ... )`.
  Modern git, curl, OpenSSL and **ssh** live under `~/local`; the scripts prefer
  them silently. Lion's own OpenSSL cannot do TLS 1.2 and its OpenSSH is 5.6,
  which has no ed25519 and can only sign `ssh-rsa` under SHA-1, which GitHub
  stopped accepting in 2022.
- **All six forks are private.** Each mini has its own key at
  `~/.ssh/id_ed25519_github`, wired in by `core.sshCommand` plus an
  `url."git@github.com:".insteadOf` rewrite, so `build-pins.sh` can keep naming
  plain https URLs. Without that a fetch fails with "could not read Username".
- **No `pkill` on 10.7, 10.4 or 10.3 at all.** Kill by PID out of `ps`.
- The hlsdk-specific traps (`--disable-altivec` is an ENGINE option and breaks
  hlsdk's configure; hlsdk assumes darwin means clang and hands gcc a
  `-Wl,--no-undefined` Apple's ld rejects; gcc-4.0 is stricter than the x86_64
  clang) are in `docs/MODS.md`, "Things that bite on these machines", with the
  script that handles each.
- Lion's `strings` cannot read a modern x86_64 Mach-O and reports zero matches,
  which looks exactly like a missing fix. Verify strings on the dev box.
- Panther's `lipo` cannot name the x86_64 slice and prints
  `cputype (16777223) cpusubtype (-2147483645)`. That is a correct fat binary.
- This dev box runs zsh, where an **unquoted `$var` does not word-split**. Use an
  array. A `git rm $LIST` silently became one long pathspec that matched nothing.
