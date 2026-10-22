#!/usr/bin/env bash
# วาดภาพ UI (Dynamic Island ทุกสถานะ + ศูนย์ควบคุม) เป็น PNG: ./Apple/tests/render-previews.sh [โฟลเดอร์]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$(mktemp -d)}"
BIN="$(mktemp -d)/april-preview"
mkdir -p "$OUT"
swiftc -swift-version 5 -parse-as-library -D APRIL_PREVIEW -module-name April -o "$BIN" "$HERE"/../Sources/*.swift
APRIL_PREVIEW_DIR="$OUT" "$BIN"
echo "$OUT"
