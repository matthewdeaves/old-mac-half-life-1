#!/bin/bash
# gen-mod-manifests.sh - derive installer/manifests.txt from the real sources.
#
#   ./gen-mod-manifests.sh [work-dir]        # default: /tmp/oldmac-manifests
#
# RUN THIS ON THE DEV BOX, not a build mini and not a bench machine. It needs
# working https, about 2 GB of downloads and a local 7z, none of which the old
# machines have. The app's own decoders are the ones that matter in the field;
# this is a one-off measurement that produces a table we then ship.
#
# WHAT THE TABLE IS FOR
# ---------------------
# For every mod, how many files and how many bytes a CORRECT install ends up
# with once the exclusions below are applied. The installer ships this table and
# checks its own work against it, so a truncated download or a half-unpacked
# archive is caught immediately instead of surfacing later as a mod that
# half-loads.
#
# WHAT WE REFUSE TO COPY, AND WHY (a correctness feature, not tidying)
# -------------------------------------------------------------------
# Mod releases are packaged by people who played them, so they carry that
# machine's runtime state:
#
#   video.cfg     the packager's own display state. The engine execs video.cfg
#                 and then applies -width/-height from the command line, and our
#                 launcher passes those only on the G3 and Panther profiles, so
#                 on any other machine a leftover video.cfg is the mode the
#                 engine starts in.
#   config.cfg    the packager's keybinds, which silently override the player's.
#   opengl.cfg    GL tuning for hardware two decades newer than a Rage 128.
#   keyboard.cfg  ditto.
#   save/ SAVE/   their actual savegames. Saves are native-endian, so a
#                 PC-recorded save is garbage on PowerPC anyway. This is not a
#                 rounding error: Residual Point ships 69 MB of them.
#   *.bak         Xash's backups of the above.
#   .xash_id      per-install identity; must not be cloned between machines.
#   dlls/ cl_dlls/  Windows game code, which we replace with our own fat build.
#
# Everything else - maps, models, sounds, sprites, wads, and the mod's OWN config
# (skill.cfg, default.cfg, server.cfg, class and map cfgs) - is real mod content
# and is counted.
#
# This script and OMInstaller's omShouldSkipPath() MUST agree. The numbers here
# are what the installer verifies its own copy against, so any divergence makes a
# correctly-installed mod fail verification and be rejected.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/installer/mod-sources.txt"
OUT="$ROOT/installer/manifests.txt"
WORK="${1:-/tmp/oldmac-manifests}"

[ -f "$SRC" ] || { echo "ERROR: missing $SRC" >&2; exit 1; }
command -v 7z   >/dev/null || { echo "ERROR: 7z not found (brew install p7zip)" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found" >&2; exit 1; }

mkdir -p "$WORK/archives" "$WORK/trees"

python3 - "$SRC" "$OUT" "$WORK" <<'PY'
import hashlib, os, subprocess, sys

src_path, out_path, work = sys.argv[1], sys.argv[2], sys.argv[3]


def parse(path):
    mods, cur = [], None
    for line in open(path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, _, val = line.partition(' ')
        val = val.strip()
        if key == 'mod':
            cur = {'mod': val, 'urls': []}
            mods.append(cur)
        elif cur is not None:
            if key == 'url':
                cur['urls'].append(val)
            else:
                cur[key] = val
    return mods


def excluded(rel):
    """Mirrors omShouldSkipPath() in installer/OMInstaller.m, and is deliberately
    structured the same way - first path component vs basename - rather than as a
    glob list, so the two stay comparable by eye."""
    parts = rel.split('/')
    first, base = parts[0], parts[-1]
    if first in ('dlls', 'cl_dlls', 'dlls 2', 'cl_dlls 2'):
        return True
    if first.lower() == 'save':
        return True
    if base in ('config.cfg', 'video.cfg', 'opengl.cfg', 'keyboard.cfg',
                '.xash_id', '.DS_Store', 'last-run.log'):
        return True
    return base.endswith('.bak')


def md5_of(p):
    h = hashlib.md5()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


rows = []
for m in parse(src_path):
    gd, kind = m['mod'], m.get('kind', 'zip')
    archive = os.path.join(work, 'archives', '%s.%s' % (gd, kind))
    tree = os.path.join(work, 'trees', gd)

    if not os.path.exists(archive):
        print('  fetching %s' % gd, flush=True)
        if subprocess.call(['curl', '-sSL', '--fail', '-o', archive, m['urls'][0]]) != 0:
            print('  WARN: could not fetch %s - skipped' % gd, file=sys.stderr)
            continue

    got = md5_of(archive)
    if got != m.get('md5'):
        print('  WARN: %s md5 %s != %s in mod-sources.txt - skipped'
              % (gd, got, m.get('md5')), file=sys.stderr)
        continue

    if not os.path.isdir(tree):
        os.makedirs(tree)
        root = m.get('root', '.')
        # Extract only the mod's own subtree, exactly as the app's `root` does.
        arg = ['7z', 'x', '-y', '-o' + tree, archive]
        if root != '.':
            arg.append(root + '/*')
        subprocess.call(arg, stdout=subprocess.DEVNULL)
        if root != '.':
            inner = os.path.join(tree, root)
            if os.path.isdir(inner):
                for name in os.listdir(inner):
                    os.rename(os.path.join(inner, name), os.path.join(tree, name))

    files = nbytes = skipped = 0
    for dirpath, _, filenames in os.walk(tree):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, tree)
            try:
                sz = os.path.getsize(p)
            except OSError:
                continue
            if excluded(rel):
                skipped += sz
            else:
                files += 1
                nbytes += sz

    rows.append((gd, files, nbytes))
    print('  %-16s %6d files %10d B  (skipped %d B)' % (gd, files, nbytes, skipped), flush=True)

rows.sort()
with open(out_path, 'w') as out:
    out.write("""# manifests.txt - expected result of a correct install, per mod.
#
# Generated by scripts/gen-mod-manifests.sh from the sources in mod-sources.txt,
# by fetching each archive, checking its md5, unpacking the subtree named by its
# `root`, and applying the same exclusions the installer does.
# Columns: gamedir  files  bytes
#
# 'files'/'bytes' EXCLUDE the Windows game dlls (we supply our own), the
# packager's savegames, and engine-generated per-machine state - see the script
# header for the full list and the reasoning.
#
# Only the mods with an automatable source appear here. The other seven have no
# entry because there is nothing to measure; see the bottom of mod-sources.txt.
#
""")
    for gd, f, b in rows:
        out.write('%-16s %-7d %d\n' % (gd, f, b))

print()
print('wrote %s (%d mods)' % (out_path, len(rows)))
PY
