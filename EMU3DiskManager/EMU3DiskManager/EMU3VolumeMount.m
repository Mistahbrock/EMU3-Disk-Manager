#import "EMU3VolumeMount.h"
#import "EMU3Filesystem.h"
#import "EMU3BlockServer.h"
#import <sys/mount.h>

@implementation EMU3VolumeMount {
    NSTask *_task;
    NSPipe *_toHelper, *_fromHelper;
    NSMutableData *_inBuf;
    dispatch_semaphore_t _editDone;
    BOOL _stopping;
    BOOL _mountedFlag;
}

+ (NSString *)helperPath {
    NSString *p = [NSBundle.mainBundle pathForResource:@"emu3nfs" ofType:nil];
    if (p) return p;
    p = [NSHomeDirectory() stringByAppendingPathComponent:@"Developer/EMU3FSKit/emu3nfs"];
    return [NSFileManager.defaultManager isExecutableFileAtPath:p] ? p : nil;
}
+ (BOOL)isAvailable { return [self unavailableReason] == nil; }
+ (NSString *)unavailableReason {
    if (![self helperPath]) return @"The emu3nfs helper is missing from the app.";
    return nil;
}

- (instancetype)initWithFilesystem:(EMU3Filesystem *)fs {
    self = [super init];
    if (self) _filesystem = fs;
    return self;
}

- (NSURL *)mountPoint {
    NSString *name = _filesystem.imageURL.lastPathComponent.stringByDeletingPathExtension ?: @"EMU3";
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"EMU3 Disks"];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
}

- (NSError *)_err:(NSString *)m { return [NSError errorWithDomain:@"EMU3VolumeMount" code:1 userInfo:@{NSLocalizedDescriptionKey: m}]; }

static BOOL IsVolumeMounted(NSString *path) {
    struct statfs s; if (statfs(path.fileSystemRepresentation, &s) != 0) return NO;
    NSString *from = @(s.f_mntfromname);
    return [from hasPrefix:@"localhost:/"] && strcmp(s.f_fstypename, "nfs") == 0 && strcmp(s.f_mntonname, [path stringByResolvingSymlinksInPath].fileSystemRepresentation) == 0;
}

- (void)mountWithCompletion:(void (^)(NSError *))done {
    NSString *why = [EMU3VolumeMount unavailableReason];
    if (why) { done([self _err:why]); return; }
    NSURL *mp = self.mountPoint;
    NSError *e = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:mp withIntermediateDirectories:YES attributes:nil error:&e];
    if (IsVolumeMounted(mp.path)) { done([self _err:@"This image is already mounted."]); return; }
    [_filesystem synchronizeToDisk:nil];

    _task = [[NSTask alloc] init];
    _task.executableURL = [NSURL fileURLWithPath:[EMU3VolumeMount helperPath]];
    _task.arguments = @[_filesystem.imageURL.path, mp.path, @"--gate"];
    _toHelper = [NSPipe pipe]; _fromHelper = [NSPipe pipe];
    _task.standardInput = _toHelper; _task.standardOutput = _fromHelper;
    _task.standardError = [NSFileHandle fileHandleWithNullDevice];
    _inBuf = [NSMutableData data];
    __weak typeof(self) weak = self;
    _fromHelper.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (d.length == 0) { h.readabilityHandler = nil; return; }
        [weak _consume:d];
    };
    _task.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weak _helperExited]; });
    };
    if (![_task launchAndReturnError:&e]) { done(e); return; }

    // wait (off the main thread) until the volume shows up
    NSString *path = mp.path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = NO;
        for (int i = 0; i < 100 && !ok; i++) {
            EMU3VolumeMount *st = weak;
            if (!st || !st->_task.running) break;
            if (IsVolumeMounted(path)) { ok = YES; break; }
            usleep(100 * 1000);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) { [weak _setMounted]; done(nil); }
            else { [weak unmount]; done([weak _err:@"The volume did not appear."]); }
        });
    });
}

- (BOOL)mounted { return _mountedFlag; }
- (void)_setMounted { _mountedFlag = YES; }

- (void)_consume:(NSData *)d {
    [_inBuf appendData:d];
    for (;;) {
        const char *b = _inBuf.bytes; NSUInteger n = _inBuf.length, i = 0;
        while (i < n && b[i] != '\n') i++;
        if (i >= n) return;
        char c = i > 0 ? b[0] : 0;
        [_inBuf replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];
        if (c == 'B') [self _beginRemoteEdit];
        else if (c == 'E') [self _endRemoteEdit];
    }
}

// The helper wants to edit the image. Hold the app's serial I/O queue (and the sampler server, if the image
// is served) from now until it reports "E".
- (void)_beginRemoteEdit {
    EMU3Filesystem *fs = _filesystem;
    EMU3BlockServer *srv = self.serverForImage ? self.serverForImage(fs.imageURL) : nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    _editDone = sem;
    NSFileHandle *out = _toHelper.fileHandleForWriting;
    dispatch_async(fs.ioQueue, ^{
        BOOL ok = srv ? [srv acquireForEditWithIdle:2.0 timeout:4.0] : YES;
        [out writeData:[(ok ? @"OK\n" : @"NO\n") dataUsingEncoding:NSASCIIStringEncoding]];
        if (!ok) return;
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));
        if (srv) [srv releaseEdit];
    });
}
- (void)_endRemoteEdit {
    if (_editDone) { dispatch_semaphore_signal(_editDone); _editDone = nil; }
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weak.imageChangedThroughMount) weak.imageChangedThroughMount(weak);
    });
}

- (void)unmount {
    _stopping = YES;
    NSString *mp = self.mountPoint.path;
    NSTask *u = [[NSTask alloc] init];
    u.executableURL = [NSURL fileURLWithPath:@"/sbin/umount"];
    u.arguments = @[mp];
    u.standardError = [NSFileHandle fileHandleWithNullDevice];
    [u launchAndReturnError:nil];
    [u waitUntilExit];
    if (u.terminationStatus != 0 && IsVolumeMounted(mp)) {
        NSTask *f = [[NSTask alloc] init];
        f.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/diskutil"];
        f.arguments = @[@"unmount", @"force", mp];
        f.standardOutput = [NSFileHandle fileHandleWithNullDevice]; f.standardError = [NSFileHandle fileHandleWithNullDevice];
        [f launchAndReturnError:nil]; [f waitUntilExit];
    }
    if (_task.running) [_task terminate];
}

- (void)_helperExited {
    _fromHelper.fileHandleForReading.readabilityHandler = nil;
    if (_editDone) { dispatch_semaphore_signal(_editDone); _editDone = nil; }
    BOOL wasMounted = _mountedFlag;
    _mountedFlag = NO;
    if (wasMounted && self.didStop) self.didStop(self);
    // the mount point folder is ours: remove it when empty
    [NSFileManager.defaultManager removeItemAtURL:self.mountPoint error:nil];
}

@end
