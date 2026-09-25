#include "../pch.h"
#include "SoundChannel.h"
#include "../osxup.h"

#include <stdio.h>
#include <time.h>

// MS-RDPEA 2.2.1 RDPSND PDU Header msgType
static const uint8_t SNDC_WAVE = 0x02;
static const uint8_t SNDC_WAVECONFIRM = 0x05;
static const uint8_t SNDC_TRAINING = 0x06;
static const uint8_t SNDC_FORMATS = 0x07;
static const uint8_t SNDC_QUALITYMODE = 0x0C;
static const uint8_t SNDC_WAVE2 = 0x0D;

static const uint32_t TSSNDCAPS_ALIVE = 0x00000001;

// Wave2 PDU 는 client/server 모두 version 8 이상일 때만 사용 가능
static const uint16_t RDPSND_SERVER_VERSION = 0x08;
static const uint16_t RDPSND_VERSION_WAVE2 = 0x08;

static const int RDPSND_HEADER_SIZE = 4;
static const int AUDIO_FORMAT_SIZE = 18;
static const int MAX_INCOMING_PDU_SIZE = 64 * 1024;

// 클라이언트가 재생을 확인하지 않은 데이터가 이 이상 쌓이면 지연 누적을 막기 위해 버림
static const int MAX_UNCONFIRMED_MS = 600;
// confirm 이 이 시간동안 오지 않으면 (confirm 을 보내지 않는 클라이언트) 흐름 제어를 초기화
static const uint64_t CONFIRM_TIMEOUT_MS = 3000;

struct PcmFormat {
    int sampleRate;
    int channels;
    int bitsPerSample;
};

// 서버가 제공하는 포맷 (agent 에서 해당 포맷으로 변환하여 전달)
static const PcmFormat kServerFormats[] = {
    { 48000, 2, 16 },
    { 44100, 2, 16 },
    { 22050, 2, 16 },
};

static const int kNumServerFormats = (int)(sizeof(kServerFormats) / sizeof(kServerFormats[0]));

namespace {

// 고정 크기 버퍼에 little-endian 으로 PDU 작성
struct PduWriter {
    uint8_t* buf;
    int cap;
    int len;

    PduWriter(uint8_t* b, int c) : buf(b), cap(c), len(0) {}

    void UInt8(uint8_t v) {
        if (len + 1 <= cap) buf[len] = v;
        len += 1;
    }

    void UInt16(uint16_t v) {
        UInt8((uint8_t)(v & 0xff));
        UInt8((uint8_t)((v >> 8) & 0xff));
    }

    void UInt32(uint32_t v) {
        UInt16((uint16_t)(v & 0xffff));
        UInt16((uint16_t)((v >> 16) & 0xffff));
    }

    void Data(const void* data, int dataLen) {
        if (len + dataLen <= cap) memcpy(buf + len, data, dataLen);
        len += dataLen;
    }

    // msgType, bPad, BodySize (EndPdu 에서 설정)
    void Header(uint8_t msgType) {
        UInt8(msgType);
        UInt8(0);
        UInt16(0);
    }

    void SetBodySize(uint16_t bodySize) {
        if (cap >= RDPSND_HEADER_SIZE) {
            buf[2] = (uint8_t)(bodySize & 0xff);
            buf[3] = (uint8_t)((bodySize >> 8) & 0xff);
        }
    }

    void EndPdu() {
        SetBodySize((uint16_t)(len - RDPSND_HEADER_SIZE));
    }

