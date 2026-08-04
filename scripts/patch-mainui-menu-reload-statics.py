#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Rebuild the menu's one-shot startup state after a menu reload (issue #35).
#
# SYMPTOM. On PowerPC the menu dictionary can stop resolving part-way through a
# session, and once it does it never resolves again. Every coded token then
# draws as its own name: GameUI_Audio, GameUI_Video, GameUI_PlayerName,
# GameUI_HighModels, GameUI_EnableVoice. Labels that are literal English in the
# source keep reading correctly, because L() returns its argument on a miss and
# for those the argument is already the English. The console is no help: it
# carries the Localize_AddToDict lines from the FIRST, successful load, so the
# dictionary looks loaded while nothing in it can be found.
#
# WHAT IS NOT THE CAUSE. Everything in MenuStrings.cpp is correct on big-endian
# and was measured to be so on a G4 (10.4.11) with the shipped toolchain and the
# shipped flags, gcc-4.0.1 -arch ppc -mcpu=7400 -faltivec -O3 -maltivec
# -fno-rtti against the 10.3.9 SDK: the whole of Localize_Init replayed on the
# shipped configs/gameui_english.txt inserts 107 keys and misses none, through
# the engine's own COM_ParseFileSafe, the real Localize_ProcessString, the real
# CUtlHashMap and the real MurmurHash3_32. The hash, the hashmap, the parser and
# the file are all sound. The dictionary is not failing to load. It is being
# thrown away after it has loaded, and never rebuilt.
#
# SECOND SYMPTOM, found on hardware after the first fix shipped. Switch renderer
# once on a G5 (10.5.8, ppc970, measured 2026-07-28) and the main menu comes back
# with NO items drawn at all. The two BaseMenu.cpp one-shots below were already
# fixed in that build and were doing their job; a THIRD one-shot was missed, in
# CFontManager::VidInit. See the FontManager section further down.
#
# CAUSE. Three pieces of once-per-run state are function-local statics:
#
#	UI_VidInit()    static bool calledOnce = false;   // gates UI_Precache()
#	UI_UpdateMenu() static bool loadStuff = true;     // gates UI_LoadCustomStrings()
#	CFontManager::VidInit() static float prevScale = 0; // gates the font rebuild
#
# Both belong to one LOAD of the menu library, but a function-local static
# belongs to the IMAGE. The engine unloads and reloads that image whenever the
# renderer changes: VID_CheckChanges compares r_refdll with r_refdll_loaded and
# calls R_ChangeRenderer, which does UI_UnloadProgs() then UI_LoadProgs().
# UI_UnloadProgs calls the menu's UI_Shutdown, which calls UI_FreeCustomStrings
# -> Localize_Free: every key and value is delete[]d and hashed_cmds is Purged.
# It also deletes every menu object and memsets uiStatic. Then COM_FreeLibrary
# calls dlclose, and UI_LoadProgs dlopens the library again.
#
# On Darwin PowerPC that dlclose does not unload anything. Measured on
# mini-g4, 10.4.11, gcc-4.0.1: dlopen a dylib, dlclose it (returns 0), dlopen it
# again, and the static constructor does NOT run a second time and a
# function-local static keeps the value it was left with. The same program on
# mini-intel, 10.7.5, x86_64 DOES re-run the constructor and DOES reset the
# static. That is the whole of the Intel/PowerPC split.
#
# So on PowerPC, after a renderer change:
#
#   - loadStuff is still false, so UI_LoadCustomStrings and therefore
#     Localize_Init are never called again. hashed_cmds stays empty for the rest
#     of the session and L() returns its argument for every key.
#   - calledOnce is still true, so UI_Precache is skipped and the menus that
#     UI_Shutdown just deleted are never re-created. ADD_MENU3's
#     `static type *cmd` is deleted without being cleared, so every subsequent
#     Show() runs on freed memory.
#
# On Intel both statics come back at their initial values, both blocks re-run,
# and neither fault is reachable.
#
# The renderer changes on this fleet: a first run auto-selects, and the Video
# menu exposes the selector. Whichever way it is reached, one change is enough,
# and the effect is permanent for that session.
#
# FIX. Move all three one-shots into uiStatic. UI_Shutdown already does
# `memset( &uiStatic, 0, sizeof( uiStatic_t ))`, so the flags are cleared by
# exactly the event that invalidates what they guard, whether or not the image
# is unloaded. A reload then re-precaches the menus and rebuilds the dictionary,
# which is what the code always meant. Correct on both endiannesses and on both
# trees, and it does not depend on any dlclose behaviour.
#
# Ordering: independent of the other mainui patches. Applies to both trees, the
# three anchored blocks are byte-identical in each. Idempotent. Python 2.5+.
import os
import sys

