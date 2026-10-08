class_name Machine
extends RefCounted
## Machine definition: kinematic bodies carrying SDF primitives. Single source
## of truth for collision (packed for the solver) and drawing (MachineView).
## Bodies are driven analytically: pose(t) per motion profile; velocities are
## central differences of the pose, the GPU extrapolates within a frame.

enum { CIRCLE, CAPSULE, BOX, ARC }
const FLAG_INVERTED := 1
const FLAG_SINK := 2
## Drawn but not collided with (rods, housings).
const FLAG_VISUAL := 4
## Heat zone: grains inside heat up (glow) and burn (removed, counted on sink_id) when hot.
const FLAG_HEAT := 8
const MU := Vector2(0.6249, 0.5317)
## Coarse collider grid (CPU-built per frame): cell size and max prims per cell.
const PCELL := 0.4
const PCELL_CAP := 31

## {pos, angle, vel, omega, name, motion: Dictionary, home, home_angle}
var bodies: Array[Dictionary] = []
## {type, body, repeat, flags, offset, angle, phase, shape[4], mu_s, mu_k, bound, ext, speed, sink_id, style}
var prims: Array[Dictionary] = []
var time := 0.0
var world := Vector2(12.288, 6.912)
var grid_overflow := 0


func _init() -> void:
	add_body(Vector2.ZERO, 0.0, "static")


func add_body(pos: Vector2, angle := 0.0, body_name := "") -> int:
	bodies.append({"pos": pos, "angle": angle, "vel": Vector2.ZERO, "omega": 0.0, "name": body_name,
		"motion": {"kind": "static"}, "home": pos, "home_angle": angle})
	return bodies.size() - 1


## Motor at constant angular velocity (rad/s, + = counter-clockwise, y up) after a soft start.
func rotor(body: int, omega: float, ramp := 2.0) -> void:
	bodies[body].motion = {"kind": "rotate", "omega": omega, "ramp": ramp}


## Piston: home + axis * stroke * (1 - cos(2πt/period + phase)) / 2.
func piston(body: int, axis: Vector2, stroke: float, period: float, phase := 0.0) -> void:
	bodies[body].motion = {"kind": "piston", "axis": axis.normalized(), "stroke": stroke, "period": period, "phase": phase}


## Pendulum flap between ±amp (rad) with plateaus (sharpness k), period in s.
func flap(body: int, amp: float, period: float, k := 4.0) -> void:
	bodies[body].motion = {"kind": "flap", "amp": amp, "period": period, "k": k}


## Chain carrier on a vertical stadium loop (sprockets at bottom/top centre, radius rs),
## counter-clockwise: down the left strand, up the right. s0 = start position along the
## loop; the body pivot rides the chain. Tips by tip_angle (CCW) while the chain
## position is inside [tip_s0, tip_s1] (measured from the top of the left strand).
func chain(body: int, bottom: Vector2, top: Vector2, rs: float, speed: float, s0: float,
		tip_s0 := 0.0, tip_s1 := 0.0, tip_angle := 0.0) -> void:
	bodies[body].motion = {"kind": "chain", "bottom": bottom, "top": top, "rs": rs, "speed": speed,
		"s0": s0, "tip_s0": tip_s0, "tip_s1": tip_s1, "tip_angle": tip_angle, "fixed": false}


## Carrier rigidly mounted on the chain: local +y points along the direction of
## travel (bucket mouth), local -x to the outside of the loop for clockwise travel.
func chain_fixed(body: int, bottom: Vector2, top: Vector2, rs: float, speed: float, s0: float) -> void:
	chain(body, bottom, top, rs, speed, s0)
	bodies[body].motion.fixed = true


## Carrier on a horizontal belt loop around drums at p0 (left) and p1 (right),
## radius rr; speed > 0 = top strand moves right. Local +y = outward normal.
func loop(body: int, p0: Vector2, p1: Vector2, rr: float, speed: float, s0: float) -> void:
	bodies[body].motion = {"kind": "loop", "p0": p0, "p1": p1, "rr": rr, "speed": speed, "s0": s0}


static func loop_length(p0: Vector2, p1: Vector2, rr: float) -> float:
	return 2.0 * (p1.x - p0.x) + TAU * rr


