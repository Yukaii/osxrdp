#include "VirtualMonitor.h"
#include "DisplayUtils.h"
#include "LocalCurtain.h"

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <unistd.h>

// 가상 모니터 해상도 목록
//  이와 같이 구성을 채우지 않으면 macOS 가 이를 모니터가 아닌 다른 무언가로 인식하여 대화상자를 띄우는것 같음 (airplay 수신기?)
//  따라서 기본 구성을 진짜 모니터처럼 넣고 xrdp 해상도를 마지막에 넣는다.
static const int baseModes[][2] = {
    { 3840, 2160 }, { 2560, 1440 }, { 1920, 1080 }, { 1600, 900 }, { 1366, 768 }, { 1280, 720 },
    { 2560, 1600 }, { 1920, 1200 }, { 1680, 1050 }, { 1440, 900 }, { 1280, 800 }
};

VirtualMonitor::VirtualMonitor() :
    _virtualDisplayInfoCnt(0),
    _init(false),
    _watchRunning(false),
    _displaySleepAssertion(kIOPMNullAssertionID),
    _curtainHeld(false)
{
    pthread_mutex_init(&_watchLock, 0);
    pthread_cond_init(&_watchWake, 0);
}

VirtualMonitor::~VirtualMonitor() {
    Destroy();
    
    pthread_cond_destroy(&_watchWake);
    pthread_mutex_destroy(&_watchLock);
}

bool VirtualMonitor::Create(int width, int height, int left, int top, int index, bool isPrimary) {
    if (_virtualDisplayInfoCnt >= 16) return false;

    HoldDisplaySleepAssertion();
    WakeupDisplay();

    // retina 여부 판단
    int scale = CalcScale(width, height);
    int refreshRate = CalcRefreshRate(width, height);

    // 가상 디스플레이를 생성
    CGVirtualDisplayDescriptor* desc = [[CGVirtualDisplayDescriptor alloc] init];
    if (desc == nil) return false;

    // 회전(가로/세로 전환) 시 재생성 없이 해상도를 바꿀 수 있도록 최대 크기는 긴 변 기준의 정사각형으로 설정
    int maxPixels = width > height ? width : height;

    // 가상 디스플레이의 기본 속성
    desc.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    desc.name = @"OSXRDP Virtual Display";
    desc.maxPixelsWide = maxPixels;
    desc.maxPixelsHigh = maxPixels;
    desc.sizeInMillimeters = CGSizeMake((double)(width / scale) * 25.4 / 96.0,
                                        (double)(height / scale) * 25.4 / 96.0);
    desc.productID = 0x5969 + index;
    desc.vendorID = 0x1207;
    desc.serialNum = 0x0007 + index;

    CGVirtualDisplaySettings* settings = CreateDisplaySettings(width, height, scale, refreshRate);
    if (settings == nil)
        return false;

    CGVirtualDisplay* virtualDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (virtualDisplay == nil)
        return false;

    // 가상 디스플레이 속성 적용
    if ([virtualDisplay applySettings:settings] == NO) {
        NSLog(@"[VirtualMonitor::Create] applySettings failed %dx%d@%dHz scale=%d", width, height, refreshRate, scale);

        return false;
    }

    WakeupDisplay();

    if (DisplayUtils::WaitDisplayOnlineState(virtualDisplay.displayID, true, 5000) == false) {
        NSLog(@"[VirtualMonitor::Create] display is not online yet; continue waiting in monitor thread %dx%d@%dHz scale=%d", width, height, refreshRate, scale);
    }

    _virtualDisplayInfo[_virtualDisplayInfoCnt].left = left;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].top = top;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].width = width;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].height = height;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].is_retina = scale == 2 ? true : false;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].is_primary = isPrimary ? true : false;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].virtualDisplay = virtualDisplay;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].refresh_rate = refreshRate;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].max_pixels = maxPixels;
    
    _virtualDisplayInfoCnt++;

    ApplyDisplayLayout();

    return true;
}

