#!/bin/zsh
set -euo pipefail

APP_PATH=""
ZIP_PATH=""
DMG_PATH=""
DSYM_PATH=""
CHECKSUM_PATH=""
VERSION=""

usage() {
  cat <<'EOF'
Usage: scripts/validate_preview_artifacts.sh \
  --app PATH --zip PATH --dmg PATH --checksums PATH [--dsym PATH] --version VERSION
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --app|--zip|--dmg|--dsym|--checksums|--version)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        --app) APP_PATH="$2" ;;
        --zip) ZIP_PATH="$2" ;;
        --dmg) DMG_PATH="$2" ;;
        --dsym) DSYM_PATH="$2" ;;
        --checksums) CHECKSUM_PATH="$2" ;;
        --version) VERSION="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$APP_PATH" && -f "$ZIP_PATH" && -f "$DMG_PATH" && -f "$CHECKSUM_PATH" && -n "$VERSION" ]] || {
  echo "App, ZIP, DMG, checksum manifest, and version are required." >&2
  usage >&2
  exit 2
}
[[ "${APP_PATH:t}" == "Haloscope Preview.app" ]] || { echo "Unexpected app product name." >&2; exit 1; }

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PATH/Contents/Info.plist"; }
bundle_id="$(plist_value CFBundleIdentifier)"
display_name="$(plist_value CFBundleDisplayName)"
channel="$(plist_value HaloscopeDistributionChannel)"
executable_name="$(plist_value CFBundleExecutable)"
[[ "$bundle_id" == "com.lamluo.haloscope.preview" ]] || { echo "Unexpected bundle identifier: $bundle_id" >&2; exit 1; }
[[ "$display_name" == "Haloscope Preview" ]] || { echo "Unexpected display name: $display_name" >&2; exit 1; }
[[ "$channel" == "unsigned-preview" ]] || { echo "Unexpected distribution channel: $channel" >&2; exit 1; }

executable="$APP_PATH/Contents/MacOS/$executable_name"
[[ -f "$executable" ]] || { echo "Missing Preview executable." >&2; exit 1; }
archs="$(/usr/bin/lipo -archs "$executable")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "Preview executable is not universal: $archs" >&2; exit 1; }
[[ ! -d "$APP_PATH/Contents/PlugIns" ]] || { echo "Preview contains Contents/PlugIns." >&2; exit 1; }
[[ -z "$(/usr/bin/find "$APP_PATH" -type d -name '*.appex' -print -quit)" ]] || { echo "Preview contains an appex." >&2; exit 1; }

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
signature_details="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
print -r -- "$signature_details" | /usr/bin/grep -q '^Signature=adhoc$' || { echo "Preview signature is not ad-hoc." >&2; exit 1; }
if print -r -- "$signature_details" | /usr/bin/grep -q '^TeamIdentifier=' && ! print -r -- "$signature_details" | /usr/bin/grep -q '^TeamIdentifier=not set$'; then
  echo "Preview unexpectedly contains a signing TeamIdentifier." >&2
  exit 1
fi
entitlements="$(/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 || true)"
if print -r -- "$entitlements" | /usr/bin/grep -Eqi 'application-groups|keychain-access-groups|com.apple.security.app-sandbox'; then
  echo "Preview contains a restricted entitlement." >&2
  exit 1
fi

zip_listing="$(/usr/bin/unzip -Z1 "$ZIP_PATH")"
print -r -- "$zip_listing" | /usr/bin/grep -q '^Haloscope Preview.app/$' || { echo "ZIP does not contain Haloscope Preview.app." >&2; exit 1; }
if print -r -- "$zip_listing" | /usr/bin/grep -Eqi 'HaloscopeWidget\.appex|Contents/PlugIns'; then
  echo "ZIP contains Widget content." >&2
  exit 1
fi

[[ -z "$DSYM_PATH" || -f "$DSYM_PATH" ]] || { echo "Missing requested dSYM archive." >&2; exit 1; }
checksum_directory="${CHECKSUM_PATH:h}"
(
  cd "$checksum_directory"
  /usr/bin/shasum -a 256 -c "${CHECKSUM_PATH:t}"
)

mount_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/haloscope-preview-dmg.XXXXXX")"
mounted=0
cleanup() {
  if (( mounted )); then /usr/bin/hdiutil detach "$mount_dir" -quiet || true; fi
  /bin/rm -rf "$mount_dir"
}
trap cleanup EXIT
/usr/bin/hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null
mounted=1
[[ -d "$mount_dir/Haloscope Preview.app" ]] || { echo "DMG is missing Haloscope Preview.app." >&2; exit 1; }
[[ -L "$mount_dir/Applications" ]] || { echo "DMG is missing the Applications link." >&2; exit 1; }
[[ -f "$mount_dir/README-FIRST.txt" ]] || { echo "DMG is missing README-FIRST.txt." >&2; exit 1; }
grep -q 'SHA-256' "$mount_dir/README-FIRST.txt" || { echo "DMG README lacks checksum guidance." >&2; exit 1; }

echo "Preview artifact validation passed for $VERSION."
