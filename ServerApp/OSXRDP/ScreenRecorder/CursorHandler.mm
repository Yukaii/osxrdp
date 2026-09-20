//
//  CursorHandler.mm
//  OSXRDP
//
//  Created by byungho on 2/9/26.
//

#include "CursorHandler.h"

#import <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/time.h>

extern "C" {
    // private functions
    extern int CGSNewConnection(void* unused, int* newConnectionId);
    extern int CGSReleaseConnection(int connectionId);
    extern int CGSGetGlobalCursorDataSize(int connectionId, int* dataSize);
    extern int CGSGetGlobalCursorData(int connection, char *outData, int* ioDataSize, int* outRowBytes, CGRect* outRect, CGPoint* outHotspot, int* outDepth, int* outComponents, int* outBitsPerComponent);
    extern int CGSCurrentCursorSeed(void);
}

#define MAX_RDP_POINTER_SIZE (96)
#define MAX_CURSOR_SRC_BYTES (128 * 128 * 4)

static inline int clamp_int(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

CursorHandler::CursorHandler() :
    _cursorseed(0),
    _tmpbuffer(NULL),
    _connectionId(0),
    _lastCheckTime(0),
    _fallbackImgData(NULL),
    _fallbackWidth(0),
    _fallbackHeight(0),
    _fallbackHotX(0),
    _fallbackHotY(0),
    _fallbackActive(false)
{
    CGSNewConnection(NULL, &_connectionId);
    _tmpbuffer = (char*)malloc(MAX_CURSOR_SRC_BYTES);

    if (BuildFallbackPointer() == false) {
        NSLog(@"[CursorHandler::CursorHandler] BuildFallbackPointer failed.");
    }
}

CursorHandler::~CursorHandler()
{
    CGSReleaseConnection(_connectionId);

    if (_tmpbuffer) {
        free(_tmpbuffer);
        _tmpbuffer = NULL;
    }

    if (_fallbackImgData) {
        free(_fallbackImgData);
        _fallbackImgData = NULL;
    }
}

bool CursorHandler::HandleCursorInfo(cursor_data_t* cursor)
{
    // 커서가 이전과 달라진 경우 커서 업데이트
    int seed = CGSCurrentCursorSeed();
    if (seed == _cursorseed) {
        return false;
    }
    _cursorseed = seed;

    int srcW = 0;
    int srcH = 0;
    int srcRowBytes = 0;
    int srcSizeBytes = 0;
    int hotX = 0;
    int hotY = 0;

    if (QueryCursorImage(&srcW, &srcH, &srcRowBytes, &srcSizeBytes, &hotX, &hotY) == false) {
        // macOS 기본 커서로 그리기
        return ApplyFallbackPointer(cursor);
    }

    _fallbackActive = false;

    StorePointer(cursor, _tmpbuffer, srcRowBytes, srcSizeBytes, srcW, srcH, hotX, hotY);

    return true;
}

bool CursorHandler::QueryCursorImage(int* srcWidth, int* srcHeight, int* srcRowBytes,
                                     int* srcSizeBytes, int* hotX, int* hotY)
{
    if (_tmpbuffer == NULL) {
        return false;
    }

    // 커서 데이터 크기 조회
    int datasize = 0;
    if (CGSGetGlobalCursorDataSize(_connectionId, &datasize) != 0) {
        return false;
    }

    // 크기가 유효한지
    if (datasize <= 0) {
        return false;
    }

    // 움직이는 커서일 경우 처음 프레임만 출력하도록 조치
    if (datasize > MAX_CURSOR_SRC_BYTES) {
        datasize = MAX_CURSOR_SRC_BYTES;
    }

    int outRowBytes = 0;
    CGRect rect;
    CGPoint hotspot;
    int depth = 0;
    int comps = 0;
    int bpc = 0;

    // 커서 데이터 조회
    if (CGSGetGlobalCursorData(_connectionId,
                              _tmpbuffer,
                              &datasize,
                              &outRowBytes,
                              &rect,
                              &hotspot,
                              &depth,
                              &comps,
                              &bpc) != 0) {
        return false;
    }

    int srcW = (int)lround(rect.size.width);
    int srcH = (int)lround(rect.size.height);

    if (srcW <= 0 || srcH <= 0) {
        return false;
    }

    if (srcW > MAX_RDP_POINTER_SIZE) {
        return false;
    }

    // 움직이는 커서면 첫 프레임만 전송
    if (srcH > MAX_RDP_POINTER_SIZE) {
        srcH = CurrentCursorFrameHeight(srcW, srcH);

        if (srcH <= 0 || srcH > MAX_RDP_POINTER_SIZE) {
            return false;
        }
    }

    if (outRowBytes <= 0) {
        return false;
    }

    if (outRowBytes < srcW * 4) {
        return false;
    }

    if (datasize < outRowBytes * srcH) {
        return false;
    }

    *srcWidth = srcW;
    *srcHeight = srcH;
    *srcRowBytes = outRowBytes;
    *srcSizeBytes = datasize;
    *hotX = (int)lround(hotspot.x);
    *hotY = (int)lround(hotspot.y);

    return true;
}

// 특정 커서를 사용할 수 없을때 사용할 macOS 의 기본 화살표 커서를 fallback용으로 만들어둔다ㅣ.
bool CursorHandler::BuildFallbackPointer()
{
    bool result = false;

    @autoreleasepool {
        NSCursor* arrow = [NSCursor arrowCursor];
        if (arrow == nil) {
            return false;
        }

        NSImage* image = [arrow image];
        if (image == nil) {
            return false;
        }

        NSSize ptSize = [image size];
        if (ptSize.width <= 0 || ptSize.height <= 0) {
            return false;
        }

        // 기본 커서가 RDP 최대 크기를 넘으면 비율을 유지한 채 줄인다. (아직까지는 발생한적이 없음)
        double fit = 1.0;
        if (ptSize.width > MAX_RDP_POINTER_SIZE) {
            fit = MAX_RDP_POINTER_SIZE / ptSize.width;
        }
        if (ptSize.height * fit > MAX_RDP_POINTER_SIZE) {
            fit = MAX_RDP_POINTER_SIZE / ptSize.height;
        }

        int pxW = (int)lround(ptSize.width * fit);
        int pxH = (int)lround(ptSize.height * fit);
        if (pxW <= 0 || pxH <= 0) {
            return false;
        }

        NSRect proposed = NSMakeRect(0, 0, ptSize.width, ptSize.height);
        CGImageRef cgImage = [image CGImageForProposedRect:&proposed context:nil hints:nil];
        if (cgImage == NULL) {
            return false;
        }

        char* buffer = (char*)malloc(pxW * pxH * 4);
        if (buffer == NULL) {
            return false;
        }

        memset(buffer, 0x00, pxW * pxH * 4);

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if (colorSpace == NULL) {
            free(buffer);
            return false;
        }

        // CGSGetGlobalCursorData 가 주는 포맷과 동일
        const CGBitmapInfo bitmapInfo = (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
        CGContextRef ctx = CGBitmapContextCreate(buffer, pxW, pxH, 8, pxW * 4, colorSpace, bitmapInfo);
        CGColorSpaceRelease(colorSpace);

        if (ctx == NULL) {
            free(buffer);
            return false;
        }

        CGContextDrawImage(ctx, CGRectMake(0, 0, pxW, pxH), cgImage);
        CGContextRelease(ctx);

        NSPoint hotSpot = [arrow hotSpot];

        if (_fallbackImgData) {
            free(_fallbackImgData);
        }

        _fallbackImgData = buffer;
        _fallbackWidth = pxW;
        _fallbackHeight = pxH;
        _fallbackHotX = clamp_int((int)lround(hotSpot.x * fit), 0, pxW - 1);
        _fallbackHotY = clamp_int((int)lround(hotSpot.y * fit), 0, pxH - 1);

        result = true;
    }

    return result;
}

bool CursorHandler::ApplyFallbackPointer(cursor_data_t* cursor)
{
    if (_fallbackActive == true || _fallbackImgData == NULL) {
        return false;
    }

    StorePointer(cursor,
                 _fallbackImgData,
                 _fallbackWidth * 4,
                 _fallbackWidth * 4 * _fallbackHeight,
                 _fallbackWidth,
                 _fallbackHeight,
                 _fallbackHotX,
                 _fallbackHotY);

    _fallbackActive = true;

    return true;
}

// 커서 데이터를 공유 메모리에 기록
void CursorHandler::StorePointer(cursor_data_t* cursor, const char* src, int srcRowBytes,
                                 int srcSizeBytes, int srcWidth, int srcHeight, int hotX, int hotY)
{
    // macOS 용 ms windows app은 상관없지만, Windows 의 mstsc 는 정사각형 커서 모양만 받는것 같다.
    // 따라서 이를 정사각형 캔버스에 그리기위해 가장 가까운 크기를 조회한다.
    int dstSize = PickSquarePointerSize(srcWidth, srcHeight);

    hotX = clamp_int(hotX, 0, dstSize - 1);
    hotY = clamp_int(hotY, 0, dstSize - 1);

    cursor->width = dstSize;
    cursor->height = dstSize;
    cursor->hotspotX = hotX;
    cursor->hotspotY = hotY;

    // 그리기 (정사각형)
    BuildSquarePointerBGRA(src, srcRowBytes, srcSizeBytes, srcWidth, srcHeight, dstSize, cursor->cursorImgData);

    // 커서 이미지 크기
    cursor->cursorImgDataSize = cursor->width * cursor->height * 4;

    // 커서가 전부 투명하면 AND 마스크를 0xFF 로 채워 "보이지 않는 커서"로 보내고
    // 아니면 0x00으로 채워 클라이언트가 알파 채널을 그대로 쓰게 한다.
    // 특정 클라이언트에서 커서가 지저분하게 보이는 현상을 수정
    bool invisible = IsFullyTransparentBGRA(cursor->cursorImgData, dstSize * dstSize);
    memset(cursor->cursorMaskData, invisible ? 0xFF : 0x00, MAX_CURSOR_IMG_BUFFER_SIZE);

    atomic_store_explicit(&cursor->updated, 1, memory_order_release);
}

int CursorHandler::PickSquarePointerSize(int width, int height)
{
    int m = (width > height) ? width : height;

    if (m <= 32) return 32;
    if (m <= 48) return 48;
    if (m <= 64) return 64;
    return MAX_RDP_POINTER_SIZE;
}

void CursorHandler::BuildSquarePointerBGRA(const char* src, int srcRowBytes, int srcSizeBytes, int srcWidth, int srcHeight, int dstSize, char* dstData)
{
    const int dstRowBytes = dstSize * 4;

    memset(dstData, 0x00, dstRowBytes * dstSize);

    int copyW = srcWidth;
    int copyH = srcHeight;

    if (copyW > dstSize) copyW = dstSize;
    if (copyH > dstSize) copyH = dstSize;

    if (srcRowBytes <= 0) return;
    if (srcSizeBytes < srcRowBytes * srcHeight) return;

    // rdp 의 커서는 상하를 반전해야 한다.
    for (int y = 0; y < copyH; ++y) {
        const uint8_t* srcRow = (const uint8_t*)src + y * srcRowBytes;
        uint8_t* dstRow = (uint8_t*)dstData + (dstSize - 1 - y) * dstRowBytes;
        memcpy(dstRow, srcRow, copyW * 4);
    }
}

bool CursorHandler::IsFullyTransparentBGRA(const char* data, int pixelCount)
{
    const uint8_t* pixels = (const uint8_t*)data;

    for (int i = 0; i < pixelCount; ++i) {
        if (pixels[i * 4 + 3] != 0) {
            return false;
        }
    }

    return true;
}

int CursorHandler::CurrentCursorFrameHeight(int stripWidth, int stripHeight)
{
    int frameWidth = 0;
    int frameHeight = 0;

    @autoreleasepool {
        NSCursor* cursor = [NSCursor currentSystemCursor];
        if (cursor == nil) {
            return 0;
        }

        NSImage* image = [cursor image];
        if (image == nil) {
            return 0;
        }

        NSSize size = [image size];
        frameWidth = (int)lround(size.width);
        frameHeight = (int)lround(size.height);
    }

    // CGS 가 준 커서와 같은 커서인지 폭으로 확인한다.
    if (frameWidth != stripWidth) {
        return 0;
    }

    // 스트립이 프레임 높이의 정수배가 아니면 신뢰할 수 없음
    if (frameHeight <= 0 || frameHeight >= stripHeight || (stripHeight % frameHeight) != 0) {
        return 0;
    }

    return frameHeight;
}
