//
//  OSXRDPAudioDriver.c
//
//  "OSXRDP Microphone" virtual audio device (Core Audio AudioServerPlugIn).
//
//  The device is a loopback: audio written to its output stream is read back
//  from its input stream. The OSXRDP agent plays the RDP client's microphone
//  into the output, and macOS apps record it from the input like any other
//  microphone.
//
//  The device also publishes a custom property with the number of clients
//  doing IO other than the agent, so the agent only asks the RDP client for
//  its microphone while a Mac app is actually recording.
//
//  Structure based on Apple's NullAudio AudioServerPlugIn sample.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

// ---------------------------------------------------------------------------
// constants
// ---------------------------------------------------------------------------

#define kAgent_BundleID             "com.byungho.osxrdp.mainapp"

#define kDevice_Name                "OSXRDP Microphone"
#define kDevice_Manufacturer        "osxrdp"
#define kDevice_UID                 "OSXRDPMicrophone_UID"
#define kDevice_ModelUID            "OSXRDPMicrophone_ModelUID"

// number of IO clients other than the agent (CFNumber)
#define kDeviceCustomProperty_RecordingClients 'orcc'

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
};

static const Float64 kSampleRate = 48000.0;
static const UInt32 kChannelCount = 2;
static const UInt32 kBytesPerFrame = sizeof(Float32) * 2;

// loopback ring buffer, also the zero time stamp period (~341ms at 48kHz)
#define kRingBufferFrames 16384
static const UInt32 kLatencyFrames = 0;
static const UInt32 kSafetyOffsetFrames = 0;

#define kMaxClients 64

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------

static pthread_mutex_t gPlugIn_StateMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gDevice_IOMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gPlugIn_RefCount = 0;
static AudioServerPlugInHostRef gPlugIn_Host = NULL;

static Float64 gDevice_HostTicksPerFrame = 0.0;
static UInt64 gDevice_IOIsRunning = 0;
static UInt64 gDevice_NumberTimeStamps = 0;
static UInt64 gDevice_AnchorHostTime = 0;

// loopback buffer (interleaved Float32 stereo), indexed by sample time
static Float32 gLoopback_Buffer[kRingBufferFrames * 2];
// end (exclusive) of the samples written by the last WriteMix
static _Atomic Float64 gLoopback_WriteEndSampleTime = -1.0;

struct ClientInfo {
    UInt32 clientID;
    bool isAgent;
    bool ioRunning;
};

static struct ClientInfo gClients[kMaxClients];
static UInt32 gClientCount = 0;
static UInt32 gRecordingClientCount = 0;

// ---------------------------------------------------------------------------
// interface
// ---------------------------------------------------------------------------

static HRESULT OSXRDP_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG OSXRDP_AddRef(void* inDriver);
static ULONG OSXRDP_Release(void* inDriver);
static OSStatus OSXRDP_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus OSXRDP_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus OSXRDP_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus OSXRDP_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus OSXRDP_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus OSXRDP_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus OSXRDP_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean OSXRDP_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus OSXRDP_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus OSXRDP_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus OSXRDP_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus OSXRDP_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus OSXRDP_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus OSXRDP_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus OSXRDP_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus OSXRDP_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus OSXRDP_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus OSXRDP_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus OSXRDP_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface = {
    NULL,
    OSXRDP_QueryInterface,
    OSXRDP_AddRef,
    OSXRDP_Release,
    OSXRDP_Initialize,
    OSXRDP_CreateDevice,
    OSXRDP_DestroyDevice,
    OSXRDP_AddDeviceClient,
    OSXRDP_RemoveDeviceClient,
    OSXRDP_PerformDeviceConfigurationChange,
    OSXRDP_AbortDeviceConfigurationChange,
    OSXRDP_HasProperty,
    OSXRDP_IsPropertySettable,
    OSXRDP_GetPropertyDataSize,
    OSXRDP_GetPropertyData,
    OSXRDP_SetPropertyData,
    OSXRDP_StartIO,
    OSXRDP_StopIO,
    OSXRDP_GetZeroTimeStamp,
    OSXRDP_WillDoIOOperation,
    OSXRDP_BeginIOOperation,
    OSXRDP_DoIOOperation,
    OSXRDP_EndIOOperation
};

static AudioServerPlugInDriverInterface* gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef gAudioServerPlugInDriverRef = &gAudioServerPlugInDriverInterfacePtr;

