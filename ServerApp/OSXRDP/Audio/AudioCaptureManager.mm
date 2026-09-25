#include "AudioCaptureManager.h"
#include "osxrdp/packet.h"
#include "utils.h"

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

#include <dlfcn.h>
#include <unistd.h>

typedef void (*on_audio_data)(const void* pcm, int pcmLen, void* userData);

// 시스템 오디오 녹음 (process tap) 권한 상태. 공개 API 가 없어 TCC SPI 를 사용 (없으면 UNKNOWN)
enum AudioCapturePermission {
    AUDIO_CAPTURE_PERMISSION_GRANTED = 0,
    AUDIO_CAPTURE_PERMISSION_DENIED = 1,
    AUDIO_CAPTURE_PERMISSION_UNKNOWN = 2,
};

typedef int (*TCCAccessPreflightFn)(CFStringRef service, CFDictionaryRef options);
typedef void (*TCCAccessRequestFn)(CFStringRef service, CFDictionaryRef options, void (^callback)(Boolean granted));

static CFStringRef const kTCCServiceAudioCapture = CFSTR("kTCCServiceAudioCapture");

static void* GetTCCSymbol(const char* name) {
    static void* tcc = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW);
    });

    return tcc != NULL ? dlsym(tcc, name) : NULL;
}

static int GetAudioCapturePermission(void) {
    TCCAccessPreflightFn preflight = (TCCAccessPreflightFn)GetTCCSymbol("TCCAccessPreflight");
    if (preflight == NULL) {
        return AUDIO_CAPTURE_PERMISSION_UNKNOWN;
    }

    int result = preflight(kTCCServiceAudioCapture, NULL);
    if (result == AUDIO_CAPTURE_PERMISSION_GRANTED || result == AUDIO_CAPTURE_PERMISSION_DENIED) {
        return result;
    }

    return AUDIO_CAPTURE_PERMISSION_UNKNOWN;
}

static bool RequestAudioCapturePermission(void (^callback)(bool granted)) {
    TCCAccessRequestFn request = (TCCAccessRequestFn)GetTCCSymbol("TCCAccessRequest");
    if (request == NULL) {
        return false;
    }

    request(kTCCServiceAudioCapture, NULL, ^(Boolean granted) {
        callback(granted != 0);
    });

    return true;
}

// ScreenCaptureKit 에서 지원하는 캡처 포맷 (이후 AVAudioConverter 로 클라이언트 포맷 변환)
static const int CAPTURE_SAMPLE_RATE = 48000;
static const int CAPTURE_CHANNELS = 2;

// 디스플레이 구성 변경 (가상 모니터 등) 으로 스트림이 중단된 경우 재시작 시도
static const int MAX_RESTART_COUNT = 5;
static const int64_t RESTART_DELAY_NS = 1 * NSEC_PER_SEC;
static const int64_t STOP_TIMEOUT_NS = 3 * NSEC_PER_SEC;

// 무음이 시작된 뒤에도 잠시 전송 (AAC 인코더의 lookahead 에 남은 소리를 내보내고 클라이언트 버퍼를 비움)
static const int SILENCE_HANGOVER_MS = 250;

// AAC-LC (xrdp chansrv 와 동일: raw frame, frame 당 1024 sample)
static const AVAudioFrameCount AAC_FRAMES_PER_PACKET = 1024;
static const NSInteger AAC_BIT_RATE = 96000;

API_AVAILABLE(macos(13.0))
@interface AudioCaptureImpl : NSObject<SCStreamOutput, SCStreamDelegate>

- (instancetype)initWithSampleRate:(int)sampleRate
                          Channels:(int)channels
                             Codec:(int)codec
                      DataCallback:(on_audio_data)cb
              DataCallbackUserData:(void*)userData;
- (BOOL)start;
- (void)stop;

@end

