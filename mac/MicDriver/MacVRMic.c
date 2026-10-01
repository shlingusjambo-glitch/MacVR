// MacVR Headset Mic: a tiny loopback Audio Server Plug-In (HAL driver, runs inside coreaudiod).
// One device with an output and an input stream. MacVR plays the headset's mic audio into the output;
// whatever is written there comes back out of the input 1:1, so games record it like any microphone.
// 48 kHz, 2 channels, float32. The output side can't become the default output, so it never steals the speakers.
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

enum { kPlugIn = kAudioObjectPlugInObject, kDevice = 2, kStreamIn = 3, kStreamOut = 4 };
#define RATE 48000.0
#define CHANS 2
#define PERIOD 512                 // zero-timestamp period (frames)
#define RING 65536                 // loopback ring (frames), > any IO buffer
#define NAME "MacVR Headset Mic"
#define UID "MacVRMic_UID"         // Mic.swift looks the device up by this

static AudioServerPlugInHostRef host;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static UInt32 refCount, ioClients;
static Float64 hostTicksPerFrame;
static UInt64 anchorHost, tsCount;
static float ring[RING * CHANS];

// ---------------------------------------------------------------- property helpers
#define OUT(type, val) do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)outData = (val); *outDataSize = sizeof(type); } while (0)
#define OUT_CF(str) OUT(CFStringRef, CFSTR(str))
static AudioStreamBasicDescription format(void) {
    return (AudioStreamBasicDescription){RATE, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
                                         4 * CHANS, 1, 4 * CHANS, CHANS, 32, 0};
}
static UInt32 ids(UInt32 *out, UInt32 cap, const UInt32 *list, UInt32 n) {
    UInt32 k = n < cap ? n : cap;
    memcpy(out, list, k * sizeof(UInt32));
    return k * sizeof(UInt32);
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    switch (obj) {
    case kPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle: return true;
        }
        return false;
    case kDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner: case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType: case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertyStreams: case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyPreferredChannelsForStereo:
            return true;
        }
        return false;
    case kStreamIn: case kStreamOut:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner: case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = false;   // fixed format and rate
    return noErr;
}
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qs, const void *q, UInt32 *out) {
    (void)qs; (void)q;
    if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyName: case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID:
        *out = sizeof(CFStringRef); return noErr;
    case kAudioPlugInPropertyResourceBundle: *out = sizeof(CFStringRef); return noErr;
    case kAudioObjectPropertyOwnedObjects:
        *out = (obj == kPlugIn ? 1 : obj == kDevice ? 2 : 0) * sizeof(AudioObjectID); return noErr;
    case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: *out = sizeof(AudioObjectID); return noErr;
    case kAudioDevicePropertyStreams:
        *out = (a->mScope == kAudioObjectPropertyScopeGlobal ? 2 : 1) * sizeof(AudioObjectID); return noErr;
    case kAudioObjectPropertyControlList: *out = 0; return noErr;
    case kAudioDevicePropertyNominalSampleRate: *out = sizeof(Float64); return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates: *out = sizeof(AudioValueRange); return noErr;
    case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * sizeof(UInt32); return noErr;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: *out = sizeof(AudioStreamBasicDescription); return noErr;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        *out = sizeof(AudioStreamRangedDescription); return noErr;
    case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        *out = sizeof(AudioObjectID); return noErr;
    default: *out = sizeof(UInt32); return noErr;
    }
}
static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qs, const void *q, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)d; (void)pid;
    if (obj == kPlugIn) switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: OUT(AudioClassID, kAudioObjectClassID); return noErr;
        case kAudioObjectPropertyClass: OUT(AudioClassID, kAudioPlugInClassID); return noErr;
        case kAudioObjectPropertyOwner: OUT(AudioObjectID, kAudioObjectUnknown); return noErr;
        case kAudioObjectPropertyManufacturer: OUT_CF("MacVR"); return noErr;
        case kAudioPlugInPropertyResourceBundle: OUT_CF(""); return noErr;
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: {
            UInt32 l[] = {kDevice}; *outDataSize = ids(outData, inDataSize / sizeof(UInt32), l, 1); return noErr;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qs < sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
            CFStringRef s = *(const CFStringRef *)q;
            OUT(AudioObjectID, s && CFStringCompare(s, CFSTR(UID), 0) == kCFCompareEqualTo ? kDevice : kAudioObjectUnknown);
            return noErr;
        }
    }
    if (obj == kDevice) switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: OUT(AudioClassID, kAudioObjectClassID); return noErr;
        case kAudioObjectPropertyClass: OUT(AudioClassID, kAudioDeviceClassID); return noErr;
        case kAudioObjectPropertyOwner: OUT(AudioObjectID, kPlugIn); return noErr;
        case kAudioObjectPropertyName: OUT_CF(NAME); return noErr;
        case kAudioObjectPropertyManufacturer: OUT_CF("MacVR"); return noErr;
        case kAudioDevicePropertyDeviceUID: OUT_CF(UID); return noErr;
        case kAudioDevicePropertyModelUID: OUT_CF("MacVRMic_Model"); return noErr;
        case kAudioDevicePropertyTransportType: OUT(UInt32, kAudioDeviceTransportTypeVirtual); return noErr;
        case kAudioDevicePropertyRelatedDevices: { UInt32 l[] = {kDevice}; *outDataSize = ids(outData, inDataSize / sizeof(UInt32), l, 1); return noErr; }
        case kAudioDevicePropertyClockDomain: OUT(UInt32, 0); return noErr;
        case kAudioDevicePropertyDeviceIsAlive: OUT(UInt32, 1); return noErr;
        case kAudioDevicePropertyDeviceIsRunning: OUT(UInt32, ioClients > 0); return noErr;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: OUT(UInt32, a->mScope == kAudioObjectPropertyScopeInput); return noErr;   // never default output
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: OUT(UInt32, 0); return noErr;
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: OUT(UInt32, 0); return noErr;
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams: {
            UInt32 both[] = {kStreamIn, kStreamOut}, in[] = {kStreamIn}, out[] = {kStreamOut};
            const UInt32 *l = a->mScope == kAudioObjectPropertyScopeInput ? in : a->mScope == kAudioObjectPropertyScopeOutput ? out : both;
            *outDataSize = ids(outData, inDataSize / sizeof(UInt32), l, a->mScope == kAudioObjectPropertyScopeGlobal ? 2 : 1);
            return noErr;
        }
        case kAudioObjectPropertyControlList: *outDataSize = 0; return noErr;
        case kAudioDevicePropertyNominalSampleRate: OUT(Float64, RATE); return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: OUT(AudioValueRange, ((AudioValueRange){RATE, RATE})); return noErr;
        case kAudioDevicePropertyIsHidden: OUT(UInt32, 0); return noErr;
        case kAudioDevicePropertyZeroTimeStampPeriod: OUT(UInt32, PERIOD); return noErr;
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1; ((UInt32 *)outData)[1] = 2; *outDataSize = 2 * sizeof(UInt32); return noErr;
        }
    }
    if (obj == kStreamIn || obj == kStreamOut) switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: OUT(AudioClassID, kAudioObjectClassID); return noErr;
        case kAudioObjectPropertyClass: OUT(AudioClassID, kAudioStreamClassID); return noErr;
        case kAudioObjectPropertyOwner: OUT(AudioObjectID, kDevice); return noErr;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return noErr;
        case kAudioStreamPropertyIsActive: OUT(UInt32, 1); return noErr;
        case kAudioStreamPropertyDirection: OUT(UInt32, obj == kStreamIn); return noErr;   // 1 = input
        case kAudioStreamPropertyTerminalType: OUT(UInt32, obj == kStreamIn ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker); return noErr;
        case kAudioStreamPropertyStartingChannel: OUT(UInt32, 1); return noErr;
        case kAudioStreamPropertyLatency: OUT(UInt32, 0); return noErr;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: OUT(AudioStreamBasicDescription, format()); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            OUT(AudioStreamRangedDescription, ((AudioStreamRangedDescription){format(), {RATE, RATE}})); return noErr;
    }
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qs, const void *q, UInt32 size, const void *data) {
    (void)d; (void)obj; (void)pid; (void)qs; (void)q; (void)size; (void)data;
    // the host sets the format/rate to what we advertise; accept that silently, refuse anything else
    if (a->mSelector == kAudioDevicePropertyNominalSampleRate || a->mSelector == kAudioStreamPropertyVirtualFormat ||
        a->mSelector == kAudioStreamPropertyPhysicalFormat) return noErr;
    return kAudioHardwareUnsupportedOperationError;
}

