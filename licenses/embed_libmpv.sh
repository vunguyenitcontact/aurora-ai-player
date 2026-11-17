#!/usr/bin/env bash
# Xcode post-build phase: copy the LGPL libmpv set (Tools/build_libmpv_lgpl.sh bundle) into
# Contents/Frameworks, the third-party notices + license texts into Contents/Resources, and
# sign each dylib with the target's identity. Skips with a warning when the set is missing so a
# fresh checkout still builds (MpvLibrary then falls back to a Homebrew libmpv for dev only).
set -euo pipefail
SRC="${SRCROOT:?}/Vendor/mpv-lgpl/Frameworks"
LIC="${SRCROOT}/Vendor/mpv-lgpl/LICENSES"
DST="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

if [ ! -f "$SRC/libmpv.2.dylib" ]; then
  echo "warning: LGPL libmpv not built — run Tools/build_libmpv_lgpl.sh all (app will try Homebrew's libmpv, dev only)"
  exit 0
fi
if ls "$SRC" | grep -q -i -E "x264|x265|rubberband|xvid|cdio|dvdnav|dvdread|aom"; then
  echo "error: GPL library in Vendor/mpv-lgpl/Frameworks — refusing to embed"; exit 1
fi
mkdir -p "$DST" "$RES"
rsync -a --delete --include='*.dylib' --exclude='*' "$SRC/" "$DST/"
cp "${SRCROOT}/Tools/ThirdPartyNotices.txt" "$RES/ThirdPartyNotices.txt"
rm -rf "$RES/LICENSES"; [ -d "$LIC" ] && cp -R "$LIC" "$RES/LICENSES"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  for f in "$DST"/*.dylib; do
    codesign --force --sign "$IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} "$f" 2>&1 | grep -v "replacing existing signature" || true
  done
fi
echo "embedded $(ls "$DST"/*.dylib | wc -l | tr -d ' ') LGPL dylibs"
