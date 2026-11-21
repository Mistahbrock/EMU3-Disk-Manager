// emu3linkd: also mounts every .hda/.iso in the watch folders (watch.txt) as a volume under ~/EMU3 Disks (via emu3nfs).
// emu3linkd: serves the image named in serve.txt to the BlueSCSI board over its USB block link, with no app running.
// Files in ~/Library/Application Support/EMU3:
//   serve.txt   line 1 = image path, line 2 = "ro" for read-only (default read-write)
//   scsiid.txt  the SCSI ID the board presents, 0-7 (default 7); set it with BlueID
// Control socket link.sock (one command per line):
//   STATUS            -> streams "S <state> <port|-> <reads> <writes> <bytesR> <bytesW> <lba> <activity> <size> <id> <imgChanges> <path>"
//   ACQ <idle> <tmo>  -> "OK" (the sampler is held until "REL" or disconnect) or "NO"
#import <Foundation/Foundation.h>
#import "EMU3LinkEngine.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <sys/stat.h>
#import <signal.h>
#import <sys/mount.h>

static NSString *Base(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/EMU3"]; }
static EMU3LinkEngine *gEngine;
static NSString *gPath;
static BOOL gRW = YES;
static volatile uint64_t gImgChanges;

static NSString *ReadLine(int fd, BOOL *eof, double timeout) {
    NSMutableData *d = [NSMutableData data];
    for (;;) {
        fd_set rs; FD_ZERO(&rs); FD_SET(fd, &rs);
        struct timeval tv = { (long)timeout, (int)((timeout - (long)timeout) * 1e6) };
        int r = select(fd + 1, &rs, NULL, NULL, &tv);
        if (r == 0) return nil;
        char c; ssize_t n = read(fd, &c, 1);
        if (n <= 0) { *eof = YES; return nil; }
        if (c == '\n') return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        [d appendBytes:&c length:1];
    }
}

static BOOL SendStr(int fd, NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    return write(fd, d.bytes, d.length) == (ssize_t)d.length;
}

static void HandleClient(int fd) {
    @autoreleasepool {
        BOOL eof = NO;
        NSString *cmd = ReadLine(fd, &eof, 5);
        if ([cmd isEqualToString:@"STATUS"]) {
            for (;;) {
                EMU3LinkEngine *e; @synchronized (NSObject.class) { e = gEngine; }
                NSString *line;
                if (e && e.running)
                    line = [NSString stringWithFormat:@"S %ld %@ %llu %llu %llu %llu %u %.3f %llu %u %llu %@\n", (long)e.state, e.portPath.lastPathComponent ?: @"-",
                            e.readRequests, e.writeRequests, e.bytesRead, e.bytesWritten, e.lastLBA, e.lastActivity, e.imageSize, e.scsiID, gImgChanges, gPath];
                else line = [NSString stringWithFormat:@"S 0 - 0 0 0 0 0 0 0 0 %llu -\n", gImgChanges];
                if (!SendStr(fd, line)) break;
                usleep(500000);
            }
        } else if ([cmd hasPrefix:@"ACQ"]) {
            NSArray *p = [cmd componentsSeparatedByString:@" "];
            double idle = p.count > 1 ? [p[1] doubleValue] : 2, tmo = p.count > 2 ? [p[2] doubleValue] : 4;
            EMU3LinkEngine *e; @synchronized (NSObject.class) { e = gEngine; }
            BOOL ok = e ? [e acquireForEditWithIdle:idle timeout:tmo] : YES;
            SendStr(fd, ok ? @"OK\n" : @"NO\n");
            if (ok) {
                BOOL gone = NO;
                while (!gone) { NSString *l = ReadLine(fd, &gone, 60); if ([l isEqualToString:@"REL"]) break; }
                if (e) [e releaseEdit];
            }
        }
        close(fd);
    }
}

static void StartSocket(void) {
    NSString *path = [Base() stringByAppendingPathComponent:@"link.sock"];
    unlink(path.fileSystemRepresentation);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    strlcpy(a.sun_path, path.fileSystemRepresentation, sizeof a.sun_path);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 8) != 0) { perror("emu3linkd socket"); exit(1); }
    chmod(path.fileSystemRepresentation, 0600);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (;;) {
            int c = accept(s, NULL, NULL);
            if (c < 0) continue;
            NSThread *t = [[NSThread alloc] initWithBlock:^{ HandleClient(c); }];
            [t start];
        }
    });
}

