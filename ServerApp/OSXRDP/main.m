#import <Cocoa/Cocoa.h>
#include "duprun.h"
#include "VirtualMon/CGVirtualDisplayPrivate.h"

int g_Lockscreen = 0;

// Helper mode used by VirtualMonitor to re-enable physical displays.
// After a session, enable requests made from the agent process itself can be
// dropped before they reach WindowServer; the same request from a fresh
// process is delivered.
static int EnableDisplays(int argc, const char * argv[]) {
    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess || cfg == NULL) {
        return 1;
    }

    bool configured = false;
    for (int i = 2; i < argc; i++) {
        CGDirectDisplayID displayId = (CGDirectDisplayID)strtoul(argv[i], NULL, 10);
        if (displayId != 0 && CGSConfigureDisplayEnabled(cfg, displayId, true) == kCGErrorSuccess) {
            configured = true;
        }
    }

    if (configured == false) {
        CGCancelDisplayConfiguration(cfg);
        return 1;
    }

    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly) == kCGErrorSuccess ? 0 : 1;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
    }
    
    if (argc > 2 && !strcmp(argv[1], "--enable-displays")) {
        return EnableDisplays(argc, argv);
    }
    
    duprun* dup = NULL;
    
    if (argc > 1 && !strcmp(argv[1], "--lockscreen")) {
        g_Lockscreen = 1;
    }
    else {
        // 중복 실행 확인
        dup = duprun_initialize("com.byungho.osxrdp.agent");
        if (dup == NULL) {
            return 1;
        }
    }
    
    int re = NSApplicationMain(argc, argv);
    
    if (dup != NULL) {
        duprun_release(dup);
        dup = NULL;
    }
    
    return re;
}
