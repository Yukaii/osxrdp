#include "VirtualMonitor.h"
#include "DisplayUtils.h"

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <crt_externs.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

static const int kRestoreAwakeVerifyMs = 5000;
static const int kHelperProcessTimeoutMs = 5000;
static const int kPanelSelfRestoreWaitMs = 4000;

static const int kVirtualDisplayVendorId = 0x1207;
static const int kVirtualDisplayProductIdBase = 0x5969;

// Restore state must survive ScreenRecorderManager/VirtualMonitor teardown.
// A failed WindowServer reconfiguration otherwise loses the physical display ID.
// Every client owns its own VirtualMonitor, so guard the shared list.
static uint32_t* gDisabledDisplayIds = NULL;
static int gDisabledDisplayIdsCnt = 0;
static pthread_mutex_t gDisabledDisplayLock = PTHREAD_MUTEX_INITIALIZER;

static int RunProcess(char* const* argv, int timeoutMs);
static bool EnableDisplaysInHelperProcess(uint32_t* displayIds, int displayCnt);

static bool HasPendingRestore() {
    pthread_mutex_lock(&gDisabledDisplayLock);
    bool pending = gDisabledDisplayIdsCnt > 0;
    pthread_mutex_unlock(&gDisabledDisplayLock);
    return pending;
}

// Virtual displays created by any VirtualMonitor instance (see Create).
// During a client handoff two instances coexist, and one must not disable
// (and later try to "restore") the other's virtual display.
static bool IsOsxrdpVirtualDisplay(CGDirectDisplayID displayId) {
    uint32_t productId = CGDisplayModelNumber(displayId);
    return CGDisplayVendorNumber(displayId) == kVirtualDisplayVendorId &&
           productId >= kVirtualDisplayProductIdBase && productId < kVirtualDisplayProductIdBase + 16;
}

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
    _displaySleepAssertion(kIOPMNullAssertionID)
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

    if ([displayInfo->virtualDisplay applySettings:settings] == NO) {
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

    pthread_mutex_unlock(&_watchLock);

    NSLog(@"[VirtualMonitor::Resize] index=%d %dx%d@%dHz scale=%d", index, width, height, refreshRate, scale);
    return true;
}

void VirtualMonitor::Destroy() {
    // 가상 모미터 watch 스레드 정지
    if (_watchRunning == true) {
        _watchRunning = false;
        pthread_cond_signal(&_watchWake);
        pthread_join(_watchThread, NULL); // 완전히 정지할때까지 대기
    }

    CGDirectDisplayID virtualIds[16] = {0};
    int virtualCnt = _virtualDisplayInfoCnt;
    for (int i = 0; i < virtualCnt; i++) {
        virtualIds[i] = _virtualDisplayInfo[i].virtualDisplay.displayID;
        // nil 로 설정하면 알아서 뽀개짐 (즉시 뽀개지는건 아님)
        _virtualDisplayInfo[i].virtualDisplay = nil;
    }

    _virtualDisplayInfoCnt = 0;
    memset(&_virtualDisplayInfo, 0x00, sizeof(_virtualDisplayInfo));

    _init = false;
    ReleaseDisplaySleepAssertion();

    if (HasPendingRestore() == false) {
        return;
    }

    // Enable the physical panel only after the virtual displays are gone.
    // Enabling it while a virtual display is still active can leave the
    // built-in panel toggling between hotplug "in" and "out", which blocks the
    // WindowServer main thread in the display driver until the watchdog kills it.
    for (int i = 0; i < virtualCnt; i++) {
        DisplayUtils::WaitDisplayOnlineState(virtualIds[i], false, 5000);
    }

    // After the last virtual display is removed and the display wakes, macOS
    // normally brings the panel back by itself once it reports "in" again.
    WakeupDisplay();
    if (WaitPendingDisplaysOnline(kPanelSelfRestoreWaitMs)) {
        return;
    }

    // Otherwise ask once from a fresh process (see EnableDisplaysInHelperProcess).
    // Do not retry here: a failed restore stays pending for the next teardown.
    RestoreOtherMonitors(kRestoreAwakeVerifyMs);
    if (HasPendingRestore()) {
        NSLog(@"[VirtualMonitor::Destroy] physical display still disabled");
    }
}

