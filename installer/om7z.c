/*
 * om7z.c - read a .7z archive. Two thirds of the mods arrive in this format.
 *
 * WHY THIS IS PURE C AND NOT PART OF OMArchive.m
 * ----------------------------------------------
 * On 10.3, including Cocoa drags in Carbon's MacTypes.h, which defines UInt32,
 * UInt16 and friends. The LZMA SDK's 7zTypes.h defines the same names. Put both
 * in one translation unit and gcc-4.0 stops with
 *
 *   7zTypes.h:182: error: conflicting types for 'UInt32'
 *   MacTypes.h:72: error: previous declaration of 'UInt32' was here
 *
 * which does not happen on the Intel slice, because the 10.7 SDK's Cocoa does
 * not pull Carbon in the same way. Rather than fight it with #defines, the
 * decoder simply never meets Foundation: this file is C, talks to the caller
 * through function pointers (om7z.h), and OMArchive.m supplies the thunks.
 *
 * THE MEMORY PROBLEM, WHICH IS THE ONLY INTERESTING PART
 * -----------------------------------------------------
 * These archives are SOLID: one LZMA stream covers many files, so a member
 * cannot be decoded without decoding everything before it in its block.
 * Measured on the real downloads - xenwar puts 122 files and 25 MB of output in
 * a single block, and echoes unpacks to 450 MB.
 *
 * SzArEx_Extract decodes an entire block into one buffer from `allocMain` and
 * reuses it for later files in that block. Right for a desktop, wrong for the
 * target: a 450 MB allocation on a 448 MB G3 either fails or thrashes the
 * machine to a standstill.
 *
 * The fix is not to rewrite the decoder. It is to change where that buffer
 * lives. om_alloc_big() backs any large request with a temp file on the install
 * volume and mmaps it, so the pages are paged to disk by the kernel instead of
 * pinned in RAM, and cold parts of an already-decoded block cost nothing. The
 * decoder receives an ordinary pointer and neither knows nor cares. Resident
 * memory then tracks the LZMA dictionary (32 MB in these archives) rather than
 * the block size.
 *
 * The scratch file is unlinked the moment it is created, so a crash or a
 * force-quit part way through a 450 MB unpack cannot leave it behind.
 */

#include "om7z.h"
#include "omarchive_paths.h"

#include "7z.h"
#include "7zAlloc.h"
#include "7zCrc.h"
#include "7zFile.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>

#define OM_MMAP_THRESHOLD  ( 16u * 1024u * 1024u )
#define OM_7Z_INBUF        ( 1 << 18 )
#define OM_MAX_MAPS        4

/* ------------------------------------------------- the disk-backed allocator -- */

typedef struct
{
	ISzAlloc   vt;
	const char *scratchDir;
	struct { void *addr; size_t size; } maps[OM_MAX_MAPS];
} OMBigAlloc;

static void *om_alloc_big( ISzAllocPtr p, size_t size )
{
	OMBigAlloc *a = (OMBigAlloc *)p;
	char tmpl[1200];
	int fd, i;
	void *addr;

	if( size == 0 )
		return NULL;
	if( size < OM_MMAP_THRESHOLD )
		return malloc( size );

	for( i = 0; i < OM_MAX_MAPS; i++ )
		if( a->maps[i].addr == NULL ) break;
	if( i == OM_MAX_MAPS )
		return malloc( size );          /* table full: fall back rather than fail */

	snprintf( tmpl, sizeof( tmpl ), "%s/.om-unpack-XXXXXX", a->scratchDir );
	fd = mkstemp( tmpl );
	if( fd < 0 )
		return malloc( size );

	/* The mapping keeps the inode alive; nothing survives on disk if we die. */
	unlink( tmpl );

	if( ftruncate( fd, (off_t)size ) != 0 )
	{
		close( fd );
		return malloc( size );
	}

	addr = mmap( NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0 );
	close( fd );                        /* the mapping holds its own reference */
	if( addr == MAP_FAILED )
		return malloc( size );

	a->maps[i].addr = addr;
	a->maps[i].size = size;
	return addr;
}

