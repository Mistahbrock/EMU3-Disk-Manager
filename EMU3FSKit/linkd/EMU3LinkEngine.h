#import <Foundation/Foundation.h>

/// Serves the blocks of one .hda image to the BlueSCSI board over its second USB serial port
/// ("BlueSCSI USB Block Link"), so the sampler sees the image as a live SCSI disk.
///
/// Protocol (little endian), see the firmware's BlueSCSI_usbblk.h:
///   board -> Mac : B5 C5 cmd tag lba[4] count[2] pad[2]      (cmd 1 READ, 2 WRITE + count*512 bytes, 4 PING)
///   Mac -> board : C5 B5 status tag count[2]                 (READ is followed by count*512 bytes)
typedef NS_ENUM(NSInteger, EMU3LinkEngineState) {
    EMU3LinkEngineStateStopped = 0,
    EMU3LinkEngineStateWaitingForBoard,   // serving, but no board port found (not plugged in / card still mounted)
    EMU3LinkEngineStateBoardConnected,    // port is open, no request seen yet
    EMU3LinkEngineStateActive,            // the board is asking for blocks
};

@interface EMU3LinkEngine : NSObject

@property (nonatomic, readonly) NSURL *imageURL;
@property (nonatomic, readonly) BOOL writable;
@property (nonatomic) uint8_t scsiID;   // the SCSI ID the board presents (default 7)

// Snapshot values, updated on the main queue just before onChange fires.
@property (nonatomic, readonly) EMU3LinkEngineState state;
@property (nonatomic, readonly, copy) NSString *portPath;
@property (nonatomic, readonly) uint64_t readRequests;
@property (nonatomic, readonly) uint64_t writeRequests;
@property (nonatomic, readonly) uint64_t bytesRead;
@property (nonatomic, readonly) uint64_t bytesWritten;
@property (nonatomic, readonly) uint32_t lastLBA;
@property (nonatomic, readonly) NSTimeInterval lastActivity;   // CFAbsoluteTime of the last request, 0 = none

// All callbacks arrive on the main queue.
@property (nonatomic, copy) void (^onChange)(EMU3LinkEngine *server);
@property (nonatomic, copy) void (^onLog)(NSString *line);
/// Fired about a second after the sampler stopped writing: the image content changed behind the app's back.
@property (nonatomic, copy) void (^onImageChangedBySampler)(EMU3LinkEngine *server);

- (instancetype)initWithImageURL:(NSURL *)url writable:(BOOL)writable;
- (BOOL)startWithError:(NSError **)error;
- (void)stop;
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