// Waits for disabled displays to come back without reconfiguring them and
// drops the restored ones from the pending list. Returns true if none remain.
bool VirtualMonitor::WaitPendingDisplaysOnline(int timeoutMs) {
    pthread_mutex_lock(&gDisabledDisplayLock);

    int pendingCnt = 0;
    for (int i = 0; i < gDisabledDisplayIdsCnt; i++) {
        if (!DisplayUtils::WaitDisplayOnlineState(gDisabledDisplayIds[i], true, timeoutMs)) {
            gDisabledDisplayIds[pendingCnt++] = gDisabledDisplayIds[i];
        }
    }
    gDisabledDisplayIdsCnt = pendingCnt;

    if (pendingCnt == 0) {
        free(gDisabledDisplayIds);
        gDisabledDisplayIds = NULL;
    }

    pthread_mutex_unlock(&gDisabledDisplayLock);
    return pendingCnt == 0;
}

void VirtualMonitor::RestoreOtherMonitors(int verifyTimeoutMs) {
    pthread_mutex_lock(&gDisabledDisplayLock);

    if (gDisabledDisplayIdsCnt == 0 || gDisabledDisplayIds == NULL) {
        pthread_mutex_unlock(&gDisabledDisplayLock);
        return;
    }
    
    bool applied = EnableDisplaysInHelperProcess(gDisabledDisplayIds, gDisabledDisplayIdsCnt);
    
    // Keep only the displays that did not come back, so a later retry does not
    // reconfigure displays that are already restored.
    int pendingCnt = 0;
    for (int i = 0; i < gDisabledDisplayIdsCnt; i++) {
        if (!DisplayUtils::WaitDisplayOnlineState(gDisabledDisplayIds[i], true, verifyTimeoutMs)) {
            gDisabledDisplayIds[pendingCnt++] = gDisabledDisplayIds[i];
        }
    }
    gDisabledDisplayIdsCnt = pendingCnt;
    
    if (pendingCnt == 0) {
        free(gDisabledDisplayIds);
        gDisabledDisplayIds = NULL;
    } else {
        NSLog(@"[VirtualMonitor::RestoreOtherMonitors] restore incomplete; applied=%d pending=%d",
              applied, pendingCnt);
    }

    pthread_mutex_unlock(&gDisabledDisplayLock);
}

// Returns the exit status, or -1 if the process could not run to completion.
static int RunProcess(char* const* argv, int timeoutMs) {
    // Do not leak the agent's IPC sockets into the child.
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);

    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, argv[0], NULL, &attr, argv, *_NSGetEnviron());
    posix_spawnattr_destroy(&attr);

    if (spawnErr != 0) {
        NSLog(@"[VirtualMonitor::RunProcess] posix_spawn failed path=%s err=%d", argv[0], spawnErr);
        return -1;
    }

    int status = 0;
    for (int waitedMs = 0; waitpid(pid, &status, WNOHANG) == 0; waitedMs += 50) {
        if (waitedMs >= timeoutMs) {
            NSLog(@"[VirtualMonitor::RunProcess] timed out path=%s pid=%d", argv[0], pid);
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            return -1;
        }
        usleep(50 * 1000);
    }

    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// Enable requests made from this long-running process can be dropped by
// SkyLight without reaching WindowServer, while the same request from a fresh
// process is delivered. Run this executable in its --enable-displays helper
// mode (see main.m).
static bool EnableDisplaysInHelperProcess(uint32_t* displayIds, int displayCnt) {
    NSString* executablePath = [[NSBundle mainBundle] executablePath];
    if (executablePath == nil || displayCnt <= 0 || displayCnt > 16) {
        return DisplayUtils::ApplyDisplayEnabled(displayIds, displayCnt, true);
    }

    char idArgs[16][16];
    char* argv[16 + 3];
    int argc = 0;
    argv[argc++] = (char*)[executablePath fileSystemRepresentation];
    argv[argc++] = (char*)"--enable-displays";
    for (int i = 0; i < displayCnt; i++) {
        snprintf(idArgs[i], sizeof(idArgs[i]), "%u", displayIds[i]);
        argv[argc++] = idArgs[i];
    }
    argv[argc] = NULL;

    int exitStatus = RunProcess(argv, kHelperProcessTimeoutMs);
    if (exitStatus == -1) {
        return DisplayUtils::ApplyDisplayEnabled(displayIds, displayCnt, true);
    }

    return exitStatus == 0;
}

