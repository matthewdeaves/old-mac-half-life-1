/*
 * OMUtil.m - small process, filesystem and checksum helpers.
 *
 * These used to live in OMDiskImage.m, which attached the single 2.7 GB mod disk
 * image with hdiutil. That file is gone: the app now fetches each mod from its
 * own publisher rather than pulling one bundle somebody else assembled, so there
 * is no disk image to mount, no -puppetstrings progress to scrape and no
 * Panther-specific attach fallback to maintain. The general-purpose parts of it
 * are still needed and are here.
 *
 * fork/execv + waitpid rather than NSTask, for one reason: we need a child's
 * EXIT STATUS and its stdout, reliably, from 10.3 through modern macOS. NSTask's
 * behaviour around termination status and pipe draining shifted over that span.
 * waitpid did not.
 */

#import "OldMacMods.h"

#include <sys/types.h>
#include <sys/wait.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/select.h>
#include <sys/time.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>

/* Run a command, capture stdout, return its exit status (-1 if it never ran). */
static int om_run( const char *path, char *const argv[], NSMutableString *output )
{
	int fds[2];
	pid_t pid;
	int status = -1;

	if( pipe( fds ) != 0 )
		return -1;

	pid = fork();
	if( pid < 0 )
	{
		close( fds[0] );
		close( fds[1] );
		return -1;
	}
	if( pid == 0 )
	{
		close( fds[0] );
		dup2( fds[1], STDOUT_FILENO );
		dup2( fds[1], STDERR_FILENO );
		close( fds[1] );
		execv( path, argv );
		_exit( 127 );
	}

	/* Drain before waiting, or a chatty child fills the pipe and we deadlock. */
	close( fds[1] );
	{
		char buf[1024];
		ssize_t r;

		while(( r = read( fds[0], buf, sizeof( buf ) - 1 )) > 0 )
		{
			NSString *chunk;
			buf[r] = 0;
			chunk = [NSString stringWithUTF8String:buf];
			if( chunk != nil && output != nil )
				[output appendString:chunk];
		}
	}
	close( fds[0] );

	if( waitpid( pid, &status, 0 ) < 0 )
		return -1;
	return WIFEXITED( status ) ? WEXITSTATUS( status ) : -1;
}

int OMRunCommand( const char *path, char *const argv[], NSMutableString *output )
{
	return om_run( path, argv, output );
}

/* ------------------------------------------------------------ free space -- */
/*
 * statfs() rather than NSFileManager's volume attributes: -[NSFileManager
 * attributesOfFileSystemForPath:error:] is 10.5+, and the 10.3-era
 * fileSystemAttributesAtPath: reports NSFileSystemFreeSize as an NSNumber that
 * was 32-bit-limited on early systems. f_bavail * f_bsize is unambiguous.
 */
long long OMFreeSpaceAt( NSString *path )
{
	struct statfs st;

	if( path == nil )
		return -1;
	if( statfs( [path fileSystemRepresentation], &st ) != 0 )
		return -1;
	return (long long)st.f_bavail * (long long)st.f_bsize;
}

/*
 * Is `path` on a read-only volume?
 *
 * The case this exists for is someone double-clicking either app straight off
 * the mounted disk image. Everything looks normal until the first write: the
 * installer has nowhere to put 4 GB of mods, and the game cannot write its
 * config, its save games or even its own log. Better to say so at launch than
 * to fail obscurely later.
 *
 * MNT_RDONLY on the containing filesystem catches a mounted .dmg, a read-only
 * network share and a locked disk alike.
 */
BOOL OMPathIsReadOnly( NSString *path )
{
	struct statfs st;

	if( path == nil )
		return NO;
	if( statfs( [path fileSystemRepresentation], &st ) != 0 )
		return NO;                        /* unknown: do not block the user */
	return ( st.f_flags & MNT_RDONLY ) ? YES : NO;
}

/*
 * Can we actually install into this folder?
 *
 * The only hard requirement on a chosen install folder. Everything else about
 * where mods go is the user's call: they may install beside the game, on another
 * volume, or somewhere they intend to move later. But a folder that cannot be
 * written to fails after the first download rather than before it, which on these
 * machines can be a long wait for nothing.
 *
 * The read-only check catches a mounted disk image or a locked volume; the access
 * check catches an ordinary folder somebody else owns. Both are needed: a
 * writable filesystem says nothing about one directory on it.
 */
BOOL OMPathIsWritableDirectory( NSString *path )
{
	BOOL isdir = NO;

	if( path == nil )
		return NO;
	if( ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isdir] || !isdir )
		return NO;
	if( OMPathIsReadOnly( path ))
		return NO;
	return ( access( [path fileSystemRepresentation], W_OK | X_OK ) == 0 ) ? YES : NO;
}

/* ------------------------------------------------------------------- md5 -- */
/*
 * The download runs over plain HTTP, which is unauthenticated and, on these
 * machines, unavoidable. Checking the md5 published on the source page is
 * therefore not optional - it is the only thing standing between a corrupted or
 * substituted 2.5 GB download and an install.
 *
 * /sbin/md5 ships with every macOS from 10.0 onward. CommonCrypto's CC_MD5 would
 * avoid the fork, but it only arrived in 10.4.
 */
