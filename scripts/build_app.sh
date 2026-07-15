#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SOURCE="${ROOT}/app/HPCTaskMonitorApp.swift"
BACKEND_SOURCE="${ROOT}/app/SlurmBackend.swift"
APP="${ROOT}/HPC Task Monitor.app"
CONTENTS="${APP}/Contents"
MODULE_CACHE="/private/tmp/hpc-task-monitor-swift-module-cache"
BUILD_DIR="/private/tmp/hpc-task-monitor-universal"

mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" "${MODULE_CACHE}" "${BUILD_DIR}"
cp "${ROOT}/app/Info.plist" "${CONTENTS}/Info.plist"
cp "${ROOT}/assets/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"

for ARCH in arm64 x86_64; do
    CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
    SWIFT_MODULECACHE_PATH="${MODULE_CACHE}" \
    xcrun swiftc \
        -target "${ARCH}-apple-macos14.0" \
        -swift-version 5 \
        -parse-as-library \
        -O \
        -framework SwiftUI \
        -framework AppKit \
        "${APP_SOURCE}" \
        "${BACKEND_SOURCE}" \
        -o "${BUILD_DIR}/HPCTaskMonitor-${ARCH}"
done

lipo -create \
    "${BUILD_DIR}/HPCTaskMonitor-arm64" \
    "${BUILD_DIR}/HPCTaskMonitor-x86_64" \
    -output "${CONTENTS}/MacOS/HPCTaskMonitor"

xattr -cr "${APP}"
xattr -c "${APP}"
codesign --force --deep --sign - "${APP}"
echo "Built ${APP}"
