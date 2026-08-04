#!/usr/bin/env python
# -*- coding: utf-8 -*-
# panther-sdl2 (SDL 2.0.3) builds its Cocoa display list with Cocoa_GetDisplayName(),
# which calls IODisplayCreateInfoDictionary(..., kIODisplayOnlyPreferredName). That
# constant (and the IODisplay* info-dictionary API it uses) only appears in the 10.4u
# SDK and later -- the 10.3.9 cross-SDK on the build box does NOT declare it, so the
# file fails to compile when we target Panther. The returned string is purely cosmetic
# (surfaced through SDL_GetDisplayName, which Half-Life never uses), so on a pre-10.4
# deployment target we just return NULL. Idempotent. Python 2.5+.
import sys

GUARD = 'oldmac: kIODisplayOnlyPreferredName is 10.4+'

OLD = (
	'Cocoa_GetDisplayName(CGDirectDisplayID displayID)\n'
	'{\n'
	'    NSDictionary *deviceInfo = (NSDictionary *)IODisplayCreateInfoDictionary(CGDisplayIOServicePort(displayID), kIODisplayOnlyPreferredName);\n')

NEW = (
	'Cocoa_GetDisplayName(CGDirectDisplayID displayID)\n'
	'{\n'
	'#if MAC_OS_X_VERSION_MIN_REQUIRED < 1040\n'
	'    /* ' + GUARD + ': the IODisplayCreateInfoDictionary info-name API and this\n'
	'     * constant are absent from the 10.3.9 SDK. The name is cosmetic (SDL_GetDisplayName\n'
	'     * only, unused by Half-Life), so return NULL on a Panther-targeted build. */\n'
	'    (void)displayID;\n'
	'    return NULL;\n'
	'#else\n'
	'    NSDictionary *deviceInfo = (NSDictionary *)IODisplayCreateInfoDictionary(CGDisplayIOServicePort(displayID), kIODisplayOnlyPreferredName);\n')

# close the #else with #endif just before the function's closing brace
OLD_TAIL = (
	'    [deviceInfo release];\n'
	'    return displayName;\n'
	'}\n')
NEW_TAIL = (
	'    [deviceInfo release];\n'
	'    return displayName;\n'
	'#endif\n'
	'}\n')

for f in sys.argv[1:]:
	s = open(f).read()
	if GUARD in s:
		print('already patched:', f)
		continue
	assert OLD in s, ('head anchor not found in ' + f)
	assert OLD_TAIL in s, ('tail anchor not found in ' + f)
	s = s.replace(OLD, NEW, 1).replace(OLD_TAIL, NEW_TAIL, 1)
	open(f, 'w').write(s)
	print('patched:', f)