void VirtualMonitor::StartMonitor() {
    HoldDisplaySleepAssertion();
    WakeupDisplay();

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

// todo: DisplayUtils::ApplyDisplayEnabled 에 중복 로직이 있음
bool VirtualMonitor::DisableOtherMonitors() {
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors begin virtualDisplayCnt=%d disabledCnt=%d]", _virtualDisplayInfoCnt, gDisabledDisplayIdsCnt);
    
    // 가상 디스플레이가 없으면 무시
    if (_virtualDisplayInfoCnt <= 0) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=noVirtualDisplay]");
        return false;
    }
    
    // 디스플레이 갯수를 조회
    uint32_t displayCnt = 0;
    CGError displayListErr = CGGetOnlineDisplayList(0, NULL, &displayCnt);
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors onlineCnt=%u err=%d]", displayCnt, displayListErr);
    
    if (displayListErr != kCGErrorSuccess || displayCnt == 0) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=noDisplay err=%d cnt=%u]", displayListErr, displayCnt);
        return false;
    }
    
    // 디스플레이 id 들을 조회
    CGDirectDisplayID* displayIds = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * displayCnt);
    if (displayIds == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=mallocDisplayIds cnt=%u]", displayCnt);
        return false;
    }
    
    displayListErr = CGGetOnlineDisplayList(displayCnt, displayIds, NULL);
    if (displayListErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=getDisplayList err=%d cnt=%u]", displayListErr, displayCnt);
        free(displayIds);
        
        return false;
    }

    bool hasPhysicalOnlineDisplay = false;
    for (uint32_t i = 0; i < displayCnt; i++) {
        if (IsVirtualDisplay(displayIds[i]) == false && IsOsxrdpVirtualDisplay(displayIds[i]) == false) {
            hasPhysicalOnlineDisplay = true;
            break;
        }
    }

    if (hasPhysicalOnlineDisplay == false) {
        free(displayIds);
        return true;
    }
    
    pthread_mutex_lock(&gDisabledDisplayLock);

    uint32_t* newDisabledDisplayIds = (uint32_t*)realloc(gDisabledDisplayIds, sizeof(uint32_t) * (gDisabledDisplayIdsCnt + displayCnt));
    if (newDisabledDisplayIds == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=realloc oldCnt=%d addCnt=%u]", gDisabledDisplayIdsCnt, displayCnt);
        pthread_mutex_unlock(&gDisabledDisplayLock);
        free(displayIds);
        return false;
    }
    
    gDisabledDisplayIds = newDisabledDisplayIds;
    
    CGDisplayConfigRef cfg = NULL;
    CGError beginErr = CGBeginDisplayConfiguration(&cfg);
    if (beginErr != kCGErrorSuccess || cfg == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=beginConfiguration err=%d cfg=%p]", beginErr, cfg);
        pthread_mutex_unlock(&gDisabledDisplayLock);
        free(displayIds);
        
        return false;
    }
    
    int newDisabledDisplayIdsCnt = gDisabledDisplayIdsCnt;
    
    for (uint32_t i = 0; i < displayCnt; i++) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors check id=%u index=%u]", displayIds[i], i);
        
        if (IsVirtualDisplay(displayIds[i]) || IsOsxrdpVirtualDisplay(displayIds[i])) {
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors skip virtual id=%u]", displayIds[i]);
            continue;
        }
        
        // 물리 디스플레이를 끄도록 구성
        CGError configureErr = CGSConfigureDisplayEnabled(cfg, displayIds[i], false);
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors configure id=%u enabled=0 err=%d]", displayIds[i], configureErr);
        
        bool exists = false;
        for (int j = 0; j < gDisabledDisplayIdsCnt; j++) {
            if (gDisabledDisplayIds[j] == displayIds[i]) {
                exists = true;
                break;
            }
        }
        
        if (exists == false) {
            // 나중에 복원할 수 있도록 id 를 저장
            gDisabledDisplayIds[newDisabledDisplayIdsCnt] = displayIds[i];
            newDisabledDisplayIdsCnt++;
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors add disabled id=%u newCnt=%d]", displayIds[i], newDisabledDisplayIdsCnt);
        }
        else {
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors skip duplicate id=%u]", displayIds[i]);
        }
    }
    
    // 설정 저장
    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    if (completeErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=complete err=%d oldCnt=%d newCnt=%d]", completeErr, gDisabledDisplayIdsCnt, newDisabledDisplayIdsCnt);
        pthread_mutex_unlock(&gDisabledDisplayLock);
        free(displayIds);
        return false;
    }
    
    gDisabledDisplayIdsCnt = newDisabledDisplayIdsCnt;
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors success disabledCnt=%d]", gDisabledDisplayIdsCnt);
    
    pthread_mutex_unlock(&gDisabledDisplayLock);
    free(displayIds);

    return true;
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
    
    // 가상 모니터를 제외한 다른 모니터가 온라인인지 확인
    DisableOtherMonitors();
    
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

    for (int i = 0; i < (int)(sizeof(baseModes) / sizeof(baseModes[0])); i++) {
        int baseWidth = baseModes[i][0];
        int baseHeight = baseModes[i][1];

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
