#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Stop the Custom Game list claiming a mod is 0.0 Mb (issue #27).
#
# CMenuModListModel::Update in menus/CustomGame.cpp:
#
#   mod.bytes = gi->size;
#   if( gi->size > 0 )
#       Q_strncpy( mod.size, Q_memprint( gi->size ), sizeof( mod.size ));
#   else Q_strncpy( mod.size, "0.0 Mb", sizeof( mod.size ));
#
# `size` is an OPTIONAL field in liblist.gam, and plenty of mods omit it. Seen on
# a G5 running the shipped v1.4.2: poke646 declares size "123055258" and lists
# correctly at 117.35, while vendetta and induction declare no size at all and
# both list as "0.0 Mb" for mods that are hundreds of megabytes on disk.
#
# Stating a wrong number is worse than stating none: a reader has no way to tell
# a genuinely empty mod from one whose author left the field out, and 0.0 looks
# like a broken install. An empty cell reads as "not stated", which is what it is.
#
# Computing the real size was considered and rejected. It means walking the whole
# mod directory for every entry every time the list is built, and this menu is
# built on a G3 with a 5400rpm disk. The engine does not cache it, so it would be
# paid on every visit to Custom Game.
#
# Applies to mainui in both trees. Idempotent. Python 2.5+.
import os
import re
import sys

MARKER = 'oldmac: size is optional in liblist.gam'

RE_SITE = re.compile(
	r'([ \t]*)else Q_strncpy\( mod\.size, "0\.0 Mb", sizeof\( mod\.size \)\);'
)


def replacement(m):
	i = m.group(1)
	return (
		'%selse\n'
		'%s{\n'
		'%s\t// %s, and many mods omit it. Showing\n'
		'%s\t// "0.0 Mb" for a mod that is hundreds of megabytes reads as a broken\n'
		'%s\t// install. An empty cell reads as "not stated", which is the truth.\n'
		'%s\tmod.size[0] = 0;\n'
		'%s}' % (i, i, i, MARKER, i, i, i, i)
	)


def patch(path):
	s = open(path).read()
	if MARKER in s:
		print('already patched: ' + path)
		return
	n = len(RE_SITE.findall(s))
	assert n == 1, ('anchor found %d times (want 1) in %s' % (n, path))
	open(path, 'w').write(RE_SITE.sub(replacement, s, 1))
	print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-modsize.py <mainui-dir-or-CustomGame.cpp> ...')
		return 1
	for arg in sys.argv[1:]:
		if os.path.isdir(arg):
			patch(os.path.join(arg, 'menus', 'CustomGame.cpp'))
		else:
			patch(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
