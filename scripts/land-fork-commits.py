#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
land-fork-commits.py - turn our patch scripts into real commits on our own forks.

Why this exists
---------------
The port used to be carried as scripts/patch-*.py: Python that string-replaces
its way through a freshly cloned upstream tree at build time. That works, but
nobody can read it. A reviewer cannot see what the port actually changes without
running the scripts first, and the interesting part - the reasoning - is buried
in a comment above a pile of escaped C.

So each fix becomes one commit on our own fork of the upstream it belongs to,
with a real diff and the reasoning as the commit message. The build then just
checks out a pin. This script is the one-time migration that gets us there, and
it stays in the tree afterwards as the record of which commit came from which
fix.

Usage
-----
    land-fork-commits.py --repo engine   --tree ~/Documents/oldmac-forks/xash3d-fwgs
    land-fork-commits.py --repo mainui   --tree .../3rdparty/mainui
    land-fork-commits.py --repo hlsdk    --tree ~/Documents/oldmac-forks/hlsdk-portable
    land-fork-commits.py --repo sdl      --tree ~/Documents/oldmac-forks/panther-sdl2
    land-fork-commits.py --repo libbacktrace --tree .../3rdparty/libbacktrace/libbacktrace

    --dry-run   print the commit messages and stop, touching nothing
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# A whole PARAGRAPH is dropped when it is about the mechanics of patching rather
# than about the fix: nothing in a commit needs to know the edit was idempotent or
# which anchor string it looked for. Dropping by paragraph and not by line matters,
# because half a paragraph reads as a truncated sentence.
PATCH_MECHANICS = re.compile(
    r'(idempotent|safe to re-?run|py(thon)? 2\.5|anchor not found|already patched|'
    r'applied to one or more|whole-word|re-run on a pristine tree)', re.I)

# Turn the language of a script that edits a tree into the language of a change.
REPHRASE = [
    (r'^Idempotently patch [^\s]+ so ', 'Make the engine so '),
    (r'\bThis script ALSO carries\b', 'This commit also carries'),
    (r'\bThis script\b', 'This change'),
    (r'\bthis script\b', 'this change'),
    (r'\bThe script\b', 'The change'),
    (r'\s*Idempotent[.,][^\n]*', ''),
    (r'^patch-[a-z0-9-]+\.py - ', ''),
]


def header_of(script):
    """Pull the leading prose out of a patch script: either its docstring or its
    run of leading # comments. Returns a list of lines with the markup gone."""
    with open(os.path.join(HERE, script)) as fh:
        src = fh.read()

    lines = src.split('\n')
    i = 0
    while i < len(lines) and (lines[i].startswith('#!') or 'coding:' in lines[i]):
        i += 1

    out = []
    if i < len(lines) and lines[i].startswith('"""'):
        i += 1
        while i < len(lines) and not lines[i].startswith('"""'):
            out.append(lines[i].rstrip())
            i += 1
    else:
        while i < len(lines) and (lines[i].startswith('#') or not lines[i].strip()):
            if not lines[i].strip():
                out.append('')
                i += 1
                continue
            ln = lines[i][1:]           # drop the '#'
            if ln.startswith(' '):
                ln = ln[1:]             # and the single space that follows it
            out.append(ln.rstrip())
            i += 1

    text = '\n'.join(out)
    for pat, repl in REPHRASE:
        text = re.sub(pat, repl, text, flags=re.M)

    # Underlines under a heading are noise once the heading is a plain line.
    text = re.sub(r'^[-=]{3,}\s*$', '', text, flags=re.M)

    paras = [p for p in re.split(r'\n\s*\n', text)]
    kept = [p.rstrip() for p in paras
            if p.strip() and not (PATCH_MECHANICS.search(p) and len(p) < 400)]
    return '\n\n'.join(kept).strip().split('\n')


# This port is our own work on top of the named upstreams and nothing else. A
# commit that describes our fix by pointing at somebody else's fork undercuts
# that, so the names are refused outright rather than left to review.
[removed]

# A commit message describes the code. How the work was organised, reviewed or
# checked belongs in the repo's own docs, not in the history of an upstream fork.
PROCESS_TALK = re.compile(
    r'\b(differentiation audit|refutation pass|code review pass|subagent|'
    r'an agent (was )?(told|asked|briefed)|clean.?room)\b', re.I)


def message(subject, script, extra=None):
    body = header_of(script)
    parts = [subject, '']
    if extra:
        parts += [extra, '']
    parts += body
    txt = '\n'.join(parts).rstrip() + '\n'
    # Collapse runs of blank lines left behind by the paragraph filter.
    txt = re.sub(r'\n{3,}', '\n\n', txt)

    for rx, why in ((BLOCKED, 'names a third-party tree'),
                    (PROCESS_TALK, 'talks about how the work was organised')):
        hit = rx.search(txt)
        if hit:
            line = next(l for l in txt.split('\n') if rx.search(l))
            raise SystemExit(
                '%s: commit message %s (%r)\n  %s\n'
                'Rewrite the header comment in that script so it describes the fault\n'
                'and the fix, and nothing else.' % (script, why, hit.group(0), line.strip()))
    return txt


