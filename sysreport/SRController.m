/*
 * SRController.m - gather the report and show it.
 *
 * Everything here is read-only: sysctl, a few system files, and one offscreen
 * OpenGL context. Nothing is sent anywhere; the user copies the text and decides
 * what to do with it.
 */

#import "SRController.h"

#include <sys/types.h>
#include <sys/sysctl.h>
#include <mach/machine.h>

#import <OpenGL/OpenGL.h>

/* ------------------------------------------------------------------- pak -- */
/*
 * A .pak reader, so clicking the picture plays a line the way the mod
 * installer's About box does. Issue #11.
 *
 * WE SHIP NO AUDIO. The wav is read out of the PLAYER's own valve/pak0.pak at
 * the moment it is wanted, and every failure here is silent: no game data, no
 * pak, no such entry, all mean "do nothing". An easter egg that complains is
 * not an easter egg, and this app in particular is run by someone whose machine
 * is already misbehaving.
 *
 * Deliberately duplicated from installer/OMAbout.m rather than shared. The two
 * apps are separate bundles built by separate drivers from separate source
 * lists, with no library between them; the alternative was to make this app
 * depend on the installer's headers and pull in its whole world for sixty lines
 * of file format. The format is Quake's, from 1996, and is not going to move.
 *
 * PAK LAYOUT
 *   header   char id[4] = "PACK"; int32 dirOfs; int32 dirLen;
 *   entry    char name[56]; int32 filePos; int32 fileLength;   (64 bytes each)
 *
 * Every integer is LITTLE-ENDIAN ON DISK. Read with a straight cast, a PowerPC
 * build gets a directory offset of about 3.4 billion and finds nothing. They
 * are assembled byte by byte below, which is correct on both architectures.
 */
static unsigned long sr_le32( const unsigned char *p )
{
	return   (unsigned long)p[0]
	     | ( (unsigned long)p[1] << 8 )
	     | ( (unsigned long)p[2] << 16 )
	     | ( (unsigned long)p[3] << 24 );
}

static NSData *SRPakEntry( NSString *pakPath, NSString *entryName )
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
			[NSException raise:@"sr" format:@"short"];

		h = (const unsigned char *)[header bytes];
		if( h[0] != 'P' || h[1] != 'A' || h[2] != 'C' || h[3] != 'K' )
			[NSException raise:@"sr" format:@"magic"];

		dirOfs = sr_le32( h + 4 );
		dirLen = sr_le32( h + 8 );
		if( dirLen == 0 || dirLen > 64UL * 65536UL )
			[NSException raise:@"sr" format:@"dir"];

		[fh seekToFileOffset:(unsigned long long)dirOfs];
		dir = [fh readDataOfLength:dirLen];
		if( [dir length] != dirLen )
			[NSException raise:@"sr" format:@"shortdir"];

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

			pos = sr_le32( e + 56 );
			len = sr_le32( e + 60 );
			if( len == 0 || len > 8UL * 1024UL * 1024UL )
				break;                  /* not something we want to play */

			[fh seekToFileOffset:(unsigned long long)pos];
			payload = [[fh readDataOfLength:len] retain];
			break;
		}
	}
	NS_HANDLER
	{
		payload = nil;                  /* truncated or malformed: give up quietly */
	}
	NS_ENDHANDLER

	[fh closeFile];
	return [payload autorelease];
}
#import <OpenGL/gl.h>
#import <OpenGL/CGLRenderers.h>
#import <ApplicationServices/ApplicationServices.h>

/*
 * The 10.3.9 SDK predates Intel Macs, so its <mach/machine.h> has no x86
 * constants at all. They are fixed numbers in the Mach-O ABI and will not
 * change, so defining them here is safe, and it keeps one source file building
 * for both slices. CPU_ARCH_ABI64 is the 64-bit flag ORed onto the base type.
 */
#ifndef CPU_ARCH_ABI64
#define CPU_ARCH_ABI64 0x01000000
#endif
#ifndef CPU_TYPE_X86
#define CPU_TYPE_X86 ( (cpu_type_t)7 )
#endif
#ifndef CPU_TYPE_X86_64
#define CPU_TYPE_X86_64 ( CPU_TYPE_X86 | CPU_ARCH_ABI64 )
#endif
#ifndef CPU_TYPE_ARM
#define CPU_TYPE_ARM ( (cpu_type_t)12 )
#endif
#ifndef CPU_TYPE_ARM64
#define CPU_TYPE_ARM64 ( CPU_TYPE_ARM | CPU_ARCH_ABI64 )
#endif

/* ------------------------------------------------------------------ sysctl -- */

/*
 * sysctl string, or nil. Two calls: one to size the buffer, one to fill it.
 */
