#!/usr/bin/env python3
"""Compare actual ripple upload functions, with GL calls stubbed, pixel for pixel.

Requires a saved baseline gl_warp.c. Reports CPU timings, not game FPS.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('baseline', type=Path)
p.add_argument('--source', type=Path, default=ROOT / 'vendor/engine-src/ref/gl/gl_warp.c')
p.add_argument('--sanitize', action='store_true')
p.add_argument('--emit', type=Path, help='write standalone C for legacy compiler and hardware checks')
args = p.parse_args()

def functions(path, suffix):
    source = path.read_text()
    source = source[source.index('static void R_GetRippleTextureSize('):]
    return source.replace('R_GetRippleTextureSize', 'R_GetRippleTextureSize' + suffix).replace(
        'R_UploadRipples', 'R_UploadRipples' + suffix)

header = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define RIPPLES_CACHEWIDTH 128
#define Q_max(a,b) ((a) > (b) ? (a) : (b))
#define XASH_TEXTURE0 0
#define IMAGE_HAS_COLOR 1
#define PF_RGBA_32 1
#define TF_NOMIPMAP 1
#define TF_ALLOW_NEAREST 2
#define GL_TEXTURE_2D 1
#define GL_RGBA 1
#define GL_UNSIGNED_BYTE 1
#define Q_snprintf snprintf
#define true 1
#define false 0
typedef int qboolean;
typedef unsigned char byte;
typedef char string[256];
typedef struct { int width,height,depth,flags,type,size,numMips; byte *buffer; } rgbdata_t;
typedef struct { int format; rgbdata_t *original; } gl_texture_t;
typedef struct { unsigned int width,height; int gl_texturenum; unsigned short fb_texturenum,dt_texturenum; char name[16]; } texture_t;
static struct { float value; } r_ripple;
static struct { int framecount; } tr;
static struct { qboolean update; short *curbuf; uint32_t texture[16384]; } g_ripple;
static gl_texture_t texture;
static volatile uint32_t checksum;
static void GL_Bind(int a,int b) { (void)a; (void)b; }
static const gl_texture_t *R_GetTexture(int a) { (void)a; return &texture; }
static int GL_LoadTextureInternal(const char*a,rgbdata_t*b,int c) { (void)a;(void)b;(void)c;return 1; }
static void pglTexImage2D(int a,int b,int c,int w,int h,int d,int e,int f,const void*p) {
    (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;
    checksum += ((const uint32_t*)p)[w*h/2];
}
'''
main = r'''
static double bench(qboolean (*fn)(texture_t*), texture_t *im) {
    clock_t start=clock();
    for(int i=0;i<10000;i++) { tr.framecount++; fn(im); }
    return (double)(clock()-start)/CLOCKS_PER_SEC;
}
int main(void) {
    setvbuf(stdout,NULL,_IOLBF,0);
    short ripple[16384]; uint32_t expected[16384];
    uint32_t *pixels=malloc(1024*1024*4);
    rgbdata_t pic={0}; pic.buffer=(byte*)pixels; texture.original=&pic;
    for(int i=0;i<1024*1024;i++) pixels[i]=(uint32_t)i*2654435761u;
    g_ripple.curbuf=ripple; g_ripple.update=1;
    const int dims[]={16,32,48,64,96,128,192,256,512,1024};
    int cases=0;
    for(int a=0;a<10;a++) for(int b=0;b<10;b++) for(int mode=1;mode<=2;mode++) {
        texture_t im={dims[a],dims[b],1,1,65535,"test"};
        r_ripple.value=mode;
        for(int run=0;run<8;run++) {
            for(int i=0;i<16384;i++) ripple[i]=(short)(rand()%65536-32768);
            tr.framecount++; R_UploadRipplesBefore(&im);
            memcpy(expected,g_ripple.texture,sizeof(expected));
            tr.framecount++; R_UploadRipplesAfter(&im);
            if(memcmp(expected,g_ripple.texture,sizeof(expected))) {
                fprintf(stderr,"pixel mismatch %dx%d mode %d\n",im.width,im.height,mode);return 1;
            }
            cases++;
        }
    }
    printf("%d pixel comparisons passed\n",cases);
    texture_t skinny={1024,1,1,1,65535,"skinny"}; int w,h;
    R_GetRippleTextureSizeAfter(&skinny,&w,&h);
    if(w!=128 || h!=1) { fprintf(stderr,"invalid wide ripple size %dx%d\n",w,h);return 1; }
    tr.framecount++; R_UploadRipplesAfter(&skinny);
    skinny.width=1; skinny.height=1024;
    R_GetRippleTextureSizeAfter(&skinny,&w,&h);
    if(w!=1 || h!=128) { fprintf(stderr,"invalid tall ripple size %dx%d\n",w,h);return 1; }
    tr.framecount++; R_UploadRipplesAfter(&skinny);
    puts("extreme aspect ratios passed");
    texture_t im={128,128,1,1,65535,"bench"};
    for(int pair=0;pair<4;pair++) {
        double before,after;
        if(pair%2) { after=bench(R_UploadRipplesAfter,&im);before=bench(R_UploadRipplesBefore,&im); }
        else { before=bench(R_UploadRipplesBefore,&im);after=bench(R_UploadRipplesAfter,&im); }
        printf("CPU pair %d: before %.6fs after %.6fs reduction %.2f%%\n",pair,before,after,100*(before-after)/before);
    }
    free(pixels);return 0;
}
'''
source = header + functions(args.baseline, 'Before') + functions(args.source, 'After') + main
if args.emit:
    args.emit.write_text(source)
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='halflife-ripple-') as tmp:
    src = Path(tmp) / 'ripples.c'
    src.write_text(source)
    exe = Path(tmp) / 'ripples'
    flags = ['-fsanitize=address,undefined'] if args.sanitize else []
    subprocess.run(['clang', '-O3', '-std=gnu99', *flags, str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
