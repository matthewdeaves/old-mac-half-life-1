/*
 * md5progress-test.m - exercise OMFileMD5Progress() on a real file.
 *
 * Built and run by hand, not part of any app. It links the SHIPPING OMDiskImage.m
 * rather than a copy, so what it measures is what the Mods app runs.
 *
 * The point of GitHub issue #10: Panther's hdiutil has no -puppetstrings, so its
 * verify pass reports no percentage and a 2.6 GB image looks like a hang on a G3.
 * OMFileMD5Progress does the checksum itself so the bar can move on every OS. This
 * harness prints each percentage the sink is handed, plus wall-clock time, so that
 * claim can be checked on the machine it was written for.
 *
 *   gcc-4.0 -arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk \
 *           -mmacosx-version-min=10.3 -framework Cocoa -Wno-long-double \
 *           -o md5progress-test md5progress-test.m OMDiskImage.m
 *
 *   ./md5progress-test <path> [expected-md5]
 */

#import "OldMacMods.h"

#include <stdio.h>
#include <string.h>
#include <sys/time.h>

static double now_seconds( void )
{
	struct timeval tv;
	gettimeofday( &tv, NULL );
	return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

@interface SinkPrinter : NSObject <OMProgressSink>
{
@public
	int    updates;
	double started;
	double lastAt;
}
@end

@implementation SinkPrinter

- (void)omLog:(NSString *)line
{
	printf( "  log: %s\n", [line UTF8String] );
}

- (void)omStatus:(NSString *)text
{
	printf( "  status: %s\n", [text UTF8String] );
}

- (void)omProgress:(double)fraction
{
	double t = now_seconds();

	updates++;
	/* Print every tenth update so the output stays readable on a 2.6 GB file,
	 * but count them all: "the bar moved" is the whole question here. */
	if( updates % 10 == 1 || fraction >= 1.0 )
		printf( "  %5.1f%%  t=%6.1fs  (gap %.2fs)\n",
			fraction * 100.0, t - started, t - lastAt );
	lastAt = t;
}

- (void)omArtwork:(NSImage *)image title:(NSString *)title { }
- (BOOL)omCancelled { return NO; }

@end

int main( int argc, const char *argv[] )
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	SinkPrinter *sink;
	NSString *path, *digest;
	double t0, t1;

	if( argc < 2 )
	{
		fprintf( stderr, "usage: %s <path> [expected-md5]\n", argv[0] );
		[pool release];
		return 2;
	}

	path = [NSString stringWithUTF8String:argv[1]];
	sink = [[SinkPrinter alloc] init];

	printf( "file: %s\n", argv[1] );
	{
		NSDictionary *a = [[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:YES];
		if( a != nil )
			printf( "size: %lld bytes\n", [[a objectForKey:NSFileSize] longLongValue] );
	}

	t0 = now_seconds();
	sink->started = t0;
	sink->lastAt = t0;
	sink->updates = 0;

	digest = OMFileMD5Progress( path, sink );
	t1 = now_seconds();

	printf( "\nresult : %s\n", digest ? [digest UTF8String] : "(nil)" );
	printf( "updates: %d progress callbacks\n", sink->updates );
	printf( "elapsed: %.1f s\n", t1 - t0 );

	if( argc > 2 && digest != nil )
	{
		NSString *want = [[NSString stringWithUTF8String:argv[2]] lowercaseString];
		printf( "expected: %s\n", [want UTF8String] );
		printf( "MATCH   : %s\n", [digest isEqualToString:want] ? "yes" : "NO" );
		if( ![digest isEqualToString:want] )
		{
			[pool release];
			return 1;
		}
	}

	[pool release];
	return digest ? 0 : 1;
}
