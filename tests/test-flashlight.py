#!/usr/bin/env python3
"""Run the actual dynamic-light accumulator against world-space geometry.

Use --source with the saved pre-fix gl_rsurf.c to demonstrate the regression.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, default=ROOT/'vendor/engine-src/ref/gl/gl_rsurf.c')
p.add_argument('--emit', type=Path)
a = p.parse_args()
s = a.source.read_text()
start = s.index('static void R_AddDynamicLights(')
pos = s.index('{', start)
depth = 1
end = pos + 1
while depth:
    depth += (s[end] == '{') - (s[end] == '}')
    end += 1
fn = s[start:end]
stub = r'''
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
typedef float vec3_t[3];
typedef unsigned int uint;
typedef int qboolean;
#define MAX_DLIGHTS 1
#define BIT(x) (1u << (x))
#define FBitSet(x,b) ((x)&(b))
#define TEX_WORLD_LUXELS 1
#define TEX_EXTRA_LIGHTMAP 2
#define LM_SAMPLE_EXTRASIZE 8
#define LM_SAMPLE_SIZE 16
#define Q_max(a,b) ((a)>(b)?(a):(b))
#define Q_min(a,b) ((a)<(b)?(a):(b))
#define DotProduct(a,b) ((a)[0]*(b)[0]+(a)[1]*(b)[1]+(a)[2]*(b)[2])
#define VectorCopy(a,b) memcpy(b,a,sizeof(vec3_t))
#define VectorScale(a,v,b) do { for(int _i=0;_i<3;_i++) (b)[_i]=(a)[_i]*(v); } while(0)
#define VectorMA(a,v,c,b) do { for(int _i=0;_i<3;_i++) (b)[_i]=(a)[_i]+(v)*(c)[_i]; } while(0)
#define CrossProduct(a,b,c) do { (c)[0]=(a)[1]*(b)[2]-(a)[2]*(b)[1]; (c)[1]=(a)[2]*(b)[0]-(a)[0]*(b)[2]; (c)[2]=(a)[0]*(b)[1]-(a)[1]*(b)[0]; } while(0)
#define VectorLength(a) sqrtf(DotProduct(a,a))
typedef struct { float normal[3],dist; int type; } plane_t;
#define PlaneDiff(a,p) (DotProduct(a,(p)->normal)-(p)->dist)
typedef struct { int texture_step; } faceinfo_t;
typedef struct { int flags; faceinfo_t *faceinfo; } mtexinfo_t;
typedef struct { float lmvecs[2][4]; float lightmapmins[2]; } mextrasurf_t;
typedef struct { uint dlightbits; mtexinfo_t *texinfo; plane_t *plane; mextrasurf_t *info; } msurface_t;
typedef struct { vec3_t origin; float radius,minlight; struct { unsigned char r,g,b; } color; } dlight_t;
static dlight_t gp_dlights[1];
static struct { int modelviewIdentity; } tr={1};
static struct { float objectMatrix[16]; } RI;
static struct { float value; } r_dlight_spherical={1};
static uint r_blocklights[3*64*64];
static void Matrix4x4_VectorITransform(const float *m,const float *a,float *b) { (void)m; VectorCopy(a,b); }
'''
main = r'''
int main(void) {
    int failed=0, checked=0;
    // Every face passes through P. Its only luxel is P, so each must receive
    // the same contribution regardless of plane angle or texture mapping.
    const vec3_t point={12,23,34};
    const vec3_t light={52,43,64};
    const float scales[]={1,1.0f/3,2,0.0625f};
    gp_dlights[0].radius=240;
    VectorCopy(light,gp_dlights[0].origin);
    gp_dlights[0].color.r=gp_dlights[0].color.g=gp_dlights[0].color.b=85;
    const uint expected=((int)((240-sqrtf(2900))*256)*85)/256;
    for(int angle=0;angle<180;angle+=15)
    for(int scale=0;scale<4;scale++)
    for(int skew=0;skew<2;skew++)
    for(int world=0;world<2;world++) {
        float r=angle*3.14159265358979323846f/180;
        plane_t plane={{cosf(r),sinf(r),0},0,3};
        plane.dist=DotProduct(point,plane.normal);
        mtexinfo_t tex={world?TEX_WORLD_LUXELS:0,NULL};
        mextrasurf_t info={{{0}}, {0}};
        // Tangent axes plus normal components. These are valid affine
        // texture mappings but normalizing their lengths is not an inverse.
        info.lmvecs[0][0]=-sinf(r)*scales[scale]+0.4f*cosf(r);
        info.lmvecs[0][1]= cosf(r)*scales[scale]+0.4f*sinf(r);
        info.lmvecs[0][2]=skew*0.2f;
        info.lmvecs[1][2]=scales[(scale+1)%4];
        for(int j=0;j<2;j++) info.lightmapmins[j]=DotProduct(point,info.lmvecs[j]);
        msurface_t surf={1,&tex,&plane,&info};
        memset(r_blocklights,0,sizeof(r_blocklights));
        R_AddDynamicLights(&surf,16,1,1);
        checked++;
        if(abs((int)r_blocklights[0]-(int)expected)>1) {
            if(failed<4) printf("FAIL angle=%d scale=%g skew=%d world=%d got=%u expected=%u\n",angle,scales[scale],skew,world,r_blocklights[0],expected);
            failed++;
        }
    }
    printf("%d shared-point cases, %d failed\n",checked,failed);
    return failed!=0;
}
'''
source=stub+fn+main
if a.emit:
    a.emit.write_text(source)
with tempfile.TemporaryDirectory(prefix='flashlight-test-') as td:
    c=Path(td)/'test.c'; exe=Path(td)/'test'
    c.write_text(source)
    subprocess.run(['cc','-std=c99','-O2','-Wall','-Wextra','-fsanitize=undefined,address',str(c),'-lm','-o',str(exe)],check=True)
    raise SystemExit(subprocess.run([str(exe)]).returncode)
