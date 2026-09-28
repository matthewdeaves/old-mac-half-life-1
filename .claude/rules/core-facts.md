---
description: Slice/arm64 rules, renderer default routes, generated configs, compat-include, dylib names, the Linux server
paths:
  - "scripts/make-app.sh"
  - "scripts/make-universal.sh"
  - "scripts/build-*.sh"
  - "scripts/fuse-mod-arm64.sh"
  - "scripts/push-*arm64*.sh"
  - "scripts/arm64-stamp.sh"
  - "configs/**"
  - "compat-include/**"
  - "server/**"
---

# Core Facts

- **Five slices**: `ppc750 ppc7400 i386 x86_64 arm64`. `dyld` grades by CPU
  subtype alone, so a slice exists only for a CPU capability difference.
  `docs/adr/0001`
- **Intel floor is 10.6** via `-stdlib=libstdc++`, not 10.7. Reasoning is in the
  `scripts/build-lion.sh:29-52` header comment.
- **arm64 is built on this box, not a mini**, by four drivers. **Never write "not
  for Apple Silicon".** `docs/adr/0001`, `docs/CORE-FACTS.md`
- **A stale arm64 slice is refused, not fused.** Rebuild it and push it; do not
  work around the refusal. `docs/adr/0015`, `docs/adr/0016`
- **Never put `compat-include/` on a MODERN compiler's include path**: it shadows
  libc++'s real headers and breaks the compile. PowerPC and libstdc++ only.
  `docs/CORE-FACTS.md`
- **Game dylib names are not "arch with an underscore"**: `hl.dylib` and
  `client.dylib` for i386, `hl_ppc`, `hl_amd64`, `hl_arm64` for the rest. The
  engine `dlopen`s by name. `docs/adr/0001`
- **A renderer default reaches a machine by one of three routes, chosen by the
  cvar's flags** (launcher `PROFILE`, seeded `opengl.cfg`, pinned
  `userconfig.cfg`). Pick the wrong one and it is "enabled" but off everywhere.
  `docs/CORE-FACTS.md`, issues #8, #9, #10
- **Never copy `opengl.cfg`, `config.cfg` or `video.cfg` between machines.** They
  are generated per machine and the wrong renderer settings then stick forever.
  Story: `docs/CORE-FACTS.md` (`quad-tiger`, 2026-08-28).
- **Benchmarks run vsync OFF, players run it ON**, so `results.csv` is cost, not
  experience. `docs/BENCHMARKING.md`
- **The Linux dedicated server is a UDP amplifier**: per-source-address firewall
  rules are not optional. `docs/adr/0013`, `docs/adr/0014`, `server/README.md`
- **Never use GitHub ZIPs**; every slice and the server build from one branch of
  each of our own forks. `docs/adr/0002`, `docs/adr/0003`, `docs/adr/0012`
- **`Contents/MacOS/xash3d` is a shell launcher**; the Mach-O is `xash3d.bin`.
  `docs/adr/0007`
- **Mac OS X only, not Mac OS 9** (issue #23).

SDL2 linking per slice (`docs/adr/0004`), the slice sets of each shipped app and
the full detail of the rules above: `docs/CORE-FACTS.md`.