bool VirtualMonitor::Resize(int index, int width, int height, int left, int top, bool isPrimary) {
    if (index < 0 || index >= _virtualDisplayInfoCnt) {
        return false;
    }

    struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[index];
    if (displayInfo->virtualDisplay == nil || width > displayInfo->max_pixels || height > displayInfo->max_pixels) {
        return false;
    }

    int scale = CalcScale(width, height);
    int refreshRate = CalcRefreshRate(width, height);

    CGVirtualDisplaySettings* settings = CreateDisplaySettings(width, height, scale, refreshRate);
    if (settings == nil) {
        return false;
    }

    // watch 스레드가 해상도/배치를 동시에 바꾸지 않도록 lock
    pthread_mutex_lock(&_watchLock);

    // 미러링 중에는 물리 모니터와 호환되는 모드만 사용할 수 있으므로 해상도 변경 동안 미러링 해제
    UnmirrorOtherMonitors();

    if ([displayInfo->virtualDisplay applySettings:settings] == NO) {
        MirrorOtherMonitors();
        pthread_mutex_unlock(&_watchLock);
        NSLog(@"[VirtualMonitor::Resize] applySettings failed %dx%d@%dHz scale=%d", width, height, refreshRate, scale);
        return false;
    }

    displayInfo->left = left;
    displayInfo->top = top;
    displayInfo->width = width;
    displayInfo->height = height;
    displayInfo->is_retina = scale == 2 ? true : false;
    displayInfo->is_primary = isPrimary ? true : false;
    displayInfo->refresh_rate = refreshRate;

    // 새 모드 목록이 반영될 때까지 잠시 재시도 (실패해도 watch 스레드가 다시 맞춘다)
    for (int i = 0; i < 10; i++) {
        if (SetResolution(index) == 0 && IsRightResolution(index)) {
            break;
        }
        usleep(100 * 1000);
    }

    ApplyDisplayLayout();
    MirrorOtherMonitors();
    LocalCurtain::Refresh();

    pthread_mutex_unlock(&_watchLock);

    NSLog(@"[VirtualMonitor::Resize] index=%d %dx%d@%dHz scale=%d", index, width, height, refreshRate, scale);
    return true;
}

void VirtualMonitor::Destroy(bool keepCurtain) {
    // 가상 모미터 watch 스레드 정지
    if (_watchRunning == true) {
        _watchRunning = false;
        pthread_cond_signal(&_watchWake);
        pthread_join(_watchThread, NULL); // 완전히 정지할때까지 대기
    }

    // 물리 모니터의 미러링을 먼저 해제 (실패해도 가상 모니터가 사라지면 미러링은 풀림)
    UnmirrorOtherMonitors();

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        // nil 로 설정하면 알아서 뽀개짐 (즉시 뽀개지는건 아님)
        _virtualDisplayInfo[i].virtualDisplay = nil;
    }

    _virtualDisplayInfoCnt = 0;
    memset(&_virtualDisplayInfo, 0x00, sizeof(_virtualDisplayInfo));

    _init = false;
    ReleaseDisplaySleepAssertion();

    // 가상 모니터를 다시 만드는 경우 (해상도 변경) 에는 로컬 화면/입력 차단을 유지
    if (_curtainHeld && keepCurtain == false) {
        LocalCurtain::Release();
        _curtainHeld = false;
    }
}

void VirtualMonitor::StartMonitor() {
    HoldDisplaySleepAssertion();
    WakeupDisplay();

    // 원격 세션 동안 로컬 화면을 가리고 로컬 입력을 차단
    if (_curtainHeld == false) {
        LocalCurtain::Acquire();
        _curtainHeld = true;
    }

    if (_watchRunning == false) {
        _watchRunning = true;
        pthread_create(&_watchThread , NULL, WatchThreadProc, this);
    }
}

void VirtualMonitor::WakeupDisplay() {
    IOPMAssertionID assertionID = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("OSXRDP: wake display"), kIOPMUserActiveLocal, &assertionID);
    if (assertionID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(assertionID);
        assertionID = kIOPMNullAssertionID;
    }
}

