extends SimTest
## Sand-quality benchmarks (does it behave like dry sand, not like a light fluid?).
##   case=collapse  quasi-2D granular column collapse against a wall, a = H0/L0 = 2.
##                  Lube et al. 2005: (L∞ - L0)/L0 ≈ 1.2 a; Lajeunesse et al. 2005: ≈ a.
##                  Then 1 s at rest: jitter (displacement per grain, in R).
##   case=impact    a 0.3 m block falls 0.7 m onto a settled bed: ejecta height of bed grains.
##   case=push      a blade (cosine stroke 2 m in 4 s, peak 0.79 m/s) ploughs a heap on a rough floor
##                  (sole sealed into it, like the factory ram): no grain shot out.

const SETTLE_S := 4.0
const MEASURE_S := 1.0
const PUSH_DELAY := 2.0

var case_ := "collapse"
var n := 0
var h0 := 0.4
var l0 := 0.2
var max_speed := 0.0
var p99_speed_peak := 0.0
var ejecta_max := 0.0
var ejecta_n := 0
var bed_n := 0
var bed_y0 := PackedFloat32Array()
var bed_top := 0.0
var pos_rest := PackedVector2Array()
var jitter := {}
var dropped := false
var blade := 0
var spray_max := 0.0
var fast_n := 0
var t_runout := -1.0


func setup() -> void:
	case_ = args.get("case", "collapse")
	match case_:
		"collapse":
			make_solver(6000, Vector2(1.6, 0.6))
			var cols := int(l0 / (2.0 * SimConst.R_MAX * 1.02))
			var rows := int(h0 / (2.0 * SimConst.R_MAX * 1.02 * sqrt(3.0) * 0.5))
			n = cols * rows
			solver.write_set(0, Spawn.block(n, Vector2(SimConst.R_MAX, SimConst.R_MAX), cols, 7))
			solver.active_n = n
			# Gate holding the column until t = 0.
		"impact":
			make_solver(8000, Vector2(2.4, 1.8))
			var bed := Spawn.block(4400, Vector2(SimConst.R_MAX, SimConst.R_MAX), 210, 3)
			bed_n = bed.size()
			solver.write_set(0, bed)
			n = bed_n
		"push":
			machine = Machine.new()
			machine.world = Vector2(3.0, 1.0)
			var fl := machine.add_segment(Vector2(0.05, 0.1), Vector2(2.95, 0.1), 0.025)
			machine.prims[fl].mu_s = Factory.FLOOR_MU
			machine.prims[fl].mu_k = Factory.FLOOR_MU
			var half := Vector2(0.045, float(args.get("bh", 0.13)))
			blade = machine.add_body(Vector2(0.3, 0.1 + 0.025 + float(args.get("gap", -Factory.SOLE_DEPTH)) + half.y), 0.0, "pusher")
			machine.piston(blade, Vector2(1.0, 0.0), 2.0, 8.0, 0.0)
			machine.add_prim(blade, Machine.BOX, [half.x, half.y, 0.003])
			machine.update(0.0)
			make_solver(6000, Vector2(3.0, 1.0))
			var heap := Spawn.block(4000, Vector2(0.45, 0.13), 100, 5)
			n = heap.size()
			solver.write_set(0, heap)
	solver.active_n = n


func tick() -> bool:
	if case_ == "impact" and not dropped and solver.sim_time >= 1.5:
		var pos := solver.read_positions()
		bed_y0 = PackedFloat32Array()
		for i in bed_n:
			bed_y0.append(pos[i].y)
			bed_top = maxf(bed_top, pos[i].y)
		var blk := Spawn.block(1800, Vector2(1.05, bed_top + 0.4), 60, 9, [0xffffff])
		solver.write_set(bed_n, blk)
		n = bed_n + blk.size()
		solver.active_n = n
		dropped = true
	step()
	_sample()
	return solver.sim_time >= _duration()


func step() -> void:
	if machine:
		machine.world = solver.world
		machine.update(maxf(solver.sim_time - PUSH_DELAY, 0.0))
		machine.upload(solver)
	solver.step()
	frame += 1


