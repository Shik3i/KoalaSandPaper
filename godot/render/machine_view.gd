class_name MachineView
extends Node2D
## Draws the machine from its definition: the same primitives the solver
## collides with (front layer), plus mechanism dressing that has no physics:
## chain, telescopic cylinder, spokes, hazard stripes (back layer).
## World m (y up) → canvas px via px_per_m and world height.
## Front layer: static geometry is drawn once; every moving body is a child
## PartNode drawn once in its own frame and only re-posed per frame (Godot keeps
## the recorded draw commands), so the machine costs almost nothing per frame.

const STEEL := {
	"wall": Color("#56696f"), "belt": Color("#2a3338"), "roller": Color("#7b9089"), "rotor": Color("#748a84"),
	"piston": Color("#a3b2ad"), "rod": Color("#9fb0ab"), "bucket": Color("#8ea19b"), "cleat": Color("#a9b8b3"),
	"drum": Color("#3a484d"), "peg": Color("#9db0aa"), "": Color("#56696f"),
}
const HAZARD := Color("#e0a93b")
## Static styles drawn above the moving parts.
const OVERLAY := ["barrel"]
const OUTLINE := Color("#0a1216")

var machine: Machine
var px_per_m := 100.0
var world_h := 1.0
## "front": colliding parts; "back": dressing behind the sand.
var layer := "front"
## Target of the draw helpers and their coordinate mode (body-local for parts).
var _ci: CanvasItem = self
var _local := false
var _parts: Array[PartNode] = []


## One moving body, drawn in its own frame (px, y down) and re-posed per frame.
class PartNode extends Node2D:
	var view: MachineView
	var body := 0
	var prims: Array = []

	func _draw() -> void:
		view._ci = self
		view._local = body != 0
		for p in prims:
			view._draw_prim(p)
		view._ci = view
		view._local = false


func to_px(p: Vector2) -> Vector2:
	if _local:
		return Vector2(p.x, -p.y) * px_per_m
	return Vector2(p.x, world_h - p.y) * px_per_m


func _ready() -> void:
	if machine == null or layer != "front":
		return
	var by_body := {}
	for p in machine.prims:
		if p.body == 0 or not _visible(p):
			continue
		if not by_body.has(p.body):
			by_body[p.body] = []
		by_body[p.body].append(p)
	for b in by_body:
		var part := PartNode.new()
		part.view = self
		part.body = b
		part.prims = by_body[b]
		add_child(part)
		_parts.append(part)
	# Static parts that sleeve moving ones (the ram barrel over its stages) on top.
	var over := PartNode.new()
	over.view = self
	for p in machine.prims:
		if p.body == 0 and p.style in OVERLAY:
			over.prims.append(p)
	add_child(over)
	_pose_parts()


func _visible(p: Dictionary) -> bool:
	return not (p.flags & (Machine.FLAG_SINK | Machine.FLAG_HEAT)) and p.style != "drum" and p.style != "rod"


func _process(_d: float) -> void:
	if layer == "back":
		queue_redraw()
	else:
		_pose_parts()


func _pose_parts() -> void:
	# The overlay node stays at the world origin; its prims are drawn in world px.
	for part in _parts:
		var b: Dictionary = machine.bodies[part.body]
		part.position = to_px(b.pos)
		part.rotation = -b.angle


func _draw() -> void:
	if machine == null:
		return
	if layer == "back":
		_draw_back()
		return
	for p in machine.prims:
		if p.body == 0 and _visible(p) and not p.style in OVERLAY:
			_draw_prim(p)


func _draw_prim(p: Dictionary) -> void:
	var xf := Transform2D.IDENTITY if _local else machine.body_xform(p.body)
	match p.style:
		"stage":
			_chrome_box(p, xf, Color("#b8c6c4"))
			return
		"barrel":
			_barrel(p, xf)
			return
		"piston_head":
			_piston_head(p, xf)
			return
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
		_ci.draw_polyline(pts, OUTLINE, lw, true)
	if p.style == "piston" and p.type == Machine.BOX:
		_hazard(p, xf)
	if p.type == Machine.CIRCLE and machine.bodies[p.body].motion.kind != "static":
		if _local:
			_spokes(p.offset, p.shape[0], 0.0, base)
		else:
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
		_ci.draw_polygon(pts, cols)


