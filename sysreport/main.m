/*
 * main.m - entry point for "Half-Life System Report".
 *
 * No nib, so the menu bar is built here. On 10.3 an app with no menu bar cannot
 * be quit with Cmd-Q, so the minimum Application menu is worth the dozen lines.
 */

#import "SRController.h"

#include <string.h>
#include <stdio.h>

static void sr_installMenuBar( void )
{
	NSMenu *mainMenu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
	NSMenuItem *appItem = [[[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""] autorelease];
	NSMenu *appMenu = [[[NSMenu alloc] initWithTitle:@"Half-Life System Report"] autorelease];

	[[appMenu addItemWithTitle:@"About Half-Life System Report"
	                    action:@selector(showAbout:)
	             keyEquivalent:@""] setTarget:nil];
	[appMenu addItem:[NSMenuItem separatorItem]];
	[appMenu addItemWithTitle:@"Hide" action:@selector(hide:) keyEquivalent:@"h"];
	[appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@""];
	[appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
	[appMenu addItem:[NSMenuItem separatorItem]];
	[appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];

	[appItem setSubmenu:appMenu];
	[mainMenu addItem:appItem];

	/* Edit menu, so Cmd-C works in the text view without a nib. */
	{
		NSMenuItem *editItem = [[[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""] autorelease];
		NSMenu *editMenu = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];

		[editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
		[editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
		[editItem setSubmenu:editMenu];
		[mainMenu addItem:editItem];
	}

	/*
	 * Tell AppKit THIS is the application menu before handing over the bar.
	 * Without it, 10.5 and earlier show two menus with the app's name and only
	 * ours carries About/Hide/Quit. -setAppleMenu: has never been in a public
	 * header, so it goes through performSelector: and is guarded: a bare call
	 * would not compile against the 10.3.9 SDK.
	 */
	if( [NSApp respondsToSelector:@selector( setAppleMenu: )] )
		[NSApp performSelector:@selector( setAppleMenu: ) withObject:appMenu];

	[NSApp setMainMenu:mainMenu];
}

int main( int argc, const char *argv[] )
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	SRController *controller;
	int i;

	/*
	 * --print writes the report to stdout and exits, without opening a window.
	 * Useful over ssh, and on a machine whose display is asleep or whose GUI
	 * session is not reachable. The graphics section will report no context in
	 * that case, which is correct rather than a failure: there is no display to
	 * ask.
	 */
	for( i = 1; i < argc; i++ )
	{
		if( strcmp( argv[i], "--print" ) != 0 )
			continue;
		printf( "%s\n", [SRReportText() UTF8String] );
		[pool release];
		return 0;
	}

	[NSApplication sharedApplication];
	sr_installMenuBar();

	controller = [[SRController alloc] init];
	[NSApp setDelegate:controller];
	[controller showWindow];

	[NSApp activateIgnoringOtherApps:YES];
	[NSApp run];

	[controller release];
	[pool release];
	return 0;
}
