#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-sys-newinstance-fork.py - make "change game" actually restart the engine.

THE BUG
-------
Switching mods from the Custom Game menu did nothing on PowerPC. The menu
worked, the engine shut down cleanly, and then:

    Note: Issuing host shutdown due to reason "change game to 'Opposing Force'"
    CL_Shutdown()
    Error: Failed to restart the engine
    execv(.../Contents/MacOS/xash3d.bin) failed: Operation not supported

leaving a live process with no window that had to be force-quit.

ROOT CAUSE (measured, not guessed)
----------------------------------
Darwin refuses execve() from a process that has more than one thread. It does
not replace the image; it returns ENOTSUP (errno 45). Demonstrated on
quicksilver, a G4 running 10.4.11, with a purpose-built test binary:

    threads created: 0 -> calling execv directly
      -> exec succeeded
    threads created: 4 -> calling execv directly
      -> execv FAILED: Operation not supported (errno 45)

Sys_NewInstance() runs after Host_Shutdown, but SDL's helper threads are still
alive at that point, so the process is multi-threaded and the exec is refused
every time.

Ruled out along the way, so nobody re-treads it:
  * NOT the path. host.argv[0] was tried as well as the resolved executable
    path; both name the same xash3d.bin and both fail identically.
  * NOT the file, and NOT fat-binary grading. execv()ing that very same
    3-slice binary (ppc750/ppc7400/x86_64) succeeds from an ordinary
    process on the same machine, whether the caller is built generic `ppc` or
    `ppc7400`. This is worth stating plainly because this project has a real
    Tiger fat-mis-grading bug (see .claude/rules/build-verification.md) and it is
    the obvious suspect -
    it is not the culprit here.

THE FIX
-------
Try the direct exec first, since it is correct and cheapest wherever the kernel
permits it. If it returns at all, fork and exec from the child - a freshly
forked child has exactly one thread, so the restriction does not apply. The
parent stands down only once it knows the child really did replace itself,
which it learns from a close-on-exec pipe: exec succeeding closes the write end
with no data, exec failing writes the child's errno back.

That ordering matters. If the parent exited immediately after fork() and the
child then failed to exec, the user would be left with no engine at all and no
message - strictly worse than today's hang.

Applies to every engine tree.

Idempotent. Python 2.5+.

Invoke:
    python patch-sys-newinstance-fork.py <engine-tree> [<engine-tree> ...]
"""
import os
import sys

MARKER = "oldmac: Darwin refuses execve() from a multi-threaded process"

# --- 1) fcntl.h, for FD_CLOEXEC on the handshake pipe ------------------------
INC_ANCHOR = """#if XASH_POSIX
#include <unistd.h>
#include <signal.h>
"""
INC_NEW = """#if XASH_POSIX
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
"""

# --- 2) the helper, placed immediately before Sys_NewInstance ----------------
HELPER_ANCHOR = """qboolean Sys_NewInstance( const char *gamedir, const char *finalmsg )
{
"""

HELPER_NEW = """/*
=================
Sys_RestartExec

""" + MARKER + """ -- it returns
ENOTSUP (errno 45) instead of replacing the image. By the time a game change
reaches here the engine has shut down, but SDL's helper threads are still
alive, so on Mac OS X a plain execv() always fails and the old process is left
running with no window. Measured on 10.4.11/G4: the same binary execs fine from
a single-threaded process and returns ENOTSUP from a 4-thread one.

So try the direct exec first -- it is correct wherever the kernel allows it --
and fall back to exec'ing from a forked child, which is single-threaded by
construction. The close-on-exec pipe is how the parent distinguishes "the child
became the new engine" (write end closes, read returns 0) from "the child could
not exec either" (child writes its errno). Only in the former case does the
parent stand down; otherwise the caller still gets to report a real failure.

Returns only on failure, with errno set to the reason.
=================
*/
static void Sys_RestartExec( const char *exe, char **newargs )
{
	int fds[2];
	pid_t pid;
	int childerr = 0;
	ssize_t got;

	execv( exe, newargs );

	/* execv returned, so it failed. Retry from a single-threaded child. */
	if( pipe( fds ) != 0 )
		return;
	fcntl( fds[1], F_SETFD, FD_CLOEXEC );

	pid = fork();
	if( pid < 0 )
	{
		close( fds[0] );
		close( fds[1] );
		return;
	}

	if( pid == 0 )
	{
		close( fds[0] );
		execv( exe, newargs );
		childerr = errno;
		write( fds[1], &childerr, sizeof( childerr ));
		_exit( 127 );
	}

	close( fds[1] );
	got = read( fds[0], &childerr, sizeof( childerr ));
	close( fds[0] );

	if( got == 0 )
		_exit( 0 );        /* the child IS the engine now; leave without fuss */

	if( childerr != 0 )
		errno = childerr;  /* report the child's failure, not the parent's */
}

""" + HELPER_ANCHOR

# --- 3) route the exec call through it ---------------------------------------
# Sys_NewInstance's exec block: one execv, then one message if it returned.
EXEC_ANCHOR = """		execv( exe, newargs );

		// if execv returned, it's probably an error
		printf( "execv failed: %s", strerror( errno ));
"""
EXEC_NEW = """		Sys_RestartExec( exe, newargs );

		// if it returned, it's probably an error
		printf( "execv failed: %s", strerror( errno ));
"""


def patch(path):
    f = open(path, "r")
    src = f.read()
    f.close()

    if MARKER in src:
        print("  already patched: %s" % path)
        return True

    for anchor, what in ((EXEC_ANCHOR, "exec block"),
                         (INC_ANCHOR, "fcntl.h include"),
                         (HELPER_ANCHOR, "Sys_NewInstance definition")):
        if src.count(anchor) != 1:
            print("  ERROR: anchor for '%s' matched %d times (want 1)"
                  % (what, src.count(anchor)))
            return False

    src = src.replace(INC_ANCHOR, INC_NEW, 1)
    print("  applied: fcntl.h include")
    src = src.replace(HELPER_ANCHOR, HELPER_NEW, 1)
    print("  applied: Sys_RestartExec helper")
    src = src.replace(EXEC_ANCHOR, EXEC_NEW, 1)
    print("  applied: exec block")

    f = open(path, "w")
    f.write(src)
    f.close()
    print("  patched: %s" % path)
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    ok = True
    for tree in sys.argv[1:]:
        path = tree
        if os.path.isdir(tree):
            path = os.path.join(tree, "engine", "common", "system.c")
        print("== %s ==" % path)
        if not os.path.isfile(path):
            print("  ERROR: not found")
            ok = False
            continue
        ok = patch(path) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
