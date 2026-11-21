#import "EMU3BlockServer.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *BaseDir(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/EMU3"]; }
static NSString *ServeFile(void) { return [BaseDir() stringByAppendingPathComponent:@"serve.txt"]; }
static NSString *IDFile(void) { return [BaseDir() stringByAppendingPathComponent:@"scsiid.txt"]; }

static int ConnectHelper(void) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return -1;
    int one = 1; setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    strlcpy(a.sun_path, [BaseDir() stringByAppendingPathComponent:@"link.sock"].fileSystemRepresentation, sizeof a.sun_path);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return -1; }
    return s;
}

static NSString *ReadLine(int fd, double timeout, BOOL *eof) {
    NSMutableData *d = [NSMutableData data];
    for (;;) {
        fd_set rs; FD_ZERO(&rs); FD_SET(fd, &rs);
        struct timeval tv = { (long)timeout, (int)((timeout - (long)timeout) * 1e6) };
        if (select(fd + 1, &rs, NULL, NULL, &tv) <= 0) { return nil; }
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

@interface EMU3BlockServer () {
    volatile BOOL _stop;
    uint64_t _seenImgChanges; BOOL _haveImgBaseline;
    NSInteger _prevState; BOOL _haveBaseline;      // for the activity log
    uint64_t _pR, _pW, _pBR, _pBW;                  // counters at the previous status line
    BOOL _burst; uint64_t _bR0, _bW0, _bBR0, _bBW0; // counters when the current burst of sampler activity began
    CFAbsoluteTime _lastCountChange;
}
@property (nonatomic, readwrite) EMU3LinkState state;
@property (nonatomic, readwrite, copy) NSString *portPath;
@property (nonatomic, readwrite) uint64_t readRequests, writeRequests, bytesRead, bytesWritten;
@property (nonatomic, readwrite) uint32_t lastLBA;
@property (nonatomic, readwrite) NSTimeInterval lastActivity;
@property (nonatomic, readwrite) uint64_t imageSize;
@property (nonatomic, readwrite) BOOL running;
@end

@implementation EMU3BlockServer

+ (NSInteger)boardSCSIID {
    NSString *t = [NSString stringWithContentsOfFile:IDFile() encoding:NSUTF8StringEncoding error:nil];
    return t.length ? MAX(0, MIN(7, t.integerValue)) : 7;
}

+ (void)setBoardSCSIID:(NSInteger)sid {
    [NSFileManager.defaultManager createDirectoryAtPath:BaseDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSString stringWithFormat:@"%ld\n", (long)MAX(0, MIN(7, sid))] writeToFile:IDFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (instancetype)attachToServedImage {
    NSString *t = [NSString stringWithContentsOfFile:ServeFile() encoding:NSUTF8StringEncoding error:nil];
    NSArray *l = [t componentsSeparatedByString:@"\n"];
    NSString *p = l.count ? [l[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
    if (!p.length || ![NSFileManager.defaultManager fileExistsAtPath:p]) return nil;
    BOOL rw = !(l.count > 1 && [[l[1] lowercaseString] hasPrefix:@"ro"]);
    EMU3BlockServer *s = [[EMU3BlockServer alloc] initWithImageURL:[NSURL fileURLWithPath:p] writable:rw];
    [s _beginWatching];
    return s;
}

- (instancetype)initWithImageURL:(NSURL *)url writable:(BOOL)writable {
    if ((self = [super init])) {
        _imageURL = url; _writable = writable; _state = EMU3LinkStateStopped;
        struct stat st; if (stat(url.fileSystemRepresentation, &st) == 0) _imageSize = (uint64_t)st.st_size;
    }
    return self;
}

- (void)dealloc { _stop = YES; }

- (BOOL)startWithError:(NSError **)error {
    if (_running) return YES;
    struct stat st;
    if (stat(_imageURL.fileSystemRepresentation, &st) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"Cannot open %@: %s", _imageURL.lastPathComponent, strerror(errno)]}];
        return NO;
    }
    _imageSize = (uint64_t)st.st_size;
    [NSFileManager.defaultManager createDirectoryAtPath:BaseDir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *txt = [NSString stringWithFormat:@"%@\n%@\n", _imageURL.path, _writable ? @"rw" : @"ro"];
    NSError *e = nil;
    if (![txt writeToFile:ServeFile() atomically:YES encoding:NSUTF8StringEncoding error:&e]) { if (error) *error = e; return NO; }
    [self _beginWatching];
    return YES;
}

- (void)stop {
    _stop = YES; _running = NO; _state = EMU3LinkStateStopped;
    _onChange = nil; _onLog = nil; _onImageChangedBySampler = nil;
}

- (void)stopServing {
    [self stop];
    [NSFileManager.defaultManager removeItemAtPath:ServeFile() error:nil];
}

#pragma mark - edit guard (through the helper)

- (BOOL)acquireForEditWithIdle:(NSTimeInterval)idle timeout:(NSTimeInterval)timeout {
    if (!_running) return YES;
    int fd = ConnectHelper();
    if (fd < 0) return YES;                       // helper not running: nobody is served
    SendStr(fd, [NSString stringWithFormat:@"ACQ %.2f %.2f\n", idle, timeout]);
    BOOL eof = NO;
    NSString *r = ReadLine(fd, timeout + 3.0, &eof);
    if ([r isEqualToString:@"OK"]) {
        NSThread.currentThread.threadDictionary[@"emu3.gate.fd"] = @(fd);
        return YES;
    }
    close(fd);
    return r == nil && eof ? YES : NO;
}

- (void)releaseEdit {
    NSNumber *n = NSThread.currentThread.threadDictionary[@"emu3.gate.fd"];
    if (!n) return;
    [NSThread.currentThread.threadDictionary removeObjectForKey:@"emu3.gate.fd"];
    SendStr(n.intValue, @"REL\n");
    close(n.intValue);
}

#pragma mark - status from the helper

- (void)_beginWatching {
    if (_running) return;
    _stop = NO; _running = YES; _state = EMU3LinkStateWaitingForBoard; _haveImgBaseline = NO;
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(_watch) object:nil];
    t.name = @"EMU3BlockServer status";
    [t start];
}

- (void)_log:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self->_stop && self.onLog) self.onLog(line); });
}