static void om_free_big( ISzAllocPtr p, void *addr )
{
	OMBigAlloc *a = (OMBigAlloc *)p;
	int i;

	if( addr == NULL )
		return;
	for( i = 0; i < OM_MAX_MAPS; i++ )
	{
		if( a->maps[i].addr == addr )
		{
			munmap( addr, a->maps[i].size );
			a->maps[i].addr = NULL;
			a->maps[i].size = 0;
			return;
		}
	}
	free( addr );
}

/* ------------------------------------------------------------------ names -- */
/*
 * 7z stores names as UTF-16. Converted by hand rather than through any
 * framework, because the result is handed straight to open(2) and because this
 * has to behave the same on 10.3 as on 26. Surrogate pairs are handled: none of
 * these archives contain one, but a silent mis-decode would produce a filename
 * that looks right in a listing and does not match what the engine opens.
 */
static void om_utf16_to_utf8( const UInt16 *src, char *dst, size_t dstSize )
{
	size_t o = 0;

	while( *src && o + 5 < dstSize )
	{
		unsigned long c = *src++;

		if( c >= 0xD800 && c <= 0xDBFF && *src >= 0xDC00 && *src <= 0xDFFF )
		{
			unsigned long lo = *src++;
			c = 0x10000 + (( c - 0xD800 ) << 10 ) + ( lo - 0xDC00 );
		}

		if( c < 0x80 )
			dst[o++] = (char)c;
		else if( c < 0x800 )
		{
			dst[o++] = (char)( 0xC0 | ( c >> 6 ));
			dst[o++] = (char)( 0x80 | ( c & 0x3F ));
		}
		else if( c < 0x10000 )
		{
			dst[o++] = (char)( 0xE0 | ( c >> 12 ));
			dst[o++] = (char)( 0x80 | (( c >> 6 ) & 0x3F ));
			dst[o++] = (char)( 0x80 | ( c & 0x3F ));
		}
		else
		{
			dst[o++] = (char)( 0xF0 | ( c >> 18 ));
			dst[o++] = (char)( 0x80 | (( c >> 12 ) & 0x3F ));
			dst[o++] = (char)( 0x80 | (( c >> 6 ) & 0x3F ));
			dst[o++] = (char)( 0x80 | ( c & 0x3F ));
		}
	}
	dst[o] = 0;
}

/* --------------------------------------------------------------- extract -- */