void VirtualMonitor::HoldDisplaySleepAssertion() {
    if (_displaySleepAssertion != kIOPMNullAssertionID) {
        return;
    }

    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                kIOPMAssertionLevelOn,
                                CFSTR("OSXRDP virtual monitor session"),
                                &_displaySleepAssertion);
}

void VirtualMonitor::ReleaseDisplaySleepAssertion() {
    if (_displaySleepAssertion == kIOPMNullAssertionID) {
        return;
    }

    IOPMAssertionRelease(_displaySleepAssertion);
    _displaySleepAssertion = kIOPMNullAssertionID;
}

// Physical displays are mirrored to the primary virtual display instead of
// being disabled. Turning the built-in panel off and on again could leave it
// toggling between hotplug "in" and "out", blocking the WindowServer main
// thread in the display driver until the watchdog killed WindowServer.
// Mirroring never powers the panel down, and removing the virtual display
// ends the mirroring by itself.
static CGDirectDisplayID* CopyOnlineDisplayList(uint32_t* outCount) {
    *outCount = 0;

    uint32_t displayCnt = 0;
    if (CGGetOnlineDisplayList(0, NULL, &displayCnt) != kCGErrorSuccess || displayCnt == 0) {
        return NULL;
    }

    CGDirectDisplayID* displayIds = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * displayCnt);
    if (displayIds == NULL) {
        return NULL;
    }

    if (CGGetOnlineDisplayList(displayCnt, displayIds, &displayCnt) != kCGErrorSuccess) {
        free(displayIds);
        return NULL;
    }

    *outCount = displayCnt;
    return displayIds;
}

bool VirtualMonitor::MirrorOtherMonitors() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || _virtualDisplayInfo[primaryIndex].virtualDisplay == nil) {
        return false;
    }

    CGDirectDisplayID masterId = _virtualDisplayInfo[primaryIndex].virtualDisplay.displayID;

    uint32_t displayCnt = 0;
    CGDirectDisplayID* displayIds = CopyOnlineDisplayList(&displayCnt);
    if (displayIds == NULL) {
        return false;
    }

    CGDisplayConfigRef cfg = NULL;
    int configuredCnt = 0;
    bool result = true;

    for (uint32_t i = 0; i < displayCnt; i++) {
        CGDirectDisplayID displayId = displayIds[i];
        if (IsVirtualDisplay(displayId) || DisplayUtils::IsOsxrdpVirtualDisplay(displayId) || CGDisplayMirrorsDisplay(displayId) == masterId) {
            continue;
        }

        if (cfg == NULL && (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess || cfg == NULL)) {
            cfg = NULL;
            result = false;
            break;
        }

        CGError err = CGConfigureDisplayMirrorOfDisplay(cfg, displayId, masterId);
        if (err == kCGErrorSuccess) {
            configuredCnt++;
        }
        else {
            NSLog(@"[VirtualMonitor::MirrorOtherMonitors] configure failed id=%u master=%u err=%d", displayId, masterId, err);
        }
    }

    free(displayIds);

    if (cfg == NULL) {
        return result;
    }

    if (configuredCnt == 0) {
        CGCancelDisplayConfiguration(cfg);
        return false;
    }

    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    if (completeErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonitor::MirrorOtherMonitors] complete failed err=%d", completeErr);
        return false;
    }

    NSLog(@"[VirtualMonitor::MirrorOtherMonitors] mirrored %d display(s) to %u", configuredCnt, masterId);
    return true;
}

