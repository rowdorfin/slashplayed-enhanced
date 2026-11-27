#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cc=${CC:-gcc}
common=(-std=c11 -Wall -Wextra -Werror -pthread -fno-omit-frame-pointer)
"$cc" "${common[@]}" -O2 -fno-builtin-malloc -fno-builtin-free bench.c ../spalloctrack.c \
  -Wl,--wrap=malloc,--wrap=free -o "$tmp/bench"
"$tmp/bench"
"$cc" "${common[@]}" -g -O1 -no-pie -fsanitize=address,undefined track.c ../spalloctrack.c -o "$tmp/asan"
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0} UBSAN_OPTIONS=halt_on_error=1 "$tmp/asan"
echo 'allocation tracker ASan/UBSan passed'
"$cc" "${common[@]}" -g -O1 -no-pie -fsanitize=thread track.c ../spalloctrack.c -o "$tmp/tsan"
"$tmp/tsan"
echo 'allocation tracker TSan passed'
