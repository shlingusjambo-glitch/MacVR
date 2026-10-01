#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc mac/Sources/GameOverrides.swift mac/Tests/GameOverridesTest.swift -o "$TEST_DIR/game-overrides"
"$TEST_DIR/game-overrides"
