#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Make panther-sdl2's Cocoa text input survive a stop/start cycle, and stop it
# from building a field editor that belongs to no window (issue #29).
#
# SYMPTOM
#
# On 10.3.9 (G3) and 10.4.11 (G4) no mainui text box accepts typed characters:
# not the Multiplayer name field, not the "enter a player name" modal, not the
# "add an internet game" address modal. Escape and the other non-printable keys
# work in those same dialogs, and the engine console accepts typing normally.
# On 10.5.8 (G5) and 10.7.5 (Intel) every one of those boxes works. The G4 and
# the G5 run the byte identical ppc7400 slice, so the difference is what AppKit
# does at run time, not what we built.
#
# WHY ONLY CHARACTERS GO MISSING
#
# engine/platform/sdl2/host_sdl2.c drops printable SDL_KEYDOWN scancodes while
# SDL_IsTextInputActive() is true, because they are supposed to arrive as
# SDL_TEXTINPUT instead. SDL_IsTextInputActive() is just the SDL_TEXTINPUT event
# state, which SDL_StartTextInput() sets in src/video/SDL_video.c before it ever
# reaches this backend. So the moment SDL_TEXTINPUT stops being generated,
# typing is silently dead while every other key keeps working. That is exactly
# the reported symptom.
#
# SDL_TEXTINPUT is generated from -[SDLTranslatorResponder insertText:], which
# AppKit calls back during the -interpretKeyEvents: in Cocoa_HandleKeyEvent. So
# the failure is that -interpretKeyEvents: on the field editor produces nothing.
#
# WHAT THIS IS NOT
#
# It is not a dangling first responder. Cocoa_StartTextInput calls
# -[NSWindow makeFirstResponder:] on the field editor, but SDLTranslatorResponder
# is a plain NSView subclass and never overrides -acceptsFirstResponder, whose
# NSResponder default is NO. That call therefore returns NO on every OS version,
# including the ones where typing works, and the field editor never becomes the
# first responder in the first place, so releasing it cannot leave the window
# pointing at a dead one. The same reasoning says first responder status is not
# how this works at all: SDL delivers text on 10.5, 10.7 and every later macOS
# with a field editor that is never the first responder.
#
# THE MECHANISM, AND WHAT IS UNPROVEN ABOUT IT
#
# Two source level defects are certain from reading the file:
#
#   1. Cocoa_StopTextInput deallocates the field editor (removeFromSuperview
#      drops the superview's retain, release drops the last one) without telling
#      anything that the input client is going away. AppKit's own NSTextInput
#      clients do the opposite: NSTextView sends -markedTextAbandoned: to the
#      current NSInputManager when it stops being the client. Pre Leopard,
#      -interpretKeyEvents: routes through NSInputManager, which is process wide
#      and keeps a plain, unretained pointer to the last client it saw. Leopard
#      introduced NSTextInputContext and rebuilt -interpretKeyEvents: on top of
#      it, and that context is owned by the view and torn down with it. That is a
#      concrete reason the omission would bite on 10.3 and 10.4 and be harmless
#      on 10.5 and later.
#
#   2. Cocoa_StartTextInput builds the field editor even when there is no window
#      to put it in. SDL_VideoInit calls SDL_StartTextInput() before any window
#      exists, and SDL_SetKeyboardFocus(NULL) runs whenever the window resigns
#      key, so SDL_GetKeyboardFocus() is routinely NULL here. Upstream then sends
#      -addSubview: and -makeFirstResponder: to nil, which does nothing quietly,
#      and leaves a field editor in no window while SDL_IsTextInputActive()
#      reports true. -interpretKeyEvents: on a view that is in no window has no
#      input session to feed.
#
# Defect 1 lines up with the reported split between the console and the menu.
# Key_SetKeyDest(key_console) calls Key_EnableTextInput(true) with no teardown
# first, so the console only ever does a single start. A mainui text box goes
# through CMenuField::_Event, which calls UI_EnableTextInput(false) on
# QM_LOSTFOCUS and UI_EnableTextInput(true) on QM_GOTFOCUS, so moving focus
# between menu controls runs stop then start, over and over. The console path
# never runs the stop.
#
# What is NOT proven: that pre Leopard NSInputManager is what keeps the stale
# pointer. AppKit is closed, and neither mini has a 10.4 SDK to read. What would
# prove it is a one line experiment on the G4: build panther-sdl2 with DEBUG_IME
# defined to NSLog, then log -[NSWindow firstResponder], [fieldEdit window] and
# every insertText: while typing into the Multiplayer name field, once with this
# patch and once without. If insertText: fires only with the patch, the
# mechanism is confirmed. If it fires in neither, the fault is further inside
# AppKit than this file can reach.
#
# THE FIX
#
# Cocoa_StopTextInput now tells the current NSInputManager the client is going
# away before the field editor dies, and hands first responder status back if
# the field editor somehow holds it. Both are what a correct NSTextInput client
# does on teardown, so both are no ops on the systems where nothing was wrong.
#
# Cocoa_StartTextInput now falls back to AppKit's own key window when SDL has no
# keyboard focus window, and returns without building anything when there is
# still no content view to attach to. Nothing is suppressed: the next call with
# a real window builds a field editor that is properly attached, which is the
# invariant the rest of the backend assumes.
#
# -[NSWindow makeFirstResponder:] is left in place. Verifying its return value
# would only record a failure that is permanent by construction, and making
# SDLTranslatorResponder accept first responder status would change behaviour on
# the machines that already work, for something the working machines demonstrate
# is not needed.
#
# Correct on all OS versions, so it is safe on the shared source tree. Applied
# to src/video/cocoa/SDL_cocoakeyboard.m by both PowerPC build drivers.
# Idempotent. Python 2.5+.
import sys

