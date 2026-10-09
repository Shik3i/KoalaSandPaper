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
const MU := Vector2(0.6249, 0.6249)
## Coarse collider grid (CPU-built per frame): cell size and max prims per cell.
const PCELL := 0.2
const PCELL_CAP := 31
## Smallest grain diameter is 2·0.9·R = 9 mm: narrower gaps are seals, not pinches.
const SEAL := 0.008

## {pos, angle, vel, omega, name, motion: Dictionary, home, home_angle}
var bodies: Array[Dictionary] = []
## {type, body, repeat, flags, offset, angle, phase, shape[4], mu_s, mu_k, bound, ext, speed, sink_id, style}
var prims: Array[Dictionary] = []
var time := 0.0
var world := Vector2(12.288, 6.912)
var grid_overflow := 0
## Per prim world AABB for this frame (min.xy, max.xy incl. motion), then flags, 0, 0, 0.
var bounds := PackedFloat32Array()
var _static_grid := PackedInt32Array()
var _static_overflow := 0
var _prim_bytes := PackedByteArray()


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


## Piston that never stops: x = (1 - cos θ) / 2 with θ = τ + a sin τ, τ = 2πt/T.
## a ≠ 0 makes it run slower on one side (|a| < 1 keeps it moving).
func piston_swept(body: int, axis: Vector2, stroke: float, period: float, a: float) -> void:
	bodies[body].motion = {"kind": "swept", "axis": axis.normalized(), "stroke": stroke, "period": period, "a": a}


## Telescopic stage: pose = anchor + (target pose + target_off - anchor) * f + off.
func follow(body: int, target: int, anchor: Vector2, target_off: Vector2, f: float, off: Vector2) -> void:
	bodies[body].motion = {"kind": "follow", "target": target, "anchor": anchor, "target_off": target_off, "f": f, "off": off}


## Ram with dwell: waits at home + axis*stroke for `dwell` of the period, sweeps
## to home in `sweep`, returns in the rest (cosine eased).
func ram(body: int, axis: Vector2, stroke: float, period: float, dwell: float, sweep: float) -> void:
	bodies[body].motion = {"kind": "ram", "axis": axis.normalized(), "stroke": stroke, "period": period,
		"dwell": dwell, "sweep": sweep}


## Slide gate: closed (home + axis * stroke) for `closed` s, opens in `move` s,
## stays open for `open_s` s, closes in `move` s; then repeats (cosine eased).
func gate(body: int, axis: Vector2, stroke: float, closed: float, move: float, open_s: float) -> void:
	bodies[body].motion = {"kind": "gate", "axis": axis.normalized(), "stroke": stroke, "closed": closed,
		"move": move, "open": open_s}


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
	return 2.0 * bottom.distance_to(top) + TAU * rs