void VirtualMonitor::UnmirrorOtherMonitors() {
    uint32_t displayCnt = 0;
    CGDirectDisplayID* displayIds = CopyOnlineDisplayList(&displayCnt);
    if (displayIds == NULL) {
        return;
    }

    CGDisplayConfigRef cfg = NULL;
    int configuredCnt = 0;

    for (uint32_t i = 0; i < displayCnt; i++) {
        // 이 인스턴스의 가상 모니터를 미러링 중인 디스플레이만 해제 (다른 클라이언트의 세션은 유지)
        if (IsVirtualDisplay(CGDisplayMirrorsDisplay(displayIds[i])) == false) {
            continue;
        }

        if (cfg == NULL && (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess || cfg == NULL)) {
            cfg = NULL;
            break;
        }

        if (CGConfigureDisplayMirrorOfDisplay(cfg, displayIds[i], kCGNullDirectDisplay) == kCGErrorSuccess) {
            configuredCnt++;
        }
    }

    free(displayIds);

    if (cfg == NULL) {
        return;
    }

    if (configuredCnt == 0) {
        CGCancelDisplayConfiguration(cfg);
        return;
    }

    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    NSLog(@"[VirtualMonitor::UnmirrorOtherMonitors] unmirrored %d display(s) err=%d", configuredCnt, completeErr);
}

bool VirtualMonitor::IsVirtualDisplay(CGDirectDisplayID displayId) {
    if (displayId == 0) {
        return false;
    }

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        if (_virtualDisplayInfo[i].virtualDisplay == nil) {
            continue;
        }

        if (_virtualDisplayInfo[i].virtualDisplay.displayID == displayId) {
            return true;
        }
    }

    return false;
}

bool VirtualMonitor::IsAllVirtualDisplayOnline() {
    if (_virtualDisplayInfoCnt <= 0) {
        return false;
    }

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        if (_virtualDisplayInfo[i].virtualDisplay == nil) {
            return false;
        }

        if (DisplayUtils::IsDisplayOnline(_virtualDisplayInfo[i].virtualDisplay.displayID) == false) {
            return false;
        }
    }

    return true;
}

int VirtualMonitor::GetPrimaryDisplayIndex() {
    if (_virtualDisplayInfoCnt <= 0) {
        return -1;
    }

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        if (_virtualDisplayInfo[i].is_primary != 0) {
            return i;
        }
    }

    return 0;
}

bool VirtualMonitor::IsRightPrimaryDisplay() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || primaryIndex >= _virtualDisplayInfoCnt) {
        return false;
    }

    if (_virtualDisplayInfo[primaryIndex].virtualDisplay == nil) {
        return false;
    }

    return CGMainDisplayID() == _virtualDisplayInfo[primaryIndex].virtualDisplay.displayID;
}

bool VirtualMonitor::IsRightDisplayLayout() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || primaryIndex >= _virtualDisplayInfoCnt) {
        return false;
    }

    struct VIRTUALMONITOR_INFO* primaryInfo = &_virtualDisplayInfo[primaryIndex];
    if (primaryInfo->virtualDisplay == nil) {
        return false;
    }

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[i];
        if (displayInfo->virtualDisplay == nil) {
            return false;
        }

        CGRect bounds = CGDisplayBounds(displayInfo->virtualDisplay.displayID);
        int expectedX = displayInfo->left - primaryInfo->left;
        int expectedY = displayInfo->top - primaryInfo->top;

        if ((int)bounds.origin.x != expectedX || (int)bounds.origin.y != expectedY) {
            return false;
        }
    }

    return IsRightPrimaryDisplay();
}

