/*
 * OMDownload.m - HTTP/1.1 GET with Range: resume, over BSD sockets.
 *
 * WHY NOT NSURLConnection / NSURLDownload
 * ---------------------------------------
 * Three reasons, all of which bite on this specific job:
 *   - The file is ~2.5 GB. Anything that counts bytes in a 32-bit int overflows
 *     (that is exactly what makes the game engine's own HTTP client unusable
 *     here - httpfile_t uses `int` for size and downloaded).
 *   - We need real resume. A multi-gigabyte download to a 20-year-old Mac over
 *     wifi will be interrupted; restarting from zero is not acceptable.
 *   - It has to behave identically on 10.3 and on modern macOS. Foundation's
 *     networking stack changed repeatedly across that span; a socket and a
 *     Range: header did not.
 *
 * HTTP AND HTTPS
 * --------------
 * This used to be plain-http only, because PowerPC has no TLS in this project and
 * 10.3-10.7's system TLS cannot negotiate modern ciphers. That held while the app
 * fetched one bundle from one mirror that served plain http. It stopped holding
 * when each mod started coming from wherever that mod is actually published:
 * moddb, gamebanana, runthinkshootlive, twhl and the rest all answer plain http
 * with a 301 to https.
 *
 * So the app carries its own TLS now (OMTLS.m, mbedTLS 3.6). This file does not
 * care which transport it got - both are an OMConn. archive.org is still reached
 * over plain http, because it works and costs nothing.
 *
 * The md5 check in the caller is still mandatory and is NOT made redundant by
 * TLS. It catches a truncated resume, a disk that lied, and a mirror serving the
 * wrong file, none of which a verified certificate says anything about.
 */

#import "OldMacMods.h"

#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>

#define OM_BUFSZ 65536

/*
 * Private method declaration. Objective-C 1.0 has no class extensions, and
 * gcc-4.0 warns on any selector used before it is defined ("OMDownload may not
 * respond to ..."), so private helpers get a category interface up front.
 */
@interface OMDownload (Private)
- (BOOL)fetchOneURL:(NSString *)url toPath:(NSString *)destPath depth:(int)depth error:(NSString **)err;
@end

@implementation OMDownload

- (id)initWithSink:(id<OMProgressSink>)aSink
{
	self = [super init];
	if( self != nil )
		sink = aSink;   /* not retained: the controller owns us and outlives us */
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
	[caBundlePath release];
	[super dealloc];
}

/*
 * NOT variadic, and it must never become variadic again.
 *
 * It used to be `-log:(NSString *)fmt, ...`, and every caller passed a string it
 * had already built with +stringWithFormat:. That string is then used as a
 * FORMAT, so any percent sign in it is reinterpreted - and the strings we log
 * here are URLs, which are full of them. A percent-encoded archive.org path
 * printed as
 *
 *   .../Black                   0ps/Black                   1ps.zip
 *
 * because "%20O" was consumed as a 20-wide field specifier, and the run then
 * died with EXC_BAD_ACCESS at 0x00000001 inside
 * _CFStringAppendFormatAndArgumentsAux when a later specifier read an argument
 * that was never passed. Crashed on a G5 under 10.3.9, mid-download, having
 * already failed every mod it had tried.
 *
 * Callers that want formatting still call +stringWithFormat: themselves; the
 * result is now printed verbatim.
 */
- (void)log:(NSString *)line
{
	[sink omLog:line];
}

/* Split "http[s]://host[:port]/path" into its parts. Returns NO for any other
 * scheme. *outTLS says which transport the caller must open. */
- (BOOL)parseURL:(NSString *)url host:(NSString **)outHost port:(int *)outPort
	path:(NSString **)outPath tls:(BOOL *)outTLS
{
	NSString *rest, *lower = [url lowercaseString];
	NSRange slash, colon;
	int defaultPort;

	if( [lower hasPrefix:@"https://"] )
	{
		*outTLS = YES;
		defaultPort = 443;
		rest = [url substringFromIndex:8];
	}
	else if( [lower hasPrefix:@"http://"] )
	{
		*outTLS = NO;
		defaultPort = 80;
		rest = [url substringFromIndex:7];
	}
	else return NO;

	slash = [rest rangeOfString:@"/"];
	if( slash.location == NSNotFound )
	{
		*outHost = rest;
		*outPath = @"/";
	}
	else
	{
		*outHost = [rest substringToIndex:slash.location];
		*outPath = [rest substringFromIndex:slash.location];
	}

	*outPort = defaultPort;
	colon = [*outHost rangeOfString:@":"];
	if( colon.location != NSNotFound )
	{
		*outPort = [[*outHost substringFromIndex:colon.location + 1] intValue];
		*outHost = [*outHost substringToIndex:colon.location];
		if( *outPort <= 0 ) *outPort = defaultPort;
	}
	return YES;
}

