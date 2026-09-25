#include "LocalCurtain.h"
#include "DisplayUtils.h"

#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <pthread.h>
#include <unistd.h>

// Acquire/Release 전체를 직렬화 (tap 스레드 시작/정지가 겹치지 않도록)
static pthread_mutex_t gCurtainLifecycleLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gCurtainLock = PTHREAD_MUTEX_INITIALIZER;
static int gCurtainRefCount = 0;

static CFMachPortRef gInputTap = NULL;
static CFRunLoopRef gInputTapRunLoop = NULL;
static pthread_t gInputTapThread;
static bool gInputTapThreadStarted = false;
static bool gCurtainThreadStop = false;

static const uint32_t kMaxDisplays = 32;

static NSString* const kMirrorToLocalDisplayKey = @"MirrorSessionToLocalDisplay";

// 물리 디스플레이 (OSXRDP 가상 모니터가 아닌 모든 디스플레이) 를 검게 표시
static void ApplyBlackoutLocked() {
    CGDirectDisplayID displayIds[kMaxDisplays];
    uint32_t displayCnt = 0;
    if (CGGetOnlineDisplayList(kMaxDisplays, displayIds, &displayCnt) != kCGErrorSuccess) {
        return;
    }

    for (uint32_t i = 0; i < displayCnt; i++) {
        if (DisplayUtils::IsOsxrdpVirtualDisplay(displayIds[i])) {
            continue;
        }

        CGError err = CGSetDisplayTransferByFormula(displayIds[i], 0, 0, 1, 0, 0, 1, 0, 0, 1);
        if (err != kCGErrorSuccess) {
            NSLog(@"[LocalCurtain] could not black out display %u err=%d", displayIds[i], err);
        }
    }
}

static void DisplayReconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void* userInfo) {
    (void)display;
    (void)userInfo;

    if ((flags & kCGDisplayBeginConfigurationFlag) != 0) {
        return;
    }

    LocalCurtain::Refresh();
}

// agent 가 주입한 이벤트만 통과시키고 나머지 (로컬 키보드/마우스/트랙패드) 는 차단
// 원격 입력 대부분은 kCGSessionEventTap 으로 주입되어 이 HID tap 을 거치지 않으며,
// kCGHIDEventTap 으로 주입되는 입력 (CJKHelper) 은 source pid 로 구분
static CGEventRef InputTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* userInfo) {
    (void)proxy;
    (void)userInfo;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        pthread_mutex_lock(&gCurtainLock);
        if (gInputTap != NULL) {
            CGEventTapEnable(gInputTap, true);
        }
        pthread_mutex_unlock(&gCurtainLock);
        return event;
    }

    if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) == getpid()) {
        return event;
    }

    return NULL;
}

// macOS 가 gamma 를 다시 설정하는 경우 (Night Shift, True Tone, 디스플레이 깨어남 등) 가 있으므로 주기적으로 확인
static const CFTimeInterval kBlackoutCheckInterval = 0.25;

static bool IsBlackedOut(CGDirectDisplayID displayId) {
    CGGammaValue red[256];
    CGGammaValue green[256];
    CGGammaValue blue[256];
    uint32_t sampleCnt = 0;

    if (CGGetDisplayTransferByTable(displayId, 256, red, green, blue, &sampleCnt) != kCGErrorSuccess || sampleCnt == 0) {
        return false;
    }

    for (uint32_t i = 0; i < sampleCnt; i++) {
        if (red[i] > 0.001f || green[i] > 0.001f || blue[i] > 0.001f) {
            return false;
        }
    }

    return true;
}

static void BlackoutCheckTimerCallback(CFRunLoopTimerRef timer, void* info) {
    (void)timer;
    (void)info;

    pthread_mutex_lock(&gCurtainLock);

    if (gCurtainRefCount > 0) {
        CGDirectDisplayID displayIds[kMaxDisplays];
        uint32_t displayCnt = 0;
        if (CGGetOnlineDisplayList(kMaxDisplays, displayIds, &displayCnt) == kCGErrorSuccess) {
            for (uint32_t i = 0; i < displayCnt; i++) {
                if (DisplayUtils::IsOsxrdpVirtualDisplay(displayIds[i]) || IsBlackedOut(displayIds[i])) {
                    continue;
                }

                NSLog(@"[LocalCurtain] display %u was restored by the system. black it out again", displayIds[i]);
                CGSetDisplayTransferByFormula(displayIds[i], 0, 0, 1, 0, 0, 1, 0, 0, 1);
            }
        }
    }

    pthread_mutex_unlock(&gCurtainLock);
}

