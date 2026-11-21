#import <Cocoa/Cocoa.h>

@class EMU3Filesystem;

/// Tooltips: every tip is registered here, so the Settings switch can turn them all on or off at once.
BOOL EMU3TooltipsEnabled(void);
void EMU3Tip(id object, NSString *tip);     // NSView, NSToolbarItem or NSMenuItem
void EMU3ApplyTooltipSetting(void);

@interface MainWindowController : NSWindowController <NSSplitViewDelegate, NSUserInterfaceValidations>

- (void)openImageAtURL:(NSURL *)url;
- (void)undo:(id)sender;
- (void)redo:(id)sender;
- (void)deleteSelectedItem:(id)sender;
/// The folder watched for images (default ~/EMU3 Images), and the picker that changes it.
- (NSURL *)imageFolderURL;
- (void)chooseImageFolder:(id)sender;

@end
