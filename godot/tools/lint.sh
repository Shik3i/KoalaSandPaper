#!/bin/sh
# Parse-checks every GDScript file headlessly; prints only errors.
cd "$(dirname "$0")/.." || exit 1
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
"$G" --headless --path . --import >/dev/null 2>&1 || "$G" --headless --path . --import >/dev/null 2>&1
fail=0
"$G" --headless --path . --script res://tools/check_shaders.gd 2>&1 | grep -v -E '^\s*$|Godot Engine' || true
"$G" --headless --path . --script res://tools/check_shaders.gd >/dev/null 2>&1 || fail=1
for f in $(find . -name '*.gd' -not -path './.godot/*' -not -name 'check_shaders.gd'); do
	out=$("$G" --headless --path . --check-only --script "res://${f#./}" 2>&1 | grep -E 'ERROR|error' | grep -v -E 'Pipeline cache|ObjectDB|Can.t run script|extends Node|SceneTree|MainLoop' | head -5)
	[ -n "$out" ] && { echo "== $f"; echo "$out"; fail=1; }
done
exit $fail
