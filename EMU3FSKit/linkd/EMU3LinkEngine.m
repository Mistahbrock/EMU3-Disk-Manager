#import "EMU3LinkEngine.h"
#import <glob.h>
#import <termios.h>
#import <sys/select.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <pthread.h>

#define BLK 512
#define MAXB 256                         // blocks per request the server accepts
#define RXCAP (12 + MAXB * BLK + 64)
#define TXCAP (6 + MAXB * BLK)

static inline uint32_t LE32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static inline uint16_t LE16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

// The board shows two serial ports with the same name stem (…561 = log console, …563 = block link).
// The block link is the one with the higher interface number.
static NSString *FindLinkPort(void) {
    NSString *forced = [NSUserDefaults.standardUserDefaults stringForKey:@"SamplerLinkPort"];
    if (forced.length && [NSFileManager.defaultManager fileExistsAtPath:forced]) return forced;
    glob_t g;
    if (glob("/dev/cu.usbmodem*", 0, NULL, &g) != 0) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (size_t i = 0; i < g.gl_pathc; i++) [names addObject:@(g.gl_pathv[i])];
    globfree(&g);
    [names sortUsingSelector:@selector(compare:)];
    NSString *best = nil;
    for (NSString *n in names) {
        NSString *stem = [n substringToIndex:n.length - 1];
        NSUInteger same = 0;
        for (NSString *m in names) if ([m hasPrefix:stem] && m.length == n.length) same++;
        if (same >= 2) best = n;   // sorted ascending: the last one of a group wins
    }
    return best;
}

static int OpenPort(NSString *path) {
    // Stay non-blocking: a blocking open()/write() of a usbmodem port can hang forever on macOS.
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return -1;
    struct termios t;
    if (tcgetattr(fd, &t) == 0) {
        t.c_iflag = 0; t.c_oflag = 0; t.c_cflag = CS8 | CREAD | CLOCAL; t.c_lflag = 0;
        tcsetattr(fd, TCSANOW, &t);
    }
    return fd;
}

static BOOL WriteAll(int fd, const uint8_t *p, size_t len, volatile BOOL *stopFlag) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 10.0;
    while (len > 0) {
        if (*stopFlag) return NO;
        fd_set ws; FD_ZERO(&ws); FD_SET(fd, &ws);
        struct timeval tv = { 0, 200000 };
        int r = select(fd + 1, NULL, &ws, NULL, &tv);
        if (r < 0 && errno != EINTR) return NO;
        if (r > 0) {
            ssize_t n = write(fd, p, len);
            if (n > 0) { p += n; len -= (size_t)n; }
            else if (n < 0 && errno != EAGAIN && errno != EINTR) return NO;
        }
        if (CFAbsoluteTimeGetCurrent() > deadline) return NO;
    }
    return YES;
}

@interface EMU3LinkEngine () {
    int _img;
    NSThread *_thread;
    volatile BOOL _stop;
    pthread_mutex_t _lock;            // held by the server thread while it handles one request
    volatile CFAbsoluteTime _lastRequest;
    volatile uint16_t _mediaChanges;  // bumped after every edit made here: the board turns it into a UNIT ATTENTION
}
@property (nonatomic, readwrite) EMU3LinkEngineState state;
@property (nonatomic, readwrite, copy) NSString *portPath;
@property (nonatomic, readwrite) uint64_t readRequests, writeRequests, bytesRead, bytesWritten;
@property (nonatomic, readwrite) uint32_t lastLBA;
@property (nonatomic, readwrite) NSTimeInterval lastActivity;
@property (nonatomic, readwrite) uint64_t imageSize;
@property (nonatomic, readwrite) BOOL running;
@end

@implementation EMU3LinkEngine

- (instancetype)initWithImageURL:(NSURL *)url writable:(BOOL)writable {
    if ((self = [super init])) {
        _imageURL = url;
        _writable = writable;
        _img = -1;
        _scsiID = 7;
        _state = EMU3LinkEngineStateStopped;
        pthread_mutex_init(&_lock, NULL);
    }
    return self;
}

- (void)dealloc { [self stop]; pthread_mutex_destroy(&_lock); }

- (BOOL)acquireForEditWithIdle:(NSTimeInterval)idle timeout:(NSTimeInterval)timeout {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    for (;;) {
        pthread_mutex_lock(&_lock);
        if (!_running || CFAbsoluteTimeGetCurrent() - _lastRequest >= idle) return YES;   // keep the lock
        pthread_mutex_unlock(&_lock);
        if (CFAbsoluteTimeGetCurrent() > deadline) return NO;
        usleep(100000);
    }
}

- (void)releaseEdit {
    // An edit made on the Mac is over: let the sampler know (touch ~/Library/Application Support/EMU3/no-notify to disable).
    NSString *off = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/EMU3/no-notify"];
    if (![NSFileManager.defaultManager fileExistsAtPath:off]) _mediaChanges++;
    pthread_mutex_unlock(&_lock);
}

