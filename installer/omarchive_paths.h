/*
 * omarchive_paths.h - path handling shared by the zip and 7z readers.
 *
 * Header-only and every function static, because the two readers cannot share a
 * translation unit: the 7z one has to be pure C (see om7z.c for why) and the zip
 * one is Objective-C. Duplicating a few hundred bytes of code in two objects is
 * the cheap half of that trade.
 *
 * Nothing here touches Foundation. That is deliberate and load-bearing: the
 * first version of the mkdir walk used -pathComponents and
 * -stringByAppendingPathComponent:, worked on modern macOS, and failed on
 * Panther with "cannot create /tmp/xt/noffice" because 10.3 does not reassemble
 * a leading "/" component the same way. Plain C behaves identically from 10.3
 * to 26, which is the property this whole app is built on.
 */

#ifndef OM_ARCHIVE_PATHS_H
#define OM_ARCHIVE_PATHS_H

#include <sys/stat.h>
#include <string.h>
#include <errno.h>

/* ---------------------------------------------------------- little-endian -- */
/*
 * Zip is little-endian on the wire and half this fleet is big-endian, so every
 * field is assembled byte by byte rather than cast through a struct. A struct
 * overlay would also be misaligned: zip headers are packed to no alignment at
 * all, and an unaligned 32-bit load is a bus error on ppc, not a slow path.
 */
static unsigned om_le16( const unsigned char *p )
{
	return (unsigned)p[0] | ((unsigned)p[1] << 8 );
}

static unsigned long om_le32( const unsigned char *p )
{
	return (unsigned long)p[0] | ((unsigned long)p[1] << 8 )
	     | ((unsigned long)p[2] << 16 ) | ((unsigned long)p[3] << 24 );
}

/* ------------------------------------------------------------ path safety -- */
/*
 * These archives come off the public internet, so a member name is untrusted
 * input. A name containing ".." or a leading "/" would let an archive write
 * outside the staging directory - over the player's valve/, or anywhere else
 * they can write. Rejected outright rather than sanitised, because a mod archive
 * has no legitimate reason to contain one, and quietly rewriting the path would
 * hide a source worth looking at.
 *
 * Backslashes are normalised to '/' first: zip stores forward slashes by spec,
 * but plenty of old Windows tools wrote backslashes anyway, and "..\\.." has to
 * be caught by the same test.
 */
static int om_name_is_safe( const char *name )
{
	const char *p;

	if( name == NULL || name[0] == 0 )
		return 0;
	if( name[0] == '/' || name[0] == '\\' )
		return 0;
	if( name[0] != 0 && name[1] == ':' )    /* a drive letter, from a Windows packer */
		return 0;

	for( p = name; *p; p++ )
	{
		if(( p[0] == '.' && p[1] == '.' ) &&
		   ( p[2] == '/' || p[2] == '\\' || p[2] == 0 ) &&
		   ( p == name || p[-1] == '/' || p[-1] == '\\' ))
			return 0;
	}
	return 1;
}

static void om_normalise_seps( char *s )
{
	for( ; *s; s++ )
		if( *s == '\\' ) *s = '/';
}

/*
 * Strip the `root` prefix. Returns a pointer into `name` at the start of the
 * path relative to the mod root, or NULL if this member sits outside it and
 * should be skipped. A `root` of "." means the archive root is already the mod
 * root.
 *
 * The trailing checks matter: without them a root of "cc" would also swallow a
 * sibling directory called "ccx".
 */
static const char *om_strip_root( const char *name, const char *root )
{
	size_t rl;

	if( root == NULL || root[0] == 0 || strcmp( root, "." ) == 0 )
		return name;

	rl = strlen( root );
	if( strncmp( name, root, rl ) != 0 )
		return NULL;
	if( name[rl] == '/' )
		return name + rl + 1;
	return NULL;                 /* the root entry itself, or a common-prefix sibling */
}

/* mkdir -p over a C string. Returns 1 on success. */
static int om_mkdir_p_c( const char *path )
{
	char buf[2048];
	size_t i, n;

	if( path == NULL )
		return 0;
	n = strlen( path );
	if( n == 0 || n >= sizeof( buf ))
		return 0;
	memcpy( buf, path, n + 1 );

	/* start at 1 so a leading '/' is never mkdir'd on its own */
	for( i = 1; i <= n; i++ )
	{
		char saved;
		if( buf[i] != '/' && buf[i] != 0 )
			continue;
		saved = buf[i];
		buf[i] = 0;
		if( mkdir( buf, 0755 ) != 0 && errno != EEXIST )
			return 0;
		buf[i] = saved;
	}
	return 1;
}

/* Join dir + "/" + rel into buf. Returns 1 on success, 0 if it would overflow. */
static int om_join( char *buf, size_t bufSize, const char *dir, const char *rel )
{
	size_t dl = strlen( dir ), rl = strlen( rel );
	if( dl + 1 + rl + 1 > bufSize )
		return 0;
	memcpy( buf, dir, dl );
	buf[dl] = '/';
	memcpy( buf + dl + 1, rel, rl + 1 );
	return 1;
}

/* Copy the parent directory of `path` into buf. */
static int om_parent( char *buf, size_t bufSize, const char *path )
{
	const char *slash = strrchr( path, '/' );
	size_t n;

	if( slash == NULL )
		return 0;
	n = (size_t)( slash - path );
	if( n + 1 > bufSize )
		return 0;
	memcpy( buf, path, n );
	buf[n] = 0;
	return 1;
}

#endif /* OM_ARCHIVE_PATHS_H */
