// emu3nfs: mounts an E-mu EOS disk image (.hda/.iso) as a folder tree, without FUSE: it runs a small NFSv3 server on
// 127.0.0.1 and lets macOS'"'"'s built-in NFS client mount it (no root, no kernel extension).
// usage: emu3nfs IMAGE MOUNTPOINT [--gate]
// The file operations (e_*) are the ones emu3fuse used; the NFS layer below calls them with paths.
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <sys/statvfs.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <fcntl.h>
#include <errno.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/mount.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
struct fuse_file_info { int flags; uint64_t fh; };   // the few fields the e_* operations use
typedef int (*fuse_fill_dir_t)(void *buf, const char *name, const struct stat *st, off_t off);
#import "EMU3Filesystem.h"
#import "EMU3Directory.h"
#import "EMU3File.h"

static EMU3Filesystem *gFS;
static NSMutableDictionary<NSString *, id> *gPaths;       // "/Folder/Bank" -> EMU3File or EMU3Directory
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gChildren; // dir path -> child names
static NSString *gCachePath; static NSData *gCacheData;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static time_t gMTime;
static BOOL gReadOnly;
static void Build(void);
static uint64_t gHash; static CFAbsoluteTime gLastCheck;
static const char *gImagePath;
static uint64_t MetaHash(void) {   // hash of the header, allocation table and directories (everything before the data area)
    int fd = open(gImagePath, O_RDONLY); if (fd < 0) return 0;
    size_t cap = 4u << 20; uint8_t *b = malloc(cap); ssize_t n = pread(fd, b, cap, 0); close(fd);
    uint64_t h = 1469598103934665603ULL;
    for (ssize_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    free(b); return h;
}

// Files being written are staged in a temp file and imported into the image when the last handle closes.
@interface Stage : NSObject
@property NSString *tmp; @property int fd; @property BOOL dirty, ghost, replace; @property int refs;
@end
@implementation Stage @end
static NSMutableDictionary<NSString *, Stage *> *gStage;
static NSString *gTmpDir;
static EMU3Directory *DirForPath(NSString *p) { id o = gPaths[p]; return [o isKindOfClass:[EMU3Directory class]] ? o : nil; }
static NSString *ParentOf(NSString *p) { NSString *d = [p stringByDeletingLastPathComponent]; return d.length ? d : @"/"; }
static BOOL IsGhostName(NSString *p) { NSString *n = p.lastPathComponent; return [n hasPrefix:@"."]; }
static NSString *BankNameFrom(NSString *n) {
    NSString *e = n.pathExtension.lowercaseString;
    if ([e isEqualToString:@"e4b"] || [e isEqualToString:@"e3b"] || [e isEqualToString:@"bnk"]) n = n.stringByDeletingPathExtension;
    return n.length > 15 ? [n substringToIndex:15] : n;
}
static void Refresh(void) { NSError *e = nil; [gFS synchronizeToDisk:nil]; [gFS reload:&e]; Build(); gCachePath = nil; gCacheData = nil; gHash = MetaHash(); gLastCheck = CFAbsoluteTimeGetCurrent(); }
// Another program (the app, the sampler) changed the image: re-read it. Call with gLock held.
static void MaybeReload(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastCheck < 1.0) return;
    gLastCheck = now;
    if (MetaHash() != gHash) { NSError *e = nil; [gFS reload:&e]; Build(); gCachePath = nil; gCacheData = nil; gHash = MetaHash(); }
}


