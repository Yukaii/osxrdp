
#ifndef ConnectionManager_h
#define ConnectionManager_h

#include "../Paint/PaintManager.h"
#include "../Status/StatusManager.h"
#include "../Channel/ChannelManager.h"
#include "../Channel/SoundChannel.h"
#include "../Command/Command.h"

#include <pthread.h>
#include <stdint.h>

struct mod;

class ConnectionManager {
public:
    ConnectionManager();
    ~ConnectionManager();
    
    int Initialize();
    void Release();
    
    // 초기 연결 수행
    bool Connect(const struct mod* mod);
    
    // ipc 메시지 펌프 및 연결 상태 확인
    void KeepAlive();
    void GetWaitObjects(void* read_objs, int* rcount);
    
    // 마우스 입력 전달
    void SendMouseInput(int inputType, short x, short y, int delta);
    
    // 키보드 입력 전달
    void SendKeyboardInput(int inputType, int keycode, int flags);
    void SendInputSync(int toggleFlags);
    
    // 상태 조회
    bool CanPaint();
    bool CanAcceptInput();
    bool NeedTerminate();
    void SetSuppress(bool suppress);
    
    void Terminate();
    
    // 화면 그리기
    void Paint();
    void PaintEnd(int ackFrameId);
    
    // handle channel msg (clipboard, etc)
    void HandleChannelMsg(long param1, long param2, long param3, long param4);
    
    // 클라이언트 해상도 변경 (xrdp dynamic resize, mod 의 해상도 정보는 이미 갱신된 상태)
    // inProgress 가 1 이면 녹화 재구성이 끝난 뒤 server_monitor_resize_done 을 호출
    void Resize(int* inProgress);
    
private:
    bool _inited;
    StatusManager _statusManager;
    Command _command;
    PaintManager _paintManager;
    ChannelManager _channelManager;
    SoundChannel _soundChannel;
    
    xipc_t* _sessionIpc;
    xipc_t* _agentIpc;
    int _sessionId;
    const mod* _mod;
    bool _pendingInputSync;
    int _pendingToggleFlags;
    bool _audioRequested;
    
    // dynamic resize 상태
    bool _resizePending;        // xrdp 가 server_monitor_resize_done 을 기다리는 중
    bool _recordSizeDirty;      // agent 의 녹화 해상도가 mod 해상도와 다름
    uint64_t _resizeStartMs;
    
    bool _ConnectToSessionManager();
    bool _ConnectToAgent(int sessionId, bool isLockScreen);
    bool _PreparePaint();
    
    void _SendRecordRequest(xipc_t* ipc, bool resize);
    void _HandleRecordReply(bool succeeded);
    void _CompleteResize();
    
    // rdpsnd 협상이 끝났고 agent 가 녹화 중이면 오디오 캡처 요청
    void _RequestAudioIfReady();
        
    void _HandleSessionMessage(int sessionId, int isLockScreen);
    
    // session manager 수신 메시지 처리
    static int _OnReceivedSessionManagerMessage(xipc_t* t, xipc_t* client, void* data, int len);
    
    // agent 수신 메시지 처리
    static int _OnReceivedAgentManagerMessage(xipc_t* t, xipc_t* client, void* data, int len);
};

#endif /* ConnectionManager_h */