MARKER = 'oldmac: text input teardown (issue #29)'
MARKER_START = 'oldmac: text input setup (issue #29)'

OLD_START = """void
Cocoa_StartTextInput(_THIS)
{
    SDL_VideoData *data = (SDL_VideoData *) _this->driverdata;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    SDL_Window *window = SDL_GetKeyboardFocus();
    NSWindow *nswindow = nil;
    if (window)
        nswindow = ((SDL_WindowData*)window->driverdata)->nswindow;

    NSView *parentView = [nswindow contentView];
"""

NEW_START = """void
Cocoa_StartTextInput(_THIS)
{
    SDL_VideoData *data = (SDL_VideoData *) _this->driverdata;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    SDL_Window *window = SDL_GetKeyboardFocus();
    NSWindow *nswindow = nil;
    NSView *parentView = nil;

    if (window)
        nswindow = ((SDL_WindowData*)window->driverdata)->nswindow;

    /* """ + MARKER_START + """. SDL_VideoInit() calls
     * SDL_StartTextInput() before any window exists, and SDL_SetKeyboardFocus(NULL)
     * runs whenever the window resigns key, so SDL_GetKeyboardFocus() is NULL here
     * more often than this code assumed. Ask AppKit for the key window before
     * giving up on finding a view to attach to. */
    if (!nswindow) {
        nswindow = [NSApp keyWindow];
    }

    parentView = [nswindow contentView];

    /* With no content view there is nothing useful to build. Upstream carried on
     * and sent -addSubview: and -makeFirstResponder: to nil, which does nothing
     * quietly and leaves a field editor that belongs to no window, while
     * SDL_IsTextInputActive() still reports true and the engine drops printable
     * keys on that basis. -interpretKeyEvents: on a view in no window has no
     * input session to feed. Build nothing instead: the next call that does have
     * a window builds a field editor that is properly attached. */
    if (!parentView) {
        [pool release];
        return;
    }
"""

OLD_STOP = """void
Cocoa_StopTextInput(_THIS)
{
    SDL_VideoData *data = (SDL_VideoData *) _this->driverdata;

    if (data && data->fieldEdit) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        [data->fieldEdit removeFromSuperview];
        [data->fieldEdit release];
        data->fieldEdit = nil;
        [pool release];
    }
}
"""

