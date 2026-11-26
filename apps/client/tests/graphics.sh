#!/bin/sh
set -eu
cd "$(dirname "$0")"
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror graphics.c -o "$output/graphics"
"$output/graphics"
