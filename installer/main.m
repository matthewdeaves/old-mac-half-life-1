/*
 * main.m - entry point for the "Get Mods" installer.
 *
 * No nib, so the menu bar is built here too. On 10.3 an app with no menu bar at
 * all cannot be quit with Cmd-Q, so the minimum Application menu is worth the
 * dozen lines.
 */

#import "OMController.h"

#include <sys/types.h>
#include <sys/sysctl.h>

static void om_installMenuBar( void )
{
	NSMenu *mainMenu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
	NSMenuItem *appItem = [[[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""] autorelease];
	NSMenu *appMenu = [[[NSMenu alloc] initWithTitle:@"Half-Life Mods"] autorelease];

	/* Our own About window, not -orderFrontStandardAboutPanel:, because the
	 * standard panel's artwork cannot be given an action. Target nil so it
	 * travels the responder chain to the app delegate. */
	[[appMenu addItemWithTitle:@"About Half-Life Mods"
	                    action:@selector(showAbout:)
	             keyEquivalent:@""] setTarget:nil];
	[appMenu addItem:[NSMenuItem separatorItem]];
	[appMenu addItemWithTitle:@"Hide Half-Life Mods" action:@selector(hide:) keyEquivalent:@"h"];
	/* Hide Others is Cmd-Opt-H everywhere. The key equivalent alone would
	 * collide with Hide's Cmd-H; the alternate mask is what separates them. */
	[[appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"]
		setKeyEquivalentModifierMask:( NSCommandKeyMask | NSAlternateKeyMask )];
	[appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
	[appMenu addItem:[NSMenuItem separatorItem]];
	[appMenu addItemWithTitle:@"Quit Half-Life Mods" action:@selector(terminate:) keyEquivalent:@"q"];

	[appItem setSubmenu:appMenu];
	[mainMenu addItem:appItem];

	/* File carries Close. The window IS the app - the delegate returns YES from
	 * -applicationShouldTerminateAfterLastWindowClosed: - so Cmd-W quits, and it
	 * still runs the mid-install confirmation in -applicationShouldTerminate:. */
	{
		NSMenuItem *fileItem = [[[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""] autorelease];
		NSMenu *fileMenu = [[[NSMenu alloc] initWithTitle:@"File"] autorelease];

		[fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
		[fileItem setSubmenu:fileMenu];
		[mainMenu addItem:fileItem];
	}

	/* Edit menu, so Cmd-C can copy log lines out of the text view without a nib. */
	{
		NSMenuItem *editItem = [[[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""] autorelease];
		NSMenu *editMenu = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];

		[editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
		[editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
		[editItem setSubmenu:editMenu];
		[mainMenu addItem:editItem];
	}

	/* Window, so Cmd-M minimizes like every other app. */
	{
		NSMenuItem *winItem = [[[NSMenuItem alloc] initWithTitle:@"Window" action:NULL keyEquivalent:@""] autorelease];
		NSMenu *winMenu = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];

		[winMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
		[winItem setSubmenu:winMenu];
		[mainMenu addItem:winItem];
	}

	/*
	 * Help. A plain menu opening our own window, NOT an Apple Help book: a help
	 * book means an HTML bundle, a registration key in Info.plist and the Help
	 * Viewer, which is a great deal of machinery for one page of text - and the
	 * Help Viewer's behaviour varies across 10.3 to 10.5.
	 *
	 * The target is left nil so the message travels the responder chain to
	 * whoever implements it, which is the app delegate. That avoids having to
	 * hand the controller in here before it exists.
	 *
	 * The selector is -showModsHelp:, NOT -showHelp:, and that is not cosmetic.
	 * NSApplication ALREADY IMPLEMENTS -showHelp: - it opens the Apple Help book
	 * named in Info.plist. A nil-targeted -showHelp: therefore walks the chain
	 * and stops at NSApplication, which sits ahead of the app delegate, so our
	 * window never opened and the user got the system's "Help isn't available
	 * for Half-Life Mods" instead. Observed on the G3. Any selector NSApplication
	 * also responds to would fail the same silent way.
	 */
	{
		NSMenuItem *helpItem = [[[NSMenuItem alloc] initWithTitle:@"Help" action:NULL keyEquivalent:@""] autorelease];
		NSMenu *helpMenu = [[[NSMenu alloc] initWithTitle:@"Help"] autorelease];

		[[helpMenu addItemWithTitle:@"Half-Life Mods Help"
		                     action:@selector(showModsHelp:)
		              keyEquivalent:@"?"] setTarget:nil];
		[helpItem setSubmenu:helpMenu];
		[mainMenu addItem:helpItem];
	}

	/*
	 * Tell AppKit that THIS is the application menu, before handing over the menu
	 * bar. Without it, 10.5 and earlier put two menus titled "Half-Life Mods" in
	 * the bar: AppKit's own synthesised one, and ours, with only ours carrying
	 * About / Hide / Quit. (Reported on the iMac G5, which runs Leopard.)
	 *
	 * Only 10.6 onwards infers the application menu from position, which is why
	 * the same binary looks correct on the Intel machines and wrong on the PowerPC
	 * ones. -setAppleMenu: is the pre-10.6 way to say so. It has never been in a
	 * public header - SDL's own Cocoa startup does exactly this - so it is called
	 * through performSelector: and guarded, rather than declared: a bare call
	 * would not compile against the 10.3.9 SDK, and hard-coding it would crash on
	 * any future system that finally drops it.
	 */
	if( [NSApp respondsToSelector:@selector( setAppleMenu: )] )
		[NSApp performSelector:@selector( setAppleMenu: ) withObject:appMenu];

	[NSApp setMainMenu:mainMenu];
}

/*
 * Refuse to start on a machine that cannot finish the job.
 *
 * This is not defensive tidiness. The largest mod, Echoes, expands to about
 * 450 MB and is stored as a single compressed block, so unpacking it is the
 * hungriest thing this app ever does; it was measured completing on a 450 MHz G3
 * with 448 MB, at a peak of 380 MB resident. Below 256 MB the machine would
 * spend a very long time swapping and then fail, having already downloaded
 * hundreds of megabytes over a slow link. Saying so in two seconds is kinder
 * than discovering it in two hours.
 *
 * 256 MB rather than 448: the smaller mods are well within reach on such a
 * machine, and refusing a G4 with 256 MB the whole catalogue because one mod is
 * large would be the wrong trade. The dialog says which mods may struggle rather
 * than pretending the limit is sharp.
 *
 * hw.memsize is 64-bit and 10.6+. hw.physmem is what 10.3 through 10.5 have, and
 * it is a 32-bit int that saturates at 4 GB - harmless here, since we only ever
 * compare it against 256 MB.
 */
#define OM_MIN_RAM_MB 256

static BOOL om_check_minimum_specs( void )
{
	unsigned long long bytes = 0;
	size_t len = sizeof( bytes );

	if( sysctlbyname( "hw.memsize", &bytes, &len, NULL, 0 ) != 0 || bytes == 0 )
	{
		unsigned int phys = 0;
		len = sizeof( phys );
		if( sysctlbyname( "hw.physmem", &phys, &len, NULL, 0 ) != 0 )
			return YES;              /* cannot tell: let them try rather than refuse */
		bytes = (unsigned long long)phys;
	}

	if( bytes >= (unsigned long long)OM_MIN_RAM_MB * 1024 * 1024 )
		return YES;

	NSRunCriticalAlertPanel( @"This Mac does not have enough memory",
		@"Half-Life Mods needs at least %d MB of memory and this Mac has %llu MB.\n\n"
		 "Unpacking a mod means decompressing it in one piece, and the largest of "
		 "them expands to about 450 MB. With this much memory the app would spend "
		 "hours swapping and then fail, most likely after a long download.\n\n"
		 "Adding memory is the only fix.",
		@"Quit", nil, nil, OM_MIN_RAM_MB, bytes / ( 1024 * 1024 ));
	return NO;
}

int main( int argc, const char *argv[] )
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	OMController *controller;

	[NSApplication sharedApplication];

	/* Before the window, so a machine that cannot do the work is told once and
	 * plainly rather than being allowed to start and fail later. */
	if( !om_check_minimum_specs() )
	{
		[pool release];
		return 1;
	}

	om_installMenuBar();

	controller = [[OMController alloc] init];
	[NSApp setDelegate:controller];
	[controller showWindow];

	[NSApp activateIgnoringOtherApps:YES];
	[NSApp run];

	[controller release];
	[pool release];
	return 0;
}