## [point, unwrapped angle] at arc length s (0 = left end of the top strand, clockwise).
static func loop_pose(p0: Vector2, p1: Vector2, rr: float, s: float) -> Array:
	var lx := p1.x - p0.x
	var l := 2.0 * lx + TAU * rr
	var turns := floorf(s / l)
	var u := s - turns * l
	var base := -TAU * turns
	if u < lx:
		return [Vector2(p0.x + u, p0.y + rr), base]
	u -= lx
	if u < PI * rr:
		var a := -u / rr
		return [p1 + Vector2.from_angle(PI * 0.5 + a) * rr, base + a]
	u -= PI * rr
	if u < lx:
		return [Vector2(p1.x - u, p0.y - rr), base - PI]
	u -= lx
	var b := -PI - u / rr
	return [p0 + Vector2.from_angle(PI * 0.5 + b) * rr, base + b]


static func chain_length(bottom: Vector2, top: Vector2, rs: float) -> float:
	return 2.0 * (top.y - bottom.y) + TAU * rs


## Point on the loop at arc length s (0 = top of the left strand, going down).
static func chain_point(bottom: Vector2, top: Vector2, rs: float, s: float) -> Vector2:
	var hgt := top.y - bottom.y
	var l := 2.0 * hgt + TAU * rs
	s = fposmod(s, l)
	if s < hgt:
		return Vector2(top.x - rs, top.y - s)
	s -= hgt
	if s < PI * rs:
		return bottom + Vector2.from_angle(PI + s / rs) * rs
	s -= PI * rs
	if s < hgt:
		return Vector2(bottom.x + rs, bottom.y + s)
	s -= hgt
	return top + Vector2.from_angle(s / rs) * rs


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
		"mu_s": MU.x, "mu_k": MU.y, "bound": offset.length() + ext, "ext": ext, "speed": speed,
		"sink_id": 0, "style": style})
	return prims.size() - 1


## Wall as a capsule from a to b with half thickness t (body-local if body != 0).
func add_segment(a: Vector2, b: Vector2, t: float, style := "wall", body := 0) -> int:
	return add_prim(body, CAPSULE, [a.distance_to(b) * 0.5, t], (a + b) * 0.5, (b - a).angle(), 1, 0, 0.0, style)


## Polyline of static segments.
func add_path(points: PackedVector2Array, t: float, style := "wall") -> void:
	for i in points.size() - 1:
		add_segment(points[i], points[i + 1], t, style)


## Arc around c from math angle a0 to a1 (radians, a1 > a0).
func add_arc(c: Vector2, radius: float, t: float, a0: float, a1: float, style := "wall", body := 0) -> int:
	return add_prim(body, ARC, [radius, t, (a1 - a0) * 0.5], c, (a0 + a1) * 0.5 - PI * 0.5, 1, 0, 0.0, style)


## Conveyor belt: rounded slab whose top surface moves at `speed` (+ = right).
func add_belt(x0: float, x1: float, top: float, speed: float, t := 0.04) -> int:
	return add_prim(0, BOX, [(x1 - x0) * 0.5, t, t], Vector2((x0 + x1) * 0.5, top - t), 0.0, 1, 0, speed, "belt")


## Removal zone (box). Particles inside are deactivated and counted in stats slot 8 + id.
func add_sink(a: Vector2, b: Vector2, id: int) -> int:
	var k := add_prim(0, BOX, [absf(b.x - a.x) * 0.5, absf(b.y - a.y) * 0.5, 0.0], (a + b) * 0.5)
	prims[k].flags = FLAG_SINK
	prims[k].sink_id = id
	return k


## Heat zone (box): grains glow up and burn; burnt grains count on sink id.
func add_heat(a: Vector2, b: Vector2, id: int) -> int:
	var k := add_prim(0, BOX, [absf(b.x - a.x) * 0.5, absf(b.y - a.y) * 0.5, 0.0], (a + b) * 0.5)
	prims[k].flags = FLAG_HEAT
	prims[k].sink_id = id
	return k