int VirtualMonitor::SetResolution(int index) {
    if (index < 0 || index >= _virtualDisplayInfoCnt) {
        return 1;
    }

    struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[index];
    if (displayInfo->virtualDisplay == nil) {
        return 1;
    }

    CGDisplayModeRef bestMode = NULL;
    
    // Retina 해상도 까지 조회하기 위한 옵션
    CFStringRef keys[1] = { kCGDisplayShowDuplicateLowResolutionModes };
    CFTypeRef values[1] = { kCFBooleanTrue };
        
    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault,
        (const void **)keys,
        (const void **)values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
        
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayInfo->virtualDisplay.displayID, options);
    if (modes == NULL) {
        NSLog(@"[VirtualMonitor::SetResolution] CGDisplayCopyAllDisplayModes null\n");
        CFRelease(options);
        
        return 1;
    }
    
    if (displayInfo->is_retina) {
        CFIndex cnt = CFArrayGetCount(modes);
        // Retina (HiDPI) 가 먹힌 해상도를 먼저 찾기
        for (CFIndex i = 0; i < cnt; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            
            size_t modeWidth = CGDisplayModeGetWidth(mode);
            size_t modeHeight = CGDisplayModeGetHeight(mode);
            
            if (modeWidth == (displayInfo->width / 2) && modeHeight == (displayInfo->height / 2)) {
                NSLog(@"found retina bestmode\n");
                bestMode = mode;
                break;
            }
        }
        
        // Retina 해상도를 찾지 못한 경우 일반 해상도를 찾기
        if (bestMode == NULL) {
            CFIndex cnt = CFArrayGetCount(modes);
            for (CFIndex i = 0; i < cnt; i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                
                size_t modeWidth = CGDisplayModeGetWidth(mode);
                size_t modeHeight = CGDisplayModeGetHeight(mode);
                
                if (modeWidth == displayInfo->width && modeHeight == displayInfo->height) {
                    NSLog(@"found bestmode\n");
                    bestMode = mode;
                    break;
                }
            }
        }
    }
    else {
        CFIndex cnt = CFArrayGetCount(modes);
        for (CFIndex i = 0; i < cnt; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            
            size_t modeWidth = CGDisplayModeGetWidth(mode);
            size_t modeHeight = CGDisplayModeGetHeight(mode);
            
            if (modeWidth == displayInfo->width && modeHeight == displayInfo->height) {
                NSLog(@"found bestmode\n");
                bestMode = mode;
                break;
            }
        }
    }
    
    if (bestMode == NULL) {
        NSLog(@"bestmode is null\n");
        
        CFRelease(modes);
        CFRelease(options);
        
        return 1;
    }
    
    CGError err = CGDisplaySetDisplayMode(displayInfo->virtualDisplay.displayID, bestMode, NULL);
    if (err != kCGErrorSuccess) {
        printf("Configure Resolution Failed. %d \n", err);
    }
    
    CFRelease(modes);
    CFRelease(options);
    
    return err == kCGErrorSuccess ? 0 : 1;
}

bool VirtualMonitor::IsRightResolution(int index) {
    if (index < 0 || index >= _virtualDisplayInfoCnt) {
        return false;
    }
    
    struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[index];
    if (displayInfo->virtualDisplay == nil) {
        return false;
    }

    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayInfo->virtualDisplay.displayID);
    if (mode == NULL) {
        return false;
    }
    
    size_t modeWidth = CGDisplayModeGetWidth(mode);
    size_t modeHeight = CGDisplayModeGetHeight(mode);
    size_t pixelWidth = CGDisplayModeGetPixelWidth(mode);
    size_t pixelHeight = CGDisplayModeGetPixelHeight(mode);
    
    bool result = false;
    if (displayInfo->is_retina) {
        result = (modeWidth == (displayInfo->width / 2) && modeHeight == (displayInfo->height / 2) &&
                  pixelWidth == displayInfo->width && pixelHeight == displayInfo->height);
    }
    else {
        result = (modeWidth == displayInfo->width && modeHeight == displayInfo->height &&
                  pixelWidth == displayInfo->width && pixelHeight == displayInfo->height);
    }
    
    CFRelease(mode);
    
    return result;
}