// ---------------------------------------------------------------- IO
static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)dev; (void)client;
    pthread_mutex_lock(&lock);
    if (ioClients++ == 0) { anchorHost = mach_absolute_time(); tsCount = 0; memset(ring, 0, sizeof ring); }
    pthread_mutex_unlock(&lock);
    return noErr;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)dev; (void)client;
    pthread_mutex_lock(&lock);
    if (ioClients) ioClients--;
    pthread_mutex_unlock(&lock);
    return noErr;
}
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    (void)d; (void)dev; (void)client;
    pthread_mutex_lock(&lock);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = hostTicksPerFrame * PERIOD;
    while ((Float64)(now - anchorHost) >= (Float64)(tsCount + 1) * ticksPerPeriod) tsCount++;
    *sampleTime = (Float64)tsCount * PERIOD;
    *hostTime = anchorHost + (UInt64)((Float64)tsCount * ticksPerPeriod);
    *seed = 1;
    pthread_mutex_unlock(&lock);
    return noErr;
}
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, Boolean *will, Boolean *inPlace) {
    (void)d; (void)dev; (void)client;
    *will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = true;
    return noErr;
}
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *c) {
    (void)d; (void)dev; (void)client; (void)op; (void)n; (void)c; return noErr;
}
/// Output (MacVR's playback) goes into the ring at its sample time; input reads the same times back.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 n,
                              const AudioServerPlugInIOCycleInfo *c, void *main, void *secondary) {
    (void)d; (void)dev; (void)stream; (void)client; (void)secondary;
    float *buf = main;
    if (op == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 t = (UInt64)c->mOutputTime.mSampleTime;
        for (UInt32 i = 0; i < n; i++) memcpy(&ring[((t + i) % RING) * CHANS], &buf[i * CHANS], CHANS * sizeof(float));
    } else if (op == kAudioServerPlugInIOOperationReadInput) {
        UInt64 t = (UInt64)c->mInputTime.mSampleTime;
        for (UInt32 i = 0; i < n; i++) {
            float *s = &ring[((t + i) % RING) * CHANS];
            memcpy(&buf[i * CHANS], s, CHANS * sizeof(float));
            memset(s, 0, CHANS * sizeof(float));   // read once: silence when MacVR stops feeding
        }
    }
    return noErr;
}
static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *c) {
    (void)d; (void)dev; (void)client; (void)op; (void)n; (void)c; return noErr;
}

