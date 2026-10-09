class_name FlowArrows
extends Node2D
## Faint chevrons drifting along the material path (Factory.flow_paths), so the
## loop reads at a glance on a wallpaper. No physics.

const COLOR := Color(0.88, 0.66, 0.23, 0.32)
const SPACING := 0.32
const SPEED := 0.35

var factory: Factory
var px_per_m := 100.0
var world_h := 1.0
var _paths: Array[PackedVector2Array] = []
var _t := 0.0


func _ready() -> void:
	_paths = factory.flow_paths()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func to_px(p: Vector2) -> Vector2:
	return Vector2(p.x, world_h - p.y) * px_per_m


func _draw() -> void:
	var size := 0.06
	var w := maxf(1.5, 0.012 * px_per_m)
	for path in _paths:
		var a := path[0]
		var b := path[path.size() - 1]
		var l := a.distance_to(b)
		var d := (b - a) / l
		var n := Vector2(-d.y, d.x)
		var s := fposmod(_t * SPEED, SPACING)
		while s < l:
			# Fade in and out at the ends of each path.
			var fade := clampf(minf(s, l - s) / 0.25, 0.0, 1.0)
			var c := Color(COLOR, COLOR.a * fade)
			var p := a + d * s
			_ci_chevron(p, d, n, size, c, w)
			s += SPACING


func _ci_chevron(p: Vector2, d: Vector2, n: Vector2, size: float, c: Color, w: float) -> void:
	var tip := to_px(p + d * size * 0.5)
	draw_polyline(PackedVector2Array([to_px(p - d * size * 0.5 + n * size), tip, to_px(p - d * size * 0.5 - n * size)]), c, w, true)
