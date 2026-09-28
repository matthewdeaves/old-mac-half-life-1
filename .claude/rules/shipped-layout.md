---
description: Where the game payload sits inside the app bundle, and why it cannot move
paths:
  - "scripts/make-app.sh"
  - "scripts/make-dmg.sh"
  - "scripts/deploy-dmg.sh"
  - "scripts/make-universal.sh"
  - "scripts/build-lion.sh"
  - "scripts/build-ppc-*.sh"
  - "installer/**"
---

# Shipped layout: we ship NO valve folder

The disk image carries `Half-Life.app`, `Half-Life Mods.app` and
`Half-Life System Report.app`, plus `README.txt` and `BUILD-INFO.txt`, and no
`valve/`. The player drops their OWN retail `valve/` beside the app, so nothing is merged.

Everything we build lives at `Half-Life.app/Contents/Resources/Half-Life/valve/`.
The engine mounts `Contents/Resources/Half-Life` as its READ-ONLY root (`fs_rodir`);
the writable root is the folder holding the `.app` (`XASH3D_BASEDIR`). `docs/adr/0006`

- **Payload sits at the `valve/` level, not the rodir root.** The engine's
  pre-flight library check cannot see the root and aborts with "missing game
  library" even though `dlopen` would work.
- **A deployed folder holds our three `.app`s, the player's `valve/`, their mod
  gamedirs and `last-run.log`, nothing else.** A loose `xash3d` or `lib*.dylib`
  beside the bundle is build spill, and it is loaded IN PREFERENCE to the bundle's
  copy, silently. Both Intel minis had some from 25 July 2026 (fixed in 45d367e).
- **Build output goes under `dist/`, and no script writes to a Desktop.**
- **`deploy-dmg.sh` names spill and leaves it. It prunes only named game-code files
  an older release left in the player's `valve/`.** Never add a general sweep of that
  folder: it holds gigabytes nobody can regenerate, and such a sweep already cost
  installed mods once.
- **No `gameinfo.txt` or `liblist.gam` in our rodir, and nothing beside the app may
  hold a `liblist.gam`** (dotted names count), or Custom Game lists a phantom entry.
  The installer unpacks inside `.om-staging/` for this reason.
- **Mod dylibs stay in `Half-Life Mods.app`.** Every mod needs a row in
  `installer/mods.map`, artwork in `installer/artwork/` and a blurb in
  `installer/descriptions/`; Xen Warrior shipped with only the first and appeared
  blank (v1.4.0). A row in `installer/manifests.txt` exists only for a mod we FETCH;
  `tests/test-repo.py` checks both directions.

Mechanisms, engine call chains and the `dist/` staging paths:
`docs/SHIPPED-LAYOUT.md`.
