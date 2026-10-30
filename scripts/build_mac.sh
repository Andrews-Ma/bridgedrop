#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
swift build -c release --arch arm64 --product BridgeDrop -Xswiftc -gnone -Xswiftc -file-prefix-map -Xswiftc "$task_root=."
task_bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"
task_app="${BRIDGEDROP_OUTPUT_APP:-$task_root/outputs/BridgeDrop-Mac-v1.3.0/轻传.app}"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin_dir/BridgeDrop" "$task_app/Contents/MacOS/BridgeDrop"
cp "$task_root/assets/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
cp "$task_root/assets/mac-icon.png" "$task_app/Contents/Resources/BrandIcon.png"
for task_language in en zh-Hans; do
    mkdir -p "$task_app/Contents/Resources/$task_language.lproj"
    cp "$task_root/config/$task_language.lproj/InfoPlist.strings" "$task_app/Contents/Resources/$task_language.lproj/InfoPlist.strings"
done
cp "$task_root/config/Mac-Info.plist" "$task_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable BridgeDrop' "$task_app/Contents/Info.plist"
codesign --force --sign "${BRIDGEDROP_SIGNING_IDENTITY:--}" --entitlements "$task_root/config/Mac.entitlements" "$task_app"
codesign --verify --deep --strict "$task_app"
printf '%s\n' "Mac app ready: $task_app"
