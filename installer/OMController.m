/*
 * OMController.m - UI + the worker thread that does the actual work.
 *
 * Threading model, chosen for 10.3: the job runs on an NSThread and every UI
 * touch is bounced to the main thread with performSelectorOnMainThread. No
 * blocks, no GCD, no @property - none of which exist before 10.5/10.6.
 */

#import "OMController.h"

/* Defined down with the help-window formatting, but the log view classifies its
 * headings the same way, and that is far earlier in the file. */
static BOOL om_is_heading( NSString *line );

@implementation OMController

/* ------------------------------------------------------------------ setup -- */

- (NSTextField *)labelAt:(NSRect)r text:(NSString *)t bold:(BOOL)bold
{
	NSTextField *f = [[[NSTextField alloc] initWithFrame:r] autorelease];
	[f setStringValue:t];
	[f setBezeled:NO];
	[f setDrawsBackground:NO];
	[f setEditable:NO];
	[f setSelectable:NO];
	if( bold )
		[f setFont:[NSFont boldSystemFontOfSize:14.0]];
	else
		[f setFont:[NSFont systemFontOfSize:11.0]];
	return f;
}

- (NSButton *)buttonAt:(NSRect)r title:(NSString *)t action:(SEL)sel
{
	NSButton *b = [[[NSButton alloc] initWithFrame:r] autorelease];
	[b setTitle:t];
	[b setBezelStyle:NSRoundedBezelStyle];
	[b setTarget:self];
	[b setAction:sel];
	return b;
}

- (void)showWindow
{
	NSRect frame = NSMakeRect( 0, 0, 640, 470 );
	NSView *content;
	NSScrollView *scroll;

	window = [[NSWindow alloc]
		initWithContentRect:frame
		          styleMask:( NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask )
		            backing:NSBackingStoreBuffered
		              defer:NO];
	[window setTitle:@"Half-Life Mods"];
	[window center];
	content = [window contentView];

	/* artwork - mod banners are 'game.tga', typically wider than tall.
	 * The frame stops at y 370 so the button row at y 330 sits clear below
	 * it; the old 120-point-tall frame reached down to the row and the
	 * Choose Folder button overlapped the bezel's bottom edge, which read
	 * as a button lost inside an empty box whenever no banner was up. */
	artView = [[NSImageView alloc] initWithFrame:NSMakeRect( 20, 370, 192, 80 )];
	[artView setImageFrameStyle:NSImageFrameGrayBezel];
	[artView setImageScaling:NSScaleProportionally];
	[content addSubview:artView];

	titleField = [self labelAt:NSMakeRect( 228, 418, 392, 22 )
	                      text:@"Half-Life Mods for old Macs" bold:YES];
	[content addSubview:titleField];

	statusField = [self labelAt:NSMakeRect( 228, 392, 392, 20 )
	                       text:@"Ready." bold:NO];
	[content addSubview:statusField];

	progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect( 230, 366, 390, 16 )];
	[progress setStyle:NSProgressIndicatorBarStyle];
	[progress setIndeterminate:NO];
	[progress setMinValue:0.0];
	[progress setMaxValue:1.0];
	[progress setDoubleValue:0.0];
	[content addSubview:progress];

	/*
	 * Three buttons. "Choose Folder..." exists because finding Half-Life.app is
	 * a convenience, not a constraint: it decides where the panel OPENS, and
	 * nothing more. Mods install wherever the user says, including a folder with
	 * no Half-Life.app in it at all, which is a perfectly reasonable thing to
	 * want. Somebody may keep mods on another volume, stage them before moving
	 * them, or run more than one copy of the game.
	 *
	 * Without this button the destination could only ever be the one the search
	 * happened to find, and the panel only appeared when the search FAILED, so a
	 * wrong guess was unfixable from the UI.
	 */
	chooseButton = [self buttonAt:NSMakeRect(  36, 330, 160, 32 ) title:@"Choose Folder..." action:@selector(chooseDestination:)];
	[content addSubview:chooseButton];
	getButton    = [self buttonAt:NSMakeRect( 228, 330, 160, 32 ) title:@"Get Mods" action:@selector(getMods:)];
	cancelButton = [self buttonAt:NSMakeRect( 400, 330, 160, 32 ) title:@"Cancel"   action:@selector(cancel:)];
	[cancelButton setEnabled:NO];
	[content addSubview:getButton];
	[content addSubview:cancelButton];

	/*
	 * Off by default, deliberately. A re-run normally skips mods that are already
	 * installed and refreshes only the game code and artwork, so it finishes in a
	 * fraction of the time the first run took. This is the escape hatch for when
	 * that is not what you want: a mod's content is damaged, or you have edited
	 * files under a mod folder and want the shipped state back.
	 */
	forceButton = [[NSButton alloc] initWithFrame:NSMakeRect( 228, 306, 392, 18 )];
	[forceButton setButtonType:NSSwitchButton];
	[forceButton setTitle:@"Reinstall mods that are already installed (slow)"];
	[forceButton setState:NSOffState];
	[forceButton setFont:[NSFont systemFontOfSize:11]];
	[content addSubview:forceButton];

	/*
	 * Log. Height 280, not 296: the reinstall checkbox above occupies y 306-324,
	 * so a 296-tall box starting at y 20 reaches y 316 and covers the bottom ten
	 * points of it - and because the scroll view is added last, it wins, leaving
	 * the checkbox clipped and unclickable. Reported on the G3. The checkbox
	 * cannot move up instead; the buttons at y 330 leave only 6 points above it.
	 */
	scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect( 20, 20, 600, 280 )] autorelease];
	[scroll setHasVerticalScroller:YES];
	[scroll setBorderType:NSBezelBorder];
	[scroll setAutoresizingMask:( NSViewWidthSizable | NSViewHeightSizable )];

	logView = [[NSTextView alloc] initWithFrame:[[scroll contentView] bounds]];
	[logView setEditable:NO];
	/* Rich text so -attributedForLogLine: styling survives; still not editable,
	 * so the user cannot type or paste formatting into it. */
	[logView setRichText:YES];
	[logView setFont:[NSFont systemFontOfSize:11.0]];
	[logView setTextContainerInset:NSMakeSize( 4.0, 4.0 )];
	[logView setAutoresizingMask:NSViewWidthSizable];
	[scroll setDocumentView:logView];
	[content addSubview:scroll];

	/*
	 * Logfile in the app's OWN folder, which is the game folder, so the log sits
	 * with the thing it describes instead of cluttering the Desktop. Falls back
	 * to the Desktop only if that folder cannot be written - which in practice
	 * means the app is on a read-only volume, and the check below is about to
	 * stop the run anyway.
	 */
	{
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *appDir = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
		NSString *cand = [appDir stringByAppendingPathComponent:@"Half-Life-Mods-install.log"];

		if( ![fm createFileAtPath:cand contents:nil attributes:nil] )
			cand = [[NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"]
				stringByAppendingPathComponent:@"Half-Life-Mods-install.log"];
		logPath = [cand retain];
		[fm createFileAtPath:logPath contents:nil attributes:nil];
		logFile = [[NSFileHandle fileHandleForWritingAtPath:logPath] retain];
	}

	[window makeKeyAndOrderFront:nil];

	/*
	 * Refuse to run from the disk image. Everything looks fine until the first
	 * write, and then there is nowhere to put 4 GB of mods. Say so now, plainly,
	 * rather than failing halfway through.
	 */
	if( OMPathIsReadOnly( [[NSBundle mainBundle] bundlePath] ))
	{
		[self omLog:@"This app is running from a read-only volume (probably the disk image)."];
		[self omLog:@"Mods cannot be installed from here."];
		[self omLog:@""];
		[self omLog:@"Copy BOTH Half-Life.app and Half-Life Mods.app out of the disk"];
		[self omLog:@"image into a normal folder first, then run this again."];
		[self omStatus:@"Copy this app out of the disk image first."];
		[getButton setEnabled:NO];
		NSRunAlertPanel( @"Copy this app out of the disk image first",
			@"%@", @"Quit", nil, nil,
			@"Half-Life Mods.app is running from the disk image, which is read-only, "
			 "so it has nowhere to install mods.\n\n"
			 "Copy Half-Life.app and Half-Life Mods.app into a normal folder (your "
			 "Desktop is fine), put your own Half-Life valve folder beside them, "
			 "and run this again from there." );
		[NSApp terminate:nil];
		return;
	}

	destRoot = [[OMInstaller defaultDestination] retain];
	if( destRoot == nil )
	{
		[self omLog:@"Could not find Half-Life.app automatically."];
		[self omLog:@"Searched: this folder, Desktop, Games, /Applications, Home."];
		[self omLog:@"You will be asked where to install when you start."];
		[self omLog:@"Or press Choose Folder... to pick one now."];
		[self omStatus:@"Choose a folder to install into."];
	}
	else
	{
		[self omLog:[NSString stringWithFormat:@"Half-Life.app found in: %@", destRoot]];
		[self omLog:@"Mods will be installed there. Press Choose Folder... to"];
		[self omLog:@"install somewhere else instead."];
		[self omStatus:@"Ready."];
	}
	[self omLog:[NSString stringWithFormat:@"Log: %@", logPath]];
	[self omLog:@""];

	/*
	 * A short orientation, here in the log rather than as window furniture. The
	 * window has no room left (see the checkbox collision above), and this is
	 * where the user is already reading. It scrolls away once install output
	 * starts, which is what the Help menu is for.
	 */
	[self omLog:@"WHAT THIS DOES"];
	[self omLog:@""];
	[self omLog:@"This supplies Mac game code for 25 Half-Life mods, rebuilt for PowerPC"];
	[self omLog:@"and Intel, so they appear in the game's Custom Game menu."];
	[self omLog:@""];
	[self omLog:@"18 of them it can also download for you. Press Get Mods and leave it."];
	[self omLog:@""];
	[self omLog:@"The other 7 it will not download, because they are not free downloads:"];
	[self omLog:@"Blue Shift, Opposing Force and Deathmatch Classic are Valve games you"];
	[self omLog:@"buy, and four more are only published as Windows installers. If you"];
	[self omLog:@"already have any of them, put the mod's folder in this folder and press"];
	[self omLog:@"Get Mods - it will add the game code and they will work too."];
	[self omLog:@""];
	[self omLog:@"No mod content is bundled here. Everything downloaded comes from that"];
	[self omLog:@"mod's own public release."];
	[self omLog:@""];
	[self omLog:@"You can stop at any time and run this again: finished mods are left"];
	[self omLog:@"alone and a part-finished download carries on from where it stopped."];
	[self omLog:@""];
	[self omLog:@"Needs about 6 GB free and at least 256 MB of memory."];
	[self omLog:@""];
	[self omLog:@"Mods install next to Half-Life.app. Play them from Custom Game inside"];
	[self omLog:@"the game, not from here."];
	[self omLog:@""];
	[self omLog:@"  Full instructions: Help menu, or press Cmd-?"];
	[self omLog:@""];
}