/* Read one CRLF-terminated line, byte at a time. Header volume is tiny, so the
 * per-call cost is irrelevant and this avoids buffering past the header - which
 * matters more on TLS than it did on a socket, since over-reading here would
 * pull body bytes out of a record we cannot push back. */
- (NSString *)readLine:(OMConn *)conn
{
	char buf[2048];
	int n = 0;
	while( n < (int)sizeof( buf ) - 1 )
	{
		char c;
		ssize_t r = OMConnRead( conn, &c, 1 );
		if( r <= 0 )
			break;
		if( c == '\n' )
			break;
		if( c != '\r' )
			buf[n++] = c;
	}
	buf[n] = 0;
	if( n == 0 )
		return @"";
	return [NSString stringWithUTF8String:buf];
}

- (BOOL)fetchOneURL:(NSString *)url toPath:(NSString *)destPath error:(NSString **)err
{
	return [self fetchOneURL:url toPath:destPath depth:0 error:err];
}

- (BOOL)fetchOneURL:(NSString *)url toPath:(NSString *)destPath depth:(int)depth error:(NSString **)err
{
	NSString *host = nil, *path = nil, *status, *line;
	int port = 80, code = 0;
	long long have = 0, total = -1, got = 0;
	struct stat st;
	FILE *out = NULL;
	char *buf;
	NSString *req, *connErr = nil;
	OMConn *conn;
	BOOL partial = NO, ok = NO, useTLS = NO;

	/* A mirror that redirects in a loop would otherwise recurse until the stack
	 * gives out. Five hops is far more than any real chain. */
	if( depth > 5 )
	{
		if( err ) *err = @"too many redirects";
		return NO;
	}

	if( ![self parseURL:url host:&host port:&port path:&path tls:&useTLS] )
	{
		if( err ) *err = [NSString stringWithFormat:@"not an http or https URL: %@", url];
		return NO;
	}

	/* An https source with no root bundle is a build or packaging fault, not a
	 * network one. Say which, rather than connecting without verification: an
	 * unverified session would give away the only thing https was added for. */
	if( useTLS && caBundlePath == nil )
	{
		if( err ) *err = @"this source needs https but the root certificate list is missing from the app";
		return NO;
	}

	/* resume point */
	if( stat( [destPath fileSystemRepresentation], &st ) == 0 )
		have = (long long)st.st_size;

	[self log:[NSString stringWithFormat:@"connecting to %@:%d%@%@", host, port,
		( useTLS ? @" over https" : @"" ), ( have > 0 ? @" (resuming)" : @"" )]];

	conn = OMConnOpen( host, port, useTLS, caBundlePath, &connErr );
	if( conn == NULL )
	{
		if( err ) *err = ( connErr != nil ? connErr :
			[NSString stringWithFormat:@"cannot connect to %@:%d", host, port] );
		return NO;
	}
	if( useTLS )
		[self log:[NSString stringWithFormat:@"  TLS established, %s", OMConnCipherName( conn )]];

	req = [NSString stringWithFormat:
		@"GET %@ HTTP/1.1\r\nHost: %@\r\nUser-Agent: OldMacHalfLife-ModInstaller/1.0\r\n"
		 "Accept: */*\r\nConnection: close\r\n%@\r\n",
		path, host,
		( have > 0 ? [NSString stringWithFormat:@"Range: bytes=%lld-\r\n", have] : @"" )];
	{
		const char *r = [req UTF8String];
		if( !OMConnWriteAll( conn, r, strlen( r )))
		{
			OMConnClose( conn );
			if( err ) *err = [NSString stringWithFormat:@"could not send the request to %@", host];
			return NO;
		}
	}

	status = [self readLine:conn];
	{
		NSArray *parts = [status componentsSeparatedByString:@" "];
		if( [parts count] >= 2 )
			code = [[parts objectAtIndex:1] intValue];
	}

	/* headers */
	while( 1 )
	{
		line = [self readLine:conn];
		if( [line length] == 0 )
			break;
		if( [[line lowercaseString] hasPrefix:@"content-length:"] )
			total = OMLongLong( [[line substringFromIndex:15]
				stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] );
		else if( [[line lowercaseString] hasPrefix:@"content-range:"] )
			partial = YES;
		else if( [[line lowercaseString] hasPrefix:@"location:"] && ( code == 301 || code == 302 || code == 303 || code == 307 ))
		{
			NSString *loc = [[line substringFromIndex:9]
				stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			OMConnClose( conn );
			[self log:[NSString stringWithFormat:@"redirected -> %@", loc]];
			/* A hop to https used to be fatal here. It is now just another hop, and
			 * it is the common case: archive.org's /download/ endpoint bounces to a
			 * storage node, and runthinkshootlive's download.php bounces to
			 * files.runthinkshootlive.com. Both are followed by the same code. */
			return [self fetchOneURL:loc toPath:destPath depth:depth + 1 error:err];
		}
	}

	if( code == 200 && have > 0 )
	{
		/* Server ignored Range and is sending the whole file: start over. */
		[self log:@"server ignored Range - restarting from 0"];
		have = 0;
	}
	else if( code == 206 && partial )
	{
		if( total >= 0 ) total += have;   /* Content-Length is the REMAINDER on a 206 */
	}
	else if( code == 416 )
	{
		/* Range Not Satisfiable: we asked to resume from at-or-past the end, i.e.
		 * the file on disk is already complete. Not an error. */
		OMConnClose( conn );
		[self log:@"already fully downloaded"];
		return YES;
	}
	else if( code != 200 )
	{
		OMConnClose( conn );
		if( err ) *err = [NSString stringWithFormat:@"HTTP %d from %@", code, host];
		return NO;
	}

	out = fopen( [destPath fileSystemRepresentation], have > 0 ? "ab" : "wb" );
	if( out == NULL )
	{
		OMConnClose( conn );
		if( err ) *err = [NSString stringWithFormat:@"cannot write %@", destPath];
		return NO;
	}

	buf = (char *)malloc( OM_BUFSZ );
	if( buf == NULL ) { fclose( out ); OMConnClose( conn ); if( err ) *err = @"out of memory"; return NO; }

	got = have;
	{
		double lastReport = -1.0;
		while( 1 )
		{
			ssize_t r;

			if( [sink omCancelled] )
			{
				[self log:@"cancelled - partial file kept for resume"];
				if( err ) *err = @"cancelled";
				break;
			}

			/* EINTR is retried inside OMConnRead for both transports, so a negative
			 * here is a real failure. On TLS it can also mean a truncation attack
			 * (a close with no close_notify), which is precisely a case we do not
			 * want silently treated as a complete file. */
			r = OMConnRead( conn, buf, OM_BUFSZ );
			if( r < 0 )
			{
				if( err ) *err = @"network read failed";
				break;
			}
			if( r == 0 )
			{
				/* clean EOF: complete only if we got everything we were promised */
				if( total < 0 || got >= total )
					ok = YES;
				else if( err )
					*err = [NSString stringWithFormat:
						@"connection closed early (%lld of %lld bytes)", got, total];
				break;
			}

			if( fwrite( buf, 1, (size_t)r, out ) != (size_t)r )
			{
				if( err ) *err = @"write failed (disk full?)";
				break;
			}
			got += r;

			if( total > 0 )
			{
				double frac = (double)got / (double)total;
				if( frac - lastReport >= 0.002 )   /* ~500 updates over the whole file */
				{
					lastReport = frac;
					[sink omProgress:frac];
					[sink omStatus:[NSString stringWithFormat:@"Downloading - %lld of %lld MB",
						got / 1048576, total / 1048576]];
				}
			}
		}
	}

	free( buf );
	fclose( out );
	OMConnClose( conn );
	return ok;
}

- (BOOL)fetchURLs:(NSArray *)urls toPath:(NSString *)destPath error:(NSString **)err
{
	unsigned i;
	NSString *lastErr = @"no URLs given";

	for( i = 0; i < [urls count]; i++ )
	{
		NSString *url = [urls objectAtIndex:i];
		NSString *e = nil;

		[sink omStatus:[NSString stringWithFormat:@"Downloading (source %u of %u)...", i + 1, (unsigned)[urls count]]];
		if( [self fetchOneURL:url toPath:destPath error:&e] )
			return YES;

		lastErr = ( e != nil ? e : @"unknown error" );
		if( [lastErr isEqualToString:@"cancelled"] )
			break;                                  /* user asked to stop; do not try mirrors */
		[self log:[NSString stringWithFormat:@"source %u failed: %@", i + 1, lastErr]];
	}

	if( err != NULL )
		*err = lastErr;
	return NO;
}

@end