int VirtualMonitor::SetPrimaryDisplay() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || primaryIndex >= _virtualDisplayInfoCnt) {
        return 1;
    }

    struct VIRTUALMONITOR_INFO* primaryInfo = &_virtualDisplayInfo[primaryIndex];
    if (primaryInfo->virtualDisplay == nil) {
        return 1;
    }

    CGDirectDisplayID primaryDisplayId = primaryInfo->virtualDisplay.displayID;
    if (primaryDisplayId == 0) {
        return 1;
    }

    CGRect primaryBounds = CGDisplayBounds(primaryDisplayId);
    int offsetX = -(int)primaryBounds.origin.x;
    int offsetY = -(int)primaryBounds.origin.y;

    if (offsetX == 0 && offsetY == 0 && CGMainDisplayID() == primaryDisplayId) {
        return 0;
    }

    uint32_t displayCnt = 0;
    CGError displayListErr = CGGetOnlineDisplayList(0, NULL, &displayCnt);
    if (displayListErr != kCGErrorSuccess || displayCnt == 0) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=noDisplay err=%d cnt=%u", displayListErr, displayCnt);
        return 1;
    }

    CGDirectDisplayID* displayIds = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * displayCnt);
    if (displayIds == NULL) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=mallocDisplayIds cnt=%u", displayCnt);
        return 1;
    }

    displayListErr = CGGetOnlineDisplayList(displayCnt, displayIds, NULL);
    if (displayListErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=getDisplayList err=%d cnt=%u", displayListErr, displayCnt);
        free(displayIds);
        return 1;
    }

    CGDisplayConfigRef cfg = NULL;
    CGError beginErr = CGBeginDisplayConfiguration(&cfg);
    if (beginErr != kCGErrorSuccess || cfg == NULL) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=beginConfiguration err=%d cfg=%p", beginErr, cfg);
        free(displayIds);
        return 1;
    }

    bool configured = true;
    for (uint32_t i = 0; i < displayCnt; i++) {
        CGRect bounds = CGDisplayBounds(displayIds[i]);
        int x = (int)bounds.origin.x + offsetX;
        int y = (int)bounds.origin.y + offsetY;

        CGError configureErr = CGConfigureDisplayOrigin(cfg, displayIds[i], x, y);
        if (configureErr != kCGErrorSuccess) {
            NSLog(@"[VirtualMonitor::SetPrimaryDisplay] configure failed id=%u err=%d", displayIds[i], configureErr);
            configured = false;
            break;
        }
    }

    if (configured == false) {
        CGCancelDisplayConfiguration(cfg);
        free(displayIds);
        return 1;
    }

    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    free(displayIds);

    if (completeErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=complete err=%d", completeErr);
        return 1;
    }

    NSLog(@"[VirtualMonitor::SetPrimaryDisplay] success primary=%u", primaryDisplayId);
    return 0;
}

int VirtualMonitor::ApplyDisplayLayout() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || primaryIndex >= _virtualDisplayInfoCnt) {
        return 1;
    }

    struct VIRTUALMONITOR_INFO* primaryInfo = &_virtualDisplayInfo[primaryIndex];
    if (primaryInfo->virtualDisplay == nil) {
        return 1;
    }

    CGDisplayConfigRef cfg = NULL;
    CGError beginErr = CGBeginDisplayConfiguration(&cfg);
    if (beginErr != kCGErrorSuccess || cfg == NULL) {
        NSLog(@"[VirtualMonitor::ApplyDisplayLayout] failed reason=beginConfiguration err=%d cfg=%p", beginErr, cfg);
        return 1;
    }

    bool configured = true;
    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[i];
        if (displayInfo->virtualDisplay == nil) {
            configured = false;
            break;
        }

        int x = displayInfo->left - primaryInfo->left;
        int y = displayInfo->top - primaryInfo->top;

        CGError configureErr = CGConfigureDisplayOrigin(cfg, displayInfo->virtualDisplay.displayID, x, y);
        if (configureErr != kCGErrorSuccess) {
            NSLog(@"[VirtualMonitor::ApplyDisplayLayout] configure failed index=%d id=%u x=%d y=%d err=%d",
                  i, displayInfo->virtualDisplay.displayID, x, y, configureErr);
            configured = false;
            break;
        }
    }

    if (configured == false) {
        CGCancelDisplayConfiguration(cfg);
        return 1;
    }

    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    if (completeErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonitor::ApplyDisplayLayout] failed reason=complete err=%d", completeErr);
        return 1;
    }

    NSLog(@"[VirtualMonitor::ApplyDisplayLayout] success primaryIndex=%d primary=%u", primaryIndex, primaryInfo->virtualDisplay.displayID);
    return 0;
}

