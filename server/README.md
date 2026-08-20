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

## Building it yourself

```sh
scripts/build-server-linux.sh                 # x86_64
scripts/build-server-linux.sh --arch aarch64  # ARM VPS
```

Runs on this box in a container. It is not a mini job: no mini has a Linux
toolchain and none is needed. Sources come from `scripts/build-pins.sh`, and
the driver refuses to build a tree that is not at the pin.
