#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Give the multiplayer name dialog a working Escape key (issue #29).
#
# CMenuPlayerIntroduceDialog::KeyDown swallows Escape and does nothing with it:
#
#   if( UI::Key::IsEscape( key ) )
#   {
#       return true; // handled
#   }
#
# Returning true claims the key is handled, so the base class never sees it and
# the dialog cannot be dismissed from the keyboard. `CMenuYesNoMessageBox::KeyDown`,
# which this overrides, would have done Hide() plus onNegative(), and onNegative
# here is exactly the Cancel action: hide the dialog, hide the caller.
#
# WHY THIS MATTERS MORE THAN IT LOOKS
#
# The dialog appears whenever the `name` cvar is still the default, which is
# every fresh install, and it is two clicks from the main menu. On 10.3.9 and
# 10.4.11 the menu frame rate collapses while it is up, so the mouse cursor is
# only sampled once per frame, clicks land on stale focus and OK and Cancel stop
# responding. That leaves no way out at all: two of the four bench machines had
# to be killed from another computer. Escape working is what turns a dead end
# back into an inconvenience.
#
# The frame-rate collapse itself is NOT fixed here and is still open on #29. The
# leading candidate is SDL's Cocoa text input adding an AppKit subview over the
# NSOpenGL content view, which pre-Leopard AppKit then composites every frame.
# That is why this fix is worth having on its own: it does not depend on
# understanding the stall, and it costs nothing on machines that do not stall.
#
# Escape now does what Cancel does rather than falling through to the base class,
# so the caller menu is hidden too. Falling through would hide only the dialog
# and leave the Multiplayer menu behind it, which is not what Cancel does and
# would look like a half-dismissed dialog.
#
# Applies to mainui in both trees, where the file is identical. Idempotent.
# Python 2.5+.
import os
import sys

MARKER = 'oldmac: Escape must dismiss this dialog'

ANCHOR = """	if( UI::Key::IsEscape( key ) )
	{
		return true; // handled
	}
"""

NEW = """	if( UI::Key::IsEscape( key ) )
	{
		// """ + MARKER + """. Upstream swallowed the key and
		// returned "handled", which left no keyboard way out. On 10.3 and 10.4
		// the menu frame rate collapses while this dialog is up, so OK and
		// Cancel stop responding to the mouse as well, and the machine has to be
		// killed from outside. Do what Cancel does: hide this dialog and the
		// menu that opened it. See GitHub issue #29.
		//
		// This is character for character what CMenuYesNoMessageBox::KeyDown
		// does for Escape, which is the base class this overrides. onNegative is
		// defaulted to NoopCb in _Init, so it never needs a null check.
		Hide();
		onNegative( this );
		return true;
	}
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
		print('usage: patch-mainui-name-dialog-escape.py <mainui-dir-or-PlayerIntroduceDialog.cpp> ...')
		return 1
	for arg in sys.argv[1:]:
		if os.path.isdir(arg):
			patch(os.path.join(arg, 'menus', 'PlayerIntroduceDialog.cpp'))
		else:
			patch(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