void* VirtualMonitor::WatchThreadProc(void* args) {
    
    if (args == NULL) return NULL;
    VirtualMonitor* _this = (VirtualMonitor*)args;
    
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    
    pthread_mutex_lock(&_this->_watchLock);
    
    for(;;) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 3;
        
        pthread_cond_timedwait(&_this->_watchWake, &_this->_watchLock, &ts);
        
        if (_this->_watchRunning == false) break;
        
        _this->WatchThreadPorcInternal();
    }
    
    pthread_mutex_unlock(&_this->_watchLock);
    
    return NULL;
}

void VirtualMonitor::WatchThreadPorcInternal() {
    // 아직 가상 모니터가 완전히 활성화 되어있는지 확인하지 못한 상황
    if (_init == false) {
        // 모든 가상 모니터가 완전히 사용 가능한지 확인
        if (IsAllVirtualDisplayOnline() == false) {
            NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display does not online yet");
            return;
        }
        
        NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display has been online now");
        _init = true;
    }
    
    // 가상 모니터를 제외한 다른 모니터는 가상 모니터를 미러링 (새로 연결된 모니터 포함)
    MirrorOtherMonitors();
    LocalCurtain::Refresh();
    
    // 해상도 정보 확인 (가상 모니터)
    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        if (IsRightResolution(i) == false) {
            // 해상도가 틀어진 경우 (혹은 아직 설정되지 않은 경우) --> 해상도 설정
            NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display has invalid resolution. try change it index=%d", i);
            SetResolution(i);
        }
    }

    // 다른 display 추가/삭제 과정에서 display 배치나 primary 가 풀리는 경우 원복
    if (IsRightDisplayLayout() == false) {
        NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display has invalid layout. try change it");
        ApplyDisplayLayout();
    }
}

int VirtualMonitor::CalcScale(int width, int height) {
    return ((width > 3440) || (width > 2300 && height > 1500)) == true ? 2 : 1;
}

CGVirtualDisplaySettings* VirtualMonitor::CreateDisplaySettings(int width, int height, int scale, int refreshRate) {
    CGVirtualDisplaySettings* settings = [[CGVirtualDisplaySettings alloc] init];
    if (settings == nil)
        return nil;

    settings.hiDPI = scale == 2 ? 1 : 0;

    NSMutableArray* modes = [NSMutableArray array];

    // 세로 해상도 (회전) 인 경우 기본 모드도 세로로 구성
    bool portrait = height > width;

    for (int i = 0; i < (int)(sizeof(baseModes) / sizeof(baseModes[0])); i++) {
        int baseWidth = portrait ? baseModes[i][1] : baseModes[i][0];
        int baseHeight = portrait ? baseModes[i][0] : baseModes[i][1];

        // 원격 클라이언트 해상도와 중복되는 모드는 skip
        if (baseWidth == width && baseHeight == height)
            continue;

        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:baseWidth height:baseHeight refreshRate:refreshRate]];
    }

    [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:refreshRate]];

    if (scale == 2) {
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:width / 2 height:height / 2 refreshRate:refreshRate]];
    }

    settings.modes = modes;

    return settings;
}

// EDID 의 픽셀 클럭 필드는 10kHz 단위 16비트라 macOS 는 655.35MHz 를 넘는 타이밍을 담지 못하는것으로 보인다. (추측, 여러 테스트를 기반)
// 따라서 655.35 를 넘는 경우 주사율을 낮추는 식으로 우회한다.
int VirtualMonitor::CalcRefreshRate(int width, int height) {
    if (width <= 0 || height <= 0) return 45;
    
    int refreshRate = (int)(655350000.0 / ((double)width * (double)height * 1.35));

    if (refreshRate > 60) refreshRate = 60;
    else if (refreshRate < 1) refreshRate = 45;
    
    // hw 가속 인코딩이 아직 지원되지 않으므로 주사율을 좀 낮추어 cpu 점유율을 감소 (temp)
    if (width >= 3000 && height >= 2000) {
        if (refreshRate > 45) {
            refreshRate = 45;
        }
    }

    return refreshRate;
}
