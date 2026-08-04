#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch-single-pass-multitexture.py - collapse the two-pass world render (base
texture pass + separate lightmap pass) into ONE immediate-mode multitexture
pass, for the GL renderer of one or more xash3d-fwgs engine trees.

Why this exists
---------------
Profiling the live engine on the Power Mac G3 (ATI Rage 128, GL 1.1, 2 TMUs)
showed it spends ~81% of every frame blocked in CGLFlushDrawable waiting on the
GPU - i.e. it is fillrate / overdraw bound, not CPU bound (see
docs/GL-OPTIMIZATION-CASE-STUDY.md). The dominant overdraw source is that the
non-VBO world path rasterizes every surface twice:

    pass 1  R_DrawTextureChains -> R_RenderBrushPoly -> DrawGLPoly   (base tex)
    pass 2  R_BlendLightmaps    -> DrawGLPolyChain                   (lightmap)

The Rage 128 has exactly 2 texture units and GL_ARB_multitexture +
GL_ARB_texture_env_combine (confirmed live via `r_info`), which is all a single
combined pass needs: TMU0 = base (GL_REPLACE), TMU1 = lightmap (GL_MODULATE, or
a COMBINE x2 for gl_overbright). Collapsing to one glBegin/glEnd halves the
world/brush fragments - the exact thing the profile says we are bound on. VBO is
a dead end here (the driver crashes in glBufferDataARB), so the win must be
captured in immediate mode.

Scope (v1): OPAQUE WORLD ONLY (R_DrawTextureChains). Brush models, alpha/water,
tiled and conveyor surfaces, and the dynamic-lightmap case all keep the classic
two-pass path. Dynamic-lightmap surfaces encountered in the single-pass loop are
drawn base-only and deferred to R_BlendLightmaps for their lightmap, exactly as
before. Gated on a new cvar `gl_singlepass` (default "1") so lighting can be
A/B'd against the classic path at runtime, and auto-disabled when fog is on or
the GPU reports fewer than 2 TMUs.

This script is idempotent: re-running on an already-patched tree is a no-op. It
is also revision-guarded, see MARKER_REV: a tree holding an older body of this
same fix is reported and fails the run rather than passing as "already patched".

Invoke:
    python3 patch-single-pass-multitexture.py <engine-tree> [<engine-tree> ...]