static NSString *Safe(NSString *n) {
    NSString *s = [[n stringByReplacingOccurrencesOfString:@"/" withString:@":"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return s.length ? s : @"_";
}
static NSString *Unique(NSString *n, NSMutableSet *used) {
    NSString *r = n; int k = 2;
    while ([used containsObject:r]) r = [NSString stringWithFormat:@"%@ %d", n, k++];
    [used addObject:r]; return r;
}
static void Build(void) {
    gPaths = [NSMutableDictionary dictionary]; gChildren = [NSMutableDictionary dictionary];
    gPaths[@"/"] = gFS.rootDirectory;
    NSMutableArray *rootKids = [NSMutableArray array]; NSMutableSet *rootUsed = [NSMutableSet set];
    for (EMU3Directory *d in gFS.rootDirectory.subdirectories) {
        NSString *dn = Unique(Safe(d.name), rootUsed); [rootKids addObject:dn];
        NSString *dp = [@"/" stringByAppendingString:dn]; gPaths[dp] = d;
        NSMutableArray *kids = [NSMutableArray array]; NSMutableSet *used = [NSMutableSet set];
        for (EMU3File *f in d.files) { if (f.isDeleted) continue;
            NSString *fn = Unique(Safe(f.name), used); [kids addObject:fn];
            gPaths[[dp stringByAppendingFormat:@"/%@", fn]] = f; }
        gChildren[dp] = kids;
    }
    for (EMU3File *f in gFS.rootDirectory.files) { if (f.isDeleted) continue;
        NSString *fn = Unique(Safe(f.name), rootUsed); [rootKids addObject:fn];
        gPaths[[@"/" stringByAppendingString:fn]] = f; }
    gChildren[@"/"] = rootKids;
}


// A bank copied in as "Foo.e4b" is stored as "Foo": let programs keep using the name they wrote.
static NSString *Resolve(const char *cpath) {
    NSString *p = [NSString stringWithUTF8String:cpath];
    pthread_mutex_lock(&gLock);
    BOOL known = gStage[p] || gPaths[p];
    NSString *alt = nil;
    if (!known) { NSString *e = p.pathExtension.lowercaseString;
        if ([e isEqualToString:@"e4b"] || [e isEqualToString:@"e3b"] || [e isEqualToString:@"bnk"]) {
            NSString *c = p.stringByDeletingPathExtension; if (c.length > 15 + ParentOf(p).length + 1) c = [c substringToIndex:ParentOf(p).length + 1 + 15];
            if (gPaths[c]) alt = c; } }
    pthread_mutex_unlock(&gLock);
    return alt ?: p;
}
static int e_getattr(const char *path, struct stat *st) {
    memset(st, 0, sizeof *st);
    @autoreleasepool {
        NSString *sp = Resolve(path);
        pthread_mutex_lock(&gLock); MaybeReload();
        Stage *stg = gStage[sp];
        id o = gPaths[sp];
        if (stg) {
            struct stat ts; fstat(stg.fd, &ts);
            pthread_mutex_unlock(&gLock);
            st->st_uid = getuid(); st->st_gid = getgid(); st->st_mode = S_IFREG | 0644; st->st_nlink = 1;
            st->st_size = ts.st_size; st->st_blocks = (ts.st_size + 511) / 512;
            st->st_mtime = st->st_atime = st->st_ctime = gMTime; return 0;
        }
        pthread_mutex_unlock(&gLock);
        if (!o) return -ENOENT;
        st->st_uid = getuid(); st->st_gid = getgid();
        st->st_mtime = st->st_atime = st->st_ctime = gMTime;
        if ([o isKindOfClass:[EMU3File class]]) {
            st->st_mode = S_IFREG | (gReadOnly ? 0444 : 0644); st->st_nlink = 1;
            st->st_size = ((EMU3File *)o).fileSize; st->st_blocks = (st->st_size + 511) / 512;
        } else { st->st_mode = S_IFDIR | (gReadOnly ? 0555 : 0755); st->st_nlink = 2; }
    }
    return 0;
}
static int e_readdir(const char *path, void *buf, fuse_fill_dir_t fill, off_t off, struct fuse_file_info *fi) {
    @autoreleasepool {
        pthread_mutex_lock(&gLock); MaybeReload();
        NSArray *kids = gChildren[[NSString stringWithUTF8String:path]];
        NSMutableArray *copy = [kids mutableCopy];
        NSString *dpath = [NSString stringWithUTF8String:path];
        for (NSString *sp in gStage) if ([ParentOf(sp) isEqualToString:dpath] && ![copy containsObject:sp.lastPathComponent]) [copy addObject:sp.lastPathComponent];
        pthread_mutex_unlock(&gLock);
        if (!kids) copy = nil;
        if (!copy) return -ENOENT;
        fill(buf, ".", NULL, 0); fill(buf, "..", NULL, 0);
        for (NSString *n in copy) fill(buf, n.UTF8String, NULL, 0);
    }
    return 0;
}
static int e_open(const char *path, struct fuse_file_info *fi) {
    @autoreleasepool {
        NSString *p = Resolve(path);
        pthread_mutex_lock(&gLock); MaybeReload();
        id o = gPaths[p]; Stage *stg = gStage[p];
        if (stg) { stg.refs++; pthread_mutex_unlock(&gLock); return 0; }
        if (!o) { pthread_mutex_unlock(&gLock); return -ENOENT; }
        if (![o isKindOfClass:[EMU3File class]]) { pthread_mutex_unlock(&gLock); return -EISDIR; }
        if ((fi->flags & O_ACCMODE) != O_RDONLY) {
            if (gReadOnly) { pthread_mutex_unlock(&gLock); return -EROFS; }
            stg = [Stage new];
            stg.tmp = [gTmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"s%u_%@.e4b", arc4random(), p.lastPathComponent]];
            stg.fd = open(stg.tmp.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0600);
            stg.replace = YES; stg.refs = 1; stg.dirty = YES;
            if (!(fi->flags & O_TRUNC)) {
                NSData *d = [gFS dataForFile:o error:nil];
                if (d) write(stg.fd, d.bytes, d.length);
            }
            gStage[p] = stg;
        }
        pthread_mutex_unlock(&gLock);
    }
    return 0;
}
static int e_read(const char *path, char *buf, size_t size, off_t off, struct fuse_file_info *fi) {
    @autoreleasepool {
        NSString *p = Resolve(path);
        pthread_mutex_lock(&gLock);
        Stage *stg = gStage[p];
        if (stg) { int fd = stg.fd; pthread_mutex_unlock(&gLock); ssize_t r = pread(fd, buf, size, off); return r < 0 ? -errno : (int)r; }
        EMU3File *f = gPaths[p];
        if (![f isKindOfClass:[EMU3File class]]) { pthread_mutex_unlock(&gLock); return -ENOENT; }
        if (![gCachePath isEqualToString:p]) {
            NSError *e = nil; NSData *d = [gFS dataForFile:f error:&e];
            if (!d) { pthread_mutex_unlock(&gLock); return -EIO; }
            gCacheData = d; gCachePath = p;
        }
        NSData *d = gCacheData;
        pthread_mutex_unlock(&gLock);
        if ((NSUInteger)off >= d.length) return 0;
        size_t n = MIN(size, d.length - (NSUInteger)off);
        memcpy(buf, (const uint8_t *)d.bytes + off, n);
        return (int)n;
    }
}

static int e_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
    if (gReadOnly) return -EROFS;
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        pthread_mutex_lock(&gLock);
        BOOL ghost = IsGhostName(p);
        EMU3Directory *dir = DirForPath(ParentOf(p));
        if (gPaths[p] && !gStage[p]) { pthread_mutex_unlock(&gLock); return -EEXIST; }
        if (!ghost && (!dir || [ParentOf(p) isEqualToString:@"/"])) { pthread_mutex_unlock(&gLock); return -EACCES; }
        Stage *stg = gStage[p];
        if (!stg) {
            stg = [Stage new];
            stg.tmp = [gTmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"s%u_%@.e4b", arc4random(), p.lastPathComponent]];
            stg.fd = open(stg.tmp.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0600);
            stg.ghost = ghost; gStage[p] = stg;
        }
        stg.refs++;
        pthread_mutex_unlock(&gLock);
    }
    return 0;
}
static int e_write(const char *path, const char *buf, size_t size, off_t off, struct fuse_file_info *fi) {
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        pthread_mutex_lock(&gLock); Stage *stg = gStage[p]; int fd = stg ? stg.fd : -1; if (stg) stg.dirty = YES; pthread_mutex_unlock(&gLock);
        if (fd < 0) return -EBADF;
        ssize_t w = pwrite(fd, buf, size, off);
        return w < 0 ? -errno : (int)w;
    }
}
static int e_truncate(const char *path, off_t size) {
    @autoreleasepool {
        NSString *p = Resolve(path);
        pthread_mutex_lock(&gLock);
        Stage *stg = gStage[p];
        if (stg) { stg.dirty = YES; int r = ftruncate(stg.fd, size); pthread_mutex_unlock(&gLock); return r ? -errno : 0; }
        id o = gPaths[p];
        pthread_mutex_unlock(&gLock);
        if (!o) return -ENOENT;
        return -EPERM;   // resizing a bank in place is not supported; rewrite it instead
    }
}
static int e_ftruncate(const char *path, off_t size, struct fuse_file_info *fi) { return e_truncate(path, size); }
// Called on every close(): the import into the image happens here so errors reach the writing program.
static int e_flush(const char *path, struct fuse_file_info *fi) {
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        pthread_mutex_lock(&gLock);
        Stage *stg = gStage[p];
        if (!stg || stg.ghost || !stg.dirty) { pthread_mutex_unlock(&gLock); return 0; }
        int rc = 0;
        fsync(stg.fd);
        EMU3Directory *dir = DirForPath(ParentOf(p));
        struct stat ts; fstat(stg.fd, &ts);
        if (!dir) rc = -ENOENT;
        else if (ts.st_size == 0) rc = 0;    // empty create (e.g. touch): keep staged until real data arrives
        else {
            NSError *e = nil;
            id old = gPaths[p];
            NSURL *u = [NSURL fileURLWithPath:stg.tmp];
            // name for the import comes from the temp file name: "<bank>.e4b"
            NSString *want = BankNameFrom(p.lastPathComponent);
            NSString *clean = [gTmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.e4b", want]];
            [[NSFileManager defaultManager] removeItemAtPath:clean error:nil];
            [[NSFileManager defaultManager] linkItemAtPath:stg.tmp toPath:clean error:nil];
            BOOL ok = YES;
            if ([old isKindOfClass:[EMU3File class]]) ok = [gFS deleteFile:old inDirectory:dir error:&e];
            ok = ok && [gFS importFileAtURL:[NSURL fileURLWithPath:clean] toDirectory:dir error:&e];
            [[NSFileManager defaultManager] removeItemAtPath:clean error:nil];
            (void)u;
            if (!ok) { fprintf(stderr, "emu3nfs: import failed: %s\n", e.localizedDescription.UTF8String); rc = -ENOSPC; }
            else { stg.dirty = NO; Refresh(); }
        }
        pthread_mutex_unlock(&gLock);
        return rc;
    }
}
static int e_release(const char *path, struct fuse_file_info *fi) {
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        pthread_mutex_lock(&gLock);
        Stage *stg = gStage[p];
        if (stg && --stg.refs <= 0) {
            struct stat ts; fstat(stg.fd, &ts);
            if (!stg.ghost && stg.dirty && ts.st_size > 0) { /* flush failed earlier: drop */ }
            if (!stg.ghost || ts.st_size >= 0) {
                if (!stg.ghost) { close(stg.fd); unlink(stg.tmp.fileSystemRepresentation); [gStage removeObjectForKey:p]; }
                // ghost files (.DS_Store, ._x) stay until unlink so the OS finds what it wrote
            }
        }
        pthread_mutex_unlock(&gLock);
    }
    return 0;
}
static int e_unlink(const char *path) {
    if (gReadOnly) return -EROFS;
    @autoreleasepool {
        NSString *p = Resolve(path);
        pthread_mutex_lock(&gLock);
        Stage *stg = gStage[p];
        if (stg) { close(stg.fd); unlink(stg.tmp.fileSystemRepresentation); [gStage removeObjectForKey:p]; pthread_mutex_unlock(&gLock); return 0; }
        id o = gPaths[p]; EMU3Directory *dir = DirForPath(ParentOf(p));
        int rc = 0;
        if (![o isKindOfClass:[EMU3File class]] || !dir) rc = o ? -EISDIR : -ENOENT;
        else { NSError *e = nil; if ([gFS deleteFile:o inDirectory:dir error:&e]) Refresh(); else rc = -EBUSY; }
        pthread_mutex_unlock(&gLock);
        return rc;
    }
}
static int e_mkdir(const char *path, mode_t mode) {
    if (gReadOnly) return -EROFS;
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        pthread_mutex_lock(&gLock);
        int rc = 0;
        if (gPaths[p]) rc = -EEXIST;
        else if (![ParentOf(p) isEqualToString:@"/"]) rc = -EPERM;       // EOS folders live directly under the root
        else { NSError *e = nil; NSString *n = p.lastPathComponent; if (n.length > 15) n = [n substringToIndex:15];
               if ([gFS createDirectoryNamed:n inDirectory:gFS.rootDirectory error:&e]) Refresh(); else rc = -ENOSPC; }
        pthread_mutex_unlock(&gLock);
        return rc;
    }
}
static int e_rmdir(const char *path) {
    if (gReadOnly) return -EROFS;
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        pthread_mutex_lock(&gLock);
        EMU3Directory *d = DirForPath(p); int rc = 0;
        if (!d || [p isEqualToString:@"/"]) rc = -ENOENT;
        else if ([gChildren[p] count]) rc = -ENOTEMPTY;
        else { NSError *e = nil; if ([gFS deleteDirectory:d fromParent:gFS.rootDirectory error:&e]) Refresh(); else rc = -EBUSY; }
        pthread_mutex_unlock(&gLock);
        return rc;
    }
}
static int e_rename(const char *from, const char *to) {
    if (gReadOnly) return -EROFS;
    @autoreleasepool {
        NSString *f = Resolve(from), *t = [NSString stringWithUTF8String:to];
        pthread_mutex_lock(&gLock);
        int rc = 0; NSError *e = nil;
        Stage *stg = gStage[f];
        if (stg) {   // staged file renamed before it was written (e.g. Finder copy)
            [gStage removeObjectForKey:f]; gStage[t] = stg;
            if (stg.ghost && !IsGhostName(t)) stg.ghost = NO;
            pthread_mutex_unlock(&gLock); return 0;
        }
        id o = gPaths[f];
        if (!o) rc = -ENOENT;
        else if ([o isKindOfClass:[EMU3Directory class]]) {
            NSString *n = t.lastPathComponent; if (n.length > 15) n = [n substringToIndex:15];
            if (gPaths[t] && ![gPaths[t] isEqual:o]) rc = -EEXIST;
            else if (![gFS renameDirectory:o newName:n error:&e]) rc = -EBUSY; else Refresh();
        } else {
            EMU3Directory *sd = DirForPath(ParentOf(f)), *dd = DirForPath(ParentOf(t));
            id existing = gPaths[t];
            if (!sd || !dd || [ParentOf(t) isEqualToString:@"/"]) rc = -EACCES;
            else {
                if (existing && existing != o && [existing isKindOfClass:[EMU3File class]]) [gFS deleteFile:existing inDirectory:dd error:nil];
                NSString *n = BankNameFrom(t.lastPathComponent);
                BOOL ok = YES;
                if (sd != dd) ok = [gFS moveFile:o fromDirectory:sd toDirectory:dd error:&e];
                if (ok) {
                    Refresh();
                    // locate the moved file in the destination by old name, then rename
                    EMU3File *mf = nil; for (EMU3File *x in dd.files) if (!x.isDeleted && [x.name isEqualToString:((EMU3File *)o).name]) { mf = x; break; }
                    if (mf && ![mf.name isEqualToString:n]) ok = [gFS renameFile:mf newName:n inDirectory:dd error:&e];
                    if (ok) Refresh();
                }
                if (!ok) rc = -EBUSY;
            }
        }
        pthread_mutex_unlock(&gLock);
        return rc;
    }
}
static int e_chmod(const char *p, mode_t m) { return 0; }
static int e_chown(const char *p, uid_t u, gid_t g) { return 0; }
static int e_utimens(const char *p, const struct timespec ts[2]) { return 0; }
static int e_fsync(const char *p, int ds, struct fuse_file_info *fi) { return 0; }
static void e_destroy(void *u) { [[NSFileManager defaultManager] removeItemAtPath:gTmpDir error:nil]; }
static int e_statfs(const char *path, struct statvfs *s) {
    memset(s, 0, sizeof *s);
    s->f_bsize = 512; s->f_frsize = 512; s->f_blocks = gFS.totalBlocks;
    s->f_bfree = s->f_bavail = gFS.freeBlocks; s->f_namemax = 16;
    return 0;
}


