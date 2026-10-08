class_name MachineView
extends Node2D
## Draws the machine from its definition: the same primitives the solver
## collides with (front layer), plus mechanism dressing that has no physics:
## chain, telescopic cylinder, spokes, hazard stripes (back layer).
## World m (y up) → canvas px via px_per_m and world height.

const STEEL := {
	"wall": Color("#56696f"), "belt": Color("#2a3338"), "roller": Color("#7b9089"), "rotor": Color("#748a84"),
	"piston": Color("#a3b2ad"), "rod": Color("#9fb0ab"), "bucket": Color("#8ea19b"), "cleat": Color("#a9b8b3"),
	"drum": Color("#3a484d"), "": Color("#56696f"),
}
const HAZARD := Color("#e0a93b")
const OUTLINE := Color("#0a1216")

var machine: Machine
var px_per_m := 100.0
var world_h := 1.0
## "front": colliding parts; "back": dressing behind the sand.
var layer := "front"


func to_px(p: Vector2) -> Vector2:
	return Vector2(p.x, world_h - p.y) * px_per_m


func _process(_d: float) -> void:
	queue_redraw()


func _draw() -> void:
	if machine == null:
		return
	if layer == "back":
		_draw_back()
		return
	for p in machine.prims:
		if p.flags & (Machine.FLAG_SINK | Machine.FLAG_HEAT):
			continue
		if p.style == "drum" or p.style == "rod":
			continue
		_draw_prim(p)


func _draw_prim(p: Dictionary) -> void:
	var xf := machine.body_xform(p.body)
	var base: Color = STEEL.get(p.style, STEEL[""])
	var outline := Machine.outline(p, 40)
	var lw := maxf(1.0, 0.006 * px_per_m)
	for k in p.repeat:
		var rep := Transform2D(TAU * k / p.repeat, Vector2.ZERO)
		var world := PackedVector2Array()
		for q in outline:
			world.append(xf * (rep * q))
		_gradient_polygon(world, base)
		var pts := PackedVector2Array()
		for w in world:
			pts.append(to_px(w))
		pts.append(pts[0])
		draw_polyline(pts, OUTLINE, lw, true)
	if p.style == "piston" and p.type == Machine.BOX:
		_hazard(p, xf)
	if p.type == Machine.CIRCLE and machine.bodies[p.body].motion.kind != "static":
		_spokes(machine.bodies[p.body].pos, p.shape[0], machine.bodies[p.body].angle, base)


## Fill with a top-lit vertical gradient (lighter above, darker below).
func _gradient_polygon(world: PackedVector2Array, base: Color) -> void:
	var lo := INF
	var hi := -INF
	for w in world:
		lo = minf(lo, w.y)
		hi = maxf(hi, w.y)
	var span := maxf(hi - lo, 1e-4)
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	for w in world:
		var k := (w.y - lo) / span
		pts.append(to_px(w))
		cols.append(base.darkened(0.25).lerp(base.lightened(0.18), k))
	if Geometry2D.triangulate_polygon(pts).size() > 0:
		draw_polygon(pts, cols)


func _spokes(c: Vector2, r: float, angle: float, base: Color) -> void:
	var col := base.darkened(0.45)
	var w := maxf(1.0, 0.012 * px_per_m)
	for k in 4:
		var d := Vector2.from_angle(angle + k * PI * 0.5)
		draw_line(to_px(c + d * r * 0.25), to_px(c + d * r * 0.82), col, w, true)
	draw_circle(to_px(c), r * 0.28 * px_per_m, base.darkened(0.3))
	draw_circle(to_px(c), r * 0.12 * px_per_m, base.lightened(0.25))


