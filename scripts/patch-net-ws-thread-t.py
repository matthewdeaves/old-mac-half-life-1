#!/usr/bin/env python
# -*- coding: utf-8 -*-
# engine/common/net_ws.c defines a file-local `thread_t` (an SDL_Thread*/pthread_t/HANDLE wrapper
# for its DNS-resolver thread). Under the 10.3.9 Panther SDK, the threading headers transitively
# pull <mach/mach_types.h>, which typedefs `thread_t` as mach_port_t -> "conflicting types for
# 'thread_t'". (The 10.4u/10.5 SDKs don't surface mach's thread_t here, so this only bites Panther.)
# The typedef is local to net_ws.c and never referenced by name outside it, so rename it to
# net_thread_t everywhere in this file. Whole-word, idempotent. Python 2.5+.
import sys, re

WORD = re.compile(r'\bthread_t\b')

for f in sys.argv[1:]:
	s = open(f).read()
	if 'net_thread_t' in s:
		print('already patched:', f)
		continue
	n = len(WORD.findall(s))
	assert n > 0, ('thread_t not found in ' + f)
	s = WORD.sub('net_thread_t', s)
	open(f, 'w').write(s)
	print('patched (%d occurrences):' % n, f)
