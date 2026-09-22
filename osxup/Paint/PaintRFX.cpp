#include "../pch.h"
#include "PaintRFX.h"
#include "../osxup.h"
#include <sys/mman.h>

static const int RFX_TILE_BYTES = 64 * 64 * 4;
static const int RFX_TILES_PER_COMMAND = 2048;

PaintRFX::PaintRFX() :
    _drawCmd(NULL)
{
    memset(_displays, 0, sizeof(_displays));
}

void PaintRFX::Initialize(const struct mod* mod) {
    Release();

    int monitorCount = mod->client_info.display_sizes.monitorCount;
    if (monitorCount == 0)
        monitorCount = 1;

    if (monitorCount > 16)
        monitorCount = 16;

    for (int i = 0; i < monitorCount; i++) {
        DisplayData* display = &_displays[i];
        int width = mod->width;
        int height = mod->height;
        if (mod->client_info.display_sizes.monitorCount > 0) {
            const struct monitor_info* monitor = &mod->client_info.display_sizes.minfo_wm[i];
            width = monitor->right - monitor->left;
            height = monitor->bottom - monitor->top;

            if (!(monitorCount == 1 && monitor->left == 0 && monitor->right == mod->width))
                width++;
            if (!(monitorCount == 1 && monitor->top == 0 && monitor->bottom == mod->height))
                height++;
        }

        display->width = width & ~1;
        display->height = height & ~1;
        if (display->width > 32767 || display->height > 32767)
            continue;

        // payload는 전체 격자의 주소 공간을 사용한다. 타일 하나는 Y/U/V/A 각 4096바이트이다.
        display->tileCols = (display->width + 63) / 64;
        display->tileRows = (display->height + 63) / 64;
        display->tileTotal = display->tileCols * display->tileRows;
        display->dataSize = (size_t)display->tileTotal * RFX_TILE_BYTES;

        if (display->dataSize > 0x7FFFFFFF)
            continue;

        display->tiles = (TileData*)malloc(display->tileTotal * sizeof(TileData));
        display->selected = (bool*)calloc(display->tileTotal, sizeof(bool));
        display->tileIndices = (int*)malloc(display->tileTotal * sizeof(int));
        if (display->tiles == NULL || display->selected == NULL || display->tileIndices == NULL)
            continue;

        // 디스플레이 정보 (크기 등) 은 원격 세선동안 바뀌지 않으므로 미리 계산
        for (int j = 0; j < display->tileTotal; j++) {
            TileData* tile = &display->tiles[j];
            tile->rect.x = (j % display->tileCols) * 64;
            tile->rect.y = (j / display->tileCols) * 64;
            tile->rect.width = display->width - tile->rect.x < 64 ? display->width - tile->rect.x : 64;
            tile->rect.height = display->height - tile->rect.y < 64 ? display->height - tile->rect.y : 64;
            tile->srcOffset = ((size_t)tile->rect.y * display->width + tile->rect.x) * 3;
            tile->dstOffset = (size_t)j * RFX_TILE_BYTES;
        }

        display->valid = 1;
    }
}

void PaintRFX::Release() {
    xstream_free(_drawCmd);
    _drawCmd = NULL;

    for (int i = 0; i < 16; i++) {
        free(_displays[i].tiles);
        free(_displays[i].selected);
        free(_displays[i].tileIndices);
    }

    memset(_displays, 0, sizeof(_displays));
}

void PaintRFX::DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId, int width, int height) {
    assert(mod != NULL);
    assert(frameInfo != NULL);
    assert(imgData != NULL);

    if (SubmitFrame(mod, frameInfo, imgData, imgDataSize, frame_id, displayId, width, height) == false) {
        return;
    }
}

