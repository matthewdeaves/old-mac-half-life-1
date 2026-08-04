/*
 * OMTLS.m - one connection type that is either a plain socket or a TLS session.
 *
 * WHY THIS EXISTS
 * ---------------
 * Until now this app could only speak plain HTTP, because PowerPC has no TLS in
 * this project and 10.3-10.7's system TLS cannot negotiate the ciphers modern
 * hosts require. That was fine while the only source was one mirror that served
 * plain HTTP. It is not fine now that each mod is fetched from wherever that mod
 * is actually published, because almost everything on the web is https-only:
 *
 *   moddb.com, gamebanana.com, runthinkshootlive.com, twhl.info, hl-improvement,
 *   csm.dev  - every one of them answers a plain-http request with 301 -> https.
 *
 * So the app carries its own TLS instead of doing without. mbedTLS 3.6 LTS,
 * pinned in vendor/MANIFEST.md, built for both slices alongside this app. That
 * is a client-side TLS stack in the INSTALLER only; the engine's own HTTPS
 * situation on PowerPC is a separate question and is untouched by this.
 *
 * WHAT IT HAS TO SPEAK, measured against the live endpoints rather than assumed:
 *
 *   files.runthinkshootlive.com   GTS Root R4 (ECC), ECDSA leaf
 *   github.com, codeload          Sectigo Public Server Auth Root E46, ECDSA
 *   *.githubusercontent.com       ISRG Root YR -> Let's Encrypt YR2, RSA leaf
 *   archive.org                   (plain http also works, and is preferred there)
 *
 * Both ECDSA and RSA chains, so neither can be trimmed. TLS 1.2 is the floor set
 * below; in practice all five negotiate TLS 1.3, four of them with ChaCha20.
 * Verified by installer/omtls-test.m against the live hosts.
 *
 * A NOTE ON WHAT IS *NOT* REACHABLE EVEN WITH THIS
 * ------------------------------------------------
 * ModDB sits behind Cloudflare and answers a non-browser client with 403 before
 * any of this matters. TLS does not help there and neither would anything else
 * short of pretending to be a browser, so ModDB is not a source. That is why the
 * source list leans on runthinkshootlive and archive.org.
 */

#import "OldMacMods.h"

#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"
#include "mbedtls/ssl_ciphersuites.h"
/*
 * Included for MBEDTLS_ERR_NET_SEND_FAILED / _RECV_FAILED only. We do not build
 * library/net_sockets.c (it does not compile against the 10.3.9 SDK, and we have
 * our own sockets), but those two constants are what the SSL layer expects a BIO
 * callback to return on a hard failure, and the header defines them
 * unconditionally rather than behind MBEDTLS_NET_C. Nothing else here is used.
 */
#include "mbedtls/net_sockets.h"

/* ------------------------------------------------------- the ALT ms clock -- */
/*
 * om_mbedtls_config.h selects MBEDTLS_PLATFORM_MS_TIME_ALT, which compiles out
 * library/platform_util.c's clock_gettime(CLOCK_MONOTONIC) path. Apple only
 * shipped clock_gettime in 10.12; without the ALT, that file fails to build
 * against the 10.3.9 SDK with a bare `#error "No mbedtls_ms_time available"`.
 *
 * gettimeofday is not monotonic, so this can step if the clock is set while a
 * download runs. mbedTLS uses this value only for TLS 1.3 / DTLS timers, neither
 * of which we build, so nothing here depends on it advancing smoothly.
 */
mbedtls_ms_time_t mbedtls_ms_time( void )
{
	struct timeval tv;
	gettimeofday( &tv, NULL );
	return (mbedtls_ms_time_t)tv.tv_sec * 1000 + (mbedtls_ms_time_t)tv.tv_usec / 1000;
}

/* ------------------------------------------------------------ the object -- */

struct OMConn
{
	int                       fd;
	BOOL                      tls;
	mbedtls_ssl_context       ssl;
	mbedtls_ssl_config        conf;
	mbedtls_ctr_drbg_context  drbg;
	mbedtls_entropy_context   entropy;
	mbedtls_x509_crt          ca;
	int                      *suites;   /* our reordered preference list, or NULL */
};

