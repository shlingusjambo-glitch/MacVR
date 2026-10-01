// Loads MacVRMic.driver like coreaudiod does (CFPlugIn factory), checks the device it reports, and that audio
// written to the output stream comes back from the input. Usage: Tests/run-mic-driver.sh
#include <CoreAudio/AudioServerPlugIn.h>
#include <assert.h>
#include <stdio.h>
int main(int argc, char **argv) {
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), true);
    CFPlugInRef p = CFPlugInCreate(NULL, u); assert(p);
    CFArrayRef f = CFPlugInFindFactoriesForPlugInType(kAudioServerPlugInTypeUUID); assert(f && CFArrayGetCount(f) == 1);
    IUnknownVTbl **unk = CFPlugInInstanceCreate(NULL, CFArrayGetValueAtIndex(f, 0), kAudioServerPlugInTypeUUID); assert(unk);
    AudioServerPlugInDriverRef d = NULL;
    assert((*unk)->QueryInterface(unk, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), (LPVOID *)&d) == S_OK && d);
    assert((*d)->Initialize(d, NULL) == noErr);
    AudioObjectPropertyAddress a = {kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef uid = CFSTR("MacVRMic_UID"); AudioObjectID dev = 0; UInt32 sz = sizeof dev;
    assert((*d)->GetPropertyData(d, kAudioObjectPlugInObject, 0, &a, sizeof uid, &uid, sz, &sz, &dev) == noErr && dev == 2);
    CFStringRef name = NULL; sz = sizeof name; a.mSelector = kAudioObjectPropertyName;
    assert((*d)->GetPropertyData(d, dev, 0, &a, 0, NULL, sz, &sz, &name) == noErr && CFStringCompare(name, CFSTR("MacVR Headset Mic"), 0) == 0);
    UInt32 v = 9; sz = sizeof v; a.mSelector = kAudioDevicePropertyDeviceCanBeDefaultDevice; a.mScope = kAudioObjectPropertyScopeOutput;
    assert((*d)->GetPropertyData(d, dev, 0, &a, 0, NULL, sz, &sz, &v) == noErr && v == 0);   // never steals the speakers
    a.mScope = kAudioObjectPropertyScopeInput;
    assert((*d)->GetPropertyData(d, dev, 0, &a, 0, NULL, sz, &sz, &v) == noErr && v == 1);
    // loopback: write 256 frames at sample time 1000, read them back at the same time
    assert((*d)->StartIO(d, dev, 1) == noErr);
    float out[512], in[512];
    for (int i = 0; i < 512; i++) out[i] = (float)i / 512;
    AudioServerPlugInIOCycleInfo c = {0}; c.mOutputTime.mSampleTime = 1000; c.mInputTime.mSampleTime = 1000;
    assert((*d)->DoIOOperation(d, dev, 4, 1, kAudioServerPlugInIOOperationWriteMix, 256, &c, out, NULL) == noErr);
    assert((*d)->DoIOOperation(d, dev, 3, 1, kAudioServerPlugInIOOperationReadInput, 256, &c, in, NULL) == noErr);
    for (int i = 0; i < 512; i++) assert(in[i] == out[i]);
    assert((*d)->DoIOOperation(d, dev, 3, 1, kAudioServerPlugInIOOperationReadInput, 256, &c, in, NULL) == noErr && in[100] == 0);   // read once
    Float64 st; UInt64 ht, seed; assert((*d)->GetZeroTimeStamp(d, dev, 1, &st, &ht, &seed) == noErr);
    (*d)->StopIO(d, dev, 1);
    puts("PASS mic driver");
    return 0;
}
