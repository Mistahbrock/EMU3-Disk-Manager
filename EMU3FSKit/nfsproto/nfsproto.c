// Throwaway prototype: a read-only NFSv3 + MOUNT v3 server on 127.0.0.1 serving a tiny in-memory tree.
// Purpose: prove that macOS mounts it as a normal user (no root, no kernel extension), the way FUSE-T does.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

typedef struct { uint8_t *b; size_t n, cap; } buf;
static void bput(buf *o, const void *p, size_t n) {
    if (o->n + n > o->cap) { o->cap = (o->n + n) * 2 + 4096; o->b = realloc(o->b, o->cap); }
    memcpy(o->b + o->n, p, n); o->n += n;
}
static void p32(buf *o, uint32_t v) { v = htonl(v); bput(o, &v, 4); }
static void p64(buf *o, uint64_t v) { p32(o, (uint32_t)(v >> 32)); p32(o, (uint32_t)v); }
static void popaq(buf *o, const void *p, size_t n) { static const uint8_t z[4] = {0}; p32(o, (uint32_t)n); bput(o, p, n); if (n & 3) bput(o, z, 4 - (n & 3)); }

typedef struct { const uint8_t *p; size_t n; int err; } rd;
static uint32_t g32(rd *r) { uint32_t v = 0; if (r->n < 4) { r->err = 1; return 0; } memcpy(&v, r->p, 4); r->p += 4; r->n -= 4; return ntohl(v); }
static uint64_t g64(rd *r) { uint64_t h = g32(r); return (h << 32) | g32(r); }
static const uint8_t *gopaq(rd *r, uint32_t *len) {
    uint32_t n = g32(r); size_t pad = (n + 3) & ~3u;
    if (r->err || r->n < pad) { r->err = 1; *len = 0; return NULL; }
    const uint8_t *p = r->p; r->p += pad; r->n -= pad; *len = n; return p;
}

// ── the tree ────────────────────────────────────────────────────────────────
typedef struct { uint64_t id, parent; const char *name; int dir; uint64_t size; } node;
static node T[] = {
    {1, 1, "",          1, 0},
    {2, 1, "hello.txt", 0, 0},
    {3, 1, "docs",      1, 0},
    {4, 3, "readme.txt",0, 0},
    {5, 1, "big.bin",   0, 1048576 + 123},
};
#define NT (sizeof T / sizeof T[0])
static const char *HELLO = "Hello from the NFS prototype\n";
static const char *README = "Served without FUSE, over NFSv3 on localhost.\n";
static node *byid(uint64_t id) { for (size_t i = 0; i < NT; i++) if (T[i].id == id) return &T[i]; return NULL; }
static void fill(node *n, uint64_t off, uint8_t *dst, size_t len) {
    for (size_t i = 0; i < len; i++) {
        uint64_t o = off + i;
        if (n->id == 2) dst[i] = o < strlen(HELLO) ? HELLO[o] : 0;
        else if (n->id == 4) dst[i] = o < strlen(README) ? README[o] : 0;
        else dst[i] = (uint8_t)(o * 7 + (o >> 8));
    }
}
static time_t T0;

static void pattr(buf *o, node *n) {   // fattr3
    p32(o, n->dir ? 2 : 1); p32(o, n->dir ? 0555 : 0444); p32(o, n->dir ? 2 : 1);
    p32(o, getuid()); p32(o, getgid());
    p64(o, n->size); p64(o, (n->size + 4095) & ~4095ull); p64(o, 0); p64(o, 1); p64(o, n->id);
    for (int i = 0; i < 3; i++) { p32(o, (uint32_t)T0); p32(o, 0); }
}
static void ppost(buf *o, node *n) { if (n) { p32(o, 1); pattr(o, n); } else p32(o, 0); }
static void pfh(buf *o, node *n) { uint8_t h[8]; uint64_t v = n->id; for (int i = 7; i >= 0; i--) { h[i] = v & 0xff; v >>= 8; } popaq(o, h, 8); }
static node *gfh(rd *r) { uint32_t l; const uint8_t *p = gopaq(r, &l); if (!p || l != 8) return NULL; uint64_t v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | p[i]; return byid(v); }

