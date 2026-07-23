#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_ROOT="${TMPDIR:-/tmp}/haloscope-build-${UID}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
BUILD_OUTPUT="$BUILD_ROOT/ReleaseProducts"
OUTPUT="$ROOT/dist"
BUILT_APP="$BUILD_OUTPUT/Haloscope.app"
ARCHIVE="$OUTPUT/Haloscope.zip"
TEMP_ARCHIVE="$BUILD_ROOT/Haloscope.zip"

/bin/mkdir -p "$OUTPUT"
# Building inside a File Provider-managed Documents directory can attach Finder
# metadata to the widget bundle and invalidate its nested signature. Keep the
# app and archive work in TMPDIR; only copy the finished ZIP into dist.
/bin/rm -rf \
  "$ARCHIVE" \
  "$TEMP_ARCHIVE" \
  "$BUILD_OUTPUT"
/bin/mkdir -p "$BUILD_OUTPUT"

cd "$ROOT"

build_args=(
  -project Haloscope.xcodeproj
  -scheme Haloscope
  -configuration Release
  -derivedDataPath "$DERIVED_DATA"
  CONFIGURATION_BUILD_DIR="$BUILD_OUTPUT"
)

if [[ -n "${HALOSCOPE_DEVELOPMENT_TEAM:-}" ]]; then
  build_args+=(DEVELOPMENT_TEAM="$HALOSCOPE_DEVELOPMENT_TEAM")
fi
if [[ -n "${HALOSCOPE_APP_BUNDLE_IDENTIFIER:-}" ]]; then
  build_args+=(HALOSCOPE_APP_BUNDLE_IDENTIFIER="$HALOSCOPE_APP_BUNDLE_IDENTIFIER")
fi
if [[ -n "${HALOSCOPE_WIDGET_BUNDLE_IDENTIFIER:-}" ]]; then
  build_args+=(HALOSCOPE_WIDGET_BUNDLE_IDENTIFIER="$HALOSCOPE_WIDGET_BUNDLE_IDENTIFIER")
fi
if [[ -n "${HALOSCOPE_APP_GROUP_IDENTIFIER:-}" ]]; then
  build_args+=(HALOSCOPE_APP_GROUP_IDENTIFIER="$HALOSCOPE_APP_GROUP_IDENTIFIER")
fi
if [[ -n "${HALOSCOPE_KEYCHAIN_GROUP_SUFFIX:-}" ]]; then
  build_args+=(HALOSCOPE_KEYCHAIN_GROUP_SUFFIX="$HALOSCOPE_KEYCHAIN_GROUP_SUFFIX")
fi

if [[ "${UNSIGNED:-0}" == "1" ]]; then
  build_args+=(CODE_SIGNING_ALLOWED=NO)
else
  build_args+=(-allowProvisioningUpdates)
fi

/usr/bin/xcodebuild "${build_args[@]}" build

if [[ "${UNSIGNED:-0}" != "1" ]]; then
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
fi

/usr/bin/ditto -c -k --keepParent "$BUILT_APP" "$TEMP_ARCHIVE"
/bin/cp "$TEMP_ARCHIVE" "$ARCHIVE"

echo "$ARCHIVE"
