#!/usr/bin/env bash
# รันเทสกติกาการอัปเดตของแอป Mac: ./Apple/tests/update-policy.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(mktemp -d)/update-policy-tests"
swiftc -swift-version 5 -parse-as-library -o "$OUT" "$HERE/../Sources/UpdatePolicy.swift" "$HERE/UpdatePolicyTests.swift"
"$OUT"
