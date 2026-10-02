#!/bin/sh
# MacVR OS shell checks (Tests/ShellTest.swift): overlays, window snapping, Mac windows, theater, capture.
# Compiles the app sources minus the @main App, with assertions on.
set -e
cd "$(dirname "$0")/.."
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT; ln -s "$PWD/Resources/hands" "$PWD/Resources/controllers" "$D/"
export MACVR_HOME="$D/home"
swiftc -Onone -parse-as-library -import-objc-header ../common/vr4mac.h Tests/ShellTest.swift $(ls Sources/*.swift | grep -v App.swift) -o "$D/shelltest"
"$D/shelltest"
