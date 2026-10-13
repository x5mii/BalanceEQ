#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cache .build/clang-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --scratch-path "$PWD/.build/tests"
binary_directory=$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" \
    --scratch-path "$PWD/.build/tests" --show-bin-path)
"$binary_directory/EqualizerMac" --self-test
clang -std=c11 -Wall -Wextra -Werror -DEQ_AUDIO_CALLBACK_TEST_MAIN \
    -I Sources/CEQ/include Sources/CEQ/audio_callback.c Sources/CEQ/eq_dsp.c \
    -framework CoreAudio -framework Accelerate -o .build/audio-callback-check
.build/audio-callback-check
plutil -lint Resources/Info.plist
bash -n scripts/install.sh scripts/notarize.sh
python3 scripts/check-installer.py
git diff --check