@implementation AudioCaptureImpl {
    SCStream* _stream;
    dispatch_queue_t _audioQue;

    // process tap (macOS 14.2+): 캡처한 소리를 로컬 스피커에서는 음소거
    AudioObjectID _tapId;
    AudioObjectID _aggregateId;
    AudioDeviceIOProcID _ioProcId;
    AVAudioFormat* _tapFormat;
    BOOL _defaultOutputListening;
    AudioObjectPropertyListenerBlock _defaultOutputListenerBlock;

    AVAudioFormat* _outputFormat;
    AVAudioConverter* _converter;
    AVAudioFormat* _converterInputFormat;

    on_audio_data _dataCb;
    void* _dataCbUserData;

    BOOL _stopped;
    int _restartCount;
    int _silentFrames;

    // AAC 인코딩 (codec == OSXRDP_AUDIO_CODEC_AAC)
    AVAudioConverter* _aacEncoder;
    AVAudioFormat* _aacFormat;
    AVAudioPCMBuffer* _aacInput;        // 인코더에 넣을 1024 frame
    int16_t* _aacFifo;                  // 1024 frame 미만으로 남은 PCM
    AVAudioFrameCount _aacFifoFrames;
}

- (instancetype)initWithSampleRate:(int)sampleRate
                          Channels:(int)channels
                             Codec:(int)codec
                      DataCallback:(on_audio_data)cb
              DataCallbackUserData:(void*)userData {
    self = [super init];
    if (self != nil) {
        _outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                         sampleRate:sampleRate
                                                           channels:channels
                                                        interleaved:YES];

        if (codec == OSXRDP_AUDIO_CODEC_AAC && [self createAACEncoderWithSampleRate:sampleRate channels:channels] == NO) {
            NSLog(@"[AudioCaptureImpl] could not create AAC encoder");
            _outputFormat = nil;
        }
        _dataCb = cb;
        _dataCbUserData = userData;
        _stopped = NO;
        _restartCount = 0;

        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _audioQue = dispatch_queue_create("osxrdp.audio", attr);
    }

    return self;
}

- (void)dealloc {
    free(_aacFifo);
}

- (BOOL)createAACEncoderWithSampleRate:(int)sampleRate channels:(int)channels {
    _aacFormat = [[AVAudioFormat alloc] initWithSettings:@{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(sampleRate),
        AVNumberOfChannelsKey: @(channels),
    }];
    if (_aacFormat == nil) {
        return NO;
    }

    _aacEncoder = [[AVAudioConverter alloc] initFromFormat:_outputFormat toFormat:_aacFormat];
    if (_aacEncoder == nil) {
        return NO;
    }
    _aacEncoder.bitRate = AAC_BIT_RATE;

    _aacInput = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_outputFormat frameCapacity:AAC_FRAMES_PER_PACKET];
    _aacFifo = (int16_t*)calloc(AAC_FRAMES_PER_PACKET * channels, sizeof(int16_t));
    _aacFifoFrames = 0;

    return _aacInput != nil && _aacFifo != NULL;
}

