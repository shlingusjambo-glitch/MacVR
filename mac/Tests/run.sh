#!/bin/sh
# Focused interaction test for the in-headset menu (Tests/main.swift).
# Compiles only the UI sources + test main (NOT Sources/*.swift, so the app
# build is untouched) and clicks every control headlessly, asserting real
# effects: slider values, mono flip, keyboard query text, sound PCM output,
# controller-model builds + device detection.
# Usage: ./Tests/run.sh   (needs only the Xcode command line tools)
set -e
cd "$(dirname "$0")/.."
swiftc -O Tests/main.swift Sources/Dashboard.swift Sources/UISounds.swift \
    Sources/ControllerModels.swift Sources/ControllerGLB.swift Sources/Settings.swift Sources/Games.swift Sources/SteamLibrary.swift Sources/Mic.swift \
    -o /tmp/vr4mac-dashtest
/tmp/vr4mac-dashtest
