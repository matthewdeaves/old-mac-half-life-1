/*
 * OMInstaller.m - find mods in a source bundle and install them next to Half-Life.app.
 *
 * WHAT AN INSTALL IS
 *   copy the mod's CONTENT (maps, models, sounds, wads, its own cfgs)
 *   + drop in OUR fat ppc/x86_64 game dylibs
 *   + make liblist.gam name those dylibs
 *   = a folder the engine's Custom Game menu can switch to.
 *
 * WHAT WE REFUSE TO COPY, AND WHY IT MATTERS
 *   The upstream bundle was made by running each mod on a Yosemite i386 Mac and
 *   packaging the result, so each mod dir carries that machine's runtime state.
 *   Copying it is actively harmful, not merely untidy:
 *     video.cfg    fullscreen "1", height "1200", vid_highdpi "1" - the packaging
 *                  machine's own display state. The engine execs video.cfg and then
 *                  applies -width/-height from the command line, and our launcher
 *                  passes those only on the G3 and Panther profiles, so on any other
 *                  machine a leftover video.cfg is the mode the engine starts in.
 *                  vid_highdpi is not a cvar in either engine we build.
 *     config.cfg   the packager's keybinds, which are why a bundle can arrive with
 *                  the arrow keys bound and WASD dead.
 *     save/        the packager's savegames. Saves are native-endian, so i386 saves are garbage
 *                  on PPC anyway.
 *     dlls/ cl_dlls/  i386 game code, which we replace.
 *   See scripts/gen-mod-manifests.sh - the same list, used to precompute the
 *   expected file/byte counts we verify against.
 */

#import "OldMacMods.h"

#include <sys/stat.h>
#include <unistd.h>

@implementation OMMod
- (NSString *)gamedir    { return gamedir; }
- (NSString *)branch     { return branch; }
- (NSString *)title      { return title; }
- (NSString *)sourcePath { return sourcePath; }
- (BOOL)supported        { return supported; }
- (void)dealloc
{
	[gamedir release]; [branch release]; [serverDLL release];
	[title release]; [sourcePath release];
	[super dealloc];
}
@end


/* Keep in lockstep with is_excluded() in scripts/gen-mod-manifests.sh. `rel` is
 * relative to the mod dir, using '/' separators. */
static BOOL omShouldSkipPath( NSString *rel )
{
	NSString *base = [rel lastPathComponent];
	NSString *first = [[rel pathComponents] count] > 0 ? [[rel pathComponents] objectAtIndex:0] : rel;

	/* our own build replaces these, and the duplicates are packaging debris */
	if( [first isEqualToString:@"dlls"] || [first isEqualToString:@"cl_dlls"] ) return YES;
	if( [first isEqualToString:@"dlls 2"] || [first isEqualToString:@"cl_dlls 2"] ) return YES;

	/* the packager's savegames */
	if( [first caseInsensitiveCompare:@"save"] == NSOrderedSame ) return YES;

	/* engine-generated per-machine state */
	if( [base isEqualToString:@"config.cfg"] )   return YES;
	if( [base isEqualToString:@"video.cfg"] )    return YES;
	if( [base isEqualToString:@"opengl.cfg"] )   return YES;
	if( [base isEqualToString:@"keyboard.cfg"] ) return YES;
	if( [base hasSuffix:@".bak"] )               return YES;
	if( [base isEqualToString:@".xash_id"] )     return YES;

	/* junk */
	if( [base isEqualToString:@".DS_Store"] )    return YES;
	if( [base isEqualToString:@"last-run.log"] ) return YES;

	return NO;
}


@implementation OMInstaller

- (id)initWithSink:(id<OMProgressSink>)aSink resources:(NSString *)res destination:(NSString *)dest
{
	self = [super init];
	if( self != nil )
	{
		sink = aSink;
		resourcesPath = [res retain];
		destRoot = [dest retain];
		forceReinstall = NO;
	}
	return self;
}

- (void)setForceReinstall:(BOOL)force { forceReinstall = force; }

- (void)dealloc
{
	[resourcesPath release];
	[destRoot release];
	[super dealloc];
}

