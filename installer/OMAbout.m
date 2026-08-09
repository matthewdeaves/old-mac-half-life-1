/*
 * OMAbout.m - the About window, and the one bit of joy in this app.
 *
 * Clicking Gordon plays the scientist's "My God, what are you doing?".
 *
 * WHERE THE SOUND COMES FROM, AND WHY NOT FROM OUR BUNDLE
 *   It is read at runtime out of the player's OWN pak0.pak. We ship no part of
 *   it. That is the same rule that makes the release carry no valve folder: we
 *   ship code, not content. It costs nothing to honour here, because anyone
 *   running this app owns the game by definition - the installer refuses to do
 *   anything at all without a Half-Life.app and a valve folder beside it.
 *
 *   The file is sound/scientist/whatyoudoing.wav: 21,642 bytes, mono, 11025 Hz,
 *   8-bit unsigned PCM, 1.96 seconds. sentences.txt uses it for the SC_PLFEAR0
 *   and SC_SCARED0 groups, which is the panicked-scientist context.
 *
 * THE PAK FORMAT, and the trap in it
 *   Quake/GoldSrc .pak, unchanged since 1996:
 *     header   char magic[4] = "PACK"; int32 dirOffset; int32 dirLength;
 *     entry    char name[56]; int32 filePos; int32 fileLength;   (64 bytes each)
 *
 *   Every one of those integers is LITTLE-ENDIAN ON DISK. Read them with a
 *   straight cast and a PowerPC build gets a directory offset of about 3.4
 *   billion and reads nothing. They are assembled byte by byte below, which is
 *   correct on both architectures and needs no byteswap header.
 */

#import "OldMacMods.h"

/* Assemble a little-endian 32-bit value from bytes. Endian-agnostic by
 * construction: it never dereferences a multi-byte type. */
static unsigned long om_le32( const unsigned char *p )
{
	return   (unsigned long)p[0]
	     | ( (unsigned long)p[1] << 8 )
	     | ( (unsigned long)p[2] << 16 )
	     | ( (unsigned long)p[3] << 24 );
}

/*
 * Pull one entry out of a .pak by name. Returns nil for anything unexpected -
 * missing file, wrong magic, absent entry - because every caller here treats a
 * failure as "do nothing", never as an error worth telling the user about.
 */
NSData *OMPakEntry( NSString *pakPath, NSString *entryName )
{
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:pakPath];
	NSData *header, *dir, *payload = nil;
	const unsigned char *h, *d;
	unsigned long dirOfs, dirLen, count, i;

	if( fh == nil )
		return nil;

	NS_DURING
	{
		header = [fh readDataOfLength:12];
		if( [header length] != 12 )
			[NSException raise:@"om" format:@"short"];

		h = (const unsigned char *)[header bytes];
		if( h[0] != 'P' || h[1] != 'A' || h[2] != 'C' || h[3] != 'K' )
			[NSException raise:@"om" format:@"magic"];

		dirOfs = om_le32( h + 4 );
		dirLen = om_le32( h + 8 );
		if( dirLen == 0 || dirLen > 64UL * 65536UL )
			[NSException raise:@"om" format:@"dir"];

		[fh seekToFileOffset:(unsigned long long)dirOfs];
		dir = [fh readDataOfLength:dirLen];
		if( [dir length] != dirLen )
			[NSException raise:@"om" format:@"shortdir"];

		d = (const unsigned char *)[dir bytes];
		count = dirLen / 64;
		for( i = 0; i < count; i++ )
		{
			const unsigned char *e = d + i * 64;
			char name[57];
			unsigned long pos, len;

			memcpy( name, e, 56 );
			name[56] = 0;
			if( ![entryName isEqualToString:[NSString stringWithUTF8String:name]] )
				continue;

			pos = om_le32( e + 56 );
			len = om_le32( e + 60 );
			if( len == 0 || len > 8UL * 1024UL * 1024UL )
				break;                  /* not something we want to play */

			[fh seekToFileOffset:(unsigned long long)pos];
			payload = [[fh readDataOfLength:len] retain];
			break;
		}
	}
	NS_HANDLER
	{
		payload = nil;                  /* truncated or malformed: silently give up */
	}
	NS_ENDHANDLER

	[fh closeFile];
	return [payload autorelease];
}

/*
 * Play the line, if we can find it. Silent no-op otherwise: an easter egg that
 * complains is not an easter egg.
 *
 * The NSSound is held in a static because -play is asynchronous - releasing it
 * on the way out of this function would cut the sound off after a few
 * milliseconds, or crash. Holding exactly one also means a rapid second click
 * stops the first rather than layering.
 */
void OMPlayPakSound( NSString *gameRoot, NSString *entryName )
{
	static NSSound *sound = nil;
	NSData *wav;

	if( gameRoot == nil || entryName == nil )
		return;

	/*
	 * Exactly ONE sound is ever held, and starting a new one stops the old.
	 *
	 * That is not only about rapid clicking on the About box any more. An install
	 * run can reach two of these events close together - a mod fails, the player
	 * hits Cancel, the run then finishes - and the issue asks specifically that a
	 * cancel mid-install must not stack sounds. Holding one static gives that for
	 * free: whoever speaks last is the only one speaking.
	 */
	if( sound != nil )
	{
		if( [sound isPlaying] )
			[sound stop];
		[sound release];
		sound = nil;
	}

	wav = OMPakEntry( [gameRoot stringByAppendingPathComponent:@"valve/pak0.pak"],
	                  entryName );
	if( wav == nil )
		return;                 /* no game data, or no such line: stay quiet */

	sound = [[NSSound alloc] initWithData:wav];
	[sound play];
}

/*
 * The About box's line, unchanged: the scientist's "My God, what are you doing?"
 * when Gordon is clicked.
 */
void OMPlayScientist( NSString *gameRoot )
{
	OMPlayPakSound( gameRoot, OM_SND_ABOUT );
}