where each <engine-tree> is the root of an xash3d-fwgs checkout (the dir that
contains ref/gl/gl_rsurf.c).
"""
import os
import sys

# Two guards per file, and they do different jobs.
#
# MARKER / CVAR_MARKER answer "is SOME revision of this fix in this file". They
# are the function and cvar names, so they match every body this script has ever
# emitted, including the ones already sitting on the build minis.
#
# MARKER_REV answers "is the CURRENT revision in this file". It is emitted into
# the comments this script writes, and it is what "already patched" tests. A file
# carrying the family marker without MARKER_REV holds a superseded body: the
# anchors it needs are gone, consumed by that older edit, so re-running cannot
# correct it. That case is an ERROR, not a skip.
#
# Issue #39. The 2026-07-27 audit of the two build minis reported this script as
# one of three whose stale output was pinned in place by its own guard: the
# welder-fix comment on those hosts differed from the current one, and the old
# FIX_MARKER and STATIC_FIX_MARKER were substrings of both spellings, so the
# tree read as fully upgraded. The in-place upgrade path this replaces could only
# correct the bodies it enumerated; git history has it if a future one is wanted.
# Bump the revision whenever the emitted C changes.
MARKER = "R_SinglePassBrushPoly"
CVAR_MARKER = "gl_singlepass"
MARKER_REV = "oldmac: single-pass multitexture world render (rev 1)"

# --- ref/gl/gl_opengl.c : define + register the cvar -----------------------

OPENGL_DEF_ANCHOR = 'CVAR_DEFINE_AUTO( gl_overbright, "1", FCVAR_GLCONFIG, "overbrights" );\n'
OPENGL_DEF_LINE = ('// ' + MARKER_REV + '\n'
                   'CVAR_DEFINE_AUTO( gl_singlepass, "1", FCVAR_GLCONFIG, '
                   '"single-pass multitexture world render (base x lightmap in one pass)" );\n')

OPENGL_REG_ANCHOR = '\tgEngfuncs.Cvar_RegisterVariable( &gl_overbright );\n'
OPENGL_REG_LINE = '\tgEngfuncs.Cvar_RegisterVariable( &gl_singlepass );\n'

# --- ref/gl/gl_local.h : extern the cvar -----------------------------------

LOCAL_ANCHOR = 'extern convar_t\tgl_overbright;\n'
LOCAL_LINE = 'extern convar_t\tgl_singlepass;\t// ' + MARKER_REV + '\n'

# --- ref/gl/gl_rsurf.c : the actual renderer work --------------------------

# 1) helper functions + state, inserted immediately before R_RenderBrushPoly.
RSURF_HELPERS = '''/*
================
Single-pass multitexture world render

''' + MARKER_REV + r'''.

Collapse the classic two-pass world render (base texture, then a separate
lightmap geometry pass in R_BlendLightmaps) into one immediate-mode
multitexture draw: TMU0 = base (GL_REPLACE), TMU1 = lightmap (GL_MODULATE, or a
COMBINE x2 when gl_overbright is set). This halves world/brush fragment count on
fillrate-bound GPUs (the ATI Rage 128 is ~81% GPU-blocked per profiling; see
docs/GL-OPTIMIZATION-CASE-STUDY.md). Active only for opaque world surfaces with
a static lightmap; dynamic-lightmap surfaces still defer to R_BlendLightmaps.
================
*/
static qboolean r_singlepass_active = false;

// set up the two texture stages for a run of single-pass world surfaces
static void R_SinglePassBegin( void )
{
	// TMU0: base texture replaces the (white) fragment color
	GL_SelectTexture( XASH_TEXTURE0 );
	pglTexEnvi( GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE );

	// TMU1: lightmap modulated onto the base (x2 if overbright)
	GL_SelectTexture( XASH_TEXTURE1 );
	pglEnable( GL_TEXTURE_2D );
	if( gl_overbright.value )
	{
		pglTexEnvi( GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_COMBINE_ARB );
		pglTexEnvi( GL_TEXTURE_ENV, GL_COMBINE_RGB_ARB, GL_MODULATE );
		pglTexEnvi( GL_TEXTURE_ENV, GL_SOURCE0_RGB_ARB, GL_PREVIOUS_ARB );
		pglTexEnvi( GL_TEXTURE_ENV, GL_SOURCE1_RGB_ARB, GL_TEXTURE );
		pglTexEnvi( GL_TEXTURE_ENV, GL_COMBINE_ALPHA_ARB, GL_REPLACE );
		pglTexEnvi( GL_TEXTURE_ENV, GL_SOURCE0_ALPHA_ARB, GL_PREVIOUS_ARB );
		pglTexEnvi( GL_TEXTURE_ENV, GL_RGB_SCALE_ARB, 2 );
	}
	else
	{
		pglTexEnvi( GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE );
	}
	GL_SelectTexture( XASH_TEXTURE0 );
}

// restore default single-texture state after the single-pass world run
static void R_SinglePassEnd( void )
{
	GL_SelectTexture( XASH_TEXTURE1 );
	pglTexEnvi( GL_TEXTURE_ENV, GL_RGB_SCALE_ARB, 1 );
	pglTexEnvi( GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE );
	pglDisable( GL_TEXTURE_2D );
	GL_SelectTexture( XASH_TEXTURE0 );
	pglTexEnvi( GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE );
}

// draw one surface as base (TMU0, already bound) x static lightmap (TMU1)
static void R_SinglePassBrushPoly( msurface_t *fa )
{
	glpoly2_t	*p = fa->polys;
	float		*v;
	int		i;

	GL_Bind( XASH_TEXTURE1, tr.lightmapTextures[fa->lightmaptexturenum] );

	pglBegin( GL_POLYGON );
	for( i = 0, v = p->verts[0]; i < p->numverts; i++, v += VERTEXSIZE )
	{
		GL_MultiTexCoord2f( XASH_TEXTURE0, v[3], v[4] );
		GL_MultiTexCoord2f( XASH_TEXTURE1, v[5], v[6] );
		pglVertex3fv( v );
	}
	pglEnd();
}

'''

# The welder fix, GitHub issue #30, and the two hazards it missed.
#
# The dynamic-lightmap branch and the static branch of the single-pass fast path
# both carry a fix of their own, and both are emitted inline as part of
# RSURF_BODY_NEW below rather than as separate edits. A tree patched before
# either of them holds a superseded body and is rejected by MARKER_REV.
#
# The welder fix above covered the dynamic-lightmap branch, but R_RenderBrushPoly
# has TWO other exits that draw with TMU1 still armed, and both were missed:
#
#   1. the SURF_DRAWTURB early return, which is opaque WATER
#   2. the classic tail, taken by SURF_DRAWTILED and SURF_CONVEYOR surfaces and
#      by anything with no lightmap
#
# Neither EmitWaterPolys nor DrawGLPoly emits a TMU1 texcoord: both use
# pglTexCoord2f, which by the GL spec writes unit 0's coordinate only. So the
# surface is drawn with TMU1 still enabled, still bound to the PREVIOUS surface's
# lightmap atlas, and sampling one frozen texel left over from that surface's
# last vertex. With gl_overbright on that texel is applied as base x L x 2, so a
# mid-grey texel happens to look right and a bright or shadowed one does not.
#
# That is the reported water bug: a body of water that snaps between two flat
# brightnesses as the camera moves. It tracks the camera because "the previous
# surface" is decided by R_RecursiveWorldNode's front-to-back descent, which
# flips at a node as the viewer crosses its plane, and by which texture chains
# frustum culling leaves non-empty. Both are discrete, hence a snap rather than
# a fade.
#
# Water only reaches this path when it is OPAQUE. With wateralpha < 1 it is
# deferred to R_DrawWaterSurfaces, which runs after R_SinglePassEnd and is safe.
# sv_wateralpha defaults to 1, so the common case is the broken one.
#
# Both fixes are guarded on r_singlepass_active because R_RenderBrushPoly is also
# reached from R_DrawBrushModel and R_DrawAlphaTextureChains, where TMU1 was
# never armed and touching it would be wrong.

# The water site also has to cover the Mod_HaveLightmappedWater() call, which is
# a second lightmap pass in its own right and equally does not want a stale TMU1
# modulating it.
TURB_OLD = """	if( FBitSet( fa->flags, SURF_DRAWTURB ))
	{
		// warp texture
		EmitWaterPolys( fa, cull_type == CULL_BACKSIDE, R_UploadRipples( t ));

		// add lightmaps if requested
		if( Mod_HaveLightmappedWater( ))
			R_RenderLightmapForSurface( fa );

		return;
	}"""

TURB_NEW = """	if( FBitSet( fa->flags, SURF_DRAWTURB ))
	{
		// warp texture.
		//
		// EmitWaterPolys uses pglTexCoord2f, so it sets unit 0's texcoord only:
		// water emits no TMU1 texcoord at all. If the single-pass lightmap stage
		// is still armed we would modulate the whole surface by one frozen texel
		// from whichever world surface happened to be drawn last, which is what
		// made water snap between two brightnesses as the camera moved (#30).
		if( r_singlepass_active )
		{
			GL_SelectTexture( XASH_TEXTURE1 );
			pglDisable( GL_TEXTURE_2D );
			GL_SelectTexture( XASH_TEXTURE0 );
		}

		EmitWaterPolys( fa, cull_type == CULL_BACKSIDE, R_UploadRipples( t ));

		// add lightmaps if requested. This is a second pass in its own right and
		// must not be modulated by the stale stage either, so it stays inside
		// the disabled window.
		if( Mod_HaveLightmappedWater( ))
			R_RenderLightmapForSurface( fa );

		// re-arm for the static single-pass surfaces that follow in this chain
		if( r_singlepass_active )
		{
			GL_SelectTexture( XASH_TEXTURE1 );
			pglEnable( GL_TEXTURE_2D );
			GL_SelectTexture( XASH_TEXTURE0 );
		}
		return;
	}"""

CLASSIC_OLD = """	DrawGLPoly( fa->polys, 0.0f, 0.0f );
	R_RenderDecalsForSurface( fa, cull_type );
	R_RenderLightmapForSurface( fa );
}"""

CLASSIC_NEW = """	// Classic two-pass tail, reached when the single-pass guard above declined:
	// SURF_DRAWTILED, SURF_CONVEYOR, or no lightmap. Same hazard as the water
	// case: the classic path emits no TMU1 texcoord, so a still-armed lightmap
	// stage would modulate by a stale texel, and R_RenderLightmapForSurface
	// would then add the real lightmap on top of it (#30).
	if( r_singlepass_active )
	{
		GL_SelectTexture( XASH_TEXTURE1 );
		pglDisable( GL_TEXTURE_2D );
		GL_SelectTexture( XASH_TEXTURE0 );
	}

	DrawGLPoly( fa->polys, 0.0f, 0.0f );
	R_RenderDecalsForSurface( fa, cull_type );
	R_RenderLightmapForSurface( fa );

	if( r_singlepass_active )
	{
		GL_SelectTexture( XASH_TEXTURE1 );
		pglEnable( GL_TEXTURE_2D );
		GL_SelectTexture( XASH_TEXTURE0 );
	}
}"""

RSURF_HELPERS_ANCHOR = """/*
================
R_RenderBrushPoly
================
*/
static void R_RenderBrushPoly( msurface_t *fa, int cull_type )
"""

# 2) R_RenderBrushPoly tail: take the single-pass fast path when active.
RSURF_BODY_ANCHOR = """	R_RenderFullbrightForSurface( fa, t );
	R_RenderDetailsForSurface( fa, t );
	DrawGLPoly( fa->polys, 0.0f, 0.0f );
	R_RenderDecalsForSurface( fa, cull_type );
	R_RenderLightmapForSurface( fa );
}"""

RSURF_BODY_NEW = """	R_RenderFullbrightForSurface( fa, t );
	R_RenderDetailsForSurface( fa, t );

	// single-pass world: combine base + lightmap in one multitexture draw for
	// plain static-lightmapped surfaces, halving world overdraw on fillrate-
	// bound GPUs. Tiled/conveyor surfaces and the dynamic-lightmap case keep
	// the classic path. R_CheckLightMap has TexSubImage / cache side effects,
	// so it is called exactly once per surface here (never together with
	// R_RenderLightmapForSurface, which would call it a second time).
	if( r_singlepass_active && fa->polys && !FBitSet( fa->polys->flags, SURF_DRAWTILED|SURF_CONVEYOR ) && R_HasLightmap( ))
	{
		if( R_CheckLightMap( fa ))
		{
			// dynamic lightmap: draw base ONLY now, then defer the real lightmap
			// to R_BlendLightmaps via the dynamic chain (as the classic path).
			// The single-pass TMU1 lightmap stage is still enabled here, so we
			// MUST disable it for this base draw - otherwise DrawGLPoly (which
			// sets no TMU1 texcoords) lets a stale lightmap texel modulate the
			// base, and R_BlendLightmaps then adds the correct lightmap on top,
			// double-lighting the surface. That is the flickering-welder glitch.
			GL_SelectTexture( XASH_TEXTURE1 );
			pglDisable( GL_TEXTURE_2D );
			GL_SelectTexture( XASH_TEXTURE0 );

			fa->info->lightmapchain = gl_lms.dynamic_surfaces;
			gl_lms.dynamic_surfaces = fa;
			DrawGLPoly( fa->polys, 0.0f, 0.0f );

			// re-arm TMU1 for the following static single-pass surfaces (and to
			// keep decal state identical to the static branch below).
			GL_SelectTexture( XASH_TEXTURE1 );
			pglEnable( GL_TEXTURE_2D );
			GL_SelectTexture( XASH_TEXTURE0 );
		}
		else
		{
			// static (or flickering-lightstyle) lightmap is current in
			// tr.lightmapTextures[]. R_CheckLightMap above may have just re-bound
			// TMU0 to the lightmap texture to TexSubImage an animated lightstyle
			// (the welder), so rebind the BASE to TMU0 before the combined draw -
			// otherwise the surface samples lightmap-as-base and flickers.
			GL_Bind( XASH_TEXTURE0, t->gl_texturenum );
			R_SinglePassBrushPoly( fa );
		}
		R_RenderDecalsForSurface( fa, cull_type );
		return;
	}

	DrawGLPoly( fa->polys, 0.0f, 0.0f );
	R_RenderDecalsForSurface( fa, cull_type );
	R_RenderLightmapForSurface( fa );
}"""

# 3) R_DrawTextureChains: arm single-pass + begin before the per-texture loop.
# Anchor on the R_DrawVBO line rather than on the per-texture loop header, whose
# declaration style is more likely to move upstream. The loop header that follows
# is left untouched.
RSURF_CHAINS_ANCHOR = """	R_DrawVBO( !r_fullbright->value && !!WORLDMODEL->lightdata, true );

