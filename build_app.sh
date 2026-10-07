#!/bin/zsh
# Builds PDFsPDFsPDFs.app into dist/ (universal: arm64 + x86_64)
set -e
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
# Output dir differs between toolchains (.build/apple/... vs .build/out/...), so ask SwiftPM.
BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP="dist/PDFsPDFsPDFs.app"
rm -rf "$APP" dist/EasyPDF.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BUILD_DIR/EasyPDF" "$APP/Contents/MacOS/EasyPDF"
if [ -d "$BUILD_DIR/EasyPDF_EasyPDF.bundle" ]; then
  cp -R "$BUILD_DIR/EasyPDF_EasyPDF.bundle" "$APP/Contents/Resources/"
fi
cp Info.plist "$APP/Contents/Info.plist"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Sparkle framework (SPM binary artifact) + rpath so the app finds it.
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/EasyPDF" 2>/dev/null || true
fi

codesign --force --deep -s - "$APP"
echo "Built $APP"
