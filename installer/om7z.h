/*
 * om7z.h - the 7z reader's C interface.
 *
 * Deliberately free of Foundation and of anything Objective-C. See om7z.c.
 */

#ifndef OM_7Z_H
#define OM_7Z_H

#include <stddef.h>

/*
 * Progress and cancellation, passed as plain function pointers so the pure-C
 * side never sees an id or a protocol. OMArchive.m supplies thunks that forward
 * to the OMProgressSink. Any of these may be NULL.
 */
typedef struct
{
	void  *ctx;
	void (*log)( void *ctx, const char *msg );
	void (*progress)( void *ctx, double fraction );   /* 0..1 */
	int  (*cancelled)( void *ctx );                   /* non-zero to stop */
} om7z_sink;

/*
 * Unpack the subtree `root` from `archivePath` into `destDir`.
 *
 * `scratchDir` is where the decoder may put a large temporary file; it must be
 * on a volume with room for the biggest solid block in the archive, which for
 * these mods means up to about half a gigabyte. Pass the install volume.
 *
 * Returns the number of files written, or -1 on failure with a human-readable
 * reason in `errbuf`.
 */
int om7z_extract( const char *archivePath, const char *root, const char *destDir,
	const char *scratchDir, om7z_sink *sink, char *errbuf, size_t errbufSize );

#endif /* OM_7Z_H */
