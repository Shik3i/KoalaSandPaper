class_name Machine
extends RefCounted
## Machine definition: kinematic bodies carrying SDF primitives. Single source
## of truth for collision (packed for the solver) and drawing (MachineView).
## Bodies are driven analytically (motors): pose and velocity are functions of
## time, the GPU extrapolates within a frame with the uploaded velocity.

enum { CIRCLE, CAPSULE, BOX, ARC }
const FLAG_INVERTED := 1
const FLAG_SINK := 2
## Drawn but not collided with (rods, housings).
const FLAG_VISUAL := 4
const MU := Vector2(0.6249, 0.5317)

## {pos, angle, vel, omega, name, motion: {kind: "static"|"rotate"|"piston", ...}, home, home_angle}
var bodies: Array[Dictionary] = []
## {type, body, repeat, flags, offset, angle, phase, shape[4], mu_s, mu_k, bound, speed, sink_id, style}
var prims: Array[Dictionary] = []
var time := 0.0


func _init() -> void:
	add_body(Vector2.ZERO, 0.0, "static")


func add_body(pos: Vector2, angle := 0.0, body_name := "") -> int:
	bodies.append({"pos": pos, "angle": angle, "vel": Vector2.ZERO, "omega": 0.0, "name": body_name,
		"motion": {"kind": "static"}, "home": pos, "home_angle": angle})
	return bodies.size() - 1


## Motor at constant angular velocity (rad/s, + = counter-clockwise, y up).
## Motor at constant angular velocity after a linear soft start over `ramp` s.
func rotor(body: int, omega: float, ramp := 2.0) -> void:
	bodies[body].motion = {"kind": "rotate", "omega": omega, "ramp": ramp}


## Piston: home + axis * stroke * (1 - cos(2πt/period)) / 2.
func piston(body: int, axis: Vector2, stroke: float, period: float, phase := 0.0) -> void:
	bodies[body].motion = {"kind": "piston", "axis": axis.normalized(), "stroke": stroke, "period": period, "phase": phase}


## shape: circle [R] | capsule [half_len, R] | box [hx, hy, corner] | arc [ra, rb, half_aperture]
## arc: centred on local +y, so angle = centre_direction - PI/2.
func add_prim(body: int, type: int, shape: Array, offset := Vector2.ZERO, angle := 0.0,
		repeat := 1, flags := 0, speed := 0.0, style := "") -> int:
	var ext := 0.0
	match type:
		CIRCLE: ext = shape[0]
		CAPSULE: ext = shape[0] + shape[1]
		BOX: ext = Vector2(shape[0], shape[1]).length()
		ARC: ext = shape[0] + shape[1]
	var s := [0.0, 0.0, 0.0, 0.0]
	for k in shape.size():
		s[k] = shape[k]
	prims.append({"type": type, "body": body, "repeat": repeat, "flags": flags, "offset": offset,
		"angle": angle, "phase": offset.angle() if repeat > 1 else 0.0, "shape": s,
		"mu_s": MU.x, "mu_k": MU.y, "bound": offset.length() + ext, "speed": speed, "sink_id": 0, "style": style})
	return prims.size() - 1


## Static wall as a capsule from a to b with half thickness t.
func add_segment(a: Vector2, b: Vector2, t: float, style := "") -> int:
	return add_prim(0, CAPSULE, [a.distance_to(b) * 0.5, t], (a + b) * 0.5, (b - a).angle(), 1, 0, 0.0, style)


## Static arc around c from math angle a0 to a1 (radians, a1 > a0).
func add_arc(c: Vector2, radius: float, t: float, a0: float, a1: float, style := "") -> int:
	return add_prim(0, ARC, [radius, t, (a1 - a0) * 0.5], c, (a0 + a1) * 0.5 - PI * 0.5, 1, 0, 0.0, style)


## Removal zone (box). Particles inside are deactivated and counted in stats slot 8 + id.
func add_sink(a: Vector2, b: Vector2, id: int) -> int:
	var k := add_prim(0, BOX, [absf(b.x - a.x) * 0.5, absf(b.y - a.y) * 0.5, 0.0], (a + b) * 0.5)
	prims[k].flags = FLAG_SINK
	prims[k].sink_id = id
	return k


## Sets every driven body to its pose/velocity at time t.
func update(t: float) -> void:
	time = t
	for b in bodies:
		var m: Dictionary = b.motion
		match m.kind:
			"rotate":
				var tr: float = m.ramp
				if t < tr:
					b.omega = m.omega * t / tr
					b.angle = b.home_angle + 0.5 * m.omega * t * t / tr
				else:
					b.omega = m.omega
					b.angle = b.home_angle + m.omega * (t - 0.5 * tr)
			"piston":
				var w: float = TAU / m.period
				var ph: float = w * t + m.phase
				b.pos = b.home + m.axis * m.stroke * (1.0 - cos(ph)) * 0.5
				b.vel = m.axis * m.stroke * w * sin(ph) * 0.5


## World transform of a body at the current time.
func body_xform(b: int) -> Transform2D:
	return Transform2D(bodies[b].angle, bodies[b].pos)


func pack_bodies() -> PackedFloat32Array:
	var f := PackedFloat32Array()
	for b in bodies:
		f.append_array([b.pos.x, b.pos.y, b.angle, 0.0, b.vel.x, b.vel.y, b.omega, 0.0])
	return f


func pack_prims() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(prims.size() * 64)
	for i in prims.size():
		var p: Dictionary = prims[i]
		var o := i * 64
		out.encode_u32(o, p.type)
		out.encode_u32(o + 4, p.body)
		out.encode_u32(o + 8, p.repeat)
		out.encode_u32(o + 12, p.flags | (p.sink_id << 8))
		var fl: Array = [p.offset.x, p.offset.y, p.angle, p.phase] + p.shape + [p.mu_s, p.mu_k, p.bound, p.speed]
		for k in 12:
			out.encode_float(o + 16 + k * 4, fl[k])
	return out


func upload(solver: GpuSolver) -> void:
	solver.set_colliders(pack_bodies(), pack_prims())


## CPU mirror of colliders.glsli prim_sdf (spawn placement, tests).
func sdf(p: Vector2) -> float:
	var best := INF
	for pr in prims:
		if pr.flags & (FLAG_SINK | FLAG_VISUAL):
			continue
		var q: Vector2 = body_xform(pr.body).affine_inverse() * p
		if pr.repeat > 1:
			var sector: float = TAU / pr.repeat
			var k := roundf((atan2(q.y, q.x) - pr.phase) / sector)
			q = q.rotated(-k * sector)
		q = (q - pr.offset).rotated(-pr.angle)
		var sh: Array = pr.shape
		var d := 0.0
		match pr.type:
			CIRCLE:
				d = q.length() - sh[0]
			CAPSULE:
				q.x -= clampf(q.x, -sh[0], sh[0])
				d = q.length() - sh[1]
			BOX:
				var e := q.abs() - Vector2(sh[0], sh[1]) + Vector2(sh[2], sh[2])
				d = e.max(Vector2.ZERO).length() + minf(maxf(e.x, e.y), 0.0) - sh[2]
			ARC:
				var sc := Vector2(sin(sh[2]), cos(sh[2]))
				q.x = absf(q.x)
				d = ((q - sc * sh[0]).length() if sc.y * q.x > sc.x * q.y else absf(q.length() - sh[0])) - sh[1]
		if pr.flags & FLAG_INVERTED:
			d = -d
		best = minf(best, d)
	return best
