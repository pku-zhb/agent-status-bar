#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc -parse-as-library \
  "$ROOT/Sources/AgentStatusBar/Models.swift" \
  "$ROOT/Sources/AgentStatusBar/MenuBarFeaturePreferences.swift" \
  "$ROOT/Sources/AgentStatusBar/ProcessRunner.swift" \
  "$ROOT/Sources/AgentStatusBar/CreditScanner.swift" \
  "$ROOT/Sources/AgentStatusBar/StatusVisuals.swift" \
  "$ROOT/Tests/AgentStatusBarTests/CreditScannerTests.swift" \
  -o "$TEST_DIR/CreditScannerTests"

"$TEST_DIR/CreditScannerTests"
