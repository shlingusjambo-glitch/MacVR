#!/bin/sh
# Direct-touch geometry check (Compositor.touch). Compiles the app sources minus the @main App.
set -e
cd "$(dirname "$0")/.."
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT; ln -s "$PWD/Resources/hands" "$PWD/Resources/controllers" "$D/"
swiftc -Onone -parse-as-library -import-objc-header ../common/vr4mac.h Tests/TouchTest.swift $(ls Sources/*.swift | grep -v App.swift) -o "$D/touchtest"
"$D/touchtest"
