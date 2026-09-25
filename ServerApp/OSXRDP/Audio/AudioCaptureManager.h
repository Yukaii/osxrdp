#ifndef AudioCaptureManager_h
#define AudioCaptureManager_h

#include "ipc.h"
#include "xstream.h"

// 시스템 오디오를 캡처하여 osxup 로 PCM 데이터를 전달 (rdpsnd 협상은 osxup 에서 수행)
class AudioCaptureManager {
public:
    AudioCaptureManager();
    ~AudioCaptureManager();

    void HandleCommand(xipc_t* client, xstream_t* cmd);

    // 캡처 정지 (반환 이후에는 osxup 로 데이터를 보내지 않음)
    void Stop();

private:
    void* _impl; // AudioCaptureImpl (macOS 13+)
    xipc_t* _client;
    int _frameBytes;

    void Start(xipc_t* client, int sampleRate, int channels, int bitsPerSample, int codec);

    // 캡처된 PCM 을 ipc 버퍼 크기에 맞춰 분할 전송 (AAC frame 은 버퍼보다 훨씬 작아 분할되지 않음)
    static void OnAudioData(const void* pcm, int pcmLen, void* userData);
};

#endif /* AudioCaptureManager_h */
