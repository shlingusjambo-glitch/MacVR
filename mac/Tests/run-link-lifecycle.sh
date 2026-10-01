#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -import-objc-header common/vr4mac.h mac/Sources/Link.swift mac/Tests/LinkLifecycle.swift -o "$TEST_DIR/link-lifecycle"
"$TEST_DIR/link-lifecycle"
