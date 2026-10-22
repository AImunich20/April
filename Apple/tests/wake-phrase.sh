#!/usr/bin/env bash
# รันเทสการจับ/ตัดคำปลุก "April": ./Apple/tests/wake-phrase.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(mktemp -d)/wake-phrase-tests"
swiftc -swift-version 5 -parse-as-library -o "$OUT" "$HERE/../Sources/WakePhrase.swift" "$HERE/WakePhraseTests.swift"
"$OUT"
