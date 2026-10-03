#!/bin/sh
# Builds and signs "QMI Darwin.app" (host app + qmid + qmictl + the daemon plist) in .build/.
# Runs as the user; no root. Install by copying the app to /Applications and opening it.
#
#   scripts/build-app.sh                  sign with the first Apple Development identity
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#
# Version: the VERSION file (bump it for every build you install; see docs/BUILDING.md).
# VERSION=x.y.z in the environment overrides it for experiments.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/.build/QMI Darwin.app"
version=${VERSION:-$(tr -d ' \n' < "$root/VERSION")}
[ -n "$version" ] || { echo "empty VERSION" >&2; exit 1; }
# Unique per build, so the app can tell that the running qmid is older than the installed one.
build=${BUILD:-$(date +%Y%m%d%H%M%S)}
identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}
[ -n "$identity" ] || { echo "no code signing identity found" >&2; exit 1; }

swift build --package-path "$root" -c release --product qmid
swift build --package-path "$root" -c release --product qmictl
swift build --package-path "$root" -c release --product QMIDarwinApp
bin=$(swift build --package-path "$root" -c release --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchDaemons"
cp "$bin/QMIDarwinApp" "$app/Contents/MacOS/QMI Darwin"
cp "$bin/qmid" "$bin/qmictl" "$app/Contents/MacOS/"
cp "$root/launchd/com.qmi-darwin.qmid.plist" "$app/Contents/Library/LaunchDaemons/"
# The comment in the source plist isn't needed at runtime; lint to be sure it parses.
plutil -lint -s "$app/Contents/Library/LaunchDaemons/com.qmi-darwin.qmid.plist"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.qmi-darwin.app</string>
    <key>CFBundleName</key><string>QMI Darwin</string>
    <key>CFBundleDisplayName</key><string>QMI Darwin</string>
    <key>CFBundleExecutable</key><string>QMI Darwin</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Inner binaries first, then the bundle. Hardened runtime everywhere (needed for notarization).
codesign --force --options runtime --timestamp=none -s "$identity" -i com.qmi-darwin.qmid "$app/Contents/MacOS/qmid"
codesign --force --options runtime --timestamp=none -s "$identity" -i com.qmi-darwin.qmictl "$app/Contents/MacOS/qmictl"
codesign --force --options runtime --timestamp=none -s "$identity" "$app"
codesign --verify --strict --deep "$app"

echo "built $app ($version, build $build)"
echo "signed by: $identity"