/* ------------------------------------------------- OMProgressSink (thread) -- */
/* These are called from the worker thread, so each hops to the main thread. */

/*
 * On-screen styling for one log line.
 *
 * Classified BY SHAPE rather than by a tag the caller passes, so every existing
 * omLog: call site gets this without changing, and code that just prints a line
 * cannot forget to say what kind of line it is.
 *
 *   ALL CAPITALS, flush left   a heading            -> bold
 *   starts "OK"                a mod installed      -> bold, green
 *   starts FAIL/ERROR/WARNING  something went wrong -> bold, red
 *   indented two spaces        detail under the
 *                              line above, and the
 *                              file/size columns    -> fixed pitch, grey, so
 *                                                      the columns still line up
 *   anything else              prose                -> plain
 *
 * The LOG FILE is deliberately left as plain text: a log someone sends us has to
 * stay greppable, and none of this styling carries meaning that the words do not.
 */
/*
 * How a log line is styled.
 *
 * Deliberately only three cases now. It used to have a fourth that switched
 * indented lines to a grey fixed-pitch face whenever they contained a run of
 * three spaces, on the theory that a two-column list ("Get Mods    fetches
 * ...") only lines up in a monospaced font. In a 600-point-wide box those
 * columns wrapped anyway, so the alignment it was protecting never survived,
 * and the result was a window mixing three faces and two greys with no pattern
 * a reader could follow. Screenshotted on the Intel mini and it looked like a
 * bug, which it effectively was.
 *
 * One face for prose, bold for headings, colour for the two outcomes that
 * matter. Indentation carries the structure on its own.
 */
- (NSDictionary *)attributesForLogLine:(NSString *)line
{
	NSFont *font = [NSFont systemFontOfSize:11.0];
	/* +textColor dates to 10.0 but resolves per-appearance on modern macOS,
	 * so the arm64 slice follows dark mode; black text on the dark-mode
	 * window background was unreadable. The vintage slices never see a dark
	 * appearance and keep drawing the light values. The accent and grey
	 * colours only gained semantic equivalents in 10.10, so those are probed
	 * at runtime; the fallbacks are what every slice shipped before. */
	NSColor *colour = [NSColor textColor];

	if( [line hasPrefix:@"OK"] )
	{
		font = [NSFont boldSystemFontOfSize:11.0];
		if( [NSColor respondsToSelector:@selector(systemGreenColor)] )
			colour = [NSColor performSelector:@selector(systemGreenColor)];
		else
			colour = [NSColor colorWithCalibratedRed:0.0 green:0.45 blue:0.05 alpha:1.0];
	}
	else if( [line hasPrefix:@"FAIL"] || [line hasPrefix:@"ERROR"] ||
	         [line hasPrefix:@"WARNING"] || [line hasPrefix:@"!!"] )
	{
		font = [NSFont boldSystemFontOfSize:11.0];
		if( [NSColor respondsToSelector:@selector(systemRedColor)] )
			colour = [NSColor performSelector:@selector(systemRedColor)];
		else
			colour = [NSColor colorWithCalibratedRed:0.65 green:0.0 blue:0.0 alpha:1.0];
	}
	else if( om_is_heading( line ) )
	{
		font = [NSFont boldSystemFontOfSize:11.5];
	}
	else if( [line hasPrefix:@"  "] )
	{
		/* Detail under a heading: same face, a shade lighter, nothing else. */
		if( [NSColor respondsToSelector:@selector(secondaryLabelColor)] )
			colour = [NSColor performSelector:@selector(secondaryLabelColor)];
		else
			colour = [NSColor colorWithCalibratedWhite:0.25 alpha:1.0];
	}

	return [NSDictionary dictionaryWithObjectsAndKeys:
		font, NSFontAttributeName, colour, NSForegroundColorAttributeName, nil];
}

