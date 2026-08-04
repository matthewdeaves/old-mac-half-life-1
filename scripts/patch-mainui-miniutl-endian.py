#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Give miniutl an endianness it can work out on Apple's PowerPC compilers (issue #36).
#
# mainui's miniutl submodule decides byte order in miniutl/minbase_endian.h. When the
# platform has not already provided __BYTE_ORDER / __LITTLE_ENDIAN / __BIG_ENDIAN it
# tries exactly one fallback and then gives up:
#
#   #if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__) && ...
#       #define __BYTE_ORDER __BYTE_ORDER__
#       ...
#   #else
#       #error
#   #endif
#
# __BYTE_ORDER__ arrived in GCC 4.3. The PowerPC slices are built with Apple's gcc-4.0
# (Panther and Tiger drivers) and gcc-4.2, neither of which defines it, and Darwin does
# not define the bare __BYTE_ORDER either. What Apple's compilers DO define, and have
# since the beginning, is the single flag __BIG_ENDIAN__ (or __LITTLE_ENDIAN__).
#
# So the bare #error fires and miniutl/generichash.cpp and miniutl/bitstring.cpp fail to
# compile, which takes the menu library with them. Verified on the Lion mini against the
# pinned tree: with the stock header both fail at minbase_endian.h:86, with this block
# both compile. Map the legacy flags onto the __BYTE_ORDER triple the rest of the header
# already tests.
#
# The block is a no-op wherever __BYTE_ORDER__ exists, so clang and modern GCC take the
# upstream path untouched; it is wired into the two PowerPC drivers only.
#
# This edit lived only in the working trees on the two build minis until #36. It is a
# patch script rather than a patches/vendor/*.diff because the drivers must re-assert it
# on every build (the hand-edit diffs are applied once, by bootstrap-vendor.sh, and are
# skipped for a tree that already exists), and because it sits inside miniutl, a submodule
# of the mainui submodule, which `git apply` in the mainui tree cannot reach.
#
# Applies to mainui in the PowerPC tree. Idempotent. Python 2.5+.
import os
import sys

MARKER = 'oldmac: Apple gcc-4.2 predates __BYTE_ORDER__'

ANCHOR = (
	'\t\t#define __BIG_ENDIAN __ORDER_BIG_ENDIAN__\n'
	'\t#else\n'
	'\t\t#error\n'
	'\t#endif\n'
)

BLOCK = (
	'\t\t#define __BIG_ENDIAN __ORDER_BIG_ENDIAN__\n'
	'\t// ' + MARKER + ' (added in gcc 4.3) but defines\n'
	'\t// the legacy __BIG_ENDIAN__/__LITTLE_ENDIAN__ single flags. Map those instead.\n'
	'\t#elif defined(__BIG_ENDIAN__)\n'
	'\t\t#define __LITTLE_ENDIAN 1234\n'
	'\t\t#define __BIG_ENDIAN 4321\n'
	'\t\t#define __BYTE_ORDER __BIG_ENDIAN\n'
	'\t#elif defined(__LITTLE_ENDIAN__)\n'
	'\t\t#define __LITTLE_ENDIAN 1234\n'
	'\t\t#define __BIG_ENDIAN 4321\n'
	'\t\t#define __BYTE_ORDER __LITTLE_ENDIAN\n'
	'\t#else\n'
	'\t\t#error\n'
	'\t#endif\n'
)


def patch(path):
	s = open(path).read()
	if MARKER in s:
		print('already patched: ' + path)
		return
	n = s.count(ANCHOR)
	assert n == 1, ('anchor found %d times (want 1) in %s' % (n, path))
	open(path, 'w').write(s.replace(ANCHOR, BLOCK, 1))
	print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-miniutl-endian.py <mainui-dir-or-minbase_endian.h> ...')
		return 1
	for arg in sys.argv[1:]:
		if os.path.isdir(arg):
			patch(os.path.join(arg, 'miniutl', 'minbase_endian.h'))
		else:
			patch(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
