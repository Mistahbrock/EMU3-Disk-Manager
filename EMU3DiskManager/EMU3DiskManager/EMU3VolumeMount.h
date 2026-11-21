#import <Foundation/Foundation.h>
@class EMU3Filesystem, EMU3BlockServer;

/// Mounts an open image as a real volume (banks as files, folders as folders) through the helper
/// "emu3nfs" (a small NFS server on localhost that macOS mounts; no FUSE needed), so Finder and any program can copy banks in and out. Every edit made through the mount asks
/// this class first (stdin/stdout handshake), so it is serialized with the app's own edits and with the
/// sampler when the image is served over the Sampler Link.
@interface EMU3VolumeMount : NSObject

/// YES when the helper is installed.
+ (BOOL)isAvailable;
+ (NSString *)unavailableReason;

@property (nonatomic, readonly) EMU3Filesystem *filesystem;
@property (nonatomic, readonly) NSURL *mountPoint;
@property (nonatomic, readonly) BOOL mounted;

/// Returns the block server currently serving the image (or nil). Evaluated on every edit.
@property (nonatomic, copy) EMU3BlockServer *(^serverForImage)(NSURL *imageURL);
/// Main queue: a program changed the image through the mount (reload the model and refresh views).
@property (nonatomic, copy) void (^imageChangedThroughMount)(EMU3VolumeMount *mount);
/// Main queue: the mount went away (unmounted in Finder, helper died, ...).
@property (nonatomic, copy) void (^didStop)(EMU3VolumeMount *mount);

- (instancetype)initWithFilesystem:(EMU3Filesystem *)fs;
/// Starts the helper; `done` runs on the main queue once the volume is visible (or with an error).
- (void)mountWithCompletion:(void (^)(NSError *error))done;
- (void)unmount;

@end
