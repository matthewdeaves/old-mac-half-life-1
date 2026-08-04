#!/usr/bin/env python
# -*- coding: utf-8 -*-
# task #6: re-enable the bundled mbedTLS (built-in HTTPS) on old macOS.
#
# The vendored mbedTLS (tf-psa-crypto) computes its millisecond clock in
# tf-psa-crypto/platform/platform_util.c via clock_gettime(CLOCK_MONOTONIC),
# a symbol Apple only shipped in macOS 10.12. On 10.7-10.11 that fails, which is
# why build-lion.sh carried --disable-mbedtls (no built-in HTTPS).
#
# The engine already ships an override: 3rdparty/mbedtls/compat.c defines
# mbedtls_ms_time() in terms of the engine's own Platform_DoubleTime() whenever
# MBEDTLS_PLATFORM_MS_TIME_ALT is defined - but xash_psa_config.h only defines
# that for Vita/Switch. This patch extends it to old macOS. With the ALT clock
# selected, platform_util.c's clock_gettime path is #if'd out and compat.c's
# impl is used instead, so mbedTLS builds and links clean against the 10.7 SDK.
#
# Everything else mbedTLS needs already works on 10.7:
#   - entropy: __APPLE__ && __MACH__ sets MBEDTLS_PLATFORM_IS_UNIXLIKE, so the
#     builtin get_entropy reads /dev/random via fopen (no getentropy(), 10.12+).
#   - psa_crypto_random.c uses gettimeofday(), present since forever.
#
# The guard is version-scoped (MAC_OS_X_VERSION_MIN_REQUIRED < 101200) so a
# modern-macOS build (arm64 dev box) is unaffected and keeps clock_gettime.
# Idempotent on the 'oldmac-mbedtls-ms-time' sentinel. Python 2.5+.
import sys

GUARD = 'oldmac-mbedtls-ms-time'
ANCHOR = (
    '#if defined( __vita__ ) || defined( __SWITCH__ )\n'
    '/* Upstream has no Vita/NSW support; compat.c fills in */\n'
    '#define MBEDTLS_PLATFORM_MS_TIME_ALT\n'
    '#endif\n')
ADD = ANCHOR + (
    '\n'
    '/* oldmac-mbedtls-ms-time (task#6): macOS before 10.12 has no clock_gettime();\n'
    "   route mbedtls_ms_time() through the engine's Platform_DoubleTime() (see\n"
    '   3rdparty/mbedtls/compat.c) so the clock_gettime path in\n'
    '   tf-psa-crypto/platform/platform_util.c is compiled out. Version-scoped so a\n'
    '   modern-macOS build keeps clock_gettime and is unaffected. */\n'
    '#if defined( __APPLE__ )\n'
    '#include <AvailabilityMacros.h>\n'
    '#if !defined( MAC_OS_X_VERSION_10_12 ) || \\\n'
    '    ( defined( MAC_OS_X_VERSION_MIN_REQUIRED ) && MAC_OS_X_VERSION_MIN_REQUIRED < 101200 )\n'
    '#define MBEDTLS_PLATFORM_MS_TIME_ALT\n'
    '#endif\n'
    '#endif\n')

for f in sys.argv[1:]:
    s = open(f).read()
    if GUARD in s:
        print('already patched:', f)
        continue
    assert ANCHOR in s, ('mbedtls MS_TIME_ALT anchor not found in ' + f)
    s = s.replace(ANCHOR, ADD, 1)
    open(f, 'w').write(s)
    print('patched:', f)