NSString *OMFileMD5( NSString *path )
{
	NSMutableString *out = [NSMutableString string];
	char *argv[4];
	int rc;
	NSString *trimmed;

	if( path == nil )
		return nil;

	argv[0] = (char *)"md5";
	argv[1] = (char *)"-q";
	argv[2] = (char *)[path fileSystemRepresentation];
	argv[3] = NULL;

	rc = OMRunCommand( "/sbin/md5", argv, out );
	if( rc != 0 )
		return nil;

	trimmed = [out stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if( [trimmed length] != 32 )
		return nil;
	return [trimmed lowercaseString];
}

/* -------------------------------------------------- md5, with a progress bar -- */
/*
 * RFC 1321 MD5, implemented here rather than called out to.
 *
 * WHY NOT CommonCrypto: CC_MD5 arrived in 10.4. This app runs on 10.3.
 * WHY NOT /sbin/md5 (which we do still use, above): it prints one line when it
 * has finished and nothing before that, so it cannot move a progress bar. On a
 * G3 chewing through a few hundred megabytes that is minutes of silence, which reads
 * as a hang. See OMFileMD5Progress at the bottom for the whole reason this is
 * here.
 *
 * Endianness matters and is handled explicitly: MD5 defines its message block as
 * little-endian 32-bit words and its digest as little-endian output. Every load
 * and store below assembles bytes by hand, so this is correct on the PowerPC
 * slice as well as the Intel one. A memcpy of the block into uint32_t would work
 * on Intel and quietly produce wrong digests on PPC.
 */

typedef struct {
	uint32_t state[4];
	uint64_t count;            /* message length in BYTES */
	unsigned char buf[64];
} om_md5_ctx;

#define OM_ROTL( x, c ) ( ( (x) << (c) ) | ( (x) >> ( 32 - (c) ) ) )

static const uint32_t om_md5_k[64] = {
	0xd76aa478u, 0xe8c7b756u, 0x242070dbu, 0xc1bdceeeu,
	0xf57c0fafu, 0x4787c62au, 0xa8304613u, 0xfd469501u,
	0x698098d8u, 0x8b44f7afu, 0xffff5bb1u, 0x895cd7beu,
	0x6b901122u, 0xfd987193u, 0xa679438eu, 0x49b40821u,
	0xf61e2562u, 0xc040b340u, 0x265e5a51u, 0xe9b6c7aau,
	0xd62f105du, 0x02441453u, 0xd8a1e681u, 0xe7d3fbc8u,
	0x21e1cde6u, 0xc33707d6u, 0xf4d50d87u, 0x455a14edu,
	0xa9e3e905u, 0xfcefa3f8u, 0x676f02d9u, 0x8d2a4c8au,
	0xfffa3942u, 0x8771f681u, 0x6d9d6122u, 0xfde5380cu,
	0xa4beea44u, 0x4bdecfa9u, 0xf6bb4b60u, 0xbebfbc70u,
	0x289b7ec6u, 0xeaa127fau, 0xd4ef3085u, 0x04881d05u,
	0xd9d4d039u, 0xe6db99e5u, 0x1fa27cf8u, 0xc4ac5665u,
	0xf4292244u, 0x432aff97u, 0xab9423a7u, 0xfc93a039u,
	0x655b59c3u, 0x8f0ccc92u, 0xffeff47du, 0x85845dd1u,
	0x6fa87e4fu, 0xfe2ce6e0u, 0xa3014314u, 0x4e0811a1u,
	0xf7537e82u, 0xbd3af235u, 0x2ad7d2bbu, 0xeb86d391u
};

static const unsigned char om_md5_r[64] = {
	7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,
	5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,
	4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,
	6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21
};

static void om_md5_init( om_md5_ctx *c )
{
	c->state[0] = 0x67452301u;
	c->state[1] = 0xefcdab89u;
	c->state[2] = 0x98badcfeu;
	c->state[3] = 0x10325476u;
	c->count = 0;
}

static void om_md5_block( om_md5_ctx *c, const unsigned char *p )
{
	uint32_t m[16], a, b, d, dd, f, tmp;
	int i, g;

	/* Explicit little-endian assembly: correct on PPC and on Intel alike. */
	for( i = 0; i < 16; i++ )
		m[i] = (uint32_t)p[i * 4]
		     | ( (uint32_t)p[i * 4 + 1] << 8 )
		     | ( (uint32_t)p[i * 4 + 2] << 16 )
		     | ( (uint32_t)p[i * 4 + 3] << 24 );

	a = c->state[0]; b = c->state[1]; d = c->state[2]; dd = c->state[3];

	for( i = 0; i < 64; i++ )
	{
		if( i < 16 )       { f = ( b & d ) | ( ~b & dd );      g = i; }
		else if( i < 32 )  { f = ( dd & b ) | ( ~dd & d );     g = ( 5 * i + 1 ) & 15; }
		else if( i < 48 )  { f = b ^ d ^ dd;                   g = ( 3 * i + 5 ) & 15; }
		else               { f = d ^ ( b | ~dd );              g = ( 7 * i ) & 15; }

		tmp = dd;
		dd = d;
		d = b;
		b = b + OM_ROTL( a + f + om_md5_k[i] + m[g], om_md5_r[i] );
		a = tmp;
	}

	c->state[0] += a; c->state[1] += b; c->state[2] += d; c->state[3] += dd;
}

static void om_md5_update( om_md5_ctx *c, const unsigned char *p, size_t n )
{
	size_t have = (size_t)( c->count & 63 );
	size_t need;

	c->count += n;

	if( have )
	{
		need = 64 - have;
		if( n < need )
		{
			memcpy( c->buf + have, p, n );
			return;
		}
		memcpy( c->buf + have, p, need );
		om_md5_block( c, c->buf );
		p += need; n -= need;
	}

	while( n >= 64 )
	{
		om_md5_block( c, p );
		p += 64; n -= 64;
	}

	if( n )
		memcpy( c->buf, p, n );
}

static void om_md5_final( om_md5_ctx *c, unsigned char out[16] )
{
	uint64_t bits = c->count * 8;
	size_t have = (size_t)( c->count & 63 );
	unsigned char pad[72];
	size_t padlen;
	int i;

	/* 0x80, then zeroes, so that length-in-bits lands in the last 8 bytes. */
	padlen = ( have < 56 ) ? ( 56 - have ) : ( 120 - have );
	memset( pad, 0, sizeof( pad ) );
	pad[0] = 0x80;
	for( i = 0; i < 8; i++ )
		pad[padlen + i] = (unsigned char)( ( bits >> ( 8 * i ) ) & 0xff );

	om_md5_update( c, pad, padlen + 8 );

	for( i = 0; i < 4; i++ )
	{
		out[i * 4]     = (unsigned char)(   c->state[i]         & 0xff );
		out[i * 4 + 1] = (unsigned char)( ( c->state[i] >> 8 )  & 0xff );
		out[i * 4 + 2] = (unsigned char)( ( c->state[i] >> 16 ) & 0xff );
		out[i * 4 + 3] = (unsigned char)( ( c->state[i] >> 24 ) & 0xff );
	}
}

/*
 * 1 MB reads. Big enough that the per-read overhead vanishes even on a G3's
 * disk, small enough that cancel is noticed promptly and the bar moves smoothly.
 */
#define OM_MD5_CHUNK ( 1024 * 1024 )

NSString *OMFileMD5Progress( NSString *path, id<OMProgressSink> sink )
{
	NSFileHandle *fh;
	om_md5_ctx ctx;
	unsigned char digest[16];
	unsigned long long total = 0, done = 0;
	NSDictionary *attrs;
	NSMutableString *hex;
	double lastShown = -1.0;
	int i;

	if( path == nil )
		return nil;

	/* NSFileSize is an NSNumber, so -longLongValue, not OMLongLong(). OMLongLong
	 * takes an NSString and sends it -UTF8String, which an NSNumber does not
	 * answer: the call raised NSInvalidArgumentException and killed the process
	 * on the first line of this function. NSNumber's -longLongValue is 10.0 API;
	 * the 10.5 addition OMLongLong() exists to avoid is NSString's. */
	attrs = [[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:YES];
	if( attrs != nil )
		total = [[attrs objectForKey:NSFileSize] longLongValue];

	fh = [NSFileHandle fileHandleForReadingAtPath:path];
	if( fh == nil )
		return nil;

	om_md5_init( &ctx );

	for(;;)
	{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSData *chunk = nil;
		double frac;

		/* -readDataOfLength: raises on I/O error rather than returning nil. */
		NS_DURING
			chunk = [fh readDataOfLength:OM_MD5_CHUNK];
		NS_HANDLER
			chunk = nil;
		NS_ENDHANDLER

		if( chunk == nil )
		{
			[pool release];
			[fh closeFile];
			return nil;
		}
		if( [chunk length] == 0 )
		{
			[pool release];
			break;
		}

		om_md5_update( &ctx, (const unsigned char *)[chunk bytes], [chunk length] );
		done += [chunk length];

		if( sink != nil && [sink omCancelled] )
		{
			[pool release];
			[fh closeFile];
			return nil;
		}

		/* Only touch the UI when the rounded percentage actually changes. */
		if( sink != nil && total > 0 )
		{
			frac = (double)done / (double)total;
			if( frac - lastShown >= 0.01 )
			{
				[sink omProgress:frac];
				lastShown = frac;
			}
		}
		[pool release];
	}

	[fh closeFile];
	om_md5_final( &ctx, digest );

	hex = [NSMutableString stringWithCapacity:32];
	for( i = 0; i < 16; i++ )
		[hex appendFormat:@"%02x", digest[i]];
	return hex;
}
