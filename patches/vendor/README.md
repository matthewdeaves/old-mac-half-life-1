# Captured vendor hand-edits

These `*.handedits.diff` files hold local edits to the upstream vendor trees that
are **not** reproduced by any `scripts/patch-*.py`. Without them, the build could
not be recreated from a clean checkout - they are the backup for those edits.

Each diff is a `git diff HEAD` taken against the vendor tree's pinned upstream
commit (see [`../../vendor/MANIFEST.md`](../../vendor/MANIFEST.md)). Apply with:

```sh
git -C vendor/<tree> apply patches/vendor/<tree>.handedits.diff
```

`scripts/bootstrap-vendor.sh` does this automatically after cloning each tree at
its pinned commit and running the relevant `patch-*.py` scripts.

## What's in them (verified 2026-07-24, byte-identical to the shipped build)

| Diff | Tree | Files | What |
|---|---|---|---|
[removed]
| `xash3d-fwgs-intel.handedits.diff` | Intel engine | 1 | `engine/platform/sdl2/sys_sdl2.c` |
| `hlsdk-portable-ppc.handedits.diff` | PPC game SDK | 2 | `public/build.h`, `wscript` |

Files that **are** reproduced by a committed `patch-*.py` (`game.cpp`,
`lib_posix.c`, `vid_sdl2.c`, `img_wad.c`, `gl_image.c`, `gl_rsurf.c`,
`r_glblit.c`, `menu_darwin.m`, `macho.c`, `net_ws.c`, `cl_main.c`,
`filesystem_engine.c`, and the SDL2 patches) are deliberately **excluded** here -
their patch script is the source of truth, so capturing them too would
double-apply.

## Known secondary gap (not yet captured)

[removed]
(`powerpc-mainui-fixes`) and itself carries `oldmac:` edits (e.g.
`menus/ServerBrowser.cpp`). That is a deeper, submodule-level gap - see the
MANIFEST's mirror recommendation.