MARKER = 'oldmac: menu-lifetime one-shots, NOT function statics'
MARKER_CPP = 'oldmac: one-shot lives in uiStatic, not a function-local static'

# The header gained a third field in rev 2, so a tree carrying the rev 1 header
# holds a SUPERSEDED body: it has the marker, it would be skipped, and the menu
# would come back from a renderer switch with no text on it. Version the header
# guard so that case is an error instead of a silent pass. See issue #39 and
# scripts/reset-vendor-trees.sh, which is the only thing that can clear it.
MARKER_REV = MARKER + ' (rev 2)'
MARKER_FONT = 'oldmac: font scale one-shot lives in uiStatic (issue #35)'

# ---------------------------------------------------------------- BaseMenu.h

HDR_ANCHOR = (
	'\tint lowmemory;\n'
	'\n'
	'\tchar sounds[SND_COUNT][40];\n'
	'} uiStatic_t;\n'
)

HDR_NEW = (
	'\tint lowmemory;\n'
	'\n'
	'\t// ' + MARKER_REV + ' (issue #35).\n'
	'\t// UI_Shutdown() memsets this struct, so a menu unload/reload clears\n'
	'\t// these by the very event that invalidates what they guard. A Darwin\n'
	'\t// dlclose() does not reliably unload the menu library, and a\n'
	'\t// function-local static then survives the reload that R_ChangeRenderer\n'
	'\t// performs, leaving the dictionary freed and never rebuilt.\n'
	'\tbool precached;     // UI_Precache() has run since the last UI_Shutdown()\n'
	'\tbool startupLoaded; // background, dictionary and script config are loaded\n'
	'\tfloat fontScale;    // scaleY the current font set was built at, 0 if none\n'
	'\n'
	'\tchar sounds[SND_COUNT][40];\n'
	'} uiStatic_t;\n'
)

# -------------------------------------------------------------- BaseMenu.cpp

VIDINIT_ANCHOR = (
	'int UI_VidInit( void )\n'
	'{\n'
	'\tstatic bool calledOnce = false;\n'
)

VIDINIT_NEW = (
	'int UI_VidInit( void )\n'
	'{\n'
	'\t// ' + MARKER_CPP + ': UI_Shutdown()\n'
	'\t// deletes every menu object, and only this flag can tell us to build\n'
	'\t// them again. See uiStatic_t in BaseMenu.h (issue #35).\n'
	'\tconst bool calledOnce = uiStatic.precached;\n'
)

VIDINIT_SET_ANCHOR = '\tif( !calledOnce ) calledOnce = true;\n'
VIDINIT_SET_NEW = '\tif( !calledOnce ) uiStatic.precached = true;\n'

UPDATE_ANCHOR = (
	'\tstatic bool loadStuff = true;\n'
	'\n'
	"\t// can't do this in Init, since these are dependent on cvar values\n"
	'\t// set from user configs\n'
	'\tif( loadStuff )\n'
	'\t{\n'
	'\t\t// load background bitmaps\n'
	'\t\tCMenuBackgroundBitmap::LoadBackground( );\n'
	'\n'
	'\t\t// load localized strings\n'
	'\t\tUI_LoadCustomStrings();\n'
	'\n'
	'\t\t// load scr\n'
	'\t\tUI_LoadScriptConfig();\n'
	'\n'
	'\t\tloadStuff = false;\n'
	'\t}\n'
)

UPDATE_NEW = (
	"\t// can't do this in Init, since these are dependent on cvar values\n"
	'\t// set from user configs\n'
	'\t// ' + MARKER_CPP + ', so a menu\n'
	'\t// unload/reload rebuilds the dictionary instead of running for the rest\n'
	'\t// of the session with an empty one. See uiStatic_t in BaseMenu.h (#35).\n'
	'\tif( !uiStatic.startupLoaded )\n'
	'\t{\n'
	'\t\t// load background bitmaps\n'
	'\t\tCMenuBackgroundBitmap::LoadBackground( );\n'
	'\n'
	'\t\t// load localized strings\n'
	'\t\tUI_LoadCustomStrings();\n'
	'\n'
	'\t\t// load scr\n'
	'\t\tUI_LoadScriptConfig();\n'
	'\n'
	'\t\tuiStatic.startupLoaded = true;\n'
	'\t}\n'
)