## Point on the loop around sprockets `bottom` and `top` (any inclination) at arc
## length s. s = 0 is the top end of the left strand (side -n, n = axis rotated
## -90°), increasing s runs down the left strand, around the bottom sprocket,
## up the right strand and over the top (counter-clockwise).
static func chain_point(bottom: Vector2, top: Vector2, rs: float, s: float) -> Vector2:
	var hgt := bottom.distance_to(top)
	var u := (top - bottom) / hgt
	var n := Vector2(u.y, -u.x)
	var l := 2.0 * hgt + TAU * rs
	s = fposmod(s, l)
	if s < hgt:
		return top - n * rs - u * s
	s -= hgt
	if s < PI * rs:
		return bottom + (-n).rotated(s / rs) * rs
	s -= PI * rs
	if s < hgt:
		return bottom + n * rs + u * s
	s -= hgt
	return top + n.rotated(s / rs) * rs


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
	_static_grid.clear()
	_prim_bytes.clear()
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
		"swept":
			var tau: float = TAU * t / m.period
			var th: float = tau + m.a * sin(tau)
			return [b.home + m.axis * m.stroke * (1.0 - cos(th)) * 0.5, b.home_angle]
		"ram":
			var ph: float = fposmod(t / m.period, 1.0)
			var x := 1.0
			if ph >= m.dwell and ph < m.dwell + m.sweep:
				x = 0.5 + 0.5 * cos(PI * (ph - m.dwell) / m.sweep)
			elif ph >= m.dwell + m.sweep:
				x = 0.5 - 0.5 * cos(PI * (ph - m.dwell - m.sweep) / (1.0 - m.dwell - m.sweep))
			return [b.home + m.axis * m.stroke * x, b.home_angle]
		"gate":
			var period: float = m.closed + 2.0 * m.move + m.open
			var u := fposmod(t, period)
			var x := 1.0
			if u >= m.closed and u < m.closed + m.move:
				x = 0.5 + 0.5 * cos(PI * (u - m.closed) / m.move)
			elif u >= m.closed + m.move and u < m.closed + m.move + m.open:
				x = 0.0
			elif u >= m.closed + m.move + m.open:
				x = 0.5 - 0.5 * cos(PI * (u - m.closed - m.move - m.open) / m.move)
			return [b.home + m.axis * m.stroke * x, b.home_angle]
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
		"follow":
			var tp: Vector2 = pose(bodies[m.target], t)[0] + m.target_off
			return [m.anchor + (tp - m.anchor) * m.f + m.off, b.home_angle]
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
## listed in every cell its bounding circle can touch during this frame. Static
## prims are binned once and cached; only moving prims are added per frame.
func pack_grid(dt: float) -> PackedInt32Array:
	var gd := grid_dims()
	if _static_grid.is_empty() or _static_grid.size() != gd.x * gd.y * (PCELL_CAP + 1):
		_static_grid.resize(gd.x * gd.y * (PCELL_CAP + 1))
		_static_grid.fill(0)
		bounds.resize(prims.size() * 8)
		_static_overflow = 0
		for k in prims.size():
			if prims[k].body == 0:
				_static_overflow += _bin_prim(_static_grid, k, dt, gd)
	var out := _static_grid.duplicate()
	grid_overflow = _static_overflow
	for k in prims.size():
		if prims[k].body != 0:
			grid_overflow += _bin_prim(out, k, dt, gd)
	return out


## World AABB of prim k at the bodies' current poses (analytic, exact for one
## pose; polar-repeated prims use their bounding circle).
func prim_aabb(k: int) -> Rect2:
	var p: Dictionary = prims[k]
	var b: Dictionary = bodies[p.body]
	var sh: Array = p.shape
	if p.repeat > 1:
		return Rect2(b.pos - Vector2.ONE * p.bound, Vector2.ONE * 2.0 * p.bound)
	var ang: float = b.angle + p.angle
	var c: Vector2 = b.pos + p.offset.rotated(b.angle)
	var cs := absf(cos(ang))
	var sn := absf(sin(ang))
	var e := Vector2.ZERO
	match p.type:
		CIRCLE:
			e = Vector2(sh[0], sh[0])
		CAPSULE:
			e = Vector2(cs * sh[0] + sh[1], sn * sh[0] + sh[1])
		BOX:
			e = Vector2(cs * sh[0] + sn * sh[1], sn * sh[0] + cs * sh[1])
		ARC:
			e = Vector2.ONE * (sh[0] + sh[1])
			c = b.pos + p.offset.rotated(b.angle)
	return Rect2(c - e, 2.0 * e)


