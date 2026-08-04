/*
 * OMArchive.m - unpack a downloaded mod archive into a staging directory.
 *
 * WHAT THIS IS FOR
 * ----------------
 * The app used to take its content from a mounted .dmg, so "reading the source"
 * was just walking a filesystem. Now each mod arrives as whatever archive its
 * publisher put it in, so something has to open those. The result is written to
 * a staging directory and everything downstream is unchanged: OMInstaller still
 * does the exclusions, the <gamedir>.partial staging, the dylib injection and
 * the liblist.gam rewrite, exactly as it did for a mounted volume.
 *
 * TWO FORMATS, BECAUSE THAT IS WHAT THE SOURCES ACTUALLY ARE
 *   zip   6 of the sourced mods, all from archive.org
 *   7z    the other two thirds, nearly all from runthinkshootlive
 * Neither is optional and neither can be converted away, because we do not host
 * anything and so cannot repackage. See installer/mod-sources.txt.
 *
 * `root` IS NOT COSMETIC
 * ----------------------
 * Almost none of these archives unpack to a folder named after the gamedir the
 * engine expects - asheep ships as `azuresheep`, cc as `caseclosed`, rp as
 * `rp_v1_pub_final1` - and two ship the mod's contents at the archive root with
 * no folder at all. Custom Game, liblist.gam and mods.map all key off the
 * gamedir, so the caller passes the subtree to take and this writes it out flat
 * into the staging directory, which the caller has named after the gamedir.
 *
 * WHY zlib IS VENDORED RATHER THAN LINKED FROM THE SYSTEM
 * ------------------------------------------------------
 * Panther ships libz 1.1.3 (2003) and has no zlib.h on the live system at all.
 * Linking whatever vintage each machine happens to carry would mean the zip path
 * behaves differently on 10.3 than on 10.7 than on macOS 26, in a decoder being
 * fed files off the internet. Vendored and pinned instead, same reasoning as
 * mbedTLS. See vendor/MANIFEST.md.
 */

#import "OldMacMods.h"

#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#include "zlib.h"
#include "omarchive_paths.h"
#include "om7z.h"

#define OM_ZIP_INBUF   65536
#define OM_ZIP_OUTBUF  262144

/* Thin wrapper so the zip reader can keep using NSString paths. The walk itself
 * is in omarchive_paths.h and is plain C, because the Foundation version of it
 * worked on modern macOS and failed on Panther. */
static BOOL om_mkdir_p( NSString *path )
{
	return om_mkdir_p_c( [path fileSystemRepresentation] ) ? YES : NO;
}


/* ================================================================== zip ==== */
/*
 * A deliberately small zip reader: central directory, stored and deflated
 * members, CRC checked. No encryption, no multi-disk, no zip64 - none of which
 * any of our sources use, and all of which are refused by name rather than
 * mis-read.
 */

