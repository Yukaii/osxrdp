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

static const uint32_t kMaxDisplays = 32;

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

static void* InputTapThreadProc(void* args) {
    dispatch_semaphore_t ready = (__bridge dispatch_semaphore_t)args;

    pthread_setname_np("osxrdp.localcurtain.input");

    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                         kCGEventMaskForAllEvents, InputTapCallback, NULL);
    if (tap == NULL) {
        NSLog(@"[LocalCurtain] could not create input event tap. local input is not blocked");
        dispatch_semaphore_signal(ready);
        return NULL;
    }

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(runLoop, source, kCFRunLoopCommonModes);

    pthread_mutex_lock(&gCurtainLock);
    gInputTap = tap;
    gInputTapRunLoop = (CFRunLoopRef)CFRetain(runLoop);
    pthread_mutex_unlock(&gCurtainLock);

    CGEventTapEnable(tap, true);
    dispatch_semaphore_signal(ready);

    CFRunLoopRun();

    pthread_mutex_lock(&gCurtainLock);
    gInputTap = NULL;
    pthread_mutex_unlock(&gCurtainLock);

    CGEventTapEnable(tap, false);
    CFRunLoopRemoveSource(runLoop, source, kCFRunLoopCommonModes);
    CFRelease(source);
    CFMachPortInvalidate(tap);
    CFRelease(tap);

    return NULL;
}

static void StartInputBlock() {
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);

    if (pthread_create(&gInputTapThread, NULL, InputTapThreadProc, (__bridge void*)ready) != 0) {
        NSLog(@"[LocalCurtain] could not start input tap thread");
        return;
    }
    gInputTapThreadStarted = true;

    // tap 생성이 끝날때까지 대기 (Stop 이 run loop 를 확실히 멈출 수 있도록)
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

static void StopInputBlock() {
    if (gInputTapThreadStarted == false) {
        return;
    }

    pthread_mutex_lock(&gCurtainLock);
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