## Adds prim k to the grid cells its AABB (grown by this frame's motion and the
## largest grain) reaches; writes its bounds. Returns the number of full cells.
func _bin_prim(out: PackedInt32Array, k: int, dt: float, gd: Vector2i) -> int:
	var p: Dictionary = prims[k]
	var b: Dictionary = bodies[p.body]
	var box := prim_aabb(k)
	var grow: float = b.vel.length() * dt + absf(b.omega) * dt * p.bound
	box = box.grow(grow)
	bounds[8 * k] = box.position.x
	bounds[8 * k + 1] = box.position.y
	bounds[8 * k + 2] = box.end.x
	bounds[8 * k + 3] = box.end.y
	bounds[8 * k + 4] = p.flags
	var bb := box.grow(2.0 * SimConst.R_MAX + 0.01)
	var lo := Vector2i(floori(bb.position.x / PCELL), floori(bb.position.y / PCELL)).clamp(Vector2i.ZERO, gd - Vector2i.ONE)
	var hi := Vector2i(floori(bb.end.x / PCELL), floori(bb.end.y / PCELL)).clamp(Vector2i.ZERO, gd - Vector2i.ONE)
	var full := 0
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var at := (y * gd.x + x) * (PCELL_CAP + 1)
			if out[at] < PCELL_CAP:
				out[at] += 1
				out[at + out[at]] = k
			else:
				full += 1
	return full


func upload(solver: GpuSolver) -> void:
	var g := pack_grid(SimConst.DT)
	if _prim_bytes.size() != prims.size() * 64:
		_prim_bytes = pack_prims()
	solver.set_colliders(pack_bodies(), _prim_bytes, g, grid_dims(), bounds)


## CPU mirror of colliders.glsli prim_sdf (spawn placement, tests).
func sdf(p: Vector2, static_only := false) -> float:
	var best := INF
	for pr in prims:
		if pr.flags & (FLAG_SINK | FLAG_VISUAL | FLAG_HEAT) or (static_only and pr.body != 0):
			continue
		best = minf(best, prim_distance(pr, p))
	return best


## Signed distance from world point p to one prim at the bodies' current poses.
func prim_distance(pr: Dictionary, p: Vector2) -> float:
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
	return -d if pr.flags & FLAG_INVERTED else d


## Moving parts must never touch other parts (static or moving): samples every
## moving prim's outline over `duration` and reports the deepest contact
## (distance < 2 mm) per pair of body names. Designed exceptions: cleats on their
## belt, telescopic stages in their barrel and in each other, a ram head on its stages.
func touching(duration: float, steps: int) -> Dictionary:
	var worst := {}
	var allowed := [["cleat", ""], ["stage", "stage"], ["stage", "pusher"], ["stage", ""]]
	for step in steps:
		update(duration * step / steps)
		var boxes: Array[Rect2] = []
		for k in prims.size():
			boxes.append(prim_aabb(k).grow(0.003))
		for ki in prims.size():
			var pr: Dictionary = prims[ki]
			if pr.body == 0 or pr.flags & (FLAG_SINK | FLAG_VISUAL | FLAG_HEAT):
				continue
			# Candidates: prims of other bodies whose box meets this prim's box.
			var cand: Array[Dictionary] = []
			for ko in prims.size():
				var o: Dictionary = prims[ko]
				if o.body != pr.body and not (o.flags & (FLAG_SINK | FLAG_VISUAL | FLAG_HEAT)) and boxes[ko].intersects(boxes[ki]):
					cand.append(o)
			if cand.is_empty():
				continue
			var xf := body_xform(pr.body)
			var na: String = bodies[pr.body].name
			for k in pr.repeat:
				var rep := Transform2D(TAU * k / pr.repeat, Vector2.ZERO)
				for q in outline(pr, 16):
					var p: Vector2 = xf * (rep * q)
					if q.y < -pr.shape[1] + 0.035 and pr.type == BOX and na == "pusher":
						continue  # ram sole: wiper seal on the floor plate by design
					if q.y > pr.shape[1] - 0.01 and pr.type == BOX and na == "gate":
						continue  # slide gate top: wiper seal under the bin dividers
					for other in cand:
						var nb: String = bodies[other.body].name if other.body != 0 else ""
						if [na, nb] in allowed or [nb, na] in allowed:
							continue
						if na == "cleat" and other.style == "belt":
							continue
						var d := prim_distance(other, p)
						if d < 0.002:
							var key := "%s/%s" % [na, nb if nb != "" else other.style]
							if not worst.has(key) or d < worst[key].d:
								worst[key] = {"d": snappedf(d, 0.0001), "at": p, "t": snappedf(duration * step / steps, 0.01)}
	update(0.0)
	return worst


