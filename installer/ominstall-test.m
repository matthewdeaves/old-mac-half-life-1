/*
 * ominstall-test.m - drive a real install from the command line.
 *
 *   ./ominstall-test <resources-dir> <destination> [gamedir ...]
 *   ./ominstall-test <resources-dir> <destination> --adopt
 *
 * Half-Life Mods.app is a GUI app, so the only way to exercise the install path
 * on a build box or over ssh is to call the same objects the controller calls.
 * That is what this does: OMFetch downloads, checks and unpacks; OMInstaller
 * copies, injects the dylibs and rewrites liblist.gam. Nothing here reimplements
 * any of it, so a pass means the shipping code path works, not that a parallel
 * one does.
 *
 * With no gamedirs it does every mod in mod-sources.txt, which is a couple of
 * gigabytes; name one or two for a quick check. --adopt runs only the
 * already-present pass, which is how Blue Shift, Opposing Force and Deathmatch
 * Classic are handled and needs no network at all.
 */

#import "OldMacMods.h"
#include <stdio.h>

@interface CLISink : NSObject <OMProgressSink>
{
	double lastShown;
}
@end

@implementation CLISink
- (void)omLog:(NSString *)line    { printf( "%s\n", [line UTF8String] ); fflush( stdout ); }
- (void)omStatus:(NSString *)text { printf( "  [%s]\n", [text UTF8String] ); fflush( stdout ); }
- (void)omProgress:(double)f
{
	/* One line per 10%, so a log of a full run stays readable. */
	if( f < 0 || f - lastShown < 0.10 ) return;
	lastShown = f;
	printf( "    %d%%\n", (int)( f * 100 ));
	fflush( stdout );
}
- (void)omArtwork:(NSImage *)i title:(NSString *)t { (void)i; (void)t; }
- (BOOL)omCancelled { return NO; }
@end

int main( int argc, const char *argv[] )
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSFileManager *fm = [NSFileManager defaultManager];
	CLISink *sink = [[CLISink alloc] init];
	NSString *res, *dest;
	OMFetch *fetch;
	OMInstaller *inst;
	NSArray *sources;
	int i, ok = 0, failed = 0, adopted = 0;
	BOOL adoptOnly = NO;

	if( argc < 3 )
	{
		fprintf( stderr, "usage: %s <resources-dir> <destination> [gamedir ...|--adopt]\n", argv[0] );
		return 2;
	}
	res  = [NSString stringWithUTF8String:argv[1]];
	dest = [NSString stringWithUTF8String:argv[2]];
	if( argc == 4 && strcmp( argv[3], "--adopt" ) == 0 )
		adoptOnly = YES;

	/* Same first move the controller makes: clear anything an interrupted run
	 * left beside the game, before touching any of it. */
	[OMFetch sweepLeftoversIn:dest sink:sink];

	inst = [[OMInstaller alloc] initWithSink:sink resources:res destination:dest];
	/* The SAME cache path the controller uses, so this harness exercises the
	 * real one. ~/Downloads does not exist on 10.3 or 10.4 - Apple added the
	 * Downloads folder in 10.5 - and creating it is part of what is under test. */
	fetch = [[OMFetch alloc] initWithSink:sink resources:res
	                                cache:[[NSHomeDirectory()
	                                        stringByAppendingPathComponent:@"Downloads"]
	                                       stringByAppendingPathComponent:@"Half-Life Mods"]];
	[fetch setCABundlePath:[res stringByAppendingPathComponent:@"ca-roots.pem"]];

	/* ---- pass 1: content already on disk, no network ----------------------- */
	{
		NSDictionary *map = [inst loadModMap];
		NSEnumerator *e = [map keyEnumerator];
		NSString *gd;

		printf( "== already present ==\n" );
		while(( gd = [e nextObject] ) != nil )
		{
			NSString *err = nil;
			if( ![inst hasContentFor:gd] )
				continue;
			if( [inst adoptExistingMod:gd error:&err] )
				adopted++;
			else
				printf( "  FAIL %s - %s\n", [gd UTF8String], [( err ? err : @"?" ) UTF8String] );
		}
		printf( "   %d already-present mod(s) given game code\n\n", adopted );
	}

	if( adoptOnly )
	{
		printf( "adopt-only: %d updated\n", adopted );
		[pool release];
		return 0;
	}

	/* ---- pass 2: fetch ----------------------------------------------------- */
	sources = [fetch loadSources];
	printf( "== fetch (%u sources known) ==\n", (unsigned)[sources count] );

	for( i = 0; i < (int)[sources count]; i++ )
	{
		NSDictionary *src = [sources objectAtIndex:(unsigned)i];
		NSString *gd = [src objectForKey:@"mod"];
		NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
		NSString *staging, *err = nil;
		OMMod *mod;
		BOOL wanted = ( argc <= 3 );
		int a;

		for( a = 3; a < argc; a++ )
			if( [gd isEqualToString:[NSString stringWithUTF8String:argv[a]]] )
				wanted = YES;
		if( !wanted ) { [inner release]; continue; }

		printf( "\n-- %s --\n", [gd UTF8String] );
		staging = [fetch stageMod:src into:dest error:&err];
		if( staging == nil )
		{
			printf( "FAIL  %s - %s\n", [gd UTF8String], [( err ? err : @"?" ) UTF8String] );
			failed++;
			[inner release];
			continue;
		}

		mod = [inst modForGamedir:gd at:staging];
		if( mod == nil )
		{
			printf( "FAIL  %s - not in mods.map\n", [gd UTF8String] );
			[fm removeFileAtPath:staging handler:nil];
			failed++;
			[inner release];
			continue;
		}

		err = nil;
		if( [inst installMod:mod error:&err] )
		{
			printf( "OK    %s\n", [gd UTF8String] );
			ok++;
		}
		else
		{
			printf( "FAIL  %s - %s\n", [gd UTF8String], [( err ? err : @"?" ) UTF8String] );
			failed++;
		}
		[fm removeFileAtPath:staging handler:nil];
		[inner release];
	}

	printf( "\n== %d installed, %d adopted, %d failed ==\n", ok, adopted, failed );
	[pool release];
	return failed == 0 ? 0 : 1;
}
