#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=Shade.app
VERSION=${VERSION:-1.0}
rm -rf $APP
mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 main.swift -o $APP/Contents/MacOS/Shade
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Shade</string>
  <key>CFBundleIdentifier</key><string>local.shade</string>
  <key>CFBundleExecutable</key><string>Shade</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Sign with a Developer ID certificate when there is one, so the app keeps its identity
# (and its Accessibility permission) across builds; otherwise fall back to ad-hoc.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
if [[ -n $IDENTITY ]]; then
  codesign --force --options runtime --timestamp -s "$IDENTITY" $APP
  echo "Signed with $IDENTITY"
else
  codesign --force -s - $APP
  echo "No Developer ID certificate found; signed ad-hoc"
fi
echo "Built $PWD/$APP"
