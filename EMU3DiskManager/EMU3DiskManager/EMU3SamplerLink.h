#import <Cocoa/Cocoa.h>
@class EMU3BlockServer;

/// "Sampler Link" window: serves an image to the BlueSCSI board over USB so the sampler sees it as a
/// live SCSI disk, and shows what the link is doing.
@interface EMU3SamplerLinkController : NSWindowController

/// Returns the images currently open in the app (file URLs).
@property (nonatomic, copy) NSArray<NSURL *> *(^mountedImageURLs)(void);
/// Called on the main queue when the sampler changed the image behind the app's back (reload the model).
@property (nonatomic, copy) void (^imageChangedBySampler)(NSURL *imageURL);
/// Called when the user picks an image through "Choose…" so the app can open it too.
@property (nonatomic, copy) void (^openImage)(NSURL *imageURL);

/// Called on the main queue when serving starts (server) or stops (nil).
@property (nonatomic, copy) void (^servingChanged)(EMU3BlockServer *server);
@property (nonatomic, readonly) EMU3BlockServer *activeServer;
/// The app edited the served image: reminds the user to rescan on the sampler.
- (void)noteImageEditedByApp;

@property (nonatomic, readonly) BOOL serving;
@property (nonatomic, readonly) NSURL *servedImageURL;

/// Adds a timestamped line to the window's log.
- (void)logLine:(NSString *)line;

- (void)showAndRefresh;
/// Picks up the image the background helper is already serving (call at launch).
- (void)attachIfServed;
- (void)stopServing;

@end