func _spokes(c: Vector2, r: float, angle: float, base: Color) -> void:
	var col := base.darkened(0.45)
	var w := maxf(1.0, 0.012 * px_per_m)
	for k in 4:
		var d := Vector2.from_angle(angle + k * PI * 0.5)
		_ci.draw_line(to_px(c + d * r * 0.25), to_px(c + d * r * 0.82), col, w, true)
	_ci.draw_circle(to_px(c), r * 0.28 * px_per_m, base.darkened(0.3))
	_ci.draw_circle(to_px(c), r * 0.12 * px_per_m, base.lightened(0.25))


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
				_ci.draw_colored_polygon(pts, HAZARD.darkened(0.15))
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
	_ci.draw_polyline(pts, Color("#1c2529"), maxf(2.0, 0.03 * px_per_m), true)
	var shift := fposmod(-Factory.ELEV_SPEED * f.time, 0.08)
	var s := shift
	while s < l:
		_ci.draw_circle(to_px(Machine.chain_point(b, t, rs, s)), 0.012 * px_per_m, Color("#6c7f7a"))
		s += 0.08
	for c in [b, t]:
		var ang := -Factory.ELEV_SPEED / rs * f.time
		_ci.draw_circle(to_px(c), rs * 0.95 * px_per_m, Color("#2f3c41"))
		_spokes(c, rs * 0.95, ang, Color("#6f837d"))
	# Belt drums.
	for p in f.prims:
		if p.style == "drum" and p.body != 0 and f.bodies[p.body].name == "drum":
			var body: Dictionary = f.bodies[p.body]
			_ci.draw_circle(to_px(body.pos), p.shape[0] * px_per_m, Color("#3a484d"))
			_spokes(body.pos, p.shape[0], body.angle, Color("#6f837d"))
	# Press: cylinder housing and rod.
	var press: Dictionary = f.bodies[f.press_body]
	var cyl := Rect2(Factory.PRESS_X - 0.09, 6.28, 0.18, 0.5)
	_rect(cyl, Color("#47575d"))
	var rod_top := Vector2(Factory.PRESS_X, 6.3)
	_ci.draw_line(to_px(press.pos), to_px(rod_top), Color("#b9c7c3"), 0.05 * px_per_m)


func _rect(r: Rect2, col: Color) -> void:
	var a := to_px(Vector2(r.position.x, r.end.y))
	var bb := to_px(Vector2(r.end.x, r.position.y))
	_ci.draw_rect(Rect2(a, bb - a), col)
	_ci.draw_rect(Rect2(a, bb - a), OUTLINE, false, maxf(1.0, 0.004 * px_per_m))


## Box prim corners in world space (no corner rounding: drawn shapes are crisp).
func _box_world(p: Dictionary, xf: Transform2D, inset := Vector2.ZERO) -> PackedVector2Array:
	var sh: Array = p.shape
	var e := Vector2(sh[0], sh[1]) - inset
	var lxf := xf * Transform2D(p.angle, p.offset)
	return PackedVector2Array([lxf * Vector2(-e.x, -e.y), lxf * Vector2(e.x, -e.y), lxf * Vector2(e.x, e.y), lxf * Vector2(-e.x, e.y)])


