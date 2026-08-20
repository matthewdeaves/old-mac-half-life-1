# 14. The server is a UDP amplifier, so it is allowlisted, hardened and sandboxed

Date: 2026-08-20
Status: accepted

## Context

The dedicated server (ADR 0013) is a 1998 codebase parsing UDP datagrams from
strangers, meant to run unattended on a box that is not ours to lose. That is a
different threat model from the Mac client, which the player launches at
content they already own.

Measured against this exact build, the engine answers **unauthenticated** status
queries with far more than it was asked for:

| Query | Sent | Received | Amplification |
|---|---|---|---|
| `A2S_RULES` | 9 bytes | 912 bytes | **101x** |
| `xash-info` | 11 bytes | 103 bytes | 9x |
| `A2S_INFO` | 25 bytes | 56 bytes | 2x |

The handlers are ungated: `SV_SourceQuery_HandleConnnectionlessPacket` checks no
password, no `public` and no `sv_lan`, and there is no rate limit anywhere in
the engine, unlike ioquake3 which carries a leaky bucket. So the server is a
usable DDoS reflector. Spoof a victim as the source, send 9 bytes, and the box
fires 912 back under our IP. For comparison the other three servers in this
family measure 32x (Quake III, but rate limited by the engine), 23x (Quake II)
and 3x (Quake 1).

## Decision

**Defend it operationally at the firewall, harden the binary, and confine the
process, rather than moving the engine pin.**

### 1. The firewall rules are per source address, and that is the fix

An address allowlist fixes amplification completely, because a spoofed packet
claims to come from the victim rather than from the operator, and the allowlist
drops it. That is why the `ufw` rules in `server/README.md` name each source
address instead of opening UDP 27015 to the world.

Where both ends have dynamic addresses and an allowlist is impractical, an
`iptables` `hashlimit` recipe is documented instead. It caps what the box can
emit no matter who asks, which is weaker than an allowlist and better than
nothing.

### 2. The binary is hardened, which the Mac builds are not

`scripts/build-server-linux.sh` exports `-fstack-protector-strong
-D_FORTIFY_SOURCE=2` and `-Wl,-z,relro,-z,now -Wl,-z,noexecstack` before
configure, on top of the PIE and NX Debian gives by default. waf bakes the
environment in at configure time, so exporting after configure would silently
do nothing; the driver then **asserts all three landed** in the linked output
rather than trusting that they arrived.

### 3. The systemd unit confines the process

`server/xash-server.service` carries seccomp (`@system-service`, minus
`@privileged`, `@resources`, `@obsolete`, `@cpu-emulation`, `@debug`, `@mount`,
`@swap`, `@reboot`, `@module`, with `SystemCallErrorNumber=EPERM` so a blocked
call returns an error instead of killing the process), `PrivateUsers`,
`ProtectProc=invisible`, `RestrictSUIDSGID`, an empty `CapabilityBoundingSet`,
`MemoryDenyWriteExecute`, and `MemoryMax=1G` / `TasksMax=64` /
`LimitNOFILE=1024` so a memory-exhaustion bug cannot take the box with it.
`systemd-analyze security` rates the result **1.4 out of 10** exposure, and
`systemd-analyze verify` is clean.

### 4. XRCON stays on localhost

This engine carries XRCON, a TCP admin console on `127.0.0.1:27000`, with **no
authentication of any kind**. It is reached over an ssh tunnel. Never bind it to
`0.0.0.0`.

## Alternatives rejected

**Move the engine pin to pick up the upstream fix.** Upstream Xash3D has since
added a challenge to `A2S_RULES` and `A2S_PLAYERS`, which fixes amplification
properly by making a querier prove it can receive at the address it claims. Our
pin predates that commit. Moving the pin means rebuilding and retesting the Mac
release across five slices, so it is recorded here as a decision taken rather
than made quietly. It remains the right long-term fix and is the first thing to
revisit at the next pin bump.

**Rely on `sv_password` alone.** It gates joining, not querying. The status
handlers run before any password is consulted.

**Rely on `public 0`.** It stops heartbeats and delists the server. It does not
stop anyone who knows the address from querying it.

**Set `sv_lan 1` to shut the queries down.** At `1` the engine refuses
non-class-C addresses, so it would reject the players the server exists for
(ADR 0013).

## Evidence

**Fuzzing.** 25000 malformed out-of-band packets across five seeds against this
build: no crash, no hang. For contrast the same harness took the Quake II server
down in 250 packets. That is a statement about out-of-band packet parsing only;
it exercises nothing behind a completed connection handshake.

**Amplification.** The table above, measured against this build rather than read
off the protocol.

**Hardening.** Asserted post-link by the driver, not assumed from the flags.

**Sandboxing.** `systemd-analyze security` and `systemd-analyze verify`.

## Consequences

- A default install is private and not usable as a reflector, but only because
  the firewall is part of the install. `server/README.md` states that the
  firewall is not optional and gives the measured reason, so an operator who
  opens the port to the world is doing it knowingly.
- The protocol underneath has no encryption, and the rcon password crosses the
  network in the clear. `server/README.md` says to treat the box as disposable
  and not to co-host anything that matters.
- The hardening is asserted, so a toolchain or waf change that dropped a flag
  fails the build instead of shipping quietly.
- Risk: the amplification is unfixed in the engine we ship. Everything above
  bounds it; none of it removes it. It comes back the moment somebody opens the
  port to the world.
- Risk: the fuzzing covers connectionless packets. A defect reachable only after
  a handshake is untested here.

## Related

- ADR 0013: what the server is and how it is built.
- `server/README.md`: the operator-facing version of all of this, with the
  `ufw` and `iptables` recipes.