// ═══ NFSv3 / MOUNT v3 server ═══════════════════════════════════════════════════════════════════════════════════════
typedef struct { uint8_t *b; size_t n, cap; } buf;
static void bput(buf *o, const void *p, size_t n) {
    if (o->n + n > o->cap) { o->cap = (o->n + n) * 2 + 4096; o->b = realloc(o->b, o->cap); }
    if (n) memcpy(o->b + o->n, p, n);
    o->n += n;
}
static void p32(buf *o, uint32_t v) { v = htonl(v); bput(o, &v, 4); }
static void p64(buf *o, uint64_t v) { p32(o, (uint32_t)(v >> 32)); p32(o, (uint32_t)v); }
static void popaq(buf *o, const void *p, size_t n) { static const uint8_t z[4] = {0}; p32(o, (uint32_t)n); bput(o, p, n); if (n & 3) bput(o, z, 4 - (n & 3)); }
typedef struct { const uint8_t *p; size_t n; int err; } rd;
static uint32_t g32(rd *r) { uint32_t v = 0; if (r->n < 4) { r->err = 1; return 0; } memcpy(&v, r->p, 4); r->p += 4; r->n -= 4; return ntohl(v); }
static uint64_t g64(rd *r) { uint64_t h = g32(r); return (h << 32) | g32(r); }
static const uint8_t *gopaq(rd *r, uint32_t *len) {
    uint32_t n = g32(r); size_t pad = ((size_t)n + 3) & ~(size_t)3;
    if (r->err || r->n < pad) { r->err = 1; *len = 0; return NULL; }
    const uint8_t *p = r->p; r->p += pad; r->n -= pad; *len = n; return p;
}

