#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/docs/protocol"

/bin/rm -rf "$OUTPUT"
/bin/mkdir -p "$OUTPUT/stable" "$OUTPUT/experimental"

codex app-server generate-json-schema --out "$OUTPUT/stable"
codex app-server generate-json-schema --experimental --out "$OUTPUT/experimental"

echo "$OUTPUT"
