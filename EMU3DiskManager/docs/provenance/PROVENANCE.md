# Provenance of the E-mu EOS format knowledge

**Purpose.** This app's E-mu disk and bank code was originally modelled on dagargo's emu3fs and emu3bm (GPLv3).
This file records, item by item, what the format facts are and how each one can be (re)derived from **real disks
alone**, so that the affected code can be rewritten without looking at that source. It is the evidence trail for
such a rewrite. It is a work list, not a legal opinion.

**Method.**

1. [`probe.py`](probe.py) is an independent reader (about 150 lines, shares no code with the app and none with
   dagargo). It opens a disk image read only and prints what is stored in it. Every line can be checked with a hex
   editor. Run: `python3 -I probe.py IMAGE.hda`.
2. [`probe-output-HD20_14GB.txt`](probe-output-HD20_14GB.txt) is its output for the 14 GB sampler-formatted image
   `HD20_14GB.hda` (21 Nov 2026). The evidence IDs below (O1, G1, F1, D1, B1 ...) are the line labels in that file.
3. Rewrite rule: write the new code from this table and the probe only. Use your own names, structure and
   comments. Nobody who has read the dagargo sources should write the new code.
4. Add disks to widen the evidence. Each "not observed" row says which disk would settle it.

Legend: **Observed** = the probe confirms it on the 14 GB image. **Measured** = confirmed on the sampler itself
(your notes, `memory/emu3-sampler-verified.md`) but not re-checkable from this image. **Open** = not observable on
the available disks.

## A. File system

