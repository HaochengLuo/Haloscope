#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/Haloscope.xcodeproj/project.pbxproj"
MANIFEST="$ROOT/scripts/preview_shared_sources.txt"

source_phase() {
  local phase_id="$1"
  /usr/bin/awk -v phase_id="$phase_id" '
    index($0, phase_id) && $0 ~ /= \{/ { inside=1 }
    inside { print }
    inside && /runOnlyForDeploymentPostprocessing/ { exit }
  ' "$PROJECT"
}

source_paths() {
  /usr/bin/sed -n 's/.*\/\* \(.*\) in Sources \*\/.*$/\1/p' | /usr/bin/sort
}

expected=$(/usr/bin/sort "$MANIFEST")
main_sources="$(source_phase AA6000000000000000000002 | source_paths)"
preview_sources="$(source_phase AC6000000000000000000002 | source_paths)"

if [[ "$main_sources" != "$expected" ]]; then
  echo "Haloscope target source membership differs from the maintained manifest." >&2
  /usr/bin/diff -u <(print -r -- "$expected") <(print -r -- "$main_sources") >&2 || true
  exit 1
fi
if [[ "$preview_sources" != "$expected" ]]; then
  echo "HaloscopePreview target source membership differs from the maintained manifest." >&2
  /usr/bin/diff -u <(print -r -- "$expected") <(print -r -- "$preview_sources") >&2 || true
  exit 1
fi

preview_target=$(/usr/bin/awk '
  /AC5000000000000000000001 \/\* HaloscopePreview \*\// { inside=1 }
  inside { print }
  inside && /productType =/ { exit }
' "$PROJECT")
[[ "$preview_target" != *HaloscopeWidget* ]] || { echo "HaloscopePreview has a Widget dependency." >&2; exit 1; }
[[ "$preview_target" != *"Embed App Extensions"* ]] || { echo "HaloscopePreview embeds an extension." >&2; exit 1; }

preview_configs=$(/usr/bin/awk '
  /ACB000000000000000000041 \/\* Debug \*\// { inside=1 }
  inside { print }
  inside && /ACB000000000000000000042 \/\* Release \*\// { release=1 }
  release && inside && /name = Release;/ { exit }
' "$PROJECT")
[[ "$preview_configs" == *"PRODUCT_BUNDLE_IDENTIFIER = com.lamluo.haloscope.preview;"* ]] || { echo "Preview bundle identifier is not isolated." >&2; exit 1; }
[[ "$preview_configs" == *"SWIFT_ACTIVE_COMPILATION_CONDITIONS = HALOSCOPE_UNSIGNED_PREVIEW;"* ]] || { echo "Preview compilation condition is missing." >&2; exit 1; }
for forbidden in CODE_SIGN_ENTITLEMENTS DEVELOPMENT_TEAM REGISTER_APP_GROUPS HALOSCOPE_APP_GROUP_IDENTIFIER HALOSCOPE_KEYCHAIN_GROUP_SUFFIX; do
  if print -r -- "$preview_configs" | /usr/bin/grep -q "$forbidden"; then
    echo "Preview configuration contains forbidden setting: $forbidden" >&2
    exit 1
  fi
done

/usr/bin/grep -A4 -q 'AA9000000000000000000001 .*PBXTargetDependency' "$PROJECT" && /usr/bin/grep -A4 -q 'target = AA5000000000000000000002 .*HaloscopeWidget' "$PROJECT" || { echo "Regular Haloscope target lost its Widget dependency." >&2; exit 1; }
/usr/bin/grep -q 'AA6000000000000000000004 .*Embed App Extensions' "$PROJECT" || { echo "Regular Haloscope target lost its extension phase." >&2; exit 1; }

echo "Preview target validation passed."
