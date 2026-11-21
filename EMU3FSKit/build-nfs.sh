#!/bin/bash
# Builds emu3nfs: mounts an EOS image as a volume through macOS's own NFS client (no FUSE needed).
set -e
cd "$(dirname "$0")"
A=../EMU3DiskManager/EMU3DiskManager
clang -fobjc-arc -O2 -framework Foundation emu3nfs.m $A/EMU3Filesystem.m $A/EMU3Directory.m $A/EMU3File.m -I$A -o emu3nfs
echo "Built: $(pwd)/emu3nfs"