/* ------------------------------------------------------------- BIO glue ---- */
/*
 * mbedTLS drives the socket through these rather than through its own
 * net_sockets.c, which we do not compile: that file does not build against the
 * 10.3.9 SDK ("'suseconds_t' undeclared"). Using our own is no loss, since this
 * app has always had to carry a socket layer for the plain-http sources.
 */
static int om_bio_send( void *ctx, const unsigned char *buf, size_t len )
{
	int fd = *(int *)ctx;
	ssize_t n = send( fd, buf, len, 0 );
	if( n < 0 )
	{
		if( errno == EINTR || errno == EAGAIN )
			return MBEDTLS_ERR_SSL_WANT_WRITE;
		return MBEDTLS_ERR_NET_SEND_FAILED;
	}
	return (int)n;
}

static int om_bio_recv( void *ctx, unsigned char *buf, size_t len )
{
	int fd = *(int *)ctx;
	ssize_t n = recv( fd, buf, len, 0 );
	if( n < 0 )
	{
		if( errno == EINTR || errno == EAGAIN )
			return MBEDTLS_ERR_SSL_WANT_READ;
		return MBEDTLS_ERR_NET_RECV_FAILED;
	}
	return (int)n;
}

/* ----------------------------------------------------------- ciphersuites -- */
/*
 * Put ChaCha20-Poly1305 ahead of everything else on PowerPC.
 *
 * A G3 and a G4 have no AES instructions, so AES-GCM there is a software cipher
 * doing a table-driven round function plus a carry-less multiply; ChaCha20 is
 * add-rotate-xor on 32-bit words, which is exactly what these chips are good at.
 * Both of our primary hosts offer ChaCha, so on PowerPC we simply ask for it
 * first and let the server agree.
 *
 * This REORDERS, it never truncates: every suite mbedTLS offered by default is
 * still in the list, just after the ChaCha ones. Truncating to ChaCha-only would
 * silently lock out any host that does not offer it. Returns NULL to mean "use
 * the library default", which is also what happens if the allocation fails.
 */
static int *om_preferred_suites( void )
{
#ifdef __ppc__
	const int *def = mbedtls_ssl_list_ciphersuites();
	int n = 0, i, w = 0;
	int *out;

	while( def[n] != 0 )
		n++;

	out = (int *)malloc( sizeof( int ) * (size_t)( n + 1 ));
	if( out == NULL )
		return NULL;

	for( i = 0; i < n; i++ )
	{
		const char *name = mbedtls_ssl_get_ciphersuite_name( def[i] );
		if( name != NULL && strstr( name, "CHACHA20" ) != NULL )
			out[w++] = def[i];
	}
	for( i = 0; i < n; i++ )
	{
		const char *name = mbedtls_ssl_get_ciphersuite_name( def[i] );
		if( name == NULL || strstr( name, "CHACHA20" ) == NULL )
			out[w++] = def[i];
	}
	out[w] = 0;
	return out;
#else
	return NULL;
#endif
}

/* ---------------------------------------------------------- error wording -- */
/*
 * Turn a verify-flags word into something a person can act on.
 *
 * The one that matters on this fleet is the clock. A Power Mac whose PRAM
 * battery has died - which after twenty years is most of them - boots with a
 * date in 1970 or 2001, and then EVERY certificate on the internet is "not yet
 * valid". The generic mbedTLS wording for that is "certificate verification
 * failed", which reads exactly like a corrupt download or a broken mirror and
 * sends people looking in the wrong place. So that case is named outright, with
 * the machine's own current date quoted back, because seeing "1970" is usually
 * the whole diagnosis.
 */
static NSString *om_verify_message( unsigned int flags )
{
	if( flags & ( MBEDTLS_X509_BADCERT_EXPIRED | MBEDTLS_X509_BADCERT_FUTURE ))
	{
		NSString *now = [[NSDate date] descriptionWithCalendarFormat:@"%Y-%m-%d"
			timeZone:nil locale:nil];
		return [NSString stringWithFormat:
			@"the server's certificate looks out of date, but the more likely cause is "
			 "this Mac's own clock: it currently says %@. Set the date and time "
			 "correctly (a dead PRAM battery resets it at every boot) and try again.", now];
	}
	if( flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED )
		return @"the server's certificate is not signed by any root this app carries. "
		        "The bundled root list ages; a newer one can be dropped in beside the app.";
	if( flags & MBEDTLS_X509_BADCERT_CN_MISMATCH )
		return @"the server's certificate is for a different host name";
	return [NSString stringWithFormat:@"certificate verification failed (flags 0x%08x)", flags];
}

