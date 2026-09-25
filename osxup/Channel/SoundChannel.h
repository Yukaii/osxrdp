
#ifndef SoundChannel_h
#define SoundChannel_h

#include <stdint.h>

#include "osxrdp/packet.h"

struct mod;

// rdpsnd 정적 가상 채널 (MS-RDPEA, 서버 -> 클라이언트 오디오 출력)
//
// 협상 순서
//   server  SNDC_FORMATS  ->  client SNDC_FORMATS (+ SNDC_QUALITYMODE)
//   server  SNDC_TRAINING ->  client SNDC_TRAINING
//   server  SNDC_WAVE2 (또는 SNDC_WAVE + wave) ...  ->  client SNDC_WAVECONFIRM
class SoundChannel {
public:
    SoundChannel();
    ~SoundChannel();

    bool Initialize(const struct mod* mod);
    void Release();

    bool IsSoundChannel(int channelId) const;

    // Server Audio Formats and Version PDU 전송 (연결당 1회)
    void SendServerFormats();

    // 클라이언트로부터 수신한 채널 데이터 처리 (chunk 재조립 포함)
    void HandleChannelData(int channelFlags, const char* data, int dataLen, int totalLen);

    // 오디오 데이터를 전송할 수 있는 상태인지 (training 완료)
    bool IsReady() const;

    // 협상된 PCM 포맷 조회
    int GetSampleRate() const;
    int GetChannels() const;
    int GetBitsPerSample() const;

    // 협상된 포맷의 interleaved PCM 데이터 전송
    void SendAudio(const void* pcm, int pcmLen);

private:
    enum class State {
        IDLE,               // 채널 없음 또는 초기화 전
        WAIT_CLIENT_FORMATS,
        WAIT_TRAINING,
        READY,
        UNSUPPORTED,        // 클라이언트가 호환 포맷을 지원하지 않음
    };

    const struct mod* _mod;
    int _channelId;
    State _state;
    bool _formatsSent;

    // 클라이언트 PDU chunk 재조립 버퍼
    char* _incoming;
    int _incomingLen;
    int _incomingTotalLen;

    // 전송 PDU 작성 버퍼 (Wave2 header 16byte + PCM)
    uint8_t _outBuf[16 + OSXRDP_AUDIO_MAX_CHUNK];

    int _clientVersion;
    int _clientFormatNo;    // 클라이언트 포맷 목록 내 index (wFormatNo)
    int _sampleRate;
    int _channels;
    int _bitsPerSample;
    int _bytesPerSec;

    uint8_t _blockNo;               // 다음에 보낼 cBlockNo
    uint8_t _lastConfirmedBlockNo;
    int _blockBytes[256];           // block 별 전송량 (미확인 데이터량 계산용)
    int64_t _unconfirmedBytes;
    uint64_t _lastConfirmTimeMs;
    uint64_t _audioStartTimeMs;

    void _ProcessPdu(const uint8_t* pdu, int pduLen);
    void _ProcessClientFormats(const uint8_t* body, int bodyLen);
    void _ProcessTrainingConfirm(const uint8_t* body, int bodyLen);
    void _ProcessWaveConfirm(const uint8_t* body, int bodyLen);

    void _SendTraining();
    bool _ShouldDropBlock();
    void _TrackSentBlock(int pcmLen);

    // 가상 채널 chunk 크기(1600)에 맞춰 분할 전송
    void _SendPdu(const uint8_t* pdu, int pduLen);

    static uint64_t _NowMs();
};

#endif /* SoundChannel_h */
