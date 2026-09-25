#include "../pch.h"
#include "AudioInputChannel.h"
#include "../osxup.h"

#include <stdio.h>

// MS-RDPEAI 2.2.1 MessageId
static const uint8_t MSG_SNDIN_VERSION = 0x01;
static const uint8_t MSG_SNDIN_FORMATS = 0x02;
static const uint8_t MSG_SNDIN_OPEN = 0x03;
static const uint8_t MSG_SNDIN_OPEN_REPLY = 0x04;
static const uint8_t MSG_SNDIN_DATA_INCOMING = 0x05;
static const uint8_t MSG_SNDIN_DATA = 0x06;
static const uint8_t MSG_SNDIN_FORMATCHANGE = 0x07;

static const char* AUDIN_CHANNEL_NAME = "AUDIO_INPUT";
static const uint32_t AUDIN_VERSION = 0x00000001;

static const int AUDIO_FORMAT_SIZE = 18;

// 패킷 당 frame 수 (44.1kHz 기준 약 23ms)
static const uint32_t FRAMES_PER_PACKET = 1024;

// server_drdynvc_open 반환값: 클라이언트의 동적 채널이 아직 준비되지 않음
static const int DRDYNVC_NOT_READY = 2;

struct PcmFormat {
    int sampleRate;
    int channels;
};

// 서버가 받을 수 있는 포맷 (agent 에서 가상 마이크 포맷으로 변환)
static const PcmFormat kServerFormats[] = {
    { 44100, 2 },
    { 48000, 2 },
    { 44100, 1 },
    { 48000, 1 },
    { 22050, 2 },
};

static const int kNumServerFormats = (int)(sizeof(kServerFormats) / sizeof(kServerFormats[0]));

namespace {

inline uint16_t GetUInt16(const uint8_t* p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

inline uint32_t GetUInt32(const uint8_t* p) {
    return (uint32_t)GetUInt16(p) | ((uint32_t)GetUInt16(p + 2) << 16);
}

inline void PutUInt16(uint8_t* p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)((v >> 8) & 0xff);
}

inline void PutUInt32(uint8_t* p, uint32_t v) {
    PutUInt16(p, (uint16_t)(v & 0xffff));
    PutUInt16(p + 2, (uint16_t)((v >> 16) & 0xffff));
}

// AUDIO_FORMAT (PCM 16bit)
inline void PutPcmFormat(uint8_t* p, int sampleRate, int channels) {
    int blockAlign = channels * 2;

    PutUInt16(p, WAVE_FORMAT_PCM);                      // wFormatTag
    PutUInt16(p + 2, (uint16_t)channels);               // nChannels
    PutUInt32(p + 4, (uint32_t)sampleRate);             // nSamplesPerSec
    PutUInt32(p + 8, (uint32_t)(sampleRate * blockAlign)); // nAvgBytesPerSec
    PutUInt16(p + 12, (uint16_t)blockAlign);            // nBlockAlign
    PutUInt16(p + 14, 16);                              // wBitsPerSample
    PutUInt16(p + 16, 0);                               // cbSize
}

}

AudioInputChannel::AudioInputChannel() :
    _mod(NULL),
    _formatCb(NULL),
    _dataCb(NULL),
    _userData(NULL),
    _state(State::CLOSED),
    _wanted(false),
    _channelId(-1),
    _numClientFormats(0),
    _formatNo(-1)
{
    memset(_clientFormats, 0, sizeof(_clientFormats));
}

AudioInputChannel::~AudioInputChannel()
{}

void AudioInputChannel::Initialize(const struct mod* mod, FormatCallback formatCb, DataCallback dataCb, void* userData) {
    _mod = mod;
    _formatCb = formatCb;
    _dataCb = dataCb;
    _userData = userData;
}

void AudioInputChannel::Release() {
    // xrdp 는 모듈 종료 시 모듈의 동적 채널을 닫는다
    _mod = NULL;
    _formatCb = NULL;
    _dataCb = NULL;
    _userData = NULL;
    _state = State::CLOSED;
    _wanted = false;
    _channelId = -1;
    _numClientFormats = 0;
    _formatNo = -1;
}

void AudioInputChannel::Start() {
    _wanted = true;

    if (_state == State::CLOSED) {
        _Open();
    }
}

void AudioInputChannel::Stop() {
    _wanted = false;

    // OPENING 중이면 open 응답을 받은 뒤 닫는다 (HandleOpenResponse)
    if (_state == State::WAIT_VERSION || _state == State::WAIT_FORMATS ||
        _state == State::WAIT_OPEN_REPLY || _state == State::STREAMING) {
        _Close();
    }
}

