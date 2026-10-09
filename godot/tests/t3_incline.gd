extends SimTest
## T3: tilting-plane test for a rigid piece (8 x 8 grain block). The block settles
## on a flat floor, the plane is tilted slowly (gravity rotated over 0.5 s) to θ
## and held for 1 s. Coulomb with static/kinetic friction: below φ = atan(mu_s)
## the block stays (θ = φ - 2°: moves < 2 R); above it slides (θ = φ + 2°) with
## acceleration g (sin θ - mu_k cos θ) (within 15 %, measured over the hold).

const SETTLE := 30
const TILT := 30
const HOLD := 60

var COLS := 8
var ROWS := 8
var phi := rad_to_deg(atan(SimConst.MATERIALS[1].mu_s))
var solvers: Array[GpuSolver] = []
var thetas := [phi - 2.0, phi + 2.0]
var x_hold: Array[float] = [0.0, 0.0]
var v_mid: Array[float] = [0.0, 0.0]


func setup() -> void:
	ROWS = int(args.get("rows", ROWS))
	COLS = int(args.get("cols", COLS))
	if args.has("deg"):
		thetas = [float(args.deg), float(args.deg) + 4.0]
	for th in thetas:
		make_solver(256, Vector2(2.0, 0.3))
		var b := Spawn.bonded_block(COLS, ROWS, Vector2(0.2, 0.0), 1, Spawn.SORBET[solvers.size()], 7)
		solver.spawn_piece(0, GpuSolver.slot_range(0, b.size()), b, Vector2(0.2, 0.0), Vector2.ZERO)
		solvers.append(solver)


func tick() -> bool:
	for k in 2:
		var s := solvers[k]
		var tilt := clampf(float(frame - SETTLE) / TILT, 0.0, 1.0)
		var th := deg_to_rad(thetas[k]) * tilt
		s.gravity = SimConst.G * Vector2(sin(th), -cos(th))
		s.step()
		if frame + 1 == SETTLE + TILT:
			x_hold[k] = _body(s).x
		if frame + 1 == SETTLE + TILT + HOLD / 2:
			v_mid[k] = _body(s).z
	frame += 1
	return frame >= SETTLE + TILT + HOLD


## Body state of piece 0: (x, y, vx, vy).
func _body(s: GpuSolver) -> Vector4:
	var rb := s.read_body(0)
	return Vector4(rb[0], rb[1], rb[4], rb[5])


func result() -> Dictionary:
	var out := {"phi_deg": snappedf(phi, 0.01)}
	var ok := true
	var mu_k: float = SimConst.MATERIALS[1].mu_k
	for k in 2:
		var s := solvers[k]
		var b := _body(s)
		var dx := b.x - x_hold[k]
		var th := deg_to_rad(thetas[k])
		var a_expect := maxf(0.0, SimConst.G * (sin(th) - mu_k * cos(th)))
		# Mean acceleration over the second half of the hold.
		var a := (b.z - v_mid[k]) / (HOLD / 2 * SimConst.DT)
		var slides := dx > 2.0 * SimConst.R
		ok = ok and slides == (k == 1)
		if k == 1:
			ok = ok and absf(a - a_expect) < 0.15 * a_expect
		out["theta_%d" % k] = {"deg": snappedf(thetas[k], 0.01), "dx_m": snappedf(dx, 0.0001), "slides": slides,
			"accel": snappedf(a, 0.001), "expected_accel": snappedf(a_expect, 0.001), "broken": s.read_stats().broken}
	out["pass"] = ok
	return out


func cleanup() -> void:
	for s in solvers:
		s.free_all()
