/*
 * OMFetch.m - get one mod from its own publisher and stage it for installation.
 *
 * WHAT REPLACED WHAT
 * ------------------
 * This app used to download a single 2.7 GB disk image that somebody else had
 * assembled from 26 mods, mount it, and copy content out. That worked, and it
 * meant the whole catalogue lived or died with one file on one mirror, packaged
 * by one person, containing three Valve retail games we had no business
 * redistributing.
 *
 * Now each mod is fetched from wherever that mod is actually published, which is
 * the same posture the project already takes toward valve/: we ship code, the
 * player's own copy and the mod author's own release supply the content. The
 * per-mod list, with the reasoning for every source and for every mod that has
 * none, is installer/mod-sources.txt.
 *
 * WHAT ONE MOD COSTS
 * ------------------
 *   download the archive (resumable) -> md5 -> unpack to <gamedir>.staging
 *   -> hand that directory to OMInstaller exactly as if it were a mounted volume
 *   -> delete the staging directory
 *
 * The last step matters on these machines. Staging and the finished install are
 * both on the target volume, so a mod is briefly on disk twice; deleting as we
 * go keeps the peak at one mod rather than the whole catalogue.
 *
 * THE ARCHIVE IS KEPT, THE STAGING DIRECTORY IS NOT
 * -------------------------------------------------
 * Downloads live in ~/Downloads/Half-Life Mods/ and are deliberately left there.
 * A G3 on wifi takes a long time over 234 MB, and a failed unpack, a cancel or a
 * second run should not mean fetching it again. The md5 in mod-sources.txt is
 * what makes reusing a cached file safe.
 */

#import "OldMacMods.h"

#include <sys/stat.h>

@implementation OMFetch

- (id)initWithSink:(id<OMProgressSink>)aSink resources:(NSString *)res cache:(NSString *)cache
{
	self = [super init];
	if( self != nil )
	{
		sink = aSink;                       /* not retained; the controller outlives us */
		resourcesPath = [res retain];
		cacheDir = [cache retain];
	}
	return self;
}

- (void)setCABundlePath:(NSString *)path
{
	[path retain];
	[caBundlePath release];
	caBundlePath = path;
}

- (void)dealloc
{
	[resourcesPath release];
	[cacheDir release];
	[caBundlePath release];
	[super dealloc];
}

/*
 * Parse mod-sources.txt into an ordered array of dictionaries.
 *
 * Blocks are separated by a blank line and start with `mod`. Order is preserved
 * because it is the install order the user sees, and the file is grouped by host
 * so a run does not bounce between two servers for no reason.
 */
