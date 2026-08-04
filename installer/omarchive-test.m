/*
 * omarchive-test.m - unpack a real mod archive and check what came out.
 *
 *   ./omarchive-test <archive> <zip|7z> <root> <destdir> [expect-gamedir]
 *
 * Throwaway harness, like omtls-test.m. The reason it exists is that the failure
 * modes here are silent: a zip reader that mishandles the local-header extra
 * field offsets every member by a few bytes and produces files that are the
 * right size and complete garbage. So this reports the file count, the total
 * bytes and whether liblist.gam turned up, which is the one file that decides
 * whether the engine will treat the result as a mod at all.
 *
 * Run it on a PowerPC box too. Zip is little-endian on the wire and half the
 * fleet is not, so the byte assembly in OMArchive.m is exactly the kind of code
 * that works on Intel and quietly does not on a G4.
 */

#import "OldMacMods.h"
#include <stdio.h>
#include <sys/stat.h>

@interface TestSink : NSObject <OMProgressSink>
@end

@implementation TestSink
- (void)omLog:(NSString *)line          { printf( "    %s\n", [line UTF8String] ); }
- (void)omStatus:(NSString *)text       { (void)text; }
- (void)omProgress:(double)fraction     { (void)fraction; }
- (void)omArtwork:(NSImage *)i title:(NSString *)t { (void)i; (void)t; }
- (BOOL)omCancelled                     { return NO; }
@end

static void walk( NSString *dir, unsigned *files, unsigned long long *bytes, BOOL *sawLiblist )
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *names = [fm directoryContentsAtPath:dir];
	unsigned i;

	for( i = 0; i < [names count]; i++ )
	{
		NSString *n = [names objectAtIndex:i];
		NSString *p = [dir stringByAppendingPathComponent:n];
		BOOL isDir = NO;

		if( ![fm fileExistsAtPath:p isDirectory:&isDir] )
			continue;
		if( isDir )
		{
			walk( p, files, bytes, sawLiblist );
		}
		else
		{
			struct stat st;
			if( stat( [p fileSystemRepresentation], &st ) == 0 )
				*bytes += (unsigned long long)st.st_size;
			(*files)++;
			if( [[n lowercaseString] isEqualToString:@"liblist.gam"] )
				*sawLiblist = YES;
		}
	}
}

int main( int argc, const char *argv[] )
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *err = nil;
	TestSink *sink = [[TestSink alloc] init];
	unsigned files = 0;
	unsigned long long bytes = 0;
	BOOL sawLiblist = NO, ok;

	if( argc < 5 )
	{
		fprintf( stderr, "usage: %s <archive> <zip|7z> <root> <destdir>\n", argv[0] );
		return 2;
	}

	printf( "%s  (%s, root=%s)\n", argv[1], argv[2], argv[3] );

	ok = OMExtractArchive( [NSString stringWithUTF8String:argv[1]],
		[NSString stringWithUTF8String:argv[2]],
		[NSString stringWithUTF8String:argv[3]],
		[NSString stringWithUTF8String:argv[4]], sink, &err );

	if( !ok )
	{
		printf( "    FAILED: %s\n", [( err ? err : @"unknown" ) UTF8String] );
		[pool release];
		return 1;
	}

	walk( [NSString stringWithUTF8String:argv[4]], &files, &bytes, &sawLiblist );
	printf( "    %u files, %llu bytes, liblist.gam %s\n",
		files, bytes, sawLiblist ? "PRESENT" : "*** MISSING ***" );

	[pool release];
	return sawLiblist ? 0 : 1;
}
