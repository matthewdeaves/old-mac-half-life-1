#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Make the crash handler produce a usable backtrace (issue #21, finding 2).
#
# Five fixes. Two are PowerPC-only and are skipped when their anchor is absent,
# because the Intel tree already has them right. Three apply to both trees.
#
# WHAT THE SYMPTOM WAS, AND WHAT IT TURNED OUT TO BE
#
# The reported symptom was PowerPC-only, on every launch of the G3 and G4 slices:
#   Error: libbacktrace error: backtrace library does not support threads (0)
# Fixing that alone was not enough. With libbacktrace running, a forced SIGSEGV
# produced fourteen lines of "no debug info in Mach-O executable" and not one
# stack frame. Running the same test on Intel, which never had the threads
# error, produced the same fourteen lines. So the crash handler produced no
# usable backtrace on ANY slice, and the PowerPC fault was hiding a defect that
# was never architecture-specific.
#
# 1. libbacktrace refused to start at all (PowerPC only)
#
#    Sys_SetupLibbacktrace passed threaded = true. libbacktrace rejects that
#    unless HAVE_SYNC_FUNCTIONS was defined at configure time, and returns NULL
#    (3rdparty/libbacktrace/libbacktrace/state.c:53-59). That probe compiles a
#    __sync_bool_compare_and_swap fragment, which gcc-4.0 cannot build, so the
#    slices that build C with gcc-4.0 never get the macro. Both shipped PowerPC
#    slices do, so this affected the G3, the G4 and the G5 alike, not just the
#    two named in the issue, which was written when the G5 still had a gcc-4.2
#    slice of its own.
#
#    threaded = false is the accurate value here rather than a concession:
#    g_bt_state is written once at startup (crash_posix.c, before the sigaction
#    calls) and thereafter only read, from a fatal signal handler. What threaded
#    guards is concurrent use of the state's lazily built caches, which this
#    never does. Ask for threaded first and retry unthreaded only if refused, so
#    builds that do have the sync functions are unaffected.
#
# 2. A pointer-sized buffer length in the crash handler (PowerPC only)
#
#    .message_size = sizeof( message ) - len, where message is a char *. sizeof
#    is the POINTER size, 4 on ppc32. For any len above 4 that underflows a
#    size_t to about 4 GB, and Q_vsnprintf is handed an effectively unbounded
#    limit into an 8 KB stack buffer. A stack smash while already handling
#    SIGSEGV. max_len is the real size, was already a parameter, and was unused.
#
# 3, 4 and 5. No frames, on every slice
#
#    backtrace_full only calls its frame callback for frames it can describe from
#    DWARF. These builds carry no -g and no dSYM, so libbacktrace has nothing to
#    read, calls the ERROR callback once per frame, and the frame callback never
#    runs. Every frame became an identical error line.
#
#    The unwinder itself was working the whole time: fourteen errors means
#    fourteen frames were walked. Only symbolisation failed. So use
#    backtrace_simple, which reports every program counter regardless of debug
#    info, and symbolise each one with dladdr, which needs no debug info at all.
#    backtrace_pcinfo is still tried first, so a build made with -g still gets
#    file and line.
#
#    dladdr gives the nearest EXPORTED symbol, so it names the neighbourhood
#    rather than the exact static function. The module plus its load offset is
#    the part that matters: that is what atos takes to resolve an address
#    exactly, against a build of the same commit.
#
#    Fix 4 also removes a real defect on the old path: when there was no debug
#    info, Sys_BacktracePrintFull called backtrace_syminfo with
#    Sys_BacktraceError, the STARTUP error callback, which sets
#    enable_libbacktrace = false. A missing symbol partway through a trace
#    therefore disabled the whole facility.
#
# Applies to both engine trees. Idempotent. Python 2.5+.
import os
import re
import sys

MARKER_SIZE = 'oldmac: max_len, not sizeof( message )'
MARKER_THREAD = 'oldmac: retry unthreaded'
MARKER_DLADDR = 'oldmac: dladdr needs no debug info'
MARKER_NOSYMINFO = 'oldmac: no backtrace_syminfo here'
MARKER_SIMPLE = 'oldmac: every frame, with or without debug info'
MARKER_APPEND = 'oldmac: the format strings already end in a newline'

