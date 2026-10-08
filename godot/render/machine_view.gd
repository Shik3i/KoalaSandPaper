class_name MachineView
extends Node2D
## Draws the machine from its definition (same primitives the solver collides
## with). World m (y up) → canvas px via px_per_m and world height.

const COLORS := {
	"wall": Color("#55676d"), "belt": Color("#3c4a50"), "roller": Color("#718781"),
	"rotor": Color("#718781"), "piston": Color("#8a9c97"), "rod": Color("#46565b"), "": Color("#55676d"),
}

var machine: Machine
var px_per_m := 100.0
var world_h := 1.0
var laser: Array = [Vector2.ZERO, Vector2.ZERO]


func to_px(p: Vector2) -> Vector2:
	return Vector2(p.x, world_h - p.y) * px_per_m


func _process(_d: float) -> void:
	queue_redraw()


func _draw() -> void:
	if machine == null:
		return
	for p in machine.prims:
		if p.flags & Machine.FLAG_SINK:
			continue
		var outline := _outline(p)
		var xf := machine.body_xform(p.body)
		var col: Color = COLORS.get(p.style, COLORS[""])
		for k in p.repeat:
			var rep := Transform2D(TAU * k / p.repeat, Vector2.ZERO)
			var pts := PackedVector2Array()
			for q in outline:
				pts.append(to_px(xf * (rep * q)))
			draw_colored_polygon(pts, col)
		if p.style == "belt":
			_belt_marks(p, xf)
	for b in machine.bodies:
		if b.motion.kind == "rotate":
			draw_circle(to_px(b.pos), 0.05 * px_per_m, Color("#2b363b"))
	if laser[0] != laser[1]:
		draw_line(to_px(laser[0]), to_px(laser[1]), Color(1.0, 0.35, 0.3, 0.9), maxf(1.0, 0.012 * px_per_m))
		draw_circle(to_px(laser[1]), 0.02 * px_per_m, Color(1.0, 0.8, 0.6))


## Primitive outline in body space (before repeat rotation).
func _outline(p: Dictionary) -> PackedVector2Array:
	var local := PackedVector2Array()
	var sh: Array = p.shape
	match p.type:
		Machine.CIRCLE:
			for i in 40:
				local.append(Vector2.from_angle(TAU * i / 40.0) * sh[0])
		Machine.CAPSULE:
			for i in 21:
				local.append(Vector2(sh[0], 0) + Vector2.from_angle(-PI / 2 + PI * i / 20.0) * sh[1])
			for i in 21:
				local.append(Vector2(-sh[0], 0) + Vector2.from_angle(PI / 2 + PI * i / 20.0) * sh[1])
		Machine.BOX:
			var c: float = sh[2]
			var e := Vector2(sh[0], sh[1]) - Vector2(c, c)
			for q in 4:
				var ctr := Vector2(e.x * (1 if q == 0 or q == 3 else -1), e.y * (1 if q < 2 else -1))
				for i in 6:
					local.append(ctr + Vector2.from_angle(PI / 2 * q + PI / 2 * i / 5.0) * c)
		Machine.ARC:
			var ra: float = sh[0]
			var rb: float = sh[1]
			var half: float = sh[2]
			var n := 48
			for i in n + 1:
				local.append(Vector2.from_angle(PI / 2 - half + 2.0 * half * i / n) * (ra + rb))
			for i in n + 1:
				local.append(Vector2.from_angle(PI / 2 + half - 2.0 * half * i / n) * (ra - rb))
	var xf := Transform2D(p.angle, p.offset)
	var out := PackedVector2Array()
	for q in local:
		out.append(xf * q)
	return out


func _belt_marks(p: Dictionary, xf: Transform2D) -> void:
	var sh: Array = p.shape
	var spacing := 0.12
	var shift := fmod(machine.time * p.speed, spacing)
	var x: float = -sh[0] + shift
	while x < sh[0]:
		var a: Vector2 = xf * (p.offset + Vector2(x, sh[1] * 0.4))
		var b: Vector2 = xf * (p.offset + Vector2(x + 0.04, sh[1] * 0.4))
		draw_line(to_px(a), to_px(b), Color("#5b6b70"), maxf(1.0, 0.01 * px_per_m))
		x += spacing