## Horizontal cylinder: dark underside, bright specular band above the axis.
func _chrome_box(p: Dictionary, xf: Transform2D, base: Color) -> void:
	var sh: Array = p.shape
	var lxf := xf * Transform2D(p.angle, p.offset)
	var bands := [[-1.0, base.darkened(0.55)], [-0.35, base.darkened(0.15)], [0.25, base.lightened(0.55)],
		[0.5, base.lightened(0.25)], [1.0, base.darkened(0.25)]]
	for k in bands.size() - 1:
		var y0: float = bands[k][0] * sh[1]
		var y1: float = bands[k + 1][0] * sh[1]
		var pts := PackedVector2Array()
		for q in [Vector2(-sh[0], y0), Vector2(sh[0], y0), Vector2(sh[0], y1), Vector2(-sh[0], y1)]:
			pts.append(to_px(lxf * q))
		_ci.draw_polygon(pts, PackedColorArray([bands[k][1], bands[k][1], bands[k + 1][1], bands[k + 1][1]]))
	var o := PackedVector2Array()
	for w in _box_world(p, xf):
		o.append(to_px(w))
	o.append(o[0])
	_ci.draw_polyline(o, OUTLINE, maxf(1.0, 0.004 * px_per_m), true)


## Hydraulic barrel: heavy dark tube with a gland flange at the mouth and bolt rings.
func _barrel(p: Dictionary, xf: Transform2D) -> void:
	_chrome_box(p, xf, Color("#5d6d70"))
	var sh: Array = p.shape
	var lxf := xf * Transform2D(p.angle, p.offset)
	var flange := Color("#3e4b4f")
	for fx in [-sh[0] + 0.03, sh[0] - 0.05]:
		var pts := PackedVector2Array()
		for q in [Vector2(fx - 0.03, -sh[1] - 0.03), Vector2(fx + 0.03, -sh[1] - 0.03), Vector2(fx + 0.03, sh[1] + 0.03), Vector2(fx - 0.03, sh[1] + 0.03)]:
			pts.append(to_px(lxf * q))
		_ci.draw_colored_polygon(pts, flange)
		for by in [-sh[1] - 0.012, sh[1] + 0.012]:
			_ci.draw_circle(to_px(lxf * Vector2(fx, by)), 0.009 * px_per_m, Color("#9aa9a6"))
	_ci.draw_string(ThemeDB.fallback_font, to_px(lxf * Vector2(-sh[0] + 0.25, -0.03)), "HYDRAULIK 6-STUFIG", HORIZONTAL_ALIGNMENT_LEFT, -1, int(maxf(8.0, 0.045 * px_per_m)), Color(1, 1, 1, 0.45))


## Ram head drawn like an engine piston: crown on the pushing (left) side with
## three ring grooves, polished skirt, wrist pin boss, hazard band on the crown.
func _piston_head(p: Dictionary, xf: Transform2D) -> void:
	_chrome_box(p, xf, Color("#c9d3d0"))
	var sh: Array = p.shape
	var lxf := xf * Transform2D(p.angle, p.offset)
	var hx: float = sh[0]
	var hy: float = sh[1]
	# Crown face plate.
	var crown := PackedVector2Array()
	for q in [Vector2(-hx, -hy), Vector2(-hx + 0.035, -hy), Vector2(-hx + 0.035, hy), Vector2(-hx, hy)]:
		crown.append(to_px(lxf * q))
	_ci.draw_colored_polygon(crown, Color("#e7ecea"))
	# Ring grooves.
	for gx in [-hx + 0.055, -hx + 0.08, -hx + 0.105]:
		_ci.draw_line(to_px(lxf * Vector2(gx, -hy + 0.006)), to_px(lxf * Vector2(gx, hy - 0.006)), Color("#2b3437"), maxf(1.5, 0.008 * px_per_m), true)
	# Wrist pin boss.
	var pin := lxf * Vector2(0.04, 0.0)
	_ci.draw_circle(to_px(pin), 0.06 * px_per_m, Color("#7d8c89"))
	_ci.draw_circle(to_px(pin), 0.042 * px_per_m, Color("#4a575a"))
	_ci.draw_circle(to_px(pin), 0.02 * px_per_m, Color("#d7dfdc"))
	# Hazard band on the skirt's tail.
	var band := {"type": Machine.BOX, "shape": [0.025, hy - 0.004, 0.0], "angle": 0.0, "offset": p.offset + Vector2(hx - 0.04, 0.0)}
	_hazard(band, xf)
