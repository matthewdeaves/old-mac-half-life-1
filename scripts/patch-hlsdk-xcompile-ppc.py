#!/usr/bin/env python
# -*- coding: utf-8 -*-
# The hlsdk-portable waf (scripts/waifulib/xcompile.py) lacks the DEST_CPU fix the engine tree
# already carries. Cross-building the PowerPC slice on the Intel Lion host, waf probes DEST_CPU
# with the *bare* compiler (no '-arch ppc', which lives in CFLAGS/CXXFLAGS) and mis-detects x86.
# compiler_optimizations.py then appends -march=pentium-m / -mtune=core2 for BUILD_TYPE builds,
# which the ppc cc1 rejects ("invalid option 'arch=pentium-m'") -> "Checking for required C flags:
# no" -> configure fails. Port the engine's oldmac_fixup_dest_cpu: force DEST_CPU='ppc' in both
# post_compiler_(c|cxx)_configure so the x86 opt flags are never chosen. Idempotent. Python 2.5+.
import sys

GUARD = 'oldmac_fixup_dest_cpu'

FIXDEF = (
	'def oldmac_fixup_dest_cpu(conf):\n'
	'\t# oldmac: cross-building the PowerPC slice on an Intel host -- waf probes DEST_CPU with\n'
	'\t# the bare compiler and never sees our \'-arch ppc\' (it lives in CFLAGS/CXXFLAGS), so it\n'
	'\t# mis-detects x86 and compiler_optimizations.py then appends -march=pentium-m/-mtune=core2,\n'
	'\t# which the ppc cc1 rejects. Force ppc so those x86 opt flags are never chosen.\n'
	'\tallflags = \' \'.join(conf.env.CFLAGS + conf.env.CXXFLAGS)\n'
	'\tif conf.env.DEST_OS == \'darwin\' and \'-arch ppc\' in allflags and conf.env.DEST_CPU != \'ppc\':\n'
	'\t\tconf.env.DEST_CPU = \'ppc\'\n'
	'\n')

CXX_OLD = 'def post_compiler_cxx_configure(conf):\n\tconf.msg(\'Target OS\', conf.env.DEST_OS)\n'
CXX_NEW = FIXDEF + 'def post_compiler_cxx_configure(conf):\n\toldmac_fixup_dest_cpu(conf)\n\tconf.msg(\'Target OS\', conf.env.DEST_OS)\n'

C_OLD = 'def post_compiler_c_configure(conf):\n\tconf.msg(\'Target OS\', conf.env.DEST_OS)\n'
C_NEW = 'def post_compiler_c_configure(conf):\n\toldmac_fixup_dest_cpu(conf)\n\tconf.msg(\'Target OS\', conf.env.DEST_OS)\n'

for f in sys.argv[1:]:
	s = open(f).read()
	if GUARD in s:
		print('already patched:', f)
		continue
	assert CXX_OLD in s, ('cxx anchor not found in ' + f)
	assert C_OLD in s, ('c anchor not found in ' + f)
	s = s.replace(CXX_OLD, CXX_NEW, 1).replace(C_OLD, C_NEW, 1)
	open(f, 'w').write(s)
	print('patched:', f)