static BOOL om_extract_zip( NSString *archivePath, const char *root, NSString *destDir,
	id<OMProgressSink> sink, NSString **err )
{
	FILE *f = NULL;
	unsigned char *cd = NULL, *tail = NULL;
	unsigned char *in = NULL, *out = NULL;
	long long fileSize, cdOffset = 0, cdSize = 0;
	long tailLen, i;
	unsigned entries = 0, done = 0, written = 0;
	BOOL ok = NO;

	f = fopen( [archivePath fileSystemRepresentation], "rb" );
	if( f == NULL )
	{
		if( err ) *err = [NSString stringWithFormat:@"cannot open %@", archivePath];
		return NO;
	}
	fseeko( f, 0, SEEK_END );
	fileSize = (long long)ftello( f );

	/*
	 * Find the End Of Central Directory. It is at the very end unless the archive
	 * carries a trailing comment, so scan back over the largest a comment can be
	 * (65535) plus the record itself.
	 */
	tailLen = (long)( fileSize < 65557 ? fileSize : 65557 );
	tail = (unsigned char *)malloc( (size_t)tailLen );
	if( tail == NULL ) { if( err ) *err = @"out of memory"; goto done; }
	fseeko( f, fileSize - tailLen, SEEK_SET );
	if( fread( tail, 1, (size_t)tailLen, f ) != (size_t)tailLen )
	{
		if( err ) *err = @"archive is truncated";
		goto done;
	}

	for( i = tailLen - 22; i >= 0; i-- )
	{
		if( om_le32( tail + i ) == 0x06054b50UL )
		{
			entries  = om_le16( tail + i + 10 );
			cdSize   = (long long)om_le32( tail + i + 12 );
			cdOffset = (long long)om_le32( tail + i + 16 );
			break;
		}
	}
	if( i < 0 )
	{
		if( err ) *err = @"not a zip archive (no end-of-central-directory record)";
		goto done;
	}
	/* 0xffff/0xffffffff are the zip64 escape values. None of our sources are
	 * anywhere near 4 GB or 65535 members, so this means something unexpected
	 * rather than something to support. */
	if( entries == 0xffff || cdOffset == 0xffffffffLL || cdSize == 0xffffffffLL )
	{
		if( err ) *err = @"this archive is zip64, which this app does not read";
		goto done;
	}

	cd = (unsigned char *)malloc( (size_t)cdSize );
	if( cd == NULL ) { if( err ) *err = @"out of memory"; goto done; }
	fseeko( f, cdOffset, SEEK_SET );
	if( fread( cd, 1, (size_t)cdSize, f ) != (size_t)cdSize )
	{
		if( err ) *err = @"archive is truncated (central directory)";
		goto done;
	}

	in  = (unsigned char *)malloc( OM_ZIP_INBUF );
	out = (unsigned char *)malloc( OM_ZIP_OUTBUF );
	if( in == NULL || out == NULL ) { if( err ) *err = @"out of memory"; goto done; }

	{
		long long p = 0;
		while( p + 46 <= cdSize && done < entries )
		{
			unsigned method, nameLen, extraLen, commentLen, flags;
			unsigned long crcWant, compSize, uncompSize, localOff;
			char name[1024];
			const char *rel;
			NSString *outPath;

			if( om_le32( cd + p ) != 0x02014b50UL )
				break;

			flags      = om_le16( cd + p + 8 );
			method     = om_le16( cd + p + 10 );
			crcWant    = om_le32( cd + p + 16 );
			compSize   = om_le32( cd + p + 20 );
			uncompSize = om_le32( cd + p + 24 );
			nameLen    = om_le16( cd + p + 28 );
			extraLen   = om_le16( cd + p + 30 );
			commentLen = om_le16( cd + p + 32 );
			localOff   = om_le32( cd + p + 42 );

			if( nameLen >= sizeof( name )) { if( err ) *err = @"archive has an absurdly long member name"; goto done; }
			memcpy( name, cd + p + 46, nameLen );
			name[nameLen] = 0;
			p += 46 + nameLen + extraLen + commentLen;
			done++;

			/* bit 0 is "encrypted". We cannot read it and must not pretend to. */
			if( flags & 1 )
			{
				if( err ) *err = [NSString stringWithFormat:@"archive member '%s' is encrypted", name];
				goto done;
			}

			om_normalise_seps( name );
			if( !om_name_is_safe( name ))
			{
				if( err ) *err = [NSString stringWithFormat:
					@"archive member '%s' has an unsafe path and was refused", name];
				goto done;
			}

			rel = om_strip_root( name, root );
			if( rel == NULL || rel[0] == 0 )
				continue;                     /* outside the mod root */

			outPath = [destDir stringByAppendingPathComponent:
				[NSString stringWithUTF8String:rel]];

			if( name[nameLen - 1] == '/' )    /* a directory entry */
			{
				om_mkdir_p( outPath );
				continue;
			}
			if( !om_mkdir_p( [outPath stringByDeletingLastPathComponent] ))
			{
				if( err ) *err = [NSString stringWithFormat:@"cannot create %@",
					[outPath stringByDeletingLastPathComponent]];
				goto done;
			}

			if( sink != nil && ( done % 25 ) == 0 )
			{
				if( [sink omCancelled] ) { if( err ) *err = @"cancelled"; goto done; }
				[sink omProgress:(double)done / (double)( entries ? entries : 1 )];
			}

			/* The local header repeats the name and extra field, and its extra
			 * field length can DIFFER from the central directory's. Read it rather
			 * than reusing the value above; getting this wrong offsets every
			 * member by a few bytes and produces plausible-looking garbage. */
			{
				unsigned char lh[30];
				unsigned lNameLen, lExtraLen;
				FILE *of;
				z_stream zs;
				unsigned long crcGot = crc32( 0L, Z_NULL, 0 );
				long long remaining = (long long)compSize;
				int zret = Z_OK;

				fseeko( f, (off_t)localOff, SEEK_SET );
				if( fread( lh, 1, 30, f ) != 30 || om_le32( lh ) != 0x04034b50UL )
				{
					if( err ) *err = [NSString stringWithFormat:@"bad local header for '%s'", name];
					goto done;
				}
				lNameLen  = om_le16( lh + 26 );
				lExtraLen = om_le16( lh + 28 );
				fseeko( f, (off_t)( localOff + 30 + lNameLen + lExtraLen ), SEEK_SET );

				if( method != 0 && method != 8 )
				{
					if( err ) *err = [NSString stringWithFormat:
						@"archive member '%s' uses compression method %u, which this app does not read",
						name, method];
					goto done;
				}

				of = fopen( [outPath fileSystemRepresentation], "wb" );
				if( of == NULL )
				{
					if( err ) *err = [NSString stringWithFormat:@"cannot write %@", outPath];
					goto done;
				}

				memset( &zs, 0, sizeof( zs ));
				if( method == 8 )
				{
					/* Negative windowBits selects raw deflate: a zip member has no
					 * zlib header or trailer around it. */
					if( inflateInit2( &zs, -MAX_WBITS ) != Z_OK )
					{
						fclose( of );
						if( err ) *err = @"could not start the decompressor";
						goto done;
					}
				}

				while( remaining > 0 )
				{
					size_t want = (size_t)( remaining < OM_ZIP_INBUF ? remaining : OM_ZIP_INBUF );
					size_t got = fread( in, 1, want, f );
					if( got == 0 ) break;
					remaining -= (long long)got;

					if( method == 0 )
					{
						crcGot = crc32( crcGot, in, (unsigned)got );
						if( fwrite( in, 1, got, of ) != got ) { zret = Z_ERRNO; break; }
					}
					else
					{
						zs.next_in = in;
						zs.avail_in = (unsigned)got;
						do {
							zs.next_out = out;
							zs.avail_out = OM_ZIP_OUTBUF;
							zret = inflate( &zs, Z_NO_FLUSH );
							if( zret != Z_OK && zret != Z_STREAM_END && zret != Z_BUF_ERROR )
								break;
							{
								size_t have = OM_ZIP_OUTBUF - zs.avail_out;
								if( have > 0 )
								{
									crcGot = crc32( crcGot, out, (unsigned)have );
									if( fwrite( out, 1, have, of ) != have ) { zret = Z_ERRNO; break; }
								}
							}
						} while( zs.avail_out == 0 );
						if( zret != Z_OK && zret != Z_STREAM_END ) break;
					}
				}

				if( method == 8 )
					inflateEnd( &zs );
				fclose( of );

				if( zret != Z_OK && zret != Z_STREAM_END )
				{
					if( err ) *err = [NSString stringWithFormat:@"'%s' did not decompress cleanly", name];
					goto done;
				}
				/*
				 * The CRC is the whole point of doing this ourselves rather than
				 * trusting the transfer. A truncated resume, a bad sector or a
				 * mirror serving a different build all look like a valid archive
				 * until a member fails its checksum.
				 */
				if( crcGot != crcWant )
				{
					if( err ) *err = [NSString stringWithFormat:
						@"'%s' failed its checksum - the download is damaged", name];
					goto done;
				}
				written++;
			}
		}
	}

	if( written == 0 )
	{
		if( err ) *err = [NSString stringWithFormat:
			@"nothing was extracted: no files inside the archive are under '%s'",
			( root && root[0] ? root : "." )];
		goto done;
	}

	if( sink != nil )
		[sink omLog:[NSString stringWithFormat:@"  unpacked %u files", written]];
	ok = YES;

done:
	if( f != NULL ) fclose( f );
	free( tail ); free( cd ); free( in ); free( out );
	return ok;
}