# ---- 6. PowerPC only: double-spaced frames, and a write to fd -1 -----------
#
# Sys_AppendPrint wrote a second '\n' after text whose format string already
# ended in one, so every crash report was double spaced. It also wrote to
# pd->logfd unconditionally, and Sys_LogFileNo() returns -1 when there is no log
# file. The Intel tree has both of these right; this brings the PowerPC copy
# into line rather than inventing anything.

ANCHOR_APPEND = (
	'\tif( len > 0 )\n'
	'\t{\n'
	'\t\tchar ch = \'\\n\';\n'
	'\n'
	'\t\twrite( pd->logfd, pd->message, len );\n'
	'\t\twrite( pd->logfd, &ch, 1 );\n'
	'\n'
	'\t\twrite( STDERR_FILENO, pd->message, len );\n'
	'\t\twrite( STDERR_FILENO, &ch, 1 );\n'
)
NEW_APPEND = (
	'\tif( len > 0 )\n'
	'\t{\n'
	'\t\t// ' + MARKER_APPEND + ', so a second one\n'
	'\t\t// double spaced every crash report. Sys_LogFileNo() also returns -1\n'
	'\t\t// when there is no log file, which this wrote to regardless.\n'
	'\t\tif( pd->logfd >= 0 )\n'
	'\t\t\twrite( pd->logfd, pd->message, len );\n'
	'\n'
	'\t\twrite( STDERR_FILENO, pd->message, len );\n'
)

# ---- 1. PowerPC only: pointer-sized buffer length --------------------------

ANCHOR_SIZE = '\t\t.message_size = sizeof( message ) - len,\n'
NEW_SIZE = (
	'\t\t// ' + MARKER_SIZE + ': message is a char *, so sizeof is the\n'
	'\t\t// pointer size and the subtraction underflowed size_t for len > 4.\n'
	'\t\t.message_size = max_len - len,\n'
)

# ---- 2. PowerPC only: libbacktrace refuses threaded mode -------------------

ANCHOR_THREAD = (
	'qboolean Sys_SetupLibbacktrace( const char *argv0 )\n'
	'{\n'
	'\tenable_libbacktrace = true;\n'
	'\tg_bt_state = backtrace_create_state( argv0, true, Sys_BacktraceError, NULL );\n'
	'\treturn g_bt_state != NULL && enable_libbacktrace;\n'
	'}\n'
)

NEW_THREAD = (
	'// ' + MARKER_THREAD + ': libbacktrace refuses threaded mode unless it was\n'
	'// configured with HAVE_SYNC_FUNCTIONS, which the gcc-4.0 slices never get\n'
	'// because gcc-4.0 has no __sync builtins. Swallow that first refusal so the\n'
	'// retry is not announced; a real failure is still reported by the second.\n'
	'static void Sys_BacktraceErrorQuiet( void *data, const char *msg, int errnum )\n'
	'{\n'
	'}\n'
	'\n'
	'qboolean Sys_SetupLibbacktrace( const char *argv0 )\n'
	'{\n'
	'\tenable_libbacktrace = true;\n'
	'\tg_bt_state = backtrace_create_state( argv0, true, Sys_BacktraceErrorQuiet, NULL );\n'
	'\n'
	'\tif( g_bt_state == NULL )\n'
	'\t{\n'
	'\t\t// The state is written once here at startup and thereafter only read,\n'
	'\t\t// from a fatal signal handler, so it is never used from two threads at\n'
	'\t\t// once and unthreaded is the accurate answer rather than a concession.\n'
	'\t\tenable_libbacktrace = true;\n'
	'\t\tg_bt_state = backtrace_create_state( argv0, false, Sys_BacktraceError, NULL );\n'
	'\t}\n'
	'\n'
	'\treturn g_bt_state != NULL && enable_libbacktrace;\n'
	'}\n'
)

# ---- 3. Both trees: symbolise the no-symbol case with dladdr ---------------
# This is the tail of Sys_BacktracePrintSyminfo, identical in both trees.

ANCHOR_DLADDR = (
	'\telse\n'
	'\t{\n'
	'\t\tif( module_name )\n'
	'\t\t\tSys_AppendPrint( pd, "%2d: %p (%s)\\n", pd->idx++, pc, module_name );\n'
	'\t\telse\n'
	'\t\t\tSys_AppendPrint( pd, "%2d: %p\\n", pd->idx++, pc );\n'
	'\t}\n'
)