static void* CurtainThreadProc(void* args) {
    dispatch_semaphore_t ready = (__bridge_transfer dispatch_semaphore_t)args;

    pthread_setname_np("osxrdp.localcurtain");

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();

    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                         kCGEventMaskForAllEvents, InputTapCallback, NULL);
    CFRunLoopSourceRef source = NULL;
    if (tap != NULL) {
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
        CFRunLoopAddSource(runLoop, source, kCFRunLoopCommonModes);
    }
    else {
        NSLog(@"[LocalCurtain] could not create input event tap. local input is not blocked");
    }

    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + kBlackoutCheckInterval,
                                                   kBlackoutCheckInterval, 0, 0, BlackoutCheckTimerCallback, NULL);
    if (timer != NULL) {
        CFRunLoopAddTimer(runLoop, timer, kCFRunLoopCommonModes);
    }

    pthread_mutex_lock(&gCurtainLock);
    gInputTap = tap;
    gInputTapRunLoop = (CFRunLoopRef)CFRetain(runLoop);
    pthread_mutex_unlock(&gCurtainLock);

    if (tap != NULL) {
        CGEventTapEnable(tap, true);
    }
    dispatch_semaphore_signal(ready);

    // Stop 이 run loop 진입 전에 호출되어도 멈출 수 있도록 stop 플래그를 주기적으로 확인
    for (;;) {
        pthread_mutex_lock(&gCurtainLock);
        bool stop = gCurtainThreadStop;
        pthread_mutex_unlock(&gCurtainLock);
        if (stop) {
            break;
        }

        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    }

    pthread_mutex_lock(&gCurtainLock);
    gInputTap = NULL;
    pthread_mutex_unlock(&gCurtainLock);

    if (timer != NULL) {
        CFRunLoopTimerInvalidate(timer);
        CFRelease(timer);
    }

    if (tap != NULL) {
        CGEventTapEnable(tap, false);
        CFRunLoopRemoveSource(runLoop, source, kCFRunLoopCommonModes);
        CFRelease(source);
        CFMachPortInvalidate(tap);
        CFRelease(tap);
    }

    return NULL;
}

static void StartInputBlock() {
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);

    pthread_mutex_lock(&gCurtainLock);
    gCurtainThreadStop = false;
    pthread_mutex_unlock(&gCurtainLock);

    // 스레드가 semaphore 를 소유 (대기 시간이 초과되어도 해제된 객체에 signal 하지 않도록)
    void* threadArg = (__bridge_retained void*)ready;
    if (pthread_create(&gInputTapThread, NULL, CurtainThreadProc, threadArg) != 0) {
        CFRelease(threadArg);
        NSLog(@"[LocalCurtain] could not start curtain thread");
        return;
    }
    gInputTapThreadStarted = true;

    // run loop 준비가 끝날때까지 대기 (Stop 이 run loop 를 확실히 멈출 수 있도록)
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

static void StopInputBlock() {
    if (gInputTapThreadStarted == false) {
        return;
    }

    pthread_mutex_lock(&gCurtainLock);
    gCurtainThreadStop = true;
    CFRunLoopRef runLoop = gInputTapRunLoop;
    gInputTapRunLoop = NULL;
    pthread_mutex_unlock(&gCurtainLock);

    if (runLoop != NULL) {
        CFRunLoopStop(runLoop);
        CFRelease(runLoop);
    }

    pthread_join(gInputTapThread, NULL);
    gInputTapThreadStarted = false;
}

void LocalCurtain::Acquire() {
    pthread_mutex_lock(&gCurtainLifecycleLock);

    pthread_mutex_lock(&gCurtainLock);
    gCurtainRefCount++;
    bool first = gCurtainRefCount == 1;
    if (first) {
        ApplyBlackoutLocked();
    }
    pthread_mutex_unlock(&gCurtainLock);

    if (first) {
        CGDisplayRegisterReconfigurationCallback(DisplayReconfigured, NULL);
        StartInputBlock();
        NSLog(@"[LocalCurtain] local display and input are blocked");
    }

    pthread_mutex_unlock(&gCurtainLifecycleLock);
}

void LocalCurtain::Release() {
    pthread_mutex_lock(&gCurtainLifecycleLock);

    pthread_mutex_lock(&gCurtainLock);
    bool last = false;
    if (gCurtainRefCount > 0) {
        gCurtainRefCount--;
        last = gCurtainRefCount == 0;
    }
    pthread_mutex_unlock(&gCurtainLock);

    if (last == false) {
        pthread_mutex_unlock(&gCurtainLifecycleLock);
        return;
    }

    CGDisplayRemoveReconfigurationCallback(DisplayReconfigured, NULL);
    StopInputBlock();

    // 이 앱이 설정한 gamma 를 모두 원래대로 (ColorSync 설정) 복원
    CGDisplayRestoreColorSyncSettings();
    NSLog(@"[LocalCurtain] local display and input are restored");

    pthread_mutex_unlock(&gCurtainLifecycleLock);
}

void LocalCurtain::Refresh() {
    pthread_mutex_lock(&gCurtainLock);
    if (gCurtainRefCount > 0) {
        ApplyBlackoutLocked();
    }
    pthread_mutex_unlock(&gCurtainLock);
}

bool LocalCurtain::IsMirrorToLocalDisplayEnabled() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kMirrorToLocalDisplayKey] == YES;
}

void LocalCurtain::SetMirrorToLocalDisplayEnabled(bool enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled ? YES : NO forKey:kMirrorToLocalDisplayKey];
}