// PCM 을 1024 frame 단위로 AAC 인코딩하여 packet (raw AAC frame) 단위로 전달
- (void)encodeAAC:(const int16_t*)samples frames:(AVAudioFrameCount)frameCount {
    UInt32 channels = _outputFormat.channelCount;

    while (frameCount > 0) {
        AVAudioFrameCount copyFrames = MIN(frameCount, AAC_FRAMES_PER_PACKET - _aacFifoFrames);
        memcpy(_aacFifo + _aacFifoFrames * channels, samples, copyFrames * channels * sizeof(int16_t));
        _aacFifoFrames += copyFrames;
        samples += copyFrames * channels;
        frameCount -= copyFrames;

        if (_aacFifoFrames < AAC_FRAMES_PER_PACKET) {
            break;
        }

        memcpy(_aacInput.mutableAudioBufferList->mBuffers[0].mData, _aacFifo, AAC_FRAMES_PER_PACKET * channels * sizeof(int16_t));
        _aacInput.frameLength = AAC_FRAMES_PER_PACKET;
        _aacFifoFrames = 0;

        AVAudioCompressedBuffer* packet = [[AVAudioCompressedBuffer alloc] initWithFormat:_aacFormat
                                                                           packetCapacity:1
                                                                        maximumPacketSize:_aacEncoder.maximumOutputPacketSize];

        // 인코더 lookahead 로 처음 몇 번은 packet 이 나오지 않을 수 있음
        __block BOOL supplied = NO;
        AVAudioPCMBuffer* input = _aacInput;
        NSError* err = nil;
        AVAudioConverterOutputStatus status = [_aacEncoder convertToBuffer:packet error:&err withInputFromBlock:^AVAudioBuffer* _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus* outStatus) {
            if (supplied) {
                *outStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }

            supplied = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return input;
        }];

        if (status == AVAudioConverterOutputStatus_Error) {
            continue;
        }

        for (AVAudioPacketCount i = 0; i < packet.packetCount; i++) {
            const AudioStreamPacketDescription* desc = &packet.packetDescriptions[i];
            _dataCb((const uint8_t*)packet.data + desc->mStartOffset, (int)desc->mDataByteSize, _dataCbUserData);
        }
    }
}

- (BOOL)start {
    if (_outputFormat == nil) {
        NSLog(@"[AudioCaptureImpl::start] invalid output format");
        return NO;
    }

    // process tap 은 캡처한 소리를 로컬에서 음소거할 수 있으므로 우선 사용 (원격 컴퓨터에서만 재생)
    if (@available(macOS 14.2, *)) {
        int permission = GetAudioCapturePermission();
        if (permission == AUDIO_CAPTURE_PERMISSION_GRANTED) {
            if ([self startTap]) {
                return YES;
            }
        }
        else if (permission == AUDIO_CAPTURE_PERMISSION_UNKNOWN) {
            // 권한 요청 후 허용되면 tap 으로 전환. 그 전까지는 ScreenCaptureKit 으로 캡처 (로컬에서도 재생됨)
            __weak AudioCaptureImpl* weakSelf = self;
            RequestAudioCapturePermission(^(bool granted) {
                if (granted) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        [weakSelf switchToTap];
                    });
                }
            });
        }
        else {
            NSLog(@"[AudioCaptureImpl::start] system audio recording permission denied. audio also plays on this Mac");
        }
    }

    return [self startScreenCaptureAudio];
}

- (BOOL)startScreenCaptureAudio {
    SCDisplay* display = [self getCaptureDisplay];
    if (display == nil) {
        NSLog(@"[AudioCaptureImpl::start] no display to attach audio capture");
        return NO;
    }

    // 오디오 캡처에도 SCContentFilter 가 필요하므로 디스플레이를 지정하되, 영상은 최소 크기로 캡처
    SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];

    SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
    config.capturesAudio = YES;
    config.excludesCurrentProcessAudio = YES;
    config.sampleRate = CAPTURE_SAMPLE_RATE;
    config.channelCount = CAPTURE_CHANNELS;
    config.width = 2;
    config.height = 2;
    config.minimumFrameInterval = CMTimeMake(1, 1);
    config.showsCursor = NO;

    SCStream* stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

    NSError* err = nil;
    if ([stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:_audioQue error:&err] == NO) {
        NSLog(@"[AudioCaptureImpl::start] addStreamOutput(audio) failed. %@", err);
        return NO;
    }

    // 화면 output 이 없으면 프레임마다 경고 로그가 발생하므로 등록만 하고 무시
    if ([stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_audioQue error:&err] == NO) {
        NSLog(@"[AudioCaptureImpl::start] addStreamOutput(screen) failed. %@", err);
    }

    // stop 과 경합하지 않도록 lock 안에서 시작 (startCapture 는 비동기이므로 lock 을 오래 잡지 않음)
    @synchronized (self) {
        if (_stopped || _tapId != kAudioObjectUnknown) {
            return NO;
        }
        _stream = stream;

        [stream startCaptureWithCompletionHandler:^(NSError* _Nullable error) {
            if (error != nil) {
                NSLog(@"[AudioCaptureImpl::start] startCapture failed. %@", error);
            }
        }];
    }

    NSLog(@"[AudioCaptureImpl::start] audio capture started with ScreenCaptureKit (%d Hz, %u ch)", (int)_outputFormat.sampleRate, (unsigned)_outputFormat.channelCount);

    return YES;
}

