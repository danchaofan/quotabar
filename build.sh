#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${QUOTABAR_OUTPUT_DIR:-$project_dir/dist}"
app_dir="$output_dir/额度看板.app"
build_dir="${QUOTABAR_BUILD_DIR:-$project_dir/.build}"
read -r -a architectures <<< "${QUOTABAR_ARCHS:-$(uname -m)}"
if [ "${#architectures[@]}" -eq 0 ]; then echo "至少需要一种目标架构" >&2; exit 1; fi
for architecture in "${architectures[@]}"; do
  case "$architecture" in arm64|x86_64) ;; *) echo "不支持的架构：$architecture" >&2; exit 1 ;; esac
done
mkdir -p "$build_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
build_dir="$(cd "$build_dir" && pwd)"
binaries=()
for architecture in "${architectures[@]}"; do
  echo "正在构建：$architecture"
  architecture_dir="$build_dir/$architecture"
  mkdir -p "$architecture_dir/module-cache"
  xcrun swiftc "${QUOTABAR_OPTIMIZATION:--O}" -whole-module-optimization -parse-as-library \
    -module-cache-path "$architecture_dir/module-cache" \
    -file-prefix-map "$project_dir=QuotaBar" -debug-prefix-map "$project_dir=QuotaBar" \
    -target "$architecture-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement -framework UserNotifications \
    -lsqlite3 "$project_dir"/Sources/*.swift -o "$architecture_dir/QuotaBar"
  binaries+=("$architecture_dir/QuotaBar")
done
xcrun lipo -create "${binaries[@]}" -output "$app_dir/Contents/MacOS/QuotaBar"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
if [ ! -f "$project_dir/AppIcon.icns" ]; then
  xcrun swift -module-cache-path "$build_dir/$(uname -m)/module-cache" "$project_dir/MakeIcon.swift" "$build_dir/AppIcon.iconset" "$project_dir/AppIcon.icns"
fi
if [ -f "$project_dir/AppIcon.icns" ]; then cp "$project_dir/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - --identifier com.local.QuotaBar "$app_dir"
echo "已构建：$app_dir"
