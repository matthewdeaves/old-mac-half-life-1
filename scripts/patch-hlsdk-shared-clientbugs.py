#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-hlsdk-shared-clientbugs.py - fix two big-endian faults in hlsdk-portable's
SHARED client code.

Neither belongs to any mod. Both files are byte-identical to hlsdk-portable
master across every branch, so the bugs ship in valve and in all 25 mods alike,
and fixing them here fixes them everywhere at once. Found during the mod endian
audit (docs/MOD-AUDIT.md); both are corruption, not crashes, which is why they
have gone unnoticed - they are only reachable from DRC_CMD_MESSAGE in an HLTV or
director stream, which ordinary single-player and LAN play never touch.


1) cl_dll/hud_spectator.cpp - a 4-byte store into a 1-byte field
-----------------------------------------------------------------

    UnpackRGB( (int&)msg->r1, (int&)msg->g1, (int&)msg->b1, READ_LONG() );

msg is client_textmessage_t*, whose r1/g1/b1 are declared `byte`
(engine/cdll_int.h). UnpackRGB takes int& and stores a full int through each
reference, so each store writes four bytes into a one-byte field.

On little-endian this works BY ACCIDENT: the 0-255 value lands in the
lowest-addressed byte, which is the field, and the three zero bytes that spill
into the neighbours are overwritten by the stores that follow. On big-endian the
most significant byte - 0x00 - lands on the field and the actual colour is
deposited three bytes further on, so director and spectator HUD messages render
black on PowerPC.

Every store stays inside the struct's r1..a2 run, so nothing goes out of bounds,
and PowerPC tolerates the unaligned word stores. Corruption, not a crash.

Fixed by unpacking into three ints and then assigning, which is also what the
type system wanted in the first place.


2) cl_dll/parsemsg.cpp, READ_FLOAT - the byteswap is commented out
------------------------------------------------------------------

    //dat.l = LittleLong( dat.l );

Wire floats are little-endian, so with that line disabled READ_FLOAT returns a
byte-reversed float on PowerPC. Its consumers are the same director path:
msg->x, msg->y, fadein, fadeout, holdtime and fxtime in hud_spectator.cpp.

The replacement rebuilds the value from the four wire bytes, in the same shape as
READ_LONG immediately above, so it needs no new include and is a no-op on
little-endian.

WATCH THE INDEX. `giRead += 4` has ALREADY run by the time control reaches the
commented-out line, so reading gpBuf[giRead] there would pick up the NEXT four
bytes on the wire. The bytes we want are the ones already sitting in dat.b[].
The shifts are done in unsigned to keep the top bit from overflowing a signed int.


Applies to any tree carrying these two files, which is both hlsdk trees and every
mod tree. Idempotent, and each fix has its own marker so a tree carrying one but
not the other still gets completed.

Invoke:
    python patch-hlsdk-shared-clientbugs.py <hlsdk-tree> [<hlsdk-tree> ...]
"""
import io
import os
import sys

SPECTATOR = os.path.join("cl_dll", "hud_spectator.cpp")
PARSEMSG = os.path.join("cl_dll", "parsemsg.cpp")

# --------------------------------------------------------------- spectator --
RGB_MARKER = "// oldmac: UnpackRGB stores a full int through each reference"
# Two spellings across the branch set. dmc unpacks blue into msg->b2 instead of
# msg->b1, and then the very next lines do `msg->b2 = msg->b1;` - overwriting the
# value it just decoded with b1, which was never assigned. So DMC's blue channel
# is stale on EVERY architecture, not just big-endian. The replacement below
# writes r1/g1/b1 properly and fixes that too, for free.
RGB_OLD_VARIANTS = (
    "\t\t\t\tUnpackRGB( (int&)msg->r1, (int&)msg->g1, (int&)msg->b1,"
    " READ_LONG() );\t// color\n",
    "\t\t\t\tUnpackRGB( (int&)msg->r1, (int&)msg->g1, (int&)msg->b2,"
    " READ_LONG() );\t// color\n",
)
RGB_NEW = (
    "\t\t\t\t" + RGB_MARKER + ", but r1/g1/b1 are\n"
    "\t\t\t\t// single bytes (engine/cdll_int.h). On little-endian the wanted byte\n"
    "\t\t\t\t// lands first and the zero spill is overwritten by the stores below,\n"
    "\t\t\t\t// so it works by accident. On big-endian the 0x00 high byte lands on\n"
    "\t\t\t\t// the field instead, and director messages render black.\n"
    "\t\t\t\t{\n"
    "\t\t\t\t\tint cr, cg, cb;\n"
    "\n"
    "\t\t\t\t\tUnpackRGB( cr, cg, cb, READ_LONG() );\t// color\n"
    "\t\t\t\t\tmsg->r1 = (byte)cr;\n"
    "\t\t\t\t\tmsg->g1 = (byte)cg;\n"
    "\t\t\t\t\tmsg->b1 = (byte)cb;\n"
    "\t\t\t\t}\n"
)

# ---------------------------------------------------------------- parsemsg --
FLOAT_MARKER = "// oldmac: wire floats are little-endian"
FLOAT_OLD = "\t//dat.l = LittleLong( dat.l );\n"
FLOAT_NEW = (
    "\t" + FLOAT_MARKER + " and this swap shipped commented\n"
    "\t// out, so READ_FLOAT returned a byte-reversed float on PowerPC. Rebuild the\n"
    "\t// value from the four wire bytes, same shape as READ_LONG above; that is a\n"
    "\t// no-op on little-endian and needs no include.\n"
    "\t// giRead has ALREADY advanced by 4 here, so this must read dat.b[], NOT\n"
    "\t// gpBuf[giRead] - that would pick up the next four bytes on the wire.\n"
    "\tdat.l = (int)( (unsigned int)dat.b[0] | ( (unsigned int)dat.b[1] << 8 )\n"
    "\t             | ( (unsigned int)dat.b[2] << 16 )"
    " | ( (unsigned int)dat.b[3] << 24 ) );\n"
)

FIXES = (
    ( SPECTATOR, RGB_MARKER, RGB_OLD_VARIANTS, RGB_NEW, "spectator UnpackRGB" ),
    ( PARSEMSG, FLOAT_MARKER, ( FLOAT_OLD, ), FLOAT_NEW, "parsemsg READ_FLOAT" ),
)


def patch_file(tree, relpath, marker, variants, new, label):
    path = os.path.join(tree, relpath)
    if not os.path.isfile(path):
        print("  %s: skipped, no %s" % (label, relpath))
        return True

    f = io.open(path, "r", encoding="latin-1")
    src = f.read()
    f.close()

    if marker in src:
        print("  %s: already patched" % label)
        return True

    matched = [ v for v in variants if src.count(v) == 1 ]
    if len(matched) != 1:
        # Every shipped branch carries exactly one spelling of this line. None, or
        # more than one, means upstream moved and the fix must not be guessed at.
        print("  %s: ERROR no single anchor in %s (matched %d of %d spellings)"
              % (label, relpath, len(matched), len(variants)))
        return False

    f = io.open(path, "w", encoding="latin-1")
    f.write(src.replace(matched[0], new, 1))
    f.close()
    print("  %s: patched" % label)
    return True


def patch_tree(tree):
    ok = True
    for relpath, marker, variants, new, label in FIXES:
        ok = patch_file(tree, relpath, marker, variants, new, label) and ok
    return ok


def main():
    trees = sys.argv[1:]
    if not trees:
        print(__doc__)
        sys.exit(2)
    ok = True
    for tree in trees:
        print("== %s ==" % tree)
        ok = patch_tree(tree) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