static NSString *om_mbed_message( int ret )
{
	char buf[256];
	mbedtls_strerror( ret, buf, sizeof( buf ));
	return [NSString stringWithFormat:@"%s (-0x%04x)", buf, (unsigned)-ret];
}

/* ------------------------------------------------------------- connecting -- */

static int om_tcp_connect( NSString *host, int port )
{
	struct hostent *he;
	struct sockaddr_in addr;
	int fd, one = 1;

	/* gethostbyname rather than getaddrinfo, matching OMDownload: present and
	 * reliable on 10.3, and none of these mirrors are v6-only. */
	he = gethostbyname( [host UTF8String] );
	if( he == NULL || he->h_addr_list[0] == NULL )
		return -1;

	fd = socket( AF_INET, SOCK_STREAM, 0 );
	if( fd < 0 )
		return -1;

	memset( &addr, 0, sizeof( addr ));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((unsigned short)port );
	memcpy( &addr.sin_addr, he->h_addr_list[0], (size_t)he->h_length );

	if( connect( fd, (struct sockaddr *)&addr, sizeof( addr )) < 0 )
	{
		close( fd );
		return -1;
	}

	/* Header writes are small and we want them out now, not coalesced with a
	 * handshake record that has not been produced yet. */
	setsockopt( fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof( one ));
	return fd;
}

OMConn *OMConnOpen( NSString *host, int port, BOOL useTLS, NSString *caBundlePath, NSString **err )
{
	OMConn *c;
	int ret;

	c = (OMConn *)calloc( 1, sizeof( OMConn ));
	if( c == NULL )
	{
		if( err ) *err = @"out of memory";
		return NULL;
	}

	c->fd = om_tcp_connect( host, port );
	if( c->fd < 0 )
	{
		free( c );
		if( err ) *err = [NSString stringWithFormat:@"cannot connect to %@:%d", host, port];
		return NULL;
	}

	if( !useTLS )
	{
		c->tls = NO;
		return c;
	}

	c->tls = YES;
	mbedtls_ssl_init( &c->ssl );
	mbedtls_ssl_config_init( &c->conf );
	mbedtls_ctr_drbg_init( &c->drbg );
	mbedtls_entropy_init( &c->entropy );
	mbedtls_x509_crt_init( &c->ca );

	/* Seed. The builtin entropy poll reads /dev/urandom through fopen on anything
	 * unix-like, which 10.3 is; getentropy() would have been 10.12+. */
	ret = mbedtls_ctr_drbg_seed( &c->drbg, mbedtls_entropy_func, &c->entropy,
		(const unsigned char *)"oldmac-halflife-mods", 20 );
	if( ret != 0 )
	{
		if( err ) *err = [NSString stringWithFormat:@"could not seed the random generator: %@",
			om_mbed_message( ret )];
		OMConnClose( c );
		return NULL;
	}

	/* Roots. Loaded from a file rather than compiled in so the list can be
	 * replaced without a new binary when a CA rotates - Sectigo's E46 root on
	 * github.com is a live example of that happening. */
	ret = mbedtls_x509_crt_parse_file( &c->ca, [caBundlePath fileSystemRepresentation] );
	if( ret < 0 )
	{
		if( err ) *err = [NSString stringWithFormat:@"could not read the root certificate list (%@): %@",
			caBundlePath, om_mbed_message( ret )];
		OMConnClose( c );
		return NULL;
	}

	ret = mbedtls_ssl_config_defaults( &c->conf, MBEDTLS_SSL_IS_CLIENT,
		MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT );
	if( ret != 0 )
	{
		if( err ) *err = om_mbed_message( ret );
		OMConnClose( c );
		return NULL;
	}

	/* Verification is REQUIRED, not optional. The whole point of adding TLS is
	 * that we are now fetching from hosts we do not control, so an unverified
	 * session would buy nothing that plain http did not already give us. */
	mbedtls_ssl_conf_authmode( &c->conf, MBEDTLS_SSL_VERIFY_REQUIRED );
	mbedtls_ssl_conf_ca_chain( &c->conf, &c->ca, NULL );
	mbedtls_ssl_conf_rng( &c->conf, mbedtls_ctr_drbg_random, &c->drbg );
	mbedtls_ssl_conf_min_tls_version( &c->conf, MBEDTLS_SSL_VERSION_TLS1_2 );

	c->suites = om_preferred_suites();
	if( c->suites != NULL )
		mbedtls_ssl_conf_ciphersuites( &c->conf, c->suites );

	ret = mbedtls_ssl_setup( &c->ssl, &c->conf );
	if( ret != 0 )
	{
		if( err ) *err = om_mbed_message( ret );
		OMConnClose( c );
		return NULL;
	}

	/* SNI. Every one of our hosts is virtual-hosted; without this they answer
	 * with the wrong certificate or refuse outright. */
	ret = mbedtls_ssl_set_hostname( &c->ssl, [host UTF8String] );
	if( ret != 0 )
	{
		if( err ) *err = om_mbed_message( ret );
		OMConnClose( c );
		return NULL;
	}

	mbedtls_ssl_set_bio( &c->ssl, &c->fd, om_bio_send, om_bio_recv, NULL );

	while(( ret = mbedtls_ssl_handshake( &c->ssl )) != 0 )
	{
		if( ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE )
			continue;

		if( ret == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED )
		{
			unsigned int flags = mbedtls_ssl_get_verify_result( &c->ssl );
			if( err ) *err = [NSString stringWithFormat:@"%@: %@", host, om_verify_message( flags )];
		}
		else if( err )
		{
			*err = [NSString stringWithFormat:@"TLS handshake with %@ failed: %@",
				host, om_mbed_message( ret )];
		}
		OMConnClose( c );
		return NULL;
	}

	return c;
}

