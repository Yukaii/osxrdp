#include "MicrophoneManager.h"
#include "osxrdp/packet.h"
#include "utils.h"

#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <stdatomic.h>

// AudioDriver/OSXRDPAudioDriver.c 와 동일해야 함
static NSString* const kMicrophoneDeviceUID = @"OSXRDPMicrophone_UID";
static const AudioObjectPropertySelector kRecordingClientsProperty = 'orcc';

// 가상 장치 포맷 (48kHz, stereo, float32 interleaved)
static const double kDeviceSampleRate = 48000.0;
static const UInt32 kDeviceChannels = 2;

// jitter buffer (frame 단위, 48kHz 기준)
static const uint64_t kRingFrames = 48000 * 2;      // 2초
static const uint64_t kPrebufferFrames = 48000 / 25; // 재생 시작 전 40ms 확보
static const uint64_t kMaxBufferedFrames = 48000 / 4; // 250ms 이상 쌓이면 최신 데이터로 건너뜀

@interface MicrophoneImpl : NSObject

- (void)startWithClient:(xipc_t*)client;
- (void)stop;
- (void)handleFormatWithSampleRate:(int)sampleRate channels:(int)channels bitsPerSample:(int)bitsPerSample;
- (void)handleData:(const void*)pcm length:(int)pcmLen;

@end

@implementation MicrophoneImpl {
    xipc_t* _client;
    dispatch_queue_t _queue;
    AudioObjectID _deviceID;
    AudioObjectID _savedDefaultInput;
    BOOL _monitoring;
    BOOL _micRequested;

    AudioObjectPropertyListenerBlock _devicesListener;
    AudioObjectPropertyListenerBlock _recordingListener;

    // IPC 스레드와 listener queue 가 공유 (재생 장치 시작/정지, 변환기)
    NSLock* _lock;
    AudioUnit _outputUnit;
    AVAudioConverter* _converter;
    AVAudioFormat* _inputFormat;
    AVAudioFormat* _deviceFormat;

    // single producer (IPC 스레드) / single consumer (render 스레드)
    float* _ring;
    _Atomic uint64_t _writeFrames;
    _Atomic uint64_t _readFrames;
    BOOL _buffering; // render 스레드 전용
}

static OSStatus RenderCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp,
                               UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData);

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _queue = dispatch_queue_create("osxrdp.microphone", DISPATCH_QUEUE_SERIAL);
        _deviceID = kAudioObjectUnknown;
        _savedDefaultInput = kAudioObjectUnknown;
        _lock = [[NSLock alloc] init];
        _deviceFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                         sampleRate:kDeviceSampleRate
                                                           channels:kDeviceChannels
                                                        interleaved:YES];
        _ring = (float*)calloc(kRingFrames * kDeviceChannels, sizeof(float));
        atomic_store(&_writeFrames, 0);
        atomic_store(&_readFrames, 0);
        _buffering = YES;
    }

    return self;
}

- (void)dealloc {
    free(_ring);
}

// ---------------------------------------------------------------------------
// monitoring (listener queue)
// ---------------------------------------------------------------------------

- (void)startWithClient:(xipc_t*)client {
    dispatch_sync(_queue, ^{
        if (self->_monitoring) {
            return;
        }

        self->_client = client;
        self->_monitoring = YES;

        // 드라이버가 나중에 로드되거나 coreaudiod 가 재시작되는 경우를 위해 장치 목록 변경 감시
        __weak MicrophoneImpl* weakSelf = self;
        self->_devicesListener = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses) {
            [weakSelf attachDevice];
        };

        AudioObjectPropertyAddress devicesAddress = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devicesAddress, self->_queue, self->_devicesListener);

        [self attachDevice];
    });
}

- (void)stop {
    dispatch_sync(_queue, ^{
        if (self->_monitoring == NO) {
            return;
        }

        AudioObjectPropertyAddress devicesAddress = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &devicesAddress, self->_queue, self->_devicesListener);
        self->_devicesListener = nil;

        [self detachDevice];

        self->_monitoring = NO;
        self->_micRequested = NO;
        self->_client = NULL;
    });

    [self stopOutput];
}

