/*
 * omtls-test.m - prove the TLS transport against the real hosts.
 *
 *   ./omtls-test <ca-roots.pem> [host ...]
 *
 * Companion to md5progress-test.m: a throwaway harness, not part of the app, so
 * that OMTLS.m can be exercised without driving the GUI. Builds with the same
 * two toolchains as the app.
 *
 * WHY THIS EXISTS RATHER THAN A UNIT TEST
 * ---------------------------------------
 * Everything that can go wrong with this code goes wrong against a real server:
 * a root missing from the bundle, a host that needs SNI, a chain mbedTLS cannot
 * build a path through, a cipher we did not compile in. None of that is visible
 * from a local test, and all of it is visible from one handshake. So this does a
 * real handshake and a real Range request, and prints the negotiated cipher, so
 * the ChaCha-first ordering on PowerPC can be confirmed rather than assumed.
 *
 * Run it on a PowerPC box as well as Intel. The point of the exercise is the old
 * machines, and the ppc slice is the one carrying the untested paths.
 */

#import "OldMacMods.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/time.h>

static int probe( NSString *host, NSString *path, NSString *ca )
{
	NSString *err = nil, *req, *status = nil;
	OMConn *c;
	char line[1024];
	int n, code = 0;

	printf( "%-38s ", [host UTF8String] );
	fflush( stdout );

	c = OMConnOpen( host, 443, YES, ca, &err );
	if( c == NULL )
	{
		printf( "FAIL  %s\n", [( err ? err : @"unknown" ) UTF8String] );
		return 1;
	}

	/* A one-byte Range request: proves the session carries data both ways and
	 * that resume will work, without pulling a gigabyte to find out. */
	req = [NSString stringWithFormat:
		@"GET %@ HTTP/1.1\r\nHost: %@\r\nUser-Agent: OldMacHalfLife-ModInstaller/1.0\r\n"
		 "Range: bytes=0-0\r\nConnection: close\r\n\r\n", path, host];
	if( !OMConnWriteAll( c, [req UTF8String], strlen( [req UTF8String] )))
	{
		printf( "FAIL  could not send request\n" );
		OMConnClose( c );
		return 1;
	}

	n = 0;
	while( n < (int)sizeof( line ) - 1 )
	{
		char ch;
		if( OMConnRead( c, &ch, 1 ) <= 0 ) break;
		if( ch == '\n' ) break;
		if( ch != '\r' ) line[n++] = ch;
	}
	line[n] = 0;
	status = [NSString stringWithUTF8String:line];
	{
		NSArray *parts = [status componentsSeparatedByString:@" "];
		if( [parts count] >= 2 ) code = [[parts objectAtIndex:1] intValue];
	}

	printf( "%-42s HTTP %d\n", OMConnCipherName( c ), code );
	OMConnClose( c );

	/* 206 is what we want (Range honoured). 200 means the host ignored Range,
	 * which still proves TLS but means resume would restart from zero there. */
	return ( code == 206 || code == 200 ) ? 0 : 1;
}

/*
 * Throughput, because "does it connect" is not the question on a 400 MHz G3.
 * These machines have no AES instructions, so the worry is that the cipher, not
 * the network, becomes the limit on a multi-hundred-megabyte mod. Pulls a real
 * Range from a real host and reports MB/s through the whole stack.
 */
static void bench( NSString *host, NSString *path, NSString *ca, long long bytes )
{
	NSString *err = nil, *req;
	OMConn *c;
	char *buf;
	long long got = 0;
	struct timeval t0, t1;
	double secs;

	c = OMConnOpen( host, 443, YES, ca, &err );
	if( c == NULL )
	{
		printf( "bench: FAIL %s\n", [( err ? err : @"unknown" ) UTF8String] );
		return;
	}

	req = [NSString stringWithFormat:
		@"GET %@ HTTP/1.1\r\nHost: %@\r\nUser-Agent: OldMacHalfLife-ModInstaller/1.0\r\n"
		 "Range: bytes=0-%lld\r\nConnection: close\r\n\r\n", path, host, bytes - 1];
	OMConnWriteAll( c, [req UTF8String], strlen( [req UTF8String] ));

	buf = (char *)malloc( 65536 );
	gettimeofday( &t0, NULL );
	while( got < bytes )
	{
		ssize_t r = OMConnRead( c, buf, 65536 );
		if( r <= 0 ) break;
		got += r;
	}
	gettimeofday( &t1, NULL );
	free( buf );
	OMConnClose( c );

	secs = ( t1.tv_sec - t0.tv_sec ) + ( t1.tv_usec - t0.tv_usec ) / 1000000.0;
	printf( "bench: %lld bytes in %.1f s = %.2f MB/s (headers included)\n",
		got, secs, secs > 0 ? ( got / 1048576.0 ) / secs : 0.0 );
}

int main( int argc, const char *argv[] )
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *ca;
	int bad = 0;

	if( argc < 2 )
	{
		fprintf( stderr, "usage: %s <ca-roots.pem> [--bench MB]\n", argv[0] );
		return 2;
	}
	ca = [NSString stringWithUTF8String:argv[1]];

	if( argc >= 4 && strcmp( argv[2], "--bench" ) == 0 )
	{
		bench( @"files.runthinkshootlive.com", @"/half-life-1/hl1-sp-xen-warrior.7z",
			ca, (long long)atoi( argv[3] ) * 1048576 );
		[pool release];
		return 0;
	}

	printf( "%-38s %-42s %s\n", "host", "negotiated", "result" );
	printf( "----------------------------------------------------------------------------------------\n" );

	/* The hosts the source list actually names. github.com and codeload are the
	 * ECDSA/Sectigo chain; the githubusercontent ones are the Let's Encrypt
	 * chain; runthinkshootlive is where most mods come from. */
	bad += probe( @"files.runthinkshootlive.com",
		@"/half-life-1/hl1-sp-xen-warrior.7z", ca );
	bad += probe( @"github.com", @"/", ca );
	bad += probe( @"codeload.github.com", @"/Mbed-TLS/mbedtls/tar.gz/refs/tags/v3.6.7", ca );
	bad += probe( @"raw.githubusercontent.com", @"/Mbed-TLS/mbedtls/development/README.md", ca );
	bad += probe( @"archive.org", @"/metadata/goldsrc_mods_poke646", ca );

	printf( "\n%s\n", bad == 0 ? "all hosts reachable" : "SOME HOSTS FAILED" );
	[pool release];
	return bad == 0 ? 0 : 1;
}