// ---------------------------------------------------------------------------
// factory (named in Info.plist CFPlugInFactories)
// ---------------------------------------------------------------------------

void* OSXRDPAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void* OSXRDPAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;

    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gAudioServerPlugInDriverRef;
    }

    return NULL;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

static bool IsValidObject(AudioObjectID inObjectID) {
    return inObjectID == kObjectID_PlugIn || inObjectID == kObjectID_Device ||
           inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output;
}

static AudioStreamBasicDescription MakeStreamFormat(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));

    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = kChannelCount;
    format.mBitsPerChannel = 32;

    return format;
}

// must be called with gPlugIn_StateMutex held. returns true if the count changed
static bool UpdateRecordingClientCount(void) {
    UInt32 count = 0;

    for (UInt32 i = 0; i < gClientCount; i++) {
        if (gClients[i].ioRunning && gClients[i].isAgent == false) {
            count++;
        }
    }

    if (count == gRecordingClientCount) {
        return false;
    }

    gRecordingClientCount = count;
    return true;
}

static void NotifyRecordingClientCountChanged(void) {
    if (gPlugIn_Host == NULL) {
        return;
    }

    AudioObjectPropertyAddress address = {
        kDeviceCustomProperty_RecordingClients,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &address);
}

static struct ClientInfo* FindClient(UInt32 clientID) {
    for (UInt32 i = 0; i < gClientCount; i++) {
        if (gClients[i].clientID == clientID) {
            return &gClients[i];
        }
    }

    return NULL;
}

// ---------------------------------------------------------------------------
// basic COM
// ---------------------------------------------------------------------------

static HRESULT OSXRDP_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gAudioServerPlugInDriverRef || outInterface == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requestedUUID == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requestedUUID, IUnknownUUID) || CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);

        *outInterface = gAudioServerPlugInDriverRef;
        result = 0;
    }

    CFRelease(requestedUUID);
    return result;
}

static ULONG OSXRDP_AddRef(void* inDriver) {
    if (inDriver != gAudioServerPlugInDriverRef) {
        return 0;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    ULONG refCount = ++gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    return refCount;
}

static ULONG OSXRDP_Release(void* inDriver) {
    if (inDriver != gAudioServerPlugInDriverRef) {
        return 0;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gPlugIn_RefCount > 0) {
        --gPlugIn_RefCount;
    }
    ULONG refCount = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    return refCount;
}

// ---------------------------------------------------------------------------
// basic operations
// ---------------------------------------------------------------------------

static OSStatus OSXRDP_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gAudioServerPlugInDriverRef) {
        return kAudioHardwareBadObjectError;
    }

    gPlugIn_Host = inHost;

    struct mach_timebase_info timeBaseInfo;
    mach_timebase_info(&timeBaseInfo);
    Float64 hostClockFrequency = (Float64)timeBaseInfo.denom / (Float64)timeBaseInfo.numer * 1000000000.0;
    gDevice_HostTicksPerFrame = hostClockFrequency / kSampleRate;

    return 0;
}

static OSStatus OSXRDP_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;

    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OSXRDP_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver;
    (void)inDeviceObjectID;

    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OSXRDP_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device || inClientInfo == NULL) {
        return kAudioHardwareBadObjectError;
    }

    bool isAgent = false;
    if (inClientInfo->mBundleID != NULL) {
        CFStringRef agentBundleID = CFSTR(kAgent_BundleID);
        isAgent = CFStringCompare(inClientInfo->mBundleID, agentBundleID, 0) == kCFCompareEqualTo;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (FindClient(inClientInfo->mClientID) == NULL && gClientCount < kMaxClients) {
        gClients[gClientCount].clientID = inClientInfo->mClientID;
        gClients[gClientCount].isAgent = isAgent;
        gClients[gClientCount].ioRunning = false;
        gClientCount++;
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    return 0;
}

static OSStatus OSXRDP_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device || inClientInfo == NULL) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    for (UInt32 i = 0; i < gClientCount; i++) {
        if (gClients[i].clientID == inClientInfo->mClientID) {
            // a client that goes away without StopIO (e.g. it crashed) no longer keeps the device running
            if (gClients[i].ioRunning && gDevice_IOIsRunning > 0) {
                gDevice_IOIsRunning--;
            }
            gClients[i] = gClients[gClientCount - 1];
            gClientCount--;
            break;
        }
    }
    bool changed = UpdateRecordingClientCount();
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    if (changed) {
        NotifyRecordingClientCountChanged();
    }

    return 0;
}

