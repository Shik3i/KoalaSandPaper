#!/bin/sh
# Usage: tools/run.sh <scene> [user args...]  — refreshes the class cache, runs a
# windowed scene (compute needs a window) with a hard frame cap. Always on top:
# macOS throttles occluded Metal windows to a crawl.
cd "$(dirname "$0")/.." || exit 1
# Godot re-imports a compute shader only when the .glsl itself changes (by
# checksum), not its #include files: when any include is newer than the stamp,
# drop the imported shader caches so every .glsl is recompiled.
STAMP=.godot/.glsli_stamp
if [ ! -f "$STAMP" ] || [ -n "$(find sim -name '*.glsli' -newer "$STAMP" 2>/dev/null)" ]; then
	rm -f .godot/imported/*.glsl-*
	mkdir -p .godot && touch "$STAMP"
fi
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
"$G" --headless --path . --import >/dev/null 2>&1 || "$G" --headless --path . --import >/dev/null 2>&1
SCENE=$1; shift
"$G" --path . --always-on-top --disable-vsync --max-fps 0 --resolution ${RES:-1920x1080} --quit-after ${QUIT_AFTER:-20000} "$SCENE" -- "$@" 2>&1 \
	| grep -E '^\{|ERROR|SCRIPT' | grep -v -E 'Pipeline cache|ObjectDB' | awk '!seen[$0]++' | head -40
