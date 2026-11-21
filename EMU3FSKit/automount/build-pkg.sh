#!/bin/bash
# Builds EMU3DiskManager.pkg: the app, the emu3nfs volume helper and the login auto-mount agent.
set -e
cd "$(dirname "$0")"
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/EMU3DiskManager-*/Build/Products/Release/EMU3DiskManager.app | head -1)
R=pkg/root
../build-nfs.sh >/dev/null
cp ../emu3nfs "$R/Library/Application Support/EMU3/emu3nfs"
(cd ../linkd && clang -fobjc-arc -O1 -framework Foundation EMU3LinkEngine.m main.m -o emu3linkd)
cp ../linkd/emu3linkd "$R/Library/Application Support/EMU3/emu3linkd"
# FIRMWARE_UF2: path of the BlueSCSI_USB.uf2 you built from firmware/usb-block-link.patch (optional)
FW="${FIRMWARE_UF2:-}"
[ -n "$FW" ] && [ -f "$FW" ] && cp "$FW" "$R/Library/Application Support/EMU3/BlueSCSI-firmware.uf2"
cp Uninstall-EMU3.command "$R/Library/Application Support/EMU3/Uninstall-EMU3.command"
cp ../../LICENSE "$R/Library/Application Support/EMU3/LICENSE"
cp ../../CREDITS.md "$R/Library/Application Support/EMU3/CREDITS.md"
chmod 755 "$R/Library/Application Support/EMU3/"*
mkdir -p "$R/Applications"; rm -rf "$R/Applications/EMU3DiskManager.app"; cp -R "$APP" "$R/Applications/"
pkgbuild --root "$R" --scripts pkg/scripts --identifier com.emu3.diskmanager --version 1.1 \
  --install-location / EMU3DiskManager-component.pkg
# optional second package: removes leftovers of older installs (no payload, script only)
pkgbuild --nopayload --scripts pkg/cleanup-scripts --identifier com.emu3.cleanup --version 1.1 EMU3Cleanup-component.pkg
cat > pkg/distribution.xml <<D
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
<title>EMU3 Disk Manager</title>
<welcome file="welcome.html"/>
<options customize="allow" require-scripts="false" hostArchitectures="arm64,x86_64"/>
<choices-outline>
  <line choice="main"/>
  <line choice="cleanup"/>
</choices-outline>
<choice id="main" title="EMU3 Disk Manager, sampler helper and login agent"
  description="The app, the background helper (emu3linkd: serves the sampler disk and auto-mounts images), the volume helper (emu3nfs), the board firmware file and the uninstaller."
  start_enabled="false" start_selected="true"><pkg-ref id="com.emu3.diskmanager"/></choice>
<choice id="cleanup" title="Remove old installs"
  description="Removes leftovers of earlier versions: the old per-user login agent, per-user helper copies, the old Python agent and older app copies. Your images and settings are kept."
  start_selected="true"><pkg-ref id="com.emu3.cleanup"/></choice>
<pkg-ref id="com.emu3.diskmanager" version="1.1">EMU3DiskManager-component.pkg</pkg-ref>
<pkg-ref id="com.emu3.cleanup" version="1.1">EMU3Cleanup-component.pkg</pkg-ref>
</installer-gui-script>
D
mkdir -p pkg/res
cat > pkg/res/welcome.html <<D
<html><body style="font-family:-apple-system;font-size:12px"><h2 style="margin:0 0 6px">EMU3 Disk Manager</h2>
<ul style="margin:0 0 0 -18px">
<li>Browse, copy, move, rename and delete banks and folders on E-mu EOS disk images</li>
<li>Export samples as WAV files and import banks</li>
<li>Serve an image to the sampler over USB with a card-less BlueSCSI board</li>
<li>Mount every image as a volume in Finder, started at login</li>
<li>Update the board firmware, and create, check or format SD cards</li>
</ul></body></html>
D
productbuild --distribution pkg/distribution.xml --resources pkg/res --package-path . EMU3DiskManager.pkg
rm -f EMU3DiskManager-component.pkg EMU3Cleanup-component.pkg
echo "Built: $(pwd)/EMU3DiskManager.pkg"