| ID | Item | Value | Evidence | Status | Notes for the rewrite |
| --- | --- | --- | --- | --- | --- |
| FS-1 | Signature | bytes 0..3 = `EMU3` | O1 | Observed | |
| FS-2 | Dword at 0x04 | 29360127 = number of 512-byte blocks minus 1 | O2, header line | Observed | |
| FS-3 | Root directory | dword 0x08 = start block (9), dword 0x0c = block count (7) | O2, G1, D1 (all 292 files found by walking these blocks) | Observed | |
| FS-4 | Folder pool | dword 0x10 = first block (16), dword 0x14 = count (217); every folder block number seen lies inside it and it ends just before the data area | O2, G2, D2 | Observed | |
| FS-5 | Allocation table (FAT) | dword 0x18 = start block (2), dword 0x1c = block count (7); 7 x 256 entries cover clusters 0..1791 | O2, G3, F1 | Observed | |
| FS-6 | Data area | dword 0x20 = first block (233); cluster *c* starts at block 233 + (c-1) x cluster size | O2, G4, B1 (files read this way start with the expected bank signatures) | Observed | |
| FS-7 | Highest cluster number | dword 0x24 = 1791 | O2, G4, G6 (1791.99 clusters fit between the data area and the end of the file) | Observed | |
| FS-8 | Cluster size | low byte of dword 0x28 = 8, cluster = 64 << 8 = 16384 blocks = 8 MB | G5, G6 | Observed for 14 GB. Measured for 1 GB (shift 5) and 64 MB (shift 1) | Needs those sampler-formatted images to re-observe |
| FS-9 | Dwords 0x2c (2048) and 0x30 (0x0d010000) | role unknown | O2 | Open | Not needed by the app; copy them unchanged when formatting |
| FS-10 | FAT entries | 16-bit little endian; 0x0000 free; 0x7fff end of chain; entry 0 = 0x8000; other values = next cluster | F1 (1380 free, 292 chains end, 1 reserved), F2 | Observed | 0x8000 appears only in entry 0 on this disk |
| FS-11 | File chain | a file's first cluster is in its directory entry; following the FAT gives exactly "clusters" entries | D4 (292 of 292 files) | Observed | |
| FS-12 | Directory entry | 32 bytes: name (16, space padded), 1 unknown byte, 1 id byte, 14 bytes of attributes; 16 entries per block | D1, D2 | Observed | |
| FS-13 | File attributes | start cluster, cluster count, blocks used in the last cluster, bytes used in the last block (all 16-bit), type byte, 5 property bytes | D1, S1 (no value out of range) | Observed | |
| FS-14 | File size | (clusters-1) x cluster size + (blocks-1) x 512 + bytes | D1; B9 (for all 200 IFF banks the result is exactly 4 bytes more than the container's own length field + 8, a constant) | Observed | The constant 4 is real: keep it |
| FS-15 | File type byte | 0x81 on all 292 files | D3 | Observed for 0x81. Open for 0x80 (system) and 0x83 (updated) | Needs a disk with ROM/system files or a recently deleted file |
| FS-16 | Property bytes | `00 45 34 42 30` (a zero byte and `E4B0`) on all 292 files | D1 | Observed | |
| FS-17 | Folder entry | id byte 0x80 (8 folders) or 0x40 (1 folder, the root-level one); attributes are 7 signed 16-bit block numbers, unused = -1 | D2, D3 | Observed | |
| FS-18 | File ids inside a folder | run 0,1,2,... in entry order | D1 | Observed | |
| FS-19 | 7 blocks per folder, 16 entries per block, 112 files per folder | structure of FS-12 and FS-17 | D2 | Observed (the limit of 112 follows; not filled on this disk) | |
| FS-20 | Formatting a blank image (sizes, empty root, pool, FAT) | the layout the sampler writes | none from the probe | Measured on the sampler (1 GB, 14 GB; own work in `formatWithError`) | Independent of dagargo; keep as is |

## B. Banks

| ID | Item | Value | Evidence | Status | Notes for the rewrite |
| --- | --- | --- | --- | --- | --- |
| BK-1 | Bank kind at offset 0 (16 bytes) | `EMULATOR 3X` + spaces, `EMU SI-32 v3` + spaces, or an IFF container (`FORM`, length, `E4B0`, first chunk `TOC1`) | B1 | Observed (90 banks of the first two kinds, 200 IFF banks) | |
| BK-2 | `EMULATOR THREE` banks | name string and the offsets 0x6c / 0x204 / 0x74a | none | **Open**: no such bank on this disk | Either find a real Emulator III disk, or drop the code path (the app reports "unknown" for them) |
| BK-3 | Bank name | 16 bytes at offset 0x10 | B2 | Observed | |
| BK-4 | Sample address table (3X / SI-32) | 32-bit little endian values starting at offset 0x1bd2; first value 0x00400000; values rise strictly; the first zero ends the list | B3, B6 (90 of 90 banks) | Observed | The 0x400000 base is the first table value, observable directly |
| BK-5 | Preset table (3X / SI-32) | 32-bit values from offset 0x17ca, rising offsets (0, 0x286, 0x50c, ...) | B3 | Observed (the app's counting rule, "stop at a repeat or zero", is the app's own) | Verify the rule against a bank whose preset count is known |
| BK-6 | Table capacities | the sample table spans 0x1bd2..0x2b72 = 4000 bytes = 1000 entries (999 + end); the preset table spans 0x17ca..0x1bd2 = 1032 bytes = 258 entries (256 + 2) | derived from the offsets | Observed (arithmetic) | Not directly proven as limits |
| BK-7 | Start of the preset data | offset 0x2b72 | B3 | Observed as the end of the sample table; not used by the app | |
| BK-8 | Sample header | a sample header holds the 16-byte name and then the number 92 (its own length) at offset 20; sample rate (e.g. 20000), a 16-bit options word (0x39 seen) follow at fixed offsets | scan of "Orbit Instrmt" (first headers at bank offsets 0x1f5c5, 0x20b5f, 0x2110b) | Partly observed | Used only by the sample export; extend the probe before rewriting that code |
| BK-9 | Header `total_blocks` (0x48) | equals ceil(file size / 512) for 49 of 90 banks | B5 | **Not reliable**: 41 banks differ | Do not use it |
| BK-10 | Header `objects` (0x20) | does not equal the table counts (4 of 90) | B7, B8 | Meaning unknown | Do not use it |
| BK-11 | Other header fields (0x30 .. 0x6c) | numbers whose meaning is not established | B2 | Open | Not used by the app |

## C. What the app actually uses

Counted in the sources on 21 Nov 2026:

- **Used:** the signature, FS-2 .. FS-19, the bank kinds, the bank name offset, and the two 3X table offsets (plus
  the three `EMULATOR THREE` offsets, BK-2).
- **Never used (dead code), delete instead of re-deriving:** the preset-header, envelope and sample-header
  structures, the note-zone, option-flag and memory-size constants, and the `EMULATOR THREE` and ESI maximums:
  `emu3_preset_header_t`, `emu3_envelope_t`, `emu3_sample_header_t`, `EMU3_NOTES`, `EMU3_MEM_SIZE`, `SAMPLE_OFFSET`,
  `EMU3_SAMPLE_OPT_*`, `EMU3_MAX_*`, `EMU3_PRESET_START_*`, `EMU3_BANK_SIZE`, `EMU3_DIRBLOCK_NONE`. Zero references
  outside `EMU3Types.h`.

So the part that is currently dagargo-shaped and still live is small: the directory/file attribute structures,
the bank header name offset and the two 3X table offsets. Everything else in the original header can simply go.

## D. Rewrite plan

1. Delete the dead items in section C.
2. Replace the file and folder attribute structures with the layout in FS-12/FS-13/FS-17, in your own names. The
   byte positions are in the probe; no struct needs to be copied, offsets are enough.
3. Replace the bank header struct with two constants: format string at 0, name at 0x10 (BK-1, BK-3).
4. Keep the 3X table offsets (BK-4, BK-5) as plain constants with the probe evidence as the source. They are
   observable facts (numbers) and are checked on 90 banks.
5. Decide on BK-2: find an Emulator III disk to observe, or remove the path.
6. Fix the wrong comment in `EMU3Types.h` ("28 bytes": the entry is 32).
7. Remove "Based on dagargo/emu3fs and dagargo/emu3bm" from the header comment and the About box only when steps
   1 to 5 are done and reviewed; keep the CREDITS entry for the firmware (BlueSCSI, GPLv3), which stays.
8. Re-run `probe.py` on every disk you have (1 GB, 64 MB, an Emulator III disk) and add the outputs to this folder.
