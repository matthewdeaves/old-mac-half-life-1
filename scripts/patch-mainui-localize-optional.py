#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Treat an absent translation dictionary as absent, not as a fault (issue #20).
#
# Localize_InitLanguage asks for four dictionaries in turn: gameui, valve, mainui
# and the gamedir's own (MenuStrings.cpp:462-473). Any subset of them may
# legitimately not exist, and Localize_AddToDictionary printed the same
# unconditional warning for every one that did not:
#
#   Localize_AddToDict( resource/mainui_english.txt ): couldn't open file.
#   Some strings will not be localized!.
#
# After this project began shipping configs/gameui_english.txt, the two that
# remain are both absent BY DESIGN and neither has any user-visible consequence:
#
#   resource/mainui_english.txt  English is mainui's source language, so upstream
#                                ships only translation templates and no English
#                                file. Its keys are plain English and L() returns
#                                the key unchanged on a miss, so they render
#                                correctly with no dictionary at all.
#   resource/valve_english.txt   Retail Half-Life carries no resource/*_english.txt
#                                of any kind: valve/resource holds only
#                                GameUIScheme.res and pak0.pak has nothing under
#                                resource/. It is Valve's to ship, not ours, and
#                                this project ships no Valve content.
#
# So the message fired on every launch of every machine for a condition that is
# normal, expected and harmless. That is what made it worth changing: a line
# present on every launch is a line nobody reads on the day it means something.
#
# This is not a blanket downgrade. The function has SEVEN other Con_Printf calls,
# for a file that IS present but malformed: unsupported UTF-32, a bad header, a
# missing brace, a truncated token list. Those indicate a real fault in a real
# file and all keep their warning. Only the "file is not there" case moves, so
# the distinction the code was missing is now made: optional and absent, versus
# present and broken.
#
# Con_DPrintf keeps it available under -dev 1, and is already the idiom in mainui
# for exactly this class of thing (CFGScript.cpp:57,238,289,293,334 and
# controls/ItemsHolder.cpp:573,615).
#
# Applies to mainui in both trees. Idempotent. Python 2.5+.
import os
import sys

MARKER = 'oldmac: optional dictionary, absent is normal'

ANCHOR = (
	'\tif( !pFileBuf )\n'
	'\t{\n'
	'\t\tCon_Printf( "Localize_AddToDict( %s ): couldn\'t open file. '
	'Some strings will not be localized!.\\n", filename );\n'
	'\t\treturn;\n'
	'\t}\n'
)

NEW = (
	'\tif( !pFileBuf )\n'
	'\t{\n'
	'\t\t// ' + MARKER + '. Callers ask for four\n'
	'\t\t// dictionaries and any of them may legitimately not exist; L() returns\n'
	'\t\t// the key itself on a miss, so English keys still render. The malformed\n'
	'\t\t// cases below stay warnings, because those are real faults.\n'
	'\t\tCon_DPrintf( "Localize_AddToDict( %s ): no dictionary, using untranslated '
	'strings\\n", filename );\n'
	'\t\treturn;\n'
	'\t}\n'
)


def patch(path):
	s = open(path).read()
	if MARKER in s:
		print('already patched: ' + path)
		return
	n = s.count(ANCHOR)
	assert n == 1, ('anchor found %d times (want 1) in %s' % (n, path))
	s = s.replace(ANCHOR, NEW, 1)
	open(path, 'w').write(s)
	print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-localize-optional.py <mainui-dir-or-MenuStrings.cpp> ...')
		return 1
	for arg in sys.argv[1:]:
		if os.path.isdir(arg):
			patch(os.path.join(arg, 'MenuStrings.cpp'))
		else:
			patch(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
