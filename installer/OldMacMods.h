/*
 * OldMacMods.h - shared declarations for the "Get Mods" installer.
 *
 * TARGET: Mac OS X 10.3.9 and up, fat ppc + x86_64. That rules out most of
 * modern Cocoa, so throughout this app:
 *   - no @property / @synthesize      (Objective-C 2.0, 10.5+)
 *   - no fast enumeration (for..in)   (10.5+)
 *   - no NSInteger / NSUInteger       (10.5+) - use int / unsigned / long long
 *   - no blocks, no GCD               (10.6+) - NSThread + performSelectorOnMainThread
 *   - no ARC                          - manual retain/release
 *   - no nibs                         - the UI is built in code, so there is no nib
 *                                       format to stay compatible with across 10.3->26
 *
 * Networking is https AND plain http. The app carries its own TLS (OMTLS.m,
 * mbedTLS 3.6), because PowerPC has no TLS in this project and 10.3-10.7's
 * system TLS cannot negotiate modern ciphers, yet every host that publishes a
 * mod answers plain http with a 301 to https. Verified working on a G3 under
 * 10.3.9. archive.org is still reached over plain http, because it works.
 */

#import <Cocoa/Cocoa.h>
#include <stdlib.h>

/* ------------------------------------------------------------ connections -- */
/*
 * One connection type for both transports, so OMDownload does not care which it
 * got. Plain is a bare socket; TLS is mbedTLS 3.6 driven over that same socket
 * (OMTLS.m). https became mandatory when the app stopped fetching one bundle
 * from one plain-http mirror and started fetching each mod from wherever that
 * mod is actually published: every host that matters answers plain http with a
 * 301 to https.
 *
 * `caBundlePath` is only read when useTLS is YES. On failure the connection is
 * closed for you and *err carries something a person can act on - notably the
 * dead-PRAM-battery case, where the real fault is the Mac's own clock and every
 * certificate on the internet looks invalid.
 */
typedef struct OMConn OMConn;

OMConn *OMConnOpen( NSString *host, int port, BOOL useTLS, NSString *caBundlePath, NSString **err );
ssize_t OMConnRead( OMConn *c, void *buf, size_t len );      /* >0 bytes, 0 EOF, <0 error */
BOOL    OMConnWriteAll( OMConn *c, const void *buf, size_t len );
const char *OMConnCipherName( OMConn *c );                   /* "plain" when not TLS */
void    OMConnClose( OMConn *c );

/* ------------------------------------------------- 10.3-safe string helpers -- */
/*
 * -longLongValue and -stringByReplacingOccurrencesOfString:withString: are both
 * 10.5 additions. Calling them on 10.3 raises doesNotRecognizeSelector at
 * runtime - and where the receiver is typed `id` the compiler cannot even warn,
 * so these are easy to reintroduce by accident. Both replacements use only 10.0
 * API. Verified by compiling against the 10.3.9 SDK, which flags any such call
 * as "'NSString' may not respond to ...".
 */
static inline long long OMLongLong( NSString *s )
{
	if( s == nil )
		return 0;
	return strtoll( [s UTF8String], NULL, 10 );
}

static inline NSString *OMReplace( NSString *s, NSString *find, NSString *repl )
{
	if( s == nil )
		return nil;
	return [[s componentsSeparatedByString:find] componentsJoinedByString:repl];
}

/* ------------------------------------------------------------- subprocess -- */
/*
 * fork/execv + waitpid, capturing stdout. NSTask would do, but its
 * termination-status and pipe-draining behaviour shifted across 10.3 -> modern;
 * waitpid did not.
 */
int OMRunCommand( const char *path, char *const argv[], NSMutableString *output );

/* Free space on the volume holding `path`, in bytes; -1 if it cannot be determined. */
long long OMFreeSpaceAt( NSString *path );

/* Is the volume holding `path` mounted read-only? True for a mounted .dmg, which
 * is how we catch someone running this app straight off the release image. */
BOOL OMPathIsReadOnly( NSString *path );
BOOL OMPathIsWritableDirectory( NSString *path );

/* md5 of a file as lowercase hex, or nil. Uses /sbin/md5, which exists on 10.3
 * through modern macOS - CommonCrypto's CC_MD5 only arrived in 10.4.
 *
 * Reports nothing until it finishes, so it cannot drive a progress bar. Fine for
 * small files; for a mod archive use OMFileMD5Progress below. */
NSString *OMFileMD5( NSString *path );

/* ---------------------------------------------------------------- logging -- */