bool PaintRFX::SubmitFrame(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId, int width, int height) {
    if (displayId < 0 || displayId >= 16) return false;

    DisplayData* display = &_displays[displayId];

    if (display->valid == 0) {
        return false;
    }

    if (display->tiles == NULL || width != display->width || height != display->height ||
        imgDataSize < (size_t)width * height * 3) {
        // 제출에 실패한 프레임의 dirty 영역은 다시 보내지지 않으므로, 다음 프레임을 full redraw 로 돌려 복구한다.
        display->frameSubmitted = false;
        return false;
    }

    screenrecord_frame_t dirtyFrame;
    const int tileCount = SelectTiles(display, frameInfo, &dirtyFrame);

    char* data = (char*)mmap(NULL, display->dataSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (data == MAP_FAILED) {
        display->frameSubmitted = false;
        return false;
    }

    CopyTiles(display, imgData, data, tileCount);
    const int commandSize = WriteCommands(display, &dirtyFrame, tileCount, frame_id, displayId);
    if (commandSize == 0) {
        munmap(data, display->dataSize);
        display->frameSubmitted = false;
        return false;
    }

    // 호출 후에는 성공/실패 모두 XRDP가 mmap 버퍼를 해제하므로 우리쪽에서 절대로 해제하면 안됨!
    if (mod->server_egfx_cmd((struct mod*)mod, (char*)_drawCmd->data_start, commandSize, data, (int)display->dataSize) != 0) {
        display->frameSubmitted = false;
        return false;
    }

    display->frameSubmitted = true;
    return true;
}

int PaintRFX::SelectTiles(DisplayData* display, const screenrecord_frame_t* frameInfo, screenrecord_frame_t* dirtyFrame) {
    const int width = display->width;
    const int height = display->height;

    RECT* dirtys = dirtyFrame->dirtys;
    int& dirtyCount = dirtyFrame->dirtyCount;
    dirtyCount = 0;
 
    if (display->frameSubmitted && frameInfo->dirtyCount > 0 && frameInfo->dirtyCount <= MAX_DIRTY_COUNT) {
        for (int i = 0; i < frameInfo->dirtyCount; i++) {
            const RECT* rect = &frameInfo->dirtys[i];

            int left = rect->x < 0 ? 0 : rect->x;
            int top = rect->y < 0 ? 0 : rect->y;
            int right = rect->x + rect->width;
            int bottom = rect->y + rect->height;

            if (right > width)
                right = width;

            if (bottom > height)
                bottom = height;

            if (right <= left || bottom <= top) continue;

            dirtys[dirtyCount].x = left;
            dirtys[dirtyCount].y = top;
            dirtys[dirtyCount].width = right - left;
            dirtys[dirtyCount].height = bottom - top;

            dirtyCount++;
        }
    }

    // full redraw
    if (dirtyCount == 0) {
        dirtys[0].x = 0;
        dirtys[0].y = 0;
        dirtys[0].width = width;
        dirtys[0].height = height;
        dirtyCount = 1;
    }

    int tileCount = 0;
    for (int i = 0; i < dirtyCount; i++) {
        const RECT* rect = &dirtys[i];
        const int right = (rect->x + rect->width + 63) / 64;
        const int bottom = (rect->y + rect->height + 63) / 64;
        for (int y = rect->y / 64; y < bottom; y++) {
            for (int x = rect->x / 64; x < right; x++) {
                const int index = y * display->tileCols + x;
                if (display->selected[index])
                    continue;
                
                display->selected[index] = true;
                display->tileIndices[tileCount++] = index;
            }
        }
    }

    for (int i = 0; i < tileCount; i++) {
        display->selected[display->tileIndices[i]] = false;
    }
    return tileCount;
}

void PaintRFX::CopyTiles(const DisplayData* display, const char* imgData, char* data, int tileCount) {
    for (int i = 0; i < tileCount; i++) {
        const int index = display->tileIndices[i];
        const TileData* tile = &display->tiles[index];
        CopyRFXTile((const unsigned char*)imgData + tile->srcOffset, display->width * 3, (unsigned char*)data + tile->dstOffset, tile->rect.width, tile->rect.height);
    }
    
}

int PaintRFX::WriteCommands(const DisplayData* display, const screenrecord_frame_t* dirtyFrame, int tileCount, int frame_id, int displayId) {
    const RECT* dirtys = dirtyFrame->dirtys;
    const int dirtyCount = dirtyFrame->dirtyCount;
    const int commandCount = (tileCount + RFX_TILES_PER_COMMAND - 1) / RFX_TILES_PER_COMMAND;
    const int commandSize = 28 + commandCount * (33 + dirtyCount * 8) + tileCount * 8;
    
    if (_drawCmd == NULL || _drawCmd->size < commandSize) {
        xstream_free(_drawCmd);
        _drawCmd = xstream_create(commandSize);
    }

    if (_drawCmd == NULL) {
        return 0;
    }

    xstream_resetPos(_drawCmd);
    xstream_writeInt16(_drawCmd, 0x000B); // STARTFRAME
    xstream_writeInt16(_drawCmd, 0);
    xstream_writeInt32(_drawCmd, 16);
    xstream_writeInt32(_drawCmd, frame_id);
    xstream_writeInt32(_drawCmd, 0); // timestamp

    for (int i = 0; i < tileCount; i += RFX_TILES_PER_COMMAND) {
        const int count = tileCount - i < RFX_TILES_PER_COMMAND ? tileCount - i : RFX_TILES_PER_COMMAND;
        xstream_writeInt16(_drawCmd, 0x0002); // WIRETOSURFACE_2
        xstream_writeInt16(_drawCmd, 0);
        xstream_writeInt32(_drawCmd, 33 + (dirtyCount + count) * 8);
        xstream_writeInt16(_drawCmd, displayId);
        xstream_writeInt16(_drawCmd, 0x0009); // CAPROGRESSIVE
        xstream_writeInt32(_drawCmd, 0); // codec_context_id
        xstream_writeInt8(_drawCmd, 0x20); // XRGB_8888
        xstream_writeInt32(_drawCmd, (unsigned int)displayId << 28);
        WriteRFXRects(_drawCmd, dirtys, dirtyCount);
        xstream_writeInt16(_drawCmd, count);
        
        for (int j = 0; j < count; j++) {
            const RECT* rect = &display->tiles[display->tileIndices[i + j]].rect;
            xstream_writeInt16(_drawCmd, rect->x);
            xstream_writeInt16(_drawCmd, rect->y);
            xstream_writeInt16(_drawCmd, rect->width);
            xstream_writeInt16(_drawCmd, rect->height);
        }
        
        xstream_writeInt32(_drawCmd, 0); // left, top
        xstream_writeInt16(_drawCmd, display->width);
        xstream_writeInt16(_drawCmd, display->height);
    }

    xstream_writeInt16(_drawCmd, 0x000C); // ENDFRAME
    xstream_writeInt16(_drawCmd, 0);
    xstream_writeInt32(_drawCmd, 12);
    xstream_writeInt32(_drawCmd, frame_id);

    return commandSize;
}

void PaintRFX::CopyRFXTile(const unsigned char* src, int stride, unsigned char* dst, int width, int height) {
    for (int y = 0; y < height; y++) {
        const unsigned char* row = src + y * stride;
        for (int x = 0; x < width; x++) {
            dst[y * 64 + x] = row[x * 3 + 1];          // Y
            dst[4096 + y * 64 + x] = row[x * 3 + 2];   // Cb
            dst[8192 + y * 64 + x] = row[x * 3];       // Cr
        }
    }
}

void PaintRFX::WriteRFXRects(xstream_t* stream, const RECT* rects, int count) {
    xstream_writeInt16(stream, count);
    for (int i = 0; i < count; i++) {
        xstream_writeInt16(stream, rects[i].x);
        xstream_writeInt16(stream, rects[i].y);
        xstream_writeInt16(stream, rects[i].width);
        xstream_writeInt16(stream, rects[i].height);
    }
}