"""

RSURF_CHAINS_NEW = """	R_DrawVBO( !r_fullbright->value && !!WORLDMODEL->lightdata, true );

	// single-pass world render is opaque-world only, needs 2 TMUs, and is
	// skipped under fog (the classic fog color path handles that).
	r_singlepass_active = gl_singlepass.value && !glState.isFogEnabled && glConfig.max_texture_units >= 2;
	if( r_singlepass_active )
		R_SinglePassBegin();

"""

# 4) R_DrawTextureChains: tear single-pass down after the loop (end of func).
RSURF_END_ANCHOR = """		for( ; s != NULL; s = s->texturechain )
			R_RenderBrushPoly( s, CULL_VISIBLE );
		t->texturechain = NULL;
	}
}

/*
================
R_DrawAlphaTextureChains
================
*/"""

RSURF_END_NEW = """		for( ; s != NULL; s = s->texturechain )
			R_RenderBrushPoly( s, CULL_VISIBLE );
		t->texturechain = NULL;
	}

	if( r_singlepass_active )
	{
		R_SinglePassEnd();
		r_singlepass_active = false;
	}
}

/*
================
R_DrawAlphaTextureChains
================
*/"""


def _need(src, anchor, path, what):
    if anchor not in src:
        print("  ERROR: %s anchor not found in %s" % (what, path))
        return False
    return True


def _superseded(path):
    """This file holds an older body of this fix and cannot be repaired here."""
    print("  ERROR: %s holds a SUPERSEDED revision of this fix." % path)
    print("         Wanted: %s" % MARKER_REV)
    print("         This cannot be repaired in place: reset the tree to its")
    print("         pinned commit (vendor/MANIFEST.md) and re-run the driver.")
    return False


def patch_opengl(tree):
    path = os.path.join(tree, "ref", "gl", "gl_opengl.c")
    if not os.path.isfile(path):
        print("  ERROR (not found): %s" % path)
        return False
    with open(path, "r") as f:
        src = f.read()
    if MARKER_REV in src:
        print("  already patched: %s" % path)
        return True
    if CVAR_MARKER in src:
        return _superseded(path)
    if not (_need(src, OPENGL_DEF_ANCHOR, path, "cvar define") and
            _need(src, OPENGL_REG_ANCHOR, path, "cvar register")):
        return False
    src = src.replace(OPENGL_DEF_ANCHOR, OPENGL_DEF_ANCHOR + OPENGL_DEF_LINE, 1)
    src = src.replace(OPENGL_REG_ANCHOR, OPENGL_REG_ANCHOR + OPENGL_REG_LINE, 1)
    with open(path, "w") as f:
        f.write(src)
    print("  patched: %s" % path)
    return True


def patch_local(tree):
    path = os.path.join(tree, "ref", "gl", "gl_local.h")
    if not os.path.isfile(path):
        print("  ERROR (not found): %s" % path)
        return False
    with open(path, "r") as f:
        src = f.read()
    if MARKER_REV in src:
        print("  already patched: %s" % path)
        return True
    if CVAR_MARKER in src:
        return _superseded(path)
    if not _need(src, LOCAL_ANCHOR, path, "extern"):
        return False
    src = src.replace(LOCAL_ANCHOR, LOCAL_ANCHOR + LOCAL_LINE, 1)
    with open(path, "w") as f:
        f.write(src)
    print("  patched: %s" % path)
    return True


def patch_rsurf(tree):
    path = os.path.join(tree, "ref", "gl", "gl_rsurf.c")
    if not os.path.isfile(path):
        print("  ERROR (not found): %s" % path)
        return False
    with open(path, "r") as f:
        src = f.read()
    if MARKER_REV in src:
        print("  already patched: %s" % path)
        return True
    # Some revision of single-pass is here, but not this one. The welder fix,
    # the water guard and the classic-tail guard are all inside bodies this
    # script cannot re-derive from what is on disk, and the anchors are gone,
    # so this is a reset, not a re-run. Issue #39.
    if MARKER in src:
        return _superseded(path)
    if not (_need(src, RSURF_HELPERS_ANCHOR, path, "helpers/R_RenderBrushPoly") and
            _need(src, RSURF_BODY_ANCHOR, path, "R_RenderBrushPoly body") and
            _need(src, RSURF_CHAINS_ANCHOR, path, "R_DrawTextureChains loop") and
            _need(src, RSURF_END_ANCHOR, path, "R_DrawTextureChains end")):
        return False
    src = src.replace(RSURF_HELPERS_ANCHOR, RSURF_HELPERS + RSURF_HELPERS_ANCHOR, 1)
    src = src.replace(RSURF_BODY_ANCHOR, RSURF_BODY_NEW, 1)
    src = src.replace(RSURF_CHAINS_ANCHOR, RSURF_CHAINS_NEW, 1)
    src = src.replace(RSURF_END_ANCHOR, RSURF_END_NEW, 1)
    # RSURF_BODY_NEW carries the two welder fixes inline, but the water and
    # classic-tail guards (#30) sit in upstream code that RSURF_BODY_NEW does not
    # replace, so they are applied here. Without them the water bug comes back on
    # the next bootstrap. Both are part of this revision, so a tree that has one
    # and not the other is a superseded body and never reaches this point.
    for _old, _new, what in ((TURB_OLD, TURB_NEW, "water"),
                             (CLASSIC_OLD, CLASSIC_NEW, "classic tail")):
        if _old not in src:
            print("  ERROR: %s anchor (#30) not found in %s" % (what, path))
            return False
        src = src.replace(_old, _new, 1)
    with open(path, "w") as f:
        f.write(src)
    print("  patched: %s" % path)
    return True


def patch_tree(tree):
    return patch_opengl(tree) and patch_local(tree) and patch_rsurf(tree)


def main():
    trees = sys.argv[1:]
    if not trees:
        print(__doc__)
        sys.exit(2)
    ok = True
    for tree in trees:
        print("== %s ==" % tree)
        ok = patch_tree(tree) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
