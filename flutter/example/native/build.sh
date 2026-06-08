#!/bin/bash -e
# Builds the Android arm64-v8a libcactus.so (C FFI exports) for the Flutter app
# and drops it into android/app/src/main/jniLibs/arm64-v8a/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
JNI_DIR="$APP_DIR/android/app/src/main/jniLibs/arm64-v8a"

ANDROID_PLATFORM=${ANDROID_PLATFORM:-android-21}
ABI="arm64-v8a"

if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -n "$ANDROID_NDK_LATEST_HOME" ]; then
        ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
    elif [ -n "$ANDROID_HOME" ]; then
        ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "Error: Android NDK not found. Set ANDROID_NDK_HOME."
    exit 1
fi

echo "Using NDK: $ANDROID_NDK_HOME"
TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
n_cpu=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

cmake -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
      -DANDROID_ABI="$ABI" \
      -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
      -DCMAKE_BUILD_TYPE=Release \
      -S "$SCRIPT_DIR" \
      -B "$BUILD_DIR" >/dev/null

cmake --build "$BUILD_DIR" --config Release -j "$n_cpu"

mkdir -p "$JNI_DIR"
cp "$BUILD_DIR/lib/libcactus.so" "$JNI_DIR/libcactus.so"
echo "Installed: $JNI_DIR/libcactus.so"