- (void)stopScreenCaptureStream:(SCStream*)stream {
    if (stream == nil) {
        return;
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [stream stopCaptureWithCompletionHandler:^(NSError* _Nullable err) {
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, STOP_TIMEOUT_NS));

    [stream removeStreamOutput:self type:SCStreamOutputTypeAudio error:nil];
    [stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
}

// 세션 중 권한이 허용된 경우 ScreenCaptureKit 캡처를 tap 으로 교체
- (void)switchToTap API_AVAILABLE(macos(14.2)) {
    SCStream* stream = nil;

    @synchronized (self) {
        if (_stopped || _tapId != kAudioObjectUnknown) {
            return;
        }
        stream = _stream;
        _stream = nil;
    }

    [self stopScreenCaptureStream:stream];

    if ([self startTap] == NO) {
        [self startScreenCaptureAudio];
    }
}

- (BOOL)startTap API_AVAILABLE(macos(14.2)) {
    @synchronized (self) {
        if (_stopped || _tapId != kAudioObjectUnknown) {
            return NO;
        }

        if ([self createTapLocked] == NO) {
            [self destroyTapLocked];
            return NO;
        }

        [self addDefaultOutputListenerLocked];
    }

    NSLog(@"[AudioCaptureImpl::start] audio capture started with process tap (%d Hz, %u ch). local playback is muted",
          (int)_outputFormat.sampleRate, (unsigned)_outputFormat.channelCount);

    return YES;
}

- (BOOL)createTapLocked API_AVAILABLE(macos(14.2)) {
    // agent 자신의 소리 (가상 마이크 재생 등) 는 캡처/음소거 대상에서 제외
    NSArray<NSNumber*>* excludes = @[];
    AudioObjectID selfObject = [self processObjectForPid:getpid()];
    if (selfObject != kAudioObjectUnknown) {
        excludes = @[@(selfObject)];
    }

    CATapDescription* desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excludes];
    desc.name = @"OSXRDP audio redirection";
    desc.privateTap = YES;
    // tap 을 읽는 동안에만 음소거 (agent 가 비정상 종료되어도 로컬 소리가 계속 꺼져 있지 않음)
    desc.muteBehavior = CATapMutedWhenTapped;

    OSStatus status = AudioHardwareCreateProcessTap(desc, &_tapId);
    if (status != noErr) {
        NSLog(@"[AudioCaptureImpl::createTap] AudioHardwareCreateProcessTap failed %d", (int)status);
        _tapId = kAudioObjectUnknown;
        return NO;
    }

    AudioStreamBasicDescription asbd;
    UInt32 size = sizeof(asbd);
    AudioObjectPropertyAddress formatAddr = { kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    status = AudioObjectGetPropertyData(_tapId, &formatAddr, 0, NULL, &size, &asbd);
    if (status != noErr) {
        NSLog(@"[AudioCaptureImpl::createTap] could not get tap format %d", (int)status);
        return NO;
    }

    _tapFormat = [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
    UInt32 tapBufferCount = _tapFormat.isInterleaved ? 1 : _tapFormat.channelCount;
    if (_tapFormat == nil || tapBufferCount == 0 || tapBufferCount > 2) {
        NSLog(@"[AudioCaptureImpl::createTap] unsupported tap format");
        return NO;
    }

    // tap 을 읽기 위한 private aggregate device (clock 은 현재 출력 장치 기준)
    NSMutableDictionary* aggregateDesc = [@{
        @kAudioAggregateDeviceNameKey: @"OSXRDP Audio Redirection",
        @kAudioAggregateDeviceUIDKey: [[NSUUID UUID] UUIDString],
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceTapListKey: @[@{
            @kAudioSubTapUIDKey: desc.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: @YES,
        }],
    } mutableCopy];

    NSString* outputUID = [self defaultOutputDeviceUID];
    if (outputUID != nil) {
        aggregateDesc[@kAudioAggregateDeviceMainSubDeviceKey] = outputUID;
        aggregateDesc[@kAudioAggregateDeviceSubDeviceListKey] = @[@{ @kAudioSubDeviceUIDKey: outputUID }];
    }

    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregateDesc, &_aggregateId);
    if (status != noErr) {
        NSLog(@"[AudioCaptureImpl::createTap] AudioHardwareCreateAggregateDevice failed %d", (int)status);
        _aggregateId = kAudioObjectUnknown;
        return NO;
    }

    AVAudioFormat* tapFormat = _tapFormat;
    __weak AudioCaptureImpl* weakSelf = self;
    status = AudioDeviceCreateIOProcIDWithBlock(&_ioProcId, _aggregateId, _audioQue,
        ^(const AudioTimeStamp* inNow, const AudioBufferList* inInputData, const AudioTimeStamp* inInputTime,
          AudioBufferList* outOutputData, const AudioTimeStamp* inOutputTime) {
        AudioCaptureImpl* strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_stopped || inInputData == NULL || inInputData->mNumberBuffers < tapBufferCount) {
            return;
        }

        // aggregate 의 입력 buffer 는 sub device 입력 뒤에 tap 이 위치
        struct {
            UInt32 mNumberBuffers;
            AudioBuffer mBuffers[2];
        } tapBuffers;
        tapBuffers.mNumberBuffers = tapBufferCount;
        for (UInt32 i = 0; i < tapBufferCount; i++) {
            tapBuffers.mBuffers[i] = inInputData->mBuffers[inInputData->mNumberBuffers - tapBufferCount + i];
        }

        AVAudioPCMBuffer* input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:tapFormat
                                                             bufferListNoCopy:(const AudioBufferList*)&tapBuffers
                                                                  deallocator:nil];
        if (input == nil || input.frameLength == 0 || [strongSelf prepareConverterForFormat:tapFormat] == NO) {
            return;
        }

        [strongSelf processInput:input];
    });
    if (status != noErr) {
        NSLog(@"[AudioCaptureImpl::createTap] AudioDeviceCreateIOProcIDWithBlock failed %d", (int)status);
        _ioProcId = NULL;
        return NO;
    }

    status = AudioDeviceStart(_aggregateId, _ioProcId);
    if (status != noErr) {
        NSLog(@"[AudioCaptureImpl::createTap] AudioDeviceStart failed %d", (int)status);
        return NO;
    }

    return YES;
}

