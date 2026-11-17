#!/usr/bin/env bash
# Build an LGPL-clean libmpv for bundling in Aurora (App Store / closed-source safe).
#
# Why: Homebrew's libmpv is GPL (mpv built with GPL parts, FFmpeg with --enable-gpl
# --enable-version3 + x264/x265, librubberband). A paid closed-source app may not ship it.
# This builds FFmpeg without any GPL/version3 parts and mpv with -Dgpl=false, linking only
# permissive/LGPL libraries. Decoding (H.264/HEVC/AV1/VP9/…) is unaffected — x264/x265 are
# *encoders* Aurora never uses; the PCM encoder used for MKV audio extraction is LGPL.
#
# Usage: Tools/build_libmpv_lgpl.sh [ffmpeg|mpv|verify|bundle|all]   (default: all)
# Output: Vendor/mpv-lgpl/prefix (build) and Vendor/mpv-lgpl/Frameworks + LICENSES (what the app
#         embeds via Tools/embed_libmpv.sh on every Xcode build).
# Requires: Xcode CLT, brew install meson ninja nasm pkgconf dylibbundler dav1d libass libplacebo
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SRC=$ROOT/Vendor/src
PREFIX=$ROOT/Vendor/mpv-lgpl/prefix
MIN_OS=${MIN_OS:-14.0}
JOBS=$(sysctl -n hw.ncpu)
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export MACOSX_DEPLOYMENT_TARGET=$MIN_OS
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/libarchive/lib/pkgconfig"

step=${1:-all}

build_ffmpeg() {
  echo "▸ FFmpeg (LGPL): configure…"
  cd "$SRC/ffmpeg"
  ./configure --prefix="$PREFIX" \
    --disable-gpl --disable-nonfree --disable-version3 \
    --enable-shared --disable-static --disable-programs --disable-doc \
    --disable-network --disable-xlib --disable-libxcb --disable-sdl2 --disable-securetransport \
    --disable-avdevice \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-libdav1d \
    --extra-cflags="-mmacosx-version-min=$MIN_OS" \
    --extra-ldflags="-mmacosx-version-min=$MIN_OS" \
    > "$SRC/ffmpeg-configure.log" 2>&1 || { tail -30 "$SRC/ffmpeg-configure.log"; exit 1; }
  grep -E "^License:" "$SRC/ffmpeg-configure.log" || grep -i "license" "$SRC/ffmpeg-configure.log" | head -2
  echo "▸ FFmpeg: build ($JOBS jobs)…"
  make -j"$JOBS" > "$SRC/ffmpeg-build.log" 2>&1 || { tail -30 "$SRC/ffmpeg-build.log"; exit 1; }
  make install > /dev/null
  echo "  ✓ $(ls "$PREFIX"/lib/libavcodec.*.dylib | head -1)"
}

build_mpv() {
  echo "▸ mpv (-Dgpl=false, libmpv only): configure…"
  cd "$SRC/mpv"
  rm -rf build
  meson setup build --prefix="$PREFIX" --buildtype=release --default-library=shared \
    -Dgpl=false -Dlibmpv=true -Dcplayer=false -Dlibavdevice=disabled \
    -Dlua=disabled -Djavascript=disabled -Drubberband=disabled \
    -Dlibbluray=disabled -Dlibarchive=disabled -Djpeg=disabled -Dlcms2=disabled \
    -Dzimg=disabled -Dvulkan=disabled -Dvapoursynth=disabled \
    -Dsdl2-audio=disabled -Dsdl2-video=disabled -Dsdl2-gamepad=disabled \
    -Duchardet=disabled -Dcdda=disabled -Ddvdnav=disabled -Ddvbin=disabled \
    -Dmanpage-build=disabled -Dhtml-build=disabled \
    -Dcoreaudio=enabled \
    > "$SRC/mpv-configure.log" 2>&1 || { tail -40 "$SRC/mpv-configure.log"; exit 1; }
  echo "▸ mpv: build…"
  meson compile -C build > "$SRC/mpv-build.log" 2>&1 || { tail -30 "$SRC/mpv-build.log"; exit 1; }
  meson install -C build > /dev/null
  echo "  ✓ $(ls "$PREFIX"/lib/libmpv.*.dylib | head -1)"
}