void AudioInputChannel::CheckPendingOpen() {
    if (_wanted && _state == State::CLOSED) {
        _Open();
    }
}

bool AudioInputChannel::IsOwnChannel(int channelId) const {
    return _channelId > 0 && channelId == _channelId;
}

void AudioInputChannel::HandleOpenResponse(int channelId, int creationStatus) {
    if (IsOwnChannel(channelId) == false || _state != State::OPENING) {
        return;
    }

    // CreationStatus 는 HRESULT (음수 = 실패). 마이크 리디렉션을 허용하지 않은 클라이언트
    if (creationStatus < 0) {
        printf("[AudioInputChannel] client refused AUDIO_INPUT (0x%08x)\n", (unsigned int)creationStatus);
        _channelId = -1;
        _state = State::UNSUPPORTED;
        return;
    }

    if (_wanted == false) {
        _Close();
        return;
    }

    _SendVersion();
}

void AudioInputChannel::HandleCloseResponse(int channelId) {
    if (IsOwnChannel(channelId) == false) {
        return;
    }

    bool wasUnsupported = (_state == State::UNSUPPORTED);

    _channelId = -1;
    _formatNo = -1;
    _state = wasUnsupported ? State::UNSUPPORTED : State::CLOSED;

    // 닫는 동안 다시 녹음이 시작된 경우
    if (_wanted && _state == State::CLOSED) {
        _Open();
    }
}

void AudioInputChannel::HandleData(int channelId, const char* data, int dataLen) {
    if (IsOwnChannel(channelId) == false || data == NULL || dataLen < 1) {
        return;
    }

    const uint8_t* msg = (const uint8_t*)data;
    const uint8_t* body = msg + 1;
    int bodyLen = dataLen - 1;

    switch (msg[0]) {
        case MSG_SNDIN_VERSION:
            if (_state == State::WAIT_VERSION && bodyLen >= 4) {
                _SendFormats();
            }
            break;
        case MSG_SNDIN_FORMATS:
            _ProcessFormats(body, bodyLen);
            break;
        case MSG_SNDIN_OPEN_REPLY:
            _ProcessOpenReply(body, bodyLen);
            break;
        case MSG_SNDIN_FORMATCHANGE:
            _ProcessFormatChange(body, bodyLen);
            break;
        case MSG_SNDIN_DATA_INCOMING:
            break;
        case MSG_SNDIN_DATA:
            if (_state == State::STREAMING && bodyLen > 0 && _dataCb != NULL) {
                _dataCb(_userData, body, bodyLen);
            }
            break;
        default:
            break;
    }
}

void AudioInputChannel::_Open() {
    if (_mod == NULL) {
        return;
    }

    // 이 기능이 없는 xrdp (osxrdp 패치 이전)
    if (_mod->server_drdynvc_open == NULL || _mod->server_drdynvc_send == NULL || _mod->server_drdynvc_close == NULL) {
        _state = State::UNSUPPORTED;
        return;
    }

    int channelId = -1;
    int rv = _mod->server_drdynvc_open((struct mod*)_mod, AUDIN_CHANNEL_NAME, 1, &channelId);
    if (rv == DRDYNVC_NOT_READY) {
        // CheckPendingOpen 에서 재시도
        return;
    }

    if (rv != 0) {
        _state = State::UNSUPPORTED;
        return;
    }

    _channelId = channelId;
    _state = State::OPENING;
}

void AudioInputChannel::_Close() {
    if (_mod == NULL || _channelId <= 0 || _mod->server_drdynvc_close == NULL) {
        _state = State::CLOSED;
        _channelId = -1;
        return;
    }

    if (_mod->server_drdynvc_close((struct mod*)_mod, _channelId) != 0) {
        _state = State::CLOSED;
        _channelId = -1;
        return;
    }

    _state = State::CLOSING;
}

void AudioInputChannel::_SendVersion() {
    uint8_t msg[5];
    msg[0] = MSG_SNDIN_VERSION;
    PutUInt32(msg + 1, AUDIN_VERSION);                  // Version

    _mod->server_drdynvc_send((struct mod*)_mod, _channelId, (const char*)msg, sizeof(msg));
    _state = State::WAIT_VERSION;
}

