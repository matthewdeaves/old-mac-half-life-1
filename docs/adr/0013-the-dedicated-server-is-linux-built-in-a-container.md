# 13. The dedicated server is Linux, built in a container from the same pins

Date: 2026-08-20
Status: accepted

## Context

LAN multiplayer already works across the endian boundary: a G5, a G4 and an
Intel Mac have played in one game together. What was missing was somewhere to
host it. Every Mac in the fleet is a bench and test target (ADR 0005), so a
listen server on one of them consumes the machine being measured, and the
oldest of them is a 450 MHz G3.

A server also has to be protocol-identical to the shipped clients. Getting that
by testing means testing it again on every pin bump, on five slices.

## Decision

**Build a headless Linux server with `scripts/build-server-linux.sh`, on this
box, in a Debian 11 container, from `scripts/build-pins.sh`.**

- The engine is configured `--dedicated`; the tarball carries `xash`,
  `filesystem_stdio.so`, `valve/dlls/hl_amd64.so`, a `valve/cl_dlls/` the
  dedicated server never loads, `server.cfg`, the systemd unit and
  `BUILD-INFO.txt`. `scripts/build-server-linux.sh --arch aarch64` produces the
  ARM VPS build.
- `-8` is not optional: the engine defaults to 32-bit output for GoldSrc mod
  compatibility, and configure fails outright on a 64-bit-only container.
- No content ships. The operator supplies `valve/`, as on the Mac (ADR 0006).
- Debian 11 makes the dependency glibc 2.31, so the floor is Ubuntu 20.04 and
  Debian 11 upward. The only shared libraries loaded are part of glibc. That is
  the same kind of argument as the 10.6 Intel and 10.3.9 PowerPC floors:
  build against the oldest runtime you are willing to serve.
- Operator documentation is `server/README.md`; the unit is
  `server/xash-server.service` and the commented config `server/server.cfg`.

### Protocol identity is by construction, not by testing

Against upstream, our engine branch leaves `net_buffer.c`, `net_chan.c`,
`net_encode.c` and the delta tables untouched; the only edits under
`engine/common/net*` are host-local behaviour (hostname resolution off the
frame loop, taking our own address from the interface list, a `thread_t` rename
for Panther's mach headers), and the two net headers gain nothing but `#ifndef`
typedef guards for old compilers. Both ends speak stock
`PROTOCOL_VERSION 49`. Because the server is built from the same pins as the
five Mach-O slices, and the driver refuses to build a tree that is not at its
pin, that stays true without a test to keep it true.

## Alternatives rejected

**Build it on a mini.** No mini has a Linux toolchain and none needs one. This
is the second product after `arm64` that is not a mini job (ADR 0005), and for
the opposite reason: `arm64` is too new for Lion, Linux is not macOS at all.

**Reuse `hl_amd64.so` out of the Mac release.** The game logic runs on the
server, as native code for the server's CPU. A Mach-O dylib is not a candidate.

**Put `maxplayers` in `server.cfg`.** It stays on the command line as
`+maxplayers 8`. The cvar is `FCVAR_LATCH`, so a value set once the map has
loaded does not apply until the next restart; command-line `+`commands run
before `+map`, which is early enough.

**Write it as `-maxplayers 8`.** Measured: the server came up with four slots.
`maxplayers` is a cvar, `sv_maxclients` registered under that name, so the minus
form is not an engine option at all. It is parsed as nothing, ignored without a
word, and the dedicated default of 4 stands. Both forms start a working server,
so nothing fails; it is quietly the wrong size. Found by running the packaged
tarball rather than the build tree, which is the only way this shows up.

**A plain stdin redirect for the console.** The server sees EOF and stops
reading the moment a writer closes, so exactly one command would ever work. The
unit opens the FIFO read-write on fd 3, keeping a writer attached from the
server's own side.

## Consequences

- One host serves the whole fleet without consuming a bench machine, and a
  little-endian Linux server talking to big-endian PowerPC clients is the
  arrangement that already works.
- `sv_maxupdaterate` is 60 rather than the usual 100, tuned for what will
  actually connect: a G3 cannot draw a hundred frames a second, so every update
  above what it can draw is bandwidth spent on a frame that never appears.
  `sv_minupdaterate 20` keeps the floor sane for a slow link, and
  `sv_timeout 120` stops a briefly stalling vintage Mac being dropped.
- Two cvar name traps, both found by running the config rather than reading the
  source. The cvars are `sv_allowupload` and `sv_allowdownload`, with no
  underscore in the middle, while the C variables behind them are
  `sv_allow_upload` and `sv_allow_download`: `CVAR_DEFINE` takes the
  user-facing name separately from the symbol. Writing the symbol name gets one
  "Unknown command" at startup and leaves uploads and downloads enabled.
  `sv_allow_dlfile` is dropped from the config entirely, the engine's own
  description being "compatibility cvar, does nothing".
- `public 0` and `sv_lan` are not the same switch and are routinely confused.
  `public 0` is the listing switch and is what makes a server private.
  `sv_lan` must stay `0`: at `1` the engine refuses non-class-C addresses and
  would reject the very people the server is for.
- Docker (or Colima) becomes a build dependency of one product. It is on the
  orchestration box only.
- Risk: the server is a fourth thing to keep at the pin. The driver's refusal
  to build off-pin is what makes that safe rather than a promise.

## Related

- ADR 0014: what the server is defended against, and why the firewall rules in
  `server/README.md` are written per source address.
- ADR 0005: where each product is built, and why.
- ADR 0006: we ship code, not content, on Linux as on the Mac.