- (void)destroyTapLocked API_AVAILABLE(macos(14.2)) {
    if (_aggregateId != kAudioObjectUnknown) {
        if (_ioProcId != NULL) {
            AudioDeviceStop(_aggregateId, _ioProcId);
            AudioDeviceDestroyIOProcID(_aggregateId, _ioProcId);
            _ioProcId = NULL;
        }

        AudioHardwareDestroyAggregateDevice(_aggregateId);
        _aggregateId = kAudioObjectUnknown;
    }

    if (_tapId != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(_tapId);
        _tapId = kAudioObjectUnknown;
    }

    _tapFormat = nil;
}

// 출력 장치가 바뀌면 (이어폰 연결/해제 등) aggregate device 의 clock 장치가 사라질 수 있으므로 tap 을 다시 생성
- (void)addDefaultOutputListenerLocked API_AVAILABLE(macos(14.2)) {
    if (_defaultOutputListening) {
        return;
    }

    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &addr, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), [self defaultOutputListener]) == noErr) {
        _defaultOutputListening = YES;
    }
}

- (void)removeDefaultOutputListener API_AVAILABLE(macos(14.2)) {
    @synchronized (self) {
        if (_defaultOutputListening == NO) {
            return;
        }
        _defaultOutputListening = NO;
    }

    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &addr, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), [self defaultOutputListener]);
}

