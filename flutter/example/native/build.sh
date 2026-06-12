#!/bin/bash -e
# Builds the Android arm64-v8a libcactus.so (C FFI exports) for the Flutter app
# and drops it into android/app/src/main/jniLibs/arm64-v8a/.
#
# The expensive part is compiling the Cactus engine from source. To keep local
# iteration fast this is content-addressed: the script hashes every native build
# input (CMakeLists, usearch, and the engine source — committed + local edits)
# and
#   1. skips entirely if the installed .so already matches that hash, or
#   2. restores a prior build of that hash from a machine-level cache
#      (~/.cache/cactus-ffi) — so a fresh checkout / cleaned tree does NOT
#      recompile the engine.
# Only a real change to native sources triggers an actual (incremental) compile.
# Set FORCE=1 to always recompile (e.g. after an NDK upgrade).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
JNI_DIR="$APP_DIR/android/app/src/main/jniLibs/arm64-v8a"
SO="$JNI_DIR/libcactus.so"
STAMP="$JNI_DIR/.libcactus.so.hash"
CACHE_DIR="${CACTUS_FFI_CACHE:-$HOME/.cache/cactus-ffi}"
# Repo root: flutter/example/native -> three levels up.
CACTUS_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ANDROID_PLATFORM=${ANDROID_PLATFORM:-android-21}
ABI="arm64-v8a"

# sha256 of stdin, portable across Linux (sha256sum) and macOS (shasum).
if command -v sha256sum >/dev/null 2>&1; then
    _sha() { sha256sum | awk '{print $1}'; }
else
    _sha() { shasum -a 256 | awk '{print $1}'; }
fi

# A content signature of all native build inputs. Uses git for the (large)
# engine tree — HEAD plus the exact content of any locally-modified/untracked
# files under the build-input paths — so both committed and uncommitted changes
# invalidate the cache. Falls back to hashing file contents when not in git.
compute_hash() {
    {
        echo "$ABI $ANDROID_PLATFORM"
        cat "$SCRIPT_DIR/CMakeLists.txt"
        find "$SCRIPT_DIR/usearch" -type f \
            \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' \
               -o -name '*.h' -o -name '*.hpp' \) -print0 2>/dev/null \
            | sort -z | xargs -0 cat 2>/dev/null
        if git -C "$CACTUS_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "$CACTUS_ROOT" rev-parse HEAD
            git -C "$CACTUS_ROOT" status --porcelain -- cactus cactus-engine \
                    flutter/example/native 2>/dev/null \
                | awk '{print $NF}' | while read -r f; do
                    [ -f "$CACTUS_ROOT/$f" ] && cat "$CACTUS_ROOT/$f"
                done
        else
            find "$CACTUS_ROOT/cactus" "$CACTUS_ROOT/cactus-engine" -type f \
                \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' \
                   -o -name '*.h' -o -name '*.hpp' -o -name 'CMakeLists.txt' \) \
                -print0 2>/dev/null | sort -z | xargs -0 cat 2>/dev/null
        fi
    } | _sha
}

HASH="$(compute_hash)"

# 1. Already installed and current — nothing to do (no NDK required).
if [ "${FORCE:-0}" != "1" ] && [ -f "$SO" ] && [ -f "$STAMP" ] \
        && [ "$(cat "$STAMP" 2>/dev/null)" = "$HASH" ]; then
    echo "libcactus.so up to date (${HASH:0:12}) — skipping native build."
    exit 0
fi

# 2. Built before on this machine — restore from cache (no NDK required).
CACHED="$CACHE_DIR/libcactus-$HASH.so"
if [ "${FORCE:-0}" != "1" ] && [ -f "$CACHED" ]; then
    mkdir -p "$JNI_DIR"
    cp "$CACHED" "$SO"
    echo "$HASH" > "$STAMP"
    echo "Restored libcactus.so from cache (${HASH:0:12})."
    exit 0
fi

# 3. Compile (incremental if $BUILD_DIR is warm). Needs the NDK.
if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -n "$ANDROID_NDK_LATEST_HOME" ]; then
        ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
    elif [ -n "$ANDROID_HOME" ]; then
        ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "Error: Android NDK not found. Set ANDROID_NDK_HOME." >&2
    exit 1
fi

echo "Using NDK: $ANDROID_NDK_HOME"
echo "Building libcactus.so (${HASH:0:12})…"
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
cp "$BUILD_DIR/lib/libcactus.so" "$SO"
echo "$HASH" > "$STAMP"
# Populate the machine-level cache so a future clean checkout reuses this build.
mkdir -p "$CACHE_DIR"
cp "$SO" "$CACHED"
echo "Installed: $SO  (cached as ${HASH:0:12})"