// File handles: 8 bytes server epoch + 8 bytes id. An id stands for a path, assigned on first sight.
static NSMutableDictionary<NSNumber *, NSString *> *gIdPath;
static NSMutableDictionary<NSString *, NSNumber *> *gPathId;
static uint64_t gNextId = 2, gEpoch;
static pthread_mutex_t gIdLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t IdForPath(NSString *p) {
    if ([p isEqualToString:@"/"]) return 1;
    pthread_mutex_lock(&gIdLock);
    NSNumber *n = gPathId[p];
    if (!n) { n = @(gNextId++); gPathId[p] = n; gIdPath[n] = p; }
    pthread_mutex_unlock(&gIdLock);
    return n.unsignedLongLongValue;
}
static NSString *PathForId(uint64_t id) {
    if (id == 1) return @"/";
    pthread_mutex_lock(&gIdLock); NSString *p = gIdPath[@(id)]; pthread_mutex_unlock(&gIdLock);
    return p;
}
static void pfh(buf *o, NSString *path) {
    uint8_t h[16]; uint64_t e = gEpoch, v = IdForPath(path);
    for (int i = 7; i >= 0; i--) { h[i] = e & 0xff; e >>= 8; h[8 + i] = v & 0xff; v >>= 8; }
    popaq(o, h, 16);
}
// nil = bad handle (stale)
static NSString *gfh(rd *r) {
    uint32_t l; const uint8_t *p = gopaq(r, &l);
    if (!p || l != 16) return nil;
    uint64_t e = 0, v = 0; for (int i = 0; i < 8; i++) { e = (e << 8) | p[i]; v = (v << 8) | p[8 + i]; }
    return e == gEpoch ? PathForId(v) : nil;
}
static NSString *ChildPath(NSString *dir, NSString *name) { return [dir isEqualToString:@"/"] ? [@"/" stringByAppendingString:name] : [NSString stringWithFormat:@"%@/%@", dir, name]; }