// listener queue
- (void)attachDevice {
    if (_monitoring == NO) {
        return;
    }

    AudioObjectID deviceID = [MicrophoneImpl findDevice];

    if (deviceID == _deviceID) {
        return;
    }

    // 장치가 사라짐 (또는 바뀜)
    if (_deviceID != kAudioObjectUnknown) {
        [self detachDevice];
    }

    if (deviceID == kAudioObjectUnknown) {
        return;
    }

    _deviceID = deviceID;

    __weak MicrophoneImpl* weakSelf = self;
    _recordingListener = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses) {
        [weakSelf updateRecordingState];
    };

    AudioObjectPropertyAddress address = { kRecordingClientsProperty, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(_deviceID, &address, _queue, _recordingListener);

    [self setDefaultInput];
    [self updateRecordingState];

    NSLog(@"[MicrophoneManager] attached to OSXRDP Microphone (%u)", (unsigned)_deviceID);
}

// listener queue
- (void)detachDevice {
    if (_deviceID == kAudioObjectUnknown) {
        return;
    }

    AudioObjectPropertyAddress address = { kRecordingClientsProperty, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectRemovePropertyListenerBlock(_deviceID, &address, _queue, _recordingListener);
    _recordingListener = nil;

    [self restoreDefaultInput];

    if (_micRequested) {
        _micRequested = NO;
        [self sendMicRequest:OSXRDP_PACKETTYPE_MIC_REQ_STOP];
    }

    _deviceID = kAudioObjectUnknown;
}

// listener queue
- (void)updateRecordingState {
    if (_deviceID == kAudioObjectUnknown) {
        return;
    }

    BOOL recording = [MicrophoneImpl recordingClientCount:_deviceID] > 0;
    if (recording == _micRequested) {
        return;
    }

    _micRequested = recording;
    [self sendMicRequest:recording ? OSXRDP_PACKETTYPE_MIC_REQ_START : OSXRDP_PACKETTYPE_MIC_REQ_STOP];

    if (recording == NO) {
        [self stopOutput];
    }

    NSLog(@"[MicrophoneManager] microphone %s", recording ? "requested" : "released");
}

- (void)sendMicRequest:(int)packetType {
    if (_client == NULL) {
        return;
    }

    struct {
        int cmdType;
        int packetType;
    } __attribute__((packed)) msg = { OSXRDP_CMDTYPE_MIC, packetType };

    xipc_send_data(_client, &msg, sizeof(msg));
}

// 세션 동안 가상 마이크를 기본 입력 장치로 사용 (원격 세션에서 mac 의 물리 마이크는 의미가 없음)
- (void)setDefaultInput {
    AudioObjectID current = [MicrophoneImpl defaultInputDevice];
    if (current == _deviceID) {
        return;
    }

    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(_deviceID), &_deviceID) == noErr) {
        _savedDefaultInput = current;
    }
}

- (void)restoreDefaultInput {
    if (_savedDefaultInput == kAudioObjectUnknown) {
        return;
    }

    // 사용자가 세션 중에 직접 바꾼 경우는 유지
    if ([MicrophoneImpl defaultInputDevice] == _deviceID) {
        AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(_savedDefaultInput), &_savedDefaultInput);
    }

    _savedDefaultInput = kAudioObjectUnknown;
}

+ (AudioObjectID)findDevice {
    AudioObjectID deviceID = kAudioObjectUnknown;
    CFStringRef uid = (__bridge CFStringRef)kMicrophoneDeviceUID;
    UInt32 size = sizeof(deviceID);

    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(uid), &uid, &size, &deviceID) != noErr) {
        return kAudioObjectUnknown;
    }

    return deviceID;
}

+ (AudioObjectID)defaultInputDevice {
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);

    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &deviceID) != noErr) {
        return kAudioObjectUnknown;
    }

    return deviceID;
}

+ (int)recordingClientCount:(AudioObjectID)deviceID {
    CFPropertyListRef value = NULL;
    UInt32 size = sizeof(value);

    AudioObjectPropertyAddress address = { kRecordingClientsProperty, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &value) != noErr || value == NULL) {
        return 0;
    }

    int count = 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &count);
    }
    CFRelease(value);

    return count;
}

// ---------------------------------------------------------------------------
// playback into the virtual device (IPC thread)
// ---------------------------------------------------------------------------