/*
 * Is this Half-Life.app OUR port, rather than some other app of the same name?
 *
 * The name alone is not enough. "Half-Life.app" is a name anyone might use, and
 * installing 4 GB of mod folders next to the wrong one puts them somewhere the
 * engine will never look. So we check the bundle LAYOUT, which is ours alone:
 * make-app.sh renames the Mach-O to xash3d.bin and puts a shell launcher at
 * xash3d in its place (it exports XASH3D_BASEDIR and picks the per-machine
 * display profile). No other Mac Half-Life build ships that pair; the i386 ports
 * that circulate use xash3d.sh + xash3d-bin.
 *
 * Deliberately NOT keyed on Contents/Resources/BUILD-INFO.txt: only make-dmg.sh
 * writes that, so requiring it would reject a make-app.sh dev build. Nor on
 * CFBundleIdentifier, which is org.xash3d.halflife - upstream Xash's, not ours.
 */
+ (BOOL)isOurGameApp:(NSString *)appPath
{
	NSFileManager *fm = [NSFileManager defaultManager];

	return [fm fileExistsAtPath:[appPath stringByAppendingPathComponent:@"Contents/MacOS/xash3d.bin"]]
	    && [fm fileExistsAtPath:[appPath stringByAppendingPathComponent:@"Contents/MacOS/xash3d"]];
}

/*
 * Find the folder that holds Half-Life.app. The app and its game data are
 * siblings (see make-app.sh: XASH3D_BASEDIR is the folder CONTAINING the .app),
 * so that folder is where mod dirs belong.
 *
 * A same-named app that is not ours does NOT stop the search - we skip it and
 * keep looking, so a stray Half-Life.app on the Desktop cannot shadow the real
 * one in ~/Games.
 */