static void pattr(buf *o, NSString *path, const struct stat *st) {   // fattr3
    BOOL dir = S_ISDIR(st->st_mode);
    p32(o, dir ? 2 : 1); p32(o, st->st_mode & 07777); p32(o, dir ? 2 : 1);
    p32(o, getuid()); p32(o, getgid());
    p64(o, st->st_size); p64(o, (uint64_t)st->st_blocks * 512); p64(o, 0); p64(o, 1); p64(o, IdForPath(path));
    for (int i = 0; i < 3; i++) { p32(o, (uint32_t)st->st_mtime); p32(o, 0); }
}
static void ppost(buf *o, NSString *path) {   // post_op_attr
    struct stat st;
    if (path && e_getattr(path.UTF8String, &st) == 0) { p32(o, 1); pattr(o, path, &st); } else p32(o, 0);
}
static uint32_t NfsErr(int e) {
    switch (e < 0 ? -e : e) { case 0: return 0; case ENOENT: return 2; case EIO: return 5; case EACCES: return 13; case EEXIST: return 17;
        case ENOTDIR: return 20; case EISDIR: return 21; case EINVAL: return 22; case EFBIG: return 27; case ENOSPC: return 28;
        case EROFS: return 30; case ENAMETOOLONG: return 63; case ENOTEMPTY: return 66; case EPERM: return 1; case EBUSY: return 5; default: return 5; }
}
enum { OK = 0, E_NOENT = 2, E_NOTDIR = 20, E_ISDIR = 21, E_INVAL = 22, E_ROFS = 30, E_STALE = 70, E_NOTSUPP = 10004 };
#define RTMAX 1048576u


// ── write support ────────────────────────────────────────────────────────────────────────────────────────────────
// NFS has no open/close: a file being written lives in a staging temp file (as in emu3fuse) that is imported into the
// image once the writes have been quiet for a moment (write-back), at unmount, or when the server stops.
static NSMutableDictionary<NSString *, NSNumber *> *gLastWrite;   // path -> CFAbsoluteTime of the last change
static void Touch(NSString *p) { pthread_mutex_lock(&gIdLock); gLastWrite[p] = @(CFAbsoluteTimeGetCurrent()); pthread_mutex_unlock(&gIdLock); }
static NSString *Canon(NSString *p) { return Resolve(p.UTF8String); }   // "Foo.e4b" -> the stored name "Foo"
static NSString *gname(rd *r) { uint32_t l; const uint8_t *p = gopaq(r, &l); return p ? [[NSString alloc] initWithBytes:p length:l encoding:NSUTF8StringEncoding] : nil; }
static void pwcc(buf *o, NSString *p) { p32(o, 0); ppost(o, p); }   // wcc_data: no pre-op attributes
typedef struct { int hasSize; uint64_t size; } sattr;
static void gsattr(rd *r, sattr *s) {   // sattr3: only the size matters here
    s->hasSize = 0;
    if (g32(r)) g32(r);            // mode
    if (g32(r)) g32(r);            // uid
    if (g32(r)) g32(r);            // gid
    if (g32(r)) { s->hasSize = 1; s->size = g64(r); }
    uint32_t a = g32(r); if (a == 2) { g32(r); g32(r); }   // atime
    uint32_t m = g32(r); if (m == 2) { g32(r); g32(r); }   // mtime
}
static void SetRefs(NSString *p, int refs) { pthread_mutex_lock(&gLock); Stage *s = gStage[p]; if (s) s.refs = refs; pthread_mutex_unlock(&gLock); }
// Makes sure a staging file exists for p (a copy of the stored bank, or empty when trunc).
static int EnsureStage(NSString *p, BOOL trunc) {
    pthread_mutex_lock(&gLock); Stage *s = gStage[p]; pthread_mutex_unlock(&gLock);
    if (s) { if (trunc) return e_truncate(p.UTF8String, 0); return 0; }
    struct fuse_file_info fi = {O_RDWR | (trunc ? O_TRUNC : 0), 0};
    int rc = e_open(p.UTF8String, &fi);
    if (!rc) SetRefs(p, 1);
    return rc;
}
static uint64_t StoredSize(NSString *p) { pthread_mutex_lock(&gLock); id o = gPaths[p]; uint64_t n = [o isKindOfClass:[EMU3File class]] ? ((EMU3File *)o).fileSize : 0; pthread_mutex_unlock(&gLock); return n; }
static void RemapId(NSString *from, NSString *to) {   // a renamed file or folder keeps its handle
    pthread_mutex_lock(&gIdLock);
    NSString *pre = [from stringByAppendingString:@"/"];
    for (NSNumber *k in gIdPath.allKeys) {
        NSString *p = gIdPath[k], *np = nil;
        if ([p isEqualToString:from]) np = to; else if ([p hasPrefix:pre]) np = [to stringByAppendingString:[p substringFromIndex:from.length]];
        if (np) { [gPathId removeObjectForKey:p]; gPathId[np] = k; gIdPath[k] = np; }
    }
    NSNumber *t = gLastWrite[from]; if (t) { [gLastWrite removeObjectForKey:from]; gLastWrite[to] = t; }
    pthread_mutex_unlock(&gIdLock);
}
// Imports staged files into the image: those idle for 2 s, or all of them when force is set.
static void FlushAll(BOOL force) {
    @autoreleasepool {
        NSMutableArray<NSString *> *cand = [NSMutableArray array];
        pthread_mutex_lock(&gLock);
        for (NSString *p in gStage) { Stage *s = gStage[p]; if (!s.ghost && s.dirty) [cand addObject:p]; }
        pthread_mutex_unlock(&gLock);
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        for (NSString *p in cand) {
            pthread_mutex_lock(&gIdLock); NSNumber *t = gLastWrite[p]; pthread_mutex_unlock(&gIdLock);
            if (!force && t && now - t.doubleValue < 2.0) continue;
            struct fuse_file_info fi = {0, 0};
            int rc = e_flush(p.UTF8String, &fi);
            pthread_mutex_lock(&gLock); Stage *s = gStage[p]; BOOL done = s && !s.ghost && (rc != 0 || !s.dirty);
            if (s && rc != 0) { fprintf(stderr, "emu3nfs: could not store %s (error %d); the data is discarded\n", p.UTF8String, rc); s.dirty = NO; }
            if (done) s.refs = 1;
            pthread_mutex_unlock(&gLock);
            if (done) e_release(p.UTF8String, &fi);
        }
    }
}

static int collect(void *b, const char *name, const struct stat *st, off_t off) { [(__bridge NSMutableArray *)b addObject:@(name)]; return 0; }

