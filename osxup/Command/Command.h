

#ifndef Command_h
#define Command_h

#include "ipc.h"
#include "xstream.h"
#include "../xrdp/xrdp_client_info.h"

class Command {
  
public:
    
    void SendRecordStartMsg(xipc_t* agentIpc, int width, int height, int recordFormat, int useVirtualmon, int monitorCount, struct monitor_info* monitorInfo);
    void SendRecordResizeMsg(xipc_t* agentIpc, int width, int height, int recordFormat, int useVirtualmon, int monitorCount, struct monitor_info* monitorInfo);
    void SendRecordStopMsg(xipc_t* agentIpc);
    
    void SendMouseInputMsg(xipc_t* agentIpc, int inputType, short x, short y, int delta);
    void SendKeyboardInputMsg(xipc_t* agentIpc, int inputType, int keycode, int flags);
    void SendInputSyncMsg(xipc_t* agentIpc, int toggleFlags);
    
    void SendSessionRequestMsg(xipc_t* sessionIpc, const char* username, int usernameLen);
    void SendSessionReleaseMsg(xipc_t* sessionIpc, int sessionId);

    void SendClipboardMsg(xipc_t* agentIpc, int channelId, int channelFlags, const char* data, int dataLen, int totalLen);

    void SendAudioStartMsg(xipc_t* agentIpc, int sampleRate, int channels, int bitsPerSample);
    
private:
    
    void _SendRecordMsg(xipc_t* agentIpc, int packetType, int width, int height, int recordFormat, int useVirtualmon, int monitorCount, struct monitor_info* monitorInfo);
    void _SendMsg(xipc_t* ipc, xstream_t* stream);
};

#endif
