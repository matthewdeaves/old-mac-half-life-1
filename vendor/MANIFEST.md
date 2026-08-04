# Vendor manifest - the mod source pins

`vendor/` holds source clones and is **git-ignored**; only this file is tracked.

**This file no longer describes the engine, the menu or the base game.** Those
are pinned in `scripts/build-pins.sh`, which is the single source of truth for
them and for the provenance stamped into a shipped app. Every change this port
makes to them is a commit on the `oldmac` branch of our own fork, so there is
nothing to record here beyond the pin, and `scripts/fetch-sources.sh` puts each
tree at it. See `docs/adr/0012`.

What is left is the one thing that genuinely lives outside that scheme: the 25
mods. Each is built from its own upstream branch, and those branches are not ours
to fork, so their pins are recorded here and the fixes they need stay as
`scripts/patch-hlsdk-*.py` applied at build time.

## Mod game code: `hlsdk-portable` branches

One branch per mod, all from `FWGS/hlsdk-portable`. Each is cloned twice
(`vendor/hlsdk-mods/<branch>-intel` and `-ppc`), built separately, then `lipo`'d
into one fat `ppc + x86_64` pair. `scripts/build-mod.sh`.

Cloned from the local **`vendor/hlsdk-portable-mirror.git`** (`--mirror`, all
branches, about 29 MB) rather than from GitHub. 57 branches clone from a local
path in seconds, it works with no internet, and the PowerPC bench boxes still
have no usable TLS. Refresh it from a modern Mac with
`git -C <mirror> remote update`.

Applied to the `-ppc` tree only, in this order: `patch-hlsdk-xcompile-ppc.py`,
`patch-hlsdk-ppc-darwin.py`, `patch-hlsdk-mod-gcc4.py`, then
`patch-hlsdk-shared-clientbugs.py` and `patch-hlsdk-mod-bugs.py`. The `-intel`
tree is a clean checkout.

No studio-model byte swap is applied to these trees, and none is needed: the
engine swaps studio animation data in `Mod_LoadCacheFile` and
`R_StudioLoadHeader`, for the mods exactly as for the base game. A client-side
swap on top of that is a second swap, which is the identity undone, and it
crashed the base game on every PowerPC machine until it was removed.
`docs/port/PPC-PORT-NOTES.md`.

Both checkouts of a branch are pinned to the same commit, and
`tests/test-repo.py` fails if any branch in `installer/mods.map` has no
40-character pin below. `sohl1.2` once shipped with none, which meant that
release could not be rebuilt from this file alone.

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

## Everything else, and where it went

| was recorded here | now |
|---|---|
| engine, menu, miniutl, libbacktrace, game dylibs | `scripts/build-pins.sh` |
| SDL for the PowerPC slices | `scripts/build-pins.sh`, `PIN_SDL_*` |
| mbedTLS, zlib, LZMA for the installer | `scripts/build-pins.sh` |
| captured hand-edits to trees we did not own | gone, with the trees |

The installer's three libraries are pinned straight at their own upstreams
because we patch none of them. Why each is needed at all, rather than using what
the system provides, is in `docs/adr/0011` and `scripts/build-pins.sh`.