static void nfs3(uint32_t proc, rd *r, buf *o) {
    @autoreleasepool {
    switch (proc) {
    case 0: break;
    case 1: { NSString *p = gfh(r); struct stat st; if (!p || e_getattr(p.UTF8String, &st)) { p32(o, E_STALE); break; } p32(o, OK); pattr(o, p, &st); break; }
    case 3: {   // LOOKUP
        NSString *d = gfh(r); uint32_t l; const uint8_t *nm = gopaq(r, &l);
        if (!d || !nm) { p32(o, E_STALE); p32(o, 0); break; }
        NSString *name = [[NSString alloc] initWithBytes:nm length:l encoding:NSUTF8StringEncoding];
        struct stat st, ds;
        if (e_getattr(d.UTF8String, &ds) || !S_ISDIR(ds.st_mode)) { p32(o, E_NOTDIR); p32(o, 0); break; }
        NSString *c = !name ? nil : [name isEqualToString:@"."] ? d : [name isEqualToString:@".."] ? ParentOf(d) : ChildPath(d, name);
        if (!c || e_getattr(c.UTF8String, &st)) { p32(o, E_NOENT); ppost(o, d); break; }
        p32(o, OK); pfh(o, c); p32(o, 1); pattr(o, c, &st); ppost(o, d); break; }
    case 4: { NSString *p = gfh(r); uint32_t want = g32(r); if (!p) { p32(o, E_STALE); p32(o, 0); break; }
        p32(o, OK); ppost(o, p); p32(o, want & (gReadOnly ? (1 | 2 | 0x20) : (1 | 2 | 4 | 8 | 0x10 | 0x20))); break; }
    case 6: {   // READ
        NSString *p = gfh(r); uint64_t off = g64(r); uint32_t cnt = g32(r); struct stat st;
        if (!p || e_getattr(p.UTF8String, &st)) { p32(o, E_STALE); p32(o, 0); break; }
        if (S_ISDIR(st.st_mode)) { p32(o, E_ISDIR); ppost(o, p); break; }
        if (cnt > RTMAX) cnt = RTMAX;
        uint8_t *tmp = malloc(cnt ? cnt : 1);
        struct fuse_file_info fi = {O_RDONLY, 0};
        int n = e_read(p.UTF8String, (char *)tmp, cnt, (off_t)off, &fi);
        if (n < 0) { free(tmp); p32(o, NfsErr(n)); ppost(o, p); break; }
        p32(o, OK); ppost(o, p); p32(o, (uint32_t)n); p32(o, off + n >= (uint64_t)st.st_size); popaq(o, tmp, n); free(tmp); break; }
    case 16: case 17: {   // READDIR / READDIRPLUS
        NSString *d = gfh(r); uint64_t cookie = g64(r); g64(r);
        uint32_t dircount = g32(r), maxcount = dircount; if (proc == 17) maxcount = g32(r);
        if (!d) { p32(o, E_STALE); p32(o, 0); break; }
        NSMutableArray<NSString *> *names = [NSMutableArray array]; struct fuse_file_info fi = {0, 0};
        int rc = e_readdir(d.UTF8String, (__bridge void *)names, collect, 0, &fi);
        if (rc) { p32(o, NfsErr(rc)); ppost(o, d); break; }
        p32(o, OK); ppost(o, d); p64(o, 0);
        size_t budget = maxcount > 512 ? maxcount - 512 : maxcount, used = 0; BOOL eof = YES;
        for (NSUInteger i = cookie; i < names.count; i++) {
            NSString *nm = names[i];
            NSString *c = [nm isEqualToString:@"."] ? d : [nm isEqualToString:@".."] ? ParentOf(d) : ChildPath(d, nm);
            size_t est = 32 + ((nm.length * 3 + 3) & ~3u) + (proc == 17 ? 120 : 0);
            if (used + est > budget && i > cookie) { eof = NO; break; }
            used += est;
            p32(o, 1); p64(o, IdForPath(c)); popaq(o, nm.UTF8String, strlen(nm.UTF8String)); p64(o, i + 1);
            if (proc == 17) { ppost(o, c); p32(o, 1); pfh(o, c); }
        }
        p32(o, 0); p32(o, eof); break; }
    case 18: { NSString *p = gfh(r); struct statvfs sv; e_statfs("/", &sv);
        p32(o, OK); ppost(o, p); p64(o, (uint64_t)sv.f_blocks * 512); p64(o, (uint64_t)sv.f_bfree * 512); p64(o, (uint64_t)sv.f_bavail * 512);
        p64(o, 1 << 20); p64(o, 1 << 20); p64(o, 1 << 20); p32(o, 0); break; }
    case 19: { NSString *p = gfh(r); p32(o, OK); ppost(o, p);
        p32(o, RTMAX); p32(o, RTMAX); p32(o, 4096); p32(o, RTMAX); p32(o, RTMAX); p32(o, 4096); p32(o, 8192);
        p64(o, 1ull << 40); p32(o, 1); p32(o, 0); p32(o, 0x18); break; }
    case 20: { NSString *p = gfh(r); p32(o, OK); ppost(o, p); p32(o, 1); p32(o, 255); p32(o, 1); p32(o, 1); p32(o, 0); p32(o, 1); break; }
    case 5: p32(o, E_INVAL); p32(o, 0); break;   // READLINK: there are no links
    case 2: {   // SETATTR: only the size matters (the rest is accepted and ignored)
        NSString *p = gfh(r); sattr sa; gsattr(r, &sa);
        if (!p) { p32(o, E_STALE); p32(o, 0); p32(o, 0); break; }
        if (gReadOnly) { p32(o, E_ROFS); pwcc(o, p); break; }
        p = Canon(p); int rc = 0; struct stat st;
        if (sa.hasSize) {
            if (e_getattr(p.UTF8String, &st)) rc = -ENOENT;
            else if (S_ISDIR(st.st_mode)) rc = -EISDIR;
            else if ((uint64_t)st.st_size != sa.size) {
                rc = EnsureStage(p, sa.size == 0);
                if (!rc && sa.size) rc = e_truncate(p.UTF8String, (off_t)sa.size);
                Touch(p);
            }
        }
        p32(o, NfsErr(rc)); pwcc(o, p); break; }
    case 7: {   // WRITE
        NSString *p = gfh(r); uint64_t off = g64(r); uint32_t cnt = g32(r); g32(r); uint32_t dl; const uint8_t *data = gopaq(r, &dl);
        if (!p || !data) { p32(o, E_STALE); p32(o, 0); p32(o, 0); break; }
        if (gReadOnly) { p32(o, E_ROFS); pwcc(o, p); break; }
        if (dl > cnt) dl = cnt;
        p = Canon(p); struct stat st; struct statvfs sv; e_statfs("/", &sv);
        if (e_getattr(p.UTF8String, &st)) { p32(o, E_NOENT); pwcc(o, p); break; }
        if (S_ISDIR(st.st_mode)) { p32(o, E_ISDIR); pwcc(o, p); break; }
        if (off + dl > (uint64_t)sv.f_bavail * 512 + StoredSize(p)) { p32(o, 28); pwcc(o, p); break; }   // NFS3ERR_NOSPC
        int rc = EnsureStage(p, NO), w = 0;
        if (!rc) { struct fuse_file_info fi = {0, 0}; w = e_write(p.UTF8String, (const char *)data, dl, (off_t)off, &fi); if (w < 0) rc = w; }
        if (rc) { p32(o, NfsErr(rc)); pwcc(o, p); break; }
        Touch(p); p32(o, OK); pwcc(o, p); p32(o, (uint32_t)w); p32(o, 0); p64(o, gEpoch); break; }
    case 21: { NSString *p = gfh(r); g64(r); g32(r); p32(o, OK); pwcc(o, p); p64(o, gEpoch); break; }   // COMMIT: the import happens when writes go quiet
    case 8: {   // CREATE
        NSString *d = gfh(r); NSString *name = gname(r); uint32_t how = g32(r); sattr sa = {0};
        if (how < 2) gsattr(r, &sa); else g64(r);
        if (!d || !name) { p32(o, E_STALE); p32(o, 0); p32(o, 0); break; }
        if (gReadOnly) { p32(o, E_ROFS); pwcc(o, d); break; }
        NSString *c = Canon(ChildPath(d, name)); struct stat st; int rc = 0;
        if (e_getattr(c.UTF8String, &st) == 0) {
            if (how != 0) rc = -EEXIST;
            else if (S_ISDIR(st.st_mode)) rc = -EISDIR;
            else if (sa.hasSize && sa.size == 0 && st.st_size > 0) rc = EnsureStage(c, YES);
        } else {
            c = ChildPath(d, name); struct fuse_file_info fi = {O_RDWR, 0};
            rc = e_create(c.UTF8String, 0644, &fi); if (!rc) SetRefs(c, 1);
        }
        if (rc) { p32(o, NfsErr(rc)); pwcc(o, d); break; }
        Touch(c); p32(o, OK); p32(o, 1); pfh(o, c); ppost(o, c); pwcc(o, d); break; }
    case 9: {   // MKDIR
        NSString *d = gfh(r); NSString *name = gname(r); sattr sa; gsattr(r, &sa);
        if (!d || !name) { p32(o, E_STALE); p32(o, 0); p32(o, 0); break; }
        NSString *c = ChildPath(d, name); int rc = e_mkdir(c.UTF8String, 0755);
        if (rc) { p32(o, NfsErr(rc)); pwcc(o, d); break; }
        p32(o, OK); p32(o, 1); pfh(o, c); ppost(o, c); pwcc(o, d); break; }
    case 12: case 13: {   // REMOVE / RMDIR
        NSString *d = gfh(r); NSString *name = gname(r);
        if (!d || !name) { p32(o, E_STALE); p32(o, 0); p32(o, 0); break; }
        NSString *c = ChildPath(d, name);
        int rc = proc == 12 ? e_unlink(Canon(c).UTF8String) : e_rmdir(c.UTF8String);
        p32(o, NfsErr(rc)); pwcc(o, d); break; }
    case 14: {   // RENAME
        NSString *fd = gfh(r); NSString *fn = gname(r); NSString *td = gfh(r); NSString *tn = gname(r);
        if (!fd || !fn || !td || !tn) { p32(o, E_STALE); for (int i = 0; i < 4; i++) p32(o, 0); break; }
        NSString *f = Canon(ChildPath(fd, fn)), *t = ChildPath(td, tn);
        int rc = e_rename(f.UTF8String, t.UTF8String);
        if (!rc) { RemapId(f, t); Touch(t); }
        p32(o, NfsErr(rc)); pwcc(o, fd); pwcc(o, td); break; }
    case 10: case 11: p32(o, E_NOTSUPP); p32(o, 0); p32(o, 0); break;           // SYMLINK, MKNOD
    case 15: p32(o, E_NOTSUPP); p32(o, 0); p32(o, 0); p32(o, 0); break;         // LINK
    default: p32(o, E_NOTSUPP); p32(o, 0); break;
    }
    }
}
static void mount3(uint32_t proc, rd *r, buf *o) {
    if (proc == 1) { uint32_t l; gopaq(r, &l); p32(o, 0); pfh(o, @"/"); p32(o, 1); p32(o, 1); }   // MNT: any path mounts the image
    else if (proc == 5) { p32(o, 1); popaq(o, "/", 1); p32(o, 0); p32(o, 0); }                      // EXPORT
}
static int readn(int fd, void *b, size_t n) { size_t g = 0; while (g < n) { ssize_t k = read(fd, (char *)b + g, n - g); if (k <= 0) return -1; g += k; } return 0; }
static int writen(int fd, const void *b, size_t n) { size_t g = 0; while (g < n) { ssize_t k = write(fd, (const char *)b + g, n - g); if (k <= 0) return -1; g += k; } return 0; }

