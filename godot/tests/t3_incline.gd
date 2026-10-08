extends SimTest
## T3: rigid bonded block (intact piece) on a slope (gravity rotated by θ over a flat floor) stays put
## iff tanθ < mu_s. θ = φ ± 2° with φ = atan(mu_s). Two independent solvers.

var COLS := 10
var ROWS := 4
var phi := rad_to_deg(atan(SimConst.MATERIALS[1].mu_s))
var solvers: Array[GpuSolver] = []
var thetas := [phi - 2.0, phi + 2.0]
var x0: Array[float] = []


func setup() -> void:
	ROWS = int(args.get("rows", 8))
	COLS = int(args.get("cols", 8))
	if args.has("deg"):
		thetas = [float(args.deg), float(args.deg) + 4.0]
	for th in thetas:
		make_solver(256, Vector2(2.0, 0.3), int(args.get("sub", SimConst.SUBSTEPS)))
		solver.gravity = SimConst.G * Vector2(sin(deg_to_rad(th)), -cos(deg_to_rad(th)))
		var b := Spawn.bonded_block(COLS, ROWS, Vector2(0.2, 0.0), 1, Spawn.SORBET[solvers.size()], 7)
		if args.get("rigid", "1") == "1":
			solver.spawn_piece(0, 0, b, Vector2(0.2, 0.0), Vector2.ZERO)
		else:
			solver.write_set(0, b)
		solvers.append(solver)
		x0.append(_mean_x(b.x, b.size()))


func tick() -> bool:
	for s in solvers:
		s.step()
	frame += 1
	return frame >= 60


func result() -> Dictionary:
	var out := {"phi_deg": snappedf(phi, 0.01)}
	var ok := true
	for k in 2:
		var s := solvers[k]
		var n := COLS * ROWS - ROWS / 2
		var dx := _mean_x(s.read_positions(), n) - x0[k]
		var th := deg_to_rad(thetas[k])
		var mu_k: float = SimConst.MATERIALS[1].mu_k
		var expect := maxf(0.0, 0.5 * SimConst.G * (sin(th) - mu_k * cos(th)))
		var slides := dx > 2.0 * SimConst.R
		ok = ok and slides == (k == 1)
		var pos := s.read_positions()
		var rows := []
		var idx := 0
		for row in ROWS:
			var m := 0.0
			var cnt := COLS - (row % 2)
			for c in cnt:
				m += pos[idx].x
				idx += 1
			rows.append(snappedf(m / cnt, 0.0001))
		out["rows_x_%d" % k] = rows
		# Block tilt from bottom-row end points.
		var a0 := pos[0]
		var a1 := pos[COLS - 1]
		out["tilt_deg_%d" % k] = snappedf(rad_to_deg((a1 - a0).angle()), 0.01)
		out["theta_%d" % k] = {"deg": snappedf(thetas[k], 0.01), "dx_m": snappedf(dx, 0.0001),
			"expected_slide_m": snappedf(expect, 0.0001) if k == 1 else 0.0, "slides": slides,
			"broken": s.read_stats().broken}
	if args.get("dbg", "0") == "1":
		var s1 := solvers[1]
		out["rb"] = Array(s1.read_floats("rb", 0, 64))
		var fr := s1.read_floats("fric", 0, 16 * 4)
		out["fric0_3"] = Array(fr)
		out["d_pen_bottom"] = s1.read_positions()[0].y - SimConst.R
	out["pass"] = ok
	return out


func _mean_x(p: PackedVector2Array, n: int) -> float:
	var m := 0.0
	for i in n:
		m += p[i].x
	return m / n


func cleanup() -> void:
	for s in solvers:
		s.free_all()
