#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/Haloscope.xcodeproj"
SCHEME="Haloscope"
EXPORT_OPTIONS="$ROOT/Packaging/ExportOptions.plist"
OUTPUT="$ROOT/dist"
UNSIGNED=0
RELEASE_TAG="${HALOSCOPE_RELEASE_TAG:-}"

usage() {
  cat <<'EOF'
Usage: scripts/release_app.sh [--tag vX.Y.Z[-prerelease]] [--unsigned]

Creates GitHub Release assets in dist/.

Distribution mode requires:
  HALOSCOPE_DEVELOPMENT_TEAM
  HALOSCOPE_APP_GROUP_IDENTIFIER
  HALOSCOPE_NOTARY_KEY_PATH + HALOSCOPE_NOTARY_KEY_ID +
    HALOSCOPE_NOTARY_ISSUER_ID
  or HALOSCOPE_NOTARY_PROFILE

Optional:
  HALOSCOPE_KEYCHAIN_GROUP_SUFFIX
  HALOSCOPE_CODE_SIGN_IDENTITY

--unsigned builds clearly labelled CI-only assets and skips signing/notarization.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { echo "Missing value for --tag" >&2; exit 2; }
      RELEASE_TAG="$2"
      shift 2
      ;;
    --unsigned)
      UNSIGNED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

project_version() {
  /usr/bin/awk -F '= ' '
    /MARKETING_VERSION = / {
      gsub(/[;[:space:]]/, "", $2)
      print $2
      exit
    }
  ' "$PROJECT/project.pbxproj"
}

if [[ -z "$RELEASE_TAG" ]]; then
  RELEASE_TAG="v$(project_version)"
fi
if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid release tag: $RELEASE_TAG" >&2
  exit 2
fi

VERSION="${RELEASE_TAG#v}"
ASSET_SUFFIX=""
if (( UNSIGNED )); then
  ASSET_SUFFIX="-unsigned"
else
  APP_MARKETING_VERSION="$(project_version)"
  if [[ "$RELEASE_TAG" != "v$APP_MARKETING_VERSION" &&
        "$RELEASE_TAG" != "v$APP_MARKETING_VERSION-"* ]]; then
    echo "Release tag $RELEASE_TAG does not match app version $APP_MARKETING_VERSION" >&2
    exit 2
  fi
fi

BUILD_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/haloscope-release.XXXXXX")"
ARCHIVE_PATH="$BUILD_ROOT/Haloscope.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
PRODUCTS_PATH="$BUILD_ROOT/products"
DMG_STAGE="$BUILD_ROOT/dmg"
NOTARY_ZIP="$BUILD_ROOT/Haloscope-notarization.zip"
APP_PATH=""

