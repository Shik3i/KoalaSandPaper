extends SimTest
## T2: pour three streams (3 seeds) onto a plane; the mean fitted flank slope of
## the three heaps must be within ±3° of dry sand's angle of repose
## (SimConst.REPOSE_DEG = 32°), every single heap within ±6° (pouring scatters).

const SLOTS := 3
const SLOT_W := 3.0
const PER_HEAP := 5000
const PER_FRAME := 8
const SETTLE := 240

var pos_x: Array[float] = []
var next := 0
var rngs: Array[RandomNumberGenerator] = []
var angles: Array = []
var stats := {}


func setup() -> void:
	make_solver(SLOTS * PER_HEAP, Vector2(SLOTS * SLOT_W, 1.2))
	for k in SLOTS:
		pos_x.append((k + 0.5) * SLOT_W)
		rngs.append(Spawn.rng_for(int(args.get("seed", 1)) * 100 + k))


func tick() -> bool:
	if next < PER_HEAP:
		var s := ParticleSet.new()
		for k in SLOTS:
			for j in PER_FRAME:
				var rng := rngs[k]
				var p := Vector2(pos_x[k] + (j - PER_FRAME * 0.5 + 0.5) * 2.3 * SimConst.R_MAX + rng.randf_range(-0.2, 0.2) * SimConst.R,
						0.9 + rng.randf_range(0.0, 0.3) * SimConst.R)
				s.add(p, Spawn.grain_radius(rng), GpuSolver.info_word(1, 0), Spawn.vary(Spawn.SORBET[k], rng), Vector2(0, -1.5))
		# Interleave slots so each heap gets its own contiguous range.
		for k in SLOTS:
			var sub := ParticleSet.new()
			for j in PER_FRAME:
				var i := k * PER_FRAME + j
				sub.add(s.x[i], s.rad[i], s.info[i], s.color[i], s.v[i])
			solver.write_set(k * PER_HEAP + next, sub)
		next += PER_FRAME
	step()
	return next >= PER_HEAP and frame >= PER_HEAP / PER_FRAME + SETTLE


func result() -> Dictionary:
	stats = solver.read_stats()
	var pos := solver.read_positions()
	var ok := true
	var target := SimConst.REPOSE_DEG
	var mean := 0.0
	for k in SLOTS:
		var a := _fit(pos.slice(k * PER_HEAP, (k + 1) * PER_HEAP), pos_x[k])
		angles.append(a)
		mean += a.mean / SLOTS
		ok = ok and absf(a.mean - target) <= 6.0
	ok = ok and absf(mean - target) <= 3.0
	var ov := Probe.overlap(pos, solver.read_radii())
	return {"pass": ok, "target_deg": snappedf(target, 0.1), "mean_deg": snappedf(mean, 0.1), "angles": angles, "max_pen_r": ov.max_pen_r, "stats": stats}


## Heap profile: top surface per x bin; least-squares line on each flank between
## 20% and 80% of the peak height.
func _fit(p: PackedVector2Array, cx: float) -> Dictionary:
	var bw := 4.0 * SimConst.R
	var tops := {}
	for q in p:
		var b := floori((q.x - cx) / bw)
		tops[b] = maxf(tops.get(b, 0.0), q.y)
	var peak := 0.0
	for b in tops:
		peak = maxf(peak, tops[b])
	var out := {}
	for side in [-1, 1]:
		var xs: Array[float] = []
		var ys: Array[float] = []
		for b in tops:
			var y: float = tops[b]
			if sign(b + 0.5) == side and y > 0.2 * peak and y < 0.8 * peak:
				xs.append(absf((b + 0.5) * bw))
				ys.append(y)
		var n := xs.size()
		if n < 3:
			out[side] = 0.0
			continue
		var mx := 0.0
		var my := 0.0
		for i in n:
			mx += xs[i] / n
			my += ys[i] / n
		var sxy := 0.0
		var sxx := 0.0
		for i in n:
			sxy += (xs[i] - mx) * (ys[i] - my)
			sxx += (xs[i] - mx) * (xs[i] - mx)
		out[side] = rad_to_deg(atan(-sxy / sxx))
	return {"left": snappedf(out[-1], 0.1), "right": snappedf(out[1], 0.1),
		"mean": snappedf(0.5 * (out[-1] + out[1]), 0.1), "peak_m": snappedf(peak, 0.001)}
