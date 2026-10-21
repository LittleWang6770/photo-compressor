#!/bin/zsh
set -eu
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT/Sources/Core.swift" "$TASK_ROOT/Sources/FilePublication.swift" "$TASK_ROOT/Sources/Demo.swift" \
  "$TASK_ROOT/scripts/MPFFixture.swift" "$TASK_ROOT/scripts/verify-danger.swift" -o "$TASK_ROOT/build/verify-danger"
"$TASK_ROOT/build/verify-danger"