static const uint32_t OK = 0, E_NOENT = 2, E_NOTDIR = 20, E_ISDIR = 21, E_INVAL = 22, E_ROFS = 30, E_STALE = 70, E_NOTSUPP = 10004;

static void nfs3(uint32_t proc, rd *r, buf *o) {
    switch (proc) {
    case 0: break;
    case 1: { node *n = gfh(r); if (!n) { p32(o, E_STALE); break; } p32(o, OK); pattr(o, n); break; }
    case 3: {   // LOOKUP
        node *d = gfh(r); uint32_t l; const uint8_t *nm = gopaq(r, &l);
        if (!d || !nm) { p32(o, E_STALE); ppost(o, NULL); break; }
        if (!d->dir) { p32(o, E_NOTDIR); ppost(o, d); break; }
        node *f = NULL;
        if (l == 1 && nm[0] == '.') f = d;
        else if (l == 2 && nm[0] == '.' && nm[1] == '.') f = byid(d->parent);
        else for (size_t i = 1; i < NT; i++) if (T[i].parent == d->id && strlen(T[i].name) == l && !memcmp(T[i].name, nm, l)) f = &T[i];
        if (!f) { p32(o, E_NOENT); ppost(o, d); break; }
        p32(o, OK); pfh(o, f); ppost(o, f); ppost(o, d); break; }
    case 4: { node *n = gfh(r); uint32_t want = g32(r); if (!n) { p32(o, E_STALE); ppost(o, NULL); break; }
        p32(o, OK); ppost(o, n); p32(o, want & (1 | 2 | 0x20)); break; }
    case 6: {   // READ
        node *n = gfh(r); uint64_t off = g64(r); uint32_t cnt = g32(r);
        if (!n) { p32(o, E_STALE); ppost(o, NULL); break; }
        if (n->dir) { p32(o, E_ISDIR); ppost(o, n); break; }
        if (cnt > 131072) cnt = 131072;
        uint64_t avail = off < n->size ? n->size - off : 0; if (cnt > avail) cnt = (uint32_t)avail;
        uint8_t *tmp = malloc(cnt ? cnt : 1); fill(n, off, tmp, cnt);
        p32(o, OK); ppost(o, n); p32(o, cnt); p32(o, off + cnt >= n->size); popaq(o, tmp, cnt); free(tmp); break; }
    case 16: case 17: {   // READDIR / READDIRPLUS
        node *d = gfh(r); uint64_t cookie = g64(r); g64(r); uint32_t dc = g32(r), mc = 0; if (proc == 17) mc = g32(r); (void)dc; (void)mc;
        if (!d) { p32(o, E_STALE); ppost(o, NULL); break; }
        if (!d->dir) { p32(o, E_NOTDIR); ppost(o, d); break; }
        p32(o, OK); ppost(o, d); p64(o, 0);
        uint64_t idx = 0;
        node *ent[16]; const char *nm[16]; size_t ne = 0;
        ent[ne] = d; nm[ne++] = "."; ent[ne] = byid(d->parent); nm[ne++] = "..";
        for (size_t i = 1; i < NT; i++) if (T[i].parent == d->id && T[i].id != d->id) { ent[ne] = &T[i]; nm[ne++] = T[i].name; }
        for (; idx < ne; idx++) {
            if (idx + 1 <= cookie) continue;
            p32(o, 1); p64(o, ent[idx]->id); popaq(o, nm[idx], strlen(nm[idx])); p64(o, idx + 1);
            if (proc == 17) { ppost(o, ent[idx]); p32(o, 1); pfh(o, ent[idx]); }
        }
        p32(o, 0); p32(o, 1); break; }
    case 18: { node *n = gfh(r); p32(o, OK); ppost(o, n); p64(o, 1ull << 30); p64(o, 0); p64(o, 0); p64(o, 100); p64(o, 0); p64(o, 0); p32(o, 0); break; }
    case 19: { node *n = gfh(r); p32(o, OK); ppost(o, n);
        p32(o, 131072); p32(o, 131072); p32(o, 4096); p32(o, 131072); p32(o, 131072); p32(o, 4096); p32(o, 8192);
        p64(o, 1ull << 40); p32(o, 1); p32(o, 0); p32(o, 0x18); break; }
    case 20: { node *n = gfh(r); p32(o, OK); ppost(o, n); p32(o, 1); p32(o, 255); p32(o, 1); p32(o, 1); p32(o, 0); p32(o, 1); break; }
    case 5: p32(o, E_INVAL); p32(o, 0); break;
    case 2: case 7: case 8: case 9: case 10: case 11: case 12: case 13: case 21:
        p32(o, E_ROFS); p32(o, 0); p32(o, 0); break;
    case 14: case 15: p32(o, E_ROFS); for (int i = 0; i < 4; i++) p32(o, 0); break;
    default: p32(o, E_NOTSUPP); p32(o, 0); break;
    }
}

