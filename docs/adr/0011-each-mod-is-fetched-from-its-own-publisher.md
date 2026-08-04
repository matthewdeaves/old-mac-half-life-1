# 11. Each mod is fetched from its own publisher, and the installer carries its own TLS

Date: 2026-07-29
Status: accepted

## Context

ADR 0006 settled that we ship code and never content. ADR 0009 settled that the
thing which fetches content is a native Cocoa app. Neither settled **where the
content comes from**, and until now the answer was: one 2.7 GB disk image,
assembled by one person, downloaded from one mirror, containing 26 mods.

That arrangement had three problems, in increasing order of seriousness.

It was **fragile**. Every mod in the catalogue depended on a single file
remaining available at a single URL. There was no per-mod fallback, because there
were no per-mod sources.

It was **coarse**. A player who wanted one mod downloaded all of them, which on a
G3 over wifi is hours.

It was **wrong about three of its contents**. Blue Shift, Opposing Force and
Deathmatch Classic are Valve retail products, not free mods. Pointing users at a
2.7 GB download in order to obtain them sat badly beside a project whose stated
position is that Valve's data is the player's to supply.

## Decision

**Fetch each mod from its own public release, one at a time, and never fetch a
Valve product at all.**

`installer/mod-sources.txt` carries, per mod: an ordered list of URLs, the
archive format, the exact size, the md5, and the subtree inside the archive where
the mod's own tree begins. `OMFetch` downloads, checks, unpacks and stages; the
existing `OMInstaller` then does exactly what it did for a mounted volume.

Three consequences follow, and each required real work.

### The app carries its own TLS

Measured against the live hosts: `moddb.com`, `gamebanana.com`,
`runthinkshootlive.com`, `twhl.info`, `files.moddb.com`, `hl-improvement.com` and
`csm.dev` all answer a plain-http request with a `301` to https. The G3's own
`curl` links OpenSSL 0.9.7b from 2003 and cannot negotiate with any of them.

So `Half-Life Mods.app` links **mbed TLS 3.6 LTS**, built into both slices, with a
shipped Mozilla root bundle. Verified on a G3 (ppc750) and a G5 (ppc970), both on
10.3.9: TLS 1.3, ChaCha20-Poly1305, certificates validated, `Range:` resume
working through the session, 4.0 MB/s. This is the installer only; the engine's
own HTTPS situation is untouched.

archive.org is still fetched over plain http, because it works there end to end
and the md5 is the integrity check either way.

### The app carries its own zip and 7z decoders

Sources arrive in whatever their publisher chose: 6 zip, 12 7z. We host nothing,
so we cannot repackage them into one format.

The 7z case is the interesting one. These archives are **solid** - one LZMA stream
spans many files - and the SDK decodes a whole block into a single buffer. Echoes
expands to 450 MB, which on a 448 MB G3 is not an allocation that can succeed. The
fix is not a rewritten decoder but a different allocator: large requests are
backed by an unlinked temp file on the target volume and mmapped, so the pages are
file-backed and evictable rather than anonymous and swap-bound. Measured
completing on that G3, byte-identical to the Intel result.

### Seven mods cannot be fetched, and the app says so per mod

- **`bshift`, `gearbox`, `dmc`** are Valve products. Never downloaded, by policy.
  If the content is already beside `Half-Life.app`, the installer detects it and
  installs the game code, which is the only part that was ever missing.
- **`aom`, `eftd`, `vendetta`, `TheGate`** have no public release in a format any
  Mac tool can open. Two are Clickteam Install Creator, one is a self-extractor
  7-Zip itself cannot read, and for The Gate no archive form was found at all.

Both groups install through `Choose...`, from content the player supplies.
`OMSkipReason()` names each one individually rather than reporting a count.

## Alternatives rejected

**Keep the bundle, add per-mod sources as a fallback.** Two code paths, two sets
of expectations, and the Valve-content problem unaddressed. The bundle would also
have stayed the default, so the fragility would have stayed real.

**Host the content ourselves, or on a GitHub release.** This is the one that
looks easiest and is most clearly wrong. It would make us a redistributor of
other people's work and of Valve's products, and it contradicts the position in
ADR 0006 that the rest of the project is built around.

**Use ModDB, where most of these mods are nominally published.** Not possible:
ModDB sits behind Cloudflare and answers a non-browser client with `403` before
TLS or anything else matters. Measured, not assumed.

**Skip TLS and use only plain-http sources.** archive.org alone covers roughly
half the catalogue. The other half would have been unreachable, which is most of
the reason the bundle existed in the first place.

## Consequences

- The catalogue no longer depends on any single file, host or person.
- A player can install one mod without downloading the other 24, and a second run
  re-fetches nothing.
- **`manifests.txt` is deliberately incomplete**: 18 rows, not 25. A manifest is
  the expected result of unpacking a known archive, so it can only exist where
  there is an archive. `tests/test-repo.py` checks that every *sourced* mod has a
  row and that no unsourced mod has one, which is a stronger invariant than the
  blanket check it replaced.
- The installer gained three vendored dependencies (mbed TLS, zlib, LZMA SDK),
  all pinned in `scripts/build-pins.sh` and cloned by `bootstrap-vendor.sh`.
- Sources will rot. A dead URL is now a per-mod failure with a named reason
  rather than a dead catalogue, but the file will need revisiting, and the md5s
  are what turn a silently-changed mirror into a hard failure.

**Risks accepted**

- **Content differs from what the bundle carried.** `blackops` and `rp` are
  different releases, not repackagings - `rp` is 290 files against the bundle's
  30. They are the mods' own published versions, which is the right default, but
  they have had less testing on these machines than the bundle's copies had.
- **We depend on hosts we do not control.** runthinkshootlive and archive.org are
  both long-lived and neither is ours. That is the trade for not hosting content.