NEW_DLADDR = (
	'\telse\n'
	'\t{\n'
	'\t\t// ' + MARKER_DLADDR + ', which is the whole point: these\n'
	'\t\t// builds carry no -g and no dSYM, so this is the path every frame\n'
	'\t\t// takes. Print the module and the offset INTO it, because that pair is\n'
	'\t\t// what atos resolves exactly against a build of the same commit. The\n'
	'\t\t// symbol is the nearest exported one, so it names the neighbourhood\n'
	'\t\t// rather than the exact static function.\n'
	'\t\tif( module_name )\n'
	'\t\t{\n'
	'\t\t\tconst char *base = COM_FileWithoutPath( module_name );\n'
	'\t\t\tunsigned long off = (unsigned long)( pc - (uintptr_t)dlinfo.dli_fbase );\n'
	'\n'
	'\t\t\tif( dlinfo.dli_sname )\n'
	'\t\t\t\tSys_AppendPrint( pd, "%2d: %s+0x%lx <%s+%ld> [%p]\\n", pd->idx++,\n'
	'\t\t\t\t\tbase, off, dlinfo.dli_sname,\n'
	'\t\t\t\t\t(long)( pc - (uintptr_t)dlinfo.dli_saddr ), (void *)pc );\n'
	'\t\t\telse\n'
	'\t\t\t\tSys_AppendPrint( pd, "%2d: %s+0x%lx [%p]\\n", pd->idx++, base, off,\n'
	'\t\t\t\t\t(void *)pc );\n'
	'\t\t}\n'
	'\t\telse\n'
	'\t\t{\n'
	'\t\t\tSys_AppendPrint( pd, "%2d: %p\\n", pd->idx++, (void *)pc );\n'
	'\t\t}\n'
	'\t}\n'
)

# ---- 4. Both trees: stop disabling libbacktrace from inside a trace --------

ANCHOR_NOSYMINFO = (
	'\t\tbacktrace_syminfo( g_bt_state, pc, Sys_BacktracePrintSyminfo, '
	'Sys_BacktraceError, data );\n'
)
NEW_NOSYMINFO = (
	'\t\t// ' + MARKER_NOSYMINFO + ': it failed on every frame of these\n'
	'\t\t// stripped builds, and it was handed Sys_BacktraceError, the STARTUP\n'
	'\t\t// callback, which sets enable_libbacktrace = false. One unsymbolised\n'
	'\t\t// frame therefore switched off the whole facility mid-trace. Go\n'
	'\t\t// straight to the dladdr path instead.\n'
	'\t\tSys_BacktracePrintSyminfo( data, pc, NULL, 0, 0 );\n'
)

# ---- 5. Both trees: walk every frame, not only the described ones ----------

RE_FULL = re.compile(
	r'\tbacktrace_full\( g_bt_state, (\d+), Sys_BacktracePrintFull, '
	r'Sys_BacktracePrintError, &pd \);\n'
)

NEW_SIMPLE_HELPER = (
	'// ' + MARKER_SIMPLE + '. backtrace_full calls its frame\n'
	'// callback only for frames it can describe from DWARF, and these builds have\n'
	'// none, so it reported one error per frame and never called it at all. The\n'
	'// unwinder was working throughout; only symbolisation failed.\n'
	'// backtrace_simple hands us every program counter, and each is then resolved\n'
	'// by debug info if there is any and by dladdr if there is not.\n'
	'static int Sys_BacktraceFrame( void *data, uintptr_t pc )\n'
	'{\n'
	'\tstruct print_data *pd = data;\n'
	'\tint before = pd->idx;\n'
	'\n'
	'\tbacktrace_pcinfo( g_bt_state, pc, Sys_BacktracePrintFull,\n'
	'\t\tSys_BacktraceErrorSilent, data );\n'
	'\n'
	'\tif( pd->idx == before )\n'
	'\t\tSys_BacktracePrintSyminfo( data, pc, NULL, 0, 0 );\n'
	'\n'
	'\treturn 0;\n'
	'}\n'
	'\n'
	'int Sys_CrashDetailsLibbacktrace('
)