- (BOOL)startWithError:(NSError **)error {
    if (_running) return YES;
    _img = open(_imageURL.fileSystemRepresentation, _writable ? O_RDWR : O_RDONLY);
    if (_img < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"Cannot open %@: %s", _imageURL.lastPathComponent, strerror(errno)]}];
        return NO;
    }
    struct stat st; fstat(_img, &st);
    _imageSize = (uint64_t)st.st_size;
    _stop = NO;
    _running = YES;
    _readRequests = _writeRequests = _bytesRead = _bytesWritten = 0;
    _lastActivity = 0; _portPath = nil;
    _state = EMU3LinkEngineStateWaitingForBoard;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(_run) object:nil];
    _thread.name = @"EMU3LinkEngine";
    _thread.qualityOfService = NSQualityOfServiceUserInitiated;
    [_thread start];
    return YES;
}

- (void)stop {
    if (!_running) return;
    _stop = YES;
    _running = NO;
    _state = EMU3LinkEngineStateStopped;
    _onChange = nil; _onLog = nil; _onImageChangedBySampler = nil;
    // The thread closes the image descriptor when it leaves its loop.
}

#pragma mark - server thread

- (void)_log:(NSString *)line {
    void (^cb)(NSString *) = self.onLog;
    if (!cb || _stop) return;
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self->_stop && self.onLog) self.onLog(line); });
}

- (void)_publishState:(EMU3LinkEngineState)st port:(NSString *)port
                reads:(uint64_t)r writes:(uint64_t)w bytesR:(uint64_t)br bytesW:(uint64_t)bw
                  lba:(uint32_t)lba activity:(NSTimeInterval)act {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_stop) return;
        self.state = st; self.portPath = port;
        self.readRequests = r; self.writeRequests = w; self.bytesRead = br; self.bytesWritten = bw;
        self.lastLBA = lba; self.lastActivity = act;
        if (self.onChange) self.onChange(self);
    });
}