static void *conn(void *arg) {
    int fd = (int)(intptr_t)arg;
    for (;;) {
        buf req = {0}; uint32_t hdr;
        for (;;) {   // record marking: gather the fragments of one request
            if (readn(fd, &hdr, 4)) { free(req.b); goto done; }
            hdr = ntohl(hdr); size_t len = hdr & 0x7fffffff;
            if (len > (4u << 20)) { free(req.b); goto done; }
            size_t at = req.n; bput(&req, NULL, 0);
            if (req.n + len > req.cap) { req.cap = req.n + len + 64; req.b = realloc(req.b, req.cap); }
            if (readn(fd, req.b + at, len)) { free(req.b); goto done; }
            req.n += len;
            if (hdr & 0x80000000u) break;
        }
        rd r = {req.b, req.n, 0};
        uint32_t xid = g32(&r), mt = g32(&r), rv = g32(&r), prog = g32(&r), vers = g32(&r), proc = g32(&r);
        for (int k = 0; k < 2; k++) { g32(&r); uint32_t l; gopaq(&r, &l); }   // credentials, verifier
        if (r.err || mt != 0 || rv != 2) { free(req.b); goto done; }
        buf rep = {0}; p32(&rep, 0); p32(&rep, xid); p32(&rep, 1); p32(&rep, 0); p32(&rep, 0); p32(&rep, 0);
        if (prog == 100003 && vers == 3) { p32(&rep, 0); nfs3(proc, &r, &rep); }
        else if (prog == 100005 && vers == 3) { p32(&rep, 0); mount3(proc, &r, &rep); }
        else if (prog == 100003 || prog == 100005) { p32(&rep, 2); p32(&rep, 3); p32(&rep, 3); }
        else p32(&rep, 1);
        uint32_t h = htonl(0x80000000u | (uint32_t)(rep.n - 4)); memcpy(rep.b, &h, 4);
        int bad = writen(fd, rep.b, rep.n);
        free(req.b); free(rep.b);
        if (bad) break;
    }
done:
    close(fd); return NULL;
}
static int gListen = -1;
static void *acceptLoop(void *a) {
    int one = 1;
    for (;;) {
        int c = accept(gListen, NULL, NULL); if (c < 0) continue;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        pthread_t t; pthread_create(&t, NULL, conn, (void *)(intptr_t)c); pthread_detach(t);
    }
    return NULL;
}

