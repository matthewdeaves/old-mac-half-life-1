/*
 * SRController.h - "Half-Life System Report".
 *
 * Gathers what this project needs to know about a Mac in order to decide
 * whether the universal binary can support it, and puts it on the clipboard in
 * one press so it can be pasted into a GitHub issue.
 *
 * It exists because the fat binary grades by CPU subtype alone (see issue #14),
 * so a machine can be locked out by a combination nobody here owns and nobody
 * here can test. This app has to run on exactly those machines, which is why it
 * is a plain [ppc, x86_64] bundle with no unusual requirements and no network
 * access.
 *
 * 10.3 rules apply throughout, same as the mod installer: no @property, no fast
 * enumeration, no NSInteger, no blocks, no ARC, no nibs.
 */

#import <Cocoa/Cocoa.h>

@interface SRController : NSObject
{
	NSWindow *window;
	NSTextView *textView;
	NSButton *copyButton;
	NSButton *saveButton;
	NSString *report;
	NSWindow *aboutWindow;
}

/* The report text, for the GUI or for -print on the command line. */
NSString *SRReportText( void );

- (void)showWindow;
- (void)copyReport:(id)sender;
- (void)saveReport:(id)sender;
- (void)showAbout:(id)sender;
/* Clicking the About picture plays a line out of the player's own pak0.pak.
 * Silent no-op when there is no game data beside the app. */
- (void)playScientist:(id)sender;

@end