/* ------------------------------------------------------------------- i/o -- */

const char *OMConnCipherName( OMConn *c )
{
	if( c == NULL || !c->tls )
		return "plain";
	return mbedtls_ssl_get_ciphersuite( &c->ssl );
}

ssize_t OMConnRead( OMConn *c, void *buf, size_t len )
{
	if( c == NULL )
		return -1;

	if( !c->tls )
	{
		ssize_t n;
		do { n = recv( c->fd, buf, len, 0 ); } while( n < 0 && errno == EINTR );
		return n;
	}

	while( 1 )
	{
		int ret = mbedtls_ssl_read( &c->ssl, (unsigned char *)buf, len );
		if( ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE )
			continue;
		/* Both of these mean the peer finished cleanly. Report them as EOF so the
		 * caller's "did I get everything I was promised" check is what decides
		 * whether a short file is an error, exactly as on a plain socket. */
		if( ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY )
			return 0;
		if( ret < 0 )
			return -1;
		return (ssize_t)ret;
	}
}

BOOL OMConnWriteAll( OMConn *c, const void *buf, size_t len )
{
	const unsigned char *p = (const unsigned char *)buf;
	size_t sent = 0;

	if( c == NULL )
		return NO;

	while( sent < len )
	{
		if( !c->tls )
		{
			ssize_t n = send( c->fd, p + sent, len - sent, 0 );
			if( n < 0 && errno == EINTR ) continue;
			if( n <= 0 ) return NO;
			sent += (size_t)n;
		}
		else
		{
			int ret = mbedtls_ssl_write( &c->ssl, p + sent, len - sent );
			if( ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE )
				continue;
			if( ret <= 0 ) return NO;
			sent += (size_t)ret;
		}
	}
	return YES;
}

void OMConnClose( OMConn *c )
{
	if( c == NULL )
		return;

	if( c->tls )
	{
		/* Best effort. If the peer has already gone this fails, and that is not
		 * worth reporting: the transfer either completed or it did not, and the
		 * caller already knows which. */
		mbedtls_ssl_close_notify( &c->ssl );
		mbedtls_ssl_free( &c->ssl );
		mbedtls_ssl_config_free( &c->conf );
		mbedtls_ctr_drbg_free( &c->drbg );
		mbedtls_entropy_free( &c->entropy );
		mbedtls_x509_crt_free( &c->ca );
		if( c->suites != NULL )
			free( c->suites );
	}

	if( c->fd >= 0 )
		close( c->fd );
	free( c );
}