cleanup() {
  /bin/rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

/bin/mkdir -p "$OUTPUT"

auth_args=()
if [[ -n "${HALOSCOPE_NOTARY_KEY_PATH:-}" ]]; then
  auth_args+=(
    -authenticationKeyPath "$HALOSCOPE_NOTARY_KEY_PATH"
    -authenticationKeyID "${HALOSCOPE_NOTARY_KEY_ID:-}"
    -authenticationKeyIssuerID "${HALOSCOPE_NOTARY_ISSUER_ID:-}"
  )
fi

if (( UNSIGNED )); then
  /bin/mkdir -p "$PRODUCTS_PATH"
  /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_ROOT/DerivedData" \
    CONFIGURATION_BUILD_DIR="$PRODUCTS_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build
  APP_PATH="$PRODUCTS_PATH/Haloscope.app"
else
  : "${HALOSCOPE_DEVELOPMENT_TEAM:?Set HALOSCOPE_DEVELOPMENT_TEAM}"
  : "${HALOSCOPE_APP_GROUP_IDENTIFIER:?Set HALOSCOPE_APP_GROUP_IDENTIFIER}"

  CODE_SIGN_IDENTITY="${HALOSCOPE_CODE_SIGN_IDENTITY:-Developer ID Application}"
  if ! /usr/bin/security find-identity -v -p codesigning |
    /usr/bin/grep -F "$CODE_SIGN_IDENTITY" >/dev/null; then
    echo "Developer ID signing identity not found: $CODE_SIGN_IDENTITY" >&2
    exit 1
  fi

  if [[ -n "${HALOSCOPE_NOTARY_PROFILE:-}" ]]; then
    :
  else
    : "${HALOSCOPE_NOTARY_KEY_PATH:?Set HALOSCOPE_NOTARY_KEY_PATH or HALOSCOPE_NOTARY_PROFILE}"
    : "${HALOSCOPE_NOTARY_KEY_ID:?Set HALOSCOPE_NOTARY_KEY_ID}"
    : "${HALOSCOPE_NOTARY_ISSUER_ID:?Set HALOSCOPE_NOTARY_ISSUER_ID}"
    [[ -f "$HALOSCOPE_NOTARY_KEY_PATH" ]] || {
      echo "Notary API key not found: $HALOSCOPE_NOTARY_KEY_PATH" >&2
      exit 1
    }
  fi

  /usr/bin/xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    -allowProvisioningUpdates \
    "${auth_args[@]}" \
    DEVELOPMENT_TEAM="$HALOSCOPE_DEVELOPMENT_TEAM" \
    HALOSCOPE_APP_GROUP_IDENTIFIER="$HALOSCOPE_APP_GROUP_IDENTIFIER" \
    HALOSCOPE_KEYCHAIN_GROUP_SUFFIX="${HALOSCOPE_KEYCHAIN_GROUP_SUFFIX:-com.lamluo.haloscope.shared}" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64"

  /usr/bin/xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    "${auth_args[@]}"

  APP_PATH="$EXPORT_PATH/Haloscope.app"
fi

[[ -d "$APP_PATH" ]] || { echo "Missing app bundle: $APP_PATH" >&2; exit 1; }
WIDGET_PATH="$APP_PATH/Contents/PlugIns/HaloscopeWidget.appex"
[[ -d "$WIDGET_PATH" ]] || { echo "Missing widget extension: $WIDGET_PATH" >&2; exit 1; }

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
WIDGET_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WIDGET_PATH/Contents/Info.plist")
[[ "$APP_VERSION" == "$WIDGET_VERSION" ]] || {
  echo "App/widget version mismatch: $APP_VERSION != $WIDGET_VERSION" >&2
  exit 1
}

verify_distribution_signature() {
  local item="$1"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$item"
}

verify_app_groups() {
  local expected="$1"
  local main_entitlements="$BUILD_ROOT/main-entitlements.plist"
  local widget_entitlements="$BUILD_ROOT/widget-entitlements.plist"

  /usr/bin/codesign -d --entitlements :- "$APP_PATH" >"$main_entitlements" 2>/dev/null
  /usr/bin/codesign -d --entitlements :- "$WIDGET_PATH" >"$widget_entitlements" 2>/dev/null

  local main_group
  local widget_group
  main_group=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups:0" "$main_entitlements")
  widget_group=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups:0" "$widget_entitlements")
  [[ "$main_group" == "$expected" && "$widget_group" == "$expected" ]] || {
    echo "App Group mismatch: app=$main_group widget=$widget_group expected=$expected" >&2
    exit 1
  }
}

notarize() {
  local item="$1"
  if [[ -n "${HALOSCOPE_NOTARY_PROFILE:-}" ]]; then
    /usr/bin/xcrun notarytool submit "$item" \
      --keychain-profile "$HALOSCOPE_NOTARY_PROFILE" \
      --wait
  else
    /usr/bin/xcrun notarytool submit "$item" \
      --key "$HALOSCOPE_NOTARY_KEY_PATH" \
      --key-id "$HALOSCOPE_NOTARY_KEY_ID" \
      --issuer "$HALOSCOPE_NOTARY_ISSUER_ID" \
      --wait
  fi
}

if (( ! UNSIGNED )); then
  verify_distribution_signature "$APP_PATH"
  verify_app_groups "$HALOSCOPE_APP_GROUP_IDENTIFIER"

  /usr/bin/ditto --norsrc -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
  notarize "$NOTARY_ZIP"
  /usr/bin/xcrun stapler staple "$APP_PATH"
  /usr/bin/xcrun stapler validate "$APP_PATH"
  verify_distribution_signature "$APP_PATH"
fi

ZIP_NAME="Haloscope-${VERSION}-macos-universal${ASSET_SUFFIX}.zip"
DMG_NAME="Haloscope-${VERSION}-macos-universal${ASSET_SUFFIX}.dmg"
DSYM_NAME="Haloscope-${VERSION}-macos-universal.dSYM.zip"
CHECKSUM_NAME="Haloscope-${VERSION}-SHA256SUMS${ASSET_SUFFIX}.txt"
ZIP_PATH="$OUTPUT/$ZIP_NAME"
DMG_PATH="$OUTPUT/$DMG_NAME"
DSYM_PATH="$OUTPUT/$DSYM_NAME"
CHECKSUM_PATH="$OUTPUT/$CHECKSUM_NAME"

/bin/rm -f "$ZIP_PATH" "$DMG_PATH" "$DSYM_PATH" "$CHECKSUM_PATH"
/usr/bin/ditto --norsrc -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

/bin/mkdir -p "$DMG_STAGE"
/bin/cp -R "$APP_PATH" "$DMG_STAGE/Haloscope.app"
/bin/ln -s /Applications "$DMG_STAGE/Applications"
/usr/bin/hdiutil create \
  -volname "Haloscope" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if (( ! UNSIGNED )); then
  /usr/bin/codesign --force --timestamp \
    --sign "${HALOSCOPE_CODE_SIGN_IDENTITY:-Developer ID Application}" \
    "$DMG_PATH"
  notarize "$DMG_PATH"
  /usr/bin/xcrun stapler staple "$DMG_PATH"
  /usr/bin/xcrun stapler validate "$DMG_PATH"
  /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"

  if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$APP_PATH"
  else
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
  fi
fi

if [[ -d "$ARCHIVE_PATH/dSYMs/Haloscope.app.dSYM" ]]; then
  /usr/bin/ditto --norsrc -c -k --keepParent \
    "$ARCHIVE_PATH/dSYMs/Haloscope.app.dSYM" \
    "$DSYM_PATH"
elif [[ -d "$PRODUCTS_PATH/Haloscope.app.dSYM" ]]; then
  /usr/bin/ditto --norsrc -c -k --keepParent \
    "$PRODUCTS_PATH/Haloscope.app.dSYM" \
    "$DSYM_PATH"
fi

(
  cd "$OUTPUT"
  checksum_targets=("$ZIP_NAME" "$DMG_NAME")
  [[ -f "$DSYM_NAME" ]] && checksum_targets+=("$DSYM_NAME")
  /usr/bin/shasum -a 256 "${checksum_targets[@]}" >"$CHECKSUM_NAME"
)

echo "Release assets:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
[[ -f "$DSYM_PATH" ]] && echo "  $DSYM_PATH"
echo "  $CHECKSUM_PATH"