@protocol OMProgressSink
- (void)omLog:(NSString *)line;                       /* one line to log + file */
- (void)omStatus:(NSString *)text;                    /* one-line status label  */
- (void)omProgress:(double)fraction;                  /* 0..1, <0 = indeterminate */
- (void)omArtwork:(NSImage *)image title:(NSString *)title;  /* nil clears */
- (BOOL)omCancelled;
@end

/* md5 of a file, computed in-process in chunks so `sink`'s progress bar moves
 * while it works, and so a cancel is noticed part way through.
 *
 * Every archive is checked against the md5 in mod-sources.txt before it is
 * unpacked, and on a G3 that is tens of seconds of apparent silence per mod.
 * /sbin/md5 says nothing at all until it finishes and cannot be cancelled, so
 * the bar would not move and Cancel would not work.
 *
 * Returns lowercase hex, or nil if the file could not be read or the user
 * cancelled. Declared here rather than beside OMFileMD5 because it needs
 * OMProgressSink. */
NSString *OMFileMD5Progress( NSString *path, id<OMProgressSink> sink );

/* ------------------------------------------------------------------- pak -- */

/*
 * Read one file out of a Quake/GoldSrc .pak archive by its internal name, e.g.
 * "sound/scientist/whatyoudoing.wav". Returns nil if the archive or the entry is
 * not there, which every caller treats as "do nothing".
 *
 * Used only by the About window, to play a line out of the player's own game
 * data. We deliberately ship no game content of our own; see OMAbout.m.
 */
NSData *OMPakEntry( NSString *pakPath, NSString *entryName );

/* Play the scientist line from <gameRoot>/valve/pak0.pak. Silent no-op if it
 * cannot be found. */
void OMPlayScientist( NSString *gameRoot );

/* -------------------------------------------------------------------- TGA -- */

/*
 * Mod artwork is game.tga, and NSImage on 10.3 has no TGA reader (TIFF/PNG/JPEG/
 * GIF/PDF only), so we decode it ourselves.
 */
@interface OMTGA : NSObject
+ (NSImage *)imageWithContentsOfFile:(NSString *)path;
+ (NSImage *)imageWithData:(NSData *)data;
@end

/* --------------------------------------------------------------- archives -- */
/*
 * Unpack a downloaded mod archive into `destDir`, which the caller has already
 * named after the gamedir.
 *
 * `kind` is "zip" or "7z", taken from mod-sources.txt rather than guessed from
 * the file extension. `root` is the subtree INSIDE the archive where the mod's
 * own tree starts, or "." when the archive root is already it: almost none of
 * these archives unpack to a folder named after the gamedir the engine expects,
 * and the gamedir is what Custom Game and liblist.gam key off.
 *
 * Everything downstream is unchanged - OMInstaller applies the same exclusions,
 * .partial staging, dylib injection and liblist.gam rewrite it applied to a
 * mounted disk image.
 */
BOOL OMExtractArchive( NSString *archivePath, NSString *kind, NSString *root,
	NSString *destDir, id<OMProgressSink> sink, NSString **err );

/* --------------------------------------------------------------- download -- */
/*
 * Minimal HTTP/1.1 GET with Range: resume, over a plain socket or a TLS session
 * (OMConn above). Written by hand rather than using NSURLConnection so that
 * resume, byte-accurate progress and 64-bit sizes behave identically on 10.3 and
 * on modern macOS - a multi-gigabyte body overflows any 32-bit counter, which is
 * exactly the bug that makes the engine's own HTTP client unusable for this.
 */
@interface OMDownload : NSObject
{
	id<OMProgressSink> sink;
	NSString *caBundlePath;   /* roots for https; nil disables https entirely */
}
- (id)initWithSink:(id<OMProgressSink>)aSink;
/* Where to find the PEM root bundle. Set this before fetching anything over
 * https; with it unset an https URL fails with a plain explanation rather than
 * an unverified connection, because falling back to no verification would give
 * away the only thing https was added for. */
- (void)setCABundlePath:(NSString *)path;
/* Resumes if destPath already exists and the server honours Range. Returns NO and
 * fills *err on failure. urls are tried in order (primary, then mirrors). */
- (BOOL)fetchURLs:(NSArray *)urls toPath:(NSString *)destPath error:(NSString **)err;
@end

/* ------------------------------------------------------- per-mod fetching -- */
/*
 * Gets one mod from its own publisher: download, md5, unpack, hand the result to
 * OMInstaller. Replaced the single-disk-image flow, which put the whole
 * catalogue behind one 2.7 GB file on one mirror and included three Valve retail
 * games we had no business redistributing.
 *
 * See installer/mod-sources.txt for the per-mod sources and, just as important,
 * for the seven mods that have none and why.
 */