static NSString *SRSysctlString( const char *name )
{
	size_t len = 0;
	char *buf;
	NSString *out;

	if( sysctlbyname( name, NULL, &len, NULL, 0 ) != 0 || len == 0 )
		return nil;

	buf = (char *)malloc( len + 1 );
	if( buf == NULL )
		return nil;

	if( sysctlbyname( name, buf, &len, NULL, 0 ) != 0 )
	{
		free( buf );
		return nil;
	}
	buf[len] = '\0';
	out = [NSString stringWithCString:buf];
	free( buf );
	return out;
}

/*
 * sysctl integer, or `missing` if the key does not exist.
 *
 * Width matters here. hw.cpufrequency and hw.memsize are 64-bit, hw.cputype and
 * friends are 32-bit, and asking for the wrong width returns garbage rather than
 * an error. So the actual size is read first and the value widened from it.
 */
static long long SRSysctlInt( const char *name, long long missing )
{
	size_t len = 0;

	if( sysctlbyname( name, NULL, &len, NULL, 0 ) != 0 )
		return missing;

	if( len == sizeof( int ) )
	{
		int v = 0;
		len = sizeof( v );
		if( sysctlbyname( name, &v, &len, NULL, 0 ) != 0 )
			return missing;
		return (long long)v;
	}
	if( len == sizeof( long long ) )
	{
		long long v = 0;
		len = sizeof( v );
		if( sysctlbyname( name, &v, &len, NULL, 0 ) != 0 )
			return missing;
		return v;
	}
	return missing;
}

/* -------------------------------------------------------------- translation -- */

/*
 * Whether this process is being translated rather than executed natively.
 *
 * Both of Apple's translators set `sysctl.proc_translated`, so the flag alone
 * does not say which one: a ppc process on an Intel Mac is Rosetta, an x86_64
 * process on an Apple Silicon Mac is Rosetta 2. The slice we are running as
 * separates them, and hw.optional.arm64 confirms the second. The key is absent
 * on older systems, which reads as "not translated" and is the right answer
 * there.
 */
static BOOL SRIsTranslated( void )
{
	return SRSysctlInt( "sysctl.proc_translated", 0 ) != 0;
}

/*
 * hw.optional.arm64 is reported through the translation, so it is visible to
 * this x86_64 process on an Apple Silicon Mac. It is absent on Intel and on
 * PowerPC.
 */
static BOOL SRIsAppleSilicon( void )
{
	return SRSysctlInt( "hw.optional.arm64", 0 ) != 0;
}

/*
 * Whether the CPU can run 64-bit code, as three states rather than two.
 *
 * hw.cpu64bit_capable arrived with 64-bit userland, so on 10.4 it is ABSENT
 * rather than 0. That distinction now matters: this app gained an i386 slice so
 * that it runs on old Intel machines, and a Core 2 Duo on Tiger is exactly such
 * a machine. Reading a missing key as "not 64-bit capable" would tell that owner
 * their Mac can never run the game, when all they need is a newer OS.
 *
 * Returns 1 for yes, 0 for no, -1 for "the system does not say".
 */
static int SRIs64BitCapable( void )
{
	long long v = SRSysctlInt( "hw.cpu64bit_capable", -1 );

	if( v >= 0 )
		return v != 0 ? 1 : 0;

	/* 10.4 spelling, present on the Intel Tiger builds. */
	v = SRSysctlInt( "hw.optional.x86_64", -1 );
	if( v >= 0 )
		return v != 0 ? 1 : 0;

	return -1;
}

/* ------------------------------------------------------- CPU interpretation -- */

/*
 * Turn cputype/cpusubtype into the names this project uses, and say which slice
 * of Half-Life.app such a machine would load.
 *
 * This is the single most useful line in the whole report. dyld picks a slice by
 * CPU subtype and ignores the OS version, so an unsupported machine does not
 * fall back to something that would have worked - it just fails to launch.
 */