    bool Overflowed() const {
        return len > cap;
    }
};

inline uint16_t GetUInt16(const uint8_t* p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

inline uint32_t GetUInt32(const uint8_t* p) {
    return (uint32_t)GetUInt16(p) | ((uint32_t)GetUInt16(p + 2) << 16);
}

}

SoundChannel::SoundChannel() :
    _mod(NULL),
    _channelId(-1),
    _state(State::IDLE),
    _formatsSent(false),
    _incoming(NULL),
    _incomingLen(0),
    _incomingTotalLen(0),
    _clientVersion(0),
    _clientFormatNo(-1),
    _sampleRate(0),
    _channels(0),
    _bitsPerSample(0),
    _bytesPerSec(0),
    _blockNo(0),
    _lastConfirmedBlockNo(0xff),
    _unconfirmedBytes(0),
    _lastConfirmTimeMs(0),
    _audioStartTimeMs(0)
{
    memset(_blockBytes, 0, sizeof(_blockBytes));
}

SoundChannel::~SoundChannel() {
    Release();
}

bool SoundChannel::Initialize(const struct mod* mod) {
    assert(mod != NULL);

    Release();

    _mod = mod;

    // 클라이언트가 오디오 재생을 원하지 않을 경우 rdpsnd 채널 자체가 없음
    _channelId = mod->server_get_channel_id((struct mod*)mod, RDPSND_SVC_CHANNEL_NAME);
    if (_channelId < 0) {
        return false;
    }

    return true;
}

void SoundChannel::Release() {
    free(_incoming);
    _incoming = NULL;
    _incomingLen = 0;
    _incomingTotalLen = 0;

    _mod = NULL;
    _channelId = -1;
    _state = State::IDLE;
    _formatsSent = false;
    _clientVersion = 0;
    _clientFormatNo = -1;
    _sampleRate = 0;
    _channels = 0;
    _bitsPerSample = 0;
    _bytesPerSec = 0;
    _blockNo = 0;
    _lastConfirmedBlockNo = 0xff;
    memset(_blockBytes, 0, sizeof(_blockBytes));
    _unconfirmedBytes = 0;
    _lastConfirmTimeMs = 0;
    _audioStartTimeMs = 0;
}

bool SoundChannel::IsSoundChannel(int channelId) const {
    return _channelId >= 0 && channelId == _channelId;
}

void SoundChannel::SendServerFormats() {
    if (_mod == NULL || _channelId < 0 || _formatsSent) {
        return;
    }

    PduWriter w(_outBuf, sizeof(_outBuf));

    w.Header(SNDC_FORMATS);
    w.UInt32(0);                            // dwFlags
    w.UInt32(0);                            // dwVolume
    w.UInt32(0);                            // dwPitch
    w.UInt16(0);                            // wDGramPort (UDP 미사용)
    w.UInt16((uint16_t)kNumServerFormats);  // wNumberOfFormats
    w.UInt8(_blockNo);                      // cLastBlockConfirmed
    w.UInt16(RDPSND_SERVER_VERSION);        // wVersion
    w.UInt8(0);                             // bPad

    for (int i = 0; i < kNumServerFormats; i++) {
        const PcmFormat& f = kServerFormats[i];
        int blockAlign = f.channels * f.bitsPerSample / 8;

        w.UInt16(WAVE_FORMAT_PCM);                      // wFormatTag
        w.UInt16((uint16_t)f.channels);                 // nChannels
        w.UInt32((uint32_t)f.sampleRate);               // nSamplesPerSec
        w.UInt32((uint32_t)(f.sampleRate * blockAlign)); // nAvgBytesPerSec
        w.UInt16((uint16_t)blockAlign);                 // nBlockAlign
        w.UInt16((uint16_t)f.bitsPerSample);            // wBitsPerSample
        w.UInt16(0);                                    // cbSize
    }

    w.EndPdu();
    _SendPdu(w.buf, w.len);

    _formatsSent = true;
    _state = State::WAIT_CLIENT_FORMATS;
}

void SoundChannel::HandleChannelData(int channelFlags, const char* data, int dataLen, int totalLen) {
    if (data == NULL || dataLen <= 0 || totalLen <= 0 || totalLen > MAX_INCOMING_PDU_SIZE) {
        return;
    }

    if ((channelFlags & XR_CHANNEL_FLAG_FIRST) != 0) {
        if (totalLen > _incomingTotalLen || _incoming == NULL) {
            char* buffer = (char*)realloc(_incoming, totalLen);
            if (buffer == NULL) {
                return;
            }
            _incoming = buffer;
        }

        _incomingLen = 0;
        _incomingTotalLen = totalLen;
    }

    // FIRST chunk 없이 들어온 데이터 또는 길이가 맞지 않는 chunk 는 무시 (다음 FIRST chunk 까지)
    if (_incoming == NULL || totalLen != _incomingTotalLen || _incomingLen + dataLen > totalLen) {
        _incomingLen = 0;
        _incomingTotalLen = 0;
        return;
    }

    memcpy(_incoming + _incomingLen, data, dataLen);
    _incomingLen += dataLen;

    if ((channelFlags & XR_CHANNEL_FLAG_LAST) == 0) {
        return;
    }

    if (_incomingLen == _incomingTotalLen) {
        _ProcessPdu((const uint8_t*)_incoming, _incomingLen);
    }

    _incomingLen = 0;
    _incomingTotalLen = 0;
}

bool SoundChannel::IsReady() const {
    return _state == State::READY;
}

int SoundChannel::GetSampleRate() const {
    return _sampleRate;
}

int SoundChannel::GetChannels() const {
    return _channels;
}

int SoundChannel::GetBitsPerSample() const {
    return _bitsPerSample;
}

void SoundChannel::SendAudio(const void* pcm, int pcmLen) {
    if (_state != State::READY || pcm == NULL || pcmLen <= 0) {
        return;
    }

    // PCM 은 nBlockAlign 단위여야 함
    int blockAlign = _channels * _bitsPerSample / 8;
    pcmLen -= pcmLen % blockAlign;
    if (pcmLen < 4 || pcmLen > OSXRDP_AUDIO_MAX_CHUNK) {
        return;
    }

    if (_ShouldDropBlock()) {
        return;
    }

    uint64_t now = _NowMs();
    uint16_t wTimeStamp = (uint16_t)(now & 0xffff);
    const uint8_t* src = (const uint8_t*)pcm;

    PduWriter w(_outBuf, sizeof(_outBuf));

    if (_clientVersion >= RDPSND_VERSION_WAVE2) {
        // Wave2 PDU (단일 PDU)
        w.Header(SNDC_WAVE2);
        w.UInt16(wTimeStamp);                           // wTimeStamp
        w.UInt16((uint16_t)_clientFormatNo);            // wFormatNo
        w.UInt8(_blockNo);                              // cBlockNo
        w.UInt8(0);                                     // bPad[3]
        w.UInt8(0);
        w.UInt8(0);
        w.UInt32((uint32_t)(now - _audioStartTimeMs));  // dwAudioTimeStamp
        w.Data(src, pcmLen);
        w.EndPdu();

        if (w.Overflowed()) {
            return;
        }

        _SendPdu(w.buf, w.len);
    }
    else {
        // WaveInfo PDU + Wave PDU
        // WaveInfo 는 데이터의 처음 4byte 를 포함하고, Wave PDU 는 그 자리를 4byte padding 으로 채운다.
        w.Header(SNDC_WAVE);
        w.UInt16(wTimeStamp);                           // wTimeStamp
        w.UInt16((uint16_t)_clientFormatNo);            // wFormatNo
        w.UInt8(_blockNo);                              // cBlockNo
        w.UInt8(0);                                     // bPad[3]
        w.UInt8(0);
        w.UInt8(0);
        w.Data(src, 4);                                 // Data[4]
        // BodySize = WaveInfo 이후 필드(8) + 전체 wave 데이터 길이
        w.SetBodySize((uint16_t)(8 + pcmLen));

        _SendPdu(w.buf, w.len);

        PduWriter wave(_outBuf, sizeof(_outBuf));
        wave.UInt32(0);                                 // bPad
        wave.Data(src + 4, pcmLen - 4);

        if (wave.Overflowed()) {
            return;
        }

        _SendPdu(wave.buf, wave.len);
    }

    _TrackSentBlock(pcmLen);
}

void SoundChannel::_ProcessPdu(const uint8_t* pdu, int pduLen) {
    if (pduLen < RDPSND_HEADER_SIZE) {
        return;
    }

    uint8_t msgType = pdu[0];
    int bodySize = GetUInt16(pdu + 2);
    const uint8_t* body = pdu + RDPSND_HEADER_SIZE;
    int bodyLen = pduLen - RDPSND_HEADER_SIZE;

    if (bodySize < bodyLen) {
        bodyLen = bodySize;
    }

    switch (msgType) {
        case SNDC_FORMATS:
            _ProcessClientFormats(body, bodyLen);
            break;
        case SNDC_TRAINING:
            _ProcessTrainingConfirm(body, bodyLen);
            break;
        case SNDC_WAVECONFIRM:
            _ProcessWaveConfirm(body, bodyLen);
            break;
        case SNDC_QUALITYMODE:
            // PCM 만 사용하므로 품질 모드는 무시
            break;
        default:
            break;
    }
}

void SoundChannel::_ProcessClientFormats(const uint8_t* body, int bodyLen) {
    if (_state != State::WAIT_CLIENT_FORMATS || bodyLen < 20) {
        return;
    }

    uint32_t dwFlags = GetUInt32(body);
    int numFormats = GetUInt16(body + 14);
    _clientVersion = GetUInt16(body + 17);

    // TSSNDCAPS_ALIVE 가 없으면 클라이언트가 오디오를 재생할 수 없음
    if ((dwFlags & TSSNDCAPS_ALIVE) == 0) {
        _state = State::UNSUPPORTED;
        return;
    }

    // 클라이언트 포맷 중 가장 적합한 PCM 포맷 선택 (wFormatNo 는 클라이언트 목록 기준 index)
    int bestIndex = -1;
    int bestScore = 0;
    int offset = 20;

    for (int i = 0; i < numFormats; i++) {
        if (offset + AUDIO_FORMAT_SIZE > bodyLen) {
            break;
        }

        const uint8_t* fmt = body + offset;
        uint16_t formatTag = GetUInt16(fmt);
        int channels = GetUInt16(fmt + 2);
        int sampleRate = (int)GetUInt32(fmt + 4);
        int bitsPerSample = GetUInt16(fmt + 14);
        int cbSize = GetUInt16(fmt + 16);

        offset += AUDIO_FORMAT_SIZE + cbSize;

        if (formatTag != WAVE_FORMAT_PCM || bitsPerSample != 16) {
            continue;
        }

        if ((channels != 1 && channels != 2) || sampleRate < 8000 || sampleRate > 192000) {
            continue;
        }

        int score = 1;
        if (sampleRate == 48000) score = 30;
        else if (sampleRate == 44100) score = 20;
        else if (sampleRate > 22050) score = 10;
        if (channels == 2) score += 5;

        if (score > bestScore) {
            bestScore = score;
            bestIndex = i;
            _sampleRate = sampleRate;
            _channels = channels;
            _bitsPerSample = bitsPerSample;
        }
    }

    if (bestIndex < 0) {
        printf("[SoundChannel] no compatible client audio format\n");
        _state = State::UNSUPPORTED;
        return;
    }

    _clientFormatNo = bestIndex;
    _bytesPerSec = _sampleRate * _channels * _bitsPerSample / 8;

    printf("[SoundChannel] client format #%d (%d Hz, %d ch, %d bit), version %d\n",
           _clientFormatNo, _sampleRate, _channels, _bitsPerSample, _clientVersion);

    _SendTraining();
}

void SoundChannel::_ProcessTrainingConfirm(const uint8_t* body, int bodyLen) {
    (void)body;

    if (_state != State::WAIT_TRAINING || bodyLen < 4) {
        return;
    }

    uint64_t now = _NowMs();
    _lastConfirmTimeMs = now;
    _audioStartTimeMs = now;
    _state = State::READY;
}

void SoundChannel::_ProcessWaveConfirm(const uint8_t* body, int bodyLen) {
    if (_state != State::READY || bodyLen < 4) {
        return;
    }

    uint8_t confirmed = body[2];

    // 미확인 block 범위 내의 confirm 인지 확인 (중복/오래된 confirm 무시)
    uint8_t outstanding = (uint8_t)(_blockNo - 1 - _lastConfirmedBlockNo);
    uint8_t distance = (uint8_t)(confirmed - _lastConfirmedBlockNo);
    if (distance == 0 || distance > outstanding) {
        return;
    }

    while (_lastConfirmedBlockNo != confirmed) {
        _lastConfirmedBlockNo++;
        _unconfirmedBytes -= _blockBytes[_lastConfirmedBlockNo];
        _blockBytes[_lastConfirmedBlockNo] = 0;
    }

    if (_unconfirmedBytes < 0) {
        _unconfirmedBytes = 0;
    }

    _lastConfirmTimeMs = _NowMs();
}

void SoundChannel::_SendTraining() {
    PduWriter w(_outBuf, sizeof(_outBuf));

    w.Header(SNDC_TRAINING);
    w.UInt16((uint16_t)(_NowMs() & 0xffff));  // wTimeStamp
    w.UInt16(0);                              // wPackSize (data 없음)
    w.EndPdu();

    _SendPdu(w.buf, w.len);

    _state = State::WAIT_TRAINING;
}

bool SoundChannel::_ShouldDropBlock() {
    if (_bytesPerSec <= 0 || _unconfirmedBytes == 0) {
        return false;
    }

    int64_t unconfirmedMs = _unconfirmedBytes * 1000 / _bytesPerSec;
    if (unconfirmedMs <= MAX_UNCONFIRMED_MS) {
        return false;
    }

    // confirm 이 오랫동안 오지 않음 -> 흐름 제어 초기화 후 전송 재개
    if (_NowMs() - _lastConfirmTimeMs > CONFIRM_TIMEOUT_MS) {
        memset(_blockBytes, 0, sizeof(_blockBytes));
        _unconfirmedBytes = 0;
        _lastConfirmedBlockNo = (uint8_t)(_blockNo - 1);
        _lastConfirmTimeMs = _NowMs();

        return false;
    }

    return true;
}

void SoundChannel::_TrackSentBlock(int pcmLen) {
    // 256 block 을 넘게 확인되지 않으면 block 번호가 겹치므로 가장 오래된 block 을 확인된 것으로 처리
    if (_blockNo == _lastConfirmedBlockNo) {
        _lastConfirmedBlockNo++;
        _unconfirmedBytes -= _blockBytes[_lastConfirmedBlockNo];
        _blockBytes[_lastConfirmedBlockNo] = 0;
    }

    _blockBytes[_blockNo] = pcmLen;
    _unconfirmedBytes += pcmLen;
    _blockNo++;
}

void SoundChannel::_SendPdu(const uint8_t* pdu, int pduLen) {
    if (_mod == NULL || _channelId < 0 || pdu == NULL || pduLen <= 0) {
        return;
    }

    int offset = 0;
    while (offset < pduLen) {
        int chunkLen = pduLen - offset;
        if (chunkLen > CHANNEL_CHUNK_LENGTH) {
            chunkLen = CHANNEL_CHUNK_LENGTH;
        }

        int flags = 0;
        if (offset == 0) flags |= XR_CHANNEL_FLAG_FIRST;
        if (offset + chunkLen >= pduLen) flags |= XR_CHANNEL_FLAG_LAST;

        _mod->server_send_to_channel((struct mod*)_mod, _channelId, (char*)(pdu + offset), chunkLen, pduLen, flags);

        offset += chunkLen;
    }
}

uint64_t SoundChannel::_NowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);

    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)(ts.tv_nsec / 1000000);
}
