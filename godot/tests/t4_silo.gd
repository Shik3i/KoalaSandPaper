extends SimTest
## T4: three flat-bottomed silos (orifice D = 6, 9, 12 grain diameters) discharge
## into their own sinks. Steady flow rate W (between 20 % and 70 % discharged)
## must follow 2D Beverloo W = C (D - k d)^1.5: best-fit (C, k) with every silo
## within 15 %.

const N := 3500
const W_SILO := 0.5
const H_FLOOR := 0.35
var widths := [0.06, 0.09, 0.12]
var xs := [0.5, 1.5, 2.5]
var samples: Array = [[], [], []]


func setup() -> void:
	machine = Machine.new()
	for k in 3:
		var cx: float = xs[k]
		var half: float = widths[k] * 0.5
		var l := cx - W_SILO * 0.5
		var r := cx + W_SILO * 0.5
		machine.add_segment(Vector2(l, H_FLOOR), Vector2(l, 1.5), 0.02)
		machine.add_segment(Vector2(r, H_FLOOR), Vector2(r, 1.5), 0.02)
		machine.add_segment(Vector2(l, H_FLOOR), Vector2(cx - half - 0.02, H_FLOOR), 0.02)
		machine.add_segment(Vector2(cx + half + 0.02, H_FLOOR), Vector2(r, H_FLOOR), 0.02)
		machine.add_sink(Vector2(cx - 0.4, 0.0), Vector2(cx + 0.4, 0.2), k)
	machine.update(0.0)
	make_solver(3 * N, Vector2(3.0, 1.6), int(args.get("sub", 32)))
	var all := ParticleSet.new()
	for k in 3:
		# Orifice blocked during filling by spawning above it: grains settle first,
		# since the hex block starts 4 cm above the floor and the flow is measured
		# only in the steady window.
		all.append(Spawn.block(N, Vector2(xs[k] - W_SILO * 0.5 + 0.03, H_FLOOR + 0.04), 38, 10 + k))
	solver.write_set(0, all)


func tick() -> bool:
	step()
	if frame % 6 == 0:
		var sinks := solver.read_sinks()
		for k in 3:
			samples[k].append([solver.sim_time, sinks[k]])
	return solver.sim_time > float(args.get("secs", 25.0))


func result() -> Dictionary:
	var rates: Array[float] = []
	for k in 3:
		var t0 := -1.0
		var t1 := -1.0
		var n0 := 0
		var n1 := 0
		for smp in samples[k]:
			if t0 < 0.0 and smp[1] >= 0.2 * N:
				t0 = smp[0]
				n0 = smp[1]
			if t1 < 0.0 and smp[1] >= 0.7 * N:
				t1 = smp[0]
				n1 = smp[1]
		rates.append((n1 - n0) / (t1 - t0) if t1 > t0 and t0 >= 0.0 else 0.0)
	# Fit k on a grid, C by least squares on W^(2/3) = C^(2/3) (D - k d).
	var d := 2.0 * SimConst.R
	var best := {"err": INF}
	for ki in 301:
		var kk := ki * 0.01
		var num := 0.0
		var den := 0.0
		for i in 3:
			var x := pow(maxf(widths[i] - kk * d, 1e-6), 1.5)
			num += x * rates[i]
			den += x * x
		var c := num / den
		var err := 0.0
		for i in 3:
			var pred := c * pow(maxf(widths[i] - kk * d, 1e-6), 1.5)
			err = maxf(err, absf(rates[i] - pred) / maxf(rates[i], 1e-9))
		if err < best.err:
			best = {"err": err, "k": kk, "C": c}
	var ok: bool = best.err <= 0.15 and rates.min() > 0.0
	return {"pass": ok, "rates_grains_per_s": rates.map(func(v): return snappedf(v, 0.1)), "D_m": widths,
		"fit_k": best.get("k", -1.0), "max_rel_err": snappedf(best.err, 0.001), "stats": solver.read_stats()}
