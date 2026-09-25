
#ifndef AudioInputChannel_h
#define AudioInputChannel_h

#include <stdint.h>

struct mod;

// AUDIO_INPUT 동적 가상 채널 (MS-RDPEAI, 클라이언트 마이크 -> 서버)
//
// 협상 순서
//   server  (DVC open)            -> client (open response)
//   server  MSG_SNDIN_VERSION     -> client MSG_SNDIN_VERSION
//   server  MSG_SNDIN_FORMATS     -> client MSG_SNDIN_FORMATS
//   server  MSG_SNDIN_OPEN        -> client MSG_SNDIN_FORMATCHANGE, MSG_SNDIN_OPEN_REPLY
//   client  MSG_SNDIN_DATA_INCOMING, MSG_SNDIN_DATA ...
//
// 클라이언트는 채널이 열려있는 동안 마이크를 사용하므로 mac 에서 녹음하는 앱이 있을 때만 연다.
class AudioInputChannel {
public:
    // 수신한 PCM 을 전달받는 콜백
    typedef void (*FormatCallback)(void* userData, int sampleRate, int channels, int bitsPerSample);
    typedef void (*DataCallback)(void* userData, const void* pcm, int pcmLen);

    AudioInputChannel();
    ~AudioInputChannel();

    void Initialize(const struct mod* mod, FormatCallback formatCb, DataCallback dataCb, void* userData);
    void Release();

    // 마이크 사용 요청 / 해제 (mac 에서 녹음 시작 / 종료)
    void Start();
    void Stop();

    // 채널 열기 재시도 (클라이언트의 동적 채널 준비 전일 수 있음). 주기적으로 호출
    void CheckPendingOpen();

    bool IsOwnChannel(int channelId) const;

    // xrdp 동적 채널 이벤트
    void HandleOpenResponse(int channelId, int creationStatus);
    void HandleCloseResponse(int channelId);
    void HandleData(int channelId, const char* data, int dataLen);

private:
    enum class State {
        CLOSED,
        OPENING,            // DVC 생성 요청 후 응답 대기
        WAIT_VERSION,
        WAIT_FORMATS,
        WAIT_OPEN_REPLY,
        STREAMING,
        CLOSING,            // DVC 닫기 요청 후 응답 대기
        UNSUPPORTED,        // 클라이언트가 마이크 리디렉션을 지원/허용하지 않음
    };

    const struct mod* _mod;
    FormatCallback _formatCb;
    DataCallback _dataCb;
    void* _userData;

    State _state;
    bool _wanted;           // mac 에서 마이크를 사용 중인지
    int _channelId;

    // 클라이언트가 지원하는 포맷 목록 (MSG_SNDIN_FORMATCHANGE 는 이 목록의 index 를 사용)
    struct ClientFormat {
        int formatTag;
        int channels;
        int sampleRate;
        int bitsPerSample;
    };
    static const int MAX_CLIENT_FORMATS = 32;
    ClientFormat _clientFormats[MAX_CLIENT_FORMATS];
    int _numClientFormats;

    // 현재 포맷 (클라이언트 목록 기준 index)
    int _formatNo;

    void _Open();
    void _Close();

    void _SendVersion();
    void _SendFormats();
    void _SendOpen();

    void _ProcessFormats(const uint8_t* body, int bodyLen);
    void _ProcessOpenReply(const uint8_t* body, int bodyLen);
    void _ProcessFormatChange(const uint8_t* body, int bodyLen);

    // 현재 포맷을 상위에 알림 (PCM 16bit 가 아니면 false)
    bool _NotifyFormat();
};

#endif /* AudioInputChannel_h */
