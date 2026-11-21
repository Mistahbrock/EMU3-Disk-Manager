# Firmware: USB disk link for BlueSCSI v2

`usb-block-link.patch` is a change to [BlueSCSI v2](https://github.com/BlueSCSI/BlueSCSI-v2) (GPLv3), based on
upstream commit `5e64e3b`. It makes the board work **without an SD card**: the Mac serves a disk image over a USB
link and the board presents it to the sampler on SCSI. It also lets the Mac tell the sampler that the disk changed.

Apply and build (Raspberry Pi Pico 2, Desktop 50-pin board):

```bash
git clone https://github.com/BlueSCSI/BlueSCSI-v2.git
cd BlueSCSI-v2 && git checkout 5e64e3b
git apply ../firmware/usb-block-link.patch
# then build as described in BUILDING.md; the output is build/Pico_2/BlueSCSI_USB.uf2
```

The firmware is distributed under the same license as BlueSCSI v2, GPLv3. This patch is a derivative work and is
released under the GPLv3 as well.
