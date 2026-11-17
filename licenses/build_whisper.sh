#!/bin/bash
# Builds whisper.cpp as static libraries into Vendor/whisper/ (gitignored).
# Run once before building Aurora (the app hard-links these libs).
# whisper.cpp dropped Swift Package support — static libs via CMake is the supported path.
set -euo pipefail

TAG="v1.9.1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.build/whisper.cpp-$TAG"
OUT="$ROOT/Vendor/whisper"

if [[ -f "$OUT/.tag" && "$(cat "$OUT/.tag")" == "$TAG" && -f "$OUT/lib/libwhisper.a" ]]; then
    echo "whisper $TAG already built at $OUT — nothing to do."
    exit 0
fi

if [[ ! -d "$SRC" ]]; then
    git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
fi

# Static, Metal with the shader embedded in the lib (no separate .metallib resource),
# matching the app's deployment target. arm64 only — the app currently ships arm64
# (bundled Homebrew libmpv is arm64); revisit for a universal build.
cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build "$SRC/build" -j "$(sysctl -n hw.ncpu)"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
find "$SRC/build" -name '*.a' -exec cp {} "$OUT/lib/" \;
cp "$SRC"/include/whisper.h "$OUT/include/"
cp "$SRC"/ggml/include/*.h "$OUT/include/"
echo "$TAG" > "$OUT/.tag"

echo "Built into $OUT:"
ls -lh "$OUT/lib"