- (void)_run {
    @autoreleasepool {
        uint8_t *rx = malloc(RXCAP), *tx = malloc(TXCAP);
        size_t rxlen = 0;
        int fd = -1;
        NSString *port = nil;
        EMU3LinkEngineState st = EMU3LinkEngineStateWaitingForBoard;
        uint64_t reads = 0, writes = 0, br = 0, bw = 0;
        uint32_t lastLBA = 0; NSTimeInterval activity = 0;
        CFAbsoluteTime lastPublish = 0, lastWrite = 0;
        BOOL dirtyWrites = NO;
        uint64_t nblocks = _imageSize / BLK;

        [self _log:[NSString stringWithFormat:@"Serving %@ (%llu MB, %@)", _imageURL.lastPathComponent,
                    _imageSize / (1024 * 1024), _writable ? @"read-write" : @"read-only"]];
        [self _publishState:st port:nil reads:0 writes:0 bytesR:0 bytesW:0 lba:0 activity:0];

        while (!_stop) {
            if (fd < 0) {
                NSString *p = FindLinkPort();
                if (p) fd = OpenPort(p);
                if (fd < 0) {
                    if (st != EMU3LinkEngineStateWaitingForBoard) {
                        st = EMU3LinkEngineStateWaitingForBoard;
                        [self _log:@"Board not found. Waiting for the BlueSCSI USB link…"];
                        [self _publishState:st port:nil reads:reads writes:writes bytesR:br bytesW:bw lba:lastLBA activity:activity];
                    }
                    usleep(400000);
                    continue;
                }
                port = p; rxlen = 0;
                st = EMU3LinkEngineStateBoardConnected;
                [self _log:[NSString stringWithFormat:@"Board connected on %@", p.lastPathComponent]];
                [self _publishState:st port:port reads:reads writes:writes bytesR:br bytesW:bw lba:lastLBA activity:activity];
            }

            fd_set rs; FD_ZERO(&rs); FD_SET(fd, &rs);
            struct timeval tv = { 0, 200000 };
            int sr = select(fd + 1, &rs, NULL, NULL, &tv);
            BOOL lost = NO;
            if (sr < 0 && errno != EINTR) lost = YES;
            // A yanked cable can leave the old descriptor open without any read error: treat a vanished device node as lost.
            if (!lost && port && access(port.fileSystemRepresentation, F_OK) != 0) lost = YES;
            if (sr > 0) {
                ssize_t n = read(fd, rx + rxlen, RXCAP - rxlen);
                if (n > 0) rxlen += (size_t)n;
                else if (n == 0) lost = YES;
                else if (errno != EAGAIN && errno != EINTR) lost = YES;
            }

            // parse complete frames
            while (!lost && rxlen >= 12) {
                if (rx[0] != 0xB5 || rx[1] != 0xC5) { memmove(rx, rx + 1, --rxlen); continue; }
                uint8_t cmd = rx[2], tag = rx[3];
                uint32_t lba = LE32(rx + 4);
                uint32_t count = LE16(rx + 8);
                if (count > MAXB) { memmove(rx, rx + 2, rxlen -= 2); continue; }
                size_t need = 12 + (cmd == 2 ? (size_t)count * BLK : 0);
                if (rxlen < need) break;

                pthread_mutex_lock(&_lock);
                if (cmd == 1 || cmd == 2) _lastRequest = CFAbsoluteTimeGetCurrent();   // polls (PING, CHANGES) do not count as sampler activity
                uint8_t status = 0;
                size_t txlen = 6;
                if (cmd == 1) {
                    uint8_t *data = tx + 6;
                    size_t want = (size_t)count * BLK;
                    memset(data, 0, want);
                    uint64_t off = (uint64_t)lba * BLK;
                    if (off < _imageSize) {
                        size_t got = 0;
                        while (got < want && off + got < _imageSize) {
                            ssize_t r = pread(_img, data + got, want - got, (off_t)(off + got));
                            if (r <= 0) { if (r < 0 && errno == EINTR) continue; status = 1; break; }
                            got += (size_t)r;
                        }
                    }
                    if (status == 0) txlen += want;
                    reads++; br += want;
                } else if (cmd == 2) {
                    uint64_t off = (uint64_t)lba * BLK;
                    size_t want = (size_t)count * BLK;
                    if (!_writable || (uint64_t)lba + count > nblocks) status = 1;
                    else {
                        const uint8_t *src = rx + 12; size_t put = 0;
                        while (put < want) {
                            ssize_t w2 = pwrite(_img, src + put, want - put, (off_t)(off + put));
                            if (w2 <= 0) { if (w2 < 0 && errno == EINTR) continue; status = 1; break; }
                            put += (size_t)w2;
                        }
                    }
                    if (status == 0) { writes++; bw += want; dirtyWrites = YES; lastWrite = CFAbsoluteTimeGetCurrent(); }
                    else [self _log:[NSString stringWithFormat:@"Write refused (LBA %u, %u blocks)", lba, count]];
                } else if (cmd == 5) {
                    // Card-less board asks which drive to present: "CFG1", SCSI id, size in MB.
                    uint8_t sid = MIN(self.scsiID, 7);
                    uint32_t mb = (uint32_t)((_imageSize + (1u << 20) - 1) >> 20);
                    uint8_t *data = tx + 6;
                    memset(data, 0, BLK);
                    memcpy(data, "CFG1", 4); data[4] = sid;
                    data[8] = (uint8_t)mb; data[9] = (uint8_t)(mb >> 8); data[10] = (uint8_t)(mb >> 16); data[11] = (uint8_t)(mb >> 24);
                    txlen += BLK; count = 1;
                    [self _log:[NSString stringWithFormat:@"The board asked for its configuration: SCSI ID %u, %u MB", sid, mb]];
                } else if (cmd == 6) {
                    count = _mediaChanges;          // CHANGES: the counter travels in the response's count field
                } else if (cmd != 4) {
                    status = 2;
                }
                tx[0] = 0xC5; tx[1] = 0xB5; tx[2] = status; tx[3] = tag;
                tx[4] = (uint8_t)count; tx[5] = (uint8_t)(count >> 8);
                BOOL sent = WriteAll(fd, tx, txlen, &_stop);
                if (cmd == 1 || cmd == 2) _lastRequest = CFAbsoluteTimeGetCurrent();
                pthread_mutex_unlock(&_lock);
                if (!sent) { lost = YES; break; }
                if (cmd == 1 || cmd == 2) lastLBA = lba;
                if (cmd == 1 || cmd == 2) activity = CFAbsoluteTimeGetCurrent();
                if (st != EMU3LinkEngineStateActive && (cmd == 1 || cmd == 2)) {
                    st = EMU3LinkEngineStateActive;
                    [self _log:@"The board is reading blocks"];
                }
                memmove(rx, rx + need, rxlen - need);
                rxlen -= need;
            }

            if (lost) {
                close(fd); fd = -1; port = nil; rxlen = 0;
                st = EMU3LinkEngineStateWaitingForBoard;
                [self _log:@"Link to the board lost. Waiting for it to come back…"];
                [self _publishState:st port:nil reads:reads writes:writes bytesR:br bytesW:bw lba:lastLBA activity:activity];
                continue;
            }

            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (dirtyWrites && now - lastWrite > 1.0) {
                fsync(_img);
                dirtyWrites = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!self->_stop && self.onImageChangedBySampler) self.onImageChangedBySampler(self);
                });
            }
            if (now - lastPublish > 0.25) {
                lastPublish = now;
                [self _publishState:st port:port reads:reads writes:writes bytesR:br bytesW:bw lba:lastLBA activity:activity];
            }
        }
        if (fd >= 0) close(fd);
        if (_img >= 0) { fsync(_img); close(_img); _img = -1; }
        free(rx); free(tx);
    }
}

@end
