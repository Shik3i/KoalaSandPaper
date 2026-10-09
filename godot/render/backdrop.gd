class_name Backdrop
extends Node2D
## Static hall dressing behind the sand: wall panels, frames, hangers, the
## elevator casing, floor base and the furnace brickwork. No physics.

const PANEL := Color("#152129")
const FRAME := Color("#26343b")
const RIVET := Color("#33444b")

var f: Factory
var px_per_m := 100.0
var world_h := 1.0


func to_px(p: Vector2) -> Vector2:
	return Vector2(p.x, world_h - p.y) * px_per_m


func _draw() -> void:
	# Elevator casing: a band along the incline behind the chain.
	var u := (f.elev_top - f.elev_bottom).normalized()
	var n := Vector2(u.y, -u.x)
	# Behind the casing walls (pit radius 0.58 m from the chain centre line).
	var w := 0.62
	var a := f.elev_bottom - u * 0.62
	var b := f.elev_top + u * 0.62
	_poly([a - n * w, a + n * w, b + n * w, b - n * w], PANEL)
	for k in 9:
		var p0 := a.lerp(b, k / 9.0)
		var p1 := a.lerp(b, (k + 1) / 9.0)
		_line(p0 - n * w, p1 + n * w, FRAME, 0.012)
		_line(p0 + n * w, p1 - n * w, FRAME, 0.012)
	_line(a - n * w, b - n * w, FRAME, 0.03)
	_line(a + n * w, b + n * w, FRAME, 0.03)
	# Shredder column and mixer backing.
	_panel(Rect2(7.5, 2.95, 1.8, 2.95))
	if f.map == "galton":
		_panel(Rect2(f.bins.position.x - 0.15, f.bins.position.y - 0.12, f.bins.size.x + 0.3, 3.35 - f.bins.position.y))
	else:
		draw_circle(to_px(f.bowl_c), (f.bowl_r + 0.18) * px_per_m, PANEL)
	# Belt A frame hung from the roof girder.
	_line(Vector2(0.0, 6.86), Vector2(12.288, 6.86), FRAME, 0.06)
	for x in [4.3, 5.2, 6.8, 7.6]:
		_line(Vector2(x, Factory.Y_A - 0.08), Vector2(x, 6.86), FRAME, 0.025)
	# Press portal.
	_line(Vector2(5.55, Factory.Y_A - 0.08), Vector2(5.55, 6.86), FRAME, 0.07)
	_line(Vector2(6.45, Factory.Y_A - 0.08), Vector2(6.45, 6.86), FRAME, 0.07)
	_line(Vector2(5.5, 6.78), Vector2(6.5, 6.78), FRAME, 0.09)
	# Floor base and legs.
	_panel(Rect2(f.floor_x.x - 0.05, 0.45, f.floor_x.y - f.floor_x.x + 0.1, Factory.Y_FLOOR - 0.45 - 0.02))
	for x in range(2, 10):
		_line(Vector2(x, 0.04), Vector2(x, 0.45), FRAME, 0.05)
	_line(Vector2(0.0, 0.04), Vector2(12.288, 0.04), FRAME, 0.04)
	# Furnace brickwork.
	var fr := f.furnace
	_poly([fr.position, Vector2(fr.end.x, fr.position.y), fr.end, Vector2(fr.position.x, fr.end.y)], Color("#1d1714"))
	var row := 0
	var y := fr.position.y
	while y < fr.end.y:
		_line(Vector2(fr.position.x, y), Vector2(fr.end.x, y), Color("#2a201b"), 0.008)
		var x := fr.position.x + (0.09 if row % 2 == 1 else 0.0)
		while x < fr.end.x:
			_line(Vector2(x, y), Vector2(x, minf(y + 0.09, fr.end.y)), Color("#2a201b"), 0.008)
			x += 0.18
		y += 0.09
		row += 1


func _panel(r: Rect2) -> void:
	_poly([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)], PANEL)
	var lw := 0.02
	_line(r.position, Vector2(r.end.x, r.position.y), FRAME, lw)
	_line(Vector2(r.end.x, r.position.y), r.end, FRAME, lw)
	_line(r.end, Vector2(r.position.x, r.end.y), FRAME, lw)
	_line(Vector2(r.position.x, r.end.y), r.position, FRAME, lw)
	for c in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		draw_circle(to_px(c + (r.get_center() - c).normalized() * 0.07), 0.018 * px_per_m, RIVET)


func _poly(pts: Array, col: Color) -> void:
	var out := PackedVector2Array()
	for p in pts:
		out.append(to_px(p))
	draw_colored_polygon(out, col)


func _line(a: Vector2, b: Vector2, col: Color, w: float) -> void:
	draw_line(to_px(a), to_px(b), col, maxf(1.0, w * px_per_m), true)
