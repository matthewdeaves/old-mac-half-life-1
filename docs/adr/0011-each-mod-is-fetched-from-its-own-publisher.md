# 11. Each mod is fetched from its own publisher, and the installer carries its own TLS

Date: 2026-07-29
Status: accepted

## Context

ADR 0006 settled that we ship code and never content, ADR 0009 that the fetcher
is a native Cocoa app. Neither settled **where the content comes from**, and the
answer used to be one 2.7 GB disk image from one mirror, containing 26 mods.

That was **fragile**, every mod depending on a single file at a single URL with
no per-mod fallback; **coarse**, one mod meaning a download of all of them, hours
on a G3 over wifi; and **wrong about three of its contents**, since Blue Shift,
Opposing Force and Deathmatch Classic are Valve retail products, not free mods,
so pointing users at a 2.7 GB download to obtain them sat badly beside our
position that Valve's data is the player's to supply.

## Decision

**Fetch each mod from its own public release, one at a time, and never fetch a
Valve product at all.**

`installer/mod-sources.txt` carries, per mod: an ordered list of URLs, the
archive format, the exact size, the md5, and the subtree inside the archive where
the mod's own tree begins. `OMFetch` downloads, checks, unpacks and stages;
`OMInstaller` then does what it did for a mounted volume.

### The app carries its own TLS

Measured against the live hosts: `moddb.com`, `gamebanana.com`,
`runthinkshootlive.com`, `twhl.info`, `files.moddb.com`, `hl-improvement.com` and
`csm.dev` all answer a plain-http request with a `301` to https. The G3's own
`curl` links OpenSSL 0.9.7b from 2003 and cannot negotiate with any of them.

So `Half-Life Mods.app` links **mbed TLS 3.6 LTS** into both slices, with a
shipped Mozilla root bundle. Verified on a G3 (ppc750) and a G5 (ppc970), both on
10.3.9: TLS 1.3, ChaCha20-Poly1305, certificates validated, `Range:` resume
working through the session, 4.0 MB/s. Installer only; the engine's own HTTPS is
untouched. archive.org is still fetched over plain http, because it works there
end to end and the md5 is the integrity check either way.

### The app carries its own zip and 7z decoders

Sources arrive in whatever format their publisher chose, 6 zip and 12 7z, and we
host nothing, so we cannot repackage them.

The 7z archives are **solid**, one LZMA stream spanning many files, and the SDK
decodes a whole block into a single buffer. Echoes expands to 450 MB, which on a
448 MB G3 is not an allocation that can succeed. The fix is a different
allocator, not a rewritten decoder: large requests are backed by an unlinked temp
file on the target volume and mmapped, so the pages are file-backed and evictable
rather than anonymous and swap-bound. Measured completing on that G3,
byte-identical to the Intel result.

### Seven mods cannot be fetched, and the app says so per mod

- **`bshift`, `gearbox`, `dmc`** are Valve products, never downloaded, by policy.
  If the content is already beside `Half-Life.app`, the installer detects it and
  installs the game code, the only part that was ever missing.
- **`aom`, `eftd`, `vendetta`, `TheGate`** have no public release in a format any
  Mac tool can open: two are Clickteam Install Creator, one a self-extractor
  7-Zip itself cannot read, and for The Gate no archive form was found at all.

Both groups install through `Choose...`, from content the player supplies, and
`OMSkipReason()` names each one individually rather than reporting a count.

## Alternatives rejected

- **Keep the bundle, add per-mod sources as a fallback.** Two code paths, the
  Valve-content problem unaddressed, and the bundle still the default.
- **Host the content ourselves, or on a GitHub release.** It makes us a
  redistributor of other people's work and of Valve's products, against ADR 0006.
- **ModDB, where most of these mods are nominally published.** Not possible: it
  sits behind Cloudflare and answers a non-browser client with `403` before TLS
  or anything else matters. Measured, not assumed.
- **Plain-http sources only, skipping TLS.** archive.org alone covers roughly
  half the catalogue; the other half would be unreachable.

## Consequences

- The catalogue no longer depends on any single file, host or person, a player
  can install one mod without the other 24, and a second run re-fetches nothing.
- **`manifests.txt` is deliberately incomplete**: 18 rows, not 25, a manifest
  being the expected result of unpacking a known archive. `tests/test-repo.py`
  checks that every *sourced* mod has a row and no unsourced mod has one, a
  stronger invariant than the blanket check it replaced.
- The installer gained three vendored dependencies, Mbed-TLS, madler/zlib and the
  LZMA SDK from ip7z/7zip, pinned in `scripts/build-pins.sh` and fetched by
  `scripts/fetch-sources.sh`.
- Sources will rot. A dead URL is a per-mod failure with a named reason rather
  than a dead catalogue, but the file needs revisiting, and the md5s turn a
  silently-changed mirror into a hard failure.
- Risk: content differs from what the bundle carried. `blackops` and `rp` are
  different releases, not repackagings: `rp` is 290 files against the bundle's
  30. They are the mods' own published versions, the right default, but less
  tested on these machines.
- Risk: runthinkshootlive and archive.org are long-lived and neither is ours.
  That is the trade for not hosting content.