static NSString *SRSliceName( long long cputype, long long cpusubtype )
{
	/*
	 * Checked before cputype, because under Rosetta 2 the sysctls describe the
	 * translated environment rather than the machine: an Apple Silicon Mac
	 * reports cputype 7 and would otherwise be written down as a 64-bit Intel
	 * one. That is wrong in the report and wrong in any issue quoting it.
	 */
	if( SRIsAppleSilicon() )
	{
		if( SRIsTranslated() )
			return @"arm64 (Apple Silicon), reporting as x86_64 under Rosetta 2";
		return @"arm64 (Apple Silicon)";
	}
	if( cputype == CPU_TYPE_ARM64 )
		return @"arm64 (Apple Silicon)";
	if( cputype == CPU_TYPE_ARM )
		return @"arm (32-bit), which is not a Mac; please report this";
	if( cputype == CPU_TYPE_POWERPC )
	{
		switch( cpusubtype )
		{
		case CPU_SUBTYPE_POWERPC_750:  return @"ppc750";
		case CPU_SUBTYPE_POWERPC_7400: return @"ppc7400";
		case CPU_SUBTYPE_POWERPC_7450: return @"ppc7450";
		case CPU_SUBTYPE_POWERPC_970:  return @"ppc970";
		case CPU_SUBTYPE_POWERPC_ALL:  return @"ppc (generic)";
		default: break;
		}
		return [NSString stringWithFormat:@"ppc (subtype %lld)", cpusubtype];
	}
	/*
	 * Every Intel Mac reports hw.cputype 7 (i386), including 64-bit ones: the
	 * 64-bit capability is a separate sysctl, not a different cputype. Reading
	 * the type alone and calling a Core 2 Duo "i386" is wrong, and would have
	 * told a supported machine it was unsupported.
	 */
	if( cputype == CPU_TYPE_X86_64 || cputype == CPU_TYPE_X86 )
	{
		switch( SRIs64BitCapable() )
		{
		case 1:  return @"x86_64 (64-bit capable Intel)";
		case 0:  return @"i386 (32-bit-only Intel)";
		default: return @"Intel, 64-bit capability not reported by this OS";
		}
	}
	return [NSString stringWithFormat:@"cputype %lld subtype %lld", cputype, cpusubtype];
}

/*
 * What we actually ship, keyed by what the machine will ask for. A 7450 asks for
 * ppc7450 and settles for our ppc7400 slice, which is why it is listed as served.
 * A 970 does the same: from v1.4.0 the G5 takes ppc7400 rather than a slice of
 * its own, so every PowerPC slice now targets 10.3.9 and no PowerPC Mac from
 * Panther up is left without one.
 */
static NSString *SRSliceVerdict( long long cputype, long long cpusubtype )
{
	/*
	 * The game carries a native arm64 slice since 2026-08-08 (issue #2, closed),
	 * so Apple Silicon is served natively and Rosetta 2 is never involved unless
	 * the user forces it.
	 */
	if( SRIsAppleSilicon() )
	{
		/*
		 * Keyed on how THIS process is running, not on the hardware. A native
		 * arm64 build of this app would otherwise report the Rosetta answer
		 * while plainly not being translated, which is the sort of contradiction
		 * that makes a report useless. Either way the game itself launches its
		 * native arm64 slice; dyld prefers native over translation.
		 */
		if( SRIsTranslated() )
			return @"this app is running under Rosetta 2; the game has a native "
			        "arm64\n  slice (needs macOS 11 or newer) and runs it natively";
		return @"served by our native arm64 slice (needs macOS 11 or newer)";
	}
	if( cputype == CPU_TYPE_POWERPC )
	{
		switch( cpusubtype )
		{
		case CPU_SUBTYPE_POWERPC_750:
			return @"served by our ppc750 slice (needs 10.3.9 to 10.5)";
		case CPU_SUBTYPE_POWERPC_7400:
		case CPU_SUBTYPE_POWERPC_7450:
		case CPU_SUBTYPE_POWERPC_970:
			return @"served by our ppc7400 slice (needs 10.3.9 to 10.5)";
		default:
			return @"NO SLICE for this PowerPC subtype - please report this";
		}
	}
	if( cputype == CPU_TYPE_X86_64 || cputype == CPU_TYPE_X86 )
	{
		switch( SRIs64BitCapable() )
		{
		case 1:
			return @"served by our x86_64 slice (needs 10.6.8 or newer)";
		case 0:
			/*
			 * The 2006 Core Solo and Core Duo Macs. The game has an i386 slice
			 * for exactly these machines; this app reaches further down still,
			 * to 10.4, so a machine below the game's floor can still say so.
			 */
			return @"served by our i386 slice - 32-bit-only Intel (Core Solo / Core Duo).\n"
			        "  The game needs 10.6 Snow Leopard on this Mac";
		default:
			/*
			 * Almost certainly a 64-bit Mac on 10.4, which does not publish the
			 * key. Saying "no slice" here would be wrong: such a machine only
			 * needs a newer OS. Ask rather than assert.
			 */
			return @"UNKNOWN - this OS does not report 64-bit capability.\n"
			        "  If this Mac is a Core 2 Duo or newer it needs 10.6.8 to run the game.\n"
			        "  Please report this, the exact model matters here";
		}
	}
	return @"NO SLICE - unrecognised CPU, please report this";
}

/* ------------------------------------------------------------ OS in range -- */

/*
 * ProductVersion as one comparable number: 10.3.9 becomes 10003009.
 *
 * A missing component counts as zero, so "10.7" is 10007000 and sorts below
 * 10.7.5, which is what we want.
 */