verify() {
  echo "▸ Verify: no GPL library in the dependency tree…"
  local lib="$PREFIX/lib/libmpv.2.dylib"
  [ -f "$lib" ] || { echo "  ✗ $lib not built"; exit 1; }
  local seen=() queue=("$lib")
  local all=""
  while [ ${#queue[@]} -gt 0 ]; do
    local f=${queue[0]}; queue=("${queue[@]:1}")
    [[ " ${seen[*]:-} " == *" $f "* ]] && continue
    seen+=("$f")
    for dep in $(otool -L "$f" | awk 'NR>1{print $1}' | grep -E "^(/opt/homebrew|@rpath|$PREFIX)"); do
      local real=$dep
      [[ $dep == @rpath/* ]] && real="$PREFIX/lib/${dep#@rpath/}"
      [ -e "$real" ] && queue+=("$real")
      all+="$(basename "$dep")"$'\n'
    done
  done
  echo "$all" | sort -u | tr '\n' ' '; echo
  if echo "$all" | grep -q -i -E "x264|x265|rubberband|xvid|libvid|cdio|dvdnav|dvdread|aom|openssl|gnutls|libmpv.*homebrew"; then
    echo "  ✗ GPL / incompatible library found"; exit 1
  fi
  echo "  ✓ tree is LGPL/permissive only"
  echo "▸ Verify: min macOS of our dylibs…"
  for f in "$PREFIX"/lib/libmpv.2.dylib "$PREFIX"/lib/libavcodec.*.dylib; do
    printf "  %s minos=%s\n" "$(basename "$f")" "$(vtool -show-build "$f" | awk '/minos/{print $2}')"
  done
}

# Relocatable copy for the app bundle: libmpv + every dependency with @executable_path paths,
# minos retagged to $MIN_OS, plus the license texts. Xcode's post-build script
# (Tools/embed_libmpv.sh) copies this folder into Contents/Frameworks on every build.
bundle() {
  echo "▸ Bundle: Vendor/mpv-lgpl/Frameworks + LICENSES…"
  command -v dylibbundler >/dev/null || { echo "  ✗ brew install dylibbundler"; exit 1; }
  local out="$ROOT/Vendor/mpv-lgpl/Frameworks" lic="$ROOT/Vendor/mpv-lgpl/LICENSES"
  rm -rf "$out" "$lic"; mkdir -p "$out" "$lic"
  local stage; stage=$(mktemp -d)
  cp -L "$PREFIX/lib/libmpv.2.dylib" "$stage/libmpv.2.dylib"; chmod u+w "$stage/libmpv.2.dylib"
  dylibbundler -od -b -x "$stage/libmpv.2.dylib" -s "$PREFIX/lib" \
    -d "$out/" -p @executable_path/../Frameworks/ >/dev/null
  cp "$stage/libmpv.2.dylib" "$out/libmpv.2.dylib"; chmod u+w "$out"/*.dylib
  install_name_tool -id @executable_path/../Frameworks/libmpv.2.dylib "$out/libmpv.2.dylib"
  rm -rf "$stage"
  for f in "$out"/*.dylib; do   # Homebrew deps are stamped with the build host's OS
    vtool -set-build-version macos "$MIN_OS" "$MIN_OS" -replace -output "$f.retag" "$f" >/dev/null 2>&1 && mv "$f.retag" "$f"
    n=$(otool -l "$f" | grep -c "path @executable_path/../Frameworks/ " || true)
    while [ "${n:-0}" -gt 1 ]; do   # dyld aborts on duplicate LC_RPATH
      install_name_tool -delete_rpath '@executable_path/../Frameworks/' "$f" 2>/dev/null || true
      n=$(otool -l "$f" | grep -c "path @executable_path/../Frameworks/ " || true)
    done
  done
  if ls "$out" | grep -q -i -E "x264|x265|rubberband|xvid|cdio|dvdnav|dvdread|aom"; then
    echo "  ✗ GPL library in the bundle set"; ls "$out"; exit 1
  fi
  cp "$SRC/ffmpeg/COPYING.LGPLv2.1" "$lic/FFmpeg-LGPL-2.1.txt"
  cp "$SRC/mpv/LICENSE.LGPL" "$lic/mpv-LGPL-2.1.txt"
  cp "$SRC/ffmpeg/COPYING.LGPLv2.1" "$lic/glib-LGPL-2.1.txt"   # Homebrew's glib keg ships no text
  for pkg in libplacebo libass dav1d freetype harfbuzz fribidi libunibreak libpng graphite2 gettext pcre2 shaderc vulkan-loader little-cms2; do
    for name in LICENSE LICENSE.txt LICENSE.md COPYING COPYING.txt; do
      f="/opt/homebrew/opt/$pkg/$name"; [ -f "$f" ] && { cp "$f" "$lic/$pkg-$name"; break; }
    done
  done
  echo "  ✓ $(ls "$out" | wc -l | tr -d ' ') dylibs, $(ls "$lic" | wc -l | tr -d ' ') license texts"
}

case $step in
  ffmpeg) build_ffmpeg ;;
  mpv) build_mpv ;;
  verify) verify ;;
  bundle) bundle ;;
  all) build_ffmpeg; build_mpv; verify; bundle ;;
  *) echo "usage: $0 [ffmpeg|mpv|verify|bundle|all]"; exit 2 ;;
esac