- (NSArray *)loadSources
{
	NSMutableArray *out = [NSMutableArray array];
	NSString *text = [NSString stringWithContentsOfFile:
		[resourcesPath stringByAppendingPathComponent:@"mod-sources.txt"]];
	NSMutableDictionary *cur = nil;
	NSMutableArray *urls = nil;
	NSArray *lines;
	unsigned i;

	if( text == nil )
		return out;

	lines = [text componentsSeparatedByString:@"\n"];
	for( i = 0; i < [lines count]; i++ )
	{
		NSString *line = [[lines objectAtIndex:i]
			stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSRange sp;
		NSString *key, *val;

		if( [line length] == 0 || [line hasPrefix:@"#"] )
			continue;

		sp = [line rangeOfString:@" "];
		if( sp.location == NSNotFound )
			continue;
		key = [line substringToIndex:sp.location];
		val = [[line substringFromIndex:sp.location]
			stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if( [val length] == 0 )
			continue;

		if( [key isEqualToString:@"mod"] )
		{
			cur = [NSMutableDictionary dictionary];
			urls = [NSMutableArray array];
			[cur setObject:val forKey:@"mod"];
			[cur setObject:urls forKey:@"urls"];
			[out addObject:cur];
		}
		else if( cur != nil )
		{
			if( [key isEqualToString:@"url"] )
				[urls addObject:val];
			else
				[cur setObject:val forKey:key];
		}
	}
	return out;
}

/*
 * Where a mod's archive is cached. Named after the gamedir rather than after the
 * URL's last component: two of the archive.org URLs end in the same
 * "noffice.zip"-style name, and one carries a lambda and several spaces that we
 * would then have to make safe for the filesystem anyway.
 */
- (NSString *)cachePathFor:(NSDictionary *)src
{
	NSString *kind = [src objectForKey:@"kind"];
	return [cacheDir stringByAppendingPathComponent:
		[NSString stringWithFormat:@"%@.%@", [src objectForKey:@"mod"],
			( kind != nil ? kind : @"bin" )]];
}

/*
 * Fetch and check one archive. Returns the path to a verified file.
 *
 * A cached file of exactly the right size is md5'd rather than trusted: a
 * download interrupted at precisely the right byte is vanishingly unlikely, but
 * a mirror that changed the file underneath us is not, and that is the case the
 * md5 exists for.
 */
- (NSString *)ensureArchive:(NSDictionary *)src error:(NSString **)err
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *path = [self cachePathFor:src];
	NSString *wantMD5 = [[src objectForKey:@"md5"] lowercaseString];
	long long wantSize = OMLongLong( [src objectForKey:@"size"] );
	NSDictionary *attrs;
	OMDownload *dl;

	/*
	 * Create the cache directory AND its parents.
	 *
	 * -createDirectoryAtPath:attributes: makes exactly one level (the recursive
	 * -createDirectoryAtPath:withIntermediateDirectories:... is 10.5). The cache
	 * is ~/Downloads/Half-Life Mods, and there IS no ~/Downloads on 10.3 or 10.4
	 * - Apple added the Downloads folder in 10.5 Leopard. So on Panther the
	 * single-level create silently did nothing and every mod then failed with
	 * "cannot write .../Half-Life Mods/<file>", after downloading it. Seen on a
	 * G5 under 10.3.9: eighteen mods, eighteen identical failures.
	 */
	if( ![fm fileExistsAtPath:cacheDir] )
	{
		NSArray *parts = [cacheDir pathComponents];
		NSString *sofar = @"/";
		unsigned k;

		for( k = 0; k < [parts count]; k++ )
		{
			NSString *c = [parts objectAtIndex:k];
			if( [c isEqualToString:@"/"] )
				continue;
			sofar = [sofar stringByAppendingPathComponent:c];
			if( ![fm fileExistsAtPath:sofar] )
				[fm createDirectoryAtPath:sofar attributes:nil];
		}
	}
	if( ![fm fileExistsAtPath:cacheDir] )
	{
		if( err ) *err = [NSString stringWithFormat:@"cannot create %@", cacheDir];
		return nil;
	}

	attrs = [fm fileAttributesAtPath:path traverseLink:YES];
	if( attrs != nil && [[attrs objectForKey:NSFileSize] longLongValue] == wantSize )
	{
		NSString *got;
		[sink omStatus:[NSString stringWithFormat:@"Checking cached %@...", [src objectForKey:@"mod"]]];
		got = OMFileMD5Progress( path, sink );
		if( got != nil && [got isEqualToString:wantMD5] )
		{
			[sink omLog:@"  already downloaded and verified"];
			return path;
		}
		if( [sink omCancelled] ) { if( err ) *err = @"cancelled"; return nil; }
		[sink omLog:@"  cached copy does not match its md5 - fetching again"];
		[fm removeFileAtPath:path handler:nil];
	}

	/* Refuse before starting rather than filling the disk and failing at 90%. The
	 * unpacked tree needs roughly another 2.5x the archive alongside it. */
	{
		long long have = OMFreeSpaceAt( cacheDir );
		long long need = wantSize + wantSize * 5 / 2;
		if( have >= 0 && have < need )
		{
			if( err ) *err = [NSString stringWithFormat:
				@"not enough disk space: need about %lld MB, %lld MB free",
				need / 1048576, have / 1048576];
			return nil;
		}
	}

	dl = [[[OMDownload alloc] initWithSink:sink] autorelease];
	[dl setCABundlePath:caBundlePath];
	if( ![dl fetchURLs:[src objectForKey:@"urls"] toPath:path error:err] )
		return nil;

	[sink omStatus:[NSString stringWithFormat:@"Checking %@...", [src objectForKey:@"mod"]]];
	{
		NSString *got = OMFileMD5Progress( path, sink );
		if( got == nil )
		{
			if( err ) *err = ( [sink omCancelled] ? @"cancelled" : @"could not read the download back" );
			return nil;
		}
		if( ![got isEqualToString:wantMD5] )
		{
			/*
			 * Deleted, not kept. A file that fails its md5 is either damaged or is
			 * not the file we expected, and leaving it in the cache would mean the
			 * next run "resumes" it forever.
			 */
			[fm removeFileAtPath:path handler:nil];
			if( err ) *err = [NSString stringWithFormat:
				@"downloaded file does not match its md5 (expected %@, got %@)", wantMD5, got];
			return nil;
		}
	}
	return path;
}

/*
 * Where unpacking happens: ONE container directory, with each mod a level down
 * inside it.
 *
 * This shape is not tidiness, it is the fix for a phantom Custom Game entry.
 * Unpacking used to write <destRoot>/<gamedir>.staging, and that directory holds
 * the mod's liblist.gam. FS_ParseGameInfo (filesystem/gameinfo.c) builds
 * "<gamedir>/liblist.gam" for every directory FS_InitStdio finds beside the app
 * and registers the ones where that file exists - and listdirectory()
 * (filesystem/sys.c) does not skip dotted names, so renaming it would not have
 * helped. A force-quit part way through an unpack therefore left something like
 * "xenwar.staging" sitting in the Custom Game list, pointing at a half-extracted
 * mod.
 *
 * With the tree one level down, the directory the engine sees is `.om-staging`,
 * which has no liblist.gam of its own and so is never registered. The mod's own
 * liblist.gam is invisible to that scan.
 *
 * Still on the target volume, deliberately: /tmp may be smaller or elsewhere,
 * and this is the volume the caller free-space checked.
 */
+ (NSString *)stagingRootIn:(NSString *)destRoot
{
	return [destRoot stringByAppendingPathComponent:@".om-staging"];
}

/*
 * Clear anything a previous run left behind, before this one starts.
 *
 * Covers the container above, and also the <gamedir>.partial directories
 * OMInstaller stages into, which have the same property: they contain a
 * liblist.gam and sit beside the app. installMod: removes its own .partial on
 * every failure path, so one only survives a crash or a force-quit, but that is
 * exactly when nobody is around to clean up.
 */
+ (void)sweepLeftoversIn:(NSString *)destRoot sink:(id<OMProgressSink>)sink
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *entries = [fm directoryContentsAtPath:destRoot];
	unsigned i, n = 0;

	if( [fm fileExistsAtPath:[self stagingRootIn:destRoot]] )
	{
		[fm removeFileAtPath:[self stagingRootIn:destRoot] handler:nil];
		n++;
	}

	for( i = 0; i < [entries count]; i++ )
	{
		NSString *name = [entries objectAtIndex:i];
		/* ".staging" is the pre-container layout; kept so an install interrupted
		 * by an older build of this app is cleaned up by a newer one. */
		if( ![name hasSuffix:@".partial"] && ![name hasSuffix:@".staging"] )
			continue;
		[fm removeFileAtPath:[destRoot stringByAppendingPathComponent:name] handler:nil];
		n++;
	}

	if( n > 0 && sink != nil )
		[sink omLog:[NSString stringWithFormat:
			@"Cleared %u leftover folder(s) from an interrupted run.", n]];
}