- (void)mainLog:(NSString *)line
{
	NSString *out = [line stringByAppendingString:@"\n"];
	NSAttributedString *styled;
	NSRange end;

	styled = [[NSAttributedString alloc] initWithString:out
	                                        attributes:[self attributesForLogLine:line]];
	[[logView textStorage] appendAttributedString:styled];
	[styled release];

	end = NSMakeRange( [[logView string] length], 0 );
	[logView scrollRangeToVisible:end];

	if( logFile != nil )
		[logFile writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)omLog:(NSString *)line
{
	if( line == nil ) line = @"";
	[self performSelectorOnMainThread:@selector(mainLog:) withObject:line waitUntilDone:NO];
}

- (void)mainStatus:(NSString *)text { [statusField setStringValue:text]; }
- (void)omStatus:(NSString *)text
{
	if( text == nil ) text = @"";
	[self performSelectorOnMainThread:@selector(mainStatus:) withObject:text waitUntilDone:NO];
}

- (void)mainProgress:(NSNumber *)n
{
	double v = [n doubleValue];
	if( v < 0.0 )
	{
		[progress setIndeterminate:YES];
		[progress startAnimation:nil];
	}
	else
	{
		[progress stopAnimation:nil];
		[progress setIndeterminate:NO];
		[progress setDoubleValue:v];
	}
}
- (void)omProgress:(double)fraction
{
	[self performSelectorOnMainThread:@selector(mainProgress:)
	                       withObject:[NSNumber numberWithDouble:fraction] waitUntilDone:NO];
}

- (void)mainArtwork:(NSArray *)pair
{
	NSImage *img = [pair count] > 0 && [[pair objectAtIndex:0] isKindOfClass:[NSImage class]]
		? [pair objectAtIndex:0] : nil;
	NSString *t = [pair count] > 1 ? [pair objectAtIndex:1] : @"";
	[artView setImage:img];
	if( [t length] > 0 )
		[titleField setStringValue:t];
}
- (void)omArtwork:(NSImage *)image title:(NSString *)t
{
	NSArray *pair = [NSArray arrayWithObjects:
		( image != nil ? (id)image : (id)[NSNull null] ),
		( t != nil ? t : @"" ), nil];
	[self performSelectorOnMainThread:@selector(mainArtwork:) withObject:pair waitUntilDone:NO];
}

- (BOOL)omCancelled { return cancelled; }

/* --------------------------------------------------------------- the work -- */

- (void)setRunning:(BOOL)r
{
	running = r;
	[getButton setEnabled:!r];
	[chooseButton setEnabled:!r];
	[forceButton setEnabled:!r];
	[cancelButton setEnabled:r];

	/*
	 * Stopping means stopping, including the barber pole. The bar is put into
	 * indeterminate mode before slow steps, and nothing on the FAILURE paths ever
	 * took it out again - so a run that died early left the app sitting there
	 * spinning as though it were still working. Doing it here covers every exit:
	 * success, cancel and error.
	 */
	if( !r )
	{
		[progress stopAnimation:nil];
		[progress setIndeterminate:NO];
		[progress setDoubleValue:0.0];
	}
}
- (void)mainSetRunning:(NSNumber *)n { [self setRunning:[n boolValue]]; }

- (NSString *)resourcesPath { return [[NSBundle mainBundle] resourcePath]; }

- (void)showArtworkFor:(OMMod *)mod
{
	NSString *tga = [[[self resourcesPath] stringByAppendingPathComponent:@"artwork"]
		stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.tga", [mod gamedir]]];
	NSImage *img = [OMTGA imageWithContentsOfFile:tga];

	if( img == nil )
	{
		tga = [[mod sourcePath] stringByAppendingPathComponent:@"game.tga"];
		img = [OMTGA imageWithContentsOfFile:tga];
	}
	[self omArtwork:img title:[mod title]];
}

/*
 * Why a folder in the source bundle was not installed.
 *
 * "no build shipped" was technically true for all of these but told the user
 * nothing, and lumped together three genuinely different situations. Most of
 * what gets skipped is not a mod we failed to support - it is an add-on content
 * folder that belongs to a mod we DID install.
 */
/*
 * End-of-run summary in a real dialog, not just the log.
 *
 * NSRunAlertPanel rather than NSAlert: NSAlert only arrived in 10.3 and this app
 * targets 10.3.9, so the function form is the safer of the two. It is modal UI,
 * so it MUST be driven from the main thread - the caller is the worker thread,
 * hence the hop below.
 *
 * NOTE the @"%@" indirection: NSRunAlertPanel treats its message as a FORMAT
 * string, and the text embeds a user-supplied path. Passing it directly would
 * make a '%' in a folder name a format-string bug.
 */
/* Main-thread half of the end-of-run line. AppKit only, off the worker. */
- (void)mainPlayOutcome:(NSArray *)pair
{
	OMPlayPakSound( [pair objectAtIndex:0], [pair objectAtIndex:1] );
}

- (void)mainFinishedAlert:(NSArray *)pair
{
	int r = NSRunAlertPanel( [pair objectAtIndex:0], @"%@", @"Quit", @"Leave Open", nil,
	                         [pair objectAtIndex:1] );
	if( r == NSAlertDefaultReturn )
		[NSApp terminate:nil];
}

- (void)finishedAlert:(unsigned)ok failed:(unsigned)failed skipped:(unsigned)skipped
              adopted:(unsigned)adopted
             cancelled:(BOOL)wasCancelled destination:(NSString *)dest
{
	NSString *title = ( wasCancelled ? @"Installation cancelled" : @"Mods installed" );
	NSMutableString *m = [NSMutableString string];

	/*
	 * One line per run, chosen by what actually happened, from the player's own
	 * pak0.pak. Issue #11.
	 *
	 * Said HERE rather than at each of the three call sites, because this is the
	 * one place that already knows all three outcomes and is reached exactly once
	 * per run. Putting it where the failures happen would speak once per failed
	 * mod, which on a bad network is two dozen warnings over each other.
	 *
	 * Cancel is checked before failures deliberately: if the player stopped the
	 * run, that is what they did, whatever else was going on when they did it.
	 *
	 * Hopped to the main thread for the same reason the alert below is. This
	 * method runs on the worker, and NSSound is AppKit: driving it from a
	 * background thread is undefined on 10.3 and 10.4, which is where this app
	 * spends most of its life.
	 */
	if( dest != nil )
		[self performSelectorOnMainThread:@selector(mainPlayOutcome:)
		                       withObject:[NSArray arrayWithObjects:dest,
		                                     ( wasCancelled ? OM_SND_CANCEL
		                                     : ( failed > 0 ? OM_SND_FAILED : OM_SND_DONE ) ),
		                                     nil]
		                    waitUntilDone:NO];

	/*
	 * Report the job, not the catalogue.
	 *
	 * This used to explain that three of the twenty-five are Valve games you buy
	 * and four are published only as Windows installers - true, but it is the
	 * app's problem, not the player's, and reading it at the END of a run makes
	 * a successful install sound like a partial one. The set this app installs
	 * is simply the set it installs. Either they all worked or some did not, and
	 * the only number worth leading with is how many are now playable.
	 */
	if( wasCancelled )
		[m appendFormat:@"Stopped early. %u mod%@ finished and %@ ready to play.\n\n",
			ok, ( ok == 1 ? @"" : @"s" ), ( ok == 1 ? @"is" : @"are" )];
	else if( failed == 0 && adopted > 0 )
		[m appendFormat:@"%u mod%@ downloaded and installed, and %u you already had "
		                 "given Mac game code. All ready to play.\n\n",
			ok, ( ok == 1 ? @"" : @"s" ), adopted];
	else if( failed == 0 )
		[m appendFormat:@"All %u mod%@ downloaded and installed, and ready to play.\n\n",
			ok, ( ok == 1 ? @"" : @"s" )];
	else
		[m appendFormat:@"%u mod%@ installed. %u did not - the log says which and why, "
		                 "and running this again will retry %@.\n\n",
			ok, ( ok == 1 ? @"" : @"s" ), failed, ( failed == 1 ? @"it" : @"them" )];

	[m appendFormat:@"They are in:\n%@\n\n", ( dest != nil ? dest : @"?" )];

	[m appendString:@"To play: launch Half-Life, then choose Custom Game from the "
	                 "main menu and activate a mod.\n\n"];

	if( wasCancelled )
		[m appendString:@"Run this again to carry on - finished mods are left alone "
		                 "and a part-finished download resumes.\n\n"];

	[m appendString:@"The downloaded archives were kept in your Downloads folder, "
	                 "under Half-Life Mods, so running this again does not fetch "
	                 "them a second time. Delete that folder once you are happy."];

	(void)skipped;

	[self performSelectorOnMainThread:@selector(mainFinishedAlert:)
	                       withObject:[NSArray arrayWithObjects:title, m, nil]
	                    waitUntilDone:NO];
}

/*
 * Why a mod could not be fetched, per mod, for the log.
 *
 * Kept short and practical. The end-of-run dialog no longer explains the
 * catalogue's shape - that is the app's problem, not the player's - but when a
 * specific mod is missing the log should say what to do about it rather than
 * leaving a gap in the list. In every case here the answer is the same: put the
 * mod's folder next to Half-Life.app and press Get Mods again, and its game
 * code will be added.
 *
 * Must stay in step with the "NOT LISTED, AND WHY" section at the bottom of
 * installer/mod-sources.txt.
 */
NSString *OMSkipReason( NSString *gamedir )
{
	NSString *g = [gamedir lowercaseString];

	if( [g isEqualToString:@"bshift"] || [g isEqualToString:@"gearbox"] ||
	    [g isEqualToString:@"dmc"] )
		return @"not a free download - copy the folder here and run again";

	if( [g isEqualToString:@"aom"] || [g isEqualToString:@"eftd"] ||
	    [g isEqualToString:@"vendetta"] || [g isEqualToString:@"thegate"] )
		return @"no download this app can unpack - copy the folder here and run again";

	if( [g hasSuffix:@"_hd"] )
		return @"HD model pack for another mod, not a mod itself";

	/* Order matters: tfc_german matches both tests, and the honest reason is
	 * that TFC has no source at all, not that it is a localisation. */
	if( [g hasPrefix:@"tfc"] )
		return @"Team Fortress Classic - no source exists to rebuild it from";

	if( [g hasSuffix:@"_german"] )
		return @"German-language variant of another mod";

	return @"not a mod this app knows about";
}

/*
 * "Get Mods": install everything we have a source for.
 *
 * WHAT THIS USED TO DO, AND WHY IT DOES NOT ANY MORE
 * -------------------------------------------------
 * It downloaded one 2.7 GB disk image somebody else had assembled from 26 mods,
 * mounted it, and copied content out. Every mod in the catalogue depended on
 * that one file on that one mirror, and three of the things inside it were Valve
 * retail games rather than free mods.
 *
 * Now each mod comes from wherever that mod is actually published, one at a
 * time. That is the same posture the project takes toward valve/: we ship code,
 * and content comes from the player's own copy or the author's own release. The
 * sources, and the reasoning for the seven mods that have none, are in
 * installer/mod-sources.txt.
 *
 * TWO PASSES, IN THIS ORDER
 * -------------------------
 * 1. Content already on disk. Blue Shift, Opposing Force and Deathmatch Classic
 *    are here permanently - they are Valve products we will not fetch - and so
 *    is anything the player unpacked by hand. All they need is our game code, so
 *    this pass is nearly instant and it runs first, because it would be perverse
 *    to spend an hour downloading before telling somebody that four mods they
 *    already had are now playable.
 * 2. Everything with a source that is not already installed.
 *
 * A mod already fully installed is not downloaded again. That is what makes a
 * second run cheap, and on a G3 over wifi the difference is hours.
 */
- (void)runGetMods:(id)ignored
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSFileManager *fm = [NSFileManager defaultManager];
	OMFetch *fetch;
	OMInstaller *inst;
	NSArray *sources;
	NSDictionary *modMap;
	NSMutableArray *noSource = [NSMutableArray array];
	NSString *err = nil;
	unsigned i, okCount = 0, failCount = 0, adoptCount = 0;
	BOOL force;

	if( destRoot == nil )
	{
		[self omLog:@"No destination - locate Half-Life.app with Choose... first."];
		goto done;
	}

	force = ( [forceButton state] == NSOnState );

	/* Anything a crashed run left behind goes first. A <gamedir>.partial or a
	 * half-unpacked tree holds a liblist.gam, and the engine registers any such
	 * directory as a Custom Game entry. */
	[OMFetch sweepLeftoversIn:destRoot sink:self];

	inst = [[[OMInstaller alloc] initWithSink:self
	                                resources:[self resourcesPath]
	                              destination:destRoot] autorelease];
	[inst setForceReinstall:force];
	if( force )
		[self omLog:@"Reinstall requested: already-installed mods will be fetched and re-copied."];

	fetch = [[[OMFetch alloc] initWithSink:self
	                             resources:[self resourcesPath]
	                                 cache:[[NSHomeDirectory()
	                                         stringByAppendingPathComponent:@"Downloads"]
	                                        stringByAppendingPathComponent:@"Half-Life Mods"]] autorelease];
	/* Roots for https. Shipped as a file rather than compiled in so a rotated CA
	 * can be fixed by replacing it, without a new binary - github.com moving to a
	 * Sectigo ECC root is a live example of that happening. */
	[fetch setCABundlePath:[[NSBundle mainBundle] pathForResource:@"ca-roots" ofType:@"pem"]];

	sources = [fetch loadSources];
	if( [sources count] == 0 )
	{
		[self omLog:@"mod-sources.txt is missing or empty - this app was built wrong."];
		[self omStatus:@"No sources configured."];
		goto done;
	}

	modMap = [inst loadModMap];

	/* ---- pass 1: content the player already has ---------------------------- */
	{
		NSEnumerator *e = [modMap keyEnumerator];
		NSString *gamedir;
		NSMutableArray *have = [NSMutableArray array];

		while(( gamedir = [e nextObject] ) != nil )
			if( [inst hasContentFor:gamedir] )
				[have addObject:gamedir];

		if( [have count] > 0 )
		{
			[self omLog:[NSString stringWithFormat:
				@"Found %u mod folder(s) already here. Adding our game code to them:",
				(unsigned)[have count]]];
			for( i = 0; i < [have count]; i++ )
			{
				NSString *g = [have objectAtIndex:i];
				NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];

				if( cancelled ) { [inner release]; break; }
				[self omStatus:[NSString stringWithFormat:@"Updating %@...", g]];
				err = nil;
				if( [inst adoptExistingMod:g error:&err] )
					adoptCount++;
				else
					[self omLog:[NSString stringWithFormat:@"      %@ - %@", g,
						( err ? err : @"unknown error" )]];
				[inner release];
			}
			[self omLog:@""];
		}
	}

	/* ---- pass 2: fetch what is left ---------------------------------------- */
	for( i = 0; i < [sources count] && !cancelled; i++ )
	{
		NSDictionary *src = [sources objectAtIndex:i];
		NSString *gamedir = [src objectForKey:@"mod"];
		NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
		NSString *staging;
		OMMod *mod;

		[self omProgress:(double)i / (double)[sources count]];

		/* Already there and not being forced: pass 1 has refreshed its game code,
		 * so there is nothing left worth an hour of downloading. */
		if( !force && [inst hasContentFor:gamedir] )
		{
			[inner release];
			continue;
		}

		mod = [inst modForGamedir:gamedir at:@"/"];
		[self showArtworkFor:mod];
		[self omLog:[NSString stringWithFormat:@"%@:", ( mod ? [mod title] : gamedir )]];

		err = nil;
		staging = [fetch stageMod:src into:destRoot error:&err];
		if( staging == nil )
		{
			if( [err isEqualToString:@"cancelled"] ) { [inner release]; break; }
			[self omLog:[NSString stringWithFormat:@"FAIL  %@ - %@", gamedir, ( err ? err : @"unknown error" )]];
			failCount++;
			[inner release];
			continue;
		}

		mod = [inst modForGamedir:gamedir at:staging];
		if( mod == nil )
		{
			[self omLog:[NSString stringWithFormat:@"FAIL  %@ - not listed in mods.map", gamedir]];
			[fm removeFileAtPath:staging handler:nil];
			failCount++;
			[inner release];
			continue;
		}

		err = nil;
		if( [inst installMod:mod error:&err] )
		{
			[self omLog:[NSString stringWithFormat:@"OK    %@", [mod title]]];
			okCount++;
		}
		else
		{
			[self omLog:[NSString stringWithFormat:@"FAIL  %@ - %@", [mod title],
				( err ? err : @"unknown error" )]];
			failCount++;
		}

		/* Staging and the finished install are both on the target volume, so the
		 * mod is briefly on disk twice. Deleting now keeps the peak at one mod
		 * rather than the whole catalogue. */
		[fm removeFileAtPath:staging handler:nil];
		[inner release];
	}

	/* ---- what we could not do, named rather than counted -------------------- */
	{
		NSEnumerator *e = [modMap keyEnumerator];
		NSString *gamedir;
		NSMutableArray *sourced = [NSMutableArray array];

		for( i = 0; i < [sources count]; i++ )
			[sourced addObject:[[sources objectAtIndex:i] objectForKey:@"mod"]];

		while(( gamedir = [e nextObject] ) != nil )
			if( ![sourced containsObject:gamedir] && ![inst hasContentFor:gamedir] )
				[noSource addObject:gamedir];
	}

	[self omArtwork:nil title:@"Half-Life Mods for old Macs"];
	[self omLog:@""];
	if( cancelled )
	{
		[self omProgress:0.0];
		[self omLog:[NSString stringWithFormat:
			@"Cancelled: %u installed, %u updated, %u failed.", okCount, adoptCount, failCount]];
		[self omLog:@"The mods listed OK above are complete and usable."];
		[self omLog:@"Run again to install the rest - finished mods are left alone, and"];
		[self omLog:@"part-finished downloads carry on from where they stopped."];
		[self omStatus:[NSString stringWithFormat:@"Cancelled - %u installed.", okCount]];
	}
	else
	{
		[self omProgress:1.0];
		[self omLog:[NSString stringWithFormat:@"Done: %u installed, %u already-present mods updated, %u failed.",
			okCount, adoptCount, failCount]];
		[self omLog:@"Launch Half-Life and pick a mod under Custom Game."];
		[self omStatus:[NSString stringWithFormat:@"%u installed, %u updated, %u failed.",
			okCount, adoptCount, failCount]];
	}

	/*
	 * Name every mod we did not install and say why, rather than reporting a
	 * smaller number than mods.map contains and leaving the user to work out
	 * which ones are missing.
	 */
	if( [noSource count] > 0 )
	{
		[self omLog:@""];
		[self omLog:[NSString stringWithFormat:@"%u mod(s) were not installed:", (unsigned)[noSource count]]];
		for( i = 0; i < [noSource count]; i++ )
		{
			NSString *g = [noSource objectAtIndex:i];
			[self omLog:[NSString stringWithFormat:@"    %@ - %@", g, OMSkipReason( g )]];
		}
		[self omLog:@"For each of these: put the mod's own folder next to Half-Life.app,"];
		[self omLog:@"then run this again and it will add the game code it needs."];
	}

	/* Again at the end. The sweep at the start is what guarantees correctness;
	 * this one just avoids leaving an empty container sitting in the player's
	 * game folder after a clean run. */
	[OMFetch sweepLeftoversIn:destRoot sink:nil];

	[self finishedAlert:okCount failed:failCount skipped:(unsigned)[noSource count]
	            adopted:adoptCount cancelled:cancelled destination:destRoot];

done:
	[self performSelectorOnMainThread:@selector(mainSetRunning:)
	                       withObject:[NSNumber numberWithBool:NO] waitUntilDone:NO];
	[pool release];
}