+ (NSString *)defaultDestination
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray *candidates = [NSMutableArray array];
	NSString *appDir = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
	unsigned i;

	/* Most likely: the user put this installer beside the game. */
	[candidates addObject:appDir];
	[candidates addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"]];
	[candidates addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Games"]];
	[candidates addObject:@"/Applications"];
	[candidates addObject:NSHomeDirectory()];

	for( i = 0; i < [candidates count]; i++ )
	{
		NSString *dir = [candidates objectAtIndex:i];
		NSString *app = [dir stringByAppendingPathComponent:@"Half-Life.app"];

		if( [fm fileExistsAtPath:app] && [self isOurGameApp:app] )
			return dir;
	}
	return nil;
}

/* mods.map: gamedir  branch  server_dll  title */
- (NSDictionary *)loadModMap
{
	NSMutableDictionary *map = [NSMutableDictionary dictionary];
	NSString *path = [resourcesPath stringByAppendingPathComponent:@"mods.map"];
	NSString *text = [NSString stringWithContentsOfFile:path];
	NSArray *lines;
	unsigned i;

	if( text == nil )
		return map;

	lines = [text componentsSeparatedByString:@"\n"];
	for( i = 0; i < [lines count]; i++ )
	{
		NSString *line = [[lines objectAtIndex:i]
			stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSMutableArray *f;
		NSArray *raw;
		unsigned j;

		if( [line length] == 0 || [line hasPrefix:@"#"] )
			continue;

		raw = [line componentsSeparatedByString:@" "];
		f = [NSMutableArray array];
		for( j = 0; j < [raw count]; j++ )
		{
			NSString *t = [[raw objectAtIndex:j]
				stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			if( [t length] > 0 ) [f addObject:t];
		}
		if( [f count] < 3 )
			continue;

		{
			NSMutableDictionary *e = [NSMutableDictionary dictionary];
			[e setObject:[f objectAtIndex:1] forKey:@"branch"];
			[e setObject:[f objectAtIndex:2] forKey:@"server_dll"];
			if( [f count] > 3 )
			{
				NSArray *rest = [f subarrayWithRange:NSMakeRange( 3, [f count] - 3 )];
				[e setObject:[rest componentsJoinedByString:@" "] forKey:@"title"];
			}
			else
			{
				[e setObject:[f objectAtIndex:0] forKey:@"title"];
			}
			[map setObject:e forKey:[f objectAtIndex:0]];
		}
	}
	return map;
}

/* manifests.txt: gamedir  files  bytes */
- (NSDictionary *)loadManifests
{
	NSMutableDictionary *m = [NSMutableDictionary dictionary];
	NSString *text = [NSString stringWithContentsOfFile:
		[resourcesPath stringByAppendingPathComponent:@"manifests.txt"]];
	NSArray *lines;
	unsigned i;

	if( text == nil )
		return m;

	lines = [text componentsSeparatedByString:@"\n"];
	for( i = 0; i < [lines count]; i++ )
	{
		NSString *line = [[lines objectAtIndex:i]
			stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSMutableArray *f = [NSMutableArray array];
		NSArray *raw;
		unsigned j;

		if( [line length] == 0 || [line hasPrefix:@"#"] ) continue;
		raw = [line componentsSeparatedByString:@" "];
		for( j = 0; j < [raw count]; j++ )
		{
			NSString *t = [raw objectAtIndex:j];
			if( [t length] > 0 ) [f addObject:t];
		}
		if( [f count] >= 3 )
			[m setObject:[NSArray arrayWithObjects:[f objectAtIndex:1], [f objectAtIndex:2], nil]
			      forKey:[f objectAtIndex:0]];
	}
	return m;
}

/*
 * Pull a server dylib basename out of one gameinfo.txt or liblist.gam.
 *   gamedll "dlls\survivor.dll"  ->  survivor
 * `wantOSX` selects which key to look for, so the caller can do two passes and
 * genuinely prefer gamedll_osx rather than taking whichever line comes first.
 */
- (NSString *)serverDLLIn:(NSString *)path osx:(BOOL)wantOSX
{
	NSString *text = [NSString stringWithContentsOfFile:path];
	NSArray *lines;
	unsigned i;

	if( text == nil )
		return nil;

	lines = [text componentsSeparatedByString:@"\n"];
	for( i = 0; i < [lines count]; i++ )
	{
		NSString *line = [[lines objectAtIndex:i]
			stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSString *lower = [line lowercaseString];
		NSRange q1, q2;
		NSString *val, *base;

		if( wantOSX )
		{
			if( ![lower hasPrefix:@"gamedll_osx"] )
				continue;
		}
		else
		{
			if( ![lower hasPrefix:@"gamedll"] )
				continue;
			/* the plain Windows key only; the others are handled separately */
			if( [lower hasPrefix:@"gamedll_linux"] || [lower hasPrefix:@"gamedll_osx"] )
				continue;
		}

		q1 = [line rangeOfString:@"\""];
		if( q1.location == NSNotFound ) continue;
		q2 = [line rangeOfString:@"\"" options:0
			range:NSMakeRange( q1.location + 1, [line length] - q1.location - 1 )];
		if( q2.location == NSNotFound ) continue;

		val = [line substringWithRange:NSMakeRange( q1.location + 1, q2.location - q1.location - 1 )];
		val = OMReplace( val, @"\\", @"/" );
		base = [[val lastPathComponent] stringByDeletingPathExtension];
		if( [base length] > 0 )
			return base;
	}
	return nil;
}

/*
 * The name the ENGINE will actually dlopen for this mod.
 *
 * Order matters and is not obvious. Xash reads gameinfo.txt in preference to
 * liblist.gam, so gameinfo.txt's gamedll_osx wins over anything in liblist.gam.
 * Within either file an explicit gamedll_osx wins over the Windows gamedll,
 * whose extension the engine would otherwise just swap to .dylib.
 *
 * For 25 of the 26 mods in the collection this makes no difference: both files
 * name the same library. Xen Warrior is the exception and is the reason this
 * exists. Its liblist.gam (the original Windows mod's) says dlls\spirit.dll,
 * while the gameinfo.txt Xash generated on the packaging machine says
 * dlls/libserver.dylib. Install it as spirit.dylib, which liblist.gam alone
 * would tell you to do, and the engine looks for libserver.dylib and the mod
 * does not load.
 */
- (NSString *)serverDLLFromLiblist:(NSString *)modDir
{
	NSString *name;

	name = [self serverDLLIn:[modDir stringByAppendingPathComponent:@"gameinfo.txt"] osx:YES];
	if( name != nil ) return name;

	name = [self serverDLLIn:[modDir stringByAppendingPathComponent:@"liblist.gam"] osx:YES];
	if( name != nil ) return name;

	name = [self serverDLLIn:[modDir stringByAppendingPathComponent:@"gameinfo.txt"] osx:NO];
	if( name != nil ) return name;

	return [self serverDLLIn:[modDir stringByAppendingPathComponent:@"liblist.gam"] osx:NO];
}

/*
 * How many regular files are under `dir`. Used only to decide whether a mod is
 * already installed, so it counts everything rather than re-applying the copy
 * exclusions - the number is compared against manifests.txt with 5% slack, and
 * the two dylibs we add ourselves sit inside that slack.
 */
- (long)countFilesAt:(NSString *)dir
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
	NSString *rel;
	long n = 0;

	while(( rel = [e nextObject] ) != nil )
	{
		BOOL isDir = NO;
		if( [fm fileExistsAtPath:[dir stringByAppendingPathComponent:rel] isDirectory:&isDir] && !isDir )
			n++;
	}
	return n;
}

/* Recursive copy honouring the exclusion rules; returns files copied, or -1. */
- (long)copyTree:(NSString *)src to:(NSString *)dst relative:(NSString *)rel
       bytesSoFar:(long long *)bytes ofTotal:(long long)total error:(NSString **)err
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *entries = [fm directoryContentsAtPath:src];
	long count = 0;
	unsigned i;

	if( ![fm fileExistsAtPath:dst] )
	{
		if( ![fm createDirectoryAtPath:dst attributes:nil] )
		{
			if( err ) *err = [NSString stringWithFormat:@"cannot create %@", dst];
			return -1;
		}
	}

	for( i = 0; i < [entries count]; i++ )
	{
		NSString *name = [entries objectAtIndex:i];
		NSString *s = [src stringByAppendingPathComponent:name];
		NSString *d = [dst stringByAppendingPathComponent:name];
		NSString *r = ( [rel length] > 0 ? [rel stringByAppendingPathComponent:name] : name );
		BOOL isDir = NO;

		if( [sink omCancelled] )
		{
			if( err ) *err = @"cancelled";
			return -1;
		}
		if( omShouldSkipPath( r ))
			continue;

		[fm fileExistsAtPath:s isDirectory:&isDir];
		if( isDir )
		{
			long sub = [self copyTree:s to:d relative:r bytesSoFar:bytes ofTotal:total error:err];
			if( sub < 0 ) return -1;
			count += sub;
		}
		else
		{
			NSDictionary *attrs = [fm fileAttributesAtPath:s traverseLink:NO];
			if( [[attrs objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink] )
				continue;

			if( [fm fileExistsAtPath:d] )
				[fm removeFileAtPath:d handler:nil];
			if( ![fm copyPath:s toPath:d handler:nil] )
			{
				if( err ) *err = [NSString stringWithFormat:@"copy failed: %@", r];
				return -1;
			}
			count++;
			*bytes += [[attrs objectForKey:NSFileSize] longLongValue];
			if( total > 0 && ( count % 25 ) == 0 )
				[sink omProgress:(double)*bytes / (double)total];
		}
	}
	return count;
}

/*
 * Make liblist.gam name the dylib we actually installed. The engine tries the
 * arch-suffixed name first and then falls back to this plain one, so if the mod's
 * liblist.gam disagrees with what is on disk the mod silently fails to load.
 * Rewriting one line removes that whole class of failure.
 */
- (void)fixLiblist:(NSString *)modDir serverDLL:(NSString *)dll
{
	NSString *path = [modDir stringByAppendingPathComponent:@"liblist.gam"];
	NSString *text = [NSString stringWithContentsOfFile:path];
	NSMutableArray *out;
	NSArray *lines;
	unsigned i;
	BOOL wrote = NO;

	if( text == nil )
		return;

	lines = [text componentsSeparatedByString:@"\n"];
	out = [NSMutableArray array];
	for( i = 0; i < [lines count]; i++ )
	{
		NSString *line = [lines objectAtIndex:i];
		if( [[[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
				lowercaseString] hasPrefix:@"gamedll_osx"] )
		{
			if( !wrote )
			{
				[out addObject:[NSString stringWithFormat:@"gamedll_osx \"dlls/%@.dylib\"", dll]];
				wrote = YES;
			}
			continue;   /* drop any duplicates */
		}
		[out addObject:line];
	}
	if( !wrote )
		[out addObject:[NSString stringWithFormat:@"gamedll_osx \"dlls/%@.dylib\"", dll]];

	[[out componentsJoinedByString:@"\n"] writeToFile:path atomically:YES];
}

/*
 * Mod banners and blurbs are NOT staged here any more.
 *
 * They used to be copied into the player's own game data, at
 * valve/gfx/shell/mods/<gamedir>.{tga,txt}, because while the engine is running
 * `valve` a mod's own folder is not in the filesystem search path, so
 * PIC_Load("bshift/game.tga") finds nothing. That worked, but it meant writing
 * our files into a folder that is entirely the player's.
 *
 * We now ship all 25 banners and blurbs inside Half-Life.app itself, at
 * Contents/Resources/Half-Life/valve/gfx/shell/mods/ (see make-universal.sh). That
 * directory is the engine's read-only root and is on the search path for every
 * gamedir, so the Custom Game menu resolves the same relative names with no
 * install-time copying, and the artwork is present even for a mod the player
 * installed by hand. See scripts/patch-mainui-modart.py.
 */

/*
 * Build a mod record for content that is already unpacked at `path`.
 *
 * The per-mod fetch flow unpacks an archive into <gamedir>.staging and then
 * wants exactly what scanSource: would have produced for a directory on a
 * mounted volume. Rather than teach scanSource: about staging directories, this
 * builds the one record directly: the archive's own folder name is not
 * necessarily the gamedir (asheep ships as `azuresheep`, cc as `caseclosed`), so
 * the caller already knows which mod this is and says so.
 */
- (OMMod *)modForGamedir:(NSString *)gamedir at:(NSString *)path
{
	NSDictionary *map = [self loadModMap];
	NSDictionary *manifests = [self loadManifests];
	NSDictionary *entry = [map objectForKey:gamedir];
	NSString *fromList;
	OMMod *mod;

	if( entry == nil )
		return nil;

	mod = [[[OMMod alloc] init] autorelease];
	mod->gamedir    = [gamedir retain];
	mod->sourcePath = [path retain];
	mod->supported  = YES;
	mod->companion  = NO;
	mod->branch     = [[entry objectForKey:@"branch"] retain];
	mod->title      = [[entry objectForKey:@"title"] retain];

	/* liblist.gam is the only thing the engine consults, so it outranks the
	 * fallback in mods.map. See -serverDLLFromLiblist:. */
	fromList = [self serverDLLFromLiblist:path];
	mod->serverDLL = [( fromList != nil ? fromList : [entry objectForKey:@"server_dll"] ) retain];

	{
		NSArray *exp = [manifests objectForKey:gamedir];
		if( exp != nil )
		{
			mod->expectedFiles = [[exp objectAtIndex:0] intValue];
			mod->expectedBytes = OMLongLong( [exp objectAtIndex:1] );
		}
	}
	return mod;
}

/*
 * Does destRoot/<gamedir> hold something that looks like real mod content?
 *
 * "The folder exists" is not enough: an empty folder, or one holding only the
 * dylibs a previous run put there, would make us report a mod as present when
 * the player cannot play it. liblist.gam is the file the engine actually reads,
 * and maps/ is what makes it a game rather than a stub, so one of those has to
 * be there.
 */
- (BOOL)hasContentFor:(NSString *)gamedir
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dir = [destRoot stringByAppendingPathComponent:gamedir];
	BOOL isDir = NO;

	if( ![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir )
		return NO;
	if( [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"liblist.gam"]] )
		return YES;
	if( [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"maps"] isDirectory:&isDir] && isDir )
		return YES;
	return NO;
}

- (BOOL)adoptExistingMod:(NSString *)gamedir error:(NSString **)err
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *map = [self loadModMap];
	NSDictionary *entry = [map objectForKey:gamedir];
	NSString *dir = [destRoot stringByAppendingPathComponent:gamedir];
	NSString *build, *sv, *cl, *dllName, *fromList;

	if( entry == nil )
	{
		if( err ) *err = [NSString stringWithFormat:@"%@ is not a mod this app knows about", gamedir];
		return NO;
	}
	if( ![self hasContentFor:gamedir] )
	{
		if( err ) *err = [NSString stringWithFormat:@"there is no %@ content at %@", gamedir, dir];
		return NO;
	}

	build = [[resourcesPath stringByAppendingPathComponent:@"mods"]
		stringByAppendingPathComponent:[entry objectForKey:@"branch"]];
	sv = [build stringByAppendingPathComponent:@"server.dylib"];
	cl = [build stringByAppendingPathComponent:@"client.dylib"];
	if( ![fm fileExistsAtPath:sv] || ![fm fileExistsAtPath:cl] )
	{
		if( err ) *err = [NSString stringWithFormat:@"missing bundled build for '%@'",
			[entry objectForKey:@"branch"]];
		return NO;
	}

	fromList = [self serverDLLFromLiblist:dir];
	dllName = ( fromList != nil ? fromList : [entry objectForKey:@"server_dll"] );

	[fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"dlls"] attributes:nil];
	[fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"cl_dlls"] attributes:nil];
	{
		NSString *dsv = [dir stringByAppendingPathComponent:
			[NSString stringWithFormat:@"dlls/%@.dylib", dllName]];
		NSString *dcl = [dir stringByAppendingPathComponent:@"cl_dlls/client.dylib"];

		if( [fm fileExistsAtPath:dsv] ) [fm removeFileAtPath:dsv handler:nil];
		if( [fm fileExistsAtPath:dcl] ) [fm removeFileAtPath:dcl handler:nil];
		if( ![fm copyPath:sv toPath:dsv handler:nil] || ![fm copyPath:cl toPath:dcl handler:nil] )
		{
			if( err ) *err = @"could not install game dylibs";
			return NO;
		}
	}
	[self fixLiblist:dir serverDLL:dllName];

	[sink omLog:[NSString stringWithFormat:
		@"  %@: content already present - added dlls/%@.dylib + cl_dlls/client.dylib",
		gamedir, dllName]];
	return YES;
}

