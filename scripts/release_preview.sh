#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/Haloscope.xcodeproj"
SCHEME="HaloscopePreview"
OUTPUT="$ROOT/dist"
RELEASE_TAG="${HALOSCOPE_PREVIEW_TAG:-}"

usage() {
  cat <<'EOF'
Usage: scripts/release_preview.sh --tag vX.Y.Z-preview.N

Builds the isolated Haloscope Unsigned Preview channel into dist/.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { echo "Missing value for --tag" >&2; exit 2; }
      RELEASE_TAG="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Invalid Preview tag: $RELEASE_TAG" >&2
  exit 2
}
[[ "$RELEASE_TAG" == *preview* ]] || {
  echo "Preview tags must contain 'preview': $RELEASE_TAG" >&2
  exit 2
}
VERSION="${RELEASE_TAG#v}"

"$ROOT/scripts/validate_preview_target.sh"

BUILD_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/haloscope-preview-build.XXXXXX")"
ROOT_REAL="$(cd "$ROOT" && /bin/pwd -P)"
BUILD_REAL="$(cd "$BUILD_ROOT" && /bin/pwd -P)"
case "$BUILD_REAL" in
  "$ROOT_REAL"|"$ROOT_REAL"/*) echo "Preview build directory must be outside the repository." >&2; exit 1 ;;
esac
PRODUCTS_PATH="$BUILD_ROOT/products"
DMG_STAGE="$BUILD_ROOT/dmg-stage"
UNPACK_PATH="$BUILD_ROOT/unpacked"
APP_PATH="$PRODUCTS_PATH/Haloscope Preview.app"
mkdir -p "$PRODUCTS_PATH" "$OUTPUT"

cleanup() { /bin/rm -rf "$BUILD_ROOT"; }
trap cleanup EXIT

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  CONFIGURATION_BUILD_DIR="$PRODUCTS_PATH" \
  DWARF_DSYM_FOLDER_PATH="$PRODUCTS_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION=1 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  build

[[ -d "$APP_PATH" ]] || { echo "Expected product not found: $APP_PATH" >&2; exit 1; }
[[ "${APP_PATH:t}" == "Haloscope Preview.app" ]] || { echo "Unexpected Preview product name." >&2; exit 1; }
[[ ! -d "$APP_PATH/Contents/PlugIns" ]] || { echo "Preview contains Contents/PlugIns." >&2; exit 1; }
[[ -z "$(find "$APP_PATH" -type d -name '*.appex' -print -quit)" ]] || { echo "Preview contains an appex." >&2; exit 1; }

executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")
/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/$executable_name" | grep -q arm64
/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/$executable_name" | grep -q x86_64

# There are no nested bundles today. If one is introduced, --deep signs its
# nested code before the outer bundle; the final strict verification below
# still rejects an incomplete or restricted signature.
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_NAME="Haloscope-${VERSION}-macos-universal-unsigned.zip"
DMG_NAME="Haloscope-${VERSION}-macos-universal-unsigned.dmg"
DSYM_NAME="Haloscope-${VERSION}-macos-universal.dSYM.zip"
CHECKSUM_NAME="Haloscope-${VERSION}-SHA256SUMS.txt"
ZIP_PATH="$OUTPUT/$ZIP_NAME"
DMG_PATH="$OUTPUT/$DMG_NAME"
DSYM_PATH="$OUTPUT/$DSYM_NAME"
CHECKSUM_PATH="$OUTPUT/$CHECKSUM_NAME"
/bin/rm -f "$ZIP_PATH" "$DMG_PATH" "$DSYM_PATH" "$CHECKSUM_PATH"

/usr/bin/ditto --norsrc -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
/bin/mkdir -p "$DMG_STAGE"
/bin/cp -R "$APP_PATH" "$DMG_STAGE/Haloscope Preview.app"
/bin/ln -s /Applications "$DMG_STAGE/Applications"
/bin/cp "$ROOT/Packaging/Preview-README-FIRST.txt" "$DMG_STAGE/README-FIRST.txt"
/usr/bin/hdiutil create \
  -volname "Haloscope Preview $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

DSYM_SOURCE="$PRODUCTS_PATH/Haloscope Preview.app.dSYM"
if [[ -d "$DSYM_SOURCE" ]]; then
  /usr/bin/ditto --norsrc -c -k --keepParent "$DSYM_SOURCE" "$DSYM_PATH"
else
  echo "Warning: Xcode did not produce a dSYM archive." >&2
fi

(
  cd "$OUTPUT"
  targets=("$ZIP_NAME" "$DMG_NAME")
  [[ -f "$DSYM_NAME" ]] && targets+=("$DSYM_NAME")
  /usr/bin/shasum -a 256 "${targets[@]}" > "$CHECKSUM_NAME"
)

validation_args=(
  --app "$APP_PATH"
  --zip "$ZIP_PATH"
  --dmg "$DMG_PATH"
  --checksums "$CHECKSUM_PATH"
  --version "$VERSION"
)
[[ -f "$DSYM_PATH" ]] && validation_args+=(--dsym "$DSYM_PATH")
"$ROOT/scripts/validate_preview_artifacts.sh" "${validation_args[@]}"

# Independently unpack the final ZIP and run the same bundle checks against the
# unpacked app, so the archive itself—not just the build directory—is covered.
/bin/mkdir -p "$UNPACK_PATH"
/usr/bin/unzip -q "$ZIP_PATH" -d "$UNPACK_PATH"
unpack_args=(
  --app "$UNPACK_PATH/Haloscope Preview.app"
  --zip "$ZIP_PATH"
  --dmg "$DMG_PATH"
  --checksums "$CHECKSUM_PATH"
  --version "$VERSION"
)
[[ -f "$DSYM_PATH" ]] && unpack_args+=(--dsym "$DSYM_PATH")
"$ROOT/scripts/validate_preview_artifacts.sh" "${unpack_args[@]}"

echo "Unsigned Preview assets:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
[[ -f "$DSYM_PATH" ]] && echo "  $DSYM_PATH"
echo "  $CHECKSUM_PATH"