- (AudioObjectPropertyListenerBlock)defaultOutputListener API_AVAILABLE(macos(14.2)) {
    // add/remove 에 같은 block 을 전달해야 하므로 한번만 생성
    if (_defaultOutputListenerBlock == nil) {
        __weak AudioCaptureImpl* weakSelf = self;
        _defaultOutputListenerBlock = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses) {
            [weakSelf recreateTap];
        };
    }

    return _defaultOutputListenerBlock;
}

- (void)recreateTap API_AVAILABLE(macos(14.2)) {
    bool fallback = false;

    @synchronized (self) {
        if (_stopped || _tapId == kAudioObjectUnknown) {
            return;
        }

        [self destroyTapLocked];
        if ([self createTapLocked] == NO) {
            [self destroyTapLocked];
            fallback = true;
        }
    }

    if (fallback) {
        NSLog(@"[AudioCaptureImpl::recreateTap] could not recreate process tap. fall back to ScreenCaptureKit");
        [self startScreenCaptureAudio];
    }
}

- (AudioObjectID)processObjectForPid:(pid_t)pid {
    AudioObjectID object = kAudioObjectUnknown;
    UInt32 size = sizeof(object);
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof(pid), &pid, &size, &object) != noErr) {
        return kAudioObjectUnknown;
    }

    return object;
}

- (NSString*)defaultOutputDeviceUID {
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &device) != noErr || device == kAudioObjectUnknown) {
        return nil;
    }

    CFStringRef uid = NULL;
    size = sizeof(uid);
    addr.mSelector = kAudioDevicePropertyDeviceUID;
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &uid) != noErr || uid == NULL) {
        return nil;
    }

    return (__bridge_transfer NSString*)uid;
}

- (void)stop {
    SCStream* stream = nil;

    @synchronized (self) {
        _stopped = YES;
        stream = _stream;
        _stream = nil;

        if (@available(macOS 14.2, *)) {
            [self destroyTapLocked];
        }
    }

    // listener 제거는 lock 밖에서 수행 (진행 중인 listener 콜백이 lock 을 기다리는 경우 교착 방지)
    if (@available(macOS 14.2, *)) {
        [self removeDefaultOutputListener];
    }

    [self stopScreenCaptureStream:stream];

    // 처리중인 콜백이 끝날때까지 대기 (이후 상위 객체의 ipc 를 사용하지 않도록)
    dispatch_sync(_audioQue, ^{});
}

- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeAudio || _stopped) {
        return;
    }

    if (CMSampleBufferIsValid(sampleBuffer) == false || CMSampleBufferDataIsReady(sampleBuffer) == false) {
        return;
    }

    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
    if (asbd == NULL) {
        return;
    }

    AVAudioFrameCount frameCount = (AVAudioFrameCount)CMSampleBufferGetNumSamples(sampleBuffer);
    if (frameCount == 0) {
        return;
    }

    // 입력 포맷이 바뀐 경우 변환기 재생성
    if (_converter == nil || _converterInputFormat.sampleRate != asbd->mSampleRate ||
        _converterInputFormat.channelCount != asbd->mChannelsPerFrame ||
        _converterInputFormat.streamDescription->mFormatFlags != asbd->mFormatFlags) {
        if ([self prepareConverterForFormat:[[AVAudioFormat alloc] initWithStreamDescription:asbd]] == NO) {
            return;
        }
    }

    AVAudioPCMBuffer* inputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_converterInputFormat frameCapacity:frameCount];
    if (inputBuffer == nil) {
        return;
    }
    inputBuffer.frameLength = frameCount;

    if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, 0, (int32_t)frameCount, inputBuffer.mutableAudioBufferList) != noErr) {
        return;
    }

    [self processInput:inputBuffer];
}