/* ---------------------------------------------------------------- actions -- */

/*
 * Make sure we know where to install before doing any work.
 *
 * The automatic search (OMInstaller +defaultDestination) covers the normal cases,
 * but it can legitimately come up empty - the game lives somewhere unusual, or
 * the only Half-Life.app around is not ours. Rather than let the user download
 * gigabytes and only then hit "No destination", ask for the folder up front.
 *
 * MUST be called on the main thread: NSOpenPanel is modal UI, and the callers
 * (the two button actions) run there before detaching their worker thread.
 * Returns NO if the user cancelled or picked somewhere unusable.
 */
- (BOOL)ensureDestination
{
	if( destRoot != nil )
		return YES;
	return [self pickDestination];
}

/*
 * Ask for the install folder.
 *
 * Finding Half-Life.app is a CONVENIENCE, not a constraint. It decides where this
 * panel opens and nothing else: mods install wherever the user says, including a
 * folder with no Half-Life.app in it. That is a reasonable thing to want. Somebody
 * may keep mods on another volume, stage them before moving them, or run more than
 * one copy of the game.
 *
 * It used to refuse any folder without Half-Life.app beside it, and it only
 * appeared at all when the automatic search had FAILED, so a wrong guess could not
 * be corrected from the UI.
 *
 * MUST be called on the main thread: NSOpenPanel is modal UI.
 */