static OSStatus OSXRDP_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction;
    (void)inChangeInfo;

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    return 0;
}

static OSStatus OSXRDP_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction;
    (void)inChangeInfo;

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    return 0;
}

// ---------------------------------------------------------------------------
// properties
// ---------------------------------------------------------------------------

static Boolean OSXRDP_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    UInt32 size = 0;

    if (inDriver != gAudioServerPlugInDriverRef || inAddress == NULL || IsValidObject(inObjectID) == false) {
        return false;
    }

    return OSXRDP_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &size) == 0;
}

static OSStatus OSXRDP_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    UInt32 size = 0;

    if (inDriver != gAudioServerPlugInDriverRef || inAddress == NULL || outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    OSStatus status = OSXRDP_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &size);
    if (status != 0) {
        return status;
    }

    // format / sample rate can be "set" to the only supported value
    *outIsSettable = (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) ||
                     ((inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) &&
                      (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat));

    return 0;
}

static OSStatus GetPlugInPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0;
            return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetPlugInPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID*)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID*)outData = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID*)outData = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef*)outData = CFSTR(kDevice_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef*)outData = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) {
                *outDataSize = 0;
                return 0;
            }
            *(AudioObjectID*)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0;
            return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;

            CFStringRef uid = *(const CFStringRef*)inQualifierData;
            bool isOurs = uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo;
            *(AudioObjectID*)outData = isOurs ? kObjectID_Device : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                *outDataSize = 2 * sizeof(AudioObjectID);
            }
            else if (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                *outDataSize = sizeof(AudioObjectID);
            }
            else {
                *outDataSize = 0;
            }
            return 0;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return 0;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription);
            return 0;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return 0;
        case kDeviceCustomProperty_RecordingClients:
            *outDataSize = sizeof(CFPropertyListRef);
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID*)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID*)outData = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID*)outData = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef*)outData = CFSTR(kDevice_Name);
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef*)outData = CFSTR(kDevice_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioDevicePropertyDeviceUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef*)outData = CFSTR(kDevice_UID);
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioDevicePropertyModelUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef*)outData = CFSTR(kDevice_ModelUID);
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            UInt32 count = 0;
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);

            if ((inAddress->mScope == kAudioObjectPropertyScopeGlobal || inAddress->mScope == kAudioObjectPropertyScopeInput) && count < capacity) {
                ids[count++] = kObjectID_Stream_Input;
            }
            if ((inAddress->mScope == kAudioObjectPropertyScopeGlobal || inAddress->mScope == kAudioObjectPropertyScopeOutput) && count < capacity) {
                ids[count++] = kObjectID_Stream_Output;
            }

            *outDataSize = count * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioDevicePropertyRelatedDevices:
            if (inDataSize < sizeof(AudioObjectID)) {
                *outDataSize = 0;
                return 0;
            }
            *(AudioObjectID*)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return 0;
        case kAudioDevicePropertyTransportType:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyClockDomain:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyDeviceIsAlive:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyDeviceIsRunning:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *(UInt32*)outData = gDevice_IOIsRunning > 0 ? 1 : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            // can be the default input, but never the default output
            *(UInt32*)outData = inAddress->mScope == kAudioObjectPropertyScopeOutput ? 0 : 1;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyLatency:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = kLatencyFrames;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertySafetyOffset:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = kSafetyOffsetFrames;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyNominalSampleRate:
            if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            *(Float64*)outData = kSampleRate;
            *outDataSize = sizeof(Float64);
            return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            if (inDataSize < sizeof(AudioValueRange)) {
                *outDataSize = 0;
                return 0;
            }
            ((AudioValueRange*)outData)->mMinimum = kSampleRate;
            ((AudioValueRange*)outData)->mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioValueRange);
            return 0;
        case kAudioDevicePropertyIsHidden:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription);
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;

            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mChannelBitmap = 0;
            layout->mNumberChannelDescriptions = kChannelCount;
            for (UInt32 i = 0; i < kChannelCount; i++) {
                layout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Left + i;
                layout->mChannelDescriptions[i].mChannelFlags = 0;
                layout->mChannelDescriptions[i].mCoordinates[0] = 0;
                layout->mChannelDescriptions[i].mCoordinates[1] = 0;
                layout->mChannelDescriptions[i].mCoordinates[2] = 0;
            }
            *outDataSize = size;
            return 0;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = kRingBufferFrames;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioObjectPropertyCustomPropertyInfoList: {
            if (inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo)) {
                *outDataSize = 0;
                return 0;
            }
            AudioServerPlugInCustomPropertyInfo* info = (AudioServerPlugInCustomPropertyInfo*)outData;
            info->mSelector = kDeviceCustomProperty_RecordingClients;
            info->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
            info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return 0;
        }
        case kDeviceCustomProperty_RecordingClients: {
            if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;

            pthread_mutex_lock(&gPlugIn_StateMutex);
            SInt32 count = (SInt32)gRecordingClientCount;
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            // the caller releases the returned object
            *(CFPropertyListRef*)outData = CFNumberCreate(NULL, kCFNumberSInt32Type, &count);
            *outDataSize = sizeof(CFPropertyListRef);
            return 0;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    bool isInput = inObjectID == kObjectID_Stream_Input;

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID*)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID*)outData = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID*)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;
        case kAudioStreamPropertyIsActive:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyDirection:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = isInput ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyTerminalType:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyStartingChannel:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyLatency:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32*)outData = kLatencyFrames;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            *(AudioStreamBasicDescription*)outData = MakeStreamFormat();
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inDataSize < sizeof(AudioStreamRangedDescription)) {
                *outDataSize = 0;
                return 0;
            }
            AudioStreamRangedDescription* desc = (AudioStreamRangedDescription*)outData;
            desc->mFormat = MakeStreamFormat();
            desc->mSampleRateRange.mMinimum = kSampleRate;
            desc->mSampleRateRange.mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return 0;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus OSXRDP_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;

    if (inDriver != gAudioServerPlugInDriverRef || inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            return GetPlugInPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Device:
            return GetDevicePropertyDataSize(inAddress, outDataSize);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            return GetStreamPropertyDataSize(inAddress, outDataSize);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus OSXRDP_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inClientProcessID;

    if (inDriver != gAudioServerPlugInDriverRef || inAddress == NULL || outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            return GetPlugInPropertyData(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectID_Device:
            return GetDevicePropertyData(inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            return GetStreamPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus OSXRDP_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;

    if (inDriver != gAudioServerPlugInDriverRef || inAddress == NULL || inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    // only the fixed format can be set
    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64*)inData == kSampleRate ? 0 : kAudioHardwareIllegalOperationError;
    }

    if ((inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) &&
        (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;

        const AudioStreamBasicDescription* format = (const AudioStreamBasicDescription*)inData;
        AudioStreamBasicDescription supported = MakeStreamFormat();
        if (format->mSampleRate != supported.mSampleRate || format->mFormatID != supported.mFormatID ||
            format->mChannelsPerFrame != supported.mChannelsPerFrame || format->mBitsPerChannel != supported.mBitsPerChannel) {
            return kAudioDeviceUnsupportedFormatError;
        }
        return 0;
    }

    return kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------------------
// IO
// ---------------------------------------------------------------------------

static OSStatus OSXRDP_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);

    if (gDevice_IOIsRunning == 0) {
        gDevice_NumberTimeStamps = 0;
        gDevice_AnchorHostTime = mach_absolute_time();
        memset(gLoopback_Buffer, 0, sizeof(gLoopback_Buffer));
        atomic_store(&gLoopback_WriteEndSampleTime, -1.0);
    }
    gDevice_IOIsRunning++;

    struct ClientInfo* client = FindClient(inClientID);
    if (client != NULL) {
        client->ioRunning = true;
    }
    bool changed = UpdateRecordingClientCount();

    pthread_mutex_unlock(&gPlugIn_StateMutex);

    if (changed) {
        NotifyRecordingClientCountChanged();
    }

    return 0;
}

static OSStatus OSXRDP_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);

    if (gDevice_IOIsRunning > 0) {
        gDevice_IOIsRunning--;
    }

    struct ClientInfo* client = FindClient(inClientID);
    if (client != NULL) {
        client->ioRunning = false;
    }
    bool changed = UpdateRecordingClientCount();

    pthread_mutex_unlock(&gPlugIn_StateMutex);

    if (changed) {
        NotifyRecordingClientCountChanged();
    }

    return 0;
}