# ---------------------------------------------------- font/FontManager.cpp
#
# The third one-shot, and the one that is actually visible. Measured on the dual
# G5 (10.5.8, ppc970) on 2026-07-28: switch renderer once and the main menu comes
# back with NO items drawn at all. The two fixes above are in that build and do
# their job; this is what was left.
#
# CFontManager::VidInit() rebuilds the font set only when the scale has changed,
# and it tracks that in a function-local static. But the font HANDLES it produces
# live in uiStatic (hDefaultFont, hSmallFont, hBigFont, hBoldFont, hConsoleFont),
# and UI_Shutdown() memsets uiStatic. So after a renderer change the handles are
# all zero while prevScale still holds the old scale. The resolution has not
# changed, so `fabs( scale - prevScale ) > 0.1f` is false and `!prevScale` is
# false, VidInit skips the whole block, and every label in the menu is drawn with
# a null font handle. Nothing appears.
#
# It needs the same treatment as the other two: keep the one-shot in the struct
# that gets cleared by the event that invalidates it. Then a reload sees
# fontScale == 0, takes the branch, and rebuilds the fonts the handles point to.
#
# On Intel dlclose does unload the image, so prevScale resets by itself and the
# fault is not reachable there. The change is correct on both regardless, and
# both trees carry byte-identical text here.

FONT_ANCHOR = (
	'void CFontManager::VidInit( void )\n'
	'{\n'
	'\tstatic float prevScale = 0;\n'
)

FONT_NEW = (
	'void CFontManager::VidInit( void )\n'
	'{\n'
	'\t// ' + MARKER_FONT + '.\n'
	'\t// The font HANDLES this builds live in uiStatic, and UI_Shutdown()\n'
	'\t// memsets that. Tracking the scale in a function-local static instead\n'
	'\t// meant a renderer reload found the handles zeroed and the scale\n'
	'\t// unchanged, skipped the rebuild, and drew the whole menu with null\n'
	'\t// fonts. Measured on a G5, 10.5.8: no menu items at all.\n'
	'\tfloat prevScale = uiStatic.fontScale;\n'
)

FONT_SET_ANCHOR = '\t\tprevScale = scale;\n'
FONT_SET_NEW = '\t\tuiStatic.fontScale = scale;\n'


def replace_once(src, anchor, new, what, path):
	n = src.count(anchor)
	assert n == 1, ('%s anchor found %d times (want 1) in %s' % (what, n, path))
	return src.replace(anchor, new, 1)


def inspect(path, edits, done_marker, stale_marker=None):
	"""Decide what to do with one file WITHOUT writing it.

	Returns ('done'|'apply'|'superseded', payload). Nothing is written until
	every file in the tree has been inspected: a run that patched file A and
	then failed on file B used to leave the tree in a state no re-run could
	complete, because A then reported 'already patched' forever.
	"""
	assert os.path.isfile(path), ('no such file: %s' % path)
	src = open(path).read()
	if done_marker in src:
		return ('done', None)
	if stale_marker is not None and stale_marker in src:
		return ('superseded', None)
	for anchor, new, what in edits:
		src = replace_once(src, anchor, new, what, path)
	return ('apply', src)


def patch_tree(mainui):
	hdr = os.path.join(mainui, 'BaseMenu.h')
	cpp = os.path.join(mainui, 'BaseMenu.cpp')
	font = os.path.join(mainui, 'font', 'FontManager.cpp')

	plan = [
		(hdr, [(HDR_ANCHOR, HDR_NEW, 'uiStatic_t tail')], MARKER_REV, MARKER),
		(cpp, [
			(VIDINIT_ANCHOR, VIDINIT_NEW, 'UI_VidInit calledOnce'),
			(VIDINIT_SET_ANCHOR, VIDINIT_SET_NEW, 'UI_VidInit calledOnce set'),
			(UPDATE_ANCHOR, UPDATE_NEW, 'UI_UpdateMenu loadStuff'),
		], MARKER_CPP, None),
		(font, [
			(FONT_ANCHOR, FONT_NEW, 'CFontManager::VidInit prevScale'),
			(FONT_SET_ANCHOR, FONT_SET_NEW, 'CFontManager::VidInit prevScale set'),
		], MARKER_FONT, None),
	]

	results = []
	for path, edits, done, stale in plan:
		state, payload = inspect(path, edits, done, stale)
		if state == 'superseded':
			raise AssertionError(
				'%s carries the rev 1 marker.\n'
				'         That body is SUPERSEDED: it lacks uiStatic.fontScale, so a\n'
				'         renderer switch brings the menu back with no text on it. A\n'
				'         marker-guarded script cannot correct a superseded body, so\n'
				'         this is an error rather than a silent skip (issue #39).\n'
				'         Run scripts/reset-vendor-trees.sh on this host to return the\n'
				'         tree to its pin, then build again.' % path)
		results.append((path, state, payload))

	for path, state, payload in results:
		if state == 'done':
			print('already patched: ' + path)
			continue
		open(path, 'w').write(payload)
		print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-menu-reload-statics.py <mainui-dir> ...')
		return 1
	for arg in sys.argv[1:]:
		assert os.path.isdir(arg), ('not a mainui directory: %s' % arg)
		patch_tree(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