- (BOOL)prepareConverterForFormat:(AVAudioFormat*)format {
    if (_converter != nil && [_converterInputFormat isEqual:format]) {
        return YES;
    }

    _converterInputFormat = format;
    _converter = format != nil ? [[AVAudioConverter alloc] initFromFormat:format toFormat:_outputFormat] : nil;
    if (_converter == nil) {
        NSLog(@"[AudioCaptureImpl] could not create converter");
        return NO;
    }

    return YES;
}

// 캡처한 오디오를 클라이언트 포맷으로 변환하여 전달 (_audioQue 에서 호출)
- (void)processInput:(AVAudioPCMBuffer*)inputBuffer {
    AVAudioFrameCount frameCount = inputBuffer.frameLength;
    AVAudioFrameCount outputCapacity = (AVAudioFrameCount)((double)frameCount * _outputFormat.sampleRate / _converterInputFormat.sampleRate) + 64;
    AVAudioPCMBuffer* outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_outputFormat frameCapacity:outputCapacity];
    if (outputBuffer == nil) {
        return;
    }

    // 스트리밍 변환: 입력을 한번만 공급하고 NoDataNow 로 변환기 내부 상태(리샘플러)를 유지
    __block BOOL supplied = NO;
    NSError* err = nil;
    AVAudioConverterOutputStatus status = [_converter convertToBuffer:outputBuffer error:&err withInputFromBlock:^AVAudioBuffer* _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus* outStatus) {
        if (supplied) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }

        supplied = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return inputBuffer;
    }];

    if (status == AVAudioConverterOutputStatus_Error || outputBuffer.frameLength == 0) {
        return;
    }

    const int16_t* samples = outputBuffer.int16ChannelData[0];
    int sampleCount = (int)(outputBuffer.frameLength * _outputFormat.channelCount);

    // 무음 여부 확인
    bool silent = true;
    for (int i = 0; i < sampleCount; i++) {
        if (samples[i] != 0) {
            silent = false;
            break;
        }
    }

    // 무음 구간은 hangover 이후 전송하지 않음 (불필요한 대역폭 사용 방지)
    if (silent) {
        _silentFrames += (int)outputBuffer.frameLength;
        if (_silentFrames > (int)_outputFormat.sampleRate * SILENCE_HANGOVER_MS / 1000) {
            return;
        }
    }
    else {
        _silentFrames = 0;
    }

    if (_aacEncoder != nil) {
        [self encodeAAC:samples frames:outputBuffer.frameLength];
    }
    else {
        _dataCb(samples, sampleCount * (int)sizeof(int16_t), _dataCbUserData);
    }
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    NSLog(@"[AudioCaptureImpl] stream stopped. %@", error);

    @synchronized (self) {
        if (_stopped || stream != _stream) {
            return;
        }
        _stream = nil;

        if (_restartCount >= MAX_RESTART_COUNT) {
            return;
        }
        _restartCount++;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RESTART_DELAY_NS), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (self->_stopped == NO) {
            [self startScreenCaptureAudio];
        }
    });
}

// 현재 메인 디스플레이 (가상 모니터 사용 시 가상 모니터) 조회
- (SCDisplay*)getCaptureDisplay {
    __block SCDisplay* found = nil;
    CGDirectDisplayID mainDisplayId = CGMainDisplayID();

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent* _Nullable content, NSError* _Nullable error) {
        for (SCDisplay* item in content.displays) {
            if (found == nil || item.displayID == mainDisplayId) {
                found = item;
            }
        }
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    return found;
}