# --- what lands where --------------------------------------------------------
#
# Ordered as a story rather than alphabetically: make it compile, make it launch,
# make it draw, make it play mods, make it talk to the network, make it
# debuggable. A reader going top to bottom sees the port being brought up.

ENGINE = [
    # -- make it compile on a 2003 toolchain --
    ('patch-net-ws-thread-t.py', ['engine/common/net_ws.c'],
     "net_ws: rename a local thread_t that Panther's mach headers already own"),

    # -- make a double-clicked .app launch --
    ('patch-game-launch.py', ['game_launch/game.cpp'],
     'game_launch: find libxash next to the executable, not next to the cwd'),
    ('patch-lib-posix.py', ['engine/platform/posix/lib_posix.c'],
     'lib_posix: resolve engine dylibs by full path, and undo Panther name mangling'),
    ('patch-fs-applebundle.py', ['engine/common/filesystem_engine.c'],
     'filesystem: a bundled .app has its read-only game root inside itself'),
    ('patch-host-plain-gamelib.py', ['engine/common/host.c'],
     "host: the pre-flight library check must accept a mod's own dylib name"),

    # -- make it draw --
    ('patch-gl-apple-context.py', None,
     'vid_sdl: stop asking Cocoa for a GL profile it cannot give us'),
    ('patch-gl-version-query.py', ['ref/gl/gl_opengl.c'],
     'ref_gl: do not ask a legacy GL context for a GL 3.0 enum'),
    ('patch-vid-drawable.py', ['engine/platform/sdl2/vid_sdl2.c'],
     'vid_sdl: refuse a drawable size that cannot be real'),
    ('patch-palette-endian.py', ['engine/common/imagelib/img_wad.c'],
     'imagelib: clear the palette alpha byte on the byte that actually holds it'),
    ('patch-bmp-palette-alpha.py', ['engine/common/imagelib/img_bmp.c'],
     'imagelib: a BMP palette entry has no alpha byte, so do not read one'),
    ('patch-soft-screenshot.py', ['ref/soft/r_glblit.c'],
     'ref_soft: write screenshot pixels as bytes, not as a native-order word'),
    ('patch-con-font-renderer-switch.py', None,
     'console: drop the font when the renderer that owns its texture goes'),
    ('patch-single-pass-multitexture.py', None,
     'ref_gl: draw the world in one multitexture pass instead of two'),

    # -- make it play mods --
    ('patch-gamedll-plain-name.py', None,
     "mods: load game code from liblist.gam's plain name as well as the suffixed one"),
    ('patch-cl-gamedir-client.py', ['engine/client/cl_main.c'],
     "mods: prefer the current gamedir's client library over the base game's"),
    ('patch-sys-newinstance-fork.py', None,
     'mods: fork before exec so "change game" can actually restart the engine'),

    # -- make it talk to the network without freezing --
    ('patch-net-local-address.py', ['engine/common/net_ws.c'],
     'net_ws: take our own address from the interface list, not from a blocking lookup'),
    ('patch-net-no-blocking-resolve.py', None,
     'net_ws: no hostname is ever resolved on the frame loop'),

    # -- make it debuggable --
    ('patch-startup-diagnostics.py', None,
     'host: two startup lines described a normal state as a problem'),
    ('patch-crash-libbacktrace.py', None,
     'crash handler: produce a backtrace that names frames on the PowerPC slices'),
    ('patch-timerefresh.py', None,
     'engine: add a demo-free timerefresh benchmark command'),
    ('patch-mbedtls-oldmac.py', ['3rdparty/mbedtls/xash_psa_config.h'],
     'mbedtls: take the millisecond clock from the engine, not from a 10.12 symbol'),
]

# Two menu fixes we used to carry are absent here on purpose. Upstream already
# swaps the BMP header to host order in CBMP::LoadFile, and its PicButton reaches
# the artwork test on every architecture, so patch-mainui-bmp-endian.py and
# patch-mainui-picbutton-endian.py have nothing left to change. Both were checked
# against this base and now only report what they found, so they are kept as
# checks and are not commits.
MAINUI = [
    ('patch-mainui-space-metrics.py', None,
     'font: an uninitialised glyph box gave the space a garbage advance width'),
    ('patch-mainui-console.py', ['menus/Main.cpp'],
     'Main: the Console button does not need a developer build'),
    ('patch-mainui-localize-optional.py', None,
     'localise: an absent optional dictionary is not a fault'),
    ('patch-mainui-menu-reload-statics.py', None,
     'reload: a Darwin dlclose does not unload us, so statics must be rebuilt'),
    ('patch-mainui-logo-nullcheck.py', None,
     'logo: the spray spinner crashed on a BMP it could not load'),
    ('patch-mainui-logo-picker.py', None,
     'logo: drop the phantom slot, and preview a spray the way it is sprayed'),
    ('patch-mainui-modart.py', None,
     'Custom Game: show each mod its own artwork and description'),
    ('patch-mainui-modlist.py', None,
     'Custom Game: a readable Type column and a name column wide enough for it'),
    ('patch-mainui-modsize.py', None,
     'Custom Game: no "0.0 Mb" for a mod that omits the optional size field'),
    ('patch-mainui-name-dialog-escape.py', None,
     'Multiplayer: Escape must dismiss the name dialog'),
]