NEW_STOP = """void
Cocoa_StopTextInput(_THIS)
{
    SDL_VideoData *data = (SDL_VideoData *) _this->driverdata;

    if (data && data->fieldEdit) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSWindow *nswindow = [data->fieldEdit window];

        /* """ + MARKER + """. removeFromSuperview drops the
         * superview's retain and the release below drops the last one, so the
         * field editor is deallocated here. Upstream did that without telling
         * anything that the input client was going away. AppKit's own
         * NSTextInput clients do the opposite: NSTextView sends
         * -markedTextAbandoned: to the current input manager when it stops being
         * the client. Pre Leopard, -interpretKeyEvents: routes through the
         * process wide NSInputManager, which keeps an unretained pointer to the
         * last client it saw; Leopard replaced that with a per view
         * NSTextInputContext that is torn down with the view. Sending the
         * notification is correct everywhere and only matters on 10.3 and 10.4.
         * See GitHub issue #29. */
        [[NSInputManager currentInputManager] markedTextAbandoned: data->fieldEdit];

        /* Defensive, and a no op as this file stands: SDLTranslatorResponder does
         * not override -acceptsFirstResponder, so -[NSWindow makeFirstResponder:]
         * in Cocoa_StartTextInput always fails and the field editor never holds
         * the status. If that ever changes, the window must not be left pointing
         * at a view that is about to be freed. */
        if (nswindow && [nswindow firstResponder] == (NSResponder *) data->fieldEdit) {
            if (![nswindow makeFirstResponder: [nswindow contentView]]) {
                [nswindow makeFirstResponder: nil];
            }
        }

        [data->fieldEdit removeFromSuperview];
        [data->fieldEdit release];
        data->fieldEdit = nil;
        [pool release];
    }
}
"""


def patch(path):
	s = open(path).read()
	have_stop = MARKER in s
	have_start = MARKER_START in s

	# TWO independent hunks, so one marker cannot answer for both. Guarding on
	# MARKER alone reported "already patched" for a tree that carried only the
	# teardown hunk, which is exactly what an interrupted run, or a build host
	# left on an earlier version of this script, leaves behind: the setup hunk
	# silently absent and the build green. See GitHub issue #39.
	if have_stop != have_start:
		if have_stop:
			found, missing = 'teardown (Cocoa_StopTextInput)', 'setup (Cocoa_StartTextInput)'
		else:
			found, missing = 'setup (Cocoa_StartTextInput)', 'teardown (Cocoa_StopTextInput)'
		print('ERROR: half patched: ' + path)
		print('       the %s hunk is present, the %s hunk is NOT.' % (found, missing))
		print('       Re-applying cannot fix this: the missing hunk\'s anchor has been')
		print('       edited or was never there. Restore the file from a pristine')
		print('       panther-sdl2 checkout and run this again.')
		return 1

	if have_stop:
		print('already patched: ' + path)
		return 0

	n = s.count(OLD_START)
	assert n == 1, ('Cocoa_StartTextInput anchor found %d times (want 1) in %s' % (n, path))
	n = s.count(OLD_STOP)
	assert n == 1, ('Cocoa_StopTextInput anchor found %d times (want 1) in %s' % (n, path))
	s = s.replace(OLD_START, NEW_START, 1)
	s = s.replace(OLD_STOP, NEW_STOP, 1)
	open(path, 'w').write(s)

	# Both markers must be in what we just wrote, or the file on disk is not
	# what this script claims it is.
	check = open(path).read()
	assert MARKER in check and MARKER_START in check, (
		'wrote %s but a marker is missing from it' % path)
	print('patched: ' + path)
	return 0


def main():
	if len(sys.argv) < 2:
		print('usage: patch-panther-sdl-textinput.py <SDL_cocoakeyboard.m> ...')
		return 1
	rc = 0
	for arg in sys.argv[1:]:
		if patch(arg):
			rc = 1
	return rc


if __name__ == '__main__':
	sys.exit(main())
