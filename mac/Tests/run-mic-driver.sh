#!/bin/sh
# Builds the app (for MacVRMic.driver) and runs the driver self-check against it.
set -e
cd "$(dirname "$0")/.."
./build.sh >/dev/null
T=$(mktemp -d)
clang -o "$T/mictest" Tests/MicDriverTest.c -framework CoreFoundation -framework CoreAudio
"$T/mictest" build/VR4Mac.app/Contents/Resources/MacVRMic.driver
