#!/bin/sh
# Runs every acceptance test (one JSON line each) and prints a summary.
# GPU tests need an unlocked desktop session (macOS throttles hidden windows).
cd "$(dirname "$0")/.." || exit 1
OUT=${OUT:-/tmp/koalasandpaper_tests.jsonl}
: > "$OUT"
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
if [ -z "$SKIP_AUDIT" ]; then
	for m in factory galton; do
		caffeinate -i "$G" --headless --path . --script res://tools/clearance.gd -- map=$m 2>&1 | grep '^{' >> "$OUT"
	done
fi
for t in t1_free_fall t2_repose t3_incline t4_silo t5_mixing t6_shredding t7_conveyor t_pusher q_sand q_press; do
	extra=""
	[ "$t" = t1_free_fall ] && extra="sub=80"
	QUIT_AFTER=20000 tools/run.sh res://tests/runner.tscn t=$t $extra | grep '^{' | tail -1 >> "$OUT"
done
QUIT_AFTER=$(( ${T8_FRAMES:-36000} + 600 )) tools/run.sh res://render/main.tscn frames=${T8_FRAMES:-36000} t8=1 | grep '^{' | tail -1 >> "$OUT"
QUIT_AFTER=2000 tools/run.sh res://tools/bench.tscn n=50000 spf=2 frames=60 warm=10 | grep '^{' | tail -1 >> "$OUT"
echo "== summary"
jq -r '[.test, (if .pass == null then "-" elif .pass then "PASS" else "FAIL" end)] | @tsv' "$OUT"