- (BOOL)installMod:(OMMod *)mod error:(NSString **)err
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dest = [destRoot stringByAppendingPathComponent:mod->gamedir];
	NSString *build = [[resourcesPath stringByAppendingPathComponent:@"mods"]
		stringByAppendingPathComponent:( mod->branch != nil ? mod->branch : @"" )];
	NSString *sv = [build stringByAppendingPathComponent:@"server.dylib"];
	NSString *cl = [build stringByAppendingPathComponent:@"client.dylib"];
	NSString *dllName;
	long long bytes = 0;
	long copied;

	if( !mod->supported )
	{
		if( err ) *err = [NSString stringWithFormat:@"%@ is not supported - no build is shipped for it", mod->gamedir];
		return NO;
	}

	/*
	 * Already fully installed? Don't copy it again.
	 *
	 * This is what makes a second run cheap, and it is not a nicety: a full
	 * install is ~4 GB and plausibly an hour or two on a G3, so re-running after
	 * a cancel - or to pick up a newer release of this installer - has to skip
	 * the mods that are already done. It is also what makes the cancel message
	 * ("run again, finished mods are left alone") actually true.
	 *
	 * We still refresh the two game dylibs and re-stage the menu assets below,
	 * because those are the parts WE ship and they are what changes between our
	 * releases. They are a handful of files against tens of thousands.
	 */
	if( !forceReinstall && !mod->companion && mod->expectedFiles > 0 && [fm fileExistsAtPath:dest] )
	{
		long have = [self countFilesAt:dest];
		long slack = mod->expectedFiles / 20;              /* same 5% as below */

		if( have >= mod->expectedFiles - slack )
		{
			dllName = ( mod->serverDLL != nil ? mod->serverDLL : @"hl" );
			[sink omStatus:[NSString stringWithFormat:@"Refreshing %@...", mod->title]];

			[fm createDirectoryAtPath:[dest stringByAppendingPathComponent:@"dlls"] attributes:nil];
			[fm createDirectoryAtPath:[dest stringByAppendingPathComponent:@"cl_dlls"] attributes:nil];
			{
				NSString *dsv = [dest stringByAppendingPathComponent:
					[NSString stringWithFormat:@"dlls/%@.dylib", dllName]];
				NSString *dcl = [dest stringByAppendingPathComponent:@"cl_dlls/client.dylib"];
				if( [fm fileExistsAtPath:dsv] ) [fm removeFileAtPath:dsv handler:nil];
				if( [fm fileExistsAtPath:dcl] ) [fm removeFileAtPath:dcl handler:nil];
				[fm copyPath:sv toPath:dsv handler:nil];
				[fm copyPath:cl toPath:dcl handler:nil];
			}
			[self fixLiblist:dest serverDLL:dllName];

			[sink omLog:[NSString stringWithFormat:
				@"  %@: already installed (%ld files) - game code refreshed",
				mod->gamedir, have]];
			return YES;
		}
	}

	/*
	 * A companion pack is pure content: copy the tree and stop. No game dylibs
	 * (it has none and needs none), no liblist.gam rewrite (it has no
	 * liblist.gam), and no manifest check (manifests.txt only covers real mods).
	 */
	if( mod->companion )
	{
		NSString *staging = [dest stringByAppendingString:@".partial"];

		if( [fm fileExistsAtPath:staging] )
			[fm removeFileAtPath:staging handler:nil];

		[sink omStatus:[NSString stringWithFormat:@"Installing %@...", mod->title]];
		copied = [self copyTree:mod->sourcePath to:staging relative:@""
		             bytesSoFar:&bytes ofTotal:mod->expectedBytes error:err];
		if( copied < 0 )
		{
			[fm removeFileAtPath:staging handler:nil];
			return NO;
		}

		if( [fm fileExistsAtPath:dest] )
			[fm removeFileAtPath:dest handler:nil];
		if( ![fm movePath:staging toPath:dest handler:nil] )
		{
			if( err ) *err = [NSString stringWithFormat:@"cannot move into place: %@", dest];
			return NO;
		}

		[sink omLog:[NSString stringWithFormat:@"  %@: %ld files, %lld MB (content only, no game code)",
			mod->gamedir, copied, bytes / 1048576]];
		return YES;
	}
	if( ![fm fileExistsAtPath:sv] || ![fm fileExistsAtPath:cl] )
	{
		if( err ) *err = [NSString stringWithFormat:@"missing bundled build for '%@'", mod->branch];
		return NO;
	}

	/* Install into a temporary name and swap at the end, so an interrupted run
	 * never leaves a half-copied folder that Custom Game will happily list. */
	{
		NSString *staging = [dest stringByAppendingString:@".partial"];
		if( [fm fileExistsAtPath:staging] )
			[fm removeFileAtPath:staging handler:nil];

		[sink omStatus:[NSString stringWithFormat:@"Installing %@...", mod->title]];
		copied = [self copyTree:mod->sourcePath to:staging relative:@""
		             bytesSoFar:&bytes ofTotal:mod->expectedBytes error:err];
		if( copied < 0 )
		{
			[fm removeFileAtPath:staging handler:nil];
			return NO;
		}

		/* our fat dylibs, at the names the engine will look for */
		dllName = ( mod->serverDLL != nil ? mod->serverDLL : @"hl" );
		[fm createDirectoryAtPath:[staging stringByAppendingPathComponent:@"dlls"] attributes:nil];
		[fm createDirectoryAtPath:[staging stringByAppendingPathComponent:@"cl_dlls"] attributes:nil];
		if( ![fm copyPath:sv toPath:[staging stringByAppendingPathComponent:
				[NSString stringWithFormat:@"dlls/%@.dylib", dllName]] handler:nil] ||
		    ![fm copyPath:cl toPath:[staging stringByAppendingPathComponent:
				@"cl_dlls/client.dylib"] handler:nil] )
		{
			if( err ) *err = @"could not install game dylibs";
			[fm removeFileAtPath:staging handler:nil];
			return NO;
		}

		[self fixLiblist:staging serverDLL:dllName];

		/* Verify against the precomputed expectation before publishing it. */
		if( mod->expectedFiles > 0 )
		{
			long slack = mod->expectedFiles / 20;   /* 5%: sources differ slightly */
			if( copied < mod->expectedFiles - slack )
			{
				if( err ) *err = [NSString stringWithFormat:
					@"only %ld of ~%ld files copied - source looks incomplete",
					copied, mod->expectedFiles];
				[fm removeFileAtPath:staging handler:nil];
				return NO;
			}
		}

		if( [fm fileExistsAtPath:dest] )
			[fm removeFileAtPath:dest handler:nil];
		if( ![fm movePath:staging toPath:dest handler:nil] )
		{
			if( err ) *err = [NSString stringWithFormat:@"cannot move into place: %@", dest];
			return NO;
		}
	}

	[sink omLog:[NSString stringWithFormat:@"  %@: %ld files, %lld MB, dlls/%@.dylib + cl_dlls/client.dylib",
		mod->gamedir, copied, bytes / 1048576, dllName]];
	return YES;
}

@end
