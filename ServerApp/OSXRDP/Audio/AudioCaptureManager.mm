#include "AudioCaptureManager.h"
#include "osxrdp/packet.h"
#include "utils.h"

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreMedia/CoreMedia.h>

typedef void (*on_audio_data)(const void* pcm, int pcmLen, void* userData);

// ScreenCaptureKit 에서 지원하는 캡처 포맷 (이후 AVAudioConverter 로 클라이언트 포맷 변환)
static const int CAPTURE_SAMPLE_RATE = 48000;
static const int CAPTURE_CHANNELS = 2;

// 디스플레이 구성 변경 (가상 모니터 등) 으로 스트림이 중단된 경우 재시작 시도
static const int MAX_RESTART_COUNT = 5;
static const int64_t RESTART_DELAY_NS = 1 * NSEC_PER_SEC;
static const int64_t STOP_TIMEOUT_NS = 3 * NSEC_PER_SEC;

API_AVAILABLE(macos(13.0))
@interface AudioCaptureImpl : NSObject<SCStreamOutput, SCStreamDelegate>

- (instancetype)initWithSampleRate:(int)sampleRate
                          Channels:(int)channels
                      DataCallback:(on_audio_data)cb
              DataCallbackUserData:(void*)userData;
- (BOOL)start;
- (void)stop;

@end

@implementation AudioCaptureImpl {
    SCStream* _stream;
    dispatch_queue_t _audioQue;

    AVAudioFormat* _outputFormat;
    AVAudioConverter* _converter;
    AVAudioFormat* _converterInputFormat;

    on_audio_data _dataCb;
    void* _dataCbUserData;

    BOOL _stopped;
    int _restartCount;
}

- (instancetype)initWithSampleRate:(int)sampleRate
                          Channels:(int)channels
                      DataCallback:(on_audio_data)cb
              DataCallbackUserData:(void*)userData {
    self = [super init];
    if (self != nil) {
        _outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                         sampleRate:sampleRate
                                                           channels:channels
                                                        interleaved:YES];
        _dataCb = cb;
        _dataCbUserData = userData;
        _stopped = NO;
        _restartCount = 0;

        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _audioQue = dispatch_queue_create("osxrdp.audio", attr);
    }

    return self;
}

- (BOOL)start {
    if (_outputFormat == nil) {
        NSLog(@"[AudioCaptureImpl::start] invalid output format");
        return NO;
    }

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
        if (_stopped) {
            return NO;
        }
        _stream = stream;

        [stream startCaptureWithCompletionHandler:^(NSError* _Nullable error) {
            if (error != nil) {
                NSLog(@"[AudioCaptureImpl::start] startCapture failed. %@", error);
            }
        }];
    }

    NSLog(@"[AudioCaptureImpl::start] audio capture started (%d Hz, %u ch)", (int)_outputFormat.sampleRate, (unsigned)_outputFormat.channelCount);

    return YES;
}

- (void)stop {
    SCStream* stream = nil;

    @synchronized (self) {
        _stopped = YES;
        stream = _stream;
        _stream = nil;
    }

    if (stream != nil) {
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        [stream stopCaptureWithCompletionHandler:^(NSError* _Nullable err) {
            dispatch_semaphore_signal(sema);
        }];
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, STOP_TIMEOUT_NS));

        [stream removeStreamOutput:self type:SCStreamOutputTypeAudio error:nil];
        [stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
    }

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
        _converterInputFormat = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
        _converter = [[AVAudioConverter alloc] initFromFormat:_converterInputFormat toFormat:_outputFormat];
        if (_converter == nil) {
            NSLog(@"[AudioCaptureImpl] could not create converter");
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

    // 무음 구간은 전송하지 않음 (불필요한 대역폭 사용 방지)
    bool silent = true;
    for (int i = 0; i < sampleCount; i++) {
        if (samples[i] != 0) {
            silent = false;
            break;
        }
    }

    if (silent) {
        return;
    }

    _dataCb(samples, sampleCount * (int)sizeof(int16_t), _dataCbUserData);
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
            [self start];
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

            Start(client, sampleRate, channels, bitsPerSample);
            break;
        }
        default:
            break;
    }
}

void AudioCaptureManager::Start(xipc_t* client, int sampleRate, int channels, int bitsPerSample) {
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
