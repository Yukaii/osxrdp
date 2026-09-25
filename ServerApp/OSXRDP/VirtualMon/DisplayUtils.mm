#include "DisplayUtils.h"
#include "CGVirtualDisplayPrivate.h"

#include <sys/time.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>

static const int kPollIntervalMs = 50;

// VirtualMonitor::Create 에서 사용하는 vendor/product id
static const uint32_t kVirtualDisplayVendorId = 0x1207;
static const uint32_t kVirtualDisplayProductIdBase = 0x5969;

static uint64_t GetNowMs() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return ((uint64_t)tv.tv_sec * 1000ULL) + ((uint64_t)tv.tv_usec / 1000ULL);
}

bool DisplayUtils::IsOsxrdpVirtualDisplay(CGDirectDisplayID displayId) {
    uint32_t productId = CGDisplayModelNumber(displayId);
    return CGDisplayVendorNumber(displayId) == kVirtualDisplayVendorId &&
           productId >= kVirtualDisplayProductIdBase && productId < kVirtualDisplayProductIdBase + 16;
}

bool DisplayUtils::IsDisplayOnline(CGDirectDisplayID displayId) {
    if (displayId == 0) {
        return false;
    }

    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        return false;
    }

    CGDirectDisplayID* ids = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * count);
    if (ids == NULL) {
        return false;
    }

    bool found = false;
    if (CGGetOnlineDisplayList(count, ids, NULL) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            if (ids[i] == displayId) {
                found = true;
                break;
            }
        }
    }

    free(ids);
    return found;
}

bool DisplayUtils::HasOtherOnlineDisplay(CGDirectDisplayID displayId) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        return false;
    }

    CGDirectDisplayID* ids = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * count);
    if (ids == NULL) {
        return false;
    }

    bool found = false;
    if (CGGetOnlineDisplayList(count, ids, NULL) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            if (ids[i] != displayId) {
                found = true;
                break;
            }
        }
    }

    free(ids);
    return found;
}

bool DisplayUtils::WaitDisplayOnlineState(CGDirectDisplayID displayId, bool shouldBeOnline, int timeoutMs) {
    uint64_t startMs = GetNowMs();
    while (true) {
        bool online = IsDisplayOnline(displayId);
        if (online == shouldBeOnline) {
            return true;
        }

        uint64_t nowMs = GetNowMs();
        int elapsedMs = (int)(nowMs - startMs);
        if (elapsedMs >= timeoutMs) {
            return false;
        }
        usleep(kPollIntervalMs * 1000);
    }
}