- (void)handleFormatWithSampleRate:(int)sampleRate channels:(int)channels bitsPerSample:(int)bitsPerSample {
    if (bitsPerSample != 16 || (channels != 1 && channels != 2) || sampleRate < 8000 || sampleRate > 192000) {
        NSLog(@"[MicrophoneManager] unsupported format %d Hz, %d ch, %d bit", sampleRate, channels, bitsPerSample);
        return;
    }

    [_lock lock];

    _inputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                    sampleRate:sampleRate
                                                      channels:channels
                                                   interleaved:YES];
    _converter = [[AVAudioConverter alloc] initFromFormat:_inputFormat toFormat:_deviceFormat];
    if (channels == 1) {
        // 모노 마이크를 양쪽 채널로 복사
        _converter.channelMap = @[ @0, @0 ];
    }

    [_lock unlock];

    // 이미 녹음이 끝난 뒤 늦게 도착한 포맷이면 재생하지 않음
    if (_micRequested) {
        [self startOutput];
    }

    NSLog(@"[MicrophoneManager] client microphone %d Hz, %d ch", sampleRate, channels);
}

- (void)handleData:(const void*)pcm length:(int)pcmLen {
    [_lock lock];

    AVAudioConverter* converter = _converter;
    AVAudioFormat* inputFormat = _inputFormat;
    if (converter == nil || inputFormat == nil || _outputUnit == NULL) {
        [_lock unlock];
        return;
    }

    UInt32 bytesPerFrame = inputFormat.streamDescription->mBytesPerFrame;
    AVAudioFrameCount frameCount = (AVAudioFrameCount)(pcmLen / (int)bytesPerFrame);
    if (frameCount == 0) {
        [_lock unlock];
        return;
    }

    AVAudioPCMBuffer* inputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:frameCount];
    inputBuffer.frameLength = frameCount;
    memcpy(inputBuffer.mutableAudioBufferList->mBuffers[0].mData, pcm, frameCount * bytesPerFrame);

    AVAudioFrameCount outputCapacity = (AVAudioFrameCount)((double)frameCount * kDeviceSampleRate / inputFormat.sampleRate) + 64;
    AVAudioPCMBuffer* outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_deviceFormat frameCapacity:outputCapacity];

    __block BOOL supplied = NO;
    NSError* err = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:outputBuffer error:&err withInputFromBlock:^AVAudioBuffer* _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus* outStatus) {
        if (supplied) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }

        supplied = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return inputBuffer;
    }];

    [_lock unlock];

    if (status == AVAudioConverterOutputStatus_Error || outputBuffer.frameLength == 0) {
        return;
    }

    [self pushFrames:(const float*)outputBuffer.audioBufferList->mBuffers[0].mData count:outputBuffer.frameLength];
}

// producer
- (void)pushFrames:(const float*)frames count:(uint64_t)frameCount {
    uint64_t write = atomic_load_explicit(&_writeFrames, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&_readFrames, memory_order_acquire);
    uint64_t space = kRingFrames - (write - read);

    // 가득 찬 경우 새 데이터는 버림 (render 스레드가 지연을 따라잡음)
    if (frameCount > space) {
        frameCount = space;
    }

    for (uint64_t i = 0; i < frameCount; i++) {
        uint64_t index = ((write + i) % kRingFrames) * kDeviceChannels;
        _ring[index] = frames[i * kDeviceChannels];
        _ring[index + 1] = frames[i * kDeviceChannels + 1];
    }

    atomic_store_explicit(&_writeFrames, write + frameCount, memory_order_release);
}

// consumer (render 스레드)
- (void)pullFrames:(float*)frames count:(UInt32)frameCount {
    uint64_t read = atomic_load_explicit(&_readFrames, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&_writeFrames, memory_order_acquire);
    uint64_t available = write - read;

    // 네트워크 지연 등으로 쌓인 데이터는 건너뛰어 지연 누적 방지
    if (available > kMaxBufferedFrames) {
        read = write - kPrebufferFrames;
        available = kPrebufferFrames;
    }

    // 버퍼가 비었다가 다시 채워질 때는 jitter 흡수를 위해 일정량을 모은 뒤 재생
    if (_buffering && available < kPrebufferFrames) {
        memset(frames, 0, frameCount * kDeviceChannels * sizeof(float));
        atomic_store_explicit(&_readFrames, read, memory_order_release);
        return;
    }
    _buffering = NO;

    UInt32 copyFrames = available < frameCount ? (UInt32)available : frameCount;
    for (UInt32 i = 0; i < copyFrames; i++) {
        uint64_t index = ((read + i) % kRingFrames) * kDeviceChannels;
        frames[i * kDeviceChannels] = _ring[index];
        frames[i * kDeviceChannels + 1] = _ring[index + 1];
    }

    if (copyFrames < frameCount) {
        memset(frames + copyFrames * kDeviceChannels, 0, (frameCount - copyFrames) * kDeviceChannels * sizeof(float));
        _buffering = YES;
    }

    atomic_store_explicit(&_readFrames, read + copyFrames, memory_order_release);
}