- (BOOL)pickDestination
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSOpenPanel *panel;
	NSString *path, *start;

	panel = [NSOpenPanel openPanel];
	[panel setCanChooseDirectories:YES];
	[panel setCanChooseFiles:YES];        /* so the .app itself can be picked too */
	[panel setAllowsMultipleSelection:NO];
	[panel setCanCreateDirectories:YES];
	[panel setTitle:@"Where should mods be installed?"];
	[panel setPrompt:@"Install Here"];

	/* Open where the game is, if we found one. That is the whole benefit of the
	 * search: a sensible starting point, not a restriction. */
	start = destRoot;
	if( start == nil )
		start = [OMInstaller defaultDestination];
	if( start == nil )
		start = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
	if( ![fm fileExistsAtPath:start] )
		start = NSHomeDirectory();

	if( [panel runModalForDirectory:start file:nil types:nil] != NSOKButton )
	{
		[self omLog:@"Cancelled - install folder unchanged."];
		if( destRoot == nil )
			[self omStatus:@"No folder chosen."];
		return ( destRoot != nil );
	}

	path = [panel filename];
	if( path == nil )
		return ( destRoot != nil );

	/* Picking Half-Life.app itself is the obvious mistake, and it is unambiguous
	 * what was meant: mods go beside the app, not inside it. */
	if( [[path lastPathComponent] isEqualToString:@"Half-Life.app"] )
		path = [path stringByDeletingLastPathComponent];

	/* The one hard requirement: we must be able to write there. Everything else
	 * is advice. */
	if( !OMPathIsWritableDirectory( path ))
	{
		[self omLog:[NSString stringWithFormat:@"Cannot write to %@", path]];
		[self omLog:@"Pick a folder you own, on a disk that is not read-only."];
		[self omStatus:@"That folder is not writable."];
		return NO;
	}

	[destRoot release];
	destRoot = [path retain];
	[self omLog:[NSString stringWithFormat:@"Installing into: %@", destRoot]];

	/* Advice, not refusal. Mods install correctly into a folder with no game in
	 * it; they simply will not be playable until the game is there too, so say
	 * so once and carry on. */
	if( ![fm fileExistsAtPath:[path stringByAppendingPathComponent:@"Half-Life.app"]] )
	{
		[self omLog:@"Note: there is no Half-Life.app in that folder."];
		[self omLog:@"Mods will install, but move them beside the game to play them."];
	}
	else if( ![OMInstaller isOurGameApp:[path stringByAppendingPathComponent:@"Half-Life.app"]] )
	{
		[self omLog:@"Note: that Half-Life.app does not look like this port"];
		[self omLog:@"      (no Contents/MacOS/xash3d.bin). Continuing anyway."];
	}

	[self omStatus:@"Ready."];
	return YES;
}

