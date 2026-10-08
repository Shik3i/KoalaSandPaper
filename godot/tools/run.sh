#!/bin/sh
# Usage: tools/run.sh <scene> [user args...]  — refreshes the class cache, runs a
# windowed scene (compute needs a window) with a hard frame cap.
cd "$(dirname "$0")/.." || exit 1
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
"$G" --headless --path . --import >/dev/null 2>&1 || "$G" --headless --path . --import >/dev/null 2>&1
SCENE=$1; shift
"$G" --path . --resolution ${RES:-1920x1080} --quit-after ${QUIT_AFTER:-20000} "$SCENE" -- "$@" 2>&1 \
	| grep -E '^\{|ERROR|SCRIPT' | grep -v -E 'Pipeline cache|ObjectDB' | awk '!seen[$0]++' | head -40
