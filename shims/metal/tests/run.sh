#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

flags=(-std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -I.)
# Linux PIE can collide with the ASan shadow mapping under high ASLR.
if [[ $(uname -s) == Linux ]]; then flags+=(-no-pie); fi
"${CC:-cc}" "${flags[@]}" spbcdecode.c tests/test_bc_decode.c -o "$out/decode"
"$out/decode"
# The decoder can be staged and tested before adding the layout suite.
if [[ -f tests/test_bc_layout.c ]]; then
  "${CC:-cc}" "${flags[@]}" spbcdecode.c spbclayout.c tests/test_bc_layout.c -o "$out/layout"
  "$out/layout"
fi
