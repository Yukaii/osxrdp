#ifndef MicrophoneManager_h
#define MicrophoneManager_h

#include "ipc.h"
#include "xstream.h"

// RDP 클라이언트의 마이크를 "OSXRDP Microphone" 가상 오디오 장치 (AudioDriver) 로 전달
//
// - 가상 마이크로 녹음하는 앱이 있을 때만 osxup 에 클라이언트 마이크를 요청
// - osxup 에서 받은 PCM 을 가상 장치의 출력으로 재생 (장치가 입력으로 loopback)
// - 세션 동안 가상 마이크를 기본 입력 장치로 설정하고 종료 시 복원
class MicrophoneManager {
public:
    MicrophoneManager();
    ~MicrophoneManager();

    // 가상 마이크 사용 여부 감시 시작 (사용자 세션 agent 에서만)
    void Start(xipc_t* client);

    // 감시 / 재생 정지, 기본 입력 장치 복원
    void Stop();

    void HandleCommand(xipc_t* client, xstream_t* cmd);

private:
    void* _impl; // MicrophoneImpl
};

#endif /* MicrophoneManager_h */