static OSStatus OSXRDP_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gDevice_IOMutex);

    // one zero time stamp per ring buffer period, anchored at StartIO
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerPeriod = gDevice_HostTicksPerFrame * (Float64)kRingBufferFrames;
    UInt64 nextHostTime = gDevice_AnchorHostTime + (UInt64)((Float64)(gDevice_NumberTimeStamps + 1) * hostTicksPerPeriod);
    if (currentHostTime >= nextHostTime) {
        gDevice_NumberTimeStamps++;
    }

    *outSampleTime = (Float64)(gDevice_NumberTimeStamps * kRingBufferFrames);
    *outHostTime = gDevice_AnchorHostTime + (UInt64)((Float64)gDevice_NumberTimeStamps * hostTicksPerPeriod);
    *outSeed = 1;

    pthread_mutex_unlock(&gDevice_IOMutex);

    return 0;
}

static OSStatus OSXRDP_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    bool willDo = inOperationID == kAudioServerPlugInIOOperationReadInput ||
                  inOperationID == kAudioServerPlugInIOOperationWriteMix;

    if (outWillDo != NULL) {
        *outWillDo = willDo;
    }
    if (outWillDoInPlace != NULL) {
        *outWillDoInPlace = true;
    }

    return 0;
}

static OSStatus OSXRDP_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    return 0;
}