/* =================================================================== 7z ==== */
/*
 * The reader itself is in om7z.c and is pure C. It has to be: on 10.3, Cocoa
 * pulls in Carbon's MacTypes.h, which defines UInt32/UInt16, and the LZMA SDK
 * defines the same names, so gcc-4.0 refuses to compile the two together. These
 * thunks are the whole of the bridge.
 */

static void om_7z_log( void *ctx, const char *msg )
{
	id<OMProgressSink> sink = (id<OMProgressSink>)ctx;
	if( sink != nil )
		[sink omLog:[NSString stringWithUTF8String:msg]];
}

static void om_7z_progress( void *ctx, double fraction )
{
	id<OMProgressSink> sink = (id<OMProgressSink>)ctx;
	if( sink != nil )
		[sink omProgress:fraction];
}

static int om_7z_cancelled( void *ctx )
{
	id<OMProgressSink> sink = (id<OMProgressSink>)ctx;
	return ( sink != nil && [sink omCancelled] ) ? 1 : 0;
}

static BOOL om_extract_7z( NSString *archivePath, const char *root, NSString *destDir,
	id<OMProgressSink> sink, NSString **err )
{
	om7z_sink cb;
	char errbuf[1024];
	int n;

	cb.ctx       = (void *)sink;
	cb.log       = om_7z_log;
	cb.progress  = om_7z_progress;
	cb.cancelled = om_7z_cancelled;

	/*
	 * The scratch directory is the staging directory's own parent, so the
	 * decoder's temp file lands on the volume the caller already free-space
	 * checked rather than on whatever /tmp happens to be.
	 */
	n = om7z_extract( [archivePath fileSystemRepresentation], root,
		[destDir fileSystemRepresentation],
		[[destDir stringByDeletingLastPathComponent] fileSystemRepresentation],
		&cb, errbuf, sizeof( errbuf ));

	if( n < 0 )
	{
		if( err ) *err = [NSString stringWithUTF8String:( errbuf[0] ? errbuf : "unknown error" )];
		return NO;
	}
	if( sink != nil )
		[sink omLog:[NSString stringWithFormat:@"  unpacked %d files", n]];
	return YES;
}

/* ============================================================== dispatch ==== */

BOOL OMExtractArchive( NSString *archivePath, NSString *kind, NSString *root,
	NSString *destDir, id<OMProgressSink> sink, NSString **err )
{
	const char *croot = ( root != nil ? [root UTF8String] : "." );

	if( !om_mkdir_p( destDir ))
	{
		if( err ) *err = [NSString stringWithFormat:@"cannot create %@", destDir];
		return NO;
	}

	if( [kind isEqualToString:@"zip"] )
		return om_extract_zip( archivePath, croot, destDir, sink, err );

	if( [kind isEqualToString:@"7z"] )
		return om_extract_7z( archivePath, croot, destDir, sink, err );

	if( err ) *err = [NSString stringWithFormat:@"unknown archive kind '%@'", kind];
	return NO;
}
