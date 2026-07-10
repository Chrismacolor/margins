#!/usr/bin/env bash
#
# Compile and run the Markdown parser + search unit tests + parse benchmark.
# Uses swiftc directly (no SwiftPM) against the SwiftUI-free source files.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

RENDERER="$ROOT_DIR/Sources/Margins/MarkdownRenderer.swift"
SEARCH="$ROOT_DIR/Sources/Margins/MarkdownSearch.swift"
TESTS="$ROOT_DIR/Tests/MarkdownRendererTests.swift"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

xcrun swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  "$RENDERER" "$SEARCH" "$TESTS" \
  -o "$TMP_DIR/testrunner"

"$TMP_DIR/testrunner"

"$SCRIPT_DIR/test_cli.sh"
