#!/bin/sh
# Builds a MacVR release: WineXR DLL + MacVR.app + DMG/zip, stages the Quest APK.
# Usage: ./release/build-release.sh [--apk PATH] [--version X.Y.Z] [--no-dmg]
#   --apk PATH   prebuilt (signed) APK to ship; default: android/VR4Mac.apk if present.
#                Signing is owned by the Android lane (see android/app/build.gradle):
#                supply an already-signed APK built with MACVR_KEYSTORE,
#                MACVR_STORE_PASSWORD, MACVR_KEY_ALIAS, MACVR_KEY_PASSWORD — never keys.
# Requirements: Xcode CLT (mac app), mingw-w64 (runtime DLL), hdiutil (DMG, macOS only).
set -e
cd "$(dirname "$0")/.."

APK=""
VERSION=""
DMG=1
DEV_APK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apk) APK="$2"; shift 2;;
        --version) VERSION="$2"; shift 2;;
        --no-dmg) DMG=0; shift;;
        --dev-apk) DEV_APK=1; shift;;   # allow a debug-signed APK (internal builds only, never public)
        *) echo "unknown flag $1"; exit 1;;
    esac
done
if [ -z "$VERSION" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" mac/Info.plist 2>/dev/null || echo 0.2.0)
fi
OUT="$PWD/dist/MacVR-$VERSION"
rm -rf "$OUT" dist/dmg-tmp
mkdir -p "$OUT"

echo "== WineXR runtime =="
./runtime/build.sh

echo "== SiliconXR (native Mac VR runtime) + its Minecraft mod =="
./SiliconXR/build.sh
if [ -z "$JAVAC" ]; then   # first javac that actually runs (/usr/bin/javac is a stub without a JDK)
    for j in javac /opt/homebrew/opt/openjdk/bin/javac /opt/homebrew/opt/openjdk@21/bin/javac "$HOME/Library/Application Support/PrismLauncher/java/java-runtime-gamma/bin/javac"; do
        if "$j" -version >/dev/null 2>&1; then JAVAC="$j"; break; fi
    done
fi
JAVAC="$JAVAC" ./SiliconXR-Mod/build.sh

echo "== MacVR.app =="
./mac/build.sh

echo "== Quest APK =="
if [ -z "$APK" ]; then APK="android/VR4Mac.apk"; fi
if [ -f "$APK" ]; then
    # Public releases must be verifiably release-signed: reject the Android
    # Debug certificate (the checked-in android/VR4Mac.apk is a debug build).
    if [ -z "$JAVA_HOME" ]; then
        for j in /opt/homebrew/opt/openjdk@21 /opt/homebrew/opt/openjdk /usr/libexec/java_home; do
            [ -x "$j/bin/java" ] && export JAVA_HOME="$j" && break
        done
    fi
    APKSIGNER=$(ls -d "$ANDROID_HOME"/build-tools/*/apksigner "$HOME/Library/Android/sdk/build-tools/"*/apksigner 2>/dev/null | head -1)
    if [ -n "$APKSIGNER" ]; then
        "$APKSIGNER" verify --print-certs "$APK" > /tmp/vr4mac-apkcerts.txt || { echo "ERROR: apksigner verify failed for $APK"; exit 1; }
        if grep -qi "Android Debug" /tmp/vr4mac-apkcerts.txt; then
            if [ "$DEV_APK" = 1 ]; then
                echo "WARNING: staging a DEBUG-signed APK (--dev-apk, internal only, never public)."
            else
                echo "ERROR: $APK is signed with the Android Debug certificate. Ship a release-signed APK via --apk (see android/app/build.gradle), or pass --dev-apk for internal builds only."
                exit 1
            fi
        else
            echo "APK signature OK (not debug): $APK"
        fi
    else
        echo "WARNING: apksigner not found — cannot verify APK signature; staging unverified."
    fi
    cp "$APK" "$OUT/VR4Mac-Quest.apk"
    echo "staged APK: $APK"
else
    echo "WARNING: no APK at $APK — release will ship Mac-only. Build/sign it via the Android lane first."
fi

cp LICENSE THIRD_PARTY_NOTICES.md README.md "$OUT/"

echo "== package =="
rm -rf dist/dmg-tmp && mkdir -p dist/dmg-tmp
cp -R mac/build/VR4Mac.app dist/dmg-tmp/MacVR.app   # shipped as MacVR.app (same bundle id/signature)
cp "$OUT"/*.md dist/dmg-tmp/ 2>/dev/null || true
(cd dist/dmg-tmp && zip -qry "../MacVR-$VERSION-mac.zip" MacVR.app *.md)
mv "dist/MacVR-$VERSION-mac.zip" "$OUT/"
[ -f "$OUT/VR4Mac-Quest.apk" ] && mv "$OUT/VR4Mac-Quest.apk" "$OUT/MacVR-Quest-$VERSION.apk"
ln -s /Applications dist/dmg-tmp/Applications   # drag-to-install DMG
if [ "$DMG" = 1 ] && command -v hdiutil >/dev/null; then
    rm -f "$OUT/MacVR-$VERSION.dmg"
    hdiutil create -volname "MacVR $VERSION" -srcfolder dist/dmg-tmp -ov -format UDZO "$OUT/MacVR-$VERSION.dmg" >/dev/null
    echo "dmg: $OUT/MacVR-$VERSION.dmg"
fi
rm -rf dist/dmg-tmp

echo "release ready in $OUT:"; ls -la "$OUT"