static OSStatus RenderCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp,
                               UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData) {
    MicrophoneImpl* impl = (__bridge MicrophoneImpl*)inRefCon;

    if (ioData == NULL || ioData->mNumberBuffers < 1 || ioData->mBuffers[0].mData == NULL) {
        return noErr;
    }

    [impl pullFrames:(float*)ioData->mBuffers[0].mData count:inNumberFrames];
    return noErr;
}

- (void)startOutput {
    [_lock lock];

    if (_outputUnit != NULL || _deviceID == kAudioObjectUnknown) {
        [_lock unlock];
        return;
    }

    AudioComponentDescription desc = { kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    AudioUnit unit = NULL;

    if (component == NULL || AudioComponentInstanceNew(component, &unit) != noErr) {
        [_lock unlock];
        NSLog(@"[MicrophoneManager] could not create output unit");
        return;
    }

    AudioObjectID deviceID = _deviceID;
    AURenderCallbackStruct callback = { RenderCallback, (__bridge void*)self };
    const AudioStreamBasicDescription* format = _deviceFormat.streamDescription;

    OSStatus status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, sizeof(deviceID));
    if (status == noErr) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format, sizeof(*format));
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    }
    if (status == noErr) {
        status = AudioUnitInitialize(unit);
    }

    // render 스레드가 시작되기 전에 버퍼 초기화
    atomic_store(&_readFrames, atomic_load(&_writeFrames));
    _buffering = YES;

    if (status == noErr) {
        status = AudioOutputUnitStart(unit);
    }

    if (status != noErr) {
        AudioComponentInstanceDispose(unit);
        [_lock unlock];
        NSLog(@"[MicrophoneManager] could not start output unit (%d)", (int)status);
        return;
    }

    _outputUnit = unit;
    [_lock unlock];
}

- (void)stopOutput {
    [_lock lock];

    if (_outputUnit != NULL) {
        AudioOutputUnitStop(_outputUnit);
        AudioUnitUninitialize(_outputUnit);
        AudioComponentInstanceDispose(_outputUnit);
        _outputUnit = NULL;
    }

    _converter = nil;
    _inputFormat = nil;

    [_lock unlock];
}

@end


MicrophoneManager::MicrophoneManager() :
    _impl(NULL)
{}

MicrophoneManager::~MicrophoneManager() {
    Stop();
}

void MicrophoneManager::Start(xipc_t* client) {
    // 잠금 화면 agent (root) 에서는 사용하지 않음
    if (is_root_process() != 0 || client == NULL || _impl != NULL) {
        return;
    }

    MicrophoneImpl* impl = [[MicrophoneImpl alloc] init];
    _impl = (__bridge_retained void*)impl;

    [impl startWithClient:client];
}

void MicrophoneManager::Stop() {
    if (_impl == NULL) {
        return;
    }

    MicrophoneImpl* impl = (__bridge_transfer MicrophoneImpl*)_impl;
    _impl = NULL;

    [impl stop];
}

void MicrophoneManager::HandleCommand(xipc_t* client, xstream_t* cmd) {
    (void)client;

    if (_impl == NULL) {
        return;
    }

    MicrophoneImpl* impl = (__bridge MicrophoneImpl*)_impl;
    int packetType = xstream_readInt32(cmd);

    switch (packetType) {
        case OSXRDP_PACKETTYPE_MIC_FORMAT: {
            int sampleRate = xstream_readInt32(cmd);
            int channels = xstream_readInt32(cmd);
            int bitsPerSample = xstream_readInt32(cmd);

            [impl handleFormatWithSampleRate:sampleRate channels:channels bitsPerSample:bitsPerSample];
            break;
        }
        case OSXRDP_PACKETTYPE_MIC_DATA: {
            int dataLen = xstream_readInt32(cmd);
            const void* data = xstream_readData(cmd, dataLen);

            if (data != NULL && dataLen > 0) {
                [impl handleData:data length:dataLen];
            }
            break;
        }
        default:
            break;
    }
}
