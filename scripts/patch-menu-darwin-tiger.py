#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Two Tiger/Panther (pre-10.5 SDK) fixes for engine/platform/darwin/menu_darwin.m. Both are
# guarded so they are exact no-ops on the 10.5 Leopard build (which already compiles this file):
#
# 1) S_ERROR macro vs OpenTransport collision. The engine's com_strings.h does
#    `#define S_ERROR S_RED "Error: " S_DEFAULT`. On the 10.4u SDK, <AppKit/AppKit.h> pulls
#    Foundation -> CoreServices -> OSServices -> OpenTransportProtocol.h, whose enum has an
#    `S_ERROR = 0x0100` member; the macro rewrites it to a string constant, giving
#    "syntax error before string constant" at OpenTransportProtocol.h:720. We never use
#    OpenTransport, so we pre-define that header's include guard (__OPENTRANSPORTPROTOCOL__)
#    before including AppKit, suppressing the legacy header. Harmless on 10.5+ (not pulled there).
#
# 2) IOPMAssertion power API is 10.5+. IOPMAssertionID / kIOPMNullAssertionID / IOPMAssertionCreate
#    / kIOPMAssertionLevelOn do not exist in the 10.4u SDK. They only drive a "don't sleep the
#    display while playing" nicety, so guard them behind MAC_OS_X_VERSION_MAX_ALLOWED >= 1050;
#    on Tiger the two Darwin_*PowerAssertion functions become no-op stubs (symbols preserved for
#    their callers). MAC_OS_X_VERSION_MAX_ALLOWED equals the SDK version (1040 on 10.4u, 1050 on 10.5).
# Idempotent. Python 2.5+.
import sys

MARK = 'oldmac: IOPMAssertion power API is 10.5+'

# --- fix 1: suppress OpenTransportProtocol.h before AppKit ---
OT_OLD = '#include <AppKit/AppKit.h>\n'
OT_NEW = (
	'/* oldmac: com_strings.h #defines S_ERROR; on the 10.4u SDK AppKit pulls\n'
	' * OSServices/OpenTransportProtocol.h whose enum has an S_ERROR member, so the macro\n'
	' * turns it into a string constant ("syntax error before string constant"). We do not\n'
	' * use OpenTransport -- pre-define its include guard to skip that legacy header. */\n'
	'#ifndef __OPENTRANSPORTPROTOCOL__\n'
	'#define __OPENTRANSPORTPROTOCOL__\n'
	'#endif\n'
	'#include <AppKit/AppKit.h>\n')

# --- fix 2a: guard the assertion-id storage ---
VAR_OLD = 'static IOPMAssertionID s_powerAssertion = kIOPMNullAssertionID;\n'
VAR_NEW = (
	'#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1050 /* ' + MARK + ' */\n'
	'static IOPMAssertionID s_powerAssertion = kIOPMNullAssertionID;\n'
	'#endif\n')

# --- fix 2b: guard the two function bodies (keep the symbols) ---
ACQ_OLD = (
	'void Darwin_AcquirePowerAssertion( void )\n'
	'{\n'
	'\tif( s_powerAssertion != kIOPMNullAssertionID )\n')
ACQ_NEW = (
	'void Darwin_AcquirePowerAssertion( void )\n'
	'{\n'
	'#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1050 /* ' + MARK + ' */\n'
	'\tif( s_powerAssertion != kIOPMNullAssertionID )\n')

ACQ_END_OLD = (
	'\t\ts_powerAssertion = kIOPMNullAssertionID;\n'
	'}\n'
	'\n'
	'void Darwin_ReleasePowerAssertion( void )\n'
	'{\n'
	'\tif( s_powerAssertion == kIOPMNullAssertionID )\n')
ACQ_END_NEW = (
	'\t\ts_powerAssertion = kIOPMNullAssertionID;\n'
	'#endif\n'
	'}\n'
	'\n'
	'void Darwin_ReleasePowerAssertion( void )\n'
	'{\n'
	'#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1050 /* ' + MARK + ' */\n'
	'\tif( s_powerAssertion == kIOPMNullAssertionID )\n')

REL_END_OLD = (
	'\tIOPMAssertionRelease( s_powerAssertion );\n'
	'\ts_powerAssertion = kIOPMNullAssertionID;\n'
	'}\n')
REL_END_NEW = (
	'\tIOPMAssertionRelease( s_powerAssertion );\n'
	'\ts_powerAssertion = kIOPMNullAssertionID;\n'
	'#endif\n'
	'}\n')

SUBS = [(OT_OLD, OT_NEW), (VAR_OLD, VAR_NEW),
        (ACQ_OLD, ACQ_NEW), (ACQ_END_OLD, ACQ_END_NEW), (REL_END_OLD, REL_END_NEW)]

for f in sys.argv[1:]:
	s = open(f).read()
	if MARK in s:
		print('already patched:', f)
		continue
	for old, new in SUBS:
		assert old in s, ('anchor not found (%r...) in %s' % (old[:40], f))
		s = s.replace(old, new, 1)
	open(f, 'w').write(s)
	print('patched:', f)
