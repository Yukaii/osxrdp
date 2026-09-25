#ifndef packet_h
#define packet_h

#ifndef OSXRDP_PACKETTYPE
#define OSXRDP_PACKETTYPE

#define OSXRDP_RECORDFORMAT_BGRA32          0
#define OSXRDP_RECORDFORMAT_NV12_PACKED     1
#define OSXRDP_RECORDFORMAT_NV12_ALIGNED    2
#define OSXRDP_RECORDFORMAT_RFX             3

#define OSXRDP_CMDTYPE_SCREEN 1
#define OSXRDP_PACKETTYPE_REQ_SCREEN 1
#define OSXRDP_PACKETTYPE_REP_SCREEN 2
#define OSXRDP_PACKETTYPE_REQ_SCREENOFF 3
#define OSXRDP_PACKETTYPE_REP_SCREENOFF 4
#define OSXRDP_PACKETTYPE_MOUSEEVT      5
#define OSXRDP_PACKETTYPE_KEYBOARDEVT   6
#define OSXRDP_PACKETTYPE_INPUTSYNC     7
#define OSXRDP_PACKETTYPE_REQ_SCREENRESIZE 8 // REQ_SCREEN 과 동일한 payload, 응답은 REP_SCREEN

#define OSXRDP_CMDTYPE_CLIPBOARD 2
#define OSXRDP_PACKETTYPE_REQ_SETCLIENTCLIP 1
#define OSXRDP_PACKETTYPE_REP_SETCLIENTCLIP 2

#define OSXRDP_CMDTYPE_MSGFROMAGENT 3
#define OSXRDP_PACKETTYPE_TERMINATE 1

#define OSXRDP_CMDTYPE_NEEDPAINT 4

#define OSXRDP_CMDTYPE_AUDIO 5
#define OSXRDP_PACKETTYPE_REQ_AUDIOSTART 1  // osxup -> agent (sampleRate, channels, bitsPerSample)
#define OSXRDP_PACKETTYPE_AUDIODATA      2  // agent -> osxup (dataLen, interleaved PCM)

// ipc 수신 버퍼(MAX_BUFFER, 16KB)를 넘지 않도록 audio 데이터 1회 전송량 제한
#define OSXRDP_AUDIO_MAX_CHUNK 8192

// 마이크 (클라이언트 -> mac). mac 에서 가상 마이크로 녹음하는 앱이 있을 때만 클라이언트 마이크를 사용
#define OSXRDP_CMDTYPE_MIC 6
#define OSXRDP_PACKETTYPE_MIC_REQ_START 1   // agent -> osxup (가상 마이크 녹음 시작)
#define OSXRDP_PACKETTYPE_MIC_REQ_STOP  2   // agent -> osxup (가상 마이크 녹음 종료)
#define OSXRDP_PACKETTYPE_MIC_FORMAT    3   // osxup -> agent (sampleRate, channels, bitsPerSample)
#define OSXRDP_PACKETTYPE_MIC_DATA      4   // osxup -> agent (dataLen, interleaved PCM)


#endif

#ifndef XRDP_KEYBOARD_EVT
#define XRDP_KEYBOARD_EVT

#define XRDP_KEYBOARD_DOWN  15
#define XRDP_KEYBOARD_UP    16

#endif


#ifndef XRDP_MOUSE_EVT
#define XRDP_MOUSE_EVT

#define XRDP_MOUSE_MOVE         100
#define XRDP_MOUSE_LBTNUP       101
#define XRDP_MOUSE_LBTNDOWN     102
#define XRDP_MOUSE_RBTNUP       103
#define XRDP_MOUSE_RBTNDOWN     104
#define XRDP_MOUSE_MBTNUP       105
#define XRDP_MOUSE_MBTNDOWN     106
#define XRDP_MOUSE_WHEELUP      107
#define XRDP_MOUSE_WHEELDOWN    109
#define XRDP_MOUSE_BBTNUP       115 // 마우스 뒤로가기키 (측면)
#define XRDP_MOUSE_BBTNDOWN     116
#define XRDP_MOUSE_FBTNUP       117 // 마우스 앞으로가기키 (측면)
#define XRDP_MOUSE_FBTNDOWN     118

#ifndef WM_TOUCH_VSCROLL
#define WM_TOUCH_VSCROLL        140
#define WM_TOUCH_HSCROLL        141
#endif

#endif


// for sessionmanager
#ifndef OSXRDP_SESSIONMANAGER_PACKETTYPE
#define OSXRDP_SESSIONMANAGER_PACKETTYPE

#define OSXRDP_SESSMAN_REQUEST_SESSION 1
#define OSXRDP_SESSMAN_REPLY_SESSION 2
#define OSXRDP_SESSMAN_REQUEST_RELEASESESSION 3
#define OSXRDP_SESSMAN_REPLY_RELEASESESSION 4 // unused

#endif

#ifndef OSXRDP_CHANNEL_MSG_TYPE
#define OSXRDP_CHANNEL_MSG_TYPE

#define OSXRDP_CHANNEL_CLIPBOARD 0
#define OSXRDP_CHANNEL_INVALID -1

#endif



#endif /* packet_h */
