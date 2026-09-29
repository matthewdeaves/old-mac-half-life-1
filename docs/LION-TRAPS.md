# Lion tooling and shell traps

Tool availability, authentication wiring and binary inspection hazards.
Machine roles and the three-G5 mix-up stay in `docs/FLEET-HARDWARE.md`.
Sections: Lion build-box traps, The dev box shell.

## Lion build-box traps

- **Git is Xcode 4's 1.7, which has no `git -C`.** Use `( cd DIR && git ... )`. Modern git,
  curl, OpenSSL and **ssh** live under `~/local`, and the scripts prefer them silently.
  Lion's own OpenSSL cannot do TLS 1.2 and its OpenSSH is 5.6, which has no ed25519 and can
  only sign `ssh-rsa` under SHA-1, which GitHub stopped accepting in 2022.
- **Authentication is separate from repository visibility.** Each mini has its own key at `~/.ssh/id_ed25519_github`,
  wired in by `core.sshCommand` plus an `url."git@github.com:".insteadOf` rewrite, so
  `build-pins.sh` can keep naming plain https URLs. A fetch can fail with "could not read Username" when this wiring is missing; that error does not prove the repository is private. Visibility was not verified during this documentation pass.
- **There is no `pkill` on 10.7, 10.4 or 10.3.** Kill by PID out of `ps`.
- **Lion's `strings` cannot read a modern x86_64 Mach-O** and reports zero matches, which
  looks exactly like a missing fix. Verify strings on the dev box.
- **Panther's `lipo` cannot name the x86_64 slice** and prints
  `cputype (16777223) cpusubtype (-2147483645)`. That is a correct fat binary.
- The hlsdk-specific traps (`--disable-altivec` is an ENGINE option and breaks hlsdk's
  configure; hlsdk assumes darwin means clang and hands gcc a `-Wl,--no-undefined` Apple's
  ld rejects; gcc-4.0 is stricter than the x86_64 clang) are in `docs/MODS.md`, "Things that
  bite on these machines", with the script that handles each.

## The dev box shell

The dev box runs zsh, where an **unquoted `$var` does not word-split**. Use an array. A
`git rm $LIST` once silently became one long pathspec that matched nothing.