static long long SROSVersionCode( NSString *v )
{
	NSArray *parts;
	long long code = 0;
	unsigned k;

	if( v == nil )
		return -1;

	parts = [v componentsSeparatedByString:@"."];

	/*
	 * A major version of 0 means the string was empty or not a version at all.
	 * Returning 0 would sort below every floor and report the OS as too old,
	 * which is a worse answer than admitting we could not read it.
	 */
	if( [parts count] == 0 || [[parts objectAtIndex:0] intValue] <= 0 )
		return -1;

	for( k = 0; k < 3; k++ )
	{
		long long n = ( k < [parts count] ) ? [[parts objectAtIndex:k] intValue] : 0;
		code = ( code * 1000 ) + n;
	}
	return code;
}

/*
 * Whether the OS is inside the range the machine's slice was built for, since
 * dyld will not check it and the user should not have to compare two lines of
 * this report by eye. Returns nil when there is nothing to say.
 *
 * PowerPC slices carry no LC_VERSION_MIN at all, so this range is not readable
 * off the binary; it is the deployment target the slices were built to.
 */
static NSString *SROSRangeWarning( long long cputype, long long os )
{
	if( os < 0 )
		return nil;

	if( SRIsAppleSilicon() )
		return nil;

	if( cputype == CPU_TYPE_POWERPC )
	{
		if( os < 10003009LL )
			return @"THIS OS IS TOO OLD: the PowerPC slices need 10.3.9 Panther.";
		if( os >= 10006000LL )
			return @"THIS OS IS NEWER THAN ANY TESTED HERE: the PowerPC slices\n"
			        "  were built for 10.3.9 through 10.5. If it works, please say so.";
		return nil;
	}
	if( cputype == CPU_TYPE_X86_64 || cputype == CPU_TYPE_X86 )
	{
		if( SRIs64BitCapable() == 0 )
		{
			/* 32-bit-only Intel: the game's i386 slice starts at 10.6. */
			if( os < 10006000LL )
				return @"THIS OS IS TOO OLD: the game's i386 slice needs 10.6 Snow Leopard.";
			return nil;
		}
		if( SRIs64BitCapable() != 1 )
			return nil;   /* already covered by the verdict above */
		if( os < 10006008LL )
			return @"THIS OS IS TOO OLD: the x86_64 slice needs 10.6.8.";
		return nil;
	}
	return nil;
}

/*
 * Which slice THIS app is running as.
 *
 * The most direct evidence in the whole report: this bundle is a
 * [ppc, i386, x86_64, arm64] fat, so whatever it is executing as is what the
 * loader picked for that machine, observed rather than inferred from sysctl.
 */
static NSString *SRRunningArch( void )
{
	NSString *arch;

#if defined( __arm64__ ) || defined( __aarch64__ )
	arch = @"arm64";
#elif defined( __x86_64__ )
	arch = @"x86_64";
#elif defined( __i386__ )
	arch = @"i386";
#elif defined( __ppc64__ )
	arch = @"ppc64";
#elif defined( __ppc__ )
	arch = @"ppc";
#else
	arch = @"unknown";
#endif

	if( SRIsTranslated() )
		return [NSString stringWithFormat:@"%@, translated by %@", arch,
			SRIsAppleSilicon() ? @"Rosetta 2" : @"Rosetta"];
	return arch;
}

/* ------------------------------------------------------------------ OpenGL -- */

/*
 * Renderer strings from an offscreen context.
 *
 * Worth having because the renderer decisions in this port turn on them: the
 * single-pass world draw needs two texture units, and the software fallback
 * exists for GPUs whose GL path does not work at all. A machine that reports no
 * context here is telling us something useful too.
 *
 * NSOpenGLPFAAccelerated is deliberately NOT requested: on a machine with no
 * hardware GL we still want whatever renderer it does have, rather than nothing.
 */