static NSString *SizeText(uint64_t b) {
    return b >= (1ULL << 20) ? [NSString stringWithFormat:@"%.1f MB", b / 1048576.0] : [NSString stringWithFormat:@"%.1f KB", b / 1024.0];
}

// Main thread: turn status changes into readable log lines (board connected, sampler reading/writing, idle).
- (void)_logTransitionsState:(NSInteger)st reads:(uint64_t)r writes:(uint64_t)w bytesR:(uint64_t)br bytesW:(uint64_t)bw {
    if (!_haveBaseline) {
        _haveBaseline = YES; _prevState = -1;
        [self _log:[NSString stringWithFormat:@"Serving %@ (%@).", _imageURL.lastPathComponent, _writable ? @"read-write" : @"read-only"]];
    }
    if (st != _prevState) {
        switch (st) {
            case EMU3LinkStateWaitingForBoard: [self _log:@"Waiting for the BlueSCSI board (USB)."]; break;
            case EMU3LinkStateBoardConnected:  [self _log:@"Board connected over USB; waiting for the sampler to ask for blocks."]; break;
            case EMU3LinkStateActive:          [self _log:@"Sampler is talking to the disk."]; break;
            default: break;
        }
        _prevState = st;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL grew = r > _pR || w > _pW;
    if (r < _pR || w < _pW) { _burst = NO; }   // counters restarted (new serve session)
    if (grew) {
        _lastCountChange = now;
        if (!_burst) {
            _burst = YES; _bR0 = _pR; _bW0 = _pW; _bBR0 = _pBR; _bBW0 = _pBW;
            [self _log:(w > _pW && r == _pR) ? @"Sampler is writing to the disk…" : @"Sampler is reading from the disk…"];
        }
    } else if (_burst && now - _lastCountChange > 5.0) {
        _burst = NO;
        uint64_t dr = r - _bR0, dw = w - _bW0;
        [self _log:[NSString stringWithFormat:@"Sampler idle. Last activity: read %@ (%llu requests), wrote %@ (%llu requests).",
                    SizeText(br - _bBR0), dr, SizeText(bw - _bBW0), dw]];
    }
    _pR = r; _pW = w; _pBR = br; _pBW = bw;
}

- (void)_watch {
    @autoreleasepool {
        BOOL warned = NO;
        while (!_stop) {
            int fd = ConnectHelper();
            if (fd < 0) {
                if (!warned) { warned = YES; [self _log:@"The background helper (emu3linkd) is not running. Install the EMU3 Disk Manager package, or run it from the login agent."]; }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->_stop) return;
                    self.state = EMU3LinkStateWaitingForBoard; self.portPath = nil;
                    if (self.onChange) self.onChange(self);
                });
                sleep(2);
                continue;
            }
            warned = NO;
            SendStr(fd, @"STATUS\n");
            BOOL eof = NO;
            while (!_stop && !eof) {
                NSString *l = ReadLine(fd, 3.0, &eof);
                if (!l) { if (eof) break; continue; }
                NSArray *p = [l componentsSeparatedByString:@" "];
                if (p.count < 13 || ![p[0] isEqualToString:@"S"]) continue;
                NSInteger st = [p[1] integerValue];
                NSString *port = [p[2] isEqualToString:@"-"] ? nil : p[2];
                uint64_t imgChanges = strtoull([p[11] UTF8String], NULL, 10);
                NSString *path = [[p subarrayWithRange:NSMakeRange(12, p.count - 12)] componentsJoinedByString:@" "];
                BOOL mine = [path isEqualToString:self->_imageURL.path];
                BOOL changed = _haveImgBaseline && imgChanges != _seenImgChanges;
                _seenImgChanges = imgChanges; _haveImgBaseline = YES;
                uint64_t r = strtoull([p[3] UTF8String], NULL, 10), w = strtoull([p[4] UTF8String], NULL, 10);
                uint64_t br = strtoull([p[5] UTF8String], NULL, 10), bw = strtoull([p[6] UTF8String], NULL, 10);
                uint32_t lba = (uint32_t)strtoul([p[7] UTF8String], NULL, 10);
                NSTimeInterval act = [p[8] doubleValue];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->_stop) return;
                    [self _logTransitionsState:(mine ? st : EMU3LinkStateWaitingForBoard) reads:r writes:w bytesR:br bytesW:bw];
                    self.state = mine ? (EMU3LinkState)st : EMU3LinkStateWaitingForBoard;
                    self.portPath = mine ? port : nil;
                    self.readRequests = r; self.writeRequests = w; self.bytesRead = br; self.bytesWritten = bw;
                    self.lastLBA = lba; self.lastActivity = act;
                    if (self.onChange) self.onChange(self);
                    if (changed && mine && self.onImageChangedBySampler) self.onImageChangedBySampler(self);
                });
            }
            close(fd);
        }
    }
}

@end
