#!/bin/sh
# Builds mac/build/VR4Mac.app (needs only the Xcode command line tools).
set -e
cd "$(dirname "$0")"
APP=build/VR4Mac.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -parse-as-library -import-objc-header ../common/vr4mac.h Sources/*.swift -o $APP/Contents/MacOS/VR4Mac
cp Info.plist $APP/Contents/
rm -rf $APP/Contents/Resources/controllers; cp -R Resources/controllers $APP/Contents/Resources/   # real controller meshes (MIT)
rm -rf $APP/Contents/Resources/environments; cp -R Resources/environments $APP/Contents/Resources/   # home panoramas (CC0)
rm -rf $APP/Contents/Resources/sounds; cp -R Resources/sounds $APP/Contents/Resources/   # UI sounds (AOSP, Apache-2.0) + welcome-tour music
rm -rf $APP/Contents/Resources/icons; cp -R Resources/icons $APP/Contents/Resources/   # UI icons (Lucide, ISC)
if [ -f ../runtime/build/vr4mac_openxr.dll ]; then cp ../runtime/build/vr4mac_openxr.dll $APP/Contents/Resources/; fi
for f in ../SiliconXR/build/libsiliconxr_openxr.dylib ../SiliconXR-Mod/build/siliconxr.jar; do if [ -f $f ]; then cp $f $APP/Contents/Resources/; fi; done   # SiliconXR: VR for native Mac games
# MacVR Headset Mic: loopback HAL driver; MacVR installs it into /Library/Audio/Plug-Ins/HAL on first launch (asks first)
D=$APP/Contents/Resources/MacVRMic.driver; rm -rf $D; mkdir -p $D/Contents/MacOS; cp MicDriver/Info.plist $D/Contents/
clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -Wall -Wextra -bundle -fvisibility=hidden -o $D/Contents/MacOS/MacVRMic MicDriver/MacVRMic.c -framework CoreFoundation -framework CoreAudio
codesign -s - --force $D
# Stable designated requirement: TCC (Screen & System Audio Recording) grants then survive rebuilds; ad-hoc default is the cdhash.
codesign -s - --force -r='designated => identifier "com.vr4mac.app"' $APP
echo "built $APP"