## Diagonal yellow/black stripes clipped to a box primitive (in its local frame).
func _hazard(p: Dictionary, xf: Transform2D) -> void:
	var sh: Array = p.shape
	var box := PackedVector2Array([Vector2(-sh[0], -sh[1]), Vector2(sh[0], -sh[1]), Vector2(sh[0], sh[1]), Vector2(-sh[0], sh[1])])
	var w := 0.035
	var reach: float = sh[0] + sh[1]
	var x := -reach * 2.0
	var k := 0
	while x < reach * 2.0:
		var stripe := PackedVector2Array([Vector2(x, -reach), Vector2(x + w, -reach), Vector2(x + w + 2.0 * reach, reach), Vector2(x + 2.0 * reach, reach)])
		if k % 2 == 0:
			for poly in Geometry2D.intersect_polygons(stripe, box):
				var pts := PackedVector2Array()
				var lxf := Transform2D(p.angle, p.offset)
				for q in poly:
					pts.append(to_px(xf * (lxf * q)))
				draw_colored_polygon(pts, HAZARD.darkened(0.15))
		x += w
		k += 1


func _draw_back() -> void:
	var f := machine as Factory
	if f == null:
		return
	var lw := maxf(1.0, 0.01 * px_per_m)
	# Elevator chain: two strands and links running at chain speed.
	var b := f.elev_bottom
	var t := f.elev_top
	var rs := f.elev_rs
	var l := Machine.chain_length(b, t, rs)
	var pts := PackedVector2Array()
	var steps := 160
	for i in steps + 1:
		pts.append(to_px(Machine.chain_point(b, t, rs, l * i / steps)))
	draw_polyline(pts, Color("#1c2529"), maxf(2.0, 0.03 * px_per_m), true)
	var shift := fposmod(-Factory.ELEV_SPEED * f.time, 0.08)
	var s := shift
	while s < l:
		draw_circle(to_px(Machine.chain_point(b, t, rs, s)), 0.012 * px_per_m, Color("#6c7f7a"))
		s += 0.08
	for c in [b, t]:
		var ang := -Factory.ELEV_SPEED / rs * f.time
		draw_circle(to_px(c), rs * 0.95 * px_per_m, Color("#2f3c41"))
		_spokes(c, rs * 0.95, ang, Color("#6f837d"))
	# Belt drums.
	for p in f.prims:
		if p.style == "drum" and p.body != 0 and f.bodies[p.body].name == "drum":
			var body: Dictionary = f.bodies[p.body]
			draw_circle(to_px(body.pos), p.shape[0] * px_per_m, Color("#3a484d"))
			_spokes(body.pos, p.shape[0], body.angle, Color("#6f837d"))
	# Press: cylinder housing and rod.
	var press: Dictionary = f.bodies[f.press_body]
	var cyl := Rect2(Factory.PRESS_X - 0.09, 6.28, 0.18, 0.5)
	_rect(cyl, Color("#47575d"))
	var rod_top := Vector2(Factory.PRESS_X, 6.3)
	draw_line(to_px(press.pos), to_px(rod_top), Color("#b9c7c3"), 0.05 * px_per_m)
	# Pusher: telescopic cylinder from its anchor to the blade.
	var pb: Dictionary = f.bodies[f.pusher_body]
	var anchor := Vector2(f.floor_x.x - 0.02, pb.pos.y + 0.02)
	var tip: float = pb.pos.x - 0.045
	var seg: float = (tip - anchor.x) / 3.0
	for k in 3:
		var x0: float = anchor.x + k * seg
		var thick := 0.075 - k * 0.018
		_rect(Rect2(x0, anchor.y - thick * 0.5, seg + 0.05, thick), Color("#8c9c98").darkened(0.15 * (2 - k)))
	_rect(Rect2(anchor.x - 0.08, anchor.y - 0.06, 0.1, 0.12), Color("#3c4b50"))


func _rect(r: Rect2, col: Color) -> void:
	var a := to_px(Vector2(r.position.x, r.end.y))
	var bb := to_px(Vector2(r.end.x, r.position.y))
	draw_rect(Rect2(a, bb - a), col)
	draw_rect(Rect2(a, bb - a), OUTLINE, false, maxf(1.0, 0.004 * px_per_m))
