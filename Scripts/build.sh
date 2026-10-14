#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --build-system native -debug-info-format none -c release --arch arm64
bin="$(swift build --disable-sandbox --build-system native -debug-info-format none -c release --arch arm64 --show-bin-path)"
app="$PWD/dist/Auto Fan Control.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchDaemons" "$app/Contents/Resources"
cp "$bin/AutoFanControl" "$app/Contents/MacOS/AutoFanControl"
cp "$bin/FanHelper" "$app/Contents/MacOS/FanHelper"
cp "$bin/fanctl" "$app/Contents/MacOS/fanctl"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/local.autofancontrol.helper.plist "$app/Contents/Library/LaunchDaemons/"
identity="${SIGNING_IDENTITY:--}"
codesign --force --options runtime --sign "$identity" --identifier local.autofancontrol.helper "$app/Contents/MacOS/FanHelper"
codesign --force --options runtime --sign "$identity" --identifier local.autofancontrol.cli "$app/Contents/MacOS/fanctl"
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
print "Built: $app"
if [[ "$identity" == "-" ]]; then
    print "Ad-hoc build: settings and preview work; the authenticated privileged helper requires an Apple-issued signing identity."
fi