func pose(b: Dictionary, t: float) -> Array:
	var m: Dictionary = b.motion
	match m.kind:
		"rotate":
			var tr: float = m.ramp
			if t < tr:
				return [b.home, b.home_angle + 0.5 * m.omega * t * t / tr]
			return [b.home, b.home_angle + m.omega * (t - 0.5 * tr)]
		"piston":
			var ph: float = TAU * t / m.period + m.phase
			return [b.home + m.axis * m.stroke * (1.0 - cos(ph)) * 0.5, b.home_angle]
		"flap":
			var k: float = m.k
			return [b.home, b.home_angle + m.amp * tanh(k * sin(TAU * t / m.period)) / tanh(k)]
		"chain":
			var s: float = m.s0 + m.speed * t
			var p := chain_point(m.bottom, m.top, m.rs, s)
			var l := chain_length(m.bottom, m.top, m.rs)
			var u := fposmod(s, l)
			var ang := 0.0
			if m.fixed:
				var dirv := (chain_point(m.bottom, m.top, m.rs, s + 1e-3) - chain_point(m.bottom, m.top, m.rs, s - 1e-3)) * signf(m.speed)
				return [p, b.home_angle + dirv.angle() - PI * 0.5]
			if u > m.tip_s0 and u < m.tip_s1:
				ang = m.tip_angle * sin(PI * (u - m.tip_s0) / (m.tip_s1 - m.tip_s0))
			return [p, b.home_angle + ang]
		"loop":
			var lp := loop_pose(m.p0, m.p1, m.rr, m.s0 + m.speed * t)
			return [lp[0], b.home_angle + lp[1]]
	return [b.pos, b.angle]


## Sets every driven body to its pose/velocity at time t.
func update(t: float) -> void:
	time = t
	var e := 1e-3
	for b in bodies:
		if b.motion.kind == "static":
			continue
		var p0: Array = pose(b, maxf(t - e, 0.0))
		var p1: Array = pose(b, t + e)
		var p: Array = pose(b, t)
		b.pos = p[0]
		b.angle = p[1]
		var dt := (t + e) - maxf(t - e, 0.0)
		b.vel = (p1[0] - p0[0]) / dt
		b.omega = wrapf(p1[1] - p0[1], -PI, PI) / dt


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


func grid_dims() -> Vector2i:
	return Vector2i(ceili(world.x / PCELL), ceili(world.y / PCELL))


## Coarse grid: per cell [count, prim ids...] (PCELL_CAP + 1 ints). A prim is
## listed in every cell its bounding circle can touch during this frame.
func pack_grid(dt: float) -> PackedInt32Array:
	var gd := grid_dims()
	var out := PackedInt32Array()
	out.resize(gd.x * gd.y * (PCELL_CAP + 1))
	grid_overflow = 0
	var margin := 2.0 * SimConst.R_MAX + 0.02
	for k in prims.size():
		var p: Dictionary = prims[k]
		var b: Dictionary = bodies[p.body]
		var c: Vector2
		var rad: float
		if p.repeat > 1:
			c = b.pos
			rad = p.bound
		else:
			c = b.pos + p.offset.rotated(b.angle)
			rad = p.ext
		rad += margin + b.vel.length() * dt + absf(b.omega) * dt * p.bound
		var lo := Vector2i(floori((c.x - rad) / PCELL), floori((c.y - rad) / PCELL)).clamp(Vector2i.ZERO, gd - Vector2i.ONE)
		var hi := Vector2i(floori((c.x + rad) / PCELL), floori((c.y + rad) / PCELL)).clamp(Vector2i.ZERO, gd - Vector2i.ONE)
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var q := Vector2(clampf(c.x, x * PCELL, (x + 1) * PCELL), clampf(c.y, y * PCELL, (y + 1) * PCELL))
				if q.distance_squared_to(c) > rad * rad:
					continue
				var at := (y * gd.x + x) * (PCELL_CAP + 1)
				if out[at] < PCELL_CAP:
					out[at] += 1
					out[at + out[at]] = k
				else:
					grid_overflow += 1
	return out


func upload(solver: GpuSolver) -> void:
	solver.set_colliders(pack_bodies(), pack_prims(), pack_grid(SimConst.DT), grid_dims())


## CPU mirror of colliders.glsli prim_sdf (spawn placement, tests).
func sdf(p: Vector2) -> float:
	var best := INF
	for pr in prims:
		if pr.flags & (FLAG_SINK | FLAG_VISUAL | FLAG_HEAT):
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
