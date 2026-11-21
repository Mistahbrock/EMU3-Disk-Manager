#!/bin/bash
# Installs the EMU3 auto-mount LaunchAgent (starts at login). Run: ./install.sh   Remove: ./install.sh uninstall
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HOME/Library/Application Support/EMU3"
PLIST="$HOME/Library/LaunchAgents/com.emu3.automount.plist"
UID_=$(id -u)
launchctl bootout gui/$UID_ "$PLIST" 2>/dev/null || true
if [ "$1" = uninstall ]; then rm -f "$PLIST"; echo "Removed. (Files in $BASE kept.)"; exit 0; fi
mkdir -p "$BASE" "$HOME/Library/LaunchAgents"
cp "$HERE/../emu3nfs" "$BASE/emu3nfs"; cp "$HERE/../linkd/emu3linkd" "$BASE/emu3linkd"
chmod +x "$BASE/emu3linkd" "$BASE/emu3nfs"
cat > "$PLIST" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.emu3.automount</string>
<key>ProgramArguments</key><array><string>$BASE/emu3linkd</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardErrorPath</key><string>/tmp/emu3-automount.log</string>
</dict></plist>
P
launchctl bootstrap gui/$UID_ "$PLIST"
echo "Installed. Images in $HOME/EMU3 Images (edit $BASE/watch.txt for more folders) mount under $HOME/EMU3 Disks."
