#!/bin/sh
# Hand tracking check (HandModel.track, HandGesture). Compiles the app sources minus the @main App.
set -e
cd "$(dirname "$0")/.."
D=$(mktemp -d); ln -s "$PWD/Resources/hands" "$PWD/Resources/controllers" "$D/"
swiftc -O -parse-as-library -import-objc-header ../common/vr4mac.h Tests/HandTrackingTest.swift $(ls Sources/*.swift | grep -v App.swift) -o "$D/handtest"
"$D/handtest"