// ---------------------------------------------------------------- plug-in boilerplate
static HRESULT QueryInterface(void *d, REFIID iid, LPVOID *out);
static ULONG AddRef(void *d) { (void)d; return ++refCount; }
static ULONG Release(void *d) { (void)d; return refCount ? --refCount : 0; }
static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef h) {
    (void)d; host = h;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    hostTicksPerFrame = (1e9 / RATE) * (Float64)tb.denom / (Float64)tb.numer;
    return noErr;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *out) {
    (void)d; (void)desc; (void)ci; (void)out; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) { (void)d; (void)dev; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci) { (void)d; (void)dev; (void)ci; return noErr; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci) { (void)d; (void)dev; (void)ci; return noErr; }
static OSStatus PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 a, void *i) { (void)d; (void)dev; (void)a; (void)i; return noErr; }
static OSStatus AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 a, void *i) { (void)d; (void)dev; (void)a; (void)i; return noErr; }

static AudioServerPlugInDriverInterface vtable = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformConfigChange, AbortConfigChange, HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface *vtablePtr = &vtable;
static AudioServerPlugInDriverRef driver = &vtablePtr;

static HRESULT QueryInterface(void *d, REFIID iid, LPVOID *out) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean ok = CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(req);
    if (!ok) { *out = NULL; return E_NOINTERFACE; }
    AddRef(d); *out = driver;
    return S_OK;
}
/// CFPlugIn factory (Info.plist CFPlugInFactories).
__attribute__((visibility("default"))) void *MacVRMic_Create(CFAllocatorRef alloc, CFUUIDRef type) {
    (void)alloc;
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? driver : NULL;
}
