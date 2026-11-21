# EMU3 Disk Manager

A macOS app for E-mu Emulator III / IV / ESI-32 sampler disks. It browses and edits the `.hda` and `.iso`
disk images of an E-mu EOS sampler (E64, E6400 and relatives), and it can serve an image to the sampler live over
USB with a BlueSCSI board, so the sampler sees the image as its hard disk and the Mac can keep editing it.

Free software under the GNU General Public License, version 3. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).

## What it does

- Browse, copy, move, rename and delete banks and folders inside EOS disk images.
- Export samples as WAV files and import banks.
- Serve an image to the sampler over USB (Sampler Link) with a card-less BlueSCSI Pico board, and tell the
  sampler to rescan when the Mac changes the disk.
- Mount every image as a volume in Finder under `~/EMU3 Disks` (no FUSE needed; macOS's own NFS client is used).
- Update the board firmware from the app; create, check and format SD cards.

## Parts

| Folder | What |
| --- | --- |
| `EMU3DiskManager/` | The app (Objective-C, AppKit). Xcode project, sources, built-in Help. |
| `EMU3FSKit/emu3nfs.m` | Volume helper: a small NFSv3 server on localhost that macOS mounts. |
| `EMU3FSKit/linkd/` | `emu3linkd`, the login helper: serves the sampler disk and mounts images. |
| `EMU3FSKit/automount/` | The installer (`build-pkg.sh`), login agent and uninstaller. |
| `EMU3FSKit/nfsproto/` | The small read-only NFS prototype this grew from. |
| `firmware/` | Patch against BlueSCSI v2 that adds the USB disk link (card-less operation). |

## Build

Requires macOS 12 or later and Xcode.

```bash
# the app
cd EMU3DiskManager && xcodebuild -project EMU3DiskManager.xcodeproj -scheme EMU3DiskManager -configuration Release build

# the installer (builds the helpers, then packages the app from Xcode's build folder)
cd EMU3FSKit/automount && ./build-pkg.sh
```

The firmware is built separately, see [firmware/README.md](firmware/README.md). `build-pkg.sh` expects the
resulting `BlueSCSI_USB.uf2` through the `FIRMWARE_UF2` environment variable; without it the installer is built without the
firmware file.

## Documentation

The app's Help (Help menu) describes every function. The notes on the disk format and how each part was observed
on real disks are in [EMU3DiskManager/docs/provenance](EMU3DiskManager/docs/provenance/PROVENANCE.md).

## License and credits

GPLv3. Based on the work of dagargo (emu3fs, emu3bm) and the BlueSCSI project. E-mu, Emulator and EOS are
trademarks of their owners; this project is independent and not affiliated with them.
