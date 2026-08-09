/*
 * modprobe.c - does dyld accept this dylib, and is the engine's entry point in it?
 *
 *   modprobe <dylib> [symbol ...]      prints "ok", or what went wrong
 *
 * Used by tests/test-mod-dylibs.sh. It is a separate file rather than a heredoc
 * inside that script because tests/make-probe.sh has to compile the same source
 * into a fat binary for the machines that have no compiler at all: a stock
 * Panther or Tiger install has no Developer folder, so the test could not run on
 * the two oldest boxes in the fleet, which are the ones it most needs to run on.
 *
 * RTLD_NOW ALONE, AND NOTHING ELSE
 *   Not RTLD_LOCAL. The engine opens game code with a bare RTLD_NOW in
 *   engine/platform/posix/lib_posix.c, at all four of its call sites, and this
 *   probe exists to answer "will the engine load this", so it has to ask in the
 *   engine's words.
 *
 *   It also happens to be the only thing that works on 10.3.9. Panther has no
 *   real dlopen: libdl there is dlcompat, a shim over the NSModule API, and it
 *   rejects RTLD_LOCAL outright with "unable to open this file with
 *   RTLD_LOCAL". A probe that asked for RTLD_LOCAL failed on all 48 dylibs on
 *   the G3 while the game itself loaded them perfectly well, which is a test
 *   reporting its own flags as a fault in the thing under test.
 *
 * C89 on purpose. This has to compile with gcc-4.0 against the 10.3.9 SDK as
 * well as with a current clang, so no declarations after statements, and no
 * // comments.
 */
#include <dlfcn.h>
#include <stdio.h>

int main( int argc, char **argv )
{
	void *h;
	int i, bad = 0;

	if( argc < 2 )
	{
		printf( "usage: modprobe <dylib> [symbol ...]" );
		return 2;
	}

	h = dlopen( argv[1], RTLD_NOW );
	if( !h )
	{
		printf( "DLOPEN FAILED: %s", dlerror() );
		return 1;
	}

	for( i = 2; i < argc; i++ )
	{
		if( !dlsym( h, argv[i] ) )
		{
			printf( "missing %s ", argv[i] );
			bad = 1;
		}
	}

	if( !bad )
		printf( "ok" );

	return bad;
}