@interface OMFetch : NSObject
{
	id<OMProgressSink> sink;
	NSString *resourcesPath;
	NSString *cacheDir;
	NSString *caBundlePath;
}
- (id)initWithSink:(id<OMProgressSink>)aSink resources:(NSString *)res cache:(NSString *)cache;
- (void)setCABundlePath:(NSString *)path;

/* Ordered array of NSDictionary: mod, urls (NSArray), kind, size, md5, root. */
- (NSArray *)loadSources;

/* Download + verify + unpack. Returns a staging directory the caller installs
 * from and then deletes, or nil with *err set. */
- (NSString *)stageMod:(NSDictionary *)src into:(NSString *)destRoot error:(NSString **)err;

/*
 * Delete anything an interrupted run left beside the game.
 *
 * Call this before every install run. Both the unpack container and
 * OMInstaller's <gamedir>.partial directories hold a liblist.gam, and
 * FS_ParseGameInfo registers ANY directory beside the app that has one - so a
 * force-quit part way through used to leave a half-extracted mod showing up in
 * the Custom Game list. Dotted names are no defence: listdirectory() in
 * filesystem/sys.c does not skip them.
 */
+ (void)sweepLeftoversIn:(NSString *)destRoot sink:(id<OMProgressSink>)sink;
@end

/* ------------------------------------------------------------- installing -- */

/*
 * One installable mod: where its content is, which of our builds it needs, and
 * what the server dylib must end up being called.
 */
@interface OMMod : NSObject
{
@public
	/* Public because OMMod is a plain data record that OMInstaller fills in and
	 * reads back. Objective-C 1.0 has no @property, and a dozen hand-written
	 * accessor pairs would be noise. */
	NSString *gamedir;       /* folder name on disk, e.g. "bshift"            */
	NSString *branch;        /* our build key, e.g. "bshift"                  */
	NSString *serverDLL;     /* basename from liblist.gam, e.g. "survivor"    */
	NSString *title;         /* display name                                  */
	NSString *sourcePath;    /* content dir inside the mounted bundle         */
	long expectedFiles;
	long long expectedBytes;
	BOOL supported;          /* we ship a build for it                        */
	BOOL companion;          /* content-only add-on to another mod (see below) */
}
- (NSString *)gamedir;
- (NSString *)branch;
- (NSString *)title;
- (NSString *)sourcePath;
- (BOOL)supported;
@end

@interface OMInstaller : NSObject
{
	id<OMProgressSink> sink;
	NSString *resourcesPath; /* our bundle's Resources (mods.map, mods/, manifests) */
	NSString *destRoot;      /* folder containing Half-Life.app                     */
	BOOL forceReinstall;     /* re-copy mods that are already installed             */
}
- (id)initWithSink:(id<OMProgressSink>)aSink resources:(NSString *)res destination:(NSString *)dest;
- (void)setForceReinstall:(BOOL)force;

/* mods.map as gamedir -> { branch, server_dll, title }. The controller needs it
 * to report which mods it could not install and why. */
- (NSDictionary *)loadModMap;

/* Copy content, inject our fat dylibs, fix up liblist.gam, verify. */
- (BOOL)installMod:(OMMod *)mod error:(NSString **)err;

/* Build a mod record for `gamedir` whose content is already unpacked at `path`.
 * Used by the per-mod fetch flow, where the staging directory takes the place of
 * a mounted volume. Returns nil if the gamedir is not one we ship a build for. */
- (OMMod *)modForGamedir:(NSString *)gamedir at:(NSString *)path;

/*
 * Make an ALREADY-PRESENT mod folder work, without touching its content.
 *
 * This is how Blue Shift, Opposing Force and Deathmatch Classic are handled.
 * They are Valve retail products rather than free mods, so we will not fetch
 * them from anywhere; but if the player already has them beside Half-Life.app,
 * everything they are missing is our game code. So: drop in the fat ppc +
 * x86_64 dylibs, rewrite liblist.gam to name them, change nothing else.
 *
 * It is deliberately not limited to those three. It is also the answer for the
 * four mods with no automatable source (aom, eftd, vendetta, TheGate) once the
 * player has put the content there themselves.
 */
- (BOOL)adoptExistingMod:(NSString *)gamedir error:(NSString **)err;

/* Is there a folder at destRoot/<gamedir> that looks like real mod content? */
- (BOOL)hasContentFor:(NSString *)gamedir;

+ (NSString *)defaultDestination;   /* folder containing OUR Half-Life.app, or nil */
+ (BOOL)isOurGameApp:(NSString *)appPath;  /* layout check: xash3d + xash3d.bin */
@end