MINIUTL = [
    ('patch-mainui-miniutl-endian.py', ['minbase_endian.h'],
     'minbase_endian: recognise the byte-order macro that older GCC is all that defines'),
]

LIBBACKTRACE = [
    ('patch-libbacktrace-bswap.py', ['macho.c'],
     'macho: a portable byte swap for compilers older than __builtin_bswap32'),
]

HLSDK = [
    ('patch-hlsdk-xcompile-ppc.py', ['scripts/waifulib/xcompile.py'],
     'xcompile: do not hand a PowerPC compiler x86 -march flags'),
    ('patch-hlsdk-ppc-darwin.py', None,
     'build: Apple ld has no --no-undefined, and darwin does not imply clang'),
    ('patch-hlsdk-shared-clientbugs.py', None,
     'client: big-endian faults on the director and HLTV path'),
    ('patch-hlsdk-studio-endian.py', None,
     'studio: byte-swap the model data the renderer reads directly'),
]

# patch-hlsdk-mod-gcc4.py and patch-hlsdk-mod-bugs.py are deliberately not here.
# They do not touch hlsdk-portable at all: they are applied by build-mod.sh to the
# separate source tree of each mod we build, which is 25 unrelated upstreams. Those
# stay as scripts, because there is no one repository for them to be commits in.

SDL = [
    ('patch-panther-sdl-version-guards.py',
     ['src/video/cocoa/SDL_cocoawindow.m', 'src/video/cocoa/SDL_cocoakeyboard.m',
      'src/video/cocoa/SDL_cocoavideo.h', 'src/video/cocoa/SDL_cocoamouse.h'],
     'cocoa: gate the 10.5-era paths on the SDK version, not on a macro name'),
    ('patch-panther-sdl-displayname.py', ['src/video/cocoa/SDL_cocoamodes.m'],
     'cocoa: drop the 10.4-only IODisplay call that 10.3 has no symbol for'),
    ('patch-panther-sdl-panther-apis.py', ['src/filesystem/cocoa/SDL_sysfilesystem.m'],
     'filesystem: use only the APIs that exist on 10.3'),
    ('patch-panther-sdl-cursors.py', ['src/video/cocoa/SDL_cocoamouse.m'],
     'cocoa: ask whether a system cursor exists before selecting it'),
    ('patch-panther-sdl-textinput.py', ['src/video/cocoa/SDL_cocoakeyboard.m'],
     'cocoa: text input without the Text Input Services that arrived in 10.5'),
    ('patch-panther-sdl-altivec-include.py',
     ['src/video/cocoa/SDL_cocoamessagebox.m', 'src/video/cocoa/SDL_cocoavideo.m'],
     'cocoa: the AltiVec header the Panther toolchain expects'),
]

SETS = {
    'engine': ENGINE,
    'mainui': MAINUI,
    'miniutl': MINIUTL,
    'libbacktrace': LIBBACKTRACE,
    'hlsdk': HLSDK,
    'sdl': SDL,
}


def run(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if p.returncode:
        sys.stderr.write('FAILED: %s\n%s%s\n' % (' '.join(cmd), p.stdout, p.stderr))
        sys.exit(1)
    return p.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True, choices=sorted(SETS))
    ap.add_argument('--tree')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    items = SETS[args.repo]

    if args.dry_run:
        for script, _, subject in items:
            print('=' * 72)
            print(message(subject, script))
        return

    tree = os.path.abspath(os.path.expanduser(args.tree))
    # A submodule's .git is a file pointing at the superproject's modules dir,
    # not a directory, and three of these five repos are submodules.
    if not os.path.exists(os.path.join(tree, '.git')):
        sys.exit('not a git tree: ' + tree)

    dirty = run(['git', 'status', '--porcelain'], cwd=tree).strip()
    if dirty:
        sys.exit('tree is dirty, refusing to start:\n' + dirty)

    for script, argv, subject in items:
        path = os.path.join(HERE, script)
        targets = [os.path.join(tree, a) for a in argv] if argv else [tree]
        out = run([sys.executable, path] + targets)

        # The tree, not the script's own output, is the evidence. Some scripts
        # report a count, some report per file, and one of them has already been
        # made obsolete by upstream and now reports only what it found. A commit
        # with an empty diff is the failure worth catching.
        if not run(['git', 'status', '--porcelain'], cwd=tree).strip():
            sys.exit('%s left no change in the tree:\n%s' % (script, out))

        run(['git', 'add', '-A'], cwd=tree)
        run(['git', 'commit', '-q', '-m', message(subject, script)], cwd=tree)
        print('%-44s %s' % (script, run(['git', 'log', '--oneline', '-1'], cwd=tree).strip()))


if __name__ == '__main__':
    main()
