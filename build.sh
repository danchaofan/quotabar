#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${QUOTABAR_OUTPUT_DIR:-$project_dir/dist}"
app_dir="$output_dir/额度看板.app"
build_dir="${QUOTABAR_BUILD_DIR:-$project_dir/.build}"
mkdir -p "$build_dir/module-cache" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
build_dir="$(cd "$build_dir" && pwd)"
xcrun swiftc "${QUOTABAR_OPTIMIZATION:--O}" -whole-module-optimization -parse-as-library -module-cache-path "$build_dir/module-cache" \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement -framework UserNotifications \
  -lsqlite3 "$project_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/QuotaBar"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
if [ ! -f "$project_dir/AppIcon.icns" ]; then
  xcrun swift -module-cache-path "$build_dir/module-cache" "$project_dir/MakeIcon.swift" "$build_dir/AppIcon.iconset" "$project_dir/AppIcon.icns"
fi
if [ -f "$project_dir/AppIcon.icns" ]; then cp "$project_dir/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - --identifier com.local.QuotaBar "$app_dir"
echo "已构建：$app_dir"
