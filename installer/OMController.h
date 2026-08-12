/*
 * OMController.h - the window, and the worker thread behind it.
 *
 * The UI is built in code rather than from a nib. A nib written by a modern
 * Xcode will not open on 10.3, and one written for 10.3 is awkward to maintain;
 * a few dozen lines of AppKit avoids owning that problem at all.
 */

#import "OldMacMods.h"

@interface OMController : NSObject <OMProgressSink>
{
	NSWindow           *window;
	NSImageView        *artView;
	NSTextField        *titleField;
	NSTextField        *statusField;
	NSProgressIndicator *progress;
	NSTextView         *logView;
	NSButton           *getButton;
	NSButton           *cancelButton;
	NSButton           *forceButton;   /* reinstall already-installed mods */
	NSButton           *chooseButton;  /* pick the install folder */

	NSString *destRoot;      /* folder containing Half-Life.app */
	NSString *logPath;
	NSFileHandle *logFile;

	NSWindow *helpWindow;    /* built lazily, on first Help */
	NSWindow *aboutWindow;   /* ditto, on first About */

	BOOL running;
	BOOL cancelled;
	int  quitTicks;          /* how long we have waited for the worker to stop */
}

- (void)showWindow;

/* actions */
- (void)getMods:(id)sender;
- (void)chooseDestination:(id)sender;
- (void)cancel:(id)sender;
- (void)showModsHelp:(id)sender;
- (void)showAbout:(id)sender;
- (void)gordonClicked:(id)sender;

/* Declared here, not just defined in the .m, because they call each other in
 * source order and gcc-4.0 (the PowerPC half of this build) warns on a selector
 * it has not seen yet. */
- (NSAttributedString *)formattedHelp;
- (NSDictionary *)attributesForLogLine:(NSString *)line;
- (NSArray *)introTitlesDownloadable:(BOOL)wantDownloadable;
- (void)omLogTitleList:(NSArray *)titles;
- (BOOL)ensureDestination;
- (BOOL)pickDestination;
- (void)quitWhenIdle:(NSTimer *)t;
- (NSString *)helpText;

@end
