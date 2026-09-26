#!/bin/bash
# Builds dist/Ganttpath.app on a Mac (Xcode 27 / Swift 6.4 or later, macOS 27).
#
#   Packaging/build-app.sh [--mpxj /path/to/mpxj-convert]
#
# --mpxj  bundles the MPXJ .mpp reader (the GraalVM binary of the JavaScript app's vendor/mppjs-darwin-arm64/bin) so .mpp files
#         open directly. Without it, MS Project files are opened after saving them as XML in MS Project.
set -euo pipefail
cd "$(dirname "$0")/.."
MPXJ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mpxj) MPXJ="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done

swift build -c release --product Ganttpath
BIN="$(swift build -c release --show-bin-path)/Ganttpath"
VERSION=$(grep -o 'APP_VERSION = "[^"]*"' Sources/GanttpathCore/Files.swift | cut -d'"' -f2)

APP=dist/Ganttpath.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ganttpath"
cp Packaging/Ganttpath.icns "$APP/Contents/Resources/Ganttpath.icns"
if [ -n "$MPXJ" ]; then
  mkdir -p "$APP/Contents/Resources/bin"
  cp "$MPXJ" "$APP/Contents/Resources/bin/mpxj-convert"
  chmod 755 "$APP/Contents/Resources/bin/mpxj-convert"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ganttpath</string>
  <key>CFBundleDisplayName</key><string>Ganttpath</string>
  <key>CFBundleIdentifier</key><string>app.ganttpath.desktop</string>
  <key>CFBundleExecutable</key><string>Ganttpath</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Ganttpath.icns</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Ganttpath - for personal use.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Ganttpath project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.ganttpath.project</string></array>
      <key>CFBundleTypeIconFile</key><string>Ganttpath.icns</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Microsoft Project file</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>mpp</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.ganttpath.project</string>
      <key>UTTypeDescription</key><string>Ganttpath project</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string><string>public.data</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>gpath</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# ad-hoc signature (the bundled mpxj-convert keeps its own signature)
codesign --force --sign - "$APP/Contents/MacOS/Ganttpath"
codesign --force --sign - "$APP"
(cd dist && ditto -c -k --keepParent Ganttpath.app "Ganttpath-${VERSION}-mac.zip")
echo "Built $APP (version $VERSION)"
