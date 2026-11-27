#!/bin/sh
set -eu
cd "$(dirname "$0")"
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
if [ "${SP_TEST_SANITIZE:-0}" = 1 ]; then
    set -- -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g
else
    set --
fi
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "$@" graphics.c -o "$output/graphics"
"$output/graphics"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "$@" hwprofile.c -o "$output/hwprofile"
"$output/hwprofile"