## Clearance audit: samples every moving collider over `duration` seconds and
## returns the smallest distance to static geometry (body 0) with the worst spot.
## Pinch gaps below one grain diameter are where grains get crushed.
func clearance(duration: float, steps: int) -> Dictionary:
	var worst := INF
	var where := Vector2.ZERO
	var who := ""
	# Gaps under SEAL are seals (smaller than the smallest grain, nothing enters);
	# the pinch band is SEAL .. 3 cm.
	for step in steps:
		update(duration * step / steps)
		for pr in prims:
			# Cleats ride on their belt and ram stages slide in their barrel by design
			# (the ram head, taller than every stage, sweeps the same path and is
			# checked); everything else must keep clear.
			if pr.body == 0 or pr.flags & (FLAG_SINK | FLAG_VISUAL | FLAG_HEAT) or bodies[pr.body].name in ["cleat", "stage"]:
				continue
			var xf := body_xform(pr.body)
			for k in pr.repeat:
				var rep := Transform2D(TAU * k / pr.repeat, Vector2.ZERO)
				for q in outline(pr, 16):
					var p: Vector2 = xf * (rep * q)
					if q.y < -pr.shape[1] + 0.035 and pr.type == BOX and bodies[pr.body].name == "pusher":
						continue  # ram head's sole: a seal on the floor that opens over the floor's end
					if q.y > pr.shape[1] - 0.01 and pr.type == BOX and bodies[pr.body].name == "gate":
						continue  # slide gate top: wiper seal under the bin dividers
					var d := sdf(p, true)
					if d >= SEAL and d < worst:
						worst = d
						where = p
						who = bodies[pr.body].name
	update(0.0)
	return {"min_open_gap_m": snappedf(worst, 0.0001), "at": where, "body": who, "pinch": worst < 0.03}


## Primitive outline in body space (before polar repeat), n points per arc.
static func outline(p: Dictionary, n := 24) -> PackedVector2Array:
	var local := PackedVector2Array()
	var sh: Array = p.shape
	match p.type:
		CIRCLE:
			for i in n:
				local.append(Vector2.from_angle(TAU * i / n) * sh[0])
		CAPSULE:
			for i in n / 2 + 1:
				local.append(Vector2(sh[0], 0) + Vector2.from_angle(-PI / 2 + PI * i / (n / 2)) * sh[1])
			for i in n / 2 + 1:
				local.append(Vector2(-sh[0], 0) + Vector2.from_angle(PI / 2 + PI * i / (n / 2)) * sh[1])
		BOX:
			var c: float = sh[2]
			var e := Vector2(sh[0], sh[1]) - Vector2(c, c)
			for q in 4:
				var ctr := Vector2(e.x * (1 if q == 0 or q == 3 else -1), e.y * (1 if q < 2 else -1))
				for i in 6:
					local.append(ctr + Vector2.from_angle(PI / 2 * q + PI / 2 * i / 5.0) * c)
		ARC:
			var ra: float = sh[0]
			var rb: float = sh[1]
			var half: float = sh[2]
			for i in n + 1:
				local.append(Vector2.from_angle(PI / 2 - half + 2.0 * half * i / n) * (ra + rb))
			for i in n + 1:
				local.append(Vector2.from_angle(PI / 2 + half - 2.0 * half * i / n) * (ra - rb))
	var xf := Transform2D(p.angle, p.offset)
	var out := PackedVector2Array()
	for q in local:
		out.append(xf * q)
	return out

