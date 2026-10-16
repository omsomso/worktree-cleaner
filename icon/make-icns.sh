#!/bin/sh
# Rebuilds Resources/AppIcon.icns from make_icon.swift.
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
tmp=$(mktemp -d)
xcrun swift make_icon.swift "$tmp/icon-1024.png"
set=$tmp/AppIcon.iconset; mkdir "$set"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon-1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d "$tmp/icon-1024.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o ../Resources/AppIcon.icns
cp "$tmp/icon-1024.png" ../Resources/AppIcon-1024.png
rm -rf "$tmp"
echo "Wrote Resources/AppIcon.icns"
