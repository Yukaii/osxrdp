#ifndef DisplayUtils_h
#define DisplayUtils_h

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

class DisplayUtils {
public:
    // 디스플레이가 온라인 상태인지 확인
    static bool IsDisplayOnline(CGDirectDisplayID displayId);
    
    // OSXRDP 가 생성한 가상 모니터인지 확인 (다른 클라이언트의 VirtualMonitor 가 만든 것 포함)
    static bool IsOsxrdpVirtualDisplay(CGDirectDisplayID displayId);
    
    // 특정 디스플레이 외의 다른 온라인 디스플레이가 있는지 확인
    static bool HasOtherOnlineDisplay(CGDirectDisplayID displayId);
    
    // 디스플레이가 특정 상태로 전환될때까지 대기 (온라인/오프라인)
    static bool WaitDisplayOnlineState(CGDirectDisplayID displayId, bool shouldBeOnline, int timeoutMs);
};

#endif /* DisplayUtils_h */
