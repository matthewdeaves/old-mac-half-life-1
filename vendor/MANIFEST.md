# Vendor manifest - how to reproduce the build trees

The `vendor/` directory holds upstream clones and is **git-ignored** (only this
file is tracked). This manifest records exactly which upstream commit each tree is
pinned to and what we apply on top, so the whole build can be reconstructed from a
clean machine using only this repo. `scripts/bootstrap-vendor.sh` automates it.

Reconstruction per tree = **clone at the pinned commit → run its `patch-*.py`
scripts → `git apply` its captured hand-edits** (`patches/vendor/*.handedits.diff`).

Always clone `--recursive` (submodules are omitted from GitHub ZIPs).

## Engine + game trees

[removed]
[removed]
- Branch / commit: `powerpc` @ `9df9420074d00f16d3a5a36bd751b8464216c612`
- Engine patch scripts: `patch-game-launch`, `patch-lib-posix`,
  `patch-fs-applebundle`, `patch-timerefresh`, `patch-vid-drawable`,
  `patch-palette-endian`, `patch-soft-screenshot`,
  `patch-gl-default-texture-endian`, `patch-single-pass-multitexture`,
  `patch-menu-darwin-tiger`, `patch-libbacktrace-bswap`,
  `patch-net-ws-thread-t` (Panther build only),
  `patch-gamedll-plain-name`, `patch-mainui-modart`,
  `patch-sys-newinstance-fork` (mod support),
  `patch-mainui-localize-optional`, `patch-startup-diagnostics`,
  `patch-crash-libbacktrace` (startup log and crash handler, #20 and #21)
[removed]
[removed]
  `powerpc-mainui-fixes` @ `1cf49f8b845ed5efc4e01243c43fc91ae81fdbd4` (NOT the
  in-tree `.gitmodules` FWGS pin - `bootstrap-vendor.sh` re-points it; edit
[removed]
  `3rdparty/maintui` (`https://github.com/FWGS/xash3d-maintui.git`) @
  `81b51637dfea2ee16f96aa2fabb7d5e5e2b8d3ee`
[removed]
[removed]

### `xash3d-fwgs-intel` - Intel engine (x86_64 slice)
- Upstream: `https://github.com/FWGS/xash3d-fwgs.git`
- Branch / commit: `master` @ `f0ea3a194ab06d56032c5d26578254698e361655`
- Engine patch scripts: `patch-game-launch`, `patch-lib-posix`,
  `patch-fs-applebundle`, `patch-timerefresh`, `patch-vid-drawable`,
  `patch-palette-endian`, `patch-soft-screenshot`,
  `patch-single-pass-multitexture`,
  `patch-gamedll-plain-name`, `patch-mainui-modart`,
  `patch-sys-newinstance-fork` (mod support),
  `patch-mainui-localize-optional`, `patch-startup-diagnostics`,
  `patch-gl-apple-context` (startup log, #20 and #21)
- Hand-edits: `patches/vendor/xash3d-fwgs-intel.handedits.diff` (`sys_sdl2.c`)
- Build with plain `./waf configure`. The x86_64 slice needs no force flag: the
  Lion mini's clang defaults to it. See `scripts/build-lion.sh:130`.

### `hlsdk-portable-ppc` - PPC game dylibs
[removed]
  `upstream`; there is **no `origin`**)
- Branch / commit: `big-endian` @ `27b551208e75d04f4dbee7defaa5ac89894d2ce5`
- Patch scripts: `patch-hlsdk-xcompile-ppc` (edits `scripts/waifulib/xcompile.py`)
- Hand-edits: `patches/vendor/hlsdk-portable-ppc.handedits.diff`
  (`public/build.h`, `wscript`)

### `hlsdk-portable-intel` - Intel game dylibs
- Upstream: `https://github.com/FWGS/hlsdk-portable.git`
- Branch / commit: `master` @ `8c5b2846c2448e2b063f358f041d565dc0f076b1`
- No local edits (clean checkout).

[removed]
[removed]
  `upstream`; no `origin`)
- Branch / commit: `big-endian` @ `00aa0ae909efd940c249aa78a6b9375062374a9b`
- Not part of the shipping build; kept for reference. The shipping PPC engine is
[removed]

## Mod game code - `hlsdk-portable` branches (v1.2.0)

One branch per mod, all from `FWGS/hlsdk-portable`. Each is cloned TWICE
(`vendor/hlsdk-mods/<branch>-intel` and `-ppc`), built separately, then `lipo`'d
into one fat `ppc + x86_64` pair - see `scripts/build-mod.sh`.

Cloned from the local **`vendor/hlsdk-portable-mirror.git`** (`--mirror`, all
branches, ~29 MB) rather than from GitHub. Originally because Xcode 4's git on the
Lion minis links an OpenSSL too old for TLS 1.2, which made `github.com`
unreachable from the build host. The minis carry modern git, curl and OpenSSL
under `~/local` since 2026-07-26 and can now reach GitHub, but the mirror stays
the source of truth: 57 branches clone from a local path in seconds, it works with
no internet, and the PowerPC bench boxes still have no TLS. Refresh it from a
modern Mac with `git -C <mirror> remote update`.

Applied to the `-ppc` tree only, in this order:
`graft-ppc-endian.sh` (→ `patch-hlsdk-studio-endian.py`),
`patch-hlsdk-xcompile-ppc.py`, `patch-hlsdk-ppc-darwin.py`,
`patch-hlsdk-mod-gcc4.py`. The `-intel` tree is a clean checkout.

Both checkouts of a branch are pinned to the same commit (verified).

| Branch | Commit | Branch | Commit |
|---|---|---|---|
| `aom` | `899cc0e` | `noffice` | `0280b25` |
| `asheep` | `6a2e223` | `opfor` | `613eb55` |
| `biglolly` | `f026236` | `poke646` | `ee347f4` |
| `blackops` | `d0c62f1` | `poke646_vendetta` | `d359cd1` |
| `bshift` | `cd04b61` | `redempt` | `4b65631` |
| `CAd` | `e65326c` | `residual_point` | `ff2bf8c` |
| `caseclosed` | `cf1217f` | `sohl1.2` | `24a22e4` |
| `dmc` | `b6ef36f` | `thegate` | `d96599b` |
| `echoes` | `903f874` | `theyhunger` | `e57c82e` |
| `eftd` | `2912cdf` | `tot` | `ca1cfe7` |
| `half-screwed` | `f56c4f3` | `visitors` | `7f6b0fe` |
| `halloween` | `cd6ddb1` | `zombie-x` | `3d243e8` |
| `induction_1.2` | `e6e9d8e` | | |

Full 40-char hashes, in alphabetical branch order:

```
aom               899cc0ef34d2375bd5f7bc8a8301ae8556b5c380
asheep            6a2e223de00596441590f450938dd53290ba457f
biglolly          f026236a04fca04152c1984882f17a6ffc7ace70
blackops          d0c62f17a7a53e829526ac7eb57895be29b8d6f8
bshift            cd04b6190b234b27abc31dd992947af3842f6d24
CAd               e65326cdfd26bdf43dd40ead937c2a09a4550e54
caseclosed        cf1217f63af029aaacd8c1142b1fff195afadde3
dmc               b6ef36f40c0d01ca2eccd948649012a31ca75a61
echoes            903f8746c1033116572795150bbcc09d18fc98af
eftd              2912cdfa7997e9711adbc8124f6a11ad2476cfd5
half-screwed      f56c4f3325f024cae7ee29b38f607300dfd09009
halloween         cd6ddb18be5e35eae30fe66fab6d8b9864f8b876
induction_1.2     e6e9d8e6e14d68a4386a3da008f7244657067718
noffice           0280b25a9512b6f35a36a5c54d3b4544e42f05df
opfor             613eb55d5bcd257219c881297d1d43c1da4a7445
poke646           ee347f427c25fb63cd58ad07aef63c3e90aeed10
poke646_vendetta  d359cd1c1eb3e0bc5c3372a579058ef0108406c6
redempt           4b65631851ce305b50256d686352748cf04dde3f
residual_point    ff2bf8c30498e7d0cef78ada2cbf007876ce8837
sohl1.2           24a22e4f04630f6ffd577bd51ee0b811f9b1c14d
thegate           d96599b0519da73ae5f411567b8be59aba9d7b16
theyhunger        e57c82ed776f386f0814339c2a843d5c0149e4df
tot               ca1cfe7626a08cae834b1e2a2c02142ded44c4a4
visitors          7f6b0feca544e2034fd5a86298e5753b0bce79d9
zombie-x          3d243e8fa6246277bb25ea0e6c52067590ee750f
```

Note the v1.2.0 builds were split across BOTH Intel minis (`aom`…`induction_1.2`
on `mini-intel`, `noffice`…`zombie-x` on `mini-intel2`), which is why neither box
holds all 25 checkouts. `sohl1.2` came later and is on `mini-intel` only.

## Installer-only libraries (v1.5.0)

Linked into **`Half-Life Mods.app` only**, never into the engine or the game
dylibs. They exist because the installer stopped fetching one prepackaged bundle
and started fetching each mod from its own publisher.

| Tree | Upstream | Tag | Commit |
|---|---|---|---|
| `mbedtls-installer` | `Mbed-TLS/mbedtls` | `mbedtls-3.6.7` | `068ff080b369adfac81509f9b57b2afabaf82dc5` |
| `zlib-installer` | `madler/zlib` | `v1.3.2` | `da607da739fa6047df13e66a2af6b8bec7c2a498` |
| `lzma-installer` | `ip7z/7zip` | `26.02` | `f9d78aff31a5f2521ae7ddbdc97c4a8855808959` |

Pins live in `scripts/build-pins.sh` and are cloned by `bootstrap-vendor.sh`
like everything else. **`build-installer.sh` refuses to run without them**, which
is the check that stops this section going stale.

**mbedTLS.** Every host that publishes a mod answers plain http with a `301` to
https, and 10.3 to 10.7's system TLS cannot negotiate what those servers require
(the G3's own curl links OpenSSL 0.9.7b from 2003). This is the **3.6 LTS** line,
deliberately **not** the 4.x tree the engine vendors at
`3rdparty/mbedtls`: that one is split across `tf-psa-crypto` and its old-macOS
clock fix routes `mbedtls_ms_time()` through the engine's
`Platform_DoubleTime()`, which does not exist in a Cocoa app.

Two files are excluded from the build, both measured against the 10.3.9 SDK with
gcc-4.0: `net_sockets.c` (`'suseconds_t' undeclared`, and unneeded because
`OMTLS.m` drives mbedTLS over the socket layer the app already had) and
`timing.c` (DTLS and self-test only). The third old-macOS problem,
`platform_util.c`'s hard `#error "No mbedtls_ms_time available"` because
`clock_gettime` is 10.12+, is fixed rather than excluded:
`installer/om_mbedtls_config.h` selects `MBEDTLS_PLATFORM_MS_TIME_ALT` and
`OMTLS.m` supplies the function from `gettimeofday`.

Everything else builds clean: **107 of 109** library files for ppc, **108 of 108**
for x86_64.

**zlib**, for the `.zip` sources. Panther ships libz 1.1.3 from 2003 and has no
`zlib.h` on the live system at all, so linking whatever each machine happens to
carry would mean a decoder being fed files off the internet behaving differently
per OS version. Only the inflate side is compiled; we never compress.

**LZMA SDK** (the `C/` directory of the 7-Zip source), for the `.7z` sources.
There is no system 7z on any macOS at any vintage. The reader set only: no
encoder, and no `Sha256`, which is needed only for AES-encrypted archives that we
refuse rather than support.

Neither of the last two is optional and neither can be converted away, because we
host nothing and therefore cannot repackage. See `installer/mod-sources.txt`.

## SDL2 sources (not git - downloaded)

Legacy native-Cocoa SDL2 from alex-free, patched by the `patch-panther-sdl-*`
scripts at build time:
- `panther-sdl2` - SDL **2.0.3** (10.3.9+) - used for BOTH PowerPC slices,
  including the G5's.
- `leopard-sdl2` - SDL **2.0.6** (10.5+) - in no shipped slice since v1.4.0. It
  was carried only by the dropped `ppc970` slice. Intel builds SDL 2.0.22 from
  source (`build-lion.sh`).

Source: the "SDL2 for legacy Mac OS X" MacRumors thread,
<https://forums.macrumors.com/threads/2262878/>.
Modern SDL2 refuses to build pre-10.6, hence these pinned legacy versions.

Six `patch-panther-sdl-*` scripts prepare `panther-sdl2`, run by both PowerPC
drivers before the SDL build: `-version-guards`, `-displayname`,
`-panther-apis`, `-cursors`, `-altivec-include` (Panther only) and
`-textinput` (#29: Cocoa text input teardown and the no-window field editor).
The SDL build is skipped when `$SDLPREFIX/bin/sdl2-config` already exists, so
changing any of these means deleting `$SDLPREFIX` on the build mini first, or
the old static library is silently relinked.

## Resilience - the weak links, now mirrored

Pinned commits are retrievable **only while the upstream repo stays online**.
GitHub does not guarantee this, and the fragile pins here are **personal forks**,
which get deleted or force-pushed far more often than org repos. To guarantee the
pins survive even if an upstream disappears, each personal fork is mirrored to a
private repo under `github.com/matthewdeaves/` (full `git push --mirror`, all
branches + tags). **Verified 2026-07-24: every mirror contains its pinned commit.**

| Upstream (primary) | Pinned commit | Private mirror (fallback) |
|---|---|---|
[removed]
[removed]
[removed]
[removed]

The FWGS org repos (`FWGS/xash3d-fwgs`, `FWGS/hlsdk-portable`,
`FWGS/xash3d-maintui`) are the safer pins and are **not** mirrored.

`bootstrap-vendor.sh` clones from the primary URL and automatically falls back to
the mirror if the primary is unreachable. Refresh the mirrors (re-push) if you
ever bump a pin to a newer upstream commit.

## mainui submodule (menu) - now reproduced

[removed]
[removed]
[removed]
[removed]
therefore build the *wrong* menu.

That fork differs from stock by exactly **one** `oldmac:` edit - a gcc-4.2
delegating-constructor workaround in `menus/ServerBrowser.cpp` - now captured as
[removed]
(`fixup_mainui`) re-points the submodule to the fork, checks out the pin, inits
the `miniutl` sub-submodule, and re-applies that diff automatically. **Gap
closed** (verified 2026-07-25: the fork/pin/edit reproduce end-to-end).

Note: the earlier belief that the PPC-MP blocker was a large "C++11 ServerBrowser
[removed]
ctor fix above.
