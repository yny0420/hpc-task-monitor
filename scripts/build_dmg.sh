#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/HPC Task Monitor.app"
DIST="${ROOT}/dist"
DMG="${DIST}/HPC-Task-Monitor-2.4-universal.dmg"
STAGE="$(mktemp -d /private/tmp/hpc-task-monitor-dmg.XXXXXX)"

zsh "${ROOT}/scripts/build_app.sh"
codesign --verify --deep --strict --verbose=2 "${APP}"

mkdir -p "${DIST}"
ditto "${APP}" "${STAGE}/HPC Task Monitor.app"
cp "${ROOT}/INSTALL.txt" "${STAGE}/INSTALL.txt"
ln -s /Applications "${STAGE}/Applications"
xattr -cr "${STAGE}/HPC Task Monitor.app"
xattr -c "${STAGE}/HPC Task Monitor.app"
codesign --force --deep --sign - "${STAGE}/HPC Task Monitor.app"

hdiutil create \
    -volname "HPC Task Monitor" \
    -srcfolder "${STAGE}" \
    -ov \
    -format UDZO \
    "${DMG}"

xattr -d com.apple.FinderInfo "${APP}" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "${APP}" 2>/dev/null || true
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}"

echo "Built ${DMG}"