void AudioInputChannel::_SendFormats() {
    uint8_t msg[9 + kNumServerFormats * AUDIO_FORMAT_SIZE];
    msg[0] = MSG_SNDIN_FORMATS;
    PutUInt32(msg + 1, (uint32_t)kNumServerFormats);    // NumFormats
    PutUInt32(msg + 5, (uint32_t)sizeof(msg));          // cbSizeFormatsPacket

    for (int i = 0; i < kNumServerFormats; i++) {
        PutPcmFormat(msg + 9 + i * AUDIO_FORMAT_SIZE, kServerFormats[i].sampleRate, kServerFormats[i].channels);
    }

    _mod->server_drdynvc_send((struct mod*)_mod, _channelId, (const char*)msg, sizeof(msg));
    _state = State::WAIT_FORMATS;
}

void AudioInputChannel::_SendOpen() {
    const ClientFormat& f = _clientFormats[_formatNo];

    uint8_t msg[9 + AUDIO_FORMAT_SIZE];
    msg[0] = MSG_SNDIN_OPEN;
    PutUInt32(msg + 1, FRAMES_PER_PACKET);              // FramesPerPacket
    PutUInt32(msg + 5, (uint32_t)_formatNo);            // initialFormat
    PutPcmFormat(msg + 9, f.sampleRate, f.channels);

    _mod->server_drdynvc_send((struct mod*)_mod, _channelId, (const char*)msg, sizeof(msg));
    _state = State::WAIT_OPEN_REPLY;
}

void AudioInputChannel::_ProcessFormats(const uint8_t* body, int bodyLen) {
    if (_state != State::WAIT_FORMATS || bodyLen < 8) {
        return;
    }

    int numFormats = (int)GetUInt32(body);
    int offset = 8;

    _numClientFormats = 0;
    _formatNo = -1;

    for (int i = 0; i < numFormats && i < MAX_CLIENT_FORMATS; i++) {
        if (offset + AUDIO_FORMAT_SIZE > bodyLen) {
            break;
        }

        const uint8_t* fmt = body + offset;
        ClientFormat& f = _clientFormats[_numClientFormats++];
        f.formatTag = GetUInt16(fmt);
        f.channels = GetUInt16(fmt + 2);
        f.sampleRate = (int)GetUInt32(fmt + 4);
        f.bitsPerSample = GetUInt16(fmt + 14);

        offset += AUDIO_FORMAT_SIZE + GetUInt16(fmt + 16);

        // 클라이언트 목록은 서버 목록의 선호 순서를 따르므로 처음 사용 가능한 PCM 포맷을 사용
        if (_formatNo < 0 && f.formatTag == WAVE_FORMAT_PCM && f.bitsPerSample == 16 &&
            (f.channels == 1 || f.channels == 2) && f.sampleRate >= 8000 && f.sampleRate <= 192000) {
            _formatNo = i;
        }
    }

    if (_formatNo < 0) {
        printf("[AudioInputChannel] no compatible client microphone format\n");
        _Close();
        _state = State::UNSUPPORTED;
        return;
    }

    _SendOpen();
}

void AudioInputChannel::_ProcessOpenReply(const uint8_t* body, int bodyLen) {
    if (_state != State::WAIT_OPEN_REPLY || bodyLen < 4) {
        return;
    }

    uint32_t result = GetUInt32(body);
    if ((int32_t)result < 0) {
        printf("[AudioInputChannel] client could not open microphone (0x%08x)\n", result);
        _Close();
        _state = State::UNSUPPORTED;
        return;
    }

    if (_NotifyFormat() == false) {
        _Close();
        _state = State::UNSUPPORTED;
        return;
    }

    _state = State::STREAMING;
}

void AudioInputChannel::_ProcessFormatChange(const uint8_t* body, int bodyLen) {
    if (bodyLen < 4) {
        return;
    }

    int formatNo = (int)GetUInt32(body);
    if (formatNo < 0 || formatNo >= _numClientFormats) {
        return;
    }

    _formatNo = formatNo;

    // Open Reply 이전의 FormatChange 는 초기 포맷 확인 용도 (Open Reply 에서 알림)
    if (_state == State::STREAMING && _NotifyFormat() == false) {
        _Close();
        _state = State::UNSUPPORTED;
    }
}

bool AudioInputChannel::_NotifyFormat() {
    if (_formatNo < 0 || _formatNo >= _numClientFormats) {
        return false;
    }

    const ClientFormat& f = _clientFormats[_formatNo];
    if (f.formatTag != WAVE_FORMAT_PCM || f.bitsPerSample != 16 || (f.channels != 1 && f.channels != 2)) {
        return false;
    }

    if (_formatCb != NULL) {
        _formatCb(_userData, f.sampleRate, f.channels, f.bitsPerSample);
    }

    return true;
}
