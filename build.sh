#!/bin/sh
# Builds "Worktree Cleaner.app" into build/. Uses Xcode's toolchain when Xcode is installed,
# because the Command Line Tools' swift-package on this Mac fails to load (a library mismatch).
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift build -c release
bin="$(xcrun swift build -c release --show-bin-path)/WorktreeCleaner"
app="build/Worktree Cleaner.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/WorktreeCleaner"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Worktree Cleaner</string>
  <key>CFBundleDisplayName</key><string>Worktree Cleaner</string>
  <key>CFBundleIdentifier</key><string>local.worktree-cleaner.app</string>
  <key>CFBundleExecutable</key><string>WorktreeCleaner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signature: enough for a local app; not for distribution.
codesign --force --sign - "$app"
echo "Built $(pwd)/$app"
