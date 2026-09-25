#!/bin/bash
#
# Build the xrdp / xrdp-keygen binaries bundled in ServerApp/ from upstream xrdp
# plus scripts/xrdp_patch.patch.
#
# The binaries are statically linked against OpenSSL and OpenH264 and built as
# universal (arm64 + x86_64) executables, matching the original configure options:
#   --enable-openh264 --enable-static --disable-shared --enable-ipv6
#   --prefix=/usr/local --sysconfdir=/etc --localstatedir=/var
#
# Requirements: Xcode command line tools, autoconf, automake, libtool, pkg-config, nasm
#   brew install autoconf automake libtool pkg-config nasm
#
# Usage:
#   scripts/build_xrdp.sh                 # universal build, copies result into ServerApp/
#   ARCHS=arm64 scripts/build_xrdp.sh     # single arch (faster, for development)
#   INSTALL=0 scripts/build_xrdp.sh       # build only, don't touch ServerApp/
#

set -euo pipefail

XRDP_TAG="v0.10.6.1"
OPENSSL_VERSION="3.6.3"
OPENH264_VERSION="2.6.0"
MACOS_MIN="12.0"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_FILE="$REPO_DIR/scripts/xrdp_patch.patch"
WORK_DIR="${WORK_DIR:-$REPO_DIR/build/xrdp}"
ARCHS="${ARCHS:-arm64 x86_64}"
INSTALL="${INSTALL:-1}"
JOBS="$(sysctl -n hw.ncpu)"

SRC_DIR="$WORK_DIR/src"
DEPS_DIR="$WORK_DIR/deps"
OUT_DIR="$WORK_DIR/out"

mkdir -p "$SRC_DIR" "$DEPS_DIR" "$OUT_DIR"

# CommandLineTools SDK 가 링커와 맞지 않는 환경이 있으므로 가능하면 Xcode toolchain 을 사용
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun -f clang)"
export CXX="$(xcrun -f clang++)"
TOOLCHAIN_CC="$CC"
TOOLCHAIN_CXX="$CXX"

log() {
    echo "=== $*"
}

host_triple() {
    case "$1" in
        arm64) echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin" ;;
        *) echo "unsupported arch $1" >&2; exit 1 ;;
    esac
}

# ------------------------------------------------------------------
# sources
# ------------------------------------------------------------------
fetch_sources() {
    if [ ! -d "$SRC_DIR/openssl-$OPENSSL_VERSION" ]; then
        log "Downloading OpenSSL $OPENSSL_VERSION"
        curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
            | tar -xz -C "$SRC_DIR"
    fi

    if [ ! -d "$SRC_DIR/openh264-$OPENH264_VERSION" ]; then
        log "Downloading OpenH264 $OPENH264_VERSION"
        curl -fsSL "https://github.com/cisco/openh264/archive/refs/tags/v$OPENH264_VERSION.tar.gz" \
            | tar -xz -C "$SRC_DIR"
    fi

    if [ ! -d "$SRC_DIR/xrdp" ]; then
        log "Cloning xrdp $XRDP_TAG"
        git clone --quiet --branch "$XRDP_TAG" --recursive https://github.com/neutrinolabs/xrdp.git "$SRC_DIR/xrdp"
    fi
}

# ------------------------------------------------------------------
# dependencies (per arch, static)
# ------------------------------------------------------------------
build_openssl() {
    local arch="$1"
    local prefix="$DEPS_DIR/$arch"

    if [ -f "$prefix/lib/libssl.a" ]; then
        return
    fi

    log "Building OpenSSL ($arch)"
    local build="$WORK_DIR/build-openssl-$arch"
    rm -rf "$build"
    cp -R "$SRC_DIR/openssl-$OPENSSL_VERSION" "$build"

    (
        cd "$build"
        # openssldir 는 기존 바이너리와 동일하게 /usr/local/ssl 사용
        ./Configure "darwin64-$arch-cc" no-shared no-tests no-docs \
            --prefix="$prefix" --openssldir=/usr/local/ssl --libdir=lib \
            "-mmacosx-version-min=$MACOS_MIN"
        make -j"$JOBS" >/dev/null
        make install_sw >/dev/null
    )
}