static NSString *gMountPoint;
static BOOL MountPresent(void) {
    struct statfs *fs; int n = getmntinfo(&fs, MNT_NOWAIT);
    for (int i = 0; i < n; i++) if (strcmp(fs[i].f_mntonname, gMountPoint.fileSystemRepresentation) == 0 && strcmp(fs[i].f_fstypename, "nfs") == 0) return YES;
    return NO;
}
static void Quit(int code) { FlushAll(YES); e_destroy(NULL); exit(code); }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: emu3nfs IMAGE MOUNTPOINT [--gate]\n"); return 2; }
        NSError *err = nil;
        gFS = [[EMU3Filesystem alloc] initWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&err];
        if (!gFS) { fprintf(stderr, "emu3nfs: %s\n", err.localizedDescription.UTF8String); return 1; }
        gMTime = time(NULL);
        gStage = [NSMutableDictionary dictionary];
        gTmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"emu3nfs-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:gTmpDir withIntermediateDirectories:YES attributes:nil error:nil];
        gReadOnly = gFS.isReadOnly;
        gImagePath = strdup(argv[1]); gHash = MetaHash(); gLastCheck = CFAbsoluteTimeGetCurrent();
        BOOL gate = NO;
        for (int i = 3; i < argc; i++) { if (strcmp(argv[i], "--gate") == 0) gate = YES; if (strcmp(argv[i], "--ro") == 0) gReadOnly = YES; }
        if (gate) {   // ask the app (over stdin/stdout) before every edit: "B" -> "OK"/"NO", then "E" when done
            gFS.editGateBegin = ^BOOL{
                fputs("B\n", stdout); fflush(stdout);
                char line[32]; if (!fgets(line, sizeof line, stdin)) return NO;
                return strncmp(line, "OK", 2) == 0;
            };
            gFS.editGateEnd = ^{ fputs("E\n", stdout); fflush(stdout); };
        }
        Build();
        gLastWrite = [NSMutableDictionary dictionary]; gIdPath = [NSMutableDictionary dictionary]; gPathId = [NSMutableDictionary dictionary];
        gEpoch = ((uint64_t)arc4random() << 32) | arc4random();
        gMountPoint = [@(argv[2]) stringByResolvingSymlinksInPath];

        gListen = socket(AF_INET, SOCK_STREAM, 0); int one = 1; setsockopt(gListen, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = 0;
        if (bind(gListen, (void *)&a, sizeof a) || listen(gListen, 16)) { perror("emu3nfs: bind"); return 1; }
        socklen_t sl = sizeof a; getsockname(gListen, (void *)&a, &sl); int port = ntohs(a.sin_port);
        pthread_t t; pthread_create(&t, NULL, acceptLoop, NULL); pthread_detach(t);

        NSString *vol = [@(argv[1]).lastPathComponent stringByDeletingPathExtension];
        NSString *opts = [NSString stringWithFormat:@"vers=3,tcp,port=%d,mountport=%d,noresvport,nolocks,locallocks,soft,nfc%@", port, port, gReadOnly ? @",rdonly" : @""];
        NSString *from = [NSString stringWithFormat:@"localhost:/%@", vol];
        char *margv[] = {"mount_nfs", "-o", (char *)opts.UTF8String, (char *)from.UTF8String, (char *)gMountPoint.fileSystemRepresentation, NULL};
        pid_t pid; if (posix_spawn(&pid, "/sbin/mount_nfs", NULL, NULL, margv, environ)) { fprintf(stderr, "emu3nfs: cannot run mount_nfs\n"); return 1; }
        int st = 0; waitpid(pid, &st, 0);
        if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) { fprintf(stderr, "emu3nfs: mount_nfs failed\n"); Quit(1); }

        // Stay alive while the volume is mounted; unmount it when asked to stop.
        void (^stop)(void) = ^{ unmount(gMountPoint.fileSystemRepresentation, 0); if (MountPresent()) unmount(gMountPoint.fileSystemRepresentation, MNT_FORCE); Quit(0); };
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN);
        static NSMutableArray *keep = nil; keep = [NSMutableArray array];
        int sigs[2] = {SIGTERM, SIGINT};
        for (int k = 0; k < 2; k++) { int sg = sigs[k];
            dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sg, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(s, stop); dispatch_resume(s);
            [keep addObject:s];
        }
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{ if (!MountPresent()) Quit(0); });
        dispatch_resume(timer);
        static dispatch_source_t flusher;   // write-back: import files whose writes have stopped
        flusher = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_queue_create("emu3nfs.flush", DISPATCH_QUEUE_SERIAL));
        dispatch_source_set_timer(flusher, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(flusher, ^{ FlushAll(NO); });
        dispatch_resume(flusher);
        dispatch_main();
    }
}