- (void)chooseDestination:(id)sender
{
	if( running )
		return;
	[self pickDestination];
}

- (void)getMods:(id)sender
{
	if( running ) return;
	if( ![self ensureDestination] ) return;
	cancelled = NO;
	[self setRunning:YES];
	[NSThread detachNewThreadSelector:@selector(runGetMods:) toTarget:self withObject:nil];
}

- (void)cancel:(id)sender
{
	if( !running ) return;
	cancelled = YES;
	[self omStatus:@"Cancelling..."];
	[self omLog:@"Cancel requested - finishing the current file."];
}

/* ------------------------------------------------------------------- help -- */

/*
 * One string, used twice: a trimmed version is printed into the log at launch,
 * where the user is already looking, and the whole of it backs the Help window
 * for when that has scrolled away under install output.
 */
- (NSString *)helpText
{
	return
	@"WHAT THIS APP DOES\n"
	 "\n"
	 "It installs Half-Life mods so they work with Half-Life.app on this Mac.\n"
	 "The game code is built for PowerPC and Intel, so the same install works on a\n"
	 "G3, G4, G5 or an Intel Mac.\n"
	 "\n"
	 "This app supplies the CODE. The CONTENT - maps, models, sounds - comes from\n"
	 "each mod's own public release, downloaded from wherever its author published\n"
	 "it. We host none of it, and we never will.\n"
	 "\n"
	 "MINIMUM SPECS\n"
	 "\n"
	 "  Mac OS X 10.3.9 or later, PowerPC or Intel\n"
	 "  256 MB of memory (512 MB or more if you want the largest mods)\n"
	 "  About 6 GB of free disk space for the full set\n"
	 "  A working internet connection for Get Mods\n"
	 "\n"
	 "The memory figure is not arbitrary. The largest mod, Echoes, expands to\n"
	 "about 450 MB and is stored as one compressed block, so unpacking it is the\n"
	 "hungriest thing this app ever does. It has been measured doing exactly that\n"
	 "on a 450 MHz G3 with 448 MB.\n"
	 "\n"
	 "BEFORE YOU START\n"
	 "\n"
	 "You need Half-Life.app and your own retail Half-Life valve folder sitting\n"
	 "in the same folder. This app finds Half-Life.app by itself and says where;\n"
	 "if it cannot, it asks you to point at the folder holding it.\n"
	 "\n"
	 "Both this app and Half-Life.app must be copied OUT of the disk image first.\n"
	 "A disk image is read-only, so nothing can be installed while they run from\n"
	 "it.\n"
	 "\n"
	 "WHICH MODS\n"
	 "\n"
	 "This app knows 25 specific mods and no others. It works by supplying the Mac\n"
	 "game code for each one, compiled per mod from that mod's own source, so a mod\n"
	 "not on the list cannot be installed here however you point at it. That code\n"
	 "is also not interchangeable between mods, which is why anything unrecognised\n"
	 "is refused rather than installed hopefully.\n"
	 "\n"
	 "Of the 25:\n"
	 "\n"
	 "  18  have a public download this app can fetch and unpack. Get Mods does\n"
	 "      these unattended.\n"
	 "\n"
	 "   4  Afraid of Monsters, Escape from the Darkness, Poke646 Vendetta and\n"
	 "      The Gate. Their only public releases are Windows installer programs\n"
	 "      in formats no Mac tool can open, so there is nothing here to unpack.\n"
	 "      Install the mod's folder yourself and this app will add its game code.\n"
	 "\n"
	 "   3  Blue Shift, Opposing Force and Deathmatch Classic. These are Valve\n"
	 "      products you buy, not free mods, so this app will not download them\n"
	 "      from anywhere. If you own them and their folders are already next to\n"
	 "      Half-Life.app, Get Mods adds the game code and they work.\n"
	 "\n"
	 "Team Fortress Classic is not supported at all: no open server code exists for\n"
	 "this engine in any language, so there is nothing to compile. That is not a\n"
	 "licensing matter and not content being withheld.\n"
	 "\n"
	 "THE BUTTONS\n"
	 "\n"
	 "Get Mods fetches each mod in turn from its own publisher, checks it against a\n"
	 "known checksum, unpacks it, and installs it with the right game code. It also\n"
	 "looks for mod folders you already have and adds game code to those first,\n"
	 "before downloading anything.\n"
	 "\n"
	 "Choose Folder... sets where mods install. Normally the folder holding\n"
	 "Half-Life.app is found automatically; use this to install somewhere else,\n"
	 "such as another copy of the game or another volume. Mod content you already\n"
	 "have goes IN that folder, beside Half-Life.app, and Get Mods picks it up. It\n"
	 "may come from any platform's release, a Windows one included: maps, models,\n"
	 "sounds and liblist.gam are the same everywhere, and this app supplies the Mac\n"
	 "game code.\n"
	 "\n"
	 "IF YOU STOP PART WAY\n"
	 "\n"
	 "Both are resumable. Cancel, or quit and come back, and running it again\n"
	 "carries on: finished mods are skipped, and a part-finished download picks up\n"
	 "from exactly where it stopped rather than starting over. A mod that was only\n"
	 "part-copied is removed rather than left looking installed.\n"
	 "\n"
	 "Downloads are kept in your Downloads folder, under Half-Life Mods, so a\n"
	 "second run does not fetch them again. Delete that folder when you are done if\n"
	 "you want the space back.\n"
	 "\n"
	 "Reinstall mods that are already installed forces every mod to be fetched and\n"
	 "copied again from scratch. Use it if a mod's files were damaged or edited and\n"
	 "you want the shipped state back. It is slow, which is why it is off by\n"
	 "default.\n"
	 "\n"
	 "PLAYING A MOD\n"
	 "\n"
	 "Mods install next to Half-Life.app, and you start them from inside the game,\n"
	 "not from this app. Launch Half-Life.app, then choose Custom Game from the\n"
	 "main menu and pick the mod from the list.\n"
	 "\n"
	 "IF SOMETHING GOES WRONG\n"
	 "\n"
	 "Everything printed in the window is also written to a log file, named at the\n"
	 "top of the window. Keep that if you need to report a problem.\n";
}