@end


AudioCaptureManager::AudioCaptureManager() :
    _impl(NULL),
    _client(NULL),
    _frameBytes(0)
{}

AudioCaptureManager::~AudioCaptureManager() {
    Stop();
}

void AudioCaptureManager::HandleCommand(xipc_t* client, xstream_t* cmd) {
    int packetType = xstream_readInt32(cmd);

    switch (packetType) {
        case OSXRDP_PACKETTYPE_REQ_AUDIOSTART: {
            int sampleRate = xstream_readInt32(cmd);
            int channels = xstream_readInt32(cmd);
            int bitsPerSample = xstream_readInt32(cmd);
            int codec = xstream_readInt32(cmd); // 이전 osxup 은 보내지 않음 (0 = PCM)

            Start(client, sampleRate, channels, bitsPerSample, codec);
            break;
        }
        default:
            break;
    }
}

void AudioCaptureManager::Start(xipc_t* client, int sampleRate, int channels, int bitsPerSample, int codec) {
    // 잠금 화면 agent (root) 에서는 오디오를 캡처하지 않음
    if (is_root_process() != 0) {
        return;
    }

    if (client == NULL || bitsPerSample != 16 || (channels != 1 && channels != 2) || sampleRate < 8000 || sampleRate > 192000) {
        NSLog(@"[AudioCaptureManager::Start] unsupported format %d Hz, %d ch, %d bit", sampleRate, channels, bitsPerSample);
        return;
    }

    if (@available(macOS 13.0, *)) {
        Stop();

        _client = client;
        _frameBytes = channels * bitsPerSample / 8;

        AudioCaptureImpl* impl = [[AudioCaptureImpl alloc] initWithSampleRate:sampleRate
                                                                     Channels:channels
                                                                        Codec:codec
                                                                 DataCallback:OnAudioData
                                                         DataCallbackUserData:this];
        if (impl == nil) {
            return;
        }

        _impl = (__bridge_retained void*)impl;

        if ([impl start] == NO) {
            Stop();
        }
    }
    else {
        NSLog(@"[AudioCaptureManager::Start] audio capture requires macOS 13 or later");
    }
}

void AudioCaptureManager::Stop() {
    if (_impl == NULL) {
        return;
    }

    if (@available(macOS 13.0, *)) {
        AudioCaptureImpl* impl = (__bridge_transfer AudioCaptureImpl*)_impl;
        _impl = NULL;

        [impl stop];
    }

    _client = NULL;
}

void AudioCaptureManager::OnAudioData(const void* pcm, int pcmLen, void* userData) {
    AudioCaptureManager* _this = (AudioCaptureManager*)userData;
    if (_this == NULL || _this->_client == NULL || _this->_frameBytes <= 0) {
        return;
    }

    struct {
        int cmdType;
        int packetType;
        int dataLen;
        char data[OSXRDP_AUDIO_MAX_CHUNK];
    } __attribute__((packed)) msg;

    // frame 경계에 맞춰 분할
    const int maxChunk = OSXRDP_AUDIO_MAX_CHUNK - (OSXRDP_AUDIO_MAX_CHUNK % _this->_frameBytes);
    const char* src = (const char*)pcm;
    int offset = 0;

    while (offset < pcmLen) {
        int chunkLen = pcmLen - offset;
        if (chunkLen > maxChunk) {
            chunkLen = maxChunk;
        }

        msg.cmdType = OSXRDP_CMDTYPE_AUDIO;
        msg.packetType = OSXRDP_PACKETTYPE_AUDIODATA;
        msg.dataLen = chunkLen;
        memcpy(msg.data, src + offset, chunkLen);

        xipc_send_data(_this->_client, (void*)&msg, (int)(sizeof(int) * 3) + chunkLen);

        offset += chunkLen;
    }
}
