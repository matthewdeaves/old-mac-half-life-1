/*
 * oldmac PPC endian-graft compatibility block.
 *
 * The big-endian save/restore and node-graph fixes we graft onto each hlsdk mod
[removed]
 * fork) call LittleLong/LittleShort/LittleFloat and the in-place *SW variants.
 *
 * When that fork was made, `common/byteswap.h` did not exist upstream, so it
 * created the file. FWGS master has since added its OWN common/byteswap.h with a
 * completely different API (Swap16/Swap32/Swap64/FloatAsUint) that does NOT
 * define any of the Little* helpers. So on any mod branch cut from a recent
 * master the graft cannot create the header - it has to extend it.
 *
 * scripts/graft-ppc-endian.sh appends this block to common/byteswap.h (creating
 * a minimal header first if the branch predates upstream's). Everything is
 * #ifndef-guarded, so appending twice, or to a header that already supplies the
 * helpers, is harmless.
 */
#ifndef OLDMAC_BYTESWAP_COMPAT_H
#define OLDMAC_BYTESWAP_COMPAT_H

#include "build.h"

#ifndef LittleLong
#ifdef XASH_BIG_ENDIAN
#define LittleLong(x) (((int)(((x)&255)<<24)) + ((int)((((x)>>8)&255)<<16)) + ((int)(((x)>>16)&255)<<8) + (((x) >> 24)&255))
#define LittleLongSW(x) (x = LittleLong(x) )
#define LittleShort(x) ((short)( (((short)(x) >> 8) & 255) + (((short)(x) & 255) << 8)))
#define LittleShortSW(x) (x = LittleShort(x) )
static float LittleFloat( float f )
{
	union
	{
		float f;
		unsigned char b[4];
	} dat1, dat2;

	dat1.f = f;
	dat2.b[0] = dat1.b[3];
	dat2.b[1] = dat1.b[2];
	dat2.b[2] = dat1.b[1];
	dat2.b[3] = dat1.b[0];

	return dat2.f;
}
#else
#define LittleLong(x) (x)
#define LittleLongSW(x)
#define LittleShort(x) (x)
#define LittleShortSW(x)
#define LittleFloat(x) (x)
#endif // XASH_BIG_ENDIAN
#endif // LittleLong

#endif // OLDMAC_BYTESWAP_COMPAT_H