// output (from the agent) -> loopback buffer
static void WriteLoopback(Float64 sampleTime, UInt32 frameCount, const Float32* source) {
    Float64 writeEnd = atomic_load(&gLoopback_WriteEndSampleTime);

    // clear samples skipped since the last write so they read back as silence
    if (writeEnd >= 0.0 && sampleTime > writeEnd) {
        Float64 gap = sampleTime - writeEnd;
        UInt64 clearCount = gap > (Float64)kRingBufferFrames ? kRingBufferFrames : (UInt64)gap;
        UInt64 start = (UInt64)writeEnd;
        for (UInt64 i = 0; i < clearCount; i++) {
            UInt64 index = ((start + i) % kRingBufferFrames) * kChannelCount;
            gLoopback_Buffer[index] = 0.0f;
            gLoopback_Buffer[index + 1] = 0.0f;
        }
    }

    UInt64 start = (UInt64)sampleTime;
    for (UInt32 i = 0; i < frameCount; i++) {
        UInt64 index = ((start + i) % kRingBufferFrames) * kChannelCount;
        gLoopback_Buffer[index] = source[i * kChannelCount];
        gLoopback_Buffer[index + 1] = source[i * kChannelCount + 1];
    }

    Float64 newEnd = sampleTime + frameCount;
    if (newEnd > writeEnd) {
        atomic_store(&gLoopback_WriteEndSampleTime, newEnd);
    }
}

// loopback buffer -> input (to recording apps)
static void ReadLoopback(Float64 sampleTime, UInt32 frameCount, Float32* destination) {
    Float64 writeEnd = atomic_load(&gLoopback_WriteEndSampleTime);
    UInt64 start = (UInt64)sampleTime;

    for (UInt32 i = 0; i < frameCount; i++) {
        Float64 frameTime = sampleTime + i;

        // not written yet, or already overwritten by a later lap
        if (writeEnd < 0.0 || frameTime >= writeEnd || writeEnd - frameTime > (Float64)kRingBufferFrames) {
            destination[i * kChannelCount] = 0.0f;
            destination[i * kChannelCount + 1] = 0.0f;
            continue;
        }

        UInt64 index = ((start + i) % kRingBufferFrames) * kChannelCount;
        destination[i * kChannelCount] = gLoopback_Buffer[index];
        destination[i * kChannelCount + 1] = gLoopback_Buffer[index + 1];
    }
}

static OSStatus OSXRDP_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inClientID;
    (void)ioSecondaryBuffer;

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) {
        return 0;
    }

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_Stream_Output) {
        WriteLoopback(inIOCycleInfo->mOutputTime.mSampleTime, inIOBufferFrameSize, (const Float32*)ioMainBuffer);
    }
    else if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObjectID_Stream_Input) {
        ReadLoopback(inIOCycleInfo->mInputTime.mSampleTime, inIOBufferFrameSize, (Float32*)ioMainBuffer);
    }

    return 0;
}

static OSStatus OSXRDP_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    return 0;
}