static void Poll(void) {
    NSString *txt = [NSString stringWithContentsOfFile:[Base() stringByAppendingPathComponent:@"serve.txt"] encoding:NSUTF8StringEncoding error:nil];
    NSArray *lines = [txt componentsSeparatedByString:@"\n"];
    NSString *path = lines.count ? [lines[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    BOOL rw = !(lines.count > 1 && [[lines[1] lowercaseString] hasPrefix:@"ro"]);
    NSString *idTxt = [NSString stringWithContentsOfFile:[Base() stringByAppendingPathComponent:@"scsiid.txt"] encoding:NSUTF8StringEncoding error:nil];
    uint8_t sid = idTxt.length ? (uint8_t)MAX(0, MIN(7, idTxt.integerValue)) : 7;
    BOOL exists = path.length && [NSFileManager.defaultManager fileExistsAtPath:path];
    BOOL changed = ![path isEqualToString:gPath ?: @""] || rw != gRW;
    if (gEngine && (!exists || changed)) {
        EMU3LinkEngine *old; @synchronized (NSObject.class) { old = gEngine; gEngine = nil; }
        [old stop]; gPath = nil;
        NSLog(@"stopped serving");
    }
    if (!gEngine && exists) {
        EMU3LinkEngine *e = [[EMU3LinkEngine alloc] initWithImageURL:[NSURL fileURLWithPath:path] writable:rw];
        e.scsiID = sid;
        e.onImageChangedBySampler = ^(EMU3LinkEngine *x) { gImgChanges++; };
        e.onLog = ^(NSString *l) { NSLog(@"%@", l); };
        NSError *err = nil;
        if ([e startWithError:&err]) {
            @synchronized (NSObject.class) { gEngine = e; }
            gPath = path; gRW = rw;
            NSLog(@"serving %@ as SCSI ID %u", path, sid);
        } else NSLog(@"cannot serve %@: %@", path, err.localizedDescription);
    }
    if (gEngine && gEngine.scsiID != sid) { gEngine.scsiID = sid; NSLog(@"SCSI ID is now %u", sid); }
}


#pragma mark - auto-mount of the images in the watch folders (volumes under ~/EMU3 Disks)

@interface MountEntry : NSObject
@property (nonatomic, strong) NSTask *task;
@property (nonatomic) BOOL gated;
@property (nonatomic) CFAbsoluteTime started;
@end
@implementation MountEntry
@end

static NSMutableDictionary<NSString *, MountEntry *> *gMounts;     // only touched on gScanQueue
static dispatch_queue_t gScanQueue;

static NSString *VolumeHelper(void) {
    for (NSString *d in @[Base(), @"/Library/Application Support/EMU3"]) {
        NSString *p = [d stringByAppendingPathComponent:@"emu3nfs"];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

static BOOL IsMounted(NSString *mp) {
    struct statfs *fs; int n = getmntinfo(&fs, MNT_NOWAIT);
    for (int i = 0; i < n; i++) if (strcmp(fs[i].f_mntonname, mp.fileSystemRepresentation) == 0) return YES;
    return NO;
}

static void RunTool(NSString *path, NSArray *args) {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = path; t.arguments = args;
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice; t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if ([t launchAndReturnError:nil]) [t waitUntilExit];
}

static void Unmount(NSString *mp) {
    RunTool(@"/sbin/umount", @[mp]);
    if (IsMounted(mp)) RunTool(@"/usr/sbin/diskutil", @[@"unmount", @"force", mp]);
    rmdir(mp.fileSystemRepresentation);
}

// emu3nfs --gate says "B" before it writes and "E" afterwards; hold the sampler link in between.
static void GateLoop(NSTask *task, int rfd, int wfd) {
    @autoreleasepool {
        EMU3LinkEngine *held = nil;
        BOOL eof = NO;
        while (!eof) {
            NSString *l = ReadLine(rfd, &eof, 5);
            if (!l) continue;
            if ([l isEqualToString:@"B"]) {
                EMU3LinkEngine *e; @synchronized (NSObject.class) { e = gEngine; }
                BOOL ok = e ? [e acquireForEditWithIdle:2.0 timeout:4.0] : YES;
                if (ok && e) held = e;
                SendStr(wfd, ok ? @"OK\n" : @"NO\n");
            } else if ([l isEqualToString:@"E"] && held) {
                [held releaseEdit]; held = nil;
            }
        }
        if (held) [held releaseEdit];
    }
}

static void SyncMounts(void) {
    NSString *helper = VolumeHelper();
    NSMutableDictionary<NSString *, NSString *> *want = [NSMutableDictionary dictionary];
    if (helper) {
        NSString *w = [NSString stringWithContentsOfFile:[Base() stringByAppendingPathComponent:@"watch.txt"] encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray *dirs = [NSMutableArray array];
        for (NSString *line in [w componentsSeparatedByString:@"\n"]) {
            NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length) [dirs addObject:t.stringByExpandingTildeInPath];
        }
        if (!dirs.count) [dirs addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"EMU3 Images"]];
        for (NSString *d in dirs) {
            NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:d];
            for (NSString *rel in en) {
                if (en.level > 2) { [en skipDescendants]; continue; }
                NSString *ext = rel.pathExtension.lowercaseString;
                if ([ext isEqualToString:@"hda"] || [ext isEqualToString:@"iso"])
                    want[[[NSHomeDirectory() stringByAppendingPathComponent:@"EMU3 Disks"] stringByAppendingPathComponent:rel.lastPathComponent.stringByDeletingPathExtension]] = [d stringByAppendingPathComponent:rel];
            }
        }
    }
    NSString *served = gPath ? [gPath stringByResolvingSymlinksInPath] : nil;
    for (NSString *mp in want) {
        NSString *img = want[mp];
        BOOL gated = served && [[img stringByResolvingSymlinksInPath] isEqualToString:served];
        MountEntry *e = gMounts[mp];
        if (e && e.task.isRunning && !IsMounted(mp) && CFAbsoluteTimeGetCurrent() - e.started < 15) continue;   // still mounting
        if (e && e.task.isRunning && IsMounted(mp)) {
            if (e.gated == gated) continue;
            Unmount(mp); [e.task terminate]; [gMounts removeObjectForKey:mp];   // served-ness changed: remount with / without the gate
        } else if (!e && IsMounted(mp)) continue;                                   // mounted by someone else (the app)
        [gMounts removeObjectForKey:mp];
        [NSFileManager.defaultManager createDirectoryAtPath:mp withIntermediateDirectories:YES attributes:nil error:nil];
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = helper;
        t.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSPipe *out = nil, *in = nil;
        if (gated) {
            out = [NSPipe pipe]; in = [NSPipe pipe];
            t.arguments = @[img, mp, @"--gate"];
            t.standardOutput = out; t.standardInput = in;
        } else {
            t.arguments = @[img, mp];
            t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        }
        NSError *err = nil;
        if (![t launchAndReturnError:&err]) { NSLog(@"cannot mount %@: %@", img, err.localizedDescription); continue; }
        if (gated) {
            int rfd = out.fileHandleForReading.fileDescriptor, wfd = in.fileHandleForWriting.fileDescriptor;
            NSThread *th = [[NSThread alloc] initWithBlock:^{ GateLoop(t, rfd, wfd); (void)out; (void)in; }];
            [th start];
        }
        MountEntry *me = [[MountEntry alloc] init]; me.task = t; me.gated = gated; me.started = CFAbsoluteTimeGetCurrent();
        gMounts[mp] = me;
        NSLog(@"mounting %@ at %@%@", img.lastPathComponent, mp, gated ? @" (guarded, the sampler is using it)" : @"");
    }
    for (NSString *mp in [gMounts.allKeys copy]) {
        if (!want[mp]) { Unmount(mp); [gMounts[mp].task terminate]; [gMounts removeObjectForKey:mp]; }
        else if (!gMounts[mp].task.isRunning) [gMounts removeObjectForKey:mp];
    }
}

static void UnmountAll(void) {
    dispatch_sync(gScanQueue, ^{
        for (NSString *mp in [gMounts.allKeys copy]) { Unmount(mp); [gMounts[mp].task terminate]; }
        [gMounts removeAllObjects];
    });
}

int main(int argc, const char *argv[]) {
    signal(SIGPIPE, SIG_IGN);   // a client that disconnects must not kill the helper
    @autoreleasepool {
        [NSFileManager.defaultManager createDirectoryAtPath:Base() withIntermediateDirectories:YES attributes:nil error:nil];
        StartSocket();
        gMounts = [NSMutableDictionary dictionary];
        gScanQueue = dispatch_queue_create("emu3linkd.mounts", DISPATCH_QUEUE_SERIAL);
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{ UnmountAll(); exit(0); });
        dispatch_resume(term);
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) { dispatch_async(gScanQueue, ^{ SyncMounts(); }); }];
        dispatch_async(gScanQueue, ^{ SyncMounts(); });
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { Poll(); }];
        Poll();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