static NSString *SRGraphicsSection( void )
{
	NSOpenGLPixelFormatAttribute attrs[] = {
		NSOpenGLPFADoubleBuffer,
		NSOpenGLPFAColorSize, 24,
		NSOpenGLPFADepthSize, 16,
		0
	};
	NSOpenGLPixelFormat *fmt;
	NSOpenGLContext *ctx;
	NSMutableString *s = [NSMutableString string];
	const GLubyte *vendor, *renderer, *version, *exts;
	GLint units = 0, maxtex = 0;

	fmt = [[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] autorelease];
	if( fmt == nil )
		return @"  OpenGL              : no pixel format available\n";

	ctx = [[[NSOpenGLContext alloc] initWithFormat:fmt shareContext:nil] autorelease];
	if( ctx == nil )
		return @"  OpenGL              : no context available\n";

	[ctx makeCurrentContext];

	vendor   = glGetString( GL_VENDOR );
	renderer = glGetString( GL_RENDERER );
	version  = glGetString( GL_VERSION );
	exts     = glGetString( GL_EXTENSIONS );

	[s appendFormat:@"  GL vendor           : %s\n", vendor   ? (const char *)vendor   : "unknown"];
	[s appendFormat:@"  GL renderer         : %s\n", renderer ? (const char *)renderer : "unknown"];
	[s appendFormat:@"  GL version          : %s\n", version  ? (const char *)version  : "unknown"];

	/* Two texture units is the bar for the single-pass world draw. */
	glGetIntegerv( GL_MAX_TEXTURE_UNITS, &units );
	[s appendFormat:@"  GL texture units    : %ld%s\n", (long)units,
		( units >= 2 ) ? "  (single-pass multitexture possible)"
		               : "  (too few for single-pass multitexture)"];

	glGetIntegerv( GL_MAX_TEXTURE_SIZE, &maxtex );
	[s appendFormat:@"  GL max texture size : %ld\n", (long)maxtex];

	/* GLSL only exists from GL 2.0; asking on an older renderer sets an error. */
	{
		const GLubyte *glsl = glGetString( 0x8B8C ); /* GL_SHADING_LANGUAGE_VERSION */
		if( glGetError() == GL_NO_ERROR && glsl != NULL )
			[s appendFormat:@"  GLSL version        : %s\n", (const char *)glsl];
		else
			[s appendString:@"  GLSL version        : none (pre-GL 2.0)\n"];
	}

	if( exts != NULL )
	{
		/*
		 * The extensions this port actually branches on, named individually so a
		 * report is useful without pasting a 4 KB extension string.
		 */
		static const char *interesting[] = {
			"GL_ARB_multitexture",
			"GL_ARB_texture_env_combine",
			"GL_EXT_texture_env_combine",
			"GL_ARB_texture_non_power_of_two",
			"GL_EXT_texture_filter_anisotropic",
			"GL_ARB_vertex_buffer_object",
			"GL_EXT_texture_compression_s3tc",
			"GL_ARB_depth_texture",
			NULL
		};
		const char *e = (const char *)exts;
		int k;

		[s appendFormat:@"  GL extension count  : %d\n",
			(int)[[[NSString stringWithCString:e]
				componentsSeparatedByString:@" "] count]];
		for( k = 0; interesting[k] != NULL; k++ )
			[s appendFormat:@"    %-34s %s\n", interesting[k],
				strstr( e, interesting[k] ) ? "yes" : "no"];
	}

	[NSOpenGLContext clearCurrentContext];

	/*
	 * CGL renderer properties. This is where the video memory actually lives:
	 * OpenGL's own strings never report it, and CGLDescribeRenderer has been
	 * available since 10.0, so it works on every machine this app targets.
	 * There can be several renderers (a real GPU plus the software one), so all
	 * of them are listed rather than guessing which is in use.
	 */
	{
		CGLRendererInfoObj info = NULL;
		GLint nrend = 0, j;

		if( CGLQueryRendererInfo( CGDisplayIDToOpenGLDisplayMask( CGMainDisplayID() ),
		                          &info, &nrend ) == kCGLNoError && info != NULL )
		{
			[s appendFormat:@"  CGL renderers       : %ld\n", (long)nrend];
			for( j = 0; j < nrend; j++ )
			{
				GLint accel = 0, vram = 0, texmem = 0, rid = 0;

				CGLDescribeRenderer( info, j, kCGLRPAccelerated, &accel );
				CGLDescribeRenderer( info, j, kCGLRPRendererID, &rid );
				CGLDescribeRenderer( info, j, kCGLRPVideoMemory, &vram );
				CGLDescribeRenderer( info, j, kCGLRPTextureMemory, &texmem );

				[s appendFormat:@"    [%ld] %@, id 0x%08lx, VRAM %ld MB, texture %ld MB\n",
					(long)j,
					accel ? @"hardware" : @"software",
					(unsigned long)rid,
					(long)( vram / ( 1024 * 1024 ) ),
					(long)( texmem / ( 1024 * 1024 ) )];
			}
			CGLDestroyRendererInfo( info );
		}
		else
		{
			[s appendString:@"  CGL renderers       : could not be queried\n"];
		}
	}

	return s;
}

/* ------------------------------------------------------------------ report -- */

