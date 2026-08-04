#!/usr/bin/env python
# -*- coding: utf-8 -*-
# The engine's bundled 3rdparty/libbacktrace (macho.c, the Mach-O fat-binary parser) calls
# __builtin_bswap32 / __builtin_bswap64 directly. Those became expandable compiler builtins in
# GCC 4.3; Apple's gcc-4.2 backported them, but gcc-4.0 (the compiler the 10.4u Tiger SDK pairs
# with) has NOT -- it emits them as unresolved libcalls, so libxash fails to link with
# "Undefined symbols: ___builtin_bswap32 / ___builtin_bswap64".
#
# Provide portable byte-swap replacements for pre-4.3 GCC and #define the builtin names to them
# (the preprocessor rewrites the calls before the compiler's builtin machinery is consulted, so
# no libcall is emitted). No-op on gcc-4.2/4.3+/clang, which keep their real builtins. Idempotent.
# Python 2.5+.
import sys

GUARD = 'oldmac: pre-4.3 GCC lacks __builtin_bswap'

ANCHOR = '#include "backtrace.h"\n#include "internal.h"\n'

BLOCK = (
	'#include "backtrace.h"\n'
	'#include "internal.h"\n'
	'\n'
	'#if defined(__GNUC__) && !defined(__clang__) && (__GNUC__ < 4 || (__GNUC__ == 4 && __GNUC_MINOR__ < 3))\n'
	'/* ' + GUARD + ' as expandable builtins (they become unresolved libcalls\n'
	' * on Apple gcc-4.0 for the 10.4u Tiger SDK). Provide portable replacements and route the\n'
	' * builtin spellings to them via the preprocessor. */\n'
	'#include <stdint.h>\n'
	'static inline uint32_t oldmac_bswap32( uint32_t x )\n'
	'{\n'
	'\treturn ( ( x & 0x000000FFu ) << 24 ) | ( ( x & 0x0000FF00u ) << 8 )\n'
	'\t     | ( ( x & 0x00FF0000u ) >> 8 )  | ( ( x & 0xFF000000u ) >> 24 );\n'
	'}\n'
	'static inline uint64_t oldmac_bswap64( uint64_t x )\n'
	'{\n'
	'\treturn ( (uint64_t) oldmac_bswap32( (uint32_t) x ) << 32 )\n'
	'\t     | (uint64_t) oldmac_bswap32( (uint32_t) ( x >> 32 ) );\n'
	'}\n'
	'#define __builtin_bswap32( x ) oldmac_bswap32( x )\n'
	'#define __builtin_bswap64( x ) oldmac_bswap64( x )\n'
	'#endif\n')

for f in sys.argv[1:]:
	s = open(f).read()
	if GUARD in s:
		print('already patched:', f)
		continue
	assert ANCHOR in s, ('anchor not found in ' + f)
	s = s.replace(ANCHOR, BLOCK, 1)
	open(f, 'w').write(s)
	print('patched:', f)
