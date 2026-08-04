#!/usr/bin/env python
# -*- coding: utf-8 -*-
# panther-sdl2 (SDL 2.0.3) gates its 10.5-era code with `#if [!]defined(MAC_OS_X_VERSION_10_5)`.
# That test assumes a *native* Panther/Tiger toolchain whose headers don't know the symbol.
# We CROSS-compile on Lion against the 10.3.9 / 10.4u SDK, and those SDKs' AvailabilityMacros.h
# DO define MAC_OS_X_VERSION_10_5 (as the constant 1050) even though we deploy lower. So:
#   * `#if !defined(MAC_OS_X_VERSION_10_5)`  (provides CGFloat/NSInteger compat typedefs)
#        wrongly evaluates false -> the typedefs vanish -> "syntax error before 'CGFloat'".
#   * `#if defined(MAC_OS_X_VERSION_10_5)`   (gates 10.5-only TIS / NSWindow APIs, e.g.
#        TISInputSourceRef, setCollectionBehavior) wrongly evaluates true -> it tries to
#        compile 10.5 symbols absent from the 10.4u SDK -> "TISInputSourceRef undeclared".
# The deployment-agnostic tests use MAC_OS_X_VERSION_MAX_ALLOWED (defined by every SDK back to
# 10.2, equal to the SDK version). We DON'T touch the `defined(__ALTIVEC__) && ...` variants:
# we don't build with -maltivec, so __ALTIVEC__ is undefined and those blocks are already inert.
# Idempotent. Python 2.5+.
import sys

MARK = 'oldmac: cross-SDK version guard'
SUBS = [
	# provide-compat-typedefs form: enable when SDK is older than 10.5
	('#if !defined(MAC_OS_X_VERSION_10_5)\n',
	 '#if MAC_OS_X_VERSION_MAX_ALLOWED < 1050 /* ' + MARK + ' */\n'),
	# gate-10.5-only-API form: enable only when the SDK actually has 10.5 symbols
	('#if defined(MAC_OS_X_VERSION_10_5)\n',
	 '#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1050 /* ' + MARK + ' */\n'),
]

for f in sys.argv[1:]:
	s = open(f).read()
	n = 0
	for old, new in SUBS:
		c = s.count(old)
		if c:
			s = s.replace(old, new)
			n += c
	if n:
		open(f, 'w').write(s)
		print('patched (%d guard(s)):' % n, f)
	elif MARK in s:
		print('already patched:', f)
	else:
		print('no plain 10_5 guard (ok):', f)