func _duration() -> float:
	match case_:
		"collapse":
			return SETTLE_S + MEASURE_S
		"impact":
			return 4.0
	return PUSH_DELAY + 4.0


func _sample() -> void:
	var vel := solver.read_velocities()
	var pos := solver.read_positions()
	var speeds := PackedFloat32Array()
	for i in n:
		var s := vel[i].length()
		speeds.append(s)
		max_speed = maxf(max_speed, s)
	speeds.sort()
	p99_speed_peak = maxf(p99_speed_peak, speeds[int(0.99 * (speeds.size() - 1))])
	match case_:
		"collapse":
			if absf(solver.sim_time - SETTLE_S) < 0.5 * SimConst.DT:
				pos_rest = pos.slice(0, n)
		"impact":
			if dropped:
				for i in bed_n:
					var e := pos[i].y - bed_y0[i]
					if e > ejecta_max:
						ejecta_max = e
				var cnt := 0
				for i in bed_n:
					if pos[i].y > bed_top + 0.05:
						cnt += 1
				ejecta_n = maxi(ejecta_n, cnt)
		"push":
			var bv: float = machine.bodies[blade].vel.length()
			if solver.sim_time < PUSH_DELAY:
				return
			var cnt := 0
			for i in n:
				spray_max = maxf(spray_max, pos[i].y)
				if vel[i].length() > 2.0 * maxf(bv, 0.25):
					cnt += 1
			fast_n = maxi(fast_n, cnt)


func result() -> Dictionary:
	var pos := solver.read_positions()
	var st := solver.read_stats()
	var out := {"case": case_, "max_speed": snappedf(max_speed, 0.01), "p99_speed_peak": snappedf(p99_speed_peak, 0.01),
		"stats": {"clamp": st.clamp, "overflow": st.overflow, "max_pen_r": st.max_pen_r}}
	match case_:
		"collapse":
			# Runout: farthest grain that is part of the deposit (≤ 5 isolated grains beyond).
			var xs := PackedFloat32Array()
			var top := 0.0
			for i in n:
				xs.append(pos[i].x)
				if pos[i].x < 0.03:
					top = maxf(top, pos[i].y)
			xs.sort()
			var runout := xs[xs.size() - 6]
			var a := h0 / l0
			var dl := (runout - l0) / l0
			var disp := PackedFloat32Array()
			for i in n:
				disp.append(pos[i].distance_to(pos_rest[i]) / SimConst.R)
			disp.sort()
			out.merge({"a": a, "runout_m": snappedf(runout, 0.001), "dL_over_L0": snappedf(dl, 0.01),
				"expected": [snappedf(a, 0.01), snappedf(1.2 * a, 0.01)], "H_final_over_L0": snappedf(top / l0, 0.01),
				"jitter_R_per_s": {"mean": snappedf(_mean(disp), 0.0001), "p99": snappedf(disp[int(0.99 * (disp.size() - 1))], 0.0001), "max": snappedf(disp[disp.size() - 1], 0.0001)}})
			out["pass"] = dl > 0.8 * a and dl < 1.5 * a and disp[int(0.99 * (disp.size() - 1))] < 0.05
		"impact":
			out.merge({"bed_top_m": snappedf(bed_top, 0.001), "impact_speed": snappedf(sqrt(2.0 * 9.81 * 0.4), 0.01),
				"ejecta_max_m": snappedf(ejecta_max, 0.001), "bed_grains_above_5cm_peak": ejecta_n})
			# A 2.8 m/s impact into a sand bed throws up an ejecta curtain; a light
			# fluid would splash far higher.
			out["pass"] = ejecta_max < 0.2
		"push":
			out.merge({"spray_max_y_m": snappedf(spray_max, 0.001),  "fast_grains_peak": fast_n})
			# Grains faster than twice the blade are the heap's own avalanches (front
			# face, spill over the blade top: free fall from the 0.55 m crest gives
			# 3.3 m/s). Anything faster was shot out (wedged under an edge, squeezed).
			out["pass"] = max_speed < 4.0 and st.max_pen_r < 1.2
	return out


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(a.size(), 1)
