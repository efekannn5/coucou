#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-remote-run.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/CoucouKit/RemoteRun.swift \
    tests/RemoteRunTests.swift -o "$TEST_DIR/remote-run-tests"
"$TEST_DIR/remote-run-tests"