NSString *SRReportText( void )
{
	NSMutableString *r = [NSMutableString string];
	long long cputype, cpusubtype, ncpu, freq, mem;
	NSString *model, *machineName, *osver, *osbuild;
	NSDictionary *sv;
	NSScreen *scr;

	cputype    = SRSysctlInt( "hw.cputype", -1 );
	cpusubtype = SRSysctlInt( "hw.cpusubtype", -1 );
	ncpu       = SRSysctlInt( "hw.ncpu", -1 );
	freq       = SRSysctlInt( "hw.cpufrequency", -1 );
	/* hw.memsize is 64-bit and modern; hw.physmem is the 10.3 spelling and caps
	 * out at 2 GB, so it is only a fallback. */
	mem        = SRSysctlInt( "hw.memsize", -1 );
	if( mem < 0 )
		mem = SRSysctlInt( "hw.physmem", -1 );

	model       = SRSysctlString( "hw.model" );
	machineName = SRSysctlString( "hw.machine" );

	sv = [NSDictionary dictionaryWithContentsOfFile:
		@"/System/Library/CoreServices/SystemVersion.plist"];
	osver   = [sv objectForKey:@"ProductVersion"];
	osbuild = [sv objectForKey:@"ProductBuildVersion"];

	[r appendString:@"Half-Life old-Mac port - system report\n"];
	[r appendString:@"======================================\n\n"];

	[r appendString:@"MACHINE\n"];
	[r appendFormat:@"  Model               : %@\n", model ? model : @"unknown"];
	[r appendFormat:@"  hw.machine          : %@\n", machineName ? machineName : @"unknown"];
	[r appendFormat:@"  CPU type / subtype  : %lld / %lld\n", cputype, cpusubtype];
	[r appendFormat:@"  Reads as            : %@\n", SRSliceName( cputype, cpusubtype )];
	[r appendFormat:@"  Cores               : %lld\n", ncpu];
	if( freq > 0 )
		[r appendFormat:@"  Clock               : %lld MHz\n", freq / 1000000];
	if( mem > 0 )
		[r appendFormat:@"  Memory              : %lld MB\n", mem / ( 1024 * 1024 )];
	[r appendFormat:@"  Byte order          : %@\n",
		( NSHostByteOrder() == NS_BigEndian ) ? @"big-endian" : @"little-endian"];
	[r appendFormat:@"  AltiVec             : %@\n",
		( SRSysctlInt( "hw.optional.altivec", 0 ) != 0 ) ? @"yes" : @"no"];
	[r appendFormat:@"  Pointer size        : %d-bit\n", (int)( sizeof( void * ) * 8 )];
	[r appendFormat:@"  64-bit capable      : %@\n",
		( SRIs64BitCapable() == 1 ) ? @"yes" :
		( SRIs64BitCapable() == 0 ) ? @"no" : @"not reported by this OS"];
	[r appendFormat:@"  This app running as : %@\n", SRRunningArch()];
	[r appendString:@"\n"];

	[r appendString:@"OPERATING SYSTEM\n"];
	[r appendFormat:@"  Version             : %@\n", osver ? osver : @"unknown"];
	[r appendFormat:@"  Build               : %@\n", osbuild ? osbuild : @"unknown"];
	[r appendString:@"\n"];

	[r appendString:@"WHICH SLICE THIS MAC WOULD LOAD\n"];
	[r appendFormat:@"  %@\n", SRSliceVerdict( cputype, cpusubtype )];
	{
		NSString *warn = SROSRangeWarning( cputype, SROSVersionCode( osver ) );

		if( warn != nil )
			[r appendFormat:@"\n  %@\n", warn];
	}
	[r appendString:@"\n"];
	[r appendString:@"  dyld chooses by CPU subtype and ignores the OS version, so if the\n"];
	[r appendString:@"  OS above is outside the range named here, the app will not launch\n"];
	[r appendString:@"  and will NOT fall back to a slice that would have worked.\n"];
	[r appendString:@"\n"];

	[r appendString:@"GRAPHICS\n"];
	scr = [NSScreen mainScreen];
	if( scr != nil )
	{
		NSRect f = [scr frame];
		[r appendFormat:@"  Screen              : %d x %d, %d bit\n",
			(int)f.size.width, (int)f.size.height,
			(int)NSBitsPerPixelFromDepth( [scr depth] )];
	}
	[r appendString:SRGraphicsSection()];
	[r appendString:@"\n"];

	[r appendString:@"WHAT TO DO WITH THIS\n"];
	[r appendString:@"  Paste it into a new issue at\n"];
	[r appendString:@"  https://github.com/matthewdeaves/old-mac-halflife/issues\n"];
	[r appendString:@"\n"];
	[r appendString:@"  Please also add anything else you can, even if it looks irrelevant:\n"];
	[r appendString:@"    - did the game launch at all, and how far did it get\n"];
	[r appendString:@"    - the exact wording of any error dialog\n"];
	[r appendString:@"    - whether it was the game, the mod installer or a specific mod\n"];
	[r appendString:@"    - anything in Console.app, or a crash report from\n"];
	[r appendString:@"      ~/Library/Logs/CrashReporter\n"];
	[r appendString:@"    - the Half-Life-Mods-install.log next to the app, if mods were involved\n"];
	[r appendString:@"    - what your graphics card is, if you know and it is not named above\n"];
	[r appendString:@"    - a photo of the screen is fine if you cannot copy the text\n"];
	[r appendString:@"\n"];
	[r appendString:@"  Too much detail is far more useful than too little. A machine we have\n"];
	[r appendString:@"  never seen is exactly the interesting case.\n"];

	return r;
}