int om7z_extract( const char *archivePath, const char *root, const char *destDir,
	const char *scratchDir, om7z_sink *sink, char *errbuf, size_t errbufSize )
{
	CFileInStream archiveStream;
	CLookToRead2  lookStream;
	CSzArEx       db;
	OMBigAlloc    big;
	ISzAlloc      allocTemp = { SzAllocTemp, SzFreeTemp };
	SRes     res;
	UInt32   i, blockIndex = 0xFFFFFFFF;
	Byte    *outBuffer = NULL;
	size_t   outBufferSize = 0;
	int      written = 0, result = -1, opened = 0;
	UInt16  *nameBuf = NULL;
	char    *name = NULL;
	char     outPath[2048], parent[2048];

	if( errbuf && errbufSize ) errbuf[0] = 0;

	memset( &big, 0, sizeof( big ));
	big.vt.Alloc   = om_alloc_big;
	big.vt.Free    = om_free_big;
	big.scratchDir = scratchDir;

	/* The SDK builds its CRC table lazily and never on its own. Without this
	 * every member "fails" its checksum, which reads exactly like a corrupt
	 * download. */
	CrcGenerateTable();

	FileInStream_CreateVTable( &archiveStream );
	LookToRead2_CreateVTable( &lookStream, False );
	lookStream.buf = NULL;

	if( InFile_Open( &archiveStream.file, archivePath ))
	{
		if( errbuf ) snprintf( errbuf, errbufSize, "cannot open %s", archivePath );
		return -1;
	}

	lookStream.buf = (Byte *)malloc( OM_7Z_INBUF );
	if( lookStream.buf == NULL )
	{
		File_Close( &archiveStream.file );
		if( errbuf ) snprintf( errbuf, errbufSize, "out of memory" );
		return -1;
	}
	lookStream.bufSize    = OM_7Z_INBUF;
	lookStream.realStream = &archiveStream.vt;
	LookToRead2_INIT( &lookStream );

	SzArEx_Init( &db );
	res = SzArEx_Open( &db, &lookStream.vt, &big.vt, &allocTemp );
	if( res != SZ_OK )
	{
		if( errbuf ) snprintf( errbuf, errbufSize, "this file is not a readable 7z archive" );
		goto done;
	}
	opened = 1;

	nameBuf = (UInt16 *)malloc( 2048 * sizeof( UInt16 ));
	name    = (char *)malloc( 4096 );
	if( nameBuf == NULL || name == NULL )
	{
		if( errbuf ) snprintf( errbuf, errbufSize, "out of memory" );
		goto done;
	}

	for( i = 0; i < db.NumFiles; i++ )
	{
		const char *rel;
		size_t offset = 0, outSizeProcessed = 0, nameLen;
		FILE *of;

		if( sink != NULL && ( i % 25 ) == 0 )
		{
			if( sink->cancelled != NULL && sink->cancelled( sink->ctx ))
			{
				if( errbuf ) snprintf( errbuf, errbufSize, "cancelled" );
				goto done;
			}
			if( sink->progress != NULL )
				sink->progress( sink->ctx,
					(double)i / (double)( db.NumFiles ? db.NumFiles : 1 ));
		}

		nameLen = SzArEx_GetFileNameUtf16( &db, i, NULL );
		if( nameLen == 0 || nameLen > 2048 )
			continue;
		SzArEx_GetFileNameUtf16( &db, i, nameBuf );
		om_utf16_to_utf8( nameBuf, name, 4096 );
		om_normalise_seps( name );

		if( !om_name_is_safe( name ))
		{
			if( errbuf ) snprintf( errbuf, errbufSize,
				"archive member '%s' has an unsafe path and was refused", name );
			goto done;
		}

		rel = om_strip_root( name, root );
		if( rel == NULL || rel[0] == 0 )
			continue;

		if( !om_join( outPath, sizeof( outPath ), destDir, rel ))
			continue;                       /* absurdly deep path; not ours to fix */

		if( SzArEx_IsDir( &db, i ))
		{
			om_mkdir_p_c( outPath );
			continue;
		}
		if( om_parent( parent, sizeof( parent ), outPath ) && !om_mkdir_p_c( parent ))
		{
			if( errbuf ) snprintf( errbuf, errbufSize, "cannot create %s", parent );
			goto done;
		}

		/*
		 * Decodes the whole solid block the first time any file in it is asked
		 * for, then reuses it. That is why iterating in archive order matters:
		 * out of order, every file would re-decode its block. CRCs are verified
		 * inside the SDK, so a damaged download fails here rather than writing a
		 * file of the right length and the wrong contents.
		 */
		res = SzArEx_Extract( &db, &lookStream.vt, i, &blockIndex,
			&outBuffer, &outBufferSize, &offset, &outSizeProcessed,
			&big.vt, &allocTemp );
		if( res != SZ_OK )
		{
			if( errbuf )
			{
				if( res == SZ_ERROR_CRC )
					snprintf( errbuf, errbufSize,
						"'%s' failed its checksum - the download is damaged", name );
				else if( res == SZ_ERROR_MEM )
					snprintf( errbuf, errbufSize,
						"not enough memory to unpack '%s'", name );
				else
					snprintf( errbuf, errbufSize, "'%s' could not be decompressed", name );
			}
			goto done;
		}

		of = fopen( outPath, "wb" );
		if( of == NULL )
		{
			if( errbuf ) snprintf( errbuf, errbufSize, "cannot write %s", outPath );
			goto done;
		}
		if( outSizeProcessed > 0 &&
		    fwrite( outBuffer + offset, 1, outSizeProcessed, of ) != outSizeProcessed )
		{
			fclose( of );
			if( errbuf ) snprintf( errbuf, errbufSize, "write failed (disk full?)" );
			goto done;
		}
		fclose( of );
		written++;
	}

	if( written == 0 )
	{
		if( errbuf ) snprintf( errbuf, errbufSize,
			"nothing was extracted: no files inside the archive are under '%s'",
			( root && root[0] ? root : "." ));
		goto done;
	}

	result = written;

done:
	if( outBuffer != NULL )
		om_free_big( &big.vt, outBuffer );
	if( opened )
		SzArEx_Free( &db, &big.vt );
	free( nameBuf );
	free( name );
	free( lookStream.buf );
	File_Close( &archiveStream.file );
	return result;
}