static void mount3(uint32_t proc, rd *r, buf *o) {
    if (proc == 1) {   // MNT
        uint32_t l; gopaq(r, &l);
        p32(o, 0); pfh(o, &T[0]); p32(o, 1); p32(o, 1);
    } else if (proc == 5) {   // EXPORT
        p32(o, 1); popaq(o, "/", 1); p32(o, 0); p32(o, 0);
    }   // NULL(0), UMNT(3), UMNTALL(4): empty
}

static int readn(int fd, void *b, size_t n) { size_t g = 0; while (g < n) { ssize_t k = read(fd, (char *)b + g, n - g); if (k <= 0) return -1; g += k; } return 0; }
static int writen(int fd, const void *b, size_t n) { size_t g = 0; while (g < n) { ssize_t k = write(fd, (const char *)b + g, n - g); if (k <= 0) return -1; g += k; } return 0; }

static void *conn(void *arg) {
    int fd = (int)(intptr_t)arg;
    for (;;) {
        buf req = {0}; uint32_t hdr;
        for (;;) {   // record marking: gather fragments
            if (readn(fd, &hdr, 4)) goto done;
            hdr = ntohl(hdr); size_t len = hdr & 0x7fffffff;
            if (len > (1 << 21)) goto done;
            size_t at = req.n; bput(&req, NULL, 0);
            if (req.n + len > req.cap) { req.cap = req.n + len + 64; req.b = realloc(req.b, req.cap); }
            if (readn(fd, req.b + at, len)) goto done; req.n += len;
            if (hdr & 0x80000000u) break;
        }
        rd r = {req.b, req.n, 0};
        uint32_t xid = g32(&r), mt = g32(&r), rv = g32(&r), prog = g32(&r), vers = g32(&r), proc = g32(&r);
        for (int k = 0; k < 2; k++) { g32(&r); uint32_t l; gopaq(&r, &l); }   // cred, verf
        buf rep = {0}; p32(&rep, 0); p32(&rep, xid); p32(&rep, 1); p32(&rep, 0); p32(&rep, 0); p32(&rep, 0);
        if (r.err || mt != 0 || rv != 2) { rep.n = 0; free(req.b); free(rep.b); goto done; }
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

int main(int argc, char **argv) {
    T0 = time(NULL);
    T[1].size = strlen(HELLO); T[3].size = strlen(README);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons(argc > 1 ? atoi(argv[1]) : 0);
    if (bind(s, (void *)&a, sizeof a) || listen(s, 8)) { perror("bind"); return 1; }
    socklen_t l = sizeof a; getsockname(s, (void *)&a, &l);
    printf("%d\n", ntohs(a.sin_port)); fflush(stdout);
    for (;;) {
        int c = accept(s, NULL, NULL); if (c < 0) continue;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        pthread_t t; pthread_create(&t, NULL, conn, (void *)(intptr_t)c); pthread_detach(t);
    }
}