SILENT_CB = (
	'// Frame-level failures are expected on a stripped build and are handled by\n'
	'// falling back to dladdr, so they are not worth a line each.\n'
	'static void Sys_BacktraceErrorSilent( void *data, const char *msg, int errnum )\n'
	'{\n'
	'}\n'
	'\n'
	'static int Sys_BacktracePrintFull('
)


def apply_literal(s, marker, anchor, new, what, optional=False):
	if marker in s:
		print('    already patched (%s)' % what)
		return s, True
	n = s.count(anchor)
	if n == 0 and optional:
		print('    not applicable (%s)' % what)
		return s, True
	if n != 1:
		print('    ERROR: %s anchor found %d times (want 1)' % (what, n))
		return s, False
	print('    patched (%s)' % what)
	return s.replace(anchor, new, 1), True


def patch(path):
	print('  ' + path)
	s = open(path).read()
	orig = s
	ok = True

	s, r = apply_literal(s, MARKER_SIZE, ANCHOR_SIZE, NEW_SIZE,
	                     'buffer size', optional=True); ok = ok and r
	s, r = apply_literal(s, MARKER_THREAD, ANCHOR_THREAD, NEW_THREAD,
	                     'threaded retry', optional=True); ok = ok and r
	s, r = apply_literal(s, MARKER_APPEND, ANCHOR_APPEND, NEW_APPEND,
	                     'newline and logfd guard', optional=True); ok = ok and r
	s, r = apply_literal(s, MARKER_DLADDR, ANCHOR_DLADDR, NEW_DLADDR,
	                     'dladdr symbolisation'); ok = ok and r
	s, r = apply_literal(s, MARKER_NOSYMINFO, ANCHOR_NOSYMINFO, NEW_NOSYMINFO,
	                     'no syminfo mid-trace'); ok = ok and r

	# 5. the silent callback, then the frame wrapper, then the call site.
	if MARKER_SIMPLE not in s:
		anchor = 'static int Sys_BacktracePrintFull('
		if s.count(anchor) != 1:
			print('    ERROR: PrintFull declaration not found exactly once')
			ok = False
		else:
			s = s.replace(anchor, SILENT_CB, 1)
			anchor = 'int Sys_CrashDetailsLibbacktrace('
			if s.count(anchor) != 1:
				print('    ERROR: CrashDetails definition not found exactly once')
				ok = False
			else:
				s = s.replace(anchor, NEW_SIMPLE_HELPER, 1)
				m = RE_FULL.search(s)
				if m is None:
					print('    ERROR: backtrace_full call site not found')
					ok = False
				else:
					s = RE_FULL.sub(
						'\t// dladdr is NOT async-signal-safe: it takes the dyld lock\n'
						'\t// and can allocate. Reaching it is the price of a symbolised\n'
						'\t// trace on a stripped build, but a fault taken inside dyld or\n'
						'\t// malloc could deadlock here, and a crash handler that hangs\n'
						'\t// is worse than one that says little. Cap it. SIGALRM\'s\n'
						'\t// default action ends the process, so the worst case becomes a\n'
						'\t// five second wait rather than a permanent stall, and alarm()\n'
						'\t// itself is async-signal-safe.\n'
						'\talarm( 5 );\n'
						'\n'
						'\tbacktrace_simple( g_bt_state, %s, Sys_BacktraceFrame,\n'
						'\t\tSys_BacktracePrintError, &pd );\n'
						'\n'
						'\talarm( 0 );\n' % m.group(1), s, 1)
					print('    patched (backtrace_simple, skip %s)' % m.group(1))
	else:
		print('    already patched (backtrace_simple)')

	if not ok:
		return False
	if s != orig:
		open(path, 'w').write(s)
	return True


def main():
	if len(sys.argv) < 2:
		print('usage: patch-crash-libbacktrace.py <engine-tree-or-crash_libbacktrace.c> ...')
		return 1
	rc = 0
	for arg in sys.argv[1:]:
		if os.path.isdir(arg):
			p = os.path.join(arg, 'engine', 'platform', 'posix', 'crash_libbacktrace.c')
		else:
			p = arg
		if not patch(p):
			rc = 1
	return rc


if __name__ == '__main__':
	sys.exit(main())
