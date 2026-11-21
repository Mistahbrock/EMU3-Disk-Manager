#import <Foundation/Foundation.h>

/// Client of the background helper emu3linkd, which serves one .hda image to the BlueSCSI board over its second USB
/// serial port ("BlueSCSI USB Block Link") so the sampler always sees it as a live SCSI disk, with or without this app.
///
/// Protocol (little endian), see the firmware's BlueSCSI_usbblk.h:
///   board -> Mac : B5 C5 cmd tag lba[4] count[2] pad[2]      (cmd 1 READ, 2 WRITE + count*512 bytes, 4 PING)
///   Mac -> board : C5 B5 status tag count[2]                 (READ is followed by count*512 bytes)
typedef NS_ENUM(NSInteger, EMU3LinkState) {
    EMU3LinkStateStopped = 0,
    EMU3LinkStateWaitingForBoard,   // serving, but no board port found (not plugged in / card still mounted)
    EMU3LinkStateBoardConnected,    // port is open, no request seen yet
    EMU3LinkStateActive,            // the board is asking for blocks
};

@interface EMU3BlockServer : NSObject

@property (nonatomic, readonly) NSURL *imageURL;
@property (nonatomic, readonly) BOOL writable;

// Snapshot values, updated on the main queue just before onChange fires.
@property (nonatomic, readonly) EMU3LinkState state;
@property (nonatomic, readonly, copy) NSString *portPath;
@property (nonatomic, readonly) uint64_t readRequests;
@property (nonatomic, readonly) uint64_t writeRequests;
@property (nonatomic, readonly) uint64_t bytesRead;
@property (nonatomic, readonly) uint64_t bytesWritten;
@property (nonatomic, readonly) uint32_t lastLBA;
@property (nonatomic, readonly) NSTimeInterval lastActivity;   // CFAbsoluteTime of the last request, 0 = none

// All callbacks arrive on the main queue.
@property (nonatomic, copy) void (^onChange)(EMU3BlockServer *server);
@property (nonatomic, copy) void (^onLog)(NSString *line);
/// Fired about a second after the sampler stopped writing: the image content changed behind the app's back.
@property (nonatomic, copy) void (^onImageChangedBySampler)(EMU3BlockServer *server);

- (instancetype)initWithImageURL:(NSURL *)url writable:(BOOL)writable;
/// Selects this image for the sampler: writes serve.txt, which the background helper (emu3linkd, started at login) serves.
- (BOOL)startWithError:(NSError **)error;
/// Stops watching. The helper keeps serving, also when the app quits.
- (void)stop;
/// Stops serving: the sampler loses the disk.
- (void)stopServing;
/// A proxy for the image the helper is serving right now, or nil when it serves nothing.
+ (instancetype)attachToServedImage;
/// The SCSI ID the board presents (scsiid.txt, default 7).
+ (NSInteger)boardSCSIID;
+ (void)setBoardSCSIID:(NSInteger)sid;
@property (nonatomic, readonly) BOOL running;

/// Size of the image in bytes (what the board's ini USBBlockDriveMB has to match).
@property (nonatomic, readonly) uint64_t imageSize;

/// Edit guard for the app's own file operations on the served image. Returns NO when the sampler used the disk
/// within `idle` seconds for the whole `timeout` (the edit must then be refused). On YES the caller holds the
/// server: the sampler's requests wait until -releaseEdit, so the sampler never sees a half-finished edit.
/// Must be paired, on the same thread.
- (BOOL)acquireForEditWithIdle:(NSTimeInterval)idle timeout:(NSTimeInterval)timeout;
- (void)releaseEdit;

@end