/* -------------------------------------------------------------- controller -- */

@implementation SRController

- (id)init
{
	self = [super init];
	if( self != nil )
		report = [SRReportText() retain];
	return self;
}

- (void)dealloc
{
	[report release];
	[window release];
	[aboutWindow release];
	[super dealloc];
}

- (void)showWindow
{
	NSRect frame = NSMakeRect( 0, 0, 620, 560 );
	NSScrollView *scroll;
	NSTextField *title;

	window = [[NSWindow alloc]
		initWithContentRect:frame
		          styleMask:( NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask )
		            backing:NSBackingStoreBuffered
		              defer:NO];
	[window setTitle:@"Half-Life System Report"];
	[window center];

	title = [[[NSTextField alloc] initWithFrame:NSMakeRect( 20, 522, 580, 20 )] autorelease];
	[title setStringValue:@"What this Mac is, and which slice of Half-Life.app it would load."];
	[title setBezeled:NO];
	[title setDrawsBackground:NO];
	[title setEditable:NO];
	[title setSelectable:NO];
	[[window contentView] addSubview:title];

	scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect( 20, 60, 580, 452 )] autorelease];
	[scroll setHasVerticalScroller:YES];
	[scroll setBorderType:NSBezelBorder];
	[scroll setAutohidesScrollers:YES];

	textView = [[[NSTextView alloc] initWithFrame:[[scroll contentView] bounds]] autorelease];
	[textView setEditable:NO];
	[textView setRichText:NO];
	/* Fixed pitch: the report is a two-column list and only lines up in one. */
	[textView setFont:[NSFont userFixedPitchFontOfSize:11.0]];
	[textView setTextContainerInset:NSMakeSize( 4.0, 4.0 )];
	[textView setString:report];
	[scroll setDocumentView:textView];
	[[window contentView] addSubview:scroll];

	copyButton = [[[NSButton alloc] initWithFrame:NSMakeRect( 20, 18, 160, 28 )] autorelease];
	[copyButton setTitle:@"Copy report"];
	[copyButton setBezelStyle:NSRoundedBezelStyle];
	[copyButton setTarget:self];
	[copyButton setAction:@selector( copyReport: )];
	[copyButton setKeyEquivalent:@"\r"];
	[[window contentView] addSubview:copyButton];

	saveButton = [[[NSButton alloc] initWithFrame:NSMakeRect( 190, 18, 160, 28 )] autorelease];
	[saveButton setTitle:@"Save to file..."];
	[saveButton setBezelStyle:NSRoundedBezelStyle];
	[saveButton setTarget:self];
	[saveButton setAction:@selector( saveReport: )];
	[[window contentView] addSubview:saveButton];

	[window makeKeyAndOrderFront:nil];
}

