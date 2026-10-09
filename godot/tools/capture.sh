#!/bin/sh
# Offline capture with Godot's Movie Maker (decoupled from real time, fixed 60 fps),
# rendered at 3840x2160 via override.cfg, then encoded with ffmpeg.
#
#   tools/capture.sh <seconds> [state]      e.g. tools/capture.sh 30 ../renders/state.bin
#
# Without a state file the machine starts empty; make one with
#   tools/run.sh res://render/main.tscn frames=5400 save_state=../renders/state.bin
cd "$(dirname "$0")/.." || exit 1
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
SECS=${1:-30}
STATE=${2:-}
OUT=../renders
mkdir -p "$OUT"
cat > override.cfg <<CFG
[display]
window/size/viewport_width=3840
window/size/viewport_height=2160
window/stretch/mode="viewport"
[editor]
movie_writer/video_quality=0.95
CFG
FRAMES=$((SECS * 60))
ARGS=""
[ -n "$STATE" ] && ARGS="load_state=$(cd "$(dirname "$STATE")" && pwd)/$(basename "$STATE")"
"$G" --headless --path . --import >/dev/null 2>&1
"$G" --path . --always-on-top --resolution 1920x1080 --write-movie "$OUT/raw.avi" --fixed-fps 60 \
	--quit-after "$FRAMES" res://render/main.tscn -- $ARGS
rm -f override.cfg
ffmpeg -loglevel error -y -i "$OUT/raw.avi" -c:v libx265 -crf 16 -preset slow -pix_fmt yuv420p10le \
	-tag:v hvc1 -an "$OUT/kinetic_study_001_4k.mp4" && rm -f "$OUT/raw.avi" "$OUT/raw.wav"
echo "$OUT/kinetic_study_001_4k.mp4"
