# Half-Life dedicated server, Linux

A headless Half-Life server built from the same pins as the Mac fat binary.
One Linux architecture, no packages to install.

## What is in the tarball

```
xash                         the engine, built --dedicated
filesystem_stdio.so          the filesystem module the engine loads
valve/dlls/hl_amd64.so       the game logic, server side
valve/cl_dlls/               the client library, carried but never loaded
server.cfg                   configuration, goes in valve/
systemd/xash-server.service
BUILD-INFO.txt               the pins this was built from
```

No content. We ship code, not content: supply your own `valve/` from your copy
of the game, exactly as the Mac release expects.

`hl_amd64.so` cannot be borrowed from the Mac release. The game logic runs on
the server, as native code for the server's CPU.

## Why this works with the vintage Mac clients

The port changes nothing on the wire. Against upstream, our engine branch
leaves `net_buffer.c`, `net_chan.c`, `net_encode.c` and the delta tables
untouched, and the only net edits are host-local behaviour. Both ends speak
stock Xash3D FWGS `PROTOCOL_VERSION 49`.

That is guaranteed by construction rather than by testing, because this server
is built from the same `scripts/build-pins.sh` as the five Mach-O slices. The
driver refuses to build a tree that is not at the pin.

Cross-endian play is not new here either: a G5, a G4 and an Intel Mac have
already played together in one game, so a little-endian Linux server talking
to big-endian PowerPC clients is the arrangement that already works.

## Requirements

Any Linux with glibc 2.31 or newer, so Ubuntu 20.04 and up, Debian 11 and up.
The only shared libraries loaded are part of glibc.

## Install

```sh
sudo useradd --system --home /opt/half-life-server --shell /usr/sbin/nologin halflife
sudo mkdir -p /opt/half-life-server
sudo tar xzf half-life-server-*-linux-x86_64.tar.gz --strip-components=1 \
     -C /opt/half-life-server

# your own copy of the game content, merged into the valve/ that is already
# there, so the dlls/ and cl_dlls/ from the tarball survive
sudo cp -R /path/to/your/valve/. /opt/half-life-server/valve/

sudo cp /opt/half-life-server/server.cfg /opt/half-life-server/valve/server.cfg

sudo chown -R halflife:halflife /opt/half-life-server
sudo cp /opt/half-life-server/systemd/xash-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now xash-server
```

`server.cfg` goes in `valve/`. The engine execs it by name once the game is
up, so unlike the Quake servers there is no `+exec` on the command line.

Set `sv_password` and `rcon_password` in it before you expose the port.

## Privacy: two switches, only one of which you want

`public 0` is the listing switch. At 0 the engine sends no heartbeats and the
server appears in no browser. It is the default and it is what keeps this
private.

`sv_lan` is not a privacy switch and must stay `0`. At 1 the engine refuses
non-class-C addresses outright, so it would not unlist the server, it would
reject both of you.

Do not set `public 1`. Besides listing the server, the engine then prints a
notice asking you to open a pull request against `FWGS/server-list` to appear
in the modern list, which is not something this project does.

## Changing the map

**From inside the game**, if `rcon_password` is set. On any client:

```
rcon_address "halflife.example.com:27015"
rcon_password "your-password"
rcon changelevel crossfire
rcon status
```

`rcon` is a restricted command, which means a SERVER cannot make your client
run it. It does not mean you cannot script it: local console, config files and
key binds all count as local. So this works in `userconfig.cfg`, and changing
map on a G4 becomes one keypress:

```
bind F6 "rcon changelevel crossfire"
bind F7 "rcon changelevel boot_camp"
```

The rcon password crosses the network in the clear. Long, random, used nowhere
else.

**From the server**, through the FIFO the systemd unit sets up:

```sh
echo "changelevel crossfire" | sudo tee /run/half-life-server/console
echo "status"                | sudo tee /run/half-life-server/console
journalctl -u xash-server -f
```

Rotation comes from `valve/mapcycle.txt`, one map name per line.

There is also XRCON in this engine, a TCP admin console on
`127.0.0.1:27000`. It has no authentication of any kind, so leave it bound to
localhost and reach it over an ssh tunnel. Never bind it to `0.0.0.0`.

## The network side

Default port is UDP 27015, IPv4 and IPv6.

```sh
sudo ufw allow from <their.ip.here> to any port 27015 proto udp
sudo ufw allow from <your.ip.here>  to any port 27015 proto udp
```

Between `sv_password` and the firewall this is genuinely private, but the
protocol underneath is from 1998 and has no encryption. Treat the box as
disposable and do not co-host anything you care about.

### The firewall is not optional, and here is the measured reason

This server answers unauthenticated status queries, and it answers them with a
great deal more than it was asked. Measured against this exact build:

| Query | Sent | Received | Amplification |
|---|---|---|---|
| `A2S_RULES` | 9 bytes | 912 bytes | **101x** |
| `xash-info` | 11 bytes | 103 bytes | 9x |
| `A2S_INFO` | 25 bytes | 56 bytes | 2x |

The handlers are ungated: `SV_SourceQuery_HandleConnnectionlessPacket` checks
no password, no `public` and no `sv_lan`. So anyone who can reach the port can
spoof your address as the source, send 9-byte queries, and have your server
fire 912-byte replies at someone else. That is a DDoS reflector, and the
traffic leaves your box under your IP.

An address allowlist fixes it completely, because a spoofed packet claims to
come from the victim rather than from you, and the allowlist drops it. That is
why the `ufw` rules above are written per source address rather than opening
the port to the world.

### The engine also limits itself now

Since engine commit `08637ea6`, the engine keeps a leaky bucket per source
address and drops unauthenticated queries from an address that has had its
allowance. `BUILD-INFO.txt` in the tarball says which engine commit your copy
was built from. It is on by default:

| Cvar | Default | What it does |
|---|---|---|
| `sv_query_rate_burst` | `10` | queries allowed per address per period. `0` turns the limiter off |
| `sv_query_rate_period` | `1` | seconds each slot takes to drain |

Measured, 40 `A2S_RULES` queries from one address: with the limiter off, 40
replies and 36,240 bytes. At the default, **10 replies and 9,060 bytes**.
Joining is deliberately not throttled, so `connect` and `getchallenge` are
unaffected. Ten queries a second per address is far above anything a server
browser does, and LAN play is unchanged. Turn it down if you are running a
public server; there is no reason to turn it up.

**This is a second layer, not a replacement for the allowlist.** The allowlist
stops a spoofed packet reaching the engine at all; the limiter caps what the
engine emits once one does. Keep both.

If both ends have dynamic addresses and an allowlist is impractical, add a
kernel-level limit as well, which caps the box no matter who asks and applies
before the packet costs the engine anything:

```sh
sudo iptables -A INPUT -p udp --dport 27015 \
  -m hashlimit --hashlimit-name hl-query --hashlimit-above 10/sec \
  --hashlimit-burst 20 --hashlimit-mode srcip -j DROP
```

Upstream Xash3D has since added a challenge to `A2S_RULES` and `A2S_PLAYERS`,
which fixes this properly by making a querier prove it can receive at the
address it claims. Our pin predates that commit. Moving the pin means
rebuilding and retesting the Mac release too, so it is a deliberate decision
rather than something to do quietly.

For comparison, the other three servers in this family measure 32x (Quake III,
rate limited by the engine), 23x (Quake II, rate limited by the engine since
2026-08-21) and 3x (Quake 1, which is not).

## Connecting

From the Mac client, by address or by name:

```
connect halflife.example.com
connect halflife.example.com:27015
```

A hostname is the better answer. The engine resolves through `getaddrinfo`, so
point an A record at the box and that name is all either of you types. Worth
knowing that typing a hostname used to stall the frame loop for fifteen to
twenty seconds on a G4, with keystrokes arriving all at once afterwards; that
was fixed on our engine branch, so the Add Server box and `connect` both
behave normally on the vintage machines now.

If `sv_password` is set, `password "..."` on the client first.

## Tuned for the machines that will actually connect

The clients here are the fat binary: `ppc750`, `ppc7400`, `i386`, `x86_64` and
`arm64` out of one app. That spread changes two things and, usefully, does not
change a third.

**Update rate is the one that matters.** `sv_maxupdaterate` is set to 60
rather than the usual 100. A G3 cannot draw a hundred frames a second, so
every update above what it can draw is bandwidth spent on a frame that never
appears. The limit worth tuning against is the oldest machine, and on these
the constraint is fill rate, never the link: the G3 is fill-rate bound, which
is the whole reason it ships a 16-bit display profile. `sv_minupdaterate 20`
keeps the floor sane for a slow link.

**Timeouts are generous.** `sv_timeout 120`, because a vintage Mac stalling
briefly should not be dropped. The same reasoning put `sv_minPing`-style
rejection out of the Quake III config.

**Endianness needs nothing.** A little-endian Linux server talking to
big-endian PowerPC clients is exactly the arrangement that already works: a
G5, a G4 and an Intel Mac have played in one game together. The protocol
converts, and this server is built from the same pins as those clients, so
both ends agree on the wire format by construction.

Map choice is worth the same thought as the update rate. Pick a rotation you
have actually watched run on the oldest machine that will join, not on the
Apple Silicon one where everything is fast.

## Building it yourself

```sh
scripts/build-server-linux.sh                 # x86_64
scripts/build-server-linux.sh --arch aarch64  # ARM VPS
```

Runs on this box in a container. It is not a mini job: no mini has a Linux
toolchain and none is needed. Sources come from `scripts/build-pins.sh`, and
the driver refuses to build a tree that is not at the pin.
