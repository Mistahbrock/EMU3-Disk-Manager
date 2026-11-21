#!/bin/bash
# Removes EMU3 Disk Manager, the emu3nfs helper and the login auto-mount agent.
# Your disk images (~/EMU3 Images or your chosen image folder) are NOT touched.
echo "This removes EMU3 Disk Manager, its helper and the auto-mount agent."
echo "Your disk images are kept."
read -p "Continue? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || exit 0
sudo -v || exit 1
U=$(id -u)
# stop the agent (per-user and system-wide copies) and unmount the volumes it made
launchctl bootout gui/$U /Library/LaunchAgents/com.emu3.automount.plist 2>/dev/null
launchctl bootout gui/$U "$HOME/Library/LaunchAgents/com.emu3.automount.plist" 2>/dev/null
pkill -x EMU3DiskManager 2>/dev/null
for mp in "$HOME/EMU3 Disks"/*; do
  [ -d "$mp" ] || continue
  /sbin/umount "$mp" 2>/dev/null || diskutil unmount force "$mp" >/dev/null 2>&1
  rmdir "$mp" 2>/dev/null
done
pkill -x emu3nfs 2>/dev/null
rmdir "$HOME/EMU3 Disks" 2>/dev/null
# remove files
rm -f "$HOME/Library/LaunchAgents/com.emu3.automount.plist"
rm -rf "$HOME/Library/Application Support/EMU3"
sudo rm -f /Library/LaunchAgents/com.emu3.automount.plist
sudo rm -rf "/Library/Application Support/EMU3" /Applications/EMU3DiskManager.app
sudo pkgutil --forget com.emu3.diskmanager >/dev/null 2>&1
rm -f /tmp/emu3-automount.log
echo "Done. EMU3 Disk Manager is removed. Your images were not touched."