build_openh264() {
    local arch="$1"
    local prefix="$DEPS_DIR/$arch"

    if [ -f "$prefix/lib/libopenh264.a" ]; then
        return
    fi

    log "Building OpenH264 ($arch)"
    local build="$WORK_DIR/build-openh264-$arch"
    rm -rf "$build"
    cp -R "$SRC_DIR/openh264-$OPENH264_VERSION" "$build"

    (
        cd "$build"
        make -j"$JOBS" OS=darwin ARCH="$arch" PREFIX="$prefix" \
            CC="$TOOLCHAIN_CC" CXX="$TOOLCHAIN_CXX" \
            CFLAGS_OPT="-O3 -mmacosx-version-min=$MACOS_MIN" \
            LDFLAGS="-mmacosx-version-min=$MACOS_MIN" \
            install-static >/dev/null
    )
}

# ------------------------------------------------------------------
# xrdp (per arch)
# ------------------------------------------------------------------
prepare_xrdp_source() {
    local tree="$WORK_DIR/xrdp-patched"

    log "Preparing patched xrdp source"
    rm -rf "$tree"
    cp -Rp "$SRC_DIR/xrdp" "$tree"

    (
        cd "$tree"
        git apply "$PATCH_FILE"
        ./bootstrap >/dev/null
    )
}

build_xrdp() {
    local arch="$1"
    local prefix="$DEPS_DIR/$arch"
    local build="$WORK_DIR/build-xrdp-$arch"

    log "Building xrdp ($arch)"
    rm -rf "$build"
    # 시간 정보를 유지해야 make 가 automake/configure 를 (병렬로) 다시 실행하지 않음
    cp -Rp "$WORK_DIR/xrdp-patched" "$build"

    (
        cd "$build"
        # xrdp 와 keygen 은 X11 을 사용하지 않지만 configure 가 항상 X11 을 찾으므로
        # 빈 경로(/var/empty)를 지정하고 X11 extension header 검사는 건너뛴다.
        ./configure \
            --host="$(host_triple "$arch")" \
            --prefix=/usr/local --sysconfdir=/etc --localstatedir=/var \
            --enable-openh264 --enable-static --disable-shared --enable-ipv6 \
            --x-includes=/var/empty --x-libraries=/var/empty \
            ac_cv_header_X11_extensions_Xfixes_h=yes \
            ac_cv_header_X11_extensions_Xrandr_h=yes \
            CC="$TOOLCHAIN_CC -arch $arch" \
            CXX="$TOOLCHAIN_CXX -arch $arch" \
            CFLAGS="-O2 -mmacosx-version-min=$MACOS_MIN" \
            LDFLAGS="-mmacosx-version-min=$MACOS_MIN" \
            OPENSSL_CFLAGS="-I$prefix/include" \
            OPENSSL_LIBS="-L$prefix/lib -lssl -lcrypto" \
            XRDP_OPENH264_CFLAGS="-I$prefix/include" \
            XRDP_OPENH264_LIBS="-L$prefix/lib -lopenh264 -lc++ -lc++abi" \
            >/dev/null

        # xrdp 와 xrdp-keygen 만 필요
        for dir in third_party/tomlc99 common libipm libpainter librfxcodec libxrdp xrdp keygen; do
            if [ -f "$dir/Makefile" ]; then
                make -j"$JOBS" -C "$dir" >/dev/null
            fi
        done
    )

    mkdir -p "$OUT_DIR/$arch"
    cp "$build/xrdp/xrdp" "$OUT_DIR/$arch/xrdp"
    cp "$build/keygen/xrdp-keygen" "$OUT_DIR/$arch/xrdp-keygen"
}

# ------------------------------------------------------------------
# main
# ------------------------------------------------------------------
fetch_sources

for arch in $ARCHS; do
    build_openssl "$arch"
    build_openh264 "$arch"
done

prepare_xrdp_source

for arch in $ARCHS; do
    build_xrdp "$arch"
done

log "Creating binaries ($ARCHS)"
for bin in xrdp xrdp-keygen; do
    inputs=()
    for arch in $ARCHS; do
        inputs+=("$OUT_DIR/$arch/$bin")
    done
    lipo -create "${inputs[@]}" -output "$OUT_DIR/$bin"
    lipo -archs "$OUT_DIR/$bin"
done

"$OUT_DIR/xrdp" --version | head -1

if [ "$INSTALL" = "1" ]; then
    log "Installing into ServerApp/"
    cp "$OUT_DIR/xrdp" "$REPO_DIR/ServerApp/xrdp"
    cp "$OUT_DIR/xrdp-keygen" "$REPO_DIR/ServerApp/xrdp-keygen"
fi

log "Done: $OUT_DIR"
