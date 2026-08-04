#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Drop the console font when the renderer that owns its texture goes (issue #43).
#
# SYMPTOM. Switch renderer at runtime, gl to soft and back to gl, and the build
# string in the bottom right corner comes back as garbage: the right number of
# glyphs in the right places, drawn from the wrong pixels. Reported on the dual
# G5 on 10.5.8, with legible-before and garbled-after screenshots. The console
# overlay itself is drawn with the same font and is affected the same way.
#
# CAUSE. A cl_font_t owns a texture handle, `hFontTexture`, allocated by
# whichever renderer was loaded when the font was built. Switching renderer
# tears that renderer down:
#
#	R_ShutdownInternal:
#		...free every clgame sprite...
#		Mod_FreeAll();
#		R_UnloadProgs( preserve_video_cvars );   // R_Shutdown, then dlclose
#
# Sprites and models are released first, deliberately, because their texture
# handles die with the renderer. `CL_ClearSpriteTextures` exists for the same
# reason on the way back up. The console fonts were missed. Nothing frees them
# and nothing marks them stale, so `con.chars[i].valid` stays true across the
# switch.
#
# On the way back up, SCR_VidInit calls Con_VidInit calls Con_LoadConchars,
# which calls Con_LoadConsoleFont for each size, and that begins:
#
#	if( font->valid )
#		return; // already loaded
#
# So nothing is reloaded. `con.curFont->hFontTexture` still holds a texture
# number handed out by the renderer that has been unloaded, and the new
# renderer has since handed that same number to some unrelated texture. The
# glyph rectangles are still right, which is why the string keeps its shape and
# spacing while the pixels are wrong.
#
# FIX. Free the fonts in R_ShutdownInternal, next to the sprites and models it
# already frees, and before R_UnloadProgs. Con_InvalidateFonts does exactly
# this: CL_FreeFont on every entry, then con.curFont = NULL. The ordering
# matters: CL_FreeFont calls ref.dllFuncs.GL_FreeTexture, so it has to run while
# the OLD renderer is still loaded, which is why the call goes before
# R_UnloadProgs rather than after it. Con_VidInit then rebuilds the fonts
# against the new renderer, because valid is false again.
#
# Every consumer of con.curFont already guards against NULL (Con_DrawConsole,
# Con_DrawNotify, Con_CheckResize) or against !font->valid (CL_DrawString,
# CL_DrawStringLen), so the window between shutdown and Con_VidInit draws
# nothing rather than faulting.
#
# Con_InvalidateFonts is defined without `static` but forward-declared WITH it
# near the top of console.c, which gives it internal linkage. The declaration
# loses its `static` here and the prototype joins the other Con_ entry points in
# client.h.
#
# Applies to both engine trees. They have diverged around this code: the
# PowerPC fork's function is R_ShutdownInternal( qboolean ) in
# engine/client/ref_common.c, mainline's is R_Shutdown( void ) in
# engine/client/dll_int/ref_common.c. Both end the same way, and the anchor is
# the Mod_FreeAll and R_UnloadProgs pair they share. Not endian specific: the
# same stale handle is used on Intel, it is simply less often provoked there
# because nothing pushes an Intel machine onto the software renderer.
#
# Ordering: independent of every other patch. Idempotent. Python 2.5+.
import os
import re
import sys

MARKER = 'oldmac: the console font holds a texture the outgoing renderer owns'

# The forward declaration, which is the only thing keeping the symbol internal.
OLD_DECL = 'static void Con_InvalidateFonts( void );'
NEW_DECL = 'void Con_InvalidateFonts( void );'

# Where the other Con_ prototypes live.
HDR_ANCHOR = 'void Con_VidInit( void );\n'
HDR_NEW = 'void Con_VidInit( void );\nvoid Con_InvalidateFonts( void );\n'

# Anchored on the pair, so a tree that reorders the teardown fails here rather
# than getting the call in the wrong place. The argument list differs between
# the forks, hence the loose tail.
RE_TEARDOWN = re.compile(
	r'(\n([ \t]*)Mod_FreeAll\(\);\n)'
	r'([ \t]*R_UnloadProgs\()'
)


def call(indent):
	lines = []
	lines.append('%s// %s,' % (indent, MARKER))
	lines.append('%s// so it has to go the same way the sprites above just did, and for the' % indent)
	lines.append('%s// same reason. CL_FreeFont calls through ref.dllFuncs.GL_FreeTexture, so' % indent)
	lines.append('%s// this MUST run before R_UnloadProgs unloads the library. Without it' % indent)
	lines.append('%s// con.chars[] keep valid = true, Con_LoadConsoleFont returns early on the' % indent)
	lines.append('%s// way back up, and every glyph is then sampled from whatever texture the' % indent)
	lines.append('%s// new renderer put in the dead handle\'s slot. Issue #43: the build string' % indent)
	lines.append('%s// came back as garbage after gl to soft and back.' % indent)
	lines.append('%sCon_InvalidateFonts();' % indent)
	return '\n' + '\n'.join(lines) + '\n'


def find_ref_common(engine):
	"""The forks keep it in different places."""
	for rel in ('engine/client/ref_common.c', 'engine/client/dll_int/ref_common.c'):
		path = os.path.join(engine, rel)
		if os.path.isfile(path):
			return path
	raise AssertionError('no ref_common.c under %s' % engine)


def patch_console(path):
	src = open(path).read()
	if OLD_DECL not in src:
		assert NEW_DECL in src, ('no Con_InvalidateFonts declaration in %s' % path)
		print('declaration already external: ' + path)
		return
	assert src.count(OLD_DECL) == 1, ('Con_InvalidateFonts declared %d times (want 1) in %s'
	                                  % (src.count(OLD_DECL), path))
	open(path, 'w').write(src.replace(OLD_DECL, NEW_DECL, 1))
	print('patched: ' + path)


def patch_header(path):
	src = open(path).read()
	if NEW_DECL in src:
		print('already declared: ' + path)
		return
	assert src.count(HDR_ANCHOR) == 1, ('Con_VidInit prototype found %d times (want 1) in %s'
	                                    % (src.count(HDR_ANCHOR), path))
	open(path, 'w').write(src.replace(HDR_ANCHOR, HDR_NEW, 1))
	print('patched: ' + path)


def patch_ref_common(path):
	src = open(path).read()
	if MARKER in src:
		print('already patched: ' + path)
		return
	found = RE_TEARDOWN.findall(src)
	assert len(found) == 1, ('renderer teardown anchor found %d times (want 1) in %s'
	                         % (len(found), path))

	def sub(m):
		return m.group(1) + call(m.group(2)) + m.group(3)

	open(path, 'w').write(RE_TEARDOWN.sub(sub, src, 1))
	print('patched: ' + path)


def patch_tree(engine):
	assert os.path.isdir(engine), ('not an engine directory: %s' % engine)
	patch_console(os.path.join(engine, 'engine', 'client', 'console.c'))
	patch_header(os.path.join(engine, 'engine', 'client', 'client.h'))
	patch_ref_common(find_ref_common(engine))


def main():
	if len(sys.argv) < 2:
		print('usage: patch-con-font-renderer-switch.py <engine-dir> ...')
		return 1
	for arg in sys.argv[1:]:
		patch_tree(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
