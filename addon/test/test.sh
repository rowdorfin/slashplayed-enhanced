#!/bin/sh
# Tests of the addons. SPHover's pixel strip: the addon runs against a mock WoW API, and the shim's
# decoder (shims/appkit/sphoverstrip.h) has to get back the rects the mock UI should produce. SPMovie:
# a tap on a mock MovieFrame has to open its close dialog (spmovie.lua).
# Needs cc and lua ($LUA if set). The addon is written for WoW's Lua 5.1: Homebrew's lua is 5.4, and CI
# (on Linux; nothing here is Mac-only) sets LUA=lua5.1, so both are covered. -lm for decode.c's fabsf,
# which macOS links implicitly and glibc doesn't.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cc -O1 -Wall -o "$OUT/decode" decode.c -lm
# Through a file rather than a pipe: a plain sh pipeline's status is only the decoder's, so a Lua error
# after the frames it did print would pass unseen.
"${LUA:-lua}" mockwow.lua ../SPHover/SPHover.lua 30 > "$OUT/frames.txt"
"$OUT/decode" < "$OUT/frames.txt"
"${LUA:-lua}" spmovie.lua ../SPMovie/SPMovie.lua
"${LUA:-lua}" sptouchbars.lua ../SPTouchBars/SPTouchBars.lua
HUD_JOYSTICK=$(awk '/^static const CGFloat sp_hud_joystick_fraction = / { sub(/;$/, "", $6); print $6 }' ../../shims/appkit/spevent.m)
HUD_JUMP=$(awk '/^static const CGFloat sp_hud_jump_fraction = / { sub(/;$/, "", $6); print $6 }' ../../shims/appkit/spevent.m)
"${LUA:-lua}" sptouchhud.lua ../SPTouchHUD/SPTouchHUD.lua "$HUD_JOYSTICK" "$HUD_JUMP"

# Fallback can only retire files whose exact packaged fingerprint is recorded by the launcher.
awk '/^static .*sp_retire_touch_hud\(/ { recording = 1 } recording { print } recording && /^}/ { exit }' \
    ../../apps/client/spcdn.m > "$OUT/sptouchhud-fingerprints"
for ext in toc lua; do
    name="SPTouchHUD.$ext"
    path="../SPTouchHUD/$name"
    size=$(wc -c < "$path" | tr -d '[:space:]')
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum "$path")
    else
        digest=$(shasum -a 256 "$path")
    fi
    digest=${digest%% *}
    if ! grep -Fq "@\"$name\", $size, @\"$digest\"" "$OUT/sptouchhud-fingerprints"; then
        echo "SPTouchHUD: update sp_retire_touch_hud with $name ($size bytes, SHA-256 $digest)" >&2
        exit 1
    fi
done
echo "SPTouchHUD: cleanup fingerprints match"