/*
 * Download, verify and unpack one mod. Returns the staging directory, which the
 * caller must hand to OMInstaller and then delete.
 */
- (NSString *)stageMod:(NSDictionary *)src into:(NSString *)destRoot error:(NSString **)err
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *gamedir = [src objectForKey:@"mod"];
	NSString *staging = [[OMFetch stagingRootIn:destRoot]
		stringByAppendingPathComponent:gamedir];
	NSString *archive;

	archive = [self ensureArchive:src error:err];
	if( archive == nil )
		return nil;

	if( [fm fileExistsAtPath:staging] )
		[fm removeFileAtPath:staging handler:nil];

	[sink omStatus:[NSString stringWithFormat:@"Unpacking %@...", gamedir]];
	if( !OMExtractArchive( archive, [src objectForKey:@"kind"], [src objectForKey:@"root"],
			staging, sink, err ))
	{
		[fm removeFileAtPath:staging handler:nil];
		return nil;
	}

	/*
	 * A last structural check before this is treated as a mod at all.
	 *
	 * liblist.gam is the file the engine reads to find the game library, and it is
	 * what mods.map, Custom Game and our own liblist rewrite all depend on. An
	 * archive that unpacked "successfully" without one means the `root` in
	 * mod-sources.txt points at the wrong subtree - which is exactly the mistake
	 * that is easy to make and invisible until the mod does not appear in the
	 * menu.
	 */
	if( ![fm fileExistsAtPath:[staging stringByAppendingPathComponent:@"liblist.gam"]] )
	{
		[fm removeFileAtPath:staging handler:nil];
		if( err ) *err = [NSString stringWithFormat:
			@"unpacked %@ but there is no liblist.gam in it - the source's 'root' is wrong",
			gamedir];
		return nil;
	}

	return staging;
}

@end