- (void)copyReport:(id)sender
{
	NSPasteboard *pb = [NSPasteboard generalPasteboard];

	[pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
	[pb setString:report forType:NSStringPboardType];

	NSRunAlertPanel( @"Copied",
		@"The report is on the clipboard. Paste it into a new issue at\n"
		 "github.com/matthewdeaves/old-mac-halflife/issues",
		@"OK", nil, nil );
}

- (void)saveReport:(id)sender
{
	NSSavePanel *panel = [NSSavePanel savePanel];

	[panel setRequiredFileType:@"txt"];
	if( [panel runModalForDirectory:NSHomeDirectory() file:@"half-life-system-report.txt"]
		!= NSFileHandlingPanelOKButton )
		return;

	if( ![report writeToFile:[panel filename] atomically:YES] )
		NSRunAlertPanel( @"Could not save",
			@"The report could not be written to that location.", @"OK", nil, nil );
}

/*
 * A hand-built About window rather than NSRunAlertPanel, so the artwork can be
 * shown. Same shape as the mod installer's, and for the same reason: the
 * standard About panel gives no room for a picture of this size.
 *
 * The window is built once and kept, because -setReleasedWhenClosed:NO means
 * closing it only orders it out. 10.3 rules throughout: no @property, no
 * autolayout, explicit frames.
 */
- (NSTextField *)labelAt:(NSRect)r text:(NSString *)s bold:(BOOL)bold
{
	NSTextField *t = [[[NSTextField alloc] initWithFrame:r] autorelease];

	[t setStringValue:s];
	[t setBezeled:NO];
	[t setDrawsBackground:NO];
	[t setEditable:NO];
	[t setSelectable:NO];
	[t setFont:bold ? [NSFont boldSystemFontOfSize:14.0]
	                : [NSFont systemFontOfSize:11.0]];
	return t;
}

/*
 * Where the player's game data is, from this app's point of view.
 *
 * The shipped layout puts all three app bundles NEXT TO the player's own valve
 * folder (.claude/rules/shipped-layout.md), and the game launcher relies on the
 * same relationship for XASH3D_BASEDIR. So the folder containing this bundle is
 * the game root, and if there is no valve/pak0.pak in it then this machine has
 * no game data and there is nothing to play. Returns nil rather than searching
 * the disk: this app reads only, and hunting a volume for someone's pak file is
 * not "reads only" in any sense a user would recognise.
 */
- (NSString *)gameRootOrNil
{
	NSString *root = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
	NSString *pak  = [root stringByAppendingPathComponent:@"valve/pak0.pak"];

	if( [[NSFileManager defaultManager] fileExistsAtPath:pak] )
		return root;
	return nil;
}

/*
 * Clicking the picture plays a line, if the player's data is there. Issue #11.
 *
 * One NSSound held in a static, so a second click stops the first rather than
 * layering, and so the object outlives this function: -play is asynchronous and
 * releasing on the way out cuts the sound off or crashes.
 */
- (void)playScientist:(id)sender
{
	static NSSound *sound = nil;
	NSString *root = [self gameRootOrNil];
	NSData *wav;

	(void)sender;
	if( root == nil )
		return;                 /* no game data beside us: stay quiet */

	if( sound != nil )
	{
		if( [sound isPlaying] )
			[sound stop];
		[sound release];
		sound = nil;
	}

	wav = SRPakEntry( [root stringByAppendingPathComponent:@"valve/pak0.pak"],
	                  @"sound/scientist/whatyoudoing.wav" );
	if( wav == nil )
		return;

	sound = [[NSSound alloc] initWithData:wav];
	[sound play];
}

- (void)showAbout:(id)sender
{
	if( aboutWindow == nil )
	{
		NSRect frame = NSMakeRect( 0, 0, 430, 300 );
		NSView *content;
		NSButton *art;
		NSImage *img;
		NSString *path;

		aboutWindow = [[NSWindow alloc]
			initWithContentRect:frame
			          styleMask:( NSTitledWindowMask | NSClosableWindowMask )
			            backing:NSBackingStoreBuffered
			              defer:NO];
		[aboutWindow setTitle:@"About Half-Life System Report"];
		[aboutWindow center];
		[aboutWindow setReleasedWhenClosed:NO];
		content = [aboutWindow contentView];

		/*
		 * The PNG is a cut-out of the figure with the black backdrop removed, so
		 * the frame is the figure's own bounds and not a picture box: any spare
		 * frame would just be empty. Authored at 210x240 by
		 * scripts/make-about-art.py, which prints the size to use here, and
		 * -setSize: pins it so nothing is resampled on screen. None of the target
		 * machines has a HiDPI display.
		 */
		/*
		 * A BORDERLESS BUTTON, not an NSImageView, so the picture can be clicked
		 * and answer with a line out of the player's own game data. Issue #11,
		 * same treatment as installer/OMController.m gives Gordon.
		 *
		 * NSImageView does not take clicks, so making it clickable means being a
		 * control. NSButton with a transparent bezel and no title draws exactly
		 * the same as the image view did: the artwork is a cut-out with the
		 * backdrop already removed, so there is no button shape to hide.
		 */
		art = [[[NSButton alloc] initWithFrame:NSMakeRect( 24, 34, 210, 240 )] autorelease];
		path = [[[NSBundle mainBundle] resourcePath]
			stringByAppendingPathComponent:@"About-Scientist.png"];
		img = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
		if( img != nil )
		{
			[img setSize:NSMakeSize( 210, 240 )];
			[art setImage:img];
		}
		[art setBordered:NO];
		[art setButtonType:NSMomentaryChangeButton];
		[art setImagePosition:NSImageOnly];
		[art setTitle:@""];
		[art setTarget:self];
		[art setAction:@selector(playScientist:)];
		[content addSubview:art];

		[content addSubview:[self labelAt:NSMakeRect( 250, 246, 160, 24 )
		                             text:@"System Report" bold:YES]];

		[content addSubview:[self labelAt:NSMakeRect( 250, 34, 160, 206 )
		                             text:@"Reports what this Mac is, so the "
		                                   "old-Mac Half-Life port can be built "
		                                   "to support it.\n\n"
		                                   "It reads only. Nothing is sent "
		                                   "anywhere.\n\n"
		                                   "PowerPC from 10.3, 32-bit Intel from "
		                                   "10.4, 64-bit Intel from 10.5, and "
		                                   "Apple Silicon native.\n\n"
		                                   "It deliberately runs on machines the "
		                                   "game itself cannot."
		                             bold:NO]];
	}
	[aboutWindow makeKeyAndOrderFront:nil];
}

/* Quit when the window is closed: one window, nothing else to do. */
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
	return YES;
}

@end
