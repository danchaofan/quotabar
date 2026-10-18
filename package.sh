#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="${QUOTABAR_BUILD_DIR:-$project_dir/.build}"
package_dir="${QUOTABAR_PACKAGE_DIR:-$project_dir/installers}"
mkdir -p "$build_dir" "$package_dir"
build_dir="$(cd "$build_dir" && pwd)"
package_dir="$(cd "$package_dir" && pwd)"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")
case "$version" in ''|*[!0-9.]*) echo "无效的应用版本号" >&2; exit 1 ;; esac
# A fresh staging directory prevents local application files from entering the package.
staging_dir=$(mktemp -d "$build_dir/installer.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
QUOTABAR_ARCHS="arm64 x86_64" QUOTABAR_BUILD_DIR="$build_dir" \
  QUOTABAR_OUTPUT_DIR="$staging_dir/app" bash "$project_dir/build.sh"
app_dir="$staging_dir/app/额度看板.app"
xcrun lipo "$app_dir/Contents/MacOS/QuotaBar" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$app_dir"
"$app_dir/Contents/MacOS/QuotaBar" --self-test
mkdir -p "$staging_dir/payload/Applications" "$staging_dir/packages"
ditto "$app_dir" "$staging_dir/payload/Applications/额度看板.app"
pkgbuild --root "$staging_dir/payload" --install-location / --ownership recommended \
  --identifier com.local.QuotaBar.pkg --version "$version" \
  --component-plist "$project_dir/packaging/Components.plist" \
  "$staging_dir/packages/QuotaBar-component.pkg"
sed "s/@VERSION@/$version/g" "$project_dir/packaging/Distribution.xml" > "$staging_dir/Distribution.xml"
package_name="QuotaBar-$version-universal.pkg"
productbuild --distribution "$staging_dir/Distribution.xml" \
  --resources "$project_dir/packaging/resources" --package-path "$staging_dir/packages" \
  "$staging_dir/$package_name"
cp "$staging_dir/$package_name" "$package_dir/$package_name"
(cd "$package_dir" && LC_ALL=C shasum -a 256 "$package_name" > "$package_name.sha256")
echo "已打包：$package_dir/$package_name"