/* Append `s` in one font and paragraph style. Written out longhand because
 * Objective-C 1.0 has no literals and 10.3 has no convenience for this. */
static void om_append_run( NSMutableAttributedString *dst, NSString *s,
                           NSFont *font, NSParagraphStyle *style )
{
	NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
		font, NSFontAttributeName, style, NSParagraphStyleAttributeName, nil];
	NSAttributedString *run =
		[[NSAttributedString alloc] initWithString:s attributes:attrs];

	[dst appendAttributedString:run];
	[run release];
}

/* A heading is a flush-left line in capitals. The letter test stops a line that
 * is only digits or punctuation from being promoted to a heading. */
static BOOL om_is_heading( NSString *line )
{
	if( [line length] == 0 || [line hasPrefix:@" "] )
		return NO;
	if( ![line isEqualToString:[line uppercaseString]] )
		return NO;
	return [line rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location
	       != NSNotFound;
}

/*
 * The help text as an attributed string.
 *
 * The source is hard-wrapped plain text because the SAME string is printed into
 * the log at launch, where fixed columns are what you want. Rendering that as-is
 * in a proportional font looks ragged: every line stops short of the margin,
 * because the breaks were chosen for an 80-column log. So this rebuilds it:
 *
 *   an all-capitals line      -> bold, with space above it
 *   a line indented 2 spaces  -> monospace, kept exactly as written, because
 *                                those are the tables and the file names, and
 *                                their columns are aligned with spaces
 *   anything else             -> prose: consecutive lines are JOINED into one
 *                                paragraph and left to wrap to the window
 *
 * The joining is the part that actually matters. Without it the text is merely
 * a different font with the old line breaks still in it.
 *
 * The log view deliberately does NOT get this treatment: it carries aligned
 * install output ("OK    Blue Shift"), which only lines up in a fixed pitch.
 */
- (NSAttributedString *)formattedHelp
{
	NSMutableAttributedString *out =
		[[[NSMutableAttributedString alloc] init] autorelease];
	NSArray *lines = [[self helpText] componentsSeparatedByString:@"\n"];
	NSMutableString *para = [NSMutableString string];
	NSFont *bodyFont = [NSFont systemFontOfSize:11.5];
	NSFont *headFont = [NSFont boldSystemFontOfSize:12.0];
	NSFont *monoFont = [NSFont userFixedPitchFontOfSize:10.0];
	NSMutableParagraphStyle *bodyStyle, *headStyle, *monoStyle;
	unsigned i, n;

	bodyStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
	[bodyStyle setParagraphSpacing:8.0];
	[bodyStyle setLineSpacing:1.0];

	headStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
	[headStyle setParagraphSpacingBefore:14.0];
	[headStyle setParagraphSpacing:5.0];

	/* Indented, and never wrapped back on itself: these lines are pre-aligned. */
	monoStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
	[monoStyle setFirstLineHeadIndent:16.0];
	[monoStyle setHeadIndent:16.0];

	n = [lines count];
	for( i = 0; i < n; i++ )
	{
		NSString *line = [lines objectAtIndex:i];
		BOOL indented = [line hasPrefix:@"  "];
		BOOL heading = om_is_heading( line );

		/* A blank line, a heading or a table row all end the paragraph in hand. */
		if( ( [line length] == 0 || heading || indented ) && [para length] > 0 )
		{
			om_append_run( out, [para stringByAppendingString:@"\n"],
			               bodyFont, bodyStyle );
			[para setString:@""];
		}

		if( heading )
			om_append_run( out, [line stringByAppendingString:@"\n"], headFont, headStyle );
		else if( indented )
			om_append_run( out, [line stringByAppendingString:@"\n"], monoFont, monoStyle );
		else if( [line length] > 0 )
		{
			if( [para length] > 0 )
				[para appendString:@" "];
			[para appendString:line];
		}
		/* Blank lines are dropped: the paragraph spacing provides the gap now. */
	}
	if( [para length] > 0 )
		om_append_run( out, para, bodyFont, bodyStyle );

	return out;
}

- (void)showModsHelp:(id)sender
{
	if( helpWindow == nil )
	{
		NSRect frame = NSMakeRect( 0, 0, 560, 460 );
		NSScrollView *scroll;
		NSTextView *text;

		helpWindow = [[NSWindow alloc]
			initWithContentRect:frame
			          styleMask:( NSTitledWindowMask | NSClosableWindowMask |
			                      NSMiniaturizableWindowMask | NSResizableWindowMask )
			            backing:NSBackingStoreBuffered
			              defer:NO];
		[helpWindow setTitle:@"Half-Life Mods Help"];
		[helpWindow center];
		/* The window outlives its close box: closing must hide it, not free it,
		 * or the next Help would send a message to a dead object. */
		[helpWindow setReleasedWhenClosed:NO];

		scroll = [[[NSScrollView alloc]
			initWithFrame:NSMakeRect( 0, 0, frame.size.width, frame.size.height )] autorelease];
		[scroll setHasVerticalScroller:YES];
		[scroll setBorderType:NSNoBorder];
		[scroll setAutoresizingMask:( NSViewWidthSizable | NSViewHeightSizable )];

		text = [[[NSTextView alloc] initWithFrame:[[scroll contentView] bounds]] autorelease];
		[text setEditable:NO];
		[text setRichText:YES];
		[text setAutoresizingMask:NSViewWidthSizable];
		[text setTextContainerInset:NSMakeSize( 14.0, 12.0 )];
		[[text textStorage] setAttributedString:[self formattedHelp]];
		[scroll setDocumentView:text];
		[[helpWindow contentView] addSubview:scroll];
	}
	[helpWindow makeKeyAndOrderFront:nil];
}

/* ------------------------------------------------------------------ about -- */

/*
 * A hand-built About window rather than -orderFrontStandardAboutPanel:, for one
 * reason: the standard panel's artwork is not something we can attach an action
 * to, and Gordon needs to be clickable.
 *
 * The image is an ordinary borderless NSButton with an image and no title, which
 * is a click target on 10.3 without subclassing anything.
 */
- (void)showAbout:(id)sender
{
	if( aboutWindow == nil )
	{
		NSRect frame = NSMakeRect( 0, 0, 420, 300 );
		NSView *content;
		NSButton *gordon;
		NSImage *art;
		NSTextField *name, *blurb;

		aboutWindow = [[NSWindow alloc]
			initWithContentRect:frame
			          styleMask:( NSTitledWindowMask | NSClosableWindowMask )
			            backing:NSBackingStoreBuffered
			              defer:NO];
		[aboutWindow setTitle:@"About Half-Life Mods"];
		[aboutWindow center];
		[aboutWindow setReleasedWhenClosed:NO];
		content = [aboutWindow contentView];

		/* The artwork is the figure cut out of its backdrop, so the frame is the
		 * figure's own bounds (147x240) and not a picture box: with a transparent
		 * background any spare frame would just be dead click target. Regenerate
		 * it with scripts/make-about-art.py, which prints the size to use here if
		 * the source art is ever changed.
		 *
		 * The PNG is authored at exactly these dimensions and -setSize: pins the
		 * NSImage to them, so nothing is resampled on screen. That matters here:
		 * none of the target machines has a HiDPI display, and 10.3's NSButton
		 * has no image-scaling mode to fall back on. */
		/* 135x220 keeps the artwork's own aspect (269x440 pixels, 0.611). The frame
		 * used to be 147x240 and setSize forced the image into it, stretching
		 * Gordon horizontally by about 18 percent. scripts/make-about-art.py
		 * prints the correct point size when it regenerates the file. */
		gordon = [[[NSButton alloc] initWithFrame:NSMakeRect( 24, 30, 135, 220 )] autorelease];
		[gordon setBordered:NO];
		[gordon setTitle:@""];
		[gordon setImagePosition:NSImageOnly];
		[gordon setButtonType:NSMomentaryChangeButton];
		art = [[[NSImage alloc] initWithContentsOfFile:
			[[self resourcesPath] stringByAppendingPathComponent:@"About-Gordon.png"]] autorelease];
		if( art != nil )
		{
			[art setSize:NSMakeSize( 135, 220 )];
			[gordon setImage:art];
		}
		[gordon setTarget:self];
		[gordon setAction:@selector(gordonClicked:)];
		[content addSubview:gordon];

		name = [self labelAt:NSMakeRect( 190, 226, 206, 24 )
		                text:@"Half-Life Mods" bold:YES];
		[content addSubview:name];

		blurb = [self labelAt:NSMakeRect( 190, 50, 206, 170 )
		                text:@"Installs 25 Half-Life mods for the old-Mac port of "
		                      "Xash3D FWGS.\n\n"
		                      "PowerPC and Intel, Mac OS X 10.3 and later.\n\n"
		                      "Supplies the game code only. Every map, model and "
		                      "sound is downloaded from that mod's own public "
		                      "release. No content is bundled here."
		                bold:NO];
		[blurb setSelectable:YES];
		[content addSubview:blurb];
	}
	[aboutWindow makeKeyAndOrderFront:nil];
}

/*
 * Gordon. See OMAbout.m for where the sound comes from and why we ship none of
 * it. Does nothing at all if the player's pak0.pak is not to hand, which is the
 * right behaviour for something nobody was told about.
 */
- (void)gordonClicked:(id)sender
{
	OMPlayScientist( destRoot );
}

/* --------------------------------------------------------------- app glue -- */

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

/*
 * Quitting while a job is in flight.
 *
 * Reported on the G3 in an earlier design: the app was quit mid-job and killed
 * outright, leaving the machine in a state the user had no obvious way to clear.
 * Nothing was corrupted, but nothing cleaned up either.
 *
 * Idle: quit immediately, no prompt. A confirmation for a no-op is just an
 * obstacle. Busy: confirm, and if they mean it take the Cancel path so any
 * part-copied mod is removed, then quit once the worker has genuinely stopped
 * rather than the instant the user clicks.
 */
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
	int r;

	if( !running )
		return NSTerminateNow;

	/* NSRunAlertPanel rather than NSAlert, for the same reason as the read-only
	 * volume check above: NSAlert only arrived in 10.3 and this builds against
	 * the 10.3.9 SDK. The default (rightmost, return-key) button is the safe one. */
	r = NSRunAlertPanel( @"Half-Life Mods is still working",
		@"%@", @"Keep Working", @"Stop and Quit", nil,
		@"Quitting now stops the installation and tidies up what it started: any "
		 "mod that was only part-copied or part-unpacked is removed, so it cannot "
		 "look installed when it is not.\n\n"
		 "Mods that already finished are kept. Running this again later picks up "
		 "where it left off." );

	if( r == NSAlertDefaultReturn )
		return NSTerminateCancel;

	cancelled = YES;
	quitTicks = 0;
	[self omStatus:@"Stopping..."];
	[self omLog:@"Quit requested - stopping and tidying up."];

	/*
	 * Poll rather than block: the run loop has to keep turning so the log keeps
	 * updating and the window still draws while the worker unwinds. Deleting a
	 * part-unpacked mod tree is not instant on a G3.
	 */
	[NSTimer scheduledTimerWithTimeInterval:0.25
	                                 target:self
	                               selector:@selector(quitWhenIdle:)
	                               userInfo:nil
	                                repeats:YES];
	return NSTerminateLater;
}

- (void)quitWhenIdle:(NSTimer *)t
{
	if( running && ++quitTicks < 240 )      /* 60s, then stop waiting */
		return;

	if( running )
		[self omLog:@"Worker did not stop in 60s - quitting anyway."];

	[t invalidate];
	[NSApp replyToApplicationShouldTerminate:YES];
}

- (void)dealloc
{
	/* titleField and statusField are NOT released here: labelAt: returns them
	 * autoreleased and nothing ever retained them, so their only owner is the
	 * superview the [window release] above tears down. Releasing them again was
	 * a latent over-release, unreachable only because terminate: exits before
	 * this ever runs. */
	[window release]; [artView release];
	[progress release]; [logView release];
	[forceButton release]; [helpWindow release]; [aboutWindow release];
	[destRoot release]; [logPath release]; [logFile release];
	[super dealloc];
}

@end
