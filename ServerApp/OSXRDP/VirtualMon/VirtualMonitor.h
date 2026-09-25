
#ifndef VirtualMonitor_h
#define VirtualMonitor_h

#include "CGVirtualDisplayPrivate.h"
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <pthread.h>

struct VIRTUALMONITOR_INFO {
    int left;
    int top;
    int width;
    int height;
    int is_retina;
    int is_primary;
    CGVirtualDisplay* virtualDisplay;
    int refresh_rate;
    int max_pixels; // 생성 시 descriptor 의 maxPixelsWide/High (이 크기 이내로만 재설정 가능)
};

class VirtualMonitor {
public:
    VirtualMonitor();
    ~VirtualMonitor();
    
    // 가상 모니터를 생성
    bool Create(int width, int height, int left, int top, int index, bool isPrimary = false);
    
    // 기존 가상 모니터의 해상도/위치를 변경 (클라이언트 창 크기 변경, 회전 등)
    // 생성 시 최대 크기를 넘는 경우 false (호출자가 재생성해야 함)
    bool Resize(int index, int width, int height, int left, int top, bool isPrimary);
    
    int GetCount() {
        return _virtualDisplayInfoCnt;
    }
    
    // 모든 가상 모니터를 파괴
    void Destroy();
    
    // 가상 모니터를 제외한 나머지 모니터를 비활성화
    // 가상 모니터를 파괴 시 원래대로 돌아옴
    bool DisableOtherMonitors();
    
    // 비활성화 하였던 나머지 모니터들을 다시 활성화
    void RestoreOtherMonitors(int verifyTimeoutMs = 1000);
    bool WaitPendingDisplaysOnline(int timeoutMs);
    
    void StartMonitor();
    
    bool IsRetina(int index) {
        if (index >= _virtualDisplayInfoCnt) return false;
        return _virtualDisplayInfo[index].is_retina == 0 ? false : true;
    }
    
    int GetDisplayId(int index) {
        if (index >= _virtualDisplayInfoCnt) return -1;
        return (int)_virtualDisplayInfo[index].virtualDisplay.displayID;
    }
    
    int GetDisplayRefreshRate(int index) {
        if (index >= _virtualDisplayInfoCnt) return 30;
        return (int)_virtualDisplayInfo[index].refresh_rate;
    }
    
    void HoldDisplaySleepAssertion();
    void ReleaseDisplaySleepAssertion();
    
    static void WakeupDisplay();
    
private:

    struct VIRTUALMONITOR_INFO _virtualDisplayInfo[16];
    int _virtualDisplayInfoCnt;

    bool _init;
    
    pthread_t _watchThread;
    pthread_mutex_t _watchLock;
    pthread_cond_t _watchWake;
    bool _watchRunning;
    IOPMAssertionID _displaySleepAssertion;

    bool IsVirtualDisplay(CGDirectDisplayID displayId);
    bool IsAllVirtualDisplayOnline();
    int GetPrimaryDisplayIndex();
    bool IsRightPrimaryDisplay();
    bool IsRightDisplayLayout();
    int CalcRefreshRate(int width, int height);
    static int CalcScale(int width, int height);
    static CGVirtualDisplaySettings* CreateDisplaySettings(int width, int height, int scale, int refreshRate);

    int SetResolution(int index);
    bool IsRightResolution(int index);
    int SetPrimaryDisplay();
    int ApplyDisplayLayout();
    
    void WatchThreadPorcInternal();
    
    static void* WatchThreadProc(void* args);
};

#endif /* VirtualMonitor_h */
