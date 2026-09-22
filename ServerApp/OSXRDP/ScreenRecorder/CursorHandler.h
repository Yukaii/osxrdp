//
//  CursorHandler.h
//  OSXRDP
//
//  Created by byungho on 2/9/26.
//

#ifndef CursorHandler_h
#define CursorHandler_h

#include "osxrdp/screenrecordshm.h"

class CursorHandler {
public:
    CursorHandler();
    ~CursorHandler();
    
    bool HandleCursorInfo(cursor_data_t* cursor);
    
private:
    int _cursorseed;
    
    char* _tmpbuffer;
    
    // 마우스 커서 정보를 가져오기 위한 connection id
    int _connectionId;
    
    long long _lastCheckTime;

    // 보낼수 없는 커서일 경우 사용하는 폴백용 macOS 기본 커서
    char* _fallbackImgData;
    int _fallbackWidth;
    int _fallbackHeight;
    int _fallbackHotX;
    int _fallbackHotY;

    // 현재 기본 커서로 대체해 둔 상태인지 및 애니메이션 커서가 매 프레임 재전송되는 것을 막는다.
    bool _fallbackActive;

    bool QueryCursorImage(int* srcWidth, int* srcHeight, int* srcRowBytes, int* srcSizeBytes, int* hotX, int* hotY);
    bool BuildFallbackPointer();
    bool ApplyFallbackPointer(cursor_data_t* cursor);
    
    // 커서가 완전히 투명한지. (앱이 투명 이미지로 커서 이미지를 지정한 경우)
    bool IsFullyTransparentBGRA(const char* data, int pixelCount);
    
    void StorePointer(cursor_data_t* cursor, const char* src, int srcRowBytes, int srcSizeBytes, int srcWidth, int srcHeight, int hotX, int hotY);
    int PickSquarePointerSize(int width, int height);
    void BuildSquarePointerBGRA(const char* src, int srcRowBytes, int srcSizeBytes, int srcWidth, int srcHeight, int dstSize, char* dstData);
    
    // 움직이는 커서의 높이
    int CurrentCursorFrameHeight(int stripWidth, int stripHeight);
};

#endif /* CursorHandler_h */
