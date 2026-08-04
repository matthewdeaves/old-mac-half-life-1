/*
 * om_mbedtls_config.h - mbedTLS tuning for "Half-Life Mods.app".
 *
 * This is an MBEDTLS_USER_CONFIG_FILE, not a replacement config. mbedTLS includes
 * it AFTER its own include/mbedtls/mbedtls_config.h, so the stock configuration
 * stands and this file only takes things away. That is deliberate: the stock
 * config is the combination upstream actually tests, and a hand-written minimal
 * config is a long tail of "I switched off something TLS needed" build failures
 * for a few hundred KB that nobody on this app is counting.
 *
 * WHY THE INSTALLER HAS ITS OWN mbedTLS AT ALL
 * -------------------------------------------
 * The engine vendors mbedTLS too (3rdparty/mbedtls, see patch-mbedtls-oldmac.py),
 * but that one is the 4.x line with the tf-psa-crypto split, and its old-macOS
 * clock fix routes mbedtls_ms_time() through the ENGINE's Platform_DoubleTime().
 * There is no engine here, so this app pins its own mbedTLS 3.6 LTS instead: one
 * tree, C99, and supported. See vendor/MANIFEST.md for the pin.
 *
 * MEASURED ON THE BUILD MINI, not assumed:
 *   ppc  (gcc-4.0, 10.3.9 SDK)  107 of 109 files under library/ compile clean
 *   x86_64 (clang, 10.7 SDK)    108 of 108 compile clean
 * The two ppc failures are the two files handled below.
 */

#ifndef OM_MBEDTLS_CONFIG_H
#define OM_MBEDTLS_CONFIG_H

/*
 * 1. No clock_gettime before macOS 10.12.
 *
 * library/platform_util.c computes mbedtls_ms_time() from
 * clock_gettime(CLOCK_MONOTONIC), a symbol Apple only shipped in 10.12, and its
 * #else arm is a hard `#error "No mbedtls_ms_time available"`. That is the exact
 * error gcc-4.0 gives against the 10.3.9 SDK. Selecting the ALT compiles that
 * whole block out and leaves us to supply the function; OMTLS.m does it with
 * gettimeofday(), which has been there since well before 10.3.
 *
 * Same shape of problem as the engine's, different fix, because the engine's
 * answer (Platform_DoubleTime) does not exist in this app.
 */
#define MBEDTLS_PLATFORM_MS_TIME_ALT

/*
 * 2. We bring our own sockets.
 *
 * library/net_sockets.c does not compile against the 10.3.9 SDK either:
 *   net_sockets.c:527: error: 'suseconds_t' undeclared
 * No loss. OMDownload.m has spoken to these mirrors over a BSD socket since the
 * first release, and it has to keep that code anyway for the plain-http sources,
 * so mbedTLS is driven through mbedtls_ssl_set_bio() with our own send/recv.
 * Dropping MBEDTLS_NET_C is what stops the file being needed at all.
 */
#undef MBEDTLS_NET_C

/*
 * 3. No timing side-channel helper.
 *
 * MBEDTLS_TIMING_C is only used for DTLS retransmission timers and the
 * self-tests, neither of which exist here, and library/timing.c is another
 * gettimeofday-vs-clock_gettime liability on 10.3 for no benefit.
 */
#undef MBEDTLS_TIMING_C

/*
 * 4. Client only, TCP only.
 *
 * This app makes outbound HTTPS GETs and nothing else. Turning off the server
 * side and DTLS is not a size optimisation, it is a reduction in the amount of
 * attack surface a 20-year-old machine is running.
 */
#undef MBEDTLS_SSL_SRV_C
#undef MBEDTLS_SSL_PROTO_DTLS
#undef MBEDTLS_SSL_DTLS_ANTI_REPLAY
#undef MBEDTLS_SSL_DTLS_HELLO_VERIFY
#undef MBEDTLS_SSL_DTLS_SRTP
#undef MBEDTLS_SSL_DTLS_CLIENT_PORT_REUSE

/*
 * 5. No certificate writing, no CSRs, no CRLs.
 *
 * We verify a server chain against a fixed root bundle. We never issue anything,
 * and CRL fetching would need a second network stack we do not have. Revocation
 * is not checked; that is stated plainly in the README rather than implied.
 */
#undef MBEDTLS_X509_CSR_PARSE_C
#undef MBEDTLS_X509_CRT_WRITE_C
#undef MBEDTLS_X509_CSR_WRITE_C
#undef MBEDTLS_X509_CREATE_C

/*
 * 6. Self-tests out.
 *
 * mbedtls_*_self_test() is a large amount of code and constant data that only
 * runs from programs/test, which we do not build.
 */
#undef MBEDTLS_SELF_TEST

/*
 * WHAT IS DELIBERATELY LEFT ON, because the real endpoints need it.
 *
 * Certificate chains, measured against the live hosts:
 *
 *   github.com, codeload.github.com
 *       Sectigo Public Server Authentication Root E46 (ECC), ECDSA leaf
 *   raw./objects./release-assets.githubusercontent.com
 *       ISRG Root YR -> Let's Encrypt YR2, RSA leaf
 *   files.runthinkshootlive.com
 *       GTS Root R4 (ECC), ECDSA leaf
 *
 * So BOTH ECDSA and RSA chain verification are required. Do not "trim" either:
 * dropping RSA loses the githubusercontent hosts, dropping ECDSA loses
 * github.com and runthinkshootlive.
 *
 * TLS 1.3 is left enabled and is what all five hosts actually negotiate with
 * this build (omtls-test, x86_64/10.7). 1.2 is only the floor, set in OMTLS.m.
 * An earlier reading of "TLS 1.2 everywhere" came from probing with
 * `openssl -tls1_2`, which forces the version rather than reporting it.
 *
 * Both AES-GCM and ChaCha20-Poly1305 stay in. ChaCha is what four of the five
 * hosts pick, and it is also the one we want on PowerPC: a G3 and a G4 have no
 * AES instructions, and ChaCha20 is add-rotate-xor on 32-bit words, which is
 * what those chips are good at. OMTLS.m puts it first in the offer list there.
 *
 * ChaCha20 is also the one we want to win on PowerPC. A G3 and a G4 have no AES
 * instructions, and ChaCha20 is a much better fit for them, so it is left in the
 * offer list ahead of AES-GCM on that slice (see OMTLS.m).
 */

#endif /* OM_MBEDTLS_CONFIG_H */
