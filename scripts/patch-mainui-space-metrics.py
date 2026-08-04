#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Fix the space character's advance width, which truncated every multi-word
# string in the menu (issue #27).
#
# SYMPTOM
#
# In the Custom Game list every mod title was drawn only up to its first space:
# "They" for They Hunger, "Blue" for Blue Shift, "Opposing" for Opposing Force,
# "Half-Life:" for Half-Life: Echoes. Single-word titles were whole, and
# hyphens, colons, apostrophes and brackets all survived. Not a column width and
# not an ellipsis: "Half-Screwed" at 12 characters rendered fully while "They" at
# 4 did not.
#
# CAUSE
#
# CStbFont::GetCharABCWidthsNoCache reads an uninitialised stack variable.
#
#     int x0, x1;
#     stbtt_GetGlyphBox( &m_fontInfo, glyphId, &x0, NULL, &x1, NULL );
#     width = x1 - x0;
#
# stb_truetype's stbtt_GetGlyphBox returns 0 WITHOUT writing any of its output
# parameters when the glyph has a zero-length outline: stbtt__GetGlyfOffset
# returns -1 for an empty glyf entry, and GetGlyphBox bails on that before its
# first store. The return value is discarded here, so x0 and x1 keep whatever
# was on the stack and `width` is garbage.
#
# The space is the only printable ASCII character this can happen to, for two
# reasons that have to coincide:
#
#   1. It is the only one with no outline. In the shipped menu font,
#      gfx/fonts/FiraSans-Regular.ttf, U+0020 is glyph 2 and loca[2] == loca[3],
#      so its outline length is zero.
#   2. It is the only one that never gets pre-measured. FontManager uploads the
#      printable range starting at 0x21 '!', so ' ' always misses the ABC cache
#      and always takes this uncached path. The garbage is then cached, so every
#      row and every string gets the same wrong number.
#
# CBaseFont::DrawCharacter special-cases the space and advances the pen by
# a + b + c, so a negative result moves the pen far to the left and the rest of
# the string is drawn outside the visible area. That is why the text vanishes
# cleanly with no ellipsis rather than being cut short: a positive garbage value
# would instead have tripped the width limiter and produced "They...".
#
# FIX
#
# Initialise the box to zero and honour the return value. A glyph with no outline
# has no ink, so a zero-width box is the correct description of it, and the
# advance then falls out of the horizontal metrics alone:
#
#     a + b + c  ==  horiBearingX + 0 + ( horiAdvance - horiBearingX - 0 )
#                ==  horiAdvance
#
# which is exactly the space's real advance width from the font's hmtx table.
#
# The read is in upstream's own code and is there on every target. Whether it
# MANIFESTS depends on what happened to be in those two stack slots, which
# varies with compiler and optimisation level, so a build that looks fine is
# benign by luck rather than correct.
#
# Applies to mainui. Idempotent. Python 2.5+.
import os
import sys

MARKER = 'oldmac: a glyph with no outline leaves the box untouched'

ANCHOR = """	int x0, x1;
	int width, horiBearingX, horiAdvance;

	stbtt_GetGlyphBox( &m_fontInfo, glyphId, &x0, NULL, &x1, NULL );
	stbtt_GetCodepointHMetrics( &m_fontInfo, ch, &horiAdvance, &horiBearingX );
	width = x1 - x0;
"""

NEW = """	// """ + MARKER + """.
	// stbtt_GetGlyphBox returns 0 without writing ANY of its outputs when the
	// glyph's outline length is zero, which for the shipped menu font is exactly
	// one character: the space. Its return value was discarded and x0/x1 were
	// uninitialised, so the space got a garbage advance width. A negative one
	// throws the pen off to the left and everything after the first space in a
	// string is drawn off screen, which is what truncated every multi-word mod
	// title in Custom Game. See GitHub issue #27.
	//
	// Zero is the right box for a glyph with no ink: a + b + c then reduces to
	// horiAdvance, the space's real advance from the font's hmtx table.
	int x0 = 0, x1 = 0;
	int width, horiBearingX, horiAdvance;

	if( !stbtt_GetGlyphBox( &m_fontInfo, glyphId, &x0, NULL, &x1, NULL ))
		x0 = x1 = 0;
	stbtt_GetCodepointHMetrics( &m_fontInfo, ch, &horiAdvance, &horiBearingX );
	width = x1 - x0;
"""


def patch(path):
	s = open(path).read()
	if MARKER in s:
		print('already patched: ' + path)
		return
	n = s.count(ANCHOR)
	assert n == 1, ('anchor found %d times (want 1) in %s' % (n, path))
	open(path, 'w').write(s.replace(ANCHOR, NEW, 1))
	print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-space-metrics.py <mainui-dir-or-StbFont.cpp> ...')
		return 1
	for arg in sys.argv[1:]:
		if os.path.isdir(arg):
			patch(os.path.join(arg, 'font', 'StbFont.cpp'))
		else:
			patch(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
