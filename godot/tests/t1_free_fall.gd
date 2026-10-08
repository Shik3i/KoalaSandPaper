extends SimTest
## T1: grain released from rest follows y(t) = y0 - g t²/2 within 1% of the
## drop over 1 s (no drag). Substeps raised so 0.5 r/substep covers 9.81 m/s.

const Y0 := 5.5
var errs: Array[float] = []
var worst := 0.0


func setup() -> void:
	make_solver(1, Vector2(0.2, 6.0), 80)
	solver.damping = 0.0
	var s := ParticleSet.new()
	s.add(Vector2(0.1, Y0), SimConst.R, GpuSolver.info_word(1, 0), 0xf6b17a)
	solver.write_set(0, s)


func tick() -> bool:
	step()
	var t := frame * SimConst.DT
	if frame % 6 == 0:
		var y := solver.read_positions()[0].y
		var expect := 0.5 * SimConst.G * t * t
		worst = maxf(worst, absf((Y0 - y) - expect) / maxf(expect, 1e-9))
		errs.append(snappedf(Y0 - y, 0.0001))
	return frame >= 60


func result() -> Dictionary:
	var st := solver.read_stats()
	var drop := Y0 - solver.read_positions()[0].y
	var rel := absf(drop - 0.5 * SimConst.G) / (0.5 * SimConst.G)
	return {"pass": rel < 0.01 and worst < 0.02 and st.clamp == 0, "drop_1s": snappedf(drop, 0.0001),
		"expected": 0.5 * SimConst.G, "rel_err": snappedf(rel, 0.00001), "worst_rel_err_after_0.1s": snappedf(worst, 0.0001),
		"clamp": st.clamp, "substeps": solver.substeps}
