#!/usr/bin/env python3 -I
"""Provenance probe: reads an E-mu EOS disk image (read only) and prints what is actually stored in it.

It is an independent implementation (it shares no code with the app) and uses only observation: every statement
it prints can be checked against the bytes of the image with a hex editor. Run:  probe.py IMAGE.hda
"""
import os, struct, sys

path = sys.argv[1]
f = open(path, "rb")
fsize = os.fstat(f.fileno()).st_size
cache = {}
def blk(n):
    if n not in cache:
        f.seek(n * 512); cache[n] = f.read(512)
    return cache[n]
def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def i16(b, o): return struct.unpack_from("<h", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def hexs(b): return " ".join("%02x" % x for x in b)

print("# Observations from", os.path.basename(path), "(%d bytes = %d blocks of 512)" % (fsize, fsize // 512))
sb = blk(0)
print("\n## Superblock (block 0)")
print("O1  bytes 0x00..0x03 =", repr(sb[:4]), " (signature)")
for i in range(1, 16):
    print("O2  dword at 0x%02x = %-10d (0x%x)" % (4 * i, u32(sb, 4 * i), u32(sb, 4 * i)))
d = [u32(sb, 4 * i) for i in range(16)]
last_block, root_dir, root_cnt, pool_start, pool_cnt, fat_start, fat_blocks = d[1], d[2], d[3], d[4], d[5], d[6], d[7]
data_area, max_cluster, shift = d[8], d[9], d[10] & 0xff
# NOTE: indices above are dword numbers (offset/4); the app reads them as fields[] = dwords from offset 4.
root_dir, root_cnt, pool_start, pool_cnt, fat_start, fat_blocks, data_area, max_cluster = d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9]
shift_dw = u32(sb, 0x28)
shift = shift_dw & 0xff
print("\n## Geometry read from the dwords")
print("G1  root directory: blocks %d .. %d  (dword 0x08 = start, 0x0c = count)" % (root_dir, root_dir + root_cnt - 1))
print("G2  folder pool: blocks %d .. %d  (dwords 0x10, 0x14)" % (pool_start, pool_start + pool_cnt - 1))
print("G3  allocation table (FAT): start block %d, %d blocks  (dwords 0x18, 0x1c)" % (fat_start, fat_blocks))
print("G4  data area starts at block %d  (dword 0x20); highest cluster number %d (dword 0x24)" % (data_area, max_cluster))
print("G5  cluster size: dword 0x28 low byte = %d -> cluster = 64 << %d = %d blocks = %.1f MB" % (shift, shift, 64 << shift, (64 << shift) * 512 / 1048576))
cb = 64 << shift
print("G6  blocks from data area to end of file: %d -> %.2f clusters of that size (header says %d)" %
      (fsize // 512 - data_area, (fsize // 512 - data_area) / cb, max_cluster))

def fat(c):
    b = blk(fat_start + c // 256); return u16(b, (c % 256) * 2)
print("\n## Allocation table")
vals = {}
for c in range(0, max_cluster + 1):
    v = fat(c); vals[v] = vals.get(v, 0) + 1 if v in (0, 0x7fff, 0x8000) else vals.get("chain", 0) + 1
print("F1  entries 0..%d: free(0x0000)=%d  end-of-chain(0x7fff)=%d  0x8000=%d  link-to-next=%d" %
      (max_cluster, vals.get(0, 0), vals.get(0x7fff, 0), vals.get(0x8000, 0), vals.get("chain", 0)))
print("F2  entry 0 = 0x%04x" % fat(0))

def chain(start):
    out = []; c = start
    while 1 <= c <= max_cluster and len(out) <= max_cluster:
        out.append(c); n = fat(c)
        if n in (0x7fff, 0, 0x8000): break
        c = n
    return out
def read_file_head(start, nbytes):
    out = b""
    for c in chain(start):
        for k in range(cb):
            out += blk(data_area + (c - 1) * cb + k)
            if len(out) >= nbytes: return out[:nbytes]
    return out

stats = {"files": 0, "dirs": 0, "chain_ok": 0, "chain_bad": 0, "size_ok": 0, "size_bad": 0}
types = {}; dirids = {}
banks = []
lines = []
def walk(blocks, depth, label):
    for bn in blocks:
        b = blk(bn)
        for i in range(16):
            e = b[i * 32:(i + 1) * 32]
            if e[0] == 0: continue
            name = e[:16].rstrip(b" \x00").decode("latin-1")
            unknown, ident = e[16], e[17]
            ftype = e[26]
            start, clusters, nblk, nbytes = u16(e, 18), u16(e, 20), u16(e, 22), u16(e, 24)
            props = e[27:32]
            if ftype in (0x80, 0x81, 0x83) or props[1:5] == b"E4B0":
                stats["files"] += 1; types[ftype] = types.get(ftype, 0) + 1
                ch = chain(start)
                ok = len(ch) == clusters
                stats["chain_ok" if ok else "chain_bad"] += 1
                size = ((clusters - 1) * cb + nblk - 1) * 512 + nbytes if clusters and nblk else 0
                banks.append((label + "/" + name, start, clusters, nblk, nbytes, ftype, props, size, ident, unknown))
                if len(lines) < 14: lines.append("D1  %-34s id=%02x type=%02x start=%d clusters=%d blocks=%d bytes=%d props=%s -> size %d, FAT chain length %d" %
                                                (label + "/" + name, ident, ftype, start, clusters, nblk, nbytes, hexs(props), size, len(ch)))
            elif ident in (0x40, 0x80):
                stats["dirs"] += 1; dirids[ident] = dirids.get(ident, 0) + 1
                bl = [i16(e, 18 + 2 * k) for k in range(7)]
                if len(lines) < 14: lines.append("D2  folder %-26s id=%02x block_list=%s" % (name, ident, bl))
                walk([x for x in bl if x > 0], depth + 1, label + "/" + name)
walk(range(root_dir, root_dir + root_cnt), 0, "")
print("\n## Directory entries (32 bytes each: name[16], unknown, id, then 14 bytes of attributes)")
print("\n".join(lines))
print("D3  totals: files=%d folders=%d  file type bytes seen: %s  folder id bytes seen: %s" %
      (stats["files"], stats["dirs"], {hex(k): v for k, v in types.items()}, {hex(k): v for k, v in dirids.items()}))
print("D4  FAT chain length equals the 'clusters' field: %d of %d files" % (stats["chain_ok"], stats["files"]))

print("\n## File contents (first bytes of each distinct kind)")
seen = {}
for name, start, clusters, nblk, nbytes, ftype, props, size, ident, unk in banks:
    head = read_file_head(start, 0x3000)
    kind = head[:16]
    if kind in seen: continue
    seen[kind] = (name, head, size)
for kind, (name, head, size) in list(seen.items())[:6]:
    print("B1  %s  size=%d  first 16 bytes=%r" % (name, size, kind))
    if kind.startswith(b"EMULATOR") or kind.startswith(b"EMU SI"):
        three = kind.startswith(b"EMULATOR THREE")
        pr, sm, ps = (0x6c, 0x204, 0x74a) if three else (0x17ca, 0x1bd2, 0x2b72)
        print("B2    header: name=%r objects=%d next_preset=%d next_sample=%d preset_blocks=%d sample_blocks=%d total_blocks=%d selected_preset=%d" %
              (head[16:32].rstrip(b' \x00'), u32(head, 0x20), u32(head, 0x30), u32(head, 0x34), u32(head, 0x3c), u32(head, 0x40), u32(head, 0x48), u32(head, 0x5c)))
        print("B3    first preset-address values @0x%x: %s ; first sample-address values @0x%x: %s ; preset area begins @0x%x" %
              (pr, [hex(u32(head, pr + 4 * k)) for k in range(3)], sm, [hex(u32(head, sm + 4 * k)) for k in range(3)], ps))
        # sample header check
        fh = read_file_head(next(b[1] for b in banks if b[0] == name), 0x400000 + 0x4000) if False else None
    elif kind[:4] == b"FORM":
        print("B2    IFF container: form type=%r first chunk id=%r length=%d" % (head[8:12], head[12:16], struct.unpack(">I", head[16:20])[0]))

print("\n## All banks: consistency of the header and the two tables (3X / ESI-32 v3 layout)")
n3x = tot_ok = tab_s_ok = tab_p_ok = hdr_ok = 0; iff_n = iff_eq = 0; diffs = {}
other = {}
for name, start, clusters, nblk, nbytes, ftype, props, size, ident, unk in banks:
    head = read_file_head(start, 0x3000)
    k = head[:16]
    if k in (b"EMULATOR 3X    \x00"[:15] + b" ", b"EMULATOR 3X     "[:16]) or k.startswith(b"EMULATOR 3X") or k.startswith(b"EMU SI-32 v3"):
        n3x += 1
        if -(-size // 512) == u32(head, 0x48): tot_ok += 1
        stbl = [u32(head, 0x1bd2 + 4 * i) for i in range(999)]
        ns = next((i for i, v in enumerate(stbl) if v == 0), 999)
        ptbl = [u32(head, 0x17ca + 4 * i) for i in range(256)]
        npz = 0
        for i in range(256):
            a = ptbl[i]; nx = ptbl[i + 1] if i + 1 < 256 else 0
            if a != nx and a != 0: npz += 1
            else: break
        mono = all(stbl[i] < stbl[i + 1] for i in range(ns - 1)) if ns > 1 else True
        if mono and (ns == 0 or stbl[0] == 0x400000): tab_s_ok += 1
        if u32(head, 0x20) == ns + npz or u32(head, 0x20) == ns + npz + 1: hdr_ok += 1
        other.setdefault("rows", []).append((name, ns, npz, u32(head, 0x20)))
    elif k[:4] == b"FORM":
        iff_n += 1
        form_len = struct.unpack(">I", head[4:8])[0]
        d = size - (form_len + 8); diffs[d] = diffs.get(d, 0) + 1
print("B4  3X/ESI-32 banks: %d" % n3x)
print("B5    size in blocks (ceil(file size/512)) equals header total_blocks (0x48): %d of %d" % (tot_ok, n3x))
print("B6    sample address table @0x1bd2 starts at 0x400000 and rises strictly: %d of %d" % (tab_s_ok, n3x))
print("B7    header 'objects' (0x20) equals sample count + preset count (+0/+1) from the tables: %d of %d" % (hdr_ok, n3x))
for r in other.get("rows", [])[:5]: print("B8      e.g. %-34s samples(table)=%d presets(table)=%d objects=%d" % r)
print("B9  IFF (E4B0) files: %d ; computed file size minus (8 + FORM length): %s" % (iff_n, dict(sorted(diffs.items()))))
print("\n## Block 'bytes in last block' sanity")
bad = [b for b in banks if b[3] > cb or b[4] > 512]
print("S1  files with blocks > cluster size or bytes > 512: %d" % len(bad))
