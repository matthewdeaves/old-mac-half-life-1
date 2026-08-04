/*
 * OMTGA.m - minimal Targa decoder.
 *
 * Mod artwork is game.tga, and NSImage on 10.3 reads TIFF/PNG/JPEG/GIF/PDF but
 * not TGA, so we decode it ourselves into an NSBitmapImageRep.
 *
 * Half-Life's game.tga files are 24- or 32-bit true colour, either uncompressed
 * (image type 2) or run-length encoded (type 10). Those two are all we handle;
 * anything else returns nil and the caller just shows no artwork, which is not
 * worth failing an install over.
 */

#import "OldMacMods.h"

/* TGA stores multi-byte fields little-endian; read them a byte at a time so this
 * is correct on PowerPC as well as Intel. */
static unsigned om_u16( const unsigned char *p )
{
	return (unsigned)p[0] | ((unsigned)p[1] << 8);
}

@implementation OMTGA

+ (NSImage *)imageWithContentsOfFile:(NSString *)path
{
	NSData *data = [NSData dataWithContentsOfFile:path];
	if( data == nil )
		return nil;
	return [self imageWithData:data];
}

+ (NSImage *)imageWithData:(NSData *)data
{
	const unsigned char *b;
	unsigned len, idLen, cmapType, imgType, width, height, bpp, descriptor;
	unsigned bytesPerPixel, pixelCount, i, offset;
	unsigned char *rgb = NULL;
	BOOL topDown;
	NSBitmapImageRep *rep;
	NSImage *image;

	if( data == nil )
		return nil;
	len = (unsigned)[data length];
	if( len < 18 )
		return nil;
	b = (const unsigned char *)[data bytes];

	idLen      = b[0];
	cmapType   = b[1];
	imgType    = b[2];
	width      = om_u16( b + 12 );
	height     = om_u16( b + 14 );
	bpp        = b[16];
	descriptor = b[17];

	/* true colour only, uncompressed (2) or RLE (10), 24/32bpp, no colour map */
	if( cmapType != 0 )                        return nil;
	if( imgType != 2 && imgType != 10 )        return nil;
	if( bpp != 24 && bpp != 32 )               return nil;
	if( width == 0 || height == 0 )            return nil;
	if( width > 4096 || height > 4096 )        return nil;   /* sanity */

	bytesPerPixel = bpp / 8;
	pixelCount = width * height;
	/* bit 5 of the descriptor: set means the first row is the TOP row */
	topDown = ( descriptor & 0x20 ) != 0;

	offset = 18 + idLen;
	if( offset > len )
		return nil;

	/* Always emit 24-bit RGB; alpha in mod banners is not meaningful. */
	rgb = (unsigned char *)malloc( pixelCount * 3 );
	if( rgb == NULL )
		return nil;

	if( imgType == 2 )
	{
		if( offset + pixelCount * bytesPerPixel > len ) { free( rgb ); return nil; }
		for( i = 0; i < pixelCount; i++ )
		{
			const unsigned char *src = b + offset + i * bytesPerPixel;
			rgb[i * 3 + 0] = src[2];   /* TGA is BGR(A) */
			rgb[i * 3 + 1] = src[1];
			rgb[i * 3 + 2] = src[0];
		}
	}
	else /* imgType == 10, RLE */
	{
		unsigned out = 0;
		unsigned p = offset;
		while( out < pixelCount )
		{
			unsigned packet, count, k;

			if( p >= len ) { free( rgb ); return nil; }
			packet = b[p++];
			count = ( packet & 0x7F ) + 1;
			if( out + count > pixelCount ) { free( rgb ); return nil; }

			if( packet & 0x80 )   /* run packet: one pixel repeated */
			{
				if( p + bytesPerPixel > len ) { free( rgb ); return nil; }
				for( k = 0; k < count; k++ )
				{
					rgb[( out + k ) * 3 + 0] = b[p + 2];
					rgb[( out + k ) * 3 + 1] = b[p + 1];
					rgb[( out + k ) * 3 + 2] = b[p + 0];
				}
				p += bytesPerPixel;
			}
			else                  /* raw packet: count distinct pixels */
			{
				if( p + count * bytesPerPixel > len ) { free( rgb ); return nil; }
				for( k = 0; k < count; k++ )
				{
					const unsigned char *src = b + p + k * bytesPerPixel;
					rgb[( out + k ) * 3 + 0] = src[2];
					rgb[( out + k ) * 3 + 1] = src[1];
					rgb[( out + k ) * 3 + 2] = src[0];
				}
				p += count * bytesPerPixel;
			}
			out += count;
		}
	}

	/* TGA's default origin is BOTTOM-left; NSBitmapImageRep wants top-left. */
	if( !topDown )
	{
		unsigned row, rowBytes = width * 3;
		unsigned char *tmp = (unsigned char *)malloc( rowBytes );
		if( tmp != NULL )
		{
			for( row = 0; row < height / 2; row++ )
			{
				unsigned char *a = rgb + row * rowBytes;
				unsigned char *c = rgb + ( height - 1 - row ) * rowBytes;
				memcpy( tmp, a, rowBytes );
				memcpy( a, c, rowBytes );
				memcpy( c, tmp, rowBytes );
			}
			free( tmp );
		}
	}

	rep = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:NULL
		              pixelsWide:(int)width
		              pixelsHigh:(int)height
		           bitsPerSample:8
		         samplesPerPixel:3
		                hasAlpha:NO
		                isPlanar:NO
		          colorSpaceName:NSDeviceRGBColorSpace
		             bytesPerRow:(int)( width * 3 )
		            bitsPerPixel:24];
	if( rep == nil ) { free( rgb ); return nil; }

	memcpy( [rep bitmapData], rgb, pixelCount * 3 );
	free( rgb );

	image = [[[NSImage alloc] initWithSize:NSMakeSize( (float)width, (float)height )] autorelease];
	[image addRepresentation:rep];
	[rep release];
	return image;
}

@end
